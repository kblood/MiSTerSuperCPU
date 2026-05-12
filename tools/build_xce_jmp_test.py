#!/usr/bin/env python3
"""xce_jmp_test.prg — characterize whether XCE drops a following JMP.

If XCE drops the JMP (like it drops LDA), we'll see the fall-through path
execute. Otherwise, the jump target's code runs.

Layout:
  $080D: SEI; CLC; XCE; JMP $0830 ; jump skips the fall-through
  $0814..$082F: fall-through writes: STA $C200 with #$AA, then RTS
  $0830: target: writes #$77 to $C201, then SEC; XCE; CLI; RTS

After autorun:
  $C200 = $AA → JMP was dropped, fall-through ran
  $C201 = $77 → JMP succeeded, target ran
  Both nonzero → impossible (different RTS paths)
"""
import os, struct, sys

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08, 0x00,0x00, 0x9E, 0x32,0x30,0x36,0x31, 0x00, 0x00,0x00])
    code += stub
    assert 0x0801 + len(code) == 0x080D

    # First, pre-zero both bytes via plain 6510 ML BEFORE entering native
    # (so we can tell what happened):
    code += bytes([
        0xA9, 0x00,            # LDA #$00
        0x8D, 0x00, 0xC2,      # STA $C200
        0x8D, 0x01, 0xC2,      # STA $C201
    ])

    code += bytes([
        0x78,                  # SEI
        0x18,                  # CLC
        0xFB,                  # XCE  -> native
        # JMP $0830 — 3 bytes (4C 30 08)
        0x4C, 0x30, 0x08,
    ])
    # Now pad code so that fall-through (next byte after JMP) lands at predictable spot.
    # JMP ends at $081A (3 bytes from $0817). Fall-through at $081A.
    # If JMP was dropped, PC advances past JMP to $081A and continues here.
    while 0x0801 + len(code) < 0x081A:
        code += bytes([0xEA])  # NOP fill
    # Fall-through marker code at $081A:
    # LDA #$AA; STA $C200; SEC; XCE; CLI; RTS
    code += bytes([
        0xA9, 0xAA,
        0x8D, 0x00, 0xC2,
        0x38,                  # SEC
        0xFB,                  # XCE -> emu
        0x58,                  # CLI
        0x60,                  # RTS
    ])
    # pad to $0830
    while 0x0801 + len(code) < 0x0830:
        code += bytes([0xEA])
    # Target code at $0830:
    # LDA #$77; STA $C201; SEC; XCE; CLI; RTS
    code += bytes([
        0xA9, 0x77,
        0x8D, 0x01, 0xC2,
        0x38,                  # SEC
        0xFB,                  # XCE -> emu
        0x58,                  # CLI
        0x60,                  # RTS
    ])
    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xce_jmp_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes, end @${0x0801+len(code)-1:04X}')

if __name__ == '__main__':
    sys.exit(main() or 0)
