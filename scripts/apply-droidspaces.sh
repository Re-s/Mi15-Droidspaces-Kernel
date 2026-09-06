#!/usr/bin/env bash
# Apply Droidspaces kernel support to a GKI kernel tree.
#
# Two jobs:
#   1. the SYSVIPC kABI padding patch (variant auto-selected, see below)
#   2. the gki_defconfig fragment
#
# Why the variant is auto-selected instead of hardcoded:
# Droidspaces ships three mutually exclusive variants of the same patch
# (1_2_3 / 3_4_5 / 6_7_8) which differ only in WHICH ANDROID_KABI_RESERVE slots
# of task_struct they consume. Upstream GKI keeps claiming low slots over time:
#   android15-6.6 @ 6.6.111 -> slot 1 used
#   android15-6.6 @ 6.6.142 -> slots 1 AND 2 used
# So a hardcoded variant silently rots. We probe instead.
set -euo pipefail

KDIR="${1:?usage: apply-droidspaces.sh <kernel-dir> [patch-dir]}"
PATCH_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches/droidspaces" && pwd)}"

SCHED="$KDIR/include/linux/sched.h"
DEFCONFIG="$KDIR/arch/arm64/configs/gki_defconfig"
FRAGMENT="$PATCH_DIR/gki-droidspaces.fragment"

[ -f "$SCHED" ]     || { echo "::error::not a kernel tree: $SCHED missing"; exit 1; }
[ -f "$DEFCONFIG" ] || { echo "::error::gki_defconfig missing: $DEFCONFIG"; exit 1; }
[ -f "$FRAGMENT" ]  || { echo "::error::fragment missing: $FRAGMENT"; exit 1; }

echo "==> kernel tree: $KDIR"
echo "==> patch dir:   $PATCH_DIR"

# ---------------------------------------------------------------- 1. kABI patch
# Report which slots upstream already consumed, for the build log.
occupied="$(awk '/^struct task_struct \{/,/^\};/' "$SCHED" \
            | grep -oE 'ANDROID_KABI_USE2?\([0-9]+' \
            | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')"
echo "==> task_struct ANDROID_KABI slots already in use upstream: ${occupied:-none}"

if grep -q 'ANDROID_KABI_USE(.*sysv_sem' "$SCHED"; then
    echo "==> SYSVIPC kABI patch already applied, skipping"
else
    applied=""
    # Highest slots first: low slots are the ones upstream keeps taking.
    for variant in 6_7_8 3_4_5 1_2_3; do
        p="$PATCH_DIR/001.GKI-below-6.12-fix_sysvipc_kabi_${variant}.patch"
        [ -f "$p" ] || continue
        if patch -p1 -d "$KDIR" --dry-run -F 3 <"$p" >/dev/null 2>&1; then
            echo "==> applying kABI variant: $variant"
            patch -p1 -d "$KDIR" -F 3 <"$p"
            applied="$variant"
            break
        fi
        echo "    variant $variant does not apply, trying next"
    done
    if [ -z "$applied" ]; then
        echo "::error::no Droidspaces SYSVIPC kABI variant applies to this tree."
        echo "::error::Upstream task_struct layout changed (slots in use: ${occupied:-none})."
        echo "::error::A new patch variant is needed; refusing to build a bootlooping kernel."
        exit 1
    fi
    echo "DROIDSPACES_KABI_VARIANT=$applied" >>"${GITHUB_ENV:-/dev/null}"

    # Verify the result rather than trusting patch's exit code: -F 3 can apply a
    # hunk in the wrong place. Both fields must be inside the SYSVIPC guard.
    if ! grep -q 'ANDROID_KABI_USE(.*struct sysv_sem sysvsem)' "$SCHED"; then
        echo "::error::post-patch check failed: sysvsem not moved into a KABI slot"; exit 1
    fi
    if ! grep -q '_ANDROID_KABI_REPLACE(.*struct sysv_shm sysvshm)' "$SCHED"; then
        echo "::error::post-patch check failed: sysvshm not moved into KABI slots"; exit 1
    fi
    # The original members must now be commented out, or the struct grows -> ABI break.
    if awk '/^struct task_struct \{/,/^\};/' "$SCHED" \
         | grep -qE '^\s+struct sysv_(sem|shm)\s'; then
        echo "::error::post-patch check failed: original sysvsem/sysvshm still active -> ABI would shift"
        exit 1
    fi

    # No slot may be claimed twice. `patch -F 3` matches fuzzily, so a hunk could in
    # principle land on a slot upstream already took: that still compiles, but the
    # field would be shared with a vendor module -> silent memory corruption.
    dupes="$(awk '/^struct task_struct \{/,/^\};/' "$SCHED" \
             | grep -oE 'ANDROID_KABI_USE2?\([0-9]+' | grep -oE '[0-9]+' \
             | sort -n | uniq -d | tr '\n' ' ')"
    if [ -n "$dupes" ]; then
        echo "::error::post-patch check failed: ANDROID_KABI slot(s) claimed twice: $dupes"
        echo "::error::patch landed on a slot upstream already uses -> silent ABI corruption"
        exit 1
    fi

    # Cross-check against the pre-patch occupancy snapshot too.
    for slot in $occupied; do
        if grep -qE "ANDROID_KABI_USE\(${slot}, struct sysv_(sem|shm)" "$SCHED"; then
            echo "::error::post-patch check failed: sysvipc took slot $slot, already used upstream"
            exit 1
        fi
    done
    echo "==> kABI patch verified (variant $applied, no slot collision)"
fi

# NOTE: 002.5.10_or_lower_*posix_mqueue*.patch is deliberately NOT applied.
# It targets struct user_struct.mq_bytes, which on 6.6 has already moved to the
# ucounts infrastructure. It is a <=5.10 patch and is not vendored here.

# ------------------------------------------------------------- 2. defconfig
# Upstream's doc is explicit: do NOT append the block wholesale, set each option
# individually. Appending would leave duplicate/contradictory lines and break
# `savedefconfig` ordering checks. This does per-option set semantics.
set_config() {
    local key="$1" val="$2" file="$3"
    if grep -q "^# CONFIG_${key} is not set$" "$file"; then
        sed -i "s|^# CONFIG_${key} is not set$|CONFIG_${key}=${val}|" "$file"
        echo "    ${key}: not-set -> ${val}"
    elif grep -q "^CONFIG_${key}=${val}$" "$file"; then
        echo "    ${key}: already ${val}"
    elif grep -q "^CONFIG_${key}=" "$file"; then
        sed -i "s|^CONFIG_${key}=.*|CONFIG_${key}=${val}|" "$file"
        echo "    ${key}: changed -> ${val}"
    else
        echo "CONFIG_${key}=${val}" >>"$file"
        echo "    ${key}: appended ${val}"
    fi
}

echo "==> applying Droidspaces defconfig fragment"
while IFS= read -r line; do
    case "$line" in
        ''|'#'*) continue ;;
    esac
    # strip trailing comments, then split CONFIG_X=y
    entry="${line%%#*}"
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    key="${entry%%=*}"; key="${key#CONFIG_}"
    val="${entry#*=}"
    set_config "$key" "$val" "$DEFCONFIG"
done <"$FRAGMENT"

echo "==> Droidspaces applied successfully"
