#!/usr/bin/env bash
# Align the build with the stock kernel environment, and set the kernel name.
#
# Every rule here comes from the stock config extracted out of the user's own
# Xiaomi 15 boot image (docs/stock-6.6.118-android15-8.config). Getting any of
# these wrong produces a kernel that builds fine and then bricks the boot or
# kills WiFi, which is why each one is asserted rather than assumed.
set -euo pipefail

KROOT="${1:?usage: fix-gki-config.sh <repo-root> [kernel-name]}"
KERNEL_NAME="${2:--Mi15-DS}"
KDIR="$KROOT/common"
DEFCONFIG="$KDIR/arch/arm64/configs/gki_defconfig"
[ -f "$DEFCONFIG" ] || { echo "::error::missing $DEFCONFIG"; exit 1; }

echo "==> aligning with stock environment"

# 1. MODULE_SIG_PROTECT must be OFF.
#    Stock has it =y and that works because Google's signing key is baked into the
#    stock trusted ring. A self-built kernel only trusts its own kleaf-generated
#    key, so every Google-signed system_dlkm module that exports a *protected*
#    symbol (rfkill, bluetooth, mii, ppp*, usbnet, virtio*, ...) is refused with
#    EACCES, silently, at boot. Result: cfg80211 cannot resolve rfkill_alloc and
#    WiFi + Bluetooth are dead. We cannot reproduce Google's trust path, so the
#    gate has to come off. This is load-time policy only: no task_struct, ABI or
#    CRC impact.
if grep -q '^CONFIG_MODULE_SIG_PROTECT=y' "$DEFCONFIG"; then
    sed -i 's/^CONFIG_MODULE_SIG_PROTECT=y/# CONFIG_MODULE_SIG_PROTECT is not set/' "$DEFCONFIG"
    echo "    MODULE_SIG_PROTECT: y -> off (system_dlkm protected-symbol gate)"
else
    sed -i '/^# CONFIG_MODULE_SIG_PROTECT is not set$/d' "$DEFCONFIG"
    echo '# CONFIG_MODULE_SIG_PROTECT is not set' >>"$DEFCONFIG"
    echo "    MODULE_SIG_PROTECT: forced off"
fi

# 2. LTO and CFI must MATCH stock, not be "improved".
#    Stock ground truth: CONFIG_LTO_NONE=y and CONFIG_CFI_CLANG=y. A different LTO
#    mode changes codegen and therefore symbol CRCs, and vendor_dlkm modules then
#    refuse to load -> bootloop. Do not enable LTO_THIN here "for speed".
#    Bonus: no LTO also means no OOM risk on a 7GB runner.
#    Note: upstream gki_defconfig only carries CONFIG_CFI_CLANG=y. LTO_NONE is the
#    Kconfig *default*, so it is absent from the defconfig yet still ends up =y in the
#    built kernel — exactly like stock. "Absent" is therefore correct, and only an
#    explicit LTO_CLANG_* would be wrong. verify-build.sh asserts the effective value
#    by reading it back out of the built Image.
echo "    LTO/CFI as shipped by upstream defconfig:"
grep -E '^(CONFIG_LTO|CONFIG_CFI)' "$DEFCONFIG" | sed 's/^/      /' || true
if grep -qE '^CONFIG_LTO_CLANG(_THIN|_FULL)?=y' "$DEFCONFIG"; then
    echo "::error::defconfig enables Clang LTO but stock is LTO_NONE."
    echo "::error::A different LTO mode changes codegen/CRCs -> vendor_dlkm refuses to load -> bootloop."
    exit 1
fi

# 3. Kernel name / localversion.
#    On 6.x with kleaf, .scmversion is dead and kleaf supplies its own localversion
#    rule (build/kleaf/impl/stamp.bzl). Without --config=stamp it emits the literal
#    string "-maybe-dirty", and that same file carries the "-android15-8" KMI tail.
#    So the name is injected by rewriting that echo. Setting CONFIG_LOCALVERSION
#    instead would append AFTER the file's content and land in the wrong order.
STAMP="$KROOT/build/kleaf/impl/stamp.bzl"
[ -f "$STAMP" ] || STAMP="$(find "$KROOT/build" -name stamp.bzl -path '*kleaf*' 2>/dev/null | head -n1)"
if [ -n "${STAMP:-}" ] && [ -f "$STAMP" ]; then
    if grep -q "echo '-maybe-dirty'" "$STAMP"; then
        sed -i "s|echo '-maybe-dirty'|echo '${KERNEL_NAME}'|" "$STAMP"
        echo "    kernel name: -maybe-dirty -> ${KERNEL_NAME}"
    else
        echo "::warning::'-maybe-dirty' not found in $STAMP; kleaf layout changed, name may not apply"
    fi
else
    echo "::warning::kleaf stamp.bzl not found; kernel name not applied"
fi
# LOCALVERSION_AUTO would append a git hash and break the KMI-looking suffix.
sed -i '/^CONFIG_LOCALVERSION_AUTO=y$/d; /^# CONFIG_LOCALVERSION_AUTO is not set$/d' "$DEFCONFIG"
echo '# CONFIG_LOCALVERSION_AUTO is not set' >>"$DEFCONFIG"

# 4. KSU prerequisites (both =y in stock already; assert so a regression is loud).
for c in KPROBES KALLSYMS KALLSYMS_ALL EXT4_FS; do
    if ! grep -q "^CONFIG_${c}=y" "$DEFCONFIG"; then
        sed -i "/^# CONFIG_${c} is not set$/d; /^CONFIG_${c}=/d" "$DEFCONFIG"
        echo "CONFIG_${c}=y" >>"$DEFCONFIG"
        echo "    ${c}: forced y"
    fi
done

# 5. Disable the savedefconfig gate at its real source.
#    We append options to gki_defconfig instead of inserting them in `savedefconfig`
#    order, so the check fails on ordering alone:
#        ERROR: savedefconfig does not match common/arch/arm64/configs/gki_defconfig
#
#    This gate is NOT a bazel attribute. It is the legacy build-config hook
#    `POST_DEFCONFIG_CMDS="check_defconfig"` in common/build.config.gki, which kleaf
#    still evaluates. Note that `check_defconfig` also exists as a `kernel_build`
#    attribute, but it cannot be reached from here: kernel_aarch64 is created by
#    define_common_kernels(), and _define_common_kernel() does not forward that
#    keyword (bazel rejects it outright). So the hook is the only lever.
GKI_BC="$KDIR/build.config.gki"
# -s, not -f: a 0-byte file must not pass. Upstream this file is 62 bytes:
#   DEFCONFIG=gki_defconfig
#   POST_DEFCONFIG_CMDS="check_defconfig"
[ -s "$GKI_BC" ] || { echo "::error::$GKI_BC missing or empty; cannot disable the defconfig check"; exit 1; }

# Require the positive precondition first. Asserting only that the old string is gone
# would also "pass" on an empty or restructured file — a vacuous check.
if grep -q 'POST_DEFCONFIG_CMDS' "$GKI_BC"; then
    sed -i 's/POST_DEFCONFIG_CMDS="check_defconfig"/POST_DEFCONFIG_CMDS="true"/' "$GKI_BC"
    if grep -q 'check_defconfig' "$GKI_BC"; then
        echo "::error::failed to disable check_defconfig in $GKI_BC:"; cat "$GKI_BC"; exit 1
    fi
    echo "    check_defconfig gate disabled ($(grep POST_DEFCONFIG "$GKI_BC"))"
else
    echo "::error::no POST_DEFCONFIG_CMDS in $GKI_BC - build-config layout changed."
    echo "::error::Refusing to build: the savedefconfig gate would reject our appended options."
    cat "$GKI_BC"
    exit 1
fi

echo "==> config alignment done"
