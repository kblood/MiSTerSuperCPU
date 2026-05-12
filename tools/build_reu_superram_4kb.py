#!/usr/bin/env python3
"""Build reu_superram_4kb.prg — 4 KB REU→SuperRAM round-trip test.

Extends the 256-byte path to 4096 bytes in a single REU/SuperRAM
transfer. If the music_num=-9 corruption is large-scale, this should
catch it.

Test sequence:
  1. Fill $A000-$AFFF with a known pattern (cycling ramp $00..$FF
     repeating 16 times = 4096 bytes).
  2. REU STASH $A000-$AFFF → REU $00:010000 (4096 bytes, length $1000).
  3. REU FETCH REU $00:010000 → $B000-$BFFF.
  4. Long-store $B000-$BFFF → SuperRAM $20:$0000-$0FFF.
  5. Long-LDA SuperRAM $20:$0000-$0FFF → $9000-$9FFF.
  6. Compare $A000 vs $9000 byte-by-byte. Count mismatches (16-bit).
  7. Also compare $A000 vs $B000 (REU STASH+FETCH only) for separate count.

Result zero-page slots:
  $F0 = REU STASH+FETCH mismatch count low byte
  $F1 = REU STASH+FETCH mismatch count high byte
  $F2 = SuperRAM round-trip mismatch count low byte
  $F3 = SuperRAM round-trip mismatch count high byte
  $F4 = $77 completion tripwire
  $F5 = $AA tail tripwire

Border = $F2 (SuperRAM mismatch low byte). PASS = black border.
"""
import os, struct, sys

LENGTH = 0x1000   # 4096 bytes

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

    # ---- Step 1: ramp at $A000-$AFFF (cycling $00..$FF, 16 reps) ----
    emit(0xA2, 0x00, 0x00)            # LDX #$0000
    s1 = addr_of(len(code))
    emit(0x8A)                        # TXA (A = X low byte)
    emit(0x9D, 0x00, 0xA0)            # STA $A000,X (X is 16-bit, so up to $AFFF)
    emit(0xE8)                        # INX
    emit(0xE0, LENGTH & 0xFF, (LENGTH>>8) & 0xFF)  # CPX #$1000
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s1 - bpc) & 0xFF)

    # ---- Step 2: REU STASH $A000-$AFFF → REU $00:010000 (length $1000) ----
    for op,val in [(0xDF02,0x00),(0xDF03,0xA0),(0xDF04,0x00),
                   (0xDF05,0x00),(0xDF06,0x01),
                   (0xDF07,LENGTH & 0xFF),(0xDF08,(LENGTH>>8) & 0xFF),
                   (0xDF01,0x90)]:
        emit(0xA9, val); emit(0x8D, op & 0xFF, (op>>8)&0xFF)

    # ---- Step 3: REU FETCH REU $00:010000 → $B000-$BFFF ----
    for op,val in [(0xDF02,0x00),(0xDF03,0xB0),(0xDF04,0x00),
                   (0xDF05,0x00),(0xDF06,0x01),
                   (0xDF07,LENGTH & 0xFF),(0xDF08,(LENGTH>>8) & 0xFF),
                   (0xDF01,0x91)]:
        emit(0xA9, val); emit(0x8D, op & 0xFF, (op>>8)&0xFF)

    # ---- Step 4: long-store $B000-$BFFF → SuperRAM $20:$0000-$0FFF ----
    emit(0xA2, 0x00, 0x00)
    s4 = addr_of(len(code))
    emit(0xBD, 0x00, 0xB0)            # LDA $B000,X
    emit(0x9F, 0x00, 0x00, 0x20)      # STA $20:0000,X (long-indexed)
    emit(0xE8)
    emit(0xE0, LENGTH & 0xFF, (LENGTH>>8) & 0xFF)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s4 - bpc) & 0xFF)

    # ---- Step 5: long-LDA SuperRAM $20:$0000-$0FFF → $9000-$9FFF ----
    emit(0xA2, 0x00, 0x00)
    s5 = addr_of(len(code))
    emit(0xBF, 0x00, 0x00, 0x20)      # LDA $20:0000,X
    emit(0x9D, 0x00, 0x90)            # STA $9000,X
    emit(0xE8)
    emit(0xE0, LENGTH & 0xFF, (LENGTH>>8) & 0xFF)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s5 - bpc) & 0xFF)

    # ---- Step 6: STASH+FETCH compare ($A000 vs $B000), counter in Y ----
    emit(0xA2, 0x00, 0x00)
    emit(0xA0, 0x00, 0x00)
    s6 = addr_of(len(code))
    emit(0xBD, 0x00, 0xA0)            # LDA $A000,X
    emit(0xDD, 0x00, 0xB0)            # CMP $B000,X
    emit(0xF0, 0x01)
    emit(0xC8)                        # INY (16-bit because X-flag=0)
    emit(0xE8)
    emit(0xE0, LENGTH & 0xFF, (LENGTH>>8) & 0xFF)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s6 - bpc) & 0xFF)
    # Store Y low to $F0, Y high to $F1
    # With M=8, X=16, STY abs is 16-bit store. Simpler: TYA (low), STA $F0,
    # then SEP/REP would change M; easier: use STX/Y abs. Let me just do
    # individual stores via REP+SEP toggles, or two scalar moves.
    # Strategy: TXA preserved? No — TYA changes A. After TYA, A=Y[7:0] (M=8).
    # Then SHIFT Y high: TYX (transfers Y to X)... actually 65816 has no direct
    # transfer for hi-byte. Easier: REP #$20 to make A 16-bit, TYA, STA $F0
    # (16-bit STA writes 2 bytes), then SEP #$20 back to M=8.
    emit(0xC2, 0x20)                  # REP #$20 (M=16)
    emit(0x98)                        # TYA (16-bit because M=0)
    emit(0x85, 0xF0)                  # STA $F0 (zero-page, M=16 → 2 bytes: F0 lo, F1 hi)
    emit(0xE2, 0x20)                  # SEP #$20 (back to M=8)

    # ---- Step 7: SuperRAM compare ($A000 vs $9000), counter in Y ----
    emit(0xA2, 0x00, 0x00)
    emit(0xA0, 0x00, 0x00)
    s7 = addr_of(len(code))
    emit(0xBD, 0x00, 0xA0)            # LDA $A000,X
    emit(0xDD, 0x00, 0x90)            # CMP $9000,X
    emit(0xF0, 0x01)
    emit(0xC8)                        # INY
    emit(0xE8)
    emit(0xE0, LENGTH & 0xFF, (LENGTH>>8) & 0xFF)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s7 - bpc) & 0xFF)
    emit(0xC2, 0x20)                  # REP #$20
    emit(0x98)                        # TYA (16-bit)
    emit(0x85, 0xF2)                  # STA $F2 (F2=lo, F3=hi)
    emit(0xE2, 0x20)                  # SEP #$20

    # Tripwires
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

    paint_row(0xF0, 0x00, 0x04, 0x00, 0xD8)   # STASH+FETCH low
    paint_row(0xF1, 0x28, 0x04, 0x28, 0xD8)   # STASH+FETCH high
    paint_row(0xF2, 0x50, 0x04, 0x50, 0xD8)   # SuperRAM low
    paint_row(0xF3, 0x78, 0x04, 0x78, 0xD8)   # SuperRAM high
    paint_row(0xF4, 0xA0, 0x04, 0xA0, 0xD8)   # $77 completion
    paint_row(0xF5, 0xC8, 0x04, 0xC8, 0xD8)   # $AA tail

    # Border + bg = $F2 (SuperRAM mismatch lo). PASS = black border.
    emit(0xA5, 0xF2); emit(0x8D, 0x20, 0xD0)
    emit(0xA5, 0xF2); emit(0x8D, 0x21, 0xD0)

    # Spin
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'reu_superram_4kb.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')
    print()
    print(f'Transfer size: {LENGTH} bytes (4 KB)')
    print('Result rows:')
    print('  0: STASH+FETCH mismatch low byte')
    print('  1: STASH+FETCH mismatch high byte')
    print('  2: SuperRAM mismatch low byte')
    print('  3: SuperRAM mismatch high byte')
    print('  4: $77 (completion)')
    print('  5: $AA (tail)')
    print('Border = $F2 (SuperRAM low). Black = PASS.')

if __name__ == '__main__':
    sys.exit(main() or 0)
