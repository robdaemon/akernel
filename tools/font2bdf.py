#!/usr/bin/env python3
"""Generate Sys:Fonts/font8x8.bdf from userspace/rts/akernel/font8x8.ads.

font8x8 is LSB-first (bit 0 = leftmost pixel); BDF bitmap rows are
MSB-first, so each row byte is bit-reversed here. Keeps the on-disk
font byte-identical in look to Trinket's compiled-in fallback, so
the BDF loader is exercised honestly against a known-good font.
"""
import re
import sys

def reverse_bits(b):
    r = 0
    for i in range(8):
        if b & (1 << i):
            r |= 1 << (7 - i)
    return r

def main():
    src = open(sys.argv[1]).read()
    entries = re.findall(
        r"'(.)'\s*=>\s*\(((?:\s*16#[0-9A-Fa-f]{2}#,){7}\s*16#[0-9A-Fa-f]{2}#)\)",
        src)
    if len(entries) != 95:
        sys.exit(f"expected 95 glyphs, parsed {len(entries)}")
    out = []
    out.append("STARTFONT 2.1")
    out.append("FONT -akernel-font8x8-medium-r-normal--8-80-75-75-c-80-iso10646-1")
    out.append("SIZE 8 75 75")
    out.append("FONTBOUNDINGBOX 8 8 0 -2")
    out.append("STARTPROPERTIES 2")
    out.append("FONT_ASCENT 6")
    out.append("FONT_DESCENT 2")
    out.append("ENDPROPERTIES")
    out.append(f"CHARS {len(entries)}")
    for ch, rows in entries:
        vals = [int(m, 16) for m in
                re.findall(r"16#([0-9A-Fa-f]{2})#", rows)]
        name = ch if ch not in " \\'" else f"quote{ord(ch)}"
        out.append(f"STARTCHAR {name}")
        out.append(f"ENCODING {ord(ch)}")
        out.append("SWIDTH 500 0")
        out.append("DWIDTH 8 0")
        out.append("BBX 8 8 0 -2")
        out.append("BITMAP")
        for v in vals:
            out.append(f"{reverse_bits(v):02X}")
        out.append("ENDCHAR")
    out.append("ENDFONT")
    print("\n".join(out))

if __name__ == "__main__":
    main()
