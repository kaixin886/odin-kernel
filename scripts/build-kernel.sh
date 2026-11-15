#!/usr/bin/env bash
# odin kernel CI builder.
#
# Environment inputs:
#   VARIANT     vanilla | finasu | finasu-susfs | resukisu   (default: vanilla)
#   OPTS        off | smooth | battery            (default: off) config layer
#   FINASU_REF  FinaSU git tag to integrate       (default: v1.3.2)
#   BAKASU_REF  BakaSU (ReSukiSU) commit to integrate (default: pinned below)
#
# Outputs land in ./out : Image, .config, utsrelease.txt, SHA256SUMS.
set -euo pipefail

VARIANT="${VARIANT:-vanilla}"
OPTS="${OPTS:-off}"
FINASU_REF="${FINASU_REF:-v1.3.2}"
BAKASU_REF="${BAKASU_REF:-548d1dda060ca198823d8808804d01f5209ef4a9}"

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
if [ "$VARIANT" = "finasu-susfs" ] || [ "$VARIANT" = "resukisu" ]; then
  # Inkypen's susfs branch is lineage-24.0 + his susfs v2.1.0 import.
  KERNEL_BRANCH="susfs"
fi
FINASU_URL="https://github.com/LyraVoid/FinaSU.git"
CLANG_WANT="clang-r574158"

step() { echo; echo "===== $* ====="; }

step "inputs: VARIANT=$VARIANT OPTS=$OPTS FINASU_REF=$FINASU_REF BAKASU_REF=$BAKASU_REF"

# ---------------------------------------------------------------- deps
step "install host dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  bc bison flex libssl-dev libelf-dev libdw-dev dwarves \
  zip unzip python3 git curl wget xz-utils zstd patch \
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
# Pin the release string to exactly CONFIG_LOCALVERSION: without this the
# SCM version helper appends a '+' for the (FinaSU-extended) dirty tree and
# the kernel reports 5.4.302-inkypen-v2+ instead of 5.4.302-inkypen-v2.
: > "$KSRC/.scmversion"

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
    step "verify susfs import present in kernel tree"
    test -f "$KSRC/include/linux/susfs_def.h"
    grep -q 'SUSFS_VERSION "v2.1.0"' "$KSRC/include/linux/susfs.h"
    echo "susfs v2.1.0 import confirmed"
  fi

  step "extract manager signature from official FinaSU manager APK"
  # The unauthenticated GitHub API is rate-limited per egress IP and the
  # CI runners share theirs; several dispatches in an hour can exhaust it
  # (the 2026-11-14 19:59 run died here with "asset not found" while the
  # asset existed). Retry the lookup, and if it still fails fall back to
  # the pinned cert values for the pinned release (derived locally from
  # the official v1.3.2 manager APK and verified with
  # scripts/extract_manager_cert.py).
  KSU_SIZE=""
  KSU_HASH=""
  APK_URL=""
  for attempt in 1 2 3; do
    APK_URL="$(curl -s "https://api.github.com/repos/LyraVoid/FinaSU/releases/tags/$FINASU_REF" \
      | python3 -c 'import json,sys
rel = json.load(sys.stdin)
for a in rel.get("assets", []):
    n = a.get("name", "")
    if n.endswith("-release.apk") and "FinaSU" in n:
        print(a["browser_download_url"]); break' 2>/dev/null)"
    [ -n "$APK_URL" ] && break
    echo "manager APK lookup attempt $attempt failed; retrying in 15s"
    sleep 15
  done
  if [ -n "$APK_URL" ]; then
    curl -sL "$APK_URL" -o "$WORK/manager.apk"
    CERT_OUT="$(python3 "$ROOT/scripts/extract_manager_cert.py" "$WORK/manager.apk")"
    echo "manager cert: $CERT_OUT"
    KSU_SIZE="$(echo "$CERT_OUT" | sed -n 's/^KSU_EXPECTED_SIZE=//p')"
    KSU_HASH="$(echo "$CERT_OUT" | sed -n 's/^KSU_EXPECTED_HASH=//p')"
  fi
  if [ -z "$KSU_SIZE" ] || [ -z "$KSU_HASH" ]; then
    if [ "$FINASU_REF" = "v1.3.2" ]; then
      echo "falling back to pinned manager cert values for $FINASU_REF"
      KSU_SIZE="0x2cc"
      KSU_HASH="2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458"
    else
      echo "ERROR: failed to derive KSU_EXPECTED_SIZE / KSU_EXPECTED_HASH" >&2
      exit 1
    fi
  fi
  EXTRA_MAKE_VARS+=(KSU_EXPECTED_SIZE="$KSU_SIZE" KSU_EXPECTED_HASH="$KSU_HASH" KSU_REQUIRE_PREINIT=1)
fi


# ---------------------------------------------------------------- BakaSU
if [ "$VARIANT" = "resukisu" ]; then
  step "integrate BakaSU (ReSukiSU) $BAKASU_REF"
  # BakaSU is ReSukiSU renamed (github.com/Baka-SU/BakaSU). Its own
  # setup.sh clones the repo into ./KernelSU (its Kbuild requires the
  # .git directory to be present) and links drivers/kernelsu. Fetch
  # setup.sh at the pinned commit so the integration is reproducible.
  # No manager-cert extraction: BakaSU ships the expected certs of
  # its supported managers built in (multi-manager is the default).
  curl -fsSL "https://raw.githubusercontent.com/Baka-SU/BakaSU/$BAKASU_REF/kernel/setup.sh" \
    -o "$WORK/bakasu-setup.sh"
  ( cd "$KSRC" && bash "$WORK/bakasu-setup.sh" "$BAKASU_REF" )
  test -d "$KSRC/KernelSU/.git"
  test -e "$KSRC/fs/susfs.c"
  grep -q 'SUSFS_VERSION "v2.1.0"' "$KSRC/include/linux/susfs.h"
  echo "BakaSU integrated on susfs v2.1.0 base"

  step "wire BakaSU SUSFS inline hooks + v2.1.0 glue"
  # KSU_SUSFS is the SUSFS inline-hook configuration: the kernel side
  # must carry the seven call sites from upstream susfs's 50_add_susfs
  # patch (setresuid, execve, faccessat, stat, sys_read, sys_reboot,
  # input), adapted to this 5.4 tree's shapes - execve's
  # do_execveat_common is a one-line wrapper here, so the pre/post
  # handling folds into it, and vfs_fstat is an inline over
  # vfs_statx_fd, so the initrc size-spoof hook lands there. BakaSU's
  # own inline_hook_check.mk greps for exactly these handler names.
  # Inkypen's susfs is v2.1.0 while BakaSU tracks the latest susfs:
  # the per-task no_su family is missing, so declare it in the
  # kernel's susfs_def.h (where upstream v2.2+ declares it) and
  # define degraded stubs in BakaSU's compat layer - the same
  # collapse shape the FinaSU line used.
  python3 - \
    "$KSRC/drivers/kernelsu/compat/kernel_compat.c" \
    "$KSRC/include/linux/susfs_def.h" \
    "$KSRC/kernel/sys.c" \
    "$KSRC/fs/exec.c" \
    "$KSRC/fs/open.c" \
    "$KSRC/fs/stat.c" \
    "$KSRC/fs/read_write.c" \
    "$KSRC/kernel/reboot.c" \
    "$KSRC/drivers/input/input.c" <<'PYEOF'
import re, sys

# Line-surgery helpers: anchors are distinctive substrings; the file's own
# bytes provide context lines, so no literal-whitespace fragility.
def load(p):
    return open(p).read().splitlines(keepends=True)

def save(p, lines):
    open(p, "w").writelines(lines)

def find(lines, sub, expect=1, start=0):
    hits = [i for i in range(start, len(lines)) if sub in lines[i]]
    if len(hits) != expect:
        print(f"ERROR: anchor {sub[:60]!r}: expected {expect}, found {len(hits)}", file=sys.stderr)
        sys.exit(1)
    return hits[0] if expect == 1 else hits

def find_first(lines, sub, start=0):
    for i in range(start, len(lines)):
        if sub in lines[i]:
            return i
    print(f"ERROR: anchor {sub[:60]!r}: not found from line {start}", file=sys.stderr)
    sys.exit(1)

def insert_before(lines, idx, text):
    lines[idx:idx] = [text]

def insert_after(lines, idx, text):
    lines[idx + 1:idx + 1] = [text]

GLUE_MARKER = "bakasu-wired"

# ---------------------------------------------------------------- glue
def wire_glue(path):
    lines = load(path)
    if any(GLUE_MARKER in l for l in lines):
        print("glue: already wired")
        return
    lines.append("""
#include <linux/susfs_def.h>

/* bakasu-wired: susfs v2.1.0 glue. Inkypen's import predates the
 * per-task no_su flag family and a few v2.2+ helpers BakaSU expects
 * from the kernel-side susfs. Degraded semantics, same shape as the
 * venus 5.4 collapse: no_su never sets, the zygote_next umount mark
 * collapses onto the plain umounted mark (a static inline in
 * susfs_def.h), and the sid pre-registration calls are no-ops
 * (BakaSU's selinux layer caches sids itself). The umounted query
 * itself needs no glue: v2.1.0 already provides it as a static
 * inline in susfs_def.h. */
bool susfs_is_current_proc_no_su(void)
{
    return false;
}

void susfs_set_current_proc_no_su(void)
{
}

void susfs_clear_current_proc_no_su(void)
{
}

void susfs_set_current_proc_umounted_for_zygote_next(void)
{
    susfs_set_current_proc_umounted();
}

void susfs_set_init_sid(void)
{
}

void susfs_set_ksu_sid(void)
{
}

void susfs_set_priv_app_sid(void)
{
}
""")
    save(path, lines)
    print("glue: appended to kernel_compat.c")

# ------------------------------------------------------- susfs_def.h
def wire_susfs_def(path):
    lines = load(path)
    if any(GLUE_MARKER in l for l in lines):
        print("susfs_def.h: already wired")
        return
    lines.append("""
/* bakasu-wired: declarations for the glue above. Upstream susfs
 * v2.2+ declares the no_su family in this header; v2.1.0 predates
 * it, so declare here and define degraded stubs in the KernelSU
 * compat layer (drivers/kernelsu/compat/kernel_compat.c). */
bool susfs_is_current_proc_no_su(void);
void susfs_set_current_proc_no_su(void);
void susfs_clear_current_proc_no_su(void);
void susfs_set_current_proc_umounted_for_zygote_next(void);
""")
    save(path, lines)
    print("susfs_def.h: declarations appended")

# ---------------------------------------------------------------- sys.c
def wire_sys(path):
    lines = load(path)
    i = find(lines, "long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)")
    insert_before(lines, i, """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif

""")
    j = find(lines, "kruid = make_kuid(ns, ruid);", start=i + 4)
    insert_before(lines, j, """#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif

""")
    save(path, lines)
    print("sys.c: setresuid site wired")

# ---------------------------------------------------------------- exec.c
def wire_exec(path):
    lines = load(path)
    i = find(lines, "static int do_execveat_common(int fd, struct filename *filename,")
    insert_before(lines, i, """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_su_compat_enabled;
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
extern bool susfs_is_current_proc_no_su(void);
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
			void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
			void *envp, int *flags);
extern int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
			void *envp, int *flags, int *retval);
extern int ksu_setup_preinit_file(struct filename **filename_ptr, struct user_arg_ptr *argv_user);
extern int ksu_preinit_handle_post_execveat(int *fd, struct filename **filename_ptr,
			void *argv_user, void *envp_user,
			int *flags, int *retval, int *preinit_fd);
#endif

""")
    j = find(lines, "return __do_execve_file(fd, filename, argv, envp, flags, NULL);")
    lines[j] = """#ifdef CONFIG_KSU_SUSFS
	{
		int ksu_retval;
		bool is_su_session = false;
		bool is_ksu_preinit_session = false;
		int preinit_fd = 0;

		if (filename && !IS_ERR(filename) &&
		    likely(!susfs_is_current_proc_no_su())) {
			if (static_branch_likely(&ksu_su_compat_enabled)) {
				if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted))
					is_su_session = !ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
				else
					is_su_session = !ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
			}
			if (unlikely(current->pid == 1) && !is_su_session &&
			    (fd == AT_FDCWD || !(flags & AT_EMPTY_PATH))) {
				preinit_fd = ksu_setup_preinit_file(&filename, &argv);
				if (preinit_fd > 0)
					is_ksu_preinit_session = true;
			}
		}
		ksu_retval = __do_execve_file(fd, filename, argv, envp, flags, NULL);
		if (unlikely(is_su_session))
			(void)ksu_handle_post_execveat_sucompat(&fd, &filename, &argv, &envp, &flags, &ksu_retval);
		if (unlikely(is_ksu_preinit_session) &&
		    ksu_preinit_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &ksu_retval, &preinit_fd))
			ksu_retval = __do_execve_file(fd, filename, argv, envp, flags, NULL);
		return ksu_retval;
	}
#endif
	return __do_execve_file(fd, filename, argv, envp, flags, NULL);
"""
    save(path, lines)
    print("exec.c: execve site wired")

# ---------------------------------------------------------------- open.c
def wire_open(path):
    src = "".join(load(path))
    if "#include <linux/susfs_def.h>" not in src:
        # Inkypen's import uses SUSFS_IS_INODE_OPEN_REDIRECT_* in this
        # file but never includes the header that defines them.
        lines = src.splitlines(keepends=True)
        i = find(lines, "#include <linux/fs.h>")
        insert_after(lines, i, "#include <linux/susfs_def.h>  /* bakasu-wired: open.c uses SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK */\n")
        src = "".join(lines)
    lines = src.splitlines(keepends=True)
    i = find(lines, "long do_faccessat(int dfd, const char __user *filename, int mode)")
    insert_before(lines, i, """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_su_compat_enabled;
extern bool __ksu_is_allow_uid_for_current(uid_t uid);
extern bool susfs_is_current_proc_no_su(void);
extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
#endif

""")
    j = find_first(lines, "unsigned int lookup_flags = LOOKUP_FOLLOW;", start=i)
    insert_after(lines, j, """#ifdef CONFIG_KSU_SUSFS
	struct filename *fname = NULL;
#endif
""")
    k = find_first(lines, "res = user_path_at(dfd, filename, lookup_flags, &path);", start=j)
    # the line above must be the retry: label
    if "retry:" not in lines[k - 1]:
        print("ERROR: open.c: user_path_at not preceded by retry:", file=sys.stderr)
        sys.exit(1)
    lines[k] = """#ifdef CONFIG_KSU_SUSFS
	fname = getname_flags(filename, lookup_flags, NULL);
	if (IS_ERR(fname)) {
		res = PTR_ERR(fname);
		goto out;
	}
	if (likely(susfs_is_current_proc_no_su()))
		goto orig_flow;
	if (static_branch_likely(&ksu_su_compat_enabled)) {
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
			ksu_handle_faccessat(&dfd, &fname, &mode, NULL);
	}
orig_flow:
	res = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
	res = user_path_at(dfd, filename, lookup_flags, &path);
#endif
"""
    save(path, lines)
    print("open.c: faccessat site wired")

# ---------------------------------------------------------------- stat.c
def wire_stat(path):
    lines = load(path)
    i = find(lines, "int vfs_statx(int dfd, const char __user *filename, int flags,")
    insert_before(lines, i, """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_su_compat_enabled;
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern bool __ksu_is_allow_uid_for_current(uid_t uid);
extern bool susfs_is_current_proc_no_su(void);
extern int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);
#endif

""")
    j = find_first(lines, "unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;", start=i)
    insert_after(lines, j, """#ifdef CONFIG_KSU_SUSFS
	struct filename *fname = NULL;
#endif
""")
    k = find_first(lines, "error = user_path_at(dfd, filename, lookup_flags, &path);", start=j)
    if "retry:" not in lines[k - 1]:
        print("ERROR: stat.c: user_path_at not preceded by retry:", file=sys.stderr)
        sys.exit(1)
    lines[k] = """#ifdef CONFIG_KSU_SUSFS
	fname = getname_flags(filename, lookup_flags, NULL);
	if (IS_ERR(fname)) {
		error = PTR_ERR(fname);
		goto out;
	}
	if (likely(susfs_is_current_proc_no_su()))
		goto orig_flow;
	if (static_branch_likely(&ksu_su_compat_enabled)) {
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
			ksu_handle_stat(&dfd, &fname, &flags);
	}
orig_flow:
	error = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
	error = user_path_at(dfd, filename, lookup_flags, &path);
#endif
"""
    # vfs_statx_fd: initrc size spoof companion hook
    m = find(lines, "error = vfs_getattr(&f.file->f_path, stat,")
    insert_after(lines, m + 1, """#ifdef CONFIG_KSU_SUSFS
		if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
			ksu_handle_vfs_fstat(fd, &stat->size);
#endif
""")
    save(path, lines)
    print("stat.c: stat + vfs_fstat sites wired")

# ---------------------------------------------------------------- read_write.c
def wire_read_write(path):
    lines = load(path)
    i = find(lines, "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)")
    insert_before(lines, i, """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif

""")
    j = find(lines, "return ksys_read(fd, buf, count);", start=i)
    insert_before(lines, j, """#ifdef CONFIG_KSU_SUSFS
	if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
		ksu_handle_sys_read(fd, &buf, &count);
#endif
""")
    save(path, lines)
    print("read_write.c: sys_read site wired")

# ---------------------------------------------------------------- reboot.c
def wire_reboot(path):
    lines = load(path)
    i = find(lines, "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,")
    insert_before(lines, i, """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif

""")
    j = find(lines, "int ret = 0;", start=i)
    insert_after(lines, j, """
#ifdef CONFIG_KSU_SUSFS
	ret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
	if (ret) {
		goto orig_flow;
	}
	return ret;
orig_flow:
#endif
""")
    save(path, lines)
    print("reboot.c: sys_reboot site wired")

# ---------------------------------------------------------------- input.c
def wire_input(path):
    lines = load(path)
    i = find(lines, "static void input_handle_event(struct input_dev *dev,")
    insert_before(lines, i, """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_is_input_hook_enabled;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif

""")
    j = find(lines, "int disposition = input_get_disposition(dev, type, code, &value);", start=i)
    insert_after(lines, j, """
#ifdef CONFIG_KSU_SUSFS
	if (static_branch_unlikely(&ksu_is_input_hook_enabled))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif
""")
    save(path, lines)
    print("input.c: input site wired")

if __name__ == "__main__":
    glue, susfs_def, sys_c, exec_c, open_c, stat_c, rw_c, reboot_c, input_c = sys.argv[1:10]
    wire_glue(glue)
    wire_susfs_def(susfs_def)
    wire_sys(sys_c)
    wire_exec(exec_c)
    wire_open(open_c)
    wire_stat(stat_c)
    wire_read_write(rw_c)
    wire_reboot(reboot_c)
    wire_input(input_c)
    print("all sites wired")
PYEOF

  step "export do_mount for BakaSU 5.4 compat"
  # BakaSU's <5.9 path_mount() fallback (compat/kernel_compat.c) calls
  # do_mount() directly; fs/namespace.c does not export it on 5.4.
  # (Its path_umount() fallback goes through the syscall table, so
  # ksys_umount needs no export.)
  NS_C="$KSRC/fs/namespace.c"
  if ! grep -q 'EXPORT_SYMBOL(do_mount)' "$NS_C"; then
    python3 - "$NS_C" <<'PYEOF2'
import sys
path = sys.argv[1]
src = open(path).read()
idx = src.find("long do_mount(const char *dev_name, const char __user *dir_name,")
if idx < 0:
    print("ERROR: namespace.c: do_mount definition not found", file=sys.stderr)
    sys.exit(1)
end = src.find("\n}\n", idx)
if end < 0:
    print("ERROR: namespace.c: end of do_mount definition not found", file=sys.stderr)
    sys.exit(1)
end += len("\n}\n")
src = src[:end] + "EXPORT_SYMBOL(do_mount);\n" + src[end:]
open(path, "w").write(src)
print("patched: fs/namespace.c EXPORT_SYMBOL(do_mount) for BakaSU")
PYEOF2
  fi
fi

if [ "$VARIANT" = "finasu" ] || [ "$VARIANT" = "finasu-susfs" ]; then
  step "5.4 compatibility patches"
  # include/linux/pgtable.h exists only since 5.10; on 5.4 the definitions
  # live in asm/pgtable.h. sucompat.c uses no pgtable symbols (the include
  # is vestigial there) but it is unguarded, so retarget it for this tree.
  SUCOMPAT="$KSRC/drivers/kernelsu/feature/sucompat.c"
  if grep -q '#include <linux/pgtable\.h>' "$SUCOMPAT"; then
    sed -i 's|#include <linux/pgtable\.h>|#include <asm/pgtable.h>|' "$SUCOMPAT"
    echo "patched: sucompat.c linux/pgtable.h -> asm/pgtable.h"
  fi

  # include/linux/minmax.h exists only since 6.2; on 5.4 min/max/min_t/
  # max_t live in <linux/kernel.h>. #12 died in sulog/event.c, which
  # uses only min() and min_t() — retarget the include in every
  # FinaSU file that has it (this checkout: only sulog/event.c).
  for f in $(grep -rl '#include <linux/minmax\.h>' "$KSRC/drivers/kernelsu" || true); do
    sed -i 's|#include <linux/minmax\.h>|#include <linux/kernel.h>|' "$f"
    echo "patched: ${f#"$KSRC"/} linux/minmax.h -> linux/kernel.h (5.4)"
  done

  # 5.4 task_work: task_work_add() takes a bool (true == TWA_RESUME);
  # the TWA_* enum only exists from 5.5. Same one-token fix in all sites
  # (pkg_observer, dynamic_manager, allowlist, supercall).
  TWA_FILES="$(grep -rl 'TWA_RESUME' "$KSRC/drivers/kernelsu" || true)"
  for f in $TWA_FILES; do
    sed -i 's/TWA_RESUME/true/g' "$f"
    echo "patched: ${f#"$KSRC"/} TWA_RESUME -> true"
  done

  # 5.4 task_struct refcounting: get_task_struct()/put_task_struct() live
  # in <linux/sched/task.h> here; on 5.10+ they are reachable via
  # <linux/sched.h> alone. Any FinaSU file that calls them without
  # including sched/task.h gets an implicit declaration, which -Werror
  # turns into a build failure. #6 hit dynamic_manager.c, #7 hit
  # policy/allowlist.c — sweep every caller instead of patching one
  # file at a time (files that already include it are left alone).
  for f in $(grep -rlE 'get_task_struct|put_task_struct' "$KSRC/drivers/kernelsu" --include='*.c' || true); do
    if ! grep -q '#include <linux/sched/task\.h>' "$f"; then
      if grep -q '#include <linux/sched\.h>' "$f"; then
        sed -i 's|#include <linux/sched\.h>|&\n#include <linux/sched/task.h>|' "$f"
      else
        sed -i '0,/^#include .*/s//&\n#include <linux\/sched\/task.h>/' "$f"
      fi
      echo "patched: ${f#"$KSRC"/} + linux/sched/task.h (5.4 put/get_task_struct)"
    fi
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

  # 5.4-5.9 have no struct selinux_policy (it arrived in 5.10): the
  # policydb/sidtab/latest_granting live directly in struct selinux_ss,
  # and selinux_state has no .policy pointer or .policy_mutex. #8 died
  # in drivers/kernelsu/selinux/rules.c on exactly that. Provide a shim
  # struct plus 5.4 install paths that mirror security_load_policy()'s
  # own swap (policydb struct copy under the ss policy_rwlock write
  # lock). The status page/lock moved out of selinux_ss a step
  # earlier, in 5.7, so that retarget is guarded separately.
  SEPOLICY_H="$KSRC/drivers/kernelsu/selinux/sepolicy.h"
  RULES_C="$KSRC/drivers/kernelsu/selinux/rules.c"
  HIDE_C="$KSRC/drivers/kernelsu/feature/selinux_hide.c"

  if ! grep -q 'Mirror the 5.10+ layout' "$SEPOLICY_H"; then
    python3 - "$SEPOLICY_H" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
if src.count("#endif") != 1:
    print("ERROR: sepolicy.h: expected exactly 1 #endif", file=sys.stderr)
    sys.exit(1)
shim = '''#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
/* 5.4-5.9 have no struct selinux_policy (it arrived in 5.10): the
 * policydb, sidtab and latest_granting live directly in struct
 * selinux_ss, and selinux_state has no .policy pointer or .policy_mutex.
 * Mirror the 5.10+ layout so ksu_dup_sepolicy() and the rule code keep
 * working on a stack-built view of the live policy. */
struct selinux_policy {
    struct sidtab *sidtab;
    struct policydb policydb;
    u32 latest_granting;
};
#endif

#endif'''
src = src.replace("#endif", shim, 1)
open(path, "w").write(src)
print("patched: sepolicy.h + struct selinux_policy shim (5.4-5.9)")
PYEOF
  fi

  if ! grep -q '5.4-5.9: no selinux_state.policy' "$RULES_C"; then
    python3 - "$RULES_C" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

def rep(old, new, expect=1):
    global src
    n = src.count(old)
    if n != expect:
        print(f"ERROR: rules.c: expected {expect} match, found {n} for {old[:60]!r}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new)

rep('''    struct selinux_policy *pol, *old_pol;
    struct policydb *db;

    if (!getenforce()) {''',
'''    struct selinux_policy *pol, *old_pol;
    struct policydb *db;
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
    /* 5.4-5.9: the live policy has no heap object; snapshot it here. */
    struct selinux_policy live_view;
#endif

    if (!getenforce()) {''')

rep('''    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    backup_sepolicy = ksu_dup_sepolicy(old_pol);''',
'''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
#else
    /* 5.4-5.9: no selinux_state.policy/policy_mutex. Snapshot the live
     * policy (plain struct copy, no allocation) under the ss write
     * lock, then dup/modify the snapshot outside the lock. A policy
     * reload racing this window would free the snapshotted tables, but
     * nothing reloads policy after boot on Android. */
    write_lock_irq(&selinux_state.ss->policy_rwlock);
    live_view.sidtab = selinux_state.ss->sidtab;
    live_view.latest_granting = selinux_state.ss->latest_granting;
    memcpy(&live_view.policydb, &selinux_state.ss->policydb, sizeof(live_view.policydb));
    write_unlock_irq(&selinux_state.ss->policy_rwlock);
    old_pol = &live_view;
#endif
    backup_sepolicy = ksu_dup_sepolicy(old_pol);''')

rep('''    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);

    reset_avc_cache();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
out_unlock:
    mutex_unlock(&selinux_state.policy_mutex);
}''',
'''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);
#else
    /* Install like security_load_policy(): struct-copy the new policydb
     * over the live one under the ss write lock, then destroy the old
     * tables (still referenced by the snapshot) after the swap. Free
     * only the new pol struct shell: its tables are now live, and the
     * sidtab pointer is unchanged (the dup aliases it). */
    write_lock_irq(&selinux_state.ss->policy_rwlock);
    memcpy(&selinux_state.ss->policydb, &pol->policydb, sizeof(selinux_state.ss->policydb));
    selinux_state.ss->latest_granting++;
    write_unlock_irq(&selinux_state.ss->policy_rwlock);
    policydb_destroy(&live_view.policydb);
    kfree(pol);
#endif

    reset_avc_cache();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
out_unlock:
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    mutex_unlock(&selinux_state.policy_mutex);
#endif
}''')

rep('''    struct selinux_policy *pol, *old_pol;
    struct policydb *db;
    struct sepol_batch_cursor cursor;''',
'''    struct selinux_policy *pol, *old_pol;
    struct policydb *db;
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
    /* 5.4-5.9: the live policy has no heap object; snapshot it here. */
    struct selinux_policy live_view;
#endif
    struct sepol_batch_cursor cursor;''')

rep('''    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    pol = ksu_dup_sepolicy(old_pol);''',
'''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
#else
    /* 5.4-5.9: no selinux_state.policy/policy_mutex; see apply_kernelsu_rules(). */
    write_lock_irq(&selinux_state.ss->policy_rwlock);
    live_view.sidtab = selinux_state.ss->sidtab;
    live_view.latest_granting = selinux_state.ss->latest_granting;
    memcpy(&live_view.policydb, &selinux_state.ss->policydb, sizeof(live_view.policydb));
    write_unlock_irq(&selinux_state.ss->policy_rwlock);
    old_pol = &live_view;
#endif
    pol = ksu_dup_sepolicy(old_pol);''')

rep('''    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);

    reset_avc_cache();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    ret = success_cmd_count;
    goto out_unlock;

out_drop_new_policy:
    ksu_destroy_sepolicy(pol);
out_unlock:
    mutex_unlock(&selinux_state.policy_mutex);''',
'''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);
#else
    /* Install like security_load_policy(); see apply_kernelsu_rules(). */
    write_lock_irq(&selinux_state.ss->policy_rwlock);
    memcpy(&selinux_state.ss->policydb, &pol->policydb, sizeof(selinux_state.ss->policydb));
    selinux_state.ss->latest_granting++;
    write_unlock_irq(&selinux_state.ss->policy_rwlock);
    policydb_destroy(&live_view.policydb);
    kfree(pol);
#endif

    reset_avc_cache();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    ret = success_cmd_count;
    goto out_unlock;

out_drop_new_policy:
    ksu_destroy_sepolicy(pol);
out_unlock:
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    mutex_unlock(&selinux_state.policy_mutex);
#endif''')

open(path, "w").write(src)
print("patched: rules.c selinux_state.policy -> 5.4 ss snapshot/swap (x2)")
PYEOF
  fi

  if ! grep -q '#include <linux/spinlock.h>' "$RULES_C"; then
    sed -i 's|#include <linux/lockdep.h>|&\n#include <linux/spinlock.h>|' "$RULES_C"
    echo "patched: rules.c + linux/spinlock.h (write_lock_irq)"
  fi

  if ! grep -q 'ksu_selinux_status_lock' "$HIDE_C"; then
    python3 - "$HIDE_C" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

def rep(old, new, expect=1):
    global src
    n = src.count(old)
    if n != expect:
        print(f"ERROR: selinux_hide.c: expected {expect} match, found {n} for {old[:60]!r}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new)

rep('''#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
#define ksu_task_security_struct task_security_struct
#else
#define ksu_task_security_struct cred_security_struct
#endif''',
'''#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
#define ksu_task_security_struct task_security_struct
#else
#define ksu_task_security_struct cred_security_struct
#endif

/* 5.4-5.6 keep the SELinux status page/lock in struct selinux_ss; 5.7+
 * moved them into struct selinux_state. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
#define ksu_selinux_status_lock (&selinux_state.status_lock)
#define ksu_selinux_status_page (selinux_state.status_page)
#else
#define ksu_selinux_status_lock (&selinux_state.ss->status_lock)
#define ksu_selinux_status_page (selinux_state.ss->status_page)
#endif''')

rep("mutex_lock(&selinux_state.status_lock);",
    "mutex_lock(ksu_selinux_status_lock);", expect=2)
rep("mutex_unlock(&selinux_state.status_lock);",
    "mutex_unlock(ksu_selinux_status_lock);", expect=2)
rep("if (!selinux_state.status_page) {",
    "if (!ksu_selinux_status_page) {")
rep("struct selinux_kernel_status *status = page_address(selinux_state.status_page);",
    "struct selinux_kernel_status *status = page_address(ksu_selinux_status_page);")

rep('''    struct selinux_policy *orig_policy;''',
'''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    struct selinux_policy *orig_policy;
#endif''')

rep('''    orig_policy = rcu_dereference(selinux_state.policy);
    orig_policydb = &orig_policy->policydb;
    orig_sidtab = orig_policy->sidtab;''',
'''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    orig_policy = rcu_dereference(selinux_state.policy);
    orig_policydb = &orig_policy->policydb;
    orig_sidtab = orig_policy->sidtab;
#else
    /* 5.4-5.9: no selinux_state.policy; the live policy is selinux_state.ss. */
    orig_policydb = &selinux_state.ss->policydb;
    orig_sidtab = selinux_state.ss->sidtab;
#endif''')

open(path, "w").write(src)
print("patched: selinux_hide.c status page/lock + live policy -> 5.4 ss")
PYEOF
  fi

  if ! grep -q 'ksu54: <6.1 sidtab port' "$HIDE_C"; then
    python3 - "$HIDE_C" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

def rep(old, new, expect=1):
    global src
    n = src.count(old)
    if n != expect:
        print(f"ERROR: selinux_hide.c sidtab port: expected {expect} match, found {n} for {old[:60]!r}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new)

rep('''#include "ss/policydb.h"''',
'''#include "ss/policydb.h"
#include "ss/hashtab.h"''')

rep('''#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
#define ksu_task_security_struct task_security_struct
#else
#define ksu_task_security_struct cred_security_struct
#endif''',
'''#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
#define ksu_task_security_struct task_security_struct
#else
#define ksu_task_security_struct cred_security_struct
#endif

/* <5.9 has no symtab_search(); the policydb symtabs are hashtab-backed.
 * Same shim FinaSU itself uses in selinux/sepolicy.c. */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
#define symtab_search(s, name) hashtab_search((s)->table, name)
#endif''')

rep('''static int sidtab_entry_to_string(struct policydb *p, struct sidtab *sidtab, struct sidtab_entry *entry,''',
'''#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
static int sidtab_entry_to_string(struct policydb *p, struct sidtab *sidtab, struct sidtab_entry *entry,''')

rep('''static int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext,
                                               u32 *scontext_len)
{
    struct policydb *policydb;
    struct sidtab *sidtab;
    struct sidtab_entry *entry;
    int rc = 0;

    if (scontext)
        *scontext = NULL;
    *scontext_len = 0;

    // removed: if (!selinux_initialized())
    // removed: rcu lock
    policydb = &policy->policydb;
    sidtab = policy->sidtab;

    // removed: force
    entry = sidtab_search_entry(sidtab, sid);
    if (!entry) {
        pr_err("SELinux: %s:  unrecognized SID %d\\n", __func__, sid);
        rc = -EINVAL;
        goto out_unlock;
    }
    // removed: only_invalid

    rc = sidtab_entry_to_string(policydb, sidtab, entry, scontext, scontext_len);

out_unlock:
    return rc;
}''',
'''static int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext,
                                               u32 *scontext_len)
{
    struct policydb *policydb;
    struct sidtab *sidtab;
    struct sidtab_entry *entry;
    int rc = 0;

    if (scontext)
        *scontext = NULL;
    *scontext_len = 0;

    // removed: if (!selinux_initialized())
    // removed: rcu lock
    policydb = &policy->policydb;
    sidtab = policy->sidtab;

    // removed: force
    entry = sidtab_search_entry(sidtab, sid);
    if (!entry) {
        pr_err("SELinux: %s:  unrecognized SID %d\\n", __func__, sid);
        rc = -EINVAL;
        goto out_unlock;
    }
    // removed: only_invalid

    rc = sidtab_entry_to_string(policydb, sidtab, entry, scontext, scontext_len);

out_unlock:
    return rc;
}
#else
/* ksu54: <6.1 sidtab port - this sidtab has no sidtab_entry and no
 * sid->string cache; sidtab_search() returns the context directly. */
static int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext,
                                               u32 *scontext_len)
{
    struct policydb *policydb;
    struct sidtab *sidtab;
    struct context *context;
    int rc = 0;

    if (scontext)
        *scontext = NULL;
    *scontext_len = 0;

    policydb = &policy->policydb;
    sidtab = policy->sidtab;

    context = sidtab_search(sidtab, sid);
    if (!context) {
        pr_err("SELinux: %s:  unrecognized SID %d\\n", __func__, sid);
        rc = -EINVAL;
        goto out_unlock;
    }

    rc = context_struct_to_string(policydb, context, scontext, scontext_len);

out_unlock:
    return rc;
}
#endif''')

open(path, "w").write(src)
print("patched: selinux_hide.c symtab_search shim + <6.1 sidtab port")
PYEOF
  fi

  # sepolicy.c add_filename_trans targets the 5.10 filename_trans layout
  # (filename_trans_key + stypes-bitmap datum). On 5.4 the table is keyed by
  # (stype, ttype, tclass, name) and the datum is a bare otype, so swap in
  # the 5.4 implementation shipped in patches/ for < 5.10.
  if [ -f "$ROOT/patches/sepolicy-filename-trans-5.4.patch" ]; then
    # drivers/kernelsu is a symlink into the FinaSU clone, and GNU patch
    # refuses to patch a file beyond a symbolic link (it asks "File to
    # patch:" and skips every hunk). Resolve the real directory, rebase
    # the patch header prefix onto it, and verify the guard landed.
    KSU_REAL="$(readlink -f "$KSRC/drivers/kernelsu")"
    sed -e 's|^--- a/drivers/kernelsu/|--- a/|' \
        -e 's|^+++ b/drivers/kernelsu/|+++ b/|' \
        "$ROOT/patches/sepolicy-filename-trans-5.4.patch" \
        > "$WORK/sepolicy-filename-trans-5.4.rebased.patch"
    patch -d "$KSU_REAL" -p1 -s --batch --no-backup-if-mismatch \
      < "$WORK/sepolicy-filename-trans-5.4.rebased.patch"
    grep -q 'KERNEL_VERSION(5, 10, 0)' \
      "$KSRC/drivers/kernelsu/selinux/sepolicy.c"
    echo "patched: sepolicy.c add_filename_trans -> 5.4 port"
  fi

  # <linux/minmax.h> was split out of <linux/kernel.h> in 6.5; on 5.4 the
  # min/max/clamp family still lives in <linux/kernel.h>. #12 died on
  # sulog/event.c (min_t/min) including it — sweep every includer.
  for f in $(grep -rl '#include <linux/minmax\.h>' "$KSRC/drivers/kernelsu" --include='*.c' --include='*.h' || true); do
    sed -i 's|#include <linux/minmax\.h>|#include <linux/kernel.h>|' "$f"
    echo "patched: ${f#"$KSRC"/} linux/minmax.h -> linux/kernel.h (5.4)"
  done

  # 5.4: tasklist_lock and init_task are declared in <linux/sched/task.h>,
  # task_pgrp()/task_session() in <linux/sched/signal.h>; newer kernels
  # surface both transitively, 5.4 does not. #13 died in supercall/
  # dispatch.c (do_set_init_pgrp) — sweep every file that uses these
  # symbols without the matching include.
  for f in $(grep -rlE 'tasklist_lock|&init_task' "$KSRC/drivers/kernelsu" --include='*.c' || true); do
    if ! grep -q '#include <linux/sched/task\.h>' "$f"; then
      if grep -q '#include <linux/sched\.h>' "$f"; then
        sed -i 's|#include <linux/sched\.h>|&\n#include <linux/sched/task.h>|' "$f"
      else
        sed -i '0,/^#include .*/s//&\n#include <linux\/sched\/task.h>/' "$f"
      fi
      echo "patched: ${f#"$KSRC"/} + linux/sched/task.h (5.4 tasklist_lock/init_task)"
    fi
  done
  for f in $(grep -rlE 'task_pgrp\(|task_session\(' "$KSRC/drivers/kernelsu" --include='*.c' || true); do
    if ! grep -q '#include <linux/sched/signal\.h>' "$f"; then
      if grep -q '#include <linux/sched\.h>' "$f"; then
        sed -i 's|#include <linux/sched\.h>|&\n#include <linux/sched/signal.h>|' "$f"
      else
        sed -i '0,/^#include .*/s//&\n#include <linux\/sched\/signal.h>/' "$f"
      fi
      echo "patched: ${f#"$KSRC"/} + linux/sched/signal.h (5.4 task_pgrp/task_session)"
    fi
  done

  # Link stage: FinaSU calls path_mount()/path_umount() (5.8+). On 5.4 the
  # equivalents are do_mount()/ksys_umount() in fs/namespace.c - unexported,
  # and string-based, so the two FinaSU call sites convert struct path via
  # d_path() under KERNEL_DS. Same retarget the venus 5.4 builds use.
  # #15 died at LD .tmp_vmlinux.kallsyms1 on exactly these two symbols.
  NS_C="$KSRC/fs/namespace.c"
  if ! grep -q 'EXPORT_SYMBOL(do_mount)' "$NS_C"; then
    python3 - "$NS_C" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

def export_after(sig, sym):
    global src
    idx = src.find(sig)
    if idx < 0:
        print(f"ERROR: namespace.c: definition not found for {sym}: {sig[:50]!r}", file=sys.stderr)
        sys.exit(1)
    end = src.find("\n}\n", idx)
    if end < 0:
        print(f"ERROR: namespace.c: end of {sym} definition not found", file=sys.stderr)
        sys.exit(1)
    end += len("\n}\n")
    src = src[:end] + f"EXPORT_SYMBOL({sym});\n" + src[end:]

export_after("long do_mount(const char *dev_name, const char __user *dir_name,", "do_mount")
export_after("int ksys_umount(char __user *name, int flags)", "ksys_umount")

open(path, "w").write(src)
print("patched: fs/namespace.c EXPORT_SYMBOL(do_mount/ksys_umount) for KSU")
PYEOF
  fi

  SMN_C="$KSRC/drivers/kernelsu/infra/su_mount_ns.c"
  if ! grep -q '5.4 has no path_mount' "$SMN_C"; then
    if ! grep -q '#include <linux/uaccess.h>' "$SMN_C"; then
      sed -i 's|#include <linux/fs.h>|&\n#include <linux/uaccess.h>|' "$SMN_C"
    fi
    python3 - "$SMN_C" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

def rep(old, new, expect=1):
    global src
    n = src.count(old)
    if n != expect:
        print(f"ERROR: su_mount_ns.c: expected {expect} match, found {n} for {old[:60]!r}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new)

rep('''extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,
                      void *data_page);''',
'''/* 5.4 has no path_mount(); do_mount() takes a __user dir_name instead. */
extern long do_mount(const char *dev_name, const char __user *dir_name,
                     const char *type_page, unsigned long flags,
                     void *data_page);''')

rep('''    int pm_ret = path_mount(NULL, &root_path, NULL, MS_PRIVATE | MS_REC, NULL);''',
'''    int pm_ret;
    {
        char *dir = kmalloc(PATH_MAX, GFP_KERNEL);

        if (dir) {
            char *p2 = d_path(&root_path, dir, PATH_MAX);

            if (!IS_ERR(p2)) {
                mm_segment_t oldfs = get_fs();

                set_fs(KERNEL_DS);
                pm_ret = (int)do_mount(NULL, (const char __user *)p2, NULL, MS_PRIVATE | MS_REC, NULL);
                set_fs(oldfs);
            } else {
                pm_ret = (int)PTR_ERR(p2);
            }
            kfree(dir);
        } else {
            pm_ret = -ENOMEM;
        }
    }''')

open(path, "w").write(src)
print("patched: su_mount_ns.c path_mount -> do_mount (5.4)")
PYEOF
  fi

  KUM_C="$KSRC/drivers/kernelsu/feature/kernel_umount.c"
  if ! grep -q '5.4 has no path_umount' "$KUM_C"; then
    if ! grep -q '#include <linux/uaccess.h>' "$KUM_C"; then
      sed -i 's|#include <linux/fs.h>|&\n#include <linux/uaccess.h>|' "$KUM_C"
    fi
    python3 - "$KUM_C" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

def rep(old, new, expect=1):
    global src
    n = src.count(old)
    if n != expect:
        print(f"ERROR: kernel_umount.c: expected {expect} match, found {n} for {old[:60]!r}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new)

rep('''extern int path_umount(struct path *path, int flags);''',
'''/* 5.4 has no path_umount(); ksys_umount() takes a path string. */
extern int ksys_umount(char __user *name, int flags);''')

rep('''static void ksu_umount_mnt(struct path *path, int flags)
{
    int err = path_umount(path, flags);''',
'''static void ksu_umount_mnt(struct path *path, int flags)
{
    int err;
    char *dir = kmalloc(PATH_MAX, GFP_KERNEL);

    if (!dir)
        return;
    {
        char *p2 = d_path(path, dir, PATH_MAX);

        if (!IS_ERR(p2)) {
            mm_segment_t oldfs = get_fs();

            set_fs(KERNEL_DS);
            err = ksys_umount((char __user *)p2, flags);
            set_fs(oldfs);
        } else {
            err = (int)PTR_ERR(p2);
        }
    }
    kfree(dir);''')

open(path, "w").write(src)
print("patched: kernel_umount.c path_umount -> ksys_umount (5.4)")
PYEOF
  fi

  if [ "$VARIANT" = "finasu" ]; then
  # BISECT history (diagnostic, 2026-11-14): vanilla BOOTED; finasu
  # full HUNG. BISECT1 (cluster off) BOOTED. BISECT2 (syscall pair
  # on) HUNG. BISECT3 (dispatcher only) BOOTED. BISECT4 (tp skipped)
  # BOOTED. BISECT5 (kretprobes off, tp on) HUNG. BISECT6 (no hooks)
  # BOOTED. BISECT7 (preinit off, hooks on) HUNG. BISECT8 (execve
  # hooks off) HUNG. BISECT9 (only newfstatat+faccessat hooks left)
  # HUNG. So even the thinnest pass-through pair kills boot.
  # Code review found what those two hooks run on EVERY call at
  # boot: ksu_is_allow_uid_for_current -> is_ksu_domain ->
  # is_sid_match, whose slow path (cached_su_sid==0 until the
  # second_stage cache_sid() runs, which needs the execve hook)
  # calls __security_secid_to_secctx() - a SELinux sidtab-to-string
  # conversion - for every single stat/access from every root
  # process, starting in first-stage init while the policy is
  # still loading.
  # BISECT10: bisect9 config, but the two bridge hooks are reduced
  # to pure pass-through (orig called immediately, sucompat logic
  # skipped). Boots -> the sucompat handler logic (the gate slow
  # path) is the poison and gets a proper fix. Hangs -> the
  # redirect machinery itself is broken under high-frequency
  # syscalls and the fight moves to handler/dispatcher deltas.
  INIT_C="$KSRC/drivers/kernelsu/core/init.c"
  MGR_C="$KSRC/drivers/kernelsu/hook/syscall_hook_manager.c"
  PRE_C="$KSRC/drivers/kernelsu/preinit/preinit.c"
  BRG_C="$KSRC/drivers/kernelsu/hook/syscall_event_bridge.c"
  if ! grep -q 'bisect10-off' "$INIT_C"; then
    python3 - "$INIT_C" "$MGR_C" "$PRE_C" "$BRG_C" <<'PYEOF'
import sys
init_path, mgr_path, pre_path, brg_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def rep(src, old, new, expect=1):
    n = src.count(old)
    if n != expect:
        print(f"ERROR: expected {expect} match, found {n} for {old[:50]!r}", file=sys.stderr)
        sys.exit(1)
    return src.replace(old, new)

src = open(init_path).read()
src = rep(src, "    ksu_selinux_hide_init();",
    "    /* bisect10-off: ksu_selinux_hide_init(); */")
src = rep(src, "    ksu_avc_spoof_init();",
    "    /* bisect10-off: ksu_avc_spoof_init(); */")
open(init_path, "w").write(src)

src = open(mgr_path).read()
src = rep(src, '    syscall_regfunc_rp = init_kretprobe("syscall_regfunc", syscall_regfunc_handler);',
    "    syscall_regfunc_rp = NULL; /* bisect10-off: kretprobe pair not registered */")
src = rep(src, '    syscall_unregfunc_rp = init_kretprobe("syscall_unregfunc", syscall_unregfunc_handler);',
    "    syscall_unregfunc_rp = NULL; /* bisect10-off: kretprobe pair not registered */")
src = rep(src, "    ksu_register_syscall_hook(__NR_execve, ksu_hook_execve);",
    "    /* bisect10-off: ksu_register_syscall_hook(__NR_execve, ksu_hook_execve); */")
src = rep(src, "    ksu_register_syscall_hook(__NR_execveat, ksu_hook_execveat);",
    "    /* bisect10-off: ksu_register_syscall_hook(__NR_execveat, ksu_hook_execveat); */")
src = rep(src, "    ksu_register_syscall_hook(__NR_setresuid, ksu_hook_setresuid);",
    "    /* bisect10-off: ksu_register_syscall_hook(__NR_setresuid, ksu_hook_setresuid); */")
open(mgr_path, "w").write(src)

src = open(pre_path).read()
old_sig = """bool ksu_preinit_handle_execve(const char __user **filename_user, const char __user *const __user *argv_user,
                               int orig_nr, struct pt_regs *regs, long *ret)
{"""
new_sig = """bool ksu_preinit_handle_execve(const char __user **filename_user, const char __user *const __user *argv_user,
                               int orig_nr, struct pt_regs *regs, long *ret)
{
    return false; /* bisect10-off: preinit runner swap disabled */"""
src = rep(src, old_sig, new_sig)
open(pre_path, "w").write(src)

src = open(brg_path).read()
old_stat = """long __nocfi ksu_hook_newfstatat(int orig_nr, const struct pt_regs *regs)
{
    if (!ksu_su_compat_is_enabled())
        return ksu_syscall_table[orig_nr](regs);

    return ksu_handle_stat_sucompat(orig_nr, (struct pt_regs *)regs);
}"""
new_stat = """long __nocfi ksu_hook_newfstatat(int orig_nr, const struct pt_regs *regs)
{
    /* bisect10-off: pure pass-through, sucompat logic skipped */
    return ksu_syscall_table[orig_nr](regs);
}"""
src = rep(src, old_stat, new_stat)
old_acc = """long __nocfi ksu_hook_faccessat(int orig_nr, const struct pt_regs *regs)
{
    if (!ksu_su_compat_is_enabled())
        return ksu_syscall_table[orig_nr](regs);

    return ksu_handle_faccessat_sucompat(orig_nr, (struct pt_regs *)regs);
}"""
new_acc = """long __nocfi ksu_hook_faccessat(int orig_nr, const struct pt_regs *regs)
{
    /* bisect10-off: pure pass-through, sucompat logic skipped */
    return ksu_syscall_table[orig_nr](regs);
}"""
src = rep(src, old_acc, new_acc)
open(brg_path, "w").write(src)
print("patched: bisect10 - stat/access hooks are pure pass-through")
PYEOF
  fi
  elif [ "$VARIANT" = "finasu-susfs" ]; then
  # SUSFS wiring (phase 3, 2026-11-15): after ten bisects the tp
  # redirect itself is the blocker on this tree - any build where a
  # syscall is actually redirected dies at the Mi logo, including a
  # pure pass-through hook (bisect10) - so the tp line is parked and
  # the SUSFS configuration goes first; it is also the configuration
  # with working 5.4 references (venus port, Neko kernel). Kept from
  # the bisect campaign: preinit runner swap off (venus diagnostic
  # builds force the same) and the tp_marker kretprobe pair off.
  # The susfs v2.1.0 kernel side lacks the per-task no_su flag family
  # FinaSU's glue expects from v2.2+; supply prototypes in the
  # kernel's susfs_def.h and degraded definitions in extension/
  # susfs.c: no_su never sets, and the zygote_next umount mark
  # collapses onto the plain umounted mark (the venus 5.4 collapse).
  SUS_DEF="$KSRC/include/linux/susfs_def.h"
  EXT_C="$KSRC/drivers/kernelsu/extension/susfs.c"
  PRE_C="$KSRC/drivers/kernelsu/preinit/preinit.c"
  MGR_C="$KSRC/drivers/kernelsu/hook/syscall_hook_manager.c"
  OPEN_C="$KSRC/fs/open.c"
  INIT_C="$KSRC/drivers/kernelsu/core/init.c"
  SYS_C="$KSRC/kernel/sys.c"
  EXEC_C="$KSRC/fs/exec.c"
  if ! grep -q 'susfs-wired' "$EXT_C"; then
    python3 - "$SUS_DEF" "$EXT_C" "$PRE_C" "$MGR_C" "$OPEN_C" "$INIT_C" "$SYS_C" "$EXEC_C" <<'PYEOF'
import sys
def_path, ext_path, pre_path, mgr_path, open_path, init_path, sys_path, exec_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]

def rep(src, old, new, expect=1):
    n = src.count(old)
    if n != expect:
        print(f"ERROR: expected {expect} match, found {n} for {old[:50]!r}", file=sys.stderr)
        sys.exit(1)
    return src.replace(old, new)

src = open(def_path).read()
src += """
/* odin-5.4 glue (susfs-wired): v2.1.0 lacks the no_su flag family */
bool susfs_is_current_proc_no_su(void);
void susfs_set_current_proc_no_su(void);
void susfs_set_current_proc_umounted_for_zygote_next(void);
"""
open(def_path, "w").write(src)

src = open(ext_path).read()
src += """
/* odin-5.4 glue (susfs-wired): degraded no_su family for susfs v2.1.0 */
bool susfs_is_current_proc_no_su(void)
{
    return false;
}

void susfs_set_current_proc_no_su(void)
{
}

void susfs_set_current_proc_umounted_for_zygote_next(void)
{
    susfs_set_current_proc_umounted();
}
"""
open(ext_path, "w").write(src)

# Inkypen's susfs import forgot the header in fs/open.c: it calls
# SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK (defined in
# susfs_def.h) but never includes it - every other patched file in
# the branch does. First SUSFS build died on this at fs/open.o.
src = open(open_path).read()
src = rep(src, "#include <linux/fs.h>",
    "#include <linux/fs.h>\n#include <linux/susfs_def.h>  /* susfs-wired: open.c uses SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK */")
open(open_path, "w").write(src)

src = open(pre_path).read()
old_sig = """bool ksu_preinit_handle_execve(const char __user **filename_user, const char __user *const __user *argv_user,
                               int orig_nr, struct pt_regs *regs, long *ret)
{"""
new_sig = """bool ksu_preinit_handle_execve(const char __user **filename_user, const char __user *const __user *argv_user,
                               int orig_nr, struct pt_regs *regs, long *ret)
{
    return false; /* susfs-wired: preinit runner swap disabled */"""
src = rep(src, old_sig, new_sig)
open(pre_path, "w").write(src)

src = open(mgr_path).read()
src = rep(src, '    syscall_regfunc_rp = init_kretprobe("syscall_regfunc", syscall_regfunc_handler);',
    "    syscall_regfunc_rp = NULL; /* susfs-wired: kretprobe pair not registered */")
src = rep(src, '    syscall_unregfunc_rp = init_kretprobe("syscall_unregfunc", syscall_unregfunc_handler);',
    "    syscall_unregfunc_rp = NULL; /* susfs-wired: kretprobe pair not registered */")
# The tp redirect is convicted on this tree (bisect10: even a pure
# pass-through hook hangs the boot), and v1.3.2 registers it in
# SUSFS mode too - the first SUSFS build hung the same way. Disable
# the whole tp layer: no hook registrations, no tracepoint. The
# susfs kernel-side hooks and the KSU core do not depend on it.
src = rep(src, "    ksu_register_syscall_hook(__NR_execve, ksu_hook_execve);",
    "    /* susfs-wired: ksu_register_syscall_hook(__NR_execve, ksu_hook_execve); */")
src = rep(src, "    ksu_register_syscall_hook(__NR_execveat, ksu_hook_execveat);",
    "    /* susfs-wired: ksu_register_syscall_hook(__NR_execveat, ksu_hook_execveat); */")
src = rep(src, "    ksu_register_syscall_hook(__NR_newfstatat, ksu_hook_newfstatat);",
    "    /* susfs-wired: ksu_register_syscall_hook(__NR_newfstatat, ksu_hook_newfstatat); */")
src = rep(src, "    ksu_register_syscall_hook(__NR_faccessat, ksu_hook_faccessat);",
    "    /* susfs-wired: ksu_register_syscall_hook(__NR_faccessat, ksu_hook_faccessat); */")
src = rep(src, "    ret = register_trace_prio_sys_enter(ksu_sys_enter_handler, NULL, INT_MIN);",
    "    ret = 0; /* susfs-wired: sys_enter tracepoint not registered on this tree */")
open(mgr_path, "w").write(src)

# The SELinux pair (our 5.4 selinux_hide port + avc spoof) has never
# been exonerated on its own: every booting build so far had it off.
# Keep it off for this round too; re-enable separately once the
# SUSFS core is proven to boot.
src = open(init_path).read()
src = rep(src, "    ksu_selinux_hide_init();",
    "    /* susfs-wired: ksu_selinux_hide_init(); */")
src = rep(src, "    ksu_avc_spoof_init();",
    "    /* susfs-wired: ksu_avc_spoof_init(); */")
open(init_path, "w").write(src)

# Round 3 (2026-11-15): round 2 boots but the manager shows
# "not supported" - with the tp layer off, two FinaSU paths never
# fire because their only caller was the tp bridge, and Inkypen's
# susfs branch has no inline call sites for them:
#   - the manager fd (ksu_install_fd) is installed from the
#     setresuid handler when zygote spawns the manager process;
#   - ksud tracking (second_stage: apply rules, cache sids, set up
#     the KSU cred) hangs off the execve bridge.
# Wire both inline. Note the setresuid handler's SUSFS branch reads
# the RAW SYSCALL ARGS (zygote specialization calls
# setresuid(app_uid, app_uid, app_uid), so ruid IS the new uid) and
# must run BEFORE commit_creds while current is still in the zygote
# domain - the tp bridge's post-call argument convention
# (old_uid, current, current) silently no-ops here; round 3 proved
# it (booted, manager still unsupported).
src = open(sys_path).read()
old_tail = """	retval = security_task_fix_setuid(new, old, LSM_SETID_RES);
	if (retval < 0)
		goto error;

	return commit_creds(new);"""
new_tail = """	retval = security_task_fix_setuid(new, old, LSM_SETID_RES);
	if (retval < 0)
		goto error;

#ifdef CONFIG_KSU_SUSFS
	{
		extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);

		ksu_handle_setresuid(ruid, euid, suid);
	}
#endif
	return commit_creds(new);"""
src = rep(src, old_tail, new_tail)
open(sys_path, "w").write(src)

src = open(exec_path).read()
old_ret = "	return __do_execve_file(fd, filename, argv, envp, flags, NULL);"
new_ret = """#ifdef CONFIG_KSU_SUSFS
	if (filename) {
		extern void ksu_handle_execveat_ksud(const char *path, struct user_arg_ptr *argv);

		ksu_handle_execveat_ksud(filename->name, &argv);

		/* Inline sucompat (round 5): app root rides on exec of
		 * /system/bin/su, whose interception lived in the disabled
		 * tp bridge - granted apps (MT, Termux) got nothing. Mirror
		 * the bridge here: an allowlisted caller execing su gets
		 * ksud as the new program (file exec, argv untouched), its
		 * root profile applied first, and an su session fd
		 * installed after a successful exec. __do_execve_file
		 * consumes the ksud file reference via bprm. */
		if (!strcmp(filename->name, "/system/bin/su")) {
			extern bool __ksu_is_allow_uid_for_current(uid_t uid);
			extern int escape_with_root_profile(void);
			extern int ksu_install_su_fd(void);
			extern struct cred *ksu_cred;
			const struct cred *old_cred;
			struct file *ksud_file;
			int ksu_ret;

			if (__ksu_is_allow_uid_for_current(current_uid().val)) {
				old_cred = override_creds(ksu_cred);
				ksud_file = filp_open("/data/adb/ksud", O_PATH, 0);
				revert_creds(old_cred);
				if (!IS_ERR(ksud_file)) {
					ksu_ret = escape_with_root_profile();
					if (!ksu_ret) {
						ksu_ret = __do_execve_file(AT_FDCWD, NULL, argv, envp, 0, ksud_file);
						if (!ksu_ret)
							ksu_install_su_fd();
						return ksu_ret;
					}
					fput(ksud_file);
				}
			}
		}
	}
#endif
	return __do_execve_file(fd, filename, argv, envp, flags, NULL);"""
src = rep(src, old_ret, new_ret)
open(exec_path, "w").write(src)
print("patched: susfs wiring - glue stubs, preinit off, kretprobe pair off, tp layer off, selinux pair off, inline setresuid+execve call sites, inline su exec")
PYEOF
  fi
  fi


fi

# ---------------------------------------------------------------- config
step "configure (odin_defconfig)"
make "${MAKE_ARGS[@]}" odin_defconfig

CFG="$WORK/kout/.config"
if [ "$VARIANT" != "vanilla" ]; then
  step "enable KSU config ($VARIANT)"
  "$KSRC/scripts/config" --file "$CFG" \
    --enable KSU --enable KPROBES --enable KALLSYMS_ALL \
    --enable EXT4_FS --enable HEADERS_INSTALL
  if [ "$VARIANT" = "finasu-susfs" ] || [ "$VARIANT" = "resukisu" ]; then
    "$KSRC/scripts/config" --file "$CFG" --enable KSU_SUSFS
  fi
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
grep -E '^CONFIG_(KSU|KSU_SUSFS|KPROBES|KALLSYMS_ALL|HZ|WQ_POWER_EFFICIENT_DEFAULT)=' "$CFG" || true

if [ "$VARIANT" = "resukisu" ]; then
  step "install UAPI headers into objtree (BakaSU preinit codegen)"
  # The preinit runner is compiled against $(objtree)/usr/include;
  # without linux/unistd.h there BakaSU disables preinit, and the
  # inline execve site in fs/exec.c would call missing symbols.
  # Install explicitly (with the full MAKE_ARGS) instead of relying
  # on the codegen's in-parse sub-make fallback.
  make "${MAKE_ARGS[@]}" headers_install
  test -f "$WORK/kout/usr/include/linux/unistd.h"
  echo "UAPI headers ready for preinit runner"
fi

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

# Package an AnyKernel3 zip next to the raw Image so the kernel can be
# flashed on-device (e.g. Horizon Kernel Flasher), no PC needed. Template:
# osm0sis/AnyKernel3 pinned by commit; our anykernel.sh in scripts/ak3/.
# Built for every variant: a vanilla AK3 is the cleanest bisection tool
# when a kernel fails to boot (packaging fault vs kernel-code fault).
if true; then
  step "package AnyKernel3 zip"
  AK3_DIR="$WORK/ak3"
  mkdir -p "$AK3_DIR"
  git -C "$AK3_DIR" init -q
  git -C "$AK3_DIR" remote add origin https://github.com/osm0sis/AnyKernel3
  git -C "$AK3_DIR" fetch -q --depth 1 origin 41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1
  git -C "$AK3_DIR" checkout -q FETCH_HEAD
  rm -rf "$AK3_DIR/.git" "$AK3_DIR/.github"
  cp "$ROOT/scripts/ak3/anykernel.sh" "$AK3_DIR/anykernel.sh"
  cp "$OUT/Image" "$AK3_DIR/Image"
  ( cd "$AK3_DIR" && zip -r -q "$OUT/odin-${VARIANT}-ak3.zip" . )
  ls -lh "$OUT/odin-${VARIANT}-ak3.zip"
fi
cat "$OUT/utsrelease.txt" || true
ls -lh "$OUT"
step "done"
