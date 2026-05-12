#!/usr/bin/env python3
"""Build reu_superram_64kb_chained.prg — 64 KB chained transfer test.

Replicates Doom's actual loader pattern: REU FETCH 4 KB → bank $00
RAM → CPU long-store → SuperRAM, repeated 16 times to fill the full
64 KB SuperRAM bank $20. Tests whether sustained chained operations
trigger corruption invisible to single-shot tests.

Sequence:
  1. Set up 4 KB ramp at $A000-$AFFF (cycling $00..$FF).
  2. REU STASH $A000-$AFFF → REU $00:010000 (one-shot, 4 KB).
  3. 16-iteration loop, i = 0..15:
     a. REU FETCH REU $00:010000 → $B000 (each iter re-fetches).
     b. Long-store $B000-$BFFF → SuperRAM $20:(i*$1000)..(i*$1000+$FFF).
  4. After all 16 chunks written: read back SuperRAM $20:F000-$FFFF
     (last chunk written) into $9000-$9FFF.
  5. Compare $A000 vs $9000 ramp, count mismatches.

This stresses:
  - 16 chained REU FETCH operations (REU length auto-reloads to
    $FFFF after each FETCH — we re-write length each iteration).
  - 16 long-store loops of 4 KB each = 65,536 long-stores total.
  - SuperRAM coverage across full 64 KB of one bank.

Result slots:
  $F0 = mismatch count low byte
  $F1 = mismatch count high byte
  $F2 = $77 completion tripwire
  $F3 = $AA tail tripwire

If $F0+$F1 = 0 = PASS = the chained 64 KB pattern is reliable.
If non-zero: we've found the corruption scale and can localize further.
"""
import os, struct, sys

CHUNK    = 0x1000   # 4 KB per chunk
N_CHUNKS = 16       # 16 × 4 KB = 64 KB

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

    # ---- Step 1: 4 KB ramp at $A000-$AFFF ----
    emit(0xA2, 0x00, 0x00)
    s1 = addr_of(len(code))
    emit(0x8A)
    emit(0x9D, 0x00, 0xA0)
    emit(0xE8)
    emit(0xE0, CHUNK & 0xFF, (CHUNK>>8) & 0xFF)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (s1 - bpc) & 0xFF)

    # ---- Step 2: REU STASH $A000-$AFFF → REU $00:010000 (one-shot) ----
    for op,val in [(0xDF02,0x00),(0xDF03,0xA0),(0xDF04,0x00),
                   (0xDF05,0x00),(0xDF06,0x01),
                   (0xDF07,CHUNK & 0xFF),(0xDF08,(CHUNK>>8) & 0xFF),
                   (0xDF01,0x90)]:
        emit(0xA9, val); emit(0x8D, op & 0xFF, (op>>8)&0xFF)

    # ---- Step 3: 16 iterations of FETCH + long-store ----
    # For each iteration i, SuperRAM target high byte = i (high byte of i*$1000).
    # We unroll the loop since each iteration has a different SuperRAM destination.
    # Long-indexed STA uses absolute long base, X register is the offset (16-bit).
    # Each iteration writes 4 KB; X iterates 0..$FFF.
    for i in range(N_CHUNKS):
        # 3a: REU FETCH REU $00:010000 → $B000-$BFFF (4 KB)
        for op,val in [(0xDF02,0x00),(0xDF03,0xB0),(0xDF04,0x00),
                       (0xDF05,0x00),(0xDF06,0x01),
                       (0xDF07,CHUNK & 0xFF),(0xDF08,(CHUNK>>8) & 0xFF),
                       (0xDF01,0x91)]:
            emit(0xA9, val); emit(0x8D, op & 0xFF, (op>>8)&0xFF)

        # 3b: long-store $B000-$BFFF → SuperRAM $20:(i*$1000)..(i*$1000+$FFF)
        # Long base = bank $20, page (i*$10), offset $00.
        # STA $20<i:00>,X with X=0..$FFF
        sram_lo  = 0x00
        sram_mid = i * 0x10           # high byte of i*$1000
        sram_hi  = 0x20
        emit(0xA2, 0x00, 0x00)        # LDX #$0000
        sx = addr_of(len(code))
        emit(0xBD, 0x00, 0xB0)        # LDA $B000,X
        emit(0x9F, sram_lo, sram_mid, sram_hi)  # STA $20<imid>:00,X long-indexed
        emit(0xE8)
        emit(0xE0, CHUNK & 0xFF, (CHUNK>>8) & 0xFF)
        bpc = addr_of(len(code) + 2)
        emit(0xD0, (sx - bpc) & 0xFF)

    # ---- Step 4: read back SuperRAM $20:F000-$FFFF (last chunk) → $9000-$9FFF ----
    emit(0xA2, 0x00, 0x00)
    sx = addr_of(len(code))
    emit(0xBF, 0x00, 0xF0, 0x20)      # LDA $20:F000,X
    emit(0x9D, 0x00, 0x90)            # STA $9000,X
    emit(0xE8)
    emit(0xE0, CHUNK & 0xFF, (CHUNK>>8) & 0xFF)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (sx - bpc) & 0xFF)

    # ---- Step 5: compare $A000 (ramp) vs $9000 (readback). 16-bit Y counter ----
    emit(0xA2, 0x00, 0x00)
    emit(0xA0, 0x00, 0x00)
    sx = addr_of(len(code))
    emit(0xBD, 0x00, 0xA0)
    emit(0xDD, 0x00, 0x90)
    emit(0xF0, 0x01)
    emit(0xC8)
    emit(0xE8)
    emit(0xE0, CHUNK & 0xFF, (CHUNK>>8) & 0xFF)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (sx - bpc) & 0xFF)
    # Y (16-bit) → $F0/$F1 via REP/SEP wrap
    emit(0xC2, 0x20)
    emit(0x98)
    emit(0x85, 0xF0)
    emit(0xE2, 0x20)

    # Tripwires
    emit(0xA9, 0x77); emit(0x85, 0xF2)
    emit(0xA9, 0xAA); emit(0x85, 0xF3)

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

    paint_row(0xF0, 0x00, 0x04, 0x00, 0xD8)   # mismatch lo
    paint_row(0xF1, 0x28, 0x04, 0x28, 0xD8)   # mismatch hi
    paint_row(0xF2, 0x50, 0x04, 0x50, 0xD8)   # $77 completion
    paint_row(0xF3, 0x78, 0x04, 0x78, 0xD8)   # $AA tail

    # Border + bg = $F0
    emit(0xA5, 0xF0); emit(0x8D, 0x20, 0xD0)
    emit(0xA5, 0xF0); emit(0x8D, 0x21, 0xD0)

    # Spin
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'reu_superram_64kb_chained.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')
    print()
    print(f'Total transfer: {N_CHUNKS} × {CHUNK} = {N_CHUNKS*CHUNK} bytes')
    print(f'Verifies: last chunk only ($20:F000-FFFF)')
    print('Border = $F0 (mismatch lo). Black = PASS.')

if __name__ == '__main__':
    sys.exit(main() or 0)
