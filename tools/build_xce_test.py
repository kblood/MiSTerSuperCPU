#!/usr/bin/env python3
"""xce_test.prg — Probe the after-XCE instruction-drop bug.

Layout (loaded at $0801, autorun via 0 SYS 2061):
  $080D: SEI; CLC; XCE                  ; enter native
  $0810..$081F: 16 instructions: LDA #$01..$10; STA $C200..$C20F
  $0830: SEC; XCE; CLI; RTS             ; back to emu mode

After RUN, PEEK 49664..49679 ($C200..$C20F) shows which writes committed.
If pos 0 ($C200) is the only one dropped, the hazard is exactly 1 instruction.
"""
import os, struct, sys

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08, 0x00,0x00, 0x9E, 0x32,0x30,0x36,0x31, 0x00, 0x00,0x00])
    code += stub
    assert 0x0801 + len(code) == 0x080D
    code += bytes([
        0x78,                  # SEI
        0x18,                  # CLC
        0xFB,                  # XCE  -> native
    ])
    # 16 writes: LDA #$10+i; STA $C200+i
    for i in range(16):
        val = 0x10 + i
        addr = 0xC200 + i
        code += bytes([0xA9, val, 0x8D, addr & 0xFF, (addr >> 8) & 0xFF])
    code += bytes([
        0x38,                  # SEC
        0xFB,                  # XCE -> emu
        0x58,                  # CLI
        0x60,                  # RTS
    ])
    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xce_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes')

if __name__ == '__main__':
    sys.exit(main() or 0)
