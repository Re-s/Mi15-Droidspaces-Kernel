#!/usr/bin/env bash
# Package a built GKI Image into flashable artifacts.
#
# Outputs (controlled by $FORMATS, a comma list of: bootimg,anykernel,image):
#   boot.img                  <- fastboot flash boot   (primary: quickest boot test)
#   AnyKernel3-*.zip          <- flash from recovery / KSU / SukiSU manager
#   Image                     <- raw kernel, for manual repacking
#
# Why mkbootimg rather than magiskboot:
# The Xiaomi 15 boot partition (verified on the user's own dump) is header v4 with
# ramdisk_size=0 — boot carries ONLY the kernel. The generic ramdisk lives on
# init_boot and the vendor ramdisk on vendor_boot, so nothing has to be preserved
# from the original image. A boot.img can therefore be synthesized from scratch,
# which removes the need for a magiskboot binary and for the user's stock dump.
# Verified: mkbootimg output matches the stock header field-for-field
# (magic/kernel_size/ramdisk_size/header_size/header_version/cmdline).
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE=/path/to/Image}"
OUTDIR="${OUTDIR:-$PWD/artifacts}"
FORMATS="${FORMATS:-bootimg,anykernel,image}"
KERNEL_NAME="${KERNEL_NAME:-Mi15-Droidspaces}"
ROOT_FLAVOR="${ROOT_FLAVOR:-none}"
HEADER_VERSION="${HEADER_VERSION:-4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$IMAGE" ] || { echo "::error::Image not found: $IMAGE"; exit 1; }
mkdir -p "$OUTDIR"

# NB: `head -n1`, not `grep -m1`: with pipefail an early grep exit kills `strings`
# with SIGPIPE, and the substitution would return 141 / an empty version.
KVER="$(strings "$IMAGE" | grep -oE 'Linux version [0-9][^ ]*' | head -n1 | cut -d' ' -f3)"
[ -n "$KVER" ] || { echo "::error::cannot read kernel version from $IMAGE (not a kernel Image?)"; exit 1; }
echo "==> kernel:  $KVER"
echo "==> formats: $FORMATS"
BASE="${KERNEL_NAME}-${KVER}"

has() { case ",$FORMATS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ------------------------------------------------------------------ boot.img
if has bootimg; then
    echo "==> building boot.img (header v$HEADER_VERSION, kernel only)"
    python3 "$SCRIPT_DIR/mkbootimg.py" \
        --header_version "$HEADER_VERSION" \
        --kernel "$IMAGE" \
        --out "$OUTDIR/boot.img"

    # Verify what we produced: header must match the stock layout, and the image
    # must actually contain the kernel we just built.
    python3 - "$OUTDIR/boot.img" "$KVER" <<'PY'
import struct, sys
p, kver = sys.argv[1], sys.argv[2]
d = open(p, 'rb').read()
assert d[:8] == b'ANDROID!', 'bad magic'
ks, rs, osv, hsz = struct.unpack_from('<4I', d, 8)
hv, = struct.unpack_from('<I', d, 40)
assert hv == 4, f'header_version {hv} != 4'
assert rs == 0, f'ramdisk_size {rs} != 0 (boot should carry kernel only)'
assert ks > 1_000_000, f'kernel_size {ks} implausible'
assert kver.encode() in d, 'built kernel version string not found in boot.img'
print(f'    boot.img OK: header v{hv}, kernel {ks} bytes, ramdisk {rs}')
PY
    ls -lh "$OUTDIR/boot.img"
fi

# --------------------------------------------------------------- AnyKernel3
if has anykernel; then
    echo "==> building AnyKernel3 zip"
    AK3="${AK3_DIR:-/tmp/AnyKernel3}"
    if [ ! -d "$AK3" ]; then
        git clone --depth=1 -q https://github.com/osm0sis/AnyKernel3 "$AK3"
    fi
    rm -rf "$AK3/.git"
    cp -f "$IMAGE" "$AK3/Image"

    # Uppercase variable style: this is what the KSU/SukiSU in-app flashers parse.
    cat >"$AK3/anykernel.sh" <<AKSH
### AnyKernel3 Ramdisk Mod Script
## $KERNEL_NAME for Xiaomi 15 (dada) - GKI android15-6.6

properties() { '
kernel.string=$KERNEL_NAME $KVER (Droidspaces + $ROOT_FLAVOR)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=dada
device.name2=Xiaomi 15
device.name3=xiaomi15
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
BLOCK=boot
IS_SLOT_DEVICE=auto
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto
NO_MAGISK_CHECK=1

. tools/ak3-core.sh

sync
sleep 0.5
chmod -R 755 \$AKHOME/tools

ui_print " Installing $KERNEL_NAME $KVER"
ui_print " boot holds the kernel only; init_boot / vendor_boot untouched"

split_boot
if [ -f "split_img/ramdisk.cpio" ]; then
    unpack_ramdisk
    write_boot
else
    flash_boot
fi

ui_print " Done."
AKSH

    AKZIP="$OUTDIR/AnyKernel3-${BASE}.zip"
    chmod +x "$AK3/tools/"* "$AK3/META-INF/com/google/android/update-binary" 2>/dev/null || true
    ( cd "$AK3" && zip -r9 -q "$AKZIP" . -x '.git/*' )

    # Verify the zip: right kernel inside, install hooks present.
    unzip -p "$AKZIP" anykernel.sh | grep -q '^BLOCK=boot' \
        || { echo "::error::anykernel.sh missing BLOCK=boot"; exit 1; }
    unzip -p "$AKZIP" anykernel.sh | grep -qE 'split_boot|flash_boot' \
        || { echo "::error::anykernel.sh missing install calls"; exit 1; }
    unzip -p "$AKZIP" Image | strings | grep -q "$KVER" \
        || { echo "::error::wrong Image packed into zip"; exit 1; }
    echo "    AnyKernel3 OK"
    ls -lh "$AKZIP"
fi

# --------------------------------------------------------------- raw Image
if has image; then
    cp -f "$IMAGE" "$OUTDIR/Image-${BASE}"
    echo "==> raw Image: $OUTDIR/Image-${BASE}"
fi

echo "==> artifacts in $OUTDIR:"
ls -lh "$OUTDIR"
