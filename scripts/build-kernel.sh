#!/usr/bin/env bash
# odin kernel CI builder.
#
# Environment inputs:
#   VARIANT     vanilla | finasu | finasu-susfs   (default: vanilla)
#   OPTS        0 | 1                             (default: 0) smoothness config layer
#   FINASU_REF  FinaSU git tag to integrate       (default: v1.3.2)
#
# Outputs land in ./out : Image, .config, utsrelease.txt, SHA256SUMS.
set -euo pipefail

VARIANT="${VARIANT:-vanilla}"
OPTS="${OPTS:-0}"
FINASU_REF="${FINASU_REF:-v1.3.2}"

ROOT="$(pwd)"
WORK="$ROOT/work"
OUT="$ROOT/out"
KSRC="$WORK/kernel"
FDIR="$WORK/FinaSU"
mkdir -p "$WORK" "$OUT"

KERNEL_URL="https://github.com/Inkypen79/kernel_xiaomi_odin.git"
KERNEL_BRANCH="lineage-24.0"
FINASU_URL="https://github.com/LyraVoid/FinaSU.git"
CLANG_WANT="clang-r574158"

step() { echo; echo "===== $* ====="; }

step "inputs: VARIANT=$VARIANT OPTS=$OPTS FINASU_REF=$FINASU_REF"

# ---------------------------------------------------------------- deps
step "install host dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  bc bison flex libssl-dev libelf-dev libdw-dev dwarves \
  zip unzip python3 git curl wget xz-utils zstd \
  build-essential gcc-aarch64-linux-gnu

# ---------------------------------------------------------------- clang
step "fetch AOSP clang ($CLANG_WANT preferred)"
TOOLBIN="$WORK/toolchain/bin"
mkdir -p "$TOOLBIN"
CLANG_HOME=""
if git clone --depth 1 --filter=blob:none --sparse \
      https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
      "$WORK/clang-prebuilts" 2>"$WORK/clang-clone.log"; then
  cd "$WORK/clang-prebuilts"
  PICK="$(git ls-tree --name-only HEAD | grep -E '^clang-r[0-9]+$' | sort -V | grep -x "$CLANG_WANT" || true)"
  if [ -z "$PICK" ]; then
    PICK="$(git ls-tree --name-only HEAD | grep -E '^clang-r[0-9]+$' | sort -V | tail -1 || true)"
  fi
  if [ -n "$PICK" ]; then
    echo "sparse-checkout $PICK"
    git sparse-checkout set "$PICK"
    CLANG_HOME="$WORK/clang-prebuilts/$PICK"
  fi
  cd "$ROOT"
else
  echo "googlesource sparse clone failed, see work/clang-clone.log"
fi

if [ -z "$CLANG_HOME" ] || [ ! -x "$CLANG_HOME/bin/clang" ]; then
  step "fallback: apt.llvm.org clang 21"
  wget -q https://apt.llvm.org/llvm.sh -O "$WORK/llvm.sh"
  sudo bash "$WORK/llvm.sh" 21
  sudo apt-get install -y -qq lld-21 llvm-21
  CLANG_HOME="/usr/lib/llvm-21"
fi

for t in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip llvm-as; do
  src="$CLANG_HOME/bin/$t"
  [ -x "$src" ] || src="$(command -v "$t-21" || true)"
  [ -n "$src" ] && ln -sf "$src" "$TOOLBIN/$t"
done
export PATH="$TOOLBIN:$PATH"
clang --version | head -2

# ---------------------------------------------------------------- kernel source
step "clone kernel ($KERNEL_BRANCH)"
git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_URL" "$KSRC"

MAKE_ARGS=(
  -C "$KSRC" O="$WORK/kout" ARCH=arm64
  CC=clang HOSTCC=clang HOSTCXX=clang++
  CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-
  LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
)

EXTRA_MAKE_VARS=()

# ---------------------------------------------------------------- FinaSU
if [ "$VARIANT" = "finasu" ] || [ "$VARIANT" = "finasu-susfs" ]; then
  step "clone FinaSU $FINASU_REF"
  git clone "$FINASU_URL" "$FDIR"
  git -C "$FDIR" checkout "$FINASU_REF"

  step "integrate FinaSU into kernel tree"
  ( cd "$KSRC" && bash "$FDIR/kernel/setup.sh" --dir "$FDIR" )

  if [ "$VARIANT" = "finasu-susfs" ]; then
    echo "ERROR: finasu-susfs is phase 3 and not wired up yet." >&2
    exit 1
  fi

  step "extract manager signature from official FinaSU manager APK"
  APK_URL="$(curl -s "https://api.github.com/repos/LyraVoid/FinaSU/releases/tags/$FINASU_REF" \
    | python3 -c 'import json,sys
rel = json.load(sys.stdin)
for a in rel.get("assets", []):
    n = a.get("name", "")
    if n.endswith("-release.apk") and "FinaSU" in n:
        print(a["browser_download_url"]); break')"
  if [ -z "$APK_URL" ]; then
    echo "ERROR: manager APK asset not found in release $FINASU_REF" >&2
    exit 1
  fi
  curl -sL "$APK_URL" -o "$WORK/manager.apk"
  CERT_OUT="$(python3 "$ROOT/scripts/extract_manager_cert.py" "$WORK/manager.apk")"
  echo "manager cert: $CERT_OUT"
  KSU_SIZE="$(echo "$CERT_OUT" | sed -n 's/^KSU_EXPECTED_SIZE=//p')"
  KSU_HASH="$(echo "$CERT_OUT" | sed -n 's/^KSU_EXPECTED_HASH=//p')"
  if [ -z "$KSU_SIZE" ] || [ -z "$KSU_HASH" ]; then
    echo "ERROR: failed to derive KSU_EXPECTED_SIZE / KSU_EXPECTED_HASH" >&2
    exit 1
  fi
  EXTRA_MAKE_VARS+=(KSU_EXPECTED_SIZE="$KSU_SIZE" KSU_EXPECTED_HASH="$KSU_HASH" KSU_REQUIRE_PREINIT=1)
fi

# ---------------------------------------------------------------- config
step "configure (odin_defconfig)"
make "${MAKE_ARGS[@]}" odin_defconfig

CFG="$WORK/kout/.config"
if [ "$VARIANT" != "vanilla" ]; then
  step "enable FinaSU config"
  "$KSRC/scripts/config" --file "$CFG" \
    --enable KSU --enable KPROBES --enable KALLSYMS_ALL \
    --enable EXT4_FS --enable HEADERS_INSTALL
fi

if [ "$OPTS" = "1" ]; then
  step "apply smoothness config layer"
  "$KSRC/scripts/config" --file "$CFG" \
    --disable HZ_250 --enable HZ_1000 \
    --enable TCP_CONG_BBR --enable DEFAULT_BBR --disable DEFAULT_CUBIC
fi

make "${MAKE_ARGS[@]}" olddefconfig
grep -E '^CONFIG_(KSU|KPROBES|KALLSYMS_ALL|HZ)=' "$CFG" || true

# ---------------------------------------------------------------- build
step "build Image"
make "${MAKE_ARGS[@]}" "${EXTRA_MAKE_VARS[@]}" -j"$(nproc)" Image

# ---------------------------------------------------------------- collect
step "collect artifacts"
cp "$WORK/kout/arch/arm64/boot/Image" "$OUT/Image"
cp "$CFG" "$OUT/kernel.config"
grep -o '"[^"]*"' "$WORK/kout/include/generated/utsrelease.h" | head -1 | tr -d '"' \
  > "$OUT/utsrelease.txt" || true
( cd "$OUT" && sha256sum Image > SHA256SUMS )
cat "$OUT/utsrelease.txt" || true
ls -lh "$OUT"
step "done"
