#!/usr/bin/env python3
#  Deterministic BMP assets for the Trinket.Images suite + tdemo
#  showcase (milestone 63). Formulas are duplicated in the fuzz
#  checks; change one side, change the other.
import struct, sys, os

def bmp24(path, w, h, pix, topdown=False):
    """pix(x, y) -> (r, g, b); y=0 is the TOP row."""
    stride = (w * 3 + 3) & ~3
    rows = []
    ys = range(h) if topdown else range(h - 1, -1, -1)
    for y in ys:
        row = bytearray()
        for x in range(w):
            r, g, b = pix(x, y)
            row += bytes((b, g, r))
        row += b'\0' * (stride - w * 3)
        rows.append(bytes(row))
    data = b''.join(rows)
    hdr = b'BM' + struct.pack('<IHHI', 54 + len(data), 0, 0, 54)
    info = struct.pack('<IiiHHIIiiII', 40, w, -h if topdown else h,
                       1, 24, 0, len(data), 2835, 2835, 0, 0)
    open(path, 'wb').write(hdr + info + data)

def bmp32(path, w, h, pix):
    """32-bit BI_RGB, top-down (negative height). pix -> (r,g,b,a)."""
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r, g, b, a = pix(x, y)
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    data = b''.join(rows)
    hdr = b'BM' + struct.pack('<IHHI', 54 + len(data), 0, 0, 54)
    info = struct.pack('<IiiHHIIiiII', 40, w, -h, 1, 32, 0,
                       len(data), 2835, 2835, 0, 0)
    open(path, 'wb').write(hdr + info + data)

#  BARS.BMP: 64x48 bottom-up 24-bit; 8 vertical bars, 8 px wide.
#  bar i: R = 32i+16, G = 239-32i, B = 128.
def bars(x, y):
    i = x // 8
    return (32 * i + 16, 239 - 32 * i, 128)

#  KEYED.BMP: 32x32 bottom-up 24-bit; magenta field, orange disc
#  radius 10 centred (15.5, 15.5): orange if (x-15)^2+(y-15)^2 <= 100
#  (integer form; centre pixel (15,15) orange, corners magenta).
KEY_R, KEY_G, KEY_B = 255, 0, 255
def keyed(x, y):
    if (x - 15) ** 2 + (y - 15) ** 2 <= 100:
        return (255, 136, 0)
    return (KEY_R, KEY_G, KEY_B)

#  GRAD32.BMP: 40x30 top-down 32-bit; R=6x, G=8y, B=200,
#  A=(x+y)&0xFF.
def grad(x, y):
    return ((6 * x) & 0xFF, (8 * y) & 0xFF, 200, (x + y) & 0xFF)

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
bmp24(os.path.join(out, 'bars.bmp'), 64, 48, bars)
bmp24(os.path.join(out, 'keyed.bmp'), 32, 32, keyed)
bmp32(os.path.join(out, 'grad32.bmp'), 40, 30, grad)
#  TRUNC.BMP: valid BARS header, data cut at 100 bytes.
full = open(os.path.join(out, 'bars.bmp'), 'rb').read()
open(os.path.join(out, 'trunc.bmp'), 'wb').write(full[:100])
print('gen_images: bars/keyed/grad32/trunc ->', out)
