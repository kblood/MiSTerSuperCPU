#!/usr/bin/env python3
"""xce_clean_test.prg — single XCE, known A in emu, then one LDA/STA after XCE.

Initial A in emu mode = $33. Then XCE → native. Then LDA #$AA; STA $C200.
Expected if drop: $C200 = $33 (A's pre-XCE value)
Expected if works: $C200 = $AA
Anything else: weirder bug

Also writes $0500 = 16 (just to mark code ran at all, before XCE).
"""
import os, struct, sys

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08, 0x00,0x00, 0x9E, 0x32,0x30,0x36,0x31, 0x00, 0x00,0x00])
    code += stub
    assert 0x0801 + len(code) == 0x080D
    code += bytes([
        # marker: $0500 = $10 (proves PRG started)
        0xA9, 0x10, 0x8D, 0x00, 0x05,
        # zero target
        0xA9, 0x00, 0x8D, 0x00, 0xC2,
        # known A in emu
        0xA9, 0x33,
        # marker before XCE: $0501 = A value when entering native
        0x8D, 0x01, 0x05,
        # enter native
        0x78, 0x18, 0xFB,
        # LDA #$AA  -- expected to set A
        0xA9, 0xAA,
        # STA $C200
        0x8D, 0x00, 0xC2,
        # marker AFTER STA: $0502 = A right after STA
        0x8D, 0x02, 0x05,
        # back to emu
        0x38, 0xFB,
        0x58, 0x60,
    ])
    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xce_clean_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes')

if __name__ == '__main__':
    sys.exit(main() or 0)
