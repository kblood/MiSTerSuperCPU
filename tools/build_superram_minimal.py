#!/usr/bin/env python3
"""Build superram_minimal.prg — minimal SuperRAM round-trip test.

No REU, no fancy logic. Just:
  1. Switch to native mode (with XCE-drop NOPs).
  2. Write step tripwire $11 to $0400 (proves we got past XCE).
  3. Long-store byte $A5 to SuperRAM $20:$0000.
  4. Write tripwire $22 to $0401 (proves long-store didn't wedge).
  5. Long-LDA from SuperRAM $20:$0000, store to $0402.
  6. Write tripwire $33 to $0403 (proves long-LDA didn't wedge).
  7. Return to emu mode, RTS.

If test runs cleanly, screen $0400-$0403 will show $11 $22 $A5 $33.
If $0402 shows something OTHER than $A5, SuperRAM round-trip is broken.
If the test wedges, the highest tripwire visible says how far it got.
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

    # SEI; CLC; XCE → native
    emit(0x78, 0x18, 0xFB)
    # Absorb XCE drop+scramble (per project_xce_drops_next_instruction.md).
    # Use 4 NOPs to be generous.
    emit(0xEA, 0xEA, 0xEA, 0xEA)

    # Tripwire 1: $11 → $0400 (proves we survived XCE)
    emit(0xA9, 0x11)            # LDA #$11
    emit(0x8D, 0x00, 0x04)      # STA $0400

    # Long-store: $A5 → $20:$0000
    emit(0xA9, 0xA5)            # LDA #$A5
    emit(0x8F, 0x00, 0x00, 0x20) # STA $200000 (long)

    # Tripwire 2: $22 → $0401 (long-store survived)
    emit(0xA9, 0x22)
    emit(0x8D, 0x01, 0x04)

    # Long-LDA: $20:$0000 → A, then STA $0402
    emit(0xAF, 0x00, 0x00, 0x20) # LDA $200000 (long)
    emit(0x8D, 0x02, 0x04)       # STA $0402

    # Tripwire 3: $33 → $0403 (long-LDA survived)
    emit(0xA9, 0x33)
    emit(0x8D, 0x03, 0x04)

    # Back to emu mode and exit
    emit(0x38, 0xFB)             # SEC; XCE → emu
    emit(0x58)                   # CLI
    emit(0x60)                   # RTS

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'superram_minimal.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    end_addr = 0x0801 + len(code) - 1
    print(f'Wrote {out}: {len(prg)} bytes ($0801..${end_addr:04X})')
    print()
    print('Expected screen $0400-$0403 after SYS 2061:')
    print('  $0400 = $11 (post-XCE tripwire)')
    print('  $0401 = $22 (post-long-store tripwire)')
    print('  $0402 = $A5 (SuperRAM readback — IF NOT $A5, BUG FOUND)')
    print('  $0403 = $33 (post-long-LDA tripwire)')

if __name__ == '__main__':
    sys.exit(main() or 0)
