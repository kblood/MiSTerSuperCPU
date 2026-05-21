#!/usr/bin/env python3
"""Build reu_peek_doom.prg — read 6 known bytes from doom.reu in REU SDRAM.

Workflow:
  1. Load doom.mgl via /dev/MiSTer_cmd pipe — populates REU SDRAM
     with doom.reu (16 MB), persists across subsequent core reloads.
  2. Load THIS PRG via its own MGL — RBF reloads but REU SDRAM survives.
  3. PRG does 6 REU FETCH ops (length=1 each) reading bytes from known
     doom.reu offsets into zero-page $F0-$F5.
  4. Paint 6 rows with $F0-$F5 + border = $F0.

Expected vs hardware-read:
  offset $200000 → $78  (start of bank $20 = Doom code 'SEI')
  offset $200001 → $D8  (CLD)
  offset $400000 → $FF  (bank $40 first byte)
  offset $400001 → $8C
  offset $800000 → $53  ('S' — "SCPUMIPS" marker)
  offset $800001 → $43  ('C')

If hardware-read matches: REU read path is delivering doom.reu correctly.
If hardware-read does NOT match: we've localised the music_num=-9 producer
to REU read corruption — narrows the bug to either REU SDRAM contents OR
REU FETCH machinery.

Visual interpretation:
  row 0: '$78' chars (= ⇣ or similar PETSCII)
  row 1: '$D8' chars
  row 2: '$FF' chars (π)
  row 3: '$8C' chars
  row 4: '$53' chars ('S' in screen code)
  row 5: '$43' chars ('C' in screen code)

Each row should render as a distinct band.
"""
import os, struct, sys

# (REU offset 24-bit, destination zero-page slot)
PROBES = [
    (0x200000, 0xF0),
    (0x200001, 0xF1),
    (0x400000, 0xF2),
    (0x400001, 0xF3),
    (0x800000, 0xF4),
    (0x800001, 0xF5),
]

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08,0x00,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
    code += stub
    def addr_of(o): return 0x0801 + o
    def emit(*bs): code.extend(bs)
    assert addr_of(len(code)) == 0x080D

    emit(0x78, 0x18, 0xFB)            # SEI; CLC; XCE → native
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    emit(0xC2, 0x10)                  # X=16
    emit(0xE2, 0x20)                  # M=8

    # ---- For each probe: 1-byte REU FETCH ----
    for reu_off, dest_zp in PROBES:
        reu_lo  =  reu_off        & 0xFF
        reu_mid = (reu_off >> 8)  & 0xFF
        reu_hi  = (reu_off >> 16) & 0xFF
        # $DF02 = C64 lo = dest_zp ; $DF03 = C64 hi = $00 (zero-page)
        emit(0xA9, dest_zp); emit(0x8D, 0x02, 0xDF)
        emit(0xA9, 0x00);    emit(0x8D, 0x03, 0xDF)
        emit(0xA9, reu_lo);  emit(0x8D, 0x04, 0xDF)
        emit(0xA9, reu_mid); emit(0x8D, 0x05, 0xDF)
        emit(0xA9, reu_hi);  emit(0x8D, 0x06, 0xDF)
        emit(0xA9, 0x01);    emit(0x8D, 0x07, 0xDF)   # length lo = 1
        emit(0xA9, 0x00);    emit(0x8D, 0x08, 0xDF)   # length hi = 0
        emit(0xA9, 0x91);    emit(0x8D, 0x01, 0xDF)   # cmd $91 FETCH

    # ---- Paint 6 rows ----
    def paint_row(zp, scr_lo, scr_hi, col_lo, col_hi):
        emit(0xA5, zp)
        emit(0xA2, 0x00, 0x00)
        lp = addr_of(len(code))
        emit(0x9D, scr_lo, scr_hi)
        emit(0xE8)
        emit(0xE0, 0x28, 0x00)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (lp - bpc) & 0xFF)
        emit(0xA9, 0x01)
        emit(0xA2, 0x00, 0x00)
        lp = addr_of(len(code))
        emit(0x9D, col_lo, col_hi)
        emit(0xE8)
        emit(0xE0, 0x28, 0x00)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (lp - bpc) & 0xFF)

    paint_row(0xF0, 0x00, 0x04, 0x00, 0xD8)
    paint_row(0xF1, 0x28, 0x04, 0x28, 0xD8)
    paint_row(0xF2, 0x50, 0x04, 0x50, 0xD8)
    paint_row(0xF3, 0x78, 0x04, 0x78, 0xD8)
    paint_row(0xF4, 0xA0, 0x04, 0xA0, 0xD8)
    paint_row(0xF5, 0xC8, 0x04, 0xC8, 0xD8)

    # Border + bg = $F0 ($78 expected)
    emit(0xA5, 0xF0); emit(0x8D, 0x20, 0xD0)
    emit(0xA5, 0xF0); emit(0x8D, 0x21, 0xD0)

    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'reu_peek_doom.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')
    print()
    print('Expected screen rows:')
    for (off, zp), (label, exp) in zip(PROBES, [
        ('row 0 (REU $200000)','$78'),
        ('row 1 (REU $200001)','$D8'),
        ('row 2 (REU $400000)','$FF'),
        ('row 3 (REU $400001)','$8C'),
        ('row 4 (REU $800000)','$53 = S'),
        ('row 5 (REU $800001)','$43 = C'),
    ]):
        print(f'  {label}: 40 cells of {exp}')
    print('Border = $78. Any divergence = REU read corruption.')

if __name__ == '__main__':
    sys.exit(main() or 0)
