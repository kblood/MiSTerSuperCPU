#!/usr/bin/env python3
"""Decode the 4x6 yellow overlay in MiSTer C64 screenshots.

PNGs from /dev/MiSTer_cmd 'screenshot' are 382x540 (1x horizontal,
~2x vertical scaling). Overlay box in source coordinates: X 4..114,
Y 6..30, with 22 cells (5px wide, last px is gap) x 4 rows (6px).

Lit pixels are RGB (255,240,64) yellow. We sample one pixel per
4x6 glyph slot, build a 24-bit signature, and match against the
font table from debug_font_4x6.sv.
"""
import sys
from PIL import Image

# Font table copied from debug_font_4x6.sv. Each entry is 24-bit
# packed {row0,row1,row2,row3,row4,row5}, 4 bits MSB=left per row.
FONT = {
    0:  0x69BD96, 1:  0x262227, 2:  0x69248F, 3:  0xE16196, 4:  0x26AF22,
    5:  0xF8E196, 6:  0x68E996, 7:  0xF12244, 8:  0x6969_96, 9:  0x69_976_6 & 0xFFFFFF,
}

# Rebuild via the same packing as the SV (avoid manual hex errors)
def pack(rows):
    v = 0
    for r in rows:
        v = (v << 4) | r
    return v

GLYPH_ROWS = {
    0:  [0b0110, 0b1001, 0b1011, 0b1101, 0b1001, 0b0110],
    1:  [0b0010, 0b0110, 0b0010, 0b0010, 0b0010, 0b0111],
    2:  [0b0110, 0b1001, 0b0010, 0b0100, 0b1000, 0b1111],
    3:  [0b1110, 0b0001, 0b0110, 0b0001, 0b1001, 0b0110],
    4:  [0b0010, 0b0110, 0b1010, 0b1111, 0b0010, 0b0010],
    5:  [0b1111, 0b1000, 0b1110, 0b0001, 0b1001, 0b0110],
    6:  [0b0110, 0b1000, 0b1110, 0b1001, 0b1001, 0b0110],
    7:  [0b1111, 0b0001, 0b0010, 0b0010, 0b0100, 0b0100],
    8:  [0b0110, 0b1001, 0b0110, 0b1001, 0b1001, 0b0110],
    9:  [0b0110, 0b1001, 0b1001, 0b0111, 0b0001, 0b0110],
    10: [0b0110, 0b1001, 0b1001, 0b1111, 0b1001, 0b1001],  # A
    11: [0b1110, 0b1001, 0b1110, 0b1001, 0b1001, 0b1110],  # B
    12: [0b0110, 0b1001, 0b1000, 0b1000, 0b1001, 0b0110],  # C
    13: [0b1110, 0b1001, 0b1001, 0b1001, 0b1001, 0b1110],  # D
    14: [0b1111, 0b1000, 0b1110, 0b1000, 0b1000, 0b1111],  # E
    15: [0b1111, 0b1000, 0b1110, 0b1000, 0b1000, 0b1000],  # F
    16: [0b0110, 0b1001, 0b1000, 0b1011, 0b1001, 0b0111],  # G
    17: [0b1001, 0b1001, 0b1111, 0b1001, 0b1001, 0b1001],  # H
    18: [0b1110, 0b0100, 0b0100, 0b0100, 0b0100, 0b1110],  # I
    19: [0b0001, 0b0001, 0b0001, 0b0001, 0b1001, 0b0110],  # J
    20: [0b1001, 0b1010, 0b1100, 0b1100, 0b1010, 0b1001],  # K
    21: [0b1000, 0b1000, 0b1000, 0b1000, 0b1000, 0b1111],  # L
    22: [0b1001, 0b1111, 0b1111, 0b1001, 0b1001, 0b1001],  # M
    23: [0b1001, 0b1101, 0b1111, 0b1011, 0b1001, 0b1001],  # N
    24: [0b0110, 0b1001, 0b1001, 0b1001, 0b1001, 0b0110],  # O
    25: [0b1110, 0b1001, 0b1001, 0b1110, 0b1000, 0b1000],  # P
    26: [0b0110, 0b1001, 0b1001, 0b1001, 0b1011, 0b0111],  # Q
    27: [0b1110, 0b1001, 0b1001, 0b1110, 0b1010, 0b1001],  # R
    28: [0b0111, 0b1000, 0b0110, 0b0001, 0b0001, 0b1110],  # S
    29: [0b1111, 0b0100, 0b0100, 0b0100, 0b0100, 0b0100],  # T
    30: [0b1001, 0b1001, 0b1001, 0b1001, 0b1001, 0b0110],  # U
    31: [0b1001, 0b1001, 0b1001, 0b1001, 0b0110, 0b0110],  # V
    32: [0b1001, 0b1001, 0b1001, 0b1111, 0b1111, 0b1001],  # W
    33: [0b1001, 0b1001, 0b0110, 0b0110, 0b1001, 0b1001],  # X
    34: [0b1001, 0b1001, 0b1001, 0b0110, 0b0100, 0b0100],  # Y
    35: [0b1111, 0b0001, 0b0010, 0b0100, 0b1000, 0b1111],  # Z
    36: [0]*6,                                             # space
    37: [0b0000, 0b0010, 0b0000, 0b0000, 0b0010, 0b0000],  # :
    38: [0b0000, 0b0000, 0b0000, 0b0000, 0b0000, 0b1111],  # _
    39: [0b0000, 0b1111, 0b0000, 0b1111, 0b0000, 0b0000],  # =
}

GLYPH_CHAR = {
    **{i: str(i) for i in range(10)},
    **{10+i: chr(ord('A')+i) for i in range(26)},
    36: ' ', 37: ':', 38: '_', 39: '=',
}

def signature(rows):
    v = 0
    for r in rows:
        v = (v << 4) | (r & 0xF)
    return v

GLYPH_BY_SIG = {signature(rows): gid for gid, rows in GLYPH_ROWS.items()}

# Overlay geometry in source coords
OVR_X0 = 4
OVR_Y0 = 6
CELL_W = 5
CELL_H = 6
ROWS = 11    # 2026-04-30 v211: 11 rows; rows 9-10 hold PC ring buffer trace
COLS = 22

# Lit color
LIT_R, LIT_G, LIT_B = 0xFF, 0xF0, 0x40
LIT_TOL = 64  # tolerance per channel

def is_lit(rgb):
    r, g, b = rgb[:3]
    return (abs(r - LIT_R) < LIT_TOL and
            abs(g - LIT_G) < LIT_TOL and
            abs(b - LIT_B) < LIT_TOL)

def decode(path, verbose=False):
    img = Image.open(path).convert('RGB')
    W, H = img.size
    px = img.load()
    # Empirically located overlay box in PNG coords:
    # x 5..108 (22 cells × 5 px), y 10..57 (4 rows × 12 px = 6 src rows × 2)
    OVR_PNG_X0 = 5
    OVR_PNG_Y0 = 10
    CELL_PNG_W = 5
    CELL_PNG_H = 12
    out = []
    for cy in range(ROWS):
        line = ''
        for cx in range(COLS):
            rows = []
            for ry in range(CELL_H):  # 6 source rows
                row_bits = 0
                for rx in range(4):
                    sample_x = OVR_PNG_X0 + cx * CELL_PNG_W + rx
                    # sy = 2; sample at the middle of the 2-px-tall band
                    sample_y = OVR_PNG_Y0 + cy * CELL_PNG_H + ry * 2 + 1
                    if 0 <= sample_x < W and 0 <= sample_y < H:
                        bit = 1 if is_lit(px[sample_x, sample_y]) else 0
                    else:
                        bit = 0
                    row_bits = (row_bits << 1) | bit
                rows.append(row_bits)
            sig = signature(rows)
            gid = GLYPH_BY_SIG.get(sig, None)
            if gid is None:
                # Fuzzy match — pick glyph with min hamming distance
                best = (999, 36)
                for g, gr in GLYPH_ROWS.items():
                    gs = signature(gr)
                    d = bin(gs ^ sig).count('1')
                    if d < best[0]:
                        best = (d, g)
                gid = best[1]
                if verbose and best[0] > 4:
                    print(f"  cell ({cy},{cx}) sig={sig:06X} fuzzy->{GLYPH_CHAR[gid]} (d={best[0]})")
            line += GLYPH_CHAR[gid]
        out.append(line.rstrip())
    return out

if __name__ == '__main__':
    for path in sys.argv[1:]:
        print(f"=== {path} ===")
        for r, line in enumerate(decode(path)):
            print(f"  R{r}: {line}")
        print()
