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
# Pin, do not chase. On 2026-09-06 upstream commit 3f0b811 ("kernel & KernelSU:
# Fix [ksu_driver_su] being wrongly installed before su session") added a
# ksu_install_su_fd() call to the 50_ kernel patch's exec.c hunk that only
# newer KSU trees define; with the pinned SukiSU builtin@6c5603f0 the kernel
# link fails: "undefined symbol: ksu_install_su_fd" (CI run 34046293618).
# Two CI builds succeeded the same day only because they synced before that
# commit landed. 8224c73 (its parent) is the newest gki-android15-6.6 revision
# verified to not reference ksu_install_su_fd. Upgrade SUSFS_REF only together
# with KSU_REF - the two pins must stay a coherent pair.
SUSFS_REF="${SUSFS_REF:-8224c73}"

KDIR="$KROOT/common"
[ -d "$KDIR/drivers" ] || { echo "::error::expected kernel tree at $KDIR"; exit 1; }
DEFCONFIG="$KDIR/arch/arm64/configs/gki_defconfig"

# Optional persistent source cache (CI caches this path). The root setup.sh scripts
# always `git clone` into the kernel tree; pointing git at a cached mirror via
# alternates lets them reuse objects instead of refetching every run.
SRC_CACHE="${SRC_CACHE:-}"
if [ -n "$SRC_CACHE" ]; then
    mkdir -p "$SRC_CACHE"
    echo "==> source cache: $SRC_CACHE"
fi

# Pre-place a cached clone at the exact path the upstream setup.sh expects, so it
# skips the download entirely. Both setup.sh scripts do:
#     test -d "$GKI_ROOT/<dir>" || git clone <url> <dir>
# with NO --depth, then `git pull` — a full-history fetch every run. If the directory
# already exists they only fetch what changed.
#
# Deliberately best-effort: any failure here just leaves the directory absent and
# setup.sh clones normally. A cache must never be able to break the build.
prime_clone() {
    url="$1" name="$2" dest="$KROOT/$2"
    [ -n "$SRC_CACHE" ] || return 0
    cached="$SRC_CACHE/$name"
    if [ -d "$cached/.git" ]; then
        echo "    $name cache HIT ($(du -sh "$cached" 2>/dev/null | cut -f1))"
    else
        echo "    $name cache MISS - cloning into cache"
        rm -rf "$cached"
        git clone -q "$url" "$cached" 2>/dev/null || { rm -rf "$cached"; return 0; }
    fi
    # Hardlink the cached clone into place (cheap, same filesystem). setup.sh then
    # sees an existing dir and only runs fetch/checkout against it.
    rm -rf "$dest"
    cp -al "$cached" "$dest" 2>/dev/null || cp -a "$cached" "$dest" 2>/dev/null || return 0
}

# After setup.sh has run, refresh the cache from the working clone so the next run
# starts from an up-to-date copy.
refresh_cache() {
    name="$1" src="$KROOT/$1"
    [ -n "$SRC_CACHE" ] || return 0
    [ -d "$src/.git" ] || return 0
    cached="$SRC_CACHE/$name"
    rm -rf "$cached.new"
    cp -al "$src" "$cached.new" 2>/dev/null || cp -a "$src" "$cached.new" 2>/dev/null || return 0
    rm -rf "$cached" && mv "$cached.new" "$cached"
}

set_y() {
    local key="$1"
    sed -i "/^# CONFIG_${key} is not set$/d; /^CONFIG_${key}=/d" "$DEFCONFIG"
    echo "CONFIG_${key}=y" >>"$DEFCONFIG"
}

# ---------------------------------------------------- flavor/SUSFS compatibility
# KernelSU-Next v3.x cannot take the susfs4ksu KSU-side patch. susfs4ksu's README
# states its patches are built against "the original official KernelSU (the one
# from weishu)" at a release tag, and 10_enable_susfs_for_ksu.patch expects that
# older layout: it *deletes* hook/lsm_hook.o, hook/syscall_hook_manager.o and
# infra/symbol_resolver.o from kernel/Kbuild, which are exactly the files v3.x is
# built on. KernelSU-Next itself carries no kernel-side SUSFS (only
# userspace/ksud/src/susfsd.rs), so there is nothing to enable either.
# SukiSU Ultra's `builtin` branch ships the KSU_SUSFS* implementation itself and
# needs no patch, so that is the supported route for SUSFS.
if [ "$ROOT_FLAVOR" = "ksu-next" ] && [ "$USE_SUSFS" = "true" ]; then
    echo "::warning::KernelSU-Next v3.x is structurally incompatible with the susfs4ksu"
    echo "::warning::KSU-side patch (it targets weishu's older KernelSU layout)."
    echo "::warning::Switching ROOT_FLAVOR to 'sukisu', which implements SUSFS natively."
    echo "::warning::To keep KernelSU-Next instead, re-run with use_susfs=false."
    ROOT_FLAVOR=sukisu
fi

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
    prime_clone https://github.com/KernelSU-Next/KernelSU-Next KernelSU-Next
    # setup.sh detects common/drivers, clones into ./KernelSU-Next, symlinks
    # drivers/kernelsu and edits drivers/{Makefile,Kconfig}.
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/stable/kernel/setup.sh" \
        | bash -s ${KSU_REF:+"$KSU_REF"}
    KSU_DIR="$KROOT/KernelSU-Next"
    refresh_cache KernelSU-Next
    set_y KSU
    if [ "$USE_KPM" = "true" ]; then
        echo "::warning::KPM is a SukiSU Ultra feature; KernelSU-Next has no CONFIG_KPM. Ignoring USE_KPM."
    fi
    ;;
  sukisu)
    # `builtin` is required: it carries the KSU_SUSFS* Kconfig symbols and the
    # KSU-side SUSFS implementation. The latest release tag (main) lacks them, and
    # kconfig would then silently drop every KSU_SUSFS entry we add below.
    #
    # But builtin's tip is not always buildable, and the breakage is in
    # kernel/feature/kernel_umount.c both times:
    #   * d13e8a75 / e2912817 (v4.2.0, 2026-09-01): dropped kernel_umount_feature_set()
    #     while keeping `.set_handler = kernel_umount_feature_set`
    #         error: use of undeclared identifier 'kernel_umount_feature_set'
    #   * 1a884658 and 2cf0f72d: reference KSU_FEATURE_WEBVIEW_ZYGOTE_UMOUNT, which is
    #     not in the enum in kernel/include/uapi/feature.h
    #         error: use of undeclared identifier 'KSU_FEATURE_WEBVIEW_ZYGOTE_UMOUNT'
    # Both only surface ~18 minutes in, when drivers/kernelsu/ksu.o is finally compiled.
    #
    # 6c5603f0 ("fix 2", 2026-08-27) is the newest commit on builtin whose feature
    # subsystem is self-consistent — verified by walking first-parent history and
    # checking every KSU_FEATURE_* reference and *_handler function against its
    # definitions. It still carries all 10 KSU_SUSFS symbols, KPM, and the
    # fs/susfs.c detection in kernel/Makefile.
    # Override with KSU_REF to track the tip once upstream fixes it.
    SUKISU_REF="${KSU_REF:-6c5603f0}"
    echo "==> integrating SukiSU Ultra (branch builtin, ref: $SUKISU_REF)"
    # setup.sh clones into $KROOT/KernelSU, so the cache entry uses that same name.
    prime_clone https://github.com/SukiSU-Ultra/SukiSU-Ultra KernelSU
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" \
        | bash -s "$SUKISU_REF"
    KSU_DIR="$KROOT/KernelSU"
    refresh_cache KernelSU
    set_y KSU
    [ "$USE_KPM" = "true" ] && { set_y KPM; echo "    KPM enabled"; }
    ;;
  *) echo "::error::unknown ROOT_FLAVOR: $ROOT_FLAVOR"; exit 1 ;;
esac

[ -L "$KDIR/drivers/kernelsu" ] || { echo "::error::drivers/kernelsu symlink missing (setup.sh failed)"; exit 1; }
grep -q kernelsu "$KDIR/drivers/Makefile" || { echo "::error::drivers/Makefile not wired"; exit 1; }
echo "==> root driver wired: $(readlink "$KDIR/drivers/kernelsu")"
echo "==> root revision: $(git -C "$KSU_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ------------------------------------------- preflight: feature subsystem coherence
# Two upstream breakages, both in kernel/feature/*.c, both invisible until
# drivers/kernelsu/ksu.o compiles ~18 minutes into the kernel build:
#   1. a *_handler struct member naming a function that no longer exists
#   2. a KSU_FEATURE_* enum constant that is not in kernel/include/uapi/feature.h
# Checking statically costs a second, so check both.
missing=""
FEATURE_H="$KSU_DIR/kernel/include/uapi/feature.h"
if [ -f "$FEATURE_H" ]; then
    enum_defs="$(grep -ohE '\bKSU_FEATURE_[A-Z0-9_]+' "$FEATURE_H" | sort -u)"
else
    enum_defs=""
    echo "::warning::$FEATURE_H not found; skipping enum coherence check"
fi

for src in "$KSU_DIR"/kernel/feature/*.c "$KSU_DIR"/kernel/policy/feature.c; do
    [ -f "$src" ] || continue

    # (1) every function named by a *_handler assignment must be defined in that file
    for fn in $(grep -oE '(get|set)_handler[[:space:]]*=[[:space:]]*[A-Za-z0-9_]+' "$src" \
                | sed 's/.*=[[:space:]]*//' | sort -u); do
        case "$fn" in NULL|0) continue ;; esac
        grep -qE "^[a-zA-Z_].*[[:space:]]\*?${fn}[[:space:]]*\(" "$src" \
            || missing="$missing $(basename "$src"):$fn"
    done

    # (2) every KSU_FEATURE_* enum reference must exist in the uapi header.
    # Exclude CONFIG_KSU_FEATURE_* — those are Kconfig macros used in #ifdef, not enum
    # members, and matching them naively flags every commit as broken.
    [ -n "$enum_defs" ] || continue
    for r in $(grep -oE '(^|[^A-Z_])KSU_FEATURE_[A-Z0-9_]+' "$src" \
               | grep -oE 'KSU_FEATURE_[A-Z0-9_]+' | sort -u); do
        printf '%s\n' "$enum_defs" | grep -qx "$r" || missing="$missing $(basename "$src"):$r"
    done
done

if [ -n "$missing" ]; then
    echo "::error::$ROOT_FLAVOR revision $(git -C "$KSU_DIR" rev-parse --short HEAD 2>/dev/null) is not buildable."
    echo "::error::Undefined symbols referenced by the feature subsystem:"
    for m in $missing; do echo "::error::  $m"; done
    echo "::error::This is an upstream bug in the pinned root revision, not a config problem."
    echo "::error::Pin a known-good commit via the ksu_ref input (SukiSU default: 6c5603f0)."
    exit 1
fi
echo "==> feature subsystem coherent (handlers + enum refs)"

# ------------------------------------------------------------------- SUSFS
if [ "$USE_SUSFS" = "true" ]; then
    echo "==> integrating SUSFS (branch $SUSFS_BRANCH)"
    # Keep the clone under $SRC_CACHE when provided (CI caches that directory), so
    # repeat runs skip the download. /tmp is not persisted on a fresh runner.
    SUS="${SRC_CACHE:-/tmp}/susfs4ksu"
    if [ -d "$SUS/.git" ]; then
        echo "    susfs cache HIT ($SUS)"
        # The cache may hold any of three states: shallow (seeded by older
        # revisions), complete-but-stale (unshallowed by a previous run and
        # saved), or complete-current. A plain fetch is always valid; unshallow
        # is only valid on a still-shallow clone - "--unshallow on a complete
        # repository" is a hard error (run 34051146826). This repo is <1MB with
        # history, so deepening is cheap either way.
        git -C "$SUS" fetch -q origin "$SUSFS_BRANCH" \
            || { echo "::error::susfs fetch of origin/$SUSFS_BRANCH failed"; exit 1; }
        if [ "$(git -C "$SUS" rev-parse --is-shallow-repository)" = "true" ]; then
            git -C "$SUS" fetch -q --unshallow origin "$SUSFS_BRANCH" \
                || { echo "::error::susfs unshallow of origin/$SUSFS_BRANCH failed"; exit 1; }
        fi
    else
        echo "    susfs cache MISS - cloning"
        mkdir -p "$(dirname "$SUS")"
        rm -rf "$SUS"
        git clone -q -b "$SUSFS_BRANCH" \
            https://gitlab.com/simonpunk/susfs4ksu.git "$SUS"
    fi
    # Detach onto the pin and verify it really is part of the branch's history.
    # A silent fallback to the moving tip is exactly the drift that broke
    # run 34046293618 - any pin problem must fail loudly instead.
    git -C "$SUS" cat-file -e "$SUSFS_REF^{commit}" 2>/dev/null \
        || { echo "::error::SUSFS_REF $SUSFS_REF not found in origin/$SUSFS_BRANCH history"; exit 1; }
    git -C "$SUS" merge-base --is-ancestor "$SUSFS_REF" "origin/$SUSFS_BRANCH" \
        || { echo "::error::SUSFS_REF $SUSFS_REF is not an ancestor of origin/$SUSFS_BRANCH"; exit 1; }
    git -C "$SUS" checkout -q --detach "$SUSFS_REF"
    echo "    susfs pinned to $(git -C "$SUS" rev-parse --short HEAD)"
    SUSFS_VER="$(grep -m1 'SUSFS_VERSION' "$SUS/kernel_patches/include/linux/susfs.h" | cut -d'"' -f2)"
    echo "    SUSFS version: $SUSFS_VER"

    cp -v "$SUS"/kernel_patches/fs/* "$KDIR/fs/"
    cp -v "$SUS"/kernel_patches/include/linux/* "$KDIR/include/linux/"

    KPATCH="$SUS/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
    [ -f "$KPATCH" ] || { echo "::error::missing $KPATCH"; exit 1; }
    patch -p1 -d "$KDIR" <"$KPATCH"

    # No KSU-side patch is applied here. SukiSU `builtin` implements SUSFS itself,
    # and the ksu-next + SUSFS combination was already redirected to sukisu above
    # (10_enable_susfs_for_ksu.patch targets weishu's older KernelSU layout and
    # cannot apply to KernelSU-Next v3.x).
    if [ ! -f "$KSU_DIR/kernel/Kconfig" ]; then
        echo "::error::root tree missing at $KSU_DIR"; exit 1
    fi
    if ! grep -q 'KSU_SUSFS' "$KSU_DIR/kernel/Kconfig"; then
        echo "::error::$ROOT_FLAVOR tree has no KSU_SUSFS symbols in kernel/Kconfig."
        echo "::error::kconfig would silently drop every CONFIG_KSU_SUSFS* line."
        echo "::error::For SukiSU Ultra this means setup.sh did not check out the 'builtin' branch."
        exit 1
    fi
    echo "    root tree provides KSU_SUSFS symbols"

    # SUSFS README step 11: on GKI android14+ the protected-exports lists must be
    # removed or modules like WiFi fail to load. Same failure class that
    # MODULE_SIG_PROTECT=n addresses (fix-gki-config.sh); doing both is belt and braces.
    for f in "$KDIR/android/abi_gki_protected_exports_aarch64" \
             "$KDIR/android/abi_gki_protected_exports_x86_64"; do
        [ -f "$f" ] && { rm -f "$f"; echo "    removed $(basename "$f")"; }
    done

    for c in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
             KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
             KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT; do
        set_y "$c"
    done
    echo "    SUSFS configs set"
fi

echo "==> root integration done ($ROOT_FLAVOR, susfs=$USE_SUSFS, kpm=$USE_KPM)"
grep -E '^CONFIG_(KSU|KPM)' "$DEFCONFIG" | sort

# Export the flavor that was ACTUALLY used: it may differ from the workflow input
# (ksu-next + SUSFS is redirected to sukisu above). Later steps must gate on the
# effective value, or verify-build.sh would assert the wrong things.
{
    echo "EFFECTIVE_ROOT_FLAVOR=$ROOT_FLAVOR"
    echo "EFFECTIVE_USE_KPM=$USE_KPM"
} >>"${GITHUB_ENV:-/dev/null}"
