#!/usr/bin/env bash
# Post-build gate: assert the produced Image is actually flashable on this device.
#
# The checks below are the ones that catch "it compiled, then bricked the phone":
# the config that ends up inside the Image is the only source of truth, so we read
# it back out of CONFIG_IKCONFIG rather than trusting the defconfig we wrote.
set -euo pipefail

KROOT="${1:?usage: verify-build.sh <repo-root>}"

IMG="$KROOT/bazel-bin/common/kernel_aarch64/Image"
[ -f "$IMG" ] || IMG="$(find "$KROOT" -name Image -path '*kernel_aarch64*' -not -path '*/dist/*' 2>/dev/null | head -n1)"
[ -f "$IMG" ] || { echo "::error::built Image not found"; exit 1; }
echo "==> Image: $IMG ($(stat -c%s "$IMG") bytes)"

# NB: no `grep -m1` upstream of a pipe here. Under `set -o pipefail`, grep exiting
# early makes `strings` die of SIGPIPE and the whole substitution returns 141.
KVER="$(strings "$IMG" | grep -oE 'Linux version [0-9][^ ]*' | head -n1 | cut -d' ' -f3)"
[ -n "$KVER" ] || { echo "::error::no kernel version string in Image"; exit 1; }
echo "==> version: $KVER"

# KMI generation must stay android15-8 or vendor modules will refuse to load.
case "$KVER" in
    *-android15-8*) echo "    KMI android15-8 OK" ;;
    *) echo "::error::KMI drifted: expected -android15-8 in '$KVER'"; exit 1 ;;
esac

# Read the config back out of the Image (CONFIG_IKCONFIG payload).
CFG=/tmp/built.config
python3 - "$IMG" "$CFG" <<'PY'
import sys, zlib
img, out = sys.argv[1], sys.argv[2]
d = open(img, 'rb').read()
i = d.find(b'IKCFG_ST')
if i < 0:
    sys.exit("::error::no IKCFG_ST in Image (CONFIG_IKCONFIG disabled?)")
start = i + 8
if d[start:start+3] != b'\x1f\x8b\x08':
    sys.exit("::error::IKCFG_ST not followed by gzip stream")
cfg = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(d[start:])
open(out, 'wb').write(cfg)
print(f"    extracted in-Image config: {len(cfg)} bytes")
PY

need_y()  { grep -q "^CONFIG_$1=y$"          "$CFG" || { echo "::error::CONFIG_$1 must be =y"; exit 1; }; }
need_off(){ grep -q "^# CONFIG_$1 is not set$" "$CFG" || { echo "::error::CONFIG_$1 must be off"; exit 1; }; }

# 1. Stock environment parity - mismatches here mean vendor_dlkm CRC failures.
need_y CFI_CLANG
need_y LTO_NONE
echo "    LTO_NONE + CFI_CLANG match stock"

# 2. WiFi/BT lifeline: this gate must be OFF in a self-signed kernel.
need_off MODULE_SIG_PROTECT
echo "    MODULE_SIG_PROTECT off (system_dlkm loadable)"

# 3. 4K pages: a page-size mismatch against the vendor partitions does not boot.
need_y ARM64_4K_PAGES
echo "    4K pages OK"

# 4. Droidspaces mandatory set (only when it was requested).
if [ "${USE_DROIDSPACES:-true}" = "true" ]; then
    for c in SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS CGROUP_DEVICE \
             NAMESPACES UTS_NS NET_NS OVERLAY_FS SECCOMP_FILTER; do
        need_y "$c"
    done
    echo "    Droidspaces mandatory configs present"
    # And the kABI patch must be what made SYSVIPC safe.
    grep -q '^CONFIG_ANDROID_KABI_RESERVE=y$' "$CFG" \
        || echo "::warning::ANDROID_KABI_RESERVE not =y; kABI padding may not be in effect"
fi

# 5. Root flavor consistency.
case "${ROOT_FLAVOR:-}" in
  ksu-next|sukisu)
      need_y KSU
      echo "    CONFIG_KSU=y"
      [ "${USE_SUSFS:-true}" = "true" ] && { need_y KSU_SUSFS; echo "    CONFIG_KSU_SUSFS=y"; }
      if [ "${USE_KPM:-false}" = "true" ] && [ "${ROOT_FLAVOR}" = "sukisu" ]; then
          need_y KPM; echo "    CONFIG_KPM=y"
      fi
      ;;
  none)
      if grep -qE '^CONFIG_(KSU|KPM)=[ym]$' "$CFG"; then
          echo "::error::ROOT_FLAVOR=none but KSU/KPM is enabled"; exit 1
      fi
      echo "    no root, as requested"
      ;;
esac

echo "image=$IMG"   >>"${GITHUB_OUTPUT:-/dev/null}"
echo "kver=$KVER"   >>"${GITHUB_OUTPUT:-/dev/null}"
echo "==> all build gates passed"
