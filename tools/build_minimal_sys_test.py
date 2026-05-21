#!/usr/bin/env python3
"""Build minimal_sys_test.prg — verifies SYS/RUN actually runs our ML.

NO native mode, NO XCE, NO cross-bank. Pure 6510 emu-mode:
  LDA #$77; STA $C200
  LDA #$88; STA $C201
  LDA #$99; STA $C202
  LDA #$AA; STA $C203
  RTS

After RUN, PEEK 49664/49665/49666/49667 should print 119 136 153 170.
If they don't change, SYS/RUN is broken (NOT a SCPU-specific bug).
"""
import os, struct, sys

def main():
    code = bytearray()
    # BASIC stub: 0 SYS 2061
    stub = bytes([
        0x0B,0x08,         # next-line ptr → $080B
        0x00,0x00,         # line 0
        0x9E,              # SYS token
        0x32,0x30,0x36,0x31, # "2061"
        0x00,              # EOL
        0x00,0x00,         # EOP
    ])
    code += stub
    main_entry = 0x0801 + len(code)
    assert main_entry == 0x080D
    # Pure 6510 ML
    code += bytes([
        0xA9, 0x77,            # LDA #$77
        0x8D, 0x00, 0xC2,      # STA $C200
        0xA9, 0x88,            # LDA #$88
        0x8D, 0x01, 0xC2,      # STA $C201
        0xA9, 0x99,            # LDA #$99
        0x8D, 0x02, 0xC2,      # STA $C202
        0xA9, 0xAA,            # LDA #$AA
        0x8D, 0x03, 0xC2,      # STA $C203
        0x60,                  # RTS
    ])
    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'minimal_sys_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes')

if __name__ == '__main__':
    sys.exit(main() or 0)
