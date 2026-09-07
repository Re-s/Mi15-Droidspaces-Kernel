#!/usr/bin/env python3
"""Verify a packaged boot.img: header shape, kernel identity, AVB tail sanity."""
import struct, sys
boot, kver, image, part_s = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = open(boot, 'rb').read()
raw = open(image, 'rb').read()
assert d[:8] == b'ANDROID!', 'bad magic'
ks, rs = struct.unpack_from('<2I', d, 8)
hv, = struct.unpack_from('<I', d, 40)
assert hv == 4, f'header_version {hv} != 4'
assert rs == 0, f'ramdisk_size {rs} != 0 (boot carries kernel only)'
assert ks == len(raw), f'kernel_size {ks} != source Image {len(raw)}'
assert d[4096:4096 + ks] == raw, 'kernel payload differs from source Image'
assert len(d) == part_s, f'image is {len(d)} bytes, expected partition size {part_s}'
assert kver.encode() in d[:4096 + ks], 'kernel version string not found'
mode = 'no AVB tail'
if d[-64:-60] == b'AVBf':
    orig, doff, dsz = struct.unpack('>QQQ', d[part_s - 64 + 12:part_s - 64 + 36])
    assert orig == doff and dsz == 2368, f'footer offsets bogus: {orig} {doff} {dsz}'
    assert doff % 4096 == 0, 'vbmeta blob not 4K aligned'
    assert 4096 + ks <= doff, 'kernel overlaps the vbmeta blob'
    assert d[doff:doff + 4] == b'AVB0', 'no vbmeta blob at the declared offset'
    mode = f'stock-signed vbmeta @{doff}'
print(f'    boot.img OK: header v{hv}, kernel {ks} bytes, {len(d)//1048576} MiB, {mode}')
