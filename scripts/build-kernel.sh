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
