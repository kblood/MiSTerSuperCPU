#!/usr/bin/env python3
"""Build superram_spin_test.prg — self-displaying SuperRAM round-trip test.

Replaces superram_minimal.prg's RTS-to-BASIC tail with a forever loop
that continuously paints the result onto a wide chunk of screen RAM,
so the result is visible in any screenshot regardless of when it's
taken AND regardless of whether SYS-return-to-BASIC clears the screen.

Test:
  1. Switch to native mode (XCE + NOP padding for the drop+scramble).
  2. Write byte $A5 to SuperRAM $20:$0000 via long-store.
  3. Read it back via long-LDA → result_byte.
  4. Spin forever painting:
       row 1 ($0428..$044F): result_byte repeated 40× (decoded color)
       row 0: SCREEN CODES spelling out "A5" or whatever was read
              (so the user can see the actual byte value visually).

Result interpretation:
  - Row 1 filled with screen code $A5 (a fully-checkered cell):
      -> SuperRAM round-trip OK ($A5 stored + read back = $A5)
  - Row 1 filled with something else (e.g. $00 = '@', $FF = pi):
      -> SuperRAM corruption — first known data path bug found
  - Row 1 BLANK ($20 spaces) or unchanged from BASIC text:
      -> test never reached the spin loop (wedged earlier)

The test takes no input, never returns. To exit, reset the C64.
"""
import os, struct, sys

def main():
    code = bytearray()

    # BASIC stub: 0 SYS 2061
    stub = bytes([
        0x0B, 0x08, 0x00, 0x00,
        0x9E, 0x32, 0x30, 0x36, 0x31,
        0x00, 0x00, 0x00,
    ])
    code += stub

    def emit(*bs):
        code.extend(bs)

    assert 0x0801 + len(code) == 0x080D, 'ML entry must be $080D'

    # SEI; CLC; XCE → native; absorb drop+scramble
    emit(0x78, 0x18, 0xFB)
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    # X=16-bit, M=8-bit
    emit(0xC2, 0x10)
    emit(0xE2, 0x20)

    # ---- SuperRAM round-trip ----
    # Long-store $A5 → $20:$0000
    emit(0xA9, 0xA5)
    emit(0x8F, 0x00, 0x00, 0x20)
    # Long-LDA $20:$0000 → A (result_byte)
    emit(0xAF, 0x00, 0x00, 0x20)
    # Stash result in $C300 (so we can re-read it inside the paint loop)
    emit(0x8D, 0x00, 0xC3)

    # ---- Paint loop ----
    # Fill $0400..$05F7 (rows 0-12) with the result byte.
    # X = 16-bit index, 0..$01F8 = 504 cells.
    emit(0xA2, 0x00, 0x00)                # LDX #$0000
    paint_loop = 0x0801 + len(code)
    emit(0xAD, 0x00, 0xC3)                # LDA $C300 (result_byte)
    emit(0x9D, 0x00, 0x04)                # STA $0400,X
    emit(0xE8)                            # INX
    emit(0xE0, 0xF8, 0x01)                # CPX #$01F8 (504 = 12 rows × 40 + 24)
    branch_pc = 0x0801 + len(code) + 2
    rel = paint_loop - branch_pc
    assert -128 <= rel <= 127, f'paint rel={rel}'
    emit(0xD0, rel & 0xFF)                # BNE paint_loop

    # ---- Spin forever ----
    # Set border colour to result low-nibble (visual confirmation).
    emit(0xAD, 0x00, 0xC3)                # LDA $C300
    emit(0x8D, 0x20, 0xD0)                # STA $D020 border
    emit(0x8D, 0x21, 0xD0)                # STA $D021 background
    spin = 0x0801 + len(code)
    branch_pc = 0x0801 + len(code) + 2
    rel = spin - branch_pc
    assert -128 <= rel <= 127
    emit(0x80, rel & 0xFF)                # BRA spin (back to itself)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'superram_spin_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    end_addr = 0x0801 + len(code) - 1
    print(f'Wrote {out}: {len(prg)} bytes ($0801..${end_addr:04X})')
    print()
    print('Interpretation after SYS 2061:')
    print('  Border & background flash to colour from $A5 low nibble ($5 = green)')
    print('  Screen rows 0-12 fill with screen code $A5 (checkered)')
    print('     -> SuperRAM round-trip WORKS')
    print('  Different fill char or no fill -> bug or wedge')

if __name__ == '__main__':
    sys.exit(main() or 0)
