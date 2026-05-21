#!/usr/bin/env python3
"""Build reu_superram_integrity_spin.prg — spin-painting variant of the
REU→SuperRAM integrity test.

Same logic as build_reu_superram_integrity.py, but instead of returning
to BASIC at the end (which races READY+cursor over the result bytes),
this variant paints the 6 result bytes onto 6 distinct screen rows
(40 cells each) and spins forever:

    row 0 ($0400-$0427): byte 0 (STASH+FETCH mismatch count)   expect $00
    row 1 ($0428-$044F): byte 1 (SuperRAM mismatch count)      expect $00
    row 2 ($0450-$0477): byte 2 ($77 completion tripwire)      expect $77
    row 3 ($0478-$049F): byte 3 (first-mismatch expected)      expect $FF
    row 4 ($04A0-$04C7): byte 4 (first-mismatch actual)        expect $FF
    row 5 ($04C8-$04EF): byte 5 ($AA tail tripwire)            expect $AA

After paint, set $D020/$D021 to the SuperRAM-mismatch byte so the
border colour gives an at-a-glance pass/fail (border black = $00 = OK).

Deploy via MGL pipe (`load_core /media/fat/_Test/...mgl`), screenshot
to read result.
"""
import os, struct, sys

def main():
    code = bytearray()

    stub = bytes([
        0x0B, 0x08, 0x00, 0x00,
        0x9E, 0x32, 0x30, 0x36, 0x31,
        0x00, 0x00, 0x00,
    ])
    code += stub

    def addr_of(offs):
        return 0x0801 + offs

    def emit(*bs):
        code.extend(bs)

    main_entry = addr_of(len(code))
    assert main_entry == 0x080D

    # native mode, X=16, M=8, absorb XCE drop+scramble
    emit(0x78, 0x18, 0xFB)
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    emit(0xC2, 0x10)
    emit(0xE2, 0x20)

    # ---- Step 1: ramp $00..$FF → $C000-$C0FF ----
    emit(0xA2, 0x00, 0x00)
    s1 = addr_of(len(code))
    emit(0x8A)                            # TXA
    emit(0x9D, 0x00, 0xC0)                # STA $C000,X
    emit(0xE8)                            # INX
    emit(0xE0, 0x00, 0x01)                # CPX #$0100
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s1 - bpc) & 0xFF)

    # ---- Step 2: REU STASH $C000-$C0FF → REU $00:010000 ----
    def reu_setup(c64_hi, reu_bank, cmd):
        emit(0xA9, 0x00); emit(0x8D, 0x02, 0xDF)
        emit(0xA9, c64_hi); emit(0x8D, 0x03, 0xDF)
        emit(0xA9, 0x00); emit(0x8D, 0x04, 0xDF)
        emit(0xA9, 0x00); emit(0x8D, 0x05, 0xDF)
        emit(0xA9, reu_bank); emit(0x8D, 0x06, 0xDF)
        emit(0xA9, 0x00); emit(0x8D, 0x07, 0xDF)
        emit(0xA9, 0x01); emit(0x8D, 0x08, 0xDF)
        emit(0xA9, cmd); emit(0x8D, 0x01, 0xDF)

    reu_setup(0xC0, 0x01, 0x90)           # STASH
    reu_setup(0xC1, 0x01, 0x91)           # FETCH

    # ---- Step 4: count STASH+FETCH mismatches into Y ----
    emit(0xA2, 0x00, 0x00)
    emit(0xA0, 0x00, 0x00)
    s4 = addr_of(len(code))
    emit(0xBD, 0x00, 0xC0)
    emit(0xDD, 0x00, 0xC1)
    skip4 = len(code)
    emit(0xF0, 0x01)                      # BEQ +1 (skip INY)
    emit(0xC8)
    emit(0xE8)
    emit(0xE0, 0x00, 0x01)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s4 - bpc) & 0xFF)
    emit(0x98)                            # TYA
    emit(0x85, 0xF0)                      # STA $F0  (byte0 = stash/fetch mismatch)

    # ---- Step 5: long-store $C100-$C1FF → SuperRAM $20:$0000 ----
    emit(0xC2, 0x10)
    emit(0xA2, 0x00, 0x00)
    s5 = addr_of(len(code))
    emit(0xBD, 0x00, 0xC1)
    emit(0x9F, 0x00, 0x00, 0x20)
    emit(0xE8)
    emit(0xE0, 0x00, 0x01)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s5 - bpc) & 0xFF)

    # ---- Step 6: long-LDA SuperRAM $20:$0000 → $C200-$C2FF ----
    emit(0xA2, 0x00, 0x00)
    s6 = addr_of(len(code))
    emit(0xBF, 0x00, 0x00, 0x20)
    emit(0x9D, 0x00, 0xC2)
    emit(0xE8)
    emit(0xE0, 0x00, 0x01)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s6 - bpc) & 0xFF)

    # ---- Step 7: count SuperRAM mismatches into Y ----
    emit(0xA2, 0x00, 0x00)
    emit(0xA0, 0x00, 0x00)
    # init first-mismatch slots to $FF
    emit(0xA9, 0xFF)
    emit(0x85, 0xF3)
    emit(0x85, 0xF4)
    s7 = addr_of(len(code))
    emit(0xBD, 0x00, 0xC0)
    emit(0xDD, 0x00, 0xC2)
    skip7_pos = len(code)
    emit(0xF0, 0x00)                      # patched
    # mismatch path: record if first (Y==0)
    emit(0xC0, 0x00, 0x00)                # CPY #$0000
    emit(0xD0, 0x09)                      # BNE +9
    emit(0x85, 0xF4)                      # STA $F4 (actual)
    emit(0xBD, 0x00, 0xC0)                # LDA $C000,X
    emit(0x85, 0xF3)                      # STA $F3 (expected)
    emit(0xC8)                            # INY
    skip_tgt = len(code)
    code[skip7_pos + 1] = (skip_tgt - (skip7_pos + 2)) & 0xFF
    emit(0xE8)
    emit(0xE0, 0x00, 0x01)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s7 - bpc) & 0xFF)
    emit(0x98)                            # TYA
    emit(0x85, 0xF1)                      # STA $F1 (byte1 = SuperRAM mismatch count)

    # ---- Stash remaining tripwires ----
    emit(0xA9, 0x77); emit(0x85, 0xF2)    # $F2 = $77 completion
    emit(0xA9, 0xAA); emit(0x85, 0xF5)    # $F5 = $AA tail

    # ---- Paint 6 result bytes onto 6 screen rows ----
    # X starts at 0, walks through 240 cells (6 rows × 40)
    # Row index = X/40 → use lookup table approach: for X in 0..239,
    # load $F0 + (X/40) into A, store at $0400+X.
    # Simpler: 6 separate inner loops (40 iters each), one per row.
    def paint_row(zp_src, scr_lo, scr_hi, col_lo, col_hi):
        # Paint 40 cells of screen RAM with byte from zero-page,
        # plus force colour RAM to $01 (white) for the same 40 cells.
        emit(0xA5, zp_src)
        emit(0xA2, 0x00, 0x00)
        lp = addr_of(len(code))
        emit(0x9D, scr_lo, scr_hi)
        emit(0xE8)
        emit(0xE0, 0x28, 0x00)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (lp - bpc) & 0xFF)
        emit(0xA9, 0x01)
        emit(0xA2, 0x00, 0x00)
        lpc = addr_of(len(code))
        emit(0x9D, col_lo, col_hi)
        emit(0xE8)
        emit(0xE0, 0x28, 0x00)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (lpc - bpc) & 0xFF)

    paint_row(0xF0, 0x00, 0x04, 0x00, 0xD8)
    paint_row(0xF1, 0x28, 0x04, 0x28, 0xD8)
    paint_row(0xF2, 0x50, 0x04, 0x50, 0xD8)
    paint_row(0xF3, 0x78, 0x04, 0x78, 0xD8)
    paint_row(0xF4, 0xA0, 0x04, 0xA0, 0xD8)
    paint_row(0xF5, 0xC8, 0x04, 0xC8, 0xD8)

    # ---- Border + bg colour ← SuperRAM mismatch byte ----
    emit(0xA5, 0xF1)                      # LDA $F1
    emit(0x8D, 0x20, 0xD0)                # STA $D020
    emit(0x8D, 0x21, 0xD0)                # STA $D021

    # ---- Spin forever ----
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    rel = spin - bpc
    assert -128 <= rel <= 127
    emit(0x80, rel & 0xFF)                # BRA self

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'reu_superram_integrity_spin.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    end_addr = 0x0801 + len(code) - 1
    print(f'Wrote {out}: {len(prg)} bytes ($0801..${end_addr:04X})')
    print()
    print('Expected screen rows (each 40 cells filled with one byte):')
    print('  row 0: $00  (STASH+FETCH mismatch count)')
    print('  row 1: $00  (SuperRAM mismatch count)')
    print('  row 2: $77  (completion tripwire)')
    print('  row 3: $FF  (first-mismatch expected, FF=no mismatch)')
    print('  row 4: $FF  (first-mismatch actual,  FF=no mismatch)')
    print('  row 5: $AA  (tail tripwire)')
    print('Border+bg colour = $F1 low nibble (0=black=PASS).')

if __name__ == '__main__':
    sys.exit(main() or 0)
