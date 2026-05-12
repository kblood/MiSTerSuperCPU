#!/usr/bin/env python3
"""Build paint_diag.prg — diagnostic for the rows-4-5-invisible puzzle.

Paints 6 screen rows with 6 hardcoded distinct screen codes,
each easy to distinguish visually:
  row 0: $01 ('A')
  row 1: $02 ('B')
  row 2: $03 ('C')
  row 3: $04 ('D')
  row 4: $05 ('E')
  row 5: $06 ('F')

Plus colour RAM = $01 (white) for each row.

If we see AAAA / BBBB / CCCC / DDDD / EEEE / FFFF as 6 distinct rows,
the paint_row helper itself is sound — the reu_superram_integrity_spin
rows-4-5-invisible was about $F4/$F5 holding $20-ish values, not paint.

If we still only see 4 rows, paint_row has a structural issue (e.g.,
BNE offsets near boundary, or the multi-loop sequence breaks at #5).
"""
import os, struct, sys

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08,0x00,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
    code += stub

    def addr_of(o): return 0x0801 + o
    def emit(*bs): code.extend(bs)

    assert addr_of(len(code)) == 0x080D

    emit(0x78, 0x18, 0xFB)            # SEI; CLC; XCE → native
    emit(0xEA, 0xEA, 0xEA, 0xEA)      # absorb XCE drop+scramble
    emit(0xC2, 0x10)                  # REP #$10  (X=16-bit)
    emit(0xE2, 0x20)                  # SEP #$20  (M=8-bit)

    def paint_row(value, scr_lo, scr_hi, col_lo, col_hi):
        emit(0xA9, value)             # LDA #value
        emit(0xA2, 0x00, 0x00)        # LDX #$0000
        lp = addr_of(len(code))
        emit(0x9D, scr_lo, scr_hi)    # STA scr,X
        emit(0xE8)                    # INX
        emit(0xE0, 0x28, 0x00)        # CPX #$0028
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (lp - bpc) & 0xFF)
        emit(0xA9, 0x01)              # LDA #$01 (white)
        emit(0xA2, 0x00, 0x00)
        lpc = addr_of(len(code))
        emit(0x9D, col_lo, col_hi)
        emit(0xE8)
        emit(0xE0, 0x28, 0x00)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (lpc - bpc) & 0xFF)

    paint_row(0x01, 0x00, 0x04, 0x00, 0xD8)   # row 0: AAAA
    paint_row(0x02, 0x28, 0x04, 0x28, 0xD8)   # row 1: BBBB
    paint_row(0x03, 0x50, 0x04, 0x50, 0xD8)   # row 2: CCCC
    paint_row(0x04, 0x78, 0x04, 0x78, 0xD8)   # row 3: DDDD
    paint_row(0x05, 0xA0, 0x04, 0xA0, 0xD8)   # row 4: EEEE
    paint_row(0x06, 0xC8, 0x04, 0xC8, 0xD8)   # row 5: FFFF

    # Border = $07 (yellow) for instant visual confirmation
    emit(0xA9, 0x07); emit(0x8D, 0x20, 0xD0)
    emit(0xA9, 0x00); emit(0x8D, 0x21, 0xD0)  # bg black for contrast

    # Spin
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'paint_diag.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')

if __name__ == '__main__':
    sys.exit(main() or 0)
