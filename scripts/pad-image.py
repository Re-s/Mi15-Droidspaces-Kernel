#!/usr/bin/env python3
"""Zero-pad an image to the partition size."""
import sys
path, size = sys.argv[1], int(sys.argv[2])
d = open(path, 'rb').read()
if len(d) < size:
    open(path, 'wb').write(d + b'\x00' * (size - len(d)))
