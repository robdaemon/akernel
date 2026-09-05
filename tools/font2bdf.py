#!/usr/bin/env python3
"""Generate Sys:Fonts/font8x8.bdf from userspace/rts/akernel/font8x8.ads.

font8x8 is LSB-first (bit 0 = leftmost pixel); BDF bitmap rows are
MSB-first, so each row byte is bit-reversed here. Keeps the on-disk
font byte-identical in look to Trinket's compiled-in fallback, so
the BDF loader is exercised honestly against a known-good font.

--proportional emits font8x8p.bdf instead: each glyph is trimmed to
its ink bounds and gets DWIDTH = ink width + 1 (space = 4), the
classic pseudo-proportional treatment. No new font data is shipped
(the glyphs stay the compiled-in 8x8 set, zero license risk); only
the metrics change.

--tall emits font8x8t.bdf: each row is replicated vertically (the
Bureau chrome Stretch trick) for an 8x16 variant — same family
font8x8, PIXEL_SIZE 16, so the Prefs/Font picker sees one family
with two sizes. font8x8p's trimmed metrics make it its own
family. FAMILY_NAME/PIXEL_SIZE properties are emitted so the
picker can group data-driven (Trinket.Fonts.Probe reads them).
"""
import re
import sys

def reverse_bits(b):
    r = 0
    for i in range(8):
        if b & (1 << i):
            r |= 1 << (7 - i)
    return r

def trim(vals):
    """Return (bitmap_bytes, width, dwidth) for a glyph, trimmed to
    ink bounds; vals are the 8 MSB-first row bytes."""
    ink = 0
    for v in vals:
        ink |= v
    if ink == 0:  # space: no ink, keep a word gap
        return vals, 1, 4
    left = 0
    while not ink & (0x80 >> left):
        left += 1
    right = 7
    while not ink & (0x80 >> right):
        right -= 1
    w = right - left + 1
    return [((v >> (7 - right)) & (0xFF >> (7 - right))) << (8 - w)
            for v in vals], w, w + 1

def main():
    prop = "--proportional" in sys.argv[2:]
    tall = "--tall" in sys.argv[2:]
    if prop and tall:
        sys.exit("--tall and --proportional don't combine (yet)")
    src = open(sys.argv[1]).read()
    entries = re.findall(
        r"'(.)'\s*=>\s*\(((?:\s*16#[0-9A-Fa-f]{2}#,){7}\s*16#[0-9A-Fa-f]{2}#)\)",
        src)
    if len(entries) != 95:
        sys.exit(f"expected 95 glyphs, parsed {len(entries)}")
    out = []
    size = 16 if tall else 8
    ascent = 12 if tall else 6
    descent = 4 if tall else 2
    out.append("STARTFONT 2.1")
    name = "font8x8p" if prop else ("font8x8t" if tall else "font8x8")
    out.append(f"FONT -akernel-{name}-medium-r-normal--{size}-80-75-75-c-80-iso10646-1")
    out.append(f"SIZE {size} 75 75")
    out.append(f"FONTBOUNDINGBOX 8 {size} 0 {-descent}")
    out.append("STARTPROPERTIES 4")
    #  font8x8t is the same typeface doubled — same family, its
    #  size distinguishes it. font8x8p's different metrics make
    #  it a different family for the picker.
    fam = "font8x8p" if prop else "font8x8"
    out.append(f'FAMILY_NAME "{fam}"')
    out.append(f"PIXEL_SIZE {size}")
    out.append(f"FONT_ASCENT {ascent}")
    out.append(f"FONT_DESCENT {descent}")
    out.append("ENDPROPERTIES")
    out.append(f"CHARS {len(entries)}")
    for ch, rows in entries:
        vals = [reverse_bits(int(m, 16)) for m in
                re.findall(r"16#([0-9A-Fa-f]{2})#", rows)]
        if prop:
            vals, w, dw = trim(vals)
        else:
            w, dw = 8, 8
        gname = ch if ch not in " \\'" else f"quote{ord(ch)}"
        out.append(f"STARTCHAR {gname}")
        out.append(f"ENCODING {ord(ch)}")
        out.append("SWIDTH 500 0")
        out.append(f"DWIDTH {dw} 0")
        out.append(f"BBX {w} {size} 0 {-descent}")
        out.append("BITMAP")
        for v in vals:
            out.append(f"{v:02X}")
            if tall:
                out.append(f"{v:02X}")
        out.append("ENDCHAR")
    out.append("ENDFONT")
    print("\n".join(out))

if __name__ == "__main__":
    main()
