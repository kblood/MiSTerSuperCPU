#!/usr/bin/env python3
"""Build reu_superram_multibank.prg — tests REU→SuperRAM across 4 banks.

Same data path as reu_superram_integrity_spin, but exercises 4 different
SuperRAM banks ($20, $40, $60, $80) to see if any specific bank diverges.

Test sequence:
  1. Ramp $00..$FF to $C000-$C0FF.
  2. REU STASH $C000-$C0FF → REU $00:010000 (once).
  3. For each test bank in [$20, $40, $60, $80]:
       a. REU FETCH REU $00:010000 → $C100-$C1FF.
       b. Long-store $C100-$C1FF → BANK:$0000-$00FF.
       c. Long-LDA  BANK:$0000-$00FF → $C200-$C2FF.
       d. Count mismatches between $C000 and $C200 into Y, store to result slot.

Result slots ($F0..$F5):
  $F0 = REU STASH→FETCH+SuperRAM bank $20 round-trip mismatch count
  $F1 = bank $40 mismatch count
  $F2 = bank $60 mismatch count
  $F3 = bank $80 mismatch count
  $F4 = $77 completion tripwire
  $F5 = $AA tail tripwire

Display: 6 rows of 40 cells each painted with the byte value.
Border = $F0 (bank-$20 mismatch) for at-a-glance PASS/FAIL.

If all four bank mismatch counts = $00 the bug is NOT a per-bank
parametric issue. Next probe would be larger-scale transfer within
one bank (16KB+) or REU offsets Doom actually uses for music data.
"""
import os, struct, sys

TEST_BANKS = [0x86, 0x87, 0xA0, 0xE0]   # banks near Doom music data + high
RESULT_ZP  = [0xF0, 0xF1, 0xF2, 0xF3]

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08,0x00,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
    code += stub

    def addr_of(o): return 0x0801 + o
    def emit(*bs): code.extend(bs)
    assert addr_of(len(code)) == 0x080D

    emit(0x78, 0x18, 0xFB)            # SEI; CLC; XCE
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    emit(0xC2, 0x10)                  # X=16
    emit(0xE2, 0x20)                  # M=8

    # ---- Step 1: ramp $00..$FF → $C000-$C0FF ----
    emit(0xA2, 0x00, 0x00)
    s1 = addr_of(len(code))
    emit(0x8A)                        # TXA
    emit(0x9D, 0x00, 0xC0)            # STA $C000,X
    emit(0xE8)
    emit(0xE0, 0x00, 0x01)            # CPX #$0100
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s1 - bpc) & 0xFF)

    # ---- Step 2: REU STASH $C000-$C0FF → REU $00:010000 ----
    for op,val in [(0xDF02,0x00),(0xDF03,0xC0),(0xDF04,0x00),
                   (0xDF05,0x00),(0xDF06,0x01),(0xDF07,0x00),
                   (0xDF08,0x01),(0xDF01,0x90)]:
        emit(0xA9, val); emit(0x8D, op & 0xFF, (op>>8)&0xFF)

    # ---- Step 3: For each test bank ----
    for idx, bank in enumerate(TEST_BANKS):
        # 3a: REU FETCH REU $00:010000 → $C100-$C1FF
        for op,val in [(0xDF02,0x00),(0xDF03,0xC1),(0xDF04,0x00),
                       (0xDF05,0x00),(0xDF06,0x01),(0xDF07,0x00),
                       (0xDF08,0x01),(0xDF01,0x91)]:
            emit(0xA9, val); emit(0x8D, op & 0xFF, (op>>8)&0xFF)

        # 3b: long-store $C100-$C1FF → bank:$0000-$00FF
        # STA long,X = $9F + lo + mid + hi (24-bit base)
        emit(0xA2, 0x00, 0x00)
        sx = addr_of(len(code))
        emit(0xBD, 0x00, 0xC1)        # LDA $C100,X
        emit(0x9F, 0x00, 0x00, bank)  # STA bank:0000,X
        emit(0xE8)
        emit(0xE0, 0x00, 0x01)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (sx - bpc) & 0xFF)

        # 3c: long-LDA bank:$0000-$00FF → $C200-$C2FF
        emit(0xA2, 0x00, 0x00)
        sx = addr_of(len(code))
        emit(0xBF, 0x00, 0x00, bank)  # LDA bank:0000,X
        emit(0x9D, 0x00, 0xC2)        # STA $C200,X
        emit(0xE8)
        emit(0xE0, 0x00, 0x01)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (sx - bpc) & 0xFF)

        # 3d: compare $C000 vs $C200, count mismatches → Y, store to $F_idx
        emit(0xA2, 0x00, 0x00)
        emit(0xA0, 0x00, 0x00)
        sx = addr_of(len(code))
        emit(0xBD, 0x00, 0xC0)        # LDA $C000,X
        emit(0xDD, 0x00, 0xC2)        # CMP $C200,X
        emit(0xF0, 0x01)              # BEQ +1 (skip INY)
        emit(0xC8)                    # INY
        emit(0xE8)                    # INX
        emit(0xE0, 0x00, 0x01)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (sx - bpc) & 0xFF)
        emit(0x98)                    # TYA (low byte of Y)
        emit(0x85, RESULT_ZP[idx])    # STA $F_idx

    # ---- Tripwires ----
    emit(0xA9, 0x77); emit(0x85, 0xF4)
    emit(0xA9, 0xAA); emit(0x85, 0xF5)

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

    paint_row(0xF0, 0x00, 0x04, 0x00, 0xD8)   # bank $20
    paint_row(0xF1, 0x28, 0x04, 0x28, 0xD8)   # bank $40
    paint_row(0xF2, 0x50, 0x04, 0x50, 0xD8)   # bank $60
    paint_row(0xF3, 0x78, 0x04, 0x78, 0xD8)   # bank $80
    paint_row(0xF4, 0xA0, 0x04, 0xA0, 0xD8)   # $77 completion
    paint_row(0xF5, 0xC8, 0x04, 0xC8, 0xD8)   # $AA tail

    # Border + bg = $F0 (bank-$20 mismatch byte). PASS = black border.
    emit(0xA5, 0xF0); emit(0x8D, 0x20, 0xD0)
    emit(0xA5, 0xF0); emit(0x8D, 0x21, 0xD0)

    # Also echo $F0-$F3 into $005C (W5 4-deep ring at $005C, per RTL comment)
    # so the result is also UART-visible.
    emit(0xA5, 0xF0); emit(0x8D, 0x5C, 0x00)
    emit(0xA5, 0xF1); emit(0x8D, 0x5C, 0x00)
    emit(0xA5, 0xF2); emit(0x8D, 0x5C, 0x00)
    emit(0xA5, 0xF3); emit(0x8D, 0x5C, 0x00)

    # Spin
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'reu_superram_multibank_high.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')
    print()
    print('Banks tested:', ', '.join(f'${b:02X}' for b in TEST_BANKS))
    print('Result reading:')
    print('  W5 ring (UART) = last 4 writes to $005C = $F0 $F1 $F2 $F3')
    print('                  (= bank $20/$40/$60/$80 mismatch counts)')
    print('  Screen rows 0-3 = same 4 mismatch counts (visual).')
    print('  Border colour = $F0 low nibble (0=black=bank $20 PASS).')

if __name__ == '__main__':
    sys.exit(main() or 0)
