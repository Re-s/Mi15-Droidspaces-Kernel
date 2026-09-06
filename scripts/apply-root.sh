#!/usr/bin/env bash
# Integrate a root solution (+ optional SUSFS) into a GKI kernel tree.
#
#   ROOT_FLAVOR=ksu-next   -> KernelSU-Next  (no KPM; hooks are built in on v3.x)
#   ROOT_FLAVOR=sukisu     -> SukiSU Ultra   (KPM available, branch `builtin` has SUSFS)
#   ROOT_FLAVOR=none       -> no root (clean kernel, still gets Droidspaces)
#
# Facts this encodes (verified against the upstream repos, see docs/RESEARCH.md):
#  * KernelSU-Next branches are stable/dev/legacy — there is NO `next` branch, and
#    v3.x Kconfig exposes only KSU / KSU_DEBUG / KSU_DISABLE_MANAGER / KSU_DISABLE_POLICY.
#    The old CONFIG_KSU_MANUAL_HOOK / KSU_KPROBES_HOOK选择 no longer exists: v3.x ships
#    kernel/hook/{lsm_hook,syscall_hook,setuid_hook}.c plus a runtime symbol_resolver
#    and needs no fs/*.c edits. CONFIG_KSU depends on KPROBES && EXT4_FS (both =y in stock).
#  * KPM is a SukiSU Ultra feature, not a KernelSU-Next one.
#  * SUSFS lives at gitlab.com/simonpunk/susfs4ksu, branch gki-android15-6.6 (SUSFS v2.3.0).
#    kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch targets the KSU tree
#    (kernel/Kbuild, kernel/hook/*, kernel/supercall/*), while SukiSU's `builtin`
#    branch already defines the KSU_SUSFS* symbols itself and must NOT be patched.
set -euo pipefail

KROOT="${1:?usage: apply-root.sh <repo-root-containing-common/>}"
ROOT_FLAVOR="${ROOT_FLAVOR:-ksu-next}"
USE_SUSFS="${USE_SUSFS:-true}"
USE_KPM="${USE_KPM:-false}"
KSU_REF="${KSU_REF:-}"           # tag/commit; empty = latest tag
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android15-6.6}"

KDIR="$KROOT/common"
[ -d "$KDIR/drivers" ] || { echo "::error::expected kernel tree at $KDIR"; exit 1; }
DEFCONFIG="$KDIR/arch/arm64/configs/gki_defconfig"

set_y() {
    local key="$1"
    sed -i "/^# CONFIG_${key} is not set$/d; /^CONFIG_${key}=/d" "$DEFCONFIG"
    echo "CONFIG_${key}=y" >>"$DEFCONFIG"
}

if [ "$ROOT_FLAVOR" = "none" ]; then
    echo "==> ROOT_FLAVOR=none: stripping any KSU/KPM leftovers"
    sed -i -E '/^CONFIG_KSU[A-Z_]*=[ym]$/d; /^CONFIG_KPM=[ym]$/d' "$DEFCONFIG"
    if grep -qE '^CONFIG_(KSU|KPM)' "$DEFCONFIG"; then
        echo "::error::defconfig still enables KSU/KPM"; exit 1
    fi
    echo "==> clean (no root)"
    exit 0
fi

cd "$KROOT"

case "$ROOT_FLAVOR" in
  ksu-next)
    echo "==> integrating KernelSU-Next (ref: ${KSU_REF:-latest tag})"
    # setup.sh detects common/drivers, clones into ./KernelSU-Next, symlinks
    # drivers/kernelsu and edits drivers/{Makefile,Kconfig}.
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/stable/kernel/setup.sh" \
        | bash -s ${KSU_REF:+"$KSU_REF"}
    KSU_DIR="$KROOT/KernelSU-Next"
    set_y KSU
    if [ "$USE_KPM" = "true" ]; then
        echo "::warning::KPM is a SukiSU Ultra feature; KernelSU-Next has no CONFIG_KPM. Ignoring USE_KPM."
    fi
    ;;
  sukisu)
    echo "==> integrating SukiSU Ultra (branch: builtin)"
    # `builtin` is required: it carries the KSU_SUSFS* Kconfig symbols and the
    # KSU-side SUSFS implementation. The latest release tag (main) lacks them, and
    # kconfig would then silently drop every KSU_SUSFS entry we add below.
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" \
        | bash -s builtin
    KSU_DIR="$KROOT/KernelSU"
    set_y KSU
    [ "$USE_KPM" = "true" ] && { set_y KPM; echo "    KPM enabled"; }
    ;;
  *) echo "::error::unknown ROOT_FLAVOR: $ROOT_FLAVOR"; exit 1 ;;
esac

[ -L "$KDIR/drivers/kernelsu" ] || { echo "::error::drivers/kernelsu symlink missing (setup.sh failed)"; exit 1; }
grep -q kernelsu "$KDIR/drivers/Makefile" || { echo "::error::drivers/Makefile not wired"; exit 1; }
echo "==> root driver wired: $(readlink "$KDIR/drivers/kernelsu")"

# ------------------------------------------------------------------- SUSFS
if [ "$USE_SUSFS" = "true" ]; then
    echo "==> integrating SUSFS (branch $SUSFS_BRANCH)"
    SUS=/tmp/susfs4ksu
    [ -d "$SUS" ] || git clone -q --depth=1 -b "$SUSFS_BRANCH" \
        https://gitlab.com/simonpunk/susfs4ksu.git "$SUS"
    SUSFS_VER="$(grep -m1 'SUSFS_VERSION' "$SUS/kernel_patches/include/linux/susfs.h" | cut -d'"' -f2)"
    echo "    SUSFS version: $SUSFS_VER"

    cp -v "$SUS"/kernel_patches/fs/* "$KDIR/fs/"
    cp -v "$SUS"/kernel_patches/include/linux/* "$KDIR/include/linux/"

    KPATCH="$SUS/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
    [ -f "$KPATCH" ] || { echo "::error::missing $KPATCH"; exit 1; }
    patch -p1 -d "$KDIR" <"$KPATCH"

    # KSU-side patch: only KernelSU-Next needs it. SukiSU's builtin branch already
    # implements SUSFS, and applying the patch there would collide.
    if [ "$ROOT_FLAVOR" = "ksu-next" ]; then
        KSUP="$SUS/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
        if [ -f "$KSUP" ]; then
            echo "    applying KSU-side SUSFS patch"
            if ! patch -p1 -d "$KSU_DIR" --dry-run <"$KSUP" >/dev/null 2>&1; then
                echo "::error::10_enable_susfs_for_ksu.patch does not apply to this KernelSU-Next revision."
                echo "::error::SUSFS $SUSFS_VER expects a different KSU layout - pin KSU_REF or disable SUSFS."
                exit 1
            fi
            patch -p1 -d "$KSU_DIR" <"$KSUP"
        fi
    fi

    for c in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
             KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
             KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT; do
        set_y "$c"
    done
    echo "    SUSFS configs set"
fi

echo "==> root integration done ($ROOT_FLAVOR, susfs=$USE_SUSFS, kpm=$USE_KPM)"
grep -E '^CONFIG_(KSU|KPM)' "$DEFCONFIG" | sort
