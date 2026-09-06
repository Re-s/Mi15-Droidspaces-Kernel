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
    echo "==> building boot.img (header v$HEADER_VERSION, kernel only, GKI-signed)"

    python3 "$SCRIPT_DIR/mkbootimg.py" \
        --header_version "$HEADER_VERSION" \
        --kernel "$IMAGE" \
        --out "$OUTDIR/boot.img"

    # ------------------------------------------------------------ GKI signature
    # Replicates the stock Xiaomi 15 boot.img byte layout, reverse-engineered from
    # the user's own dump and verified field-for-field (docs/RESEARCH.md §15):
    #   [header page][kernel, page-padded][vbmeta 'boot'][vbmeta 'generic_kernel']
    #   [partition-level vbmeta + AVBf footer][zeros to partition size]
    #   * vbmeta 'boot'           digest = sha256(salt + header+kernel content)
    #   * vbmeta 'generic_kernel' digest = sha256(salt + raw kernel Image)
    #   * the partition-level hash footer also pads the image to the real
    #     partition size, so `fastboot flash boot` overwrites every stale byte.
    # For an identical kernel the generated digests are byte-identical to stock's
    # (same salt d00df00d, same ARCH/BRANCH/KERNEL_RELEASE descriptor set). The
    # signing key is the PUBLIC AOSP AVB test key: an unlocked bootloader skips
    # verification, so Xiaomi's release key is not needed — the goal is that the
    # image parses exactly like stock instead of being an unsigned 35 MB oddity.
    AVB="$SCRIPT_DIR/avb/avbtool.py"
    KEY="$SCRIPT_DIR/avb/testkey_rsa4096.pem"
    PART_SIZE="${BOOTIMG_PARTITION_SIZE:-100663296}"   # 96 MiB, stock boot partition
    command -v openssl >/dev/null 2>&1 \
        || { echo "::error::openssl is required to sign boot.img"; exit 1; }
    [ -f "$AVB" ] && [ -f "$KEY" ] \
        || { echo "::error::vendored avbtool or test key missing"; exit 1; }

    SIG="$OUTDIR/.sigs"; mkdir -p "$SIG"
    for np in "boot:$OUTDIR/boot.img" "generic_kernel:$IMAGE"; do
        name="${np%%:*}"; img="${np#*:}"
        python3 "$AVB" add_hash_footer \
            --partition_name "$name" --dynamic_partition_size \
            --image "$img" --algorithm SHA256_RSA4096 --key "$KEY" \
            --salt d00df00d \
            --prop ARCH:arm64 --prop BRANCH: --prop "KERNEL_RELEASE:$KVER" \
            --do_not_append_vbmeta_image --output_vbmeta_image "$SIG/$name.bin"
    done
    cat "$SIG/boot.bin" "$SIG/generic_kernel.bin" >> "$OUTDIR/boot.img"

    # Partition-level hash footer; also pads the image to $PART_SIZE.
    python3 "$AVB" add_hash_footer \
        --partition_name boot --partition_size "$PART_SIZE" \
        --image "$OUTDIR/boot.img" --algorithm SHA256_RSA4096 --key "$KEY" \
        --salt d00df00d \
        --prop ARCH:arm64 --prop BRANCH: --prop "KERNEL_RELEASE:$KVER"
    rm -rf "$SIG"

    # ------------------------------------------------------------------- verify
    python3 - "$OUTDIR/boot.img" "$KVER" "$IMAGE" "$PART_SIZE" <<'PY'
import hashlib, struct, sys
boot, kver, image, part_s = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = open(boot, 'rb').read()
assert d[:8] == b'ANDROID!', 'bad magic'
ks, rs = struct.unpack_from('<2I', d, 8)
hv, = struct.unpack_from('<I', d, 40)
assert hv == 4, f'header_version {hv} != 4'
assert rs == 0, f'ramdisk_size {rs} != 0 (boot carries kernel only)'
assert ks > 1_000_000, f'kernel_size {ks} implausible'
assert len(d) == part_s, f'image is {len(d)} bytes, expected partition size {part_s}'
assert kver.encode() in d[:4096 + ks], 'kernel version string not found'

# embedded signature region: two vbmetas right after the padded kernel
content = 4096 + -(-ks // 4096) * 4096
assert d[content:content + 4] == b'AVB0', 'embedded boot signature missing'
assert d[content + 2240:content + 2244] == b'AVB0', 'embedded generic_kernel signature missing'
assert d[-64:-60] == b'AVBf', 'partition-level AVB footer missing'

# digest parity: recompute what the descriptors claim
salt = bytes.fromhex('d00df00d')
def hash_digest(vb):
    auth, aux = struct.unpack_from('!2Q', vb, 12)
    do, ds = struct.unpack_from('!2Q', vb, 96)
    a = vb[256 + auth:256 + auth + aux]
    p = do
    while p < do + ds:
        tag, nbf = struct.unpack_from('!QQ', a, p)
        body = a[p + 16:p + 16 + nbf]
        if tag == 2:
            isz, alg, nl, sl, dl, fl = struct.unpack_from('!Q32sLLLL', body, 0)
            o = 116
            return (body[o:o + nl].decode(), isz, body[o + nl:o + nl + sl],
                    body[o + nl + sl:o + nl + sl + dl])
        p += 16 + nbf
    return None

hd = hash_digest(d[content:])                       # 'boot'
assert hd[0] == 'boot' and hd[1] == content, 'boot descriptor mismatch'
assert hashlib.sha256(hd[2] + d[:content]).digest() == hd[3], 'boot digest mismatch'

gk = hash_digest(d[content + 2240:])                # 'generic_kernel'
raw = open(image, 'rb').read()
assert gk[0] == 'generic_kernel' and gk[1] == len(raw), 'generic_kernel descriptor mismatch'
assert hashlib.sha256(gk[2] + raw).digest() == gk[3], 'generic_kernel digest mismatch'

print(f'    boot.img OK: header v{hv}, kernel {ks} bytes, {len(d)//1048576} MiB, '
      f'GKI-signed (boot+generic_kernel+footer), digests verified')
PY
    ls -lh "$OUTDIR/boot.img"
fi

# --------------------------------------------------------------- AnyKernel3
if has anykernel; then
    echo "==> building AnyKernel3 zip"
    # Prefer the persistent cache dir when CI provides one; /tmp is not preserved.
    AK3="${AK3_DIR:-${SRC_CACHE:+$SRC_CACHE/AnyKernel3}}"
    AK3="${AK3:-/tmp/AnyKernel3}"
    if [ -d "$AK3/.git" ]; then
        echo "    AnyKernel3 cache HIT"
        git -C "$AK3" reset -q --hard && git -C "$AK3" clean -qfd
    else
        echo "    AnyKernel3 cache MISS - cloning"
        rm -rf "$AK3"; mkdir -p "$(dirname "$AK3")"
        git clone --depth=1 -q https://github.com/osm0sis/AnyKernel3 "$AK3"
    fi
    # Build in a scratch copy so the cached clone keeps its .git for the next run.
    # Keep it OUTSIDE $OUTDIR: anything left in there gets picked up by
    # upload-artifact, and an early `exit 1` would skip a cleanup line at the end.
    AK3_WORK="$(mktemp -d)"
    trap 'rm -rf "$AK3_WORK"' EXIT
    cp -a "$AK3/." "$AK3_WORK/"
    rm -rf "$AK3_WORK/.git"
    AK3="$AK3_WORK"
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
    #
    # NB: `grep -q` exits on its first match, which SIGPIPEs the upstream `unzip`/
    # `strings`. Under `pipefail` that makes the whole pipeline return 141 even though
    # the content is correct — a false failure that depends on where in the file the
    # match happens to land. Use `grep -c` on a fully-consumed stream instead.
    ak_sh="$(unzip -p "$AKZIP" anykernel.sh)"
    case "$ak_sh" in
        *"BLOCK=boot"*) : ;;
        *) echo "::error::anykernel.sh missing BLOCK=boot"; exit 1 ;;
    esac
    case "$ak_sh" in
        *split_boot*|*flash_boot*) : ;;
        *) echo "::error::anykernel.sh missing install calls"; exit 1 ;;
    esac
    hits="$(unzip -p "$AKZIP" Image | strings | grep -c "$KVER" || true)"
    [ "${hits:-0}" -gt 0 ] \
        || { echo "::error::wrong Image packed into zip (version $KVER not found)"; exit 1; }
    echo "    AnyKernel3 OK"
    ls -lh "$AKZIP"
    rm -rf "$AK3_WORK"; trap - EXIT
fi

# --------------------------------------------------------------- raw Image
if has image; then
    cp -f "$IMAGE" "$OUTDIR/Image-${BASE}"
    echo "==> raw Image: $OUTDIR/Image-${BASE}"
fi

echo "==> artifacts in $OUTDIR:"
ls -lh "$OUTDIR"
