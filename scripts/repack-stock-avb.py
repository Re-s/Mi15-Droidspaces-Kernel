#!/usr/bin/env python3
"""Rebuild boot.img keeping the STOCK signed vbmeta blob, swapping only the kernel.

Why this shape and not avbtool re-signing (docs/RESEARCH.md §18):
This bootloader checks the embedded vbmeta SIGNATURE (against Xiaomi's AVB key,
pubkey sha1 de5be2a5...) but NOT the hash descriptor. Proof: the third-party
kernel found in the device's other slot (6.6.77 Coolapk@GCross-Droidspaces,
which boots) carries a vbmeta blob signed with Xiaomi's key whose hash
descriptor describes a DIFFERENT image (declared image size 37003264 vs actual
38031360). It cannot have been re-signed - Xiaomi's private key is not public -
so it is a verbatim copy of a stock blob with a stale hash.

Our earlier attempts failed accordingly:
  * testkey-signed blobs   -> signature not from Xiaomi's key -> rejected
  * zero tail              -> no signature at all             -> rejected
  * vbmeta partition flags -> does not gate the boot blob      -> rejected

Layout produced (identical in shape to both stock and the working GCross image):
  [4K header][kernel][zeros to 4K boundary][stock vbmeta blob 2368B][zeros][AVBf 64B]
with the footer's original_image_size and descriptor_offset pointing at the blob.
"""
import struct, sys, os

PART_SIZE = int(os.environ.get('BOOTIMG_PARTITION_SIZE', 100663296))
BLOB_SIZE = 2368
FOOTER_SIZE = 64


def read_stock(path):
    d = open(path, 'rb').read()
    if d[:8] != b'ANDROID!':
        sys.exit(f'::error::{path} is not a boot image')
    ft = d[len(d) - FOOTER_SIZE:]
    if ft[:4] != b'AVBf':
        sys.exit(f'::error::{path} has no AVB footer to borrow')
    magic, vmaj, vmin, orig, doff, dsz = struct.unpack('>4sIIQQQ', ft[:36])
    if dsz != BLOB_SIZE or doff != orig:
        sys.exit(f'::error::unexpected stock footer: orig={orig} doff={doff} dsz={dsz}')
    return d[orig:orig + BLOB_SIZE], ft


def main():
    if len(sys.argv) != 4:
        sys.exit('usage: repack-stock-avb.py <boot.img in/out> <stock-boot.img> <out.img>')
    src, stock_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    blob, stock_ft = read_stock(stock_path)

    d = open(src, 'rb').read()
    if d[:8] != b'ANDROID!':
        sys.exit(f'::error::{src} is not a boot image')
    ks = struct.unpack_from('<I', d, 8)[0]
    content = 4096 + ks
    # blob goes at the next 4K boundary after the kernel, exactly like both
    # stock (36870656 -> 36872192... stock pads more, GCross pads to +1 page)
    blob_off = (content + 4095) // 4096 * 4096
    img = bytearray(d[:content])
    img += b'\x00' * (blob_off - content)
    img += blob
    if len(img) > PART_SIZE - FOOTER_SIZE:
        sys.exit(f'::error::image too large: {len(img)} > {PART_SIZE - FOOTER_SIZE}')
    img += b'\x00' * (PART_SIZE - FOOTER_SIZE - len(img))
    # footer: same bytes as stock but pointing at our blob offset
    ft = bytearray(stock_ft)
    struct.pack_into('>Q', ft, 12, blob_off)   # original_image_size
    struct.pack_into('>Q', ft, 20, blob_off)   # descriptor_offset
    img += ft
    assert len(img) == PART_SIZE, len(img)
    open(out, 'wb').write(bytes(img))

    # verify what we wrote
    v = open(out, 'rb').read()
    assert v[:8] == b'ANDROID!'
    assert v[blob_off:blob_off + 4] == b'AVB0', 'blob not at declared offset'
    assert v[-64:-60] == b'AVBf', 'footer missing'
    o, do, ds = struct.unpack('>QQQ', v[PART_SIZE - 64 + 12:PART_SIZE - 64 + 36])
    assert o == do == blob_off and ds == BLOB_SIZE, (o, do, ds)
    print(f'    {os.path.basename(out)}: kernel {ks}B, stock-signed vbmeta @{blob_off}, '
          f'{len(v)//1048576} MiB')


if __name__ == '__main__':
    main()
