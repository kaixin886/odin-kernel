#!/usr/bin/env bash
# odin kernel CI builder.
#
# Environment inputs:
#   VARIANT     vanilla | finasu | finasu-susfs   (default: vanilla)
#   OPTS        off | smooth | battery            (default: off) config layer
#   FINASU_REF  FinaSU git tag to integrate       (default: v1.3.2)
#
# Outputs land in ./out : Image, .config, utsrelease.txt, SHA256SUMS.
set -euo pipefail

VARIANT="${VARIANT:-vanilla}"
OPTS="${OPTS:-off}"
FINASU_REF="${FINASU_REF:-v1.3.2}"

# Backwards-compatible aliases for the old boolean switch.
case "$OPTS" in
  1) OPTS=smooth ;;
  0) OPTS=off ;;
esac

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
# Pin the Android 17 release tag: its tree carries clang-r574158, the exact
# toolchain Inkypen recorded in odin_defconfig. The default branch has
# already pruned that directory and only ships much newer clangs.
if git clone --depth 1 --filter=blob:none --sparse --branch android-17.0.0_r1 \
      https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
      "$WORK/clang-prebuilts" 2>"$WORK/clang-clone.log"; then
  cd "$WORK/clang-prebuilts"
  mapfile -t ALL_DIRS < <(git ls-tree --name-only HEAD | grep -E '^clang-r[0-9]+$' | sort -V)
  echo "available clang dirs: ${ALL_DIRS[*]:-none}"
  PICK="$(printf '%s\n' "${ALL_DIRS[@]}" | grep -x "$CLANG_WANT" || true)"
  if [ -z "$PICK" ] && [ "${#ALL_DIRS[@]}" -gt 0 ]; then
    PICK="${ALL_DIRS[-1]}"
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

# AOSP clang ships `clang` as a wrapper that execs a sibling `clang-real`;
# link the whole bin directory so every sibling stays resolvable.
for f in "$CLANG_HOME/bin/"*; do
  [ -e "$f" ] && ln -sf "$f" "$TOOLBIN/$(basename "$f")"
done
# apt.llvm.org fallback installs versioned names only; add plain aliases.
if [ ! -e "$TOOLBIN/clang" ]; then
  for t in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip llvm-as; do
    src="$(command -v "$t-21" || true)"
    [ -n "$src" ] && ln -sf "$src" "$TOOLBIN/$t"
  done
fi
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

if [ "$VARIANT" != "vanilla" ]; then
  step "5.4 compatibility patches"
  # include/linux/pgtable.h exists only since 5.10; on 5.4 the definitions
  # live in asm/pgtable.h. sucompat.c uses no pgtable symbols (the include
  # is vestigial there) but it is unguarded, so retarget it for this tree.
  SUCOMPAT="$KSRC/drivers/kernelsu/feature/sucompat.c"
  if grep -q '#include <linux/pgtable\.h>' "$SUCOMPAT"; then
    sed -i 's|#include <linux/pgtable\.h>|#include <asm/pgtable.h>|' "$SUCOMPAT"
    echo "patched: sucompat.c linux/pgtable.h -> asm/pgtable.h"
  fi

  # 5.4 task_work: task_work_add() takes a bool (true == TWA_RESUME);
  # the TWA_* enum only exists from 5.5. Same one-token fix in all sites
  # (pkg_observer, dynamic_manager, allowlist, supercall).
  TWA_FILES="$(grep -rl 'TWA_RESUME' "$KSRC/drivers/kernelsu" || true)"
  for f in $TWA_FILES; do
    sed -i 's/TWA_RESUME/true/g' "$f"
    echo "patched: ${f#"$KSRC"/} TWA_RESUME -> true"
  done

  # 5.4 fsnotify: struct fsnotify_ops has no .handle_inode_event (added
  # in 5.9); the single .handle_event hook carries the child name for
  # inode marks, with the same (qstr *file_name, u32 cookie) tail.
  PKGOBS="$KSRC/drivers/kernelsu/manager/pkg_observer.c"
  if grep -q 'handle_inode_event' "$PKGOBS"; then
    python3 - "$PKGOBS" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
pat_fn = re.compile(
    r"static int ksu_handle_inode_event\(struct fsnotify_mark \*mark, u32 mask, "
    r"struct inode \*inode, struct inode \*dir,\s+const struct qstr \*file_name, u32 cookie\)\n")
new_fn = (
    "/* 5.4: no .handle_inode_event in struct fsnotify_ops (added in 5.9);\n"
    " * .handle_event carries the child name for inode marks instead. */\n"
    "static int ksu_handle_event(struct fsnotify_group *group, struct inode *inode,\n"
    "\t\t\t    u32 mask, const void *data, int data_type,\n"
    "\t\t\t    const struct qstr *file_name, u32 cookie,\n"
    "\t\t\t    struct fsnotify_iter_info *iter_info)\n")
pat_op = re.compile(r"[ \t]*\.handle_inode_event = ksu_handle_inode_event,\n")
new_op = "\t.handle_event = ksu_handle_event,\n"
for pat, new in ((pat_fn, new_fn), (pat_op, new_op)):
    found = pat.findall(src)
    if len(found) != 1:
        print(f"ERROR: expected 1 match for {pat.pattern[:50]!r}, found {len(found)}", file=sys.stderr)
        sys.exit(1)
    src = pat.sub(new, src)
open(path, "w").write(src)
print("patched: pkg_observer.c handle_inode_event -> handle_event (5.4)")
PYEOF
  fi
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

if [ "$OPTS" = "smooth" ]; then
  step "apply smoothness config layer"
  "$KSRC/scripts/config" --file "$CFG" \
    --disable HZ_250 --enable HZ_1000 \
    --enable TCP_CONG_BBR --enable DEFAULT_BBR --disable DEFAULT_CUBIC
elif [ "$OPTS" = "battery" ]; then
  step "apply battery config layer (tick stays at 250 Hz)"
  "$KSRC/scripts/config" --file "$CFG" \
    --enable WQ_POWER_EFFICIENT_DEFAULT \
    --enable TCP_CONG_BBR --enable DEFAULT_BBR --disable DEFAULT_CUBIC
fi

make "${MAKE_ARGS[@]}" olddefconfig
grep -E '^CONFIG_(KSU|KPROBES|KALLSYMS_ALL|HZ|WQ_POWER_EFFICIENT_DEFAULT)=' "$CFG" || true

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
