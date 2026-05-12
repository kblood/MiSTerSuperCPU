#!/usr/bin/env python3
"""Characterize XCE-drop behavior across different following opcodes.

PRG runs 5 sub-tests in sequence; each:
  1. Pre-zeros a designated $C2xx byte
  2. SEI; CLC; XCE
  3. <Test instruction sequence>
  4. SEC; XCE; CLI

Tests:
  A) Following = LDA #$AA; STA $C200       (2-byte LDA + 3-byte STA)
  B) Following = NOP; LDA #$BB; STA $C201
  C) Following = JMP_abs(target); target: LDA #$CC; STA $C202
  D) Following = STA $C203 (no LDA in between — A holds whatever)
  E) Following = SEI (1-byte) + LDA #$EE + STA $C204
"""
import os, struct, sys

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08, 0x00,0x00, 0x9E, 0x32,0x30,0x36,0x31, 0x00, 0x00,0x00])
    code += stub
    assert 0x0801 + len(code) == 0x080D

    # ---- Pre-zero $C200..$C207 in pure emu mode -------------------------
    code += bytes([0xA9, 0x00])
    for i in range(8):
        code += bytes([0x8D, i, 0xC2])

    # ---- Test A: XCE then LDA #$AA; STA $C200 ----------------------------
    # Expected if no drop: $C200=$AA; if drop: $C200=A's pre-XCE value
    code += bytes([
        0x78, 0x18, 0xFB,
        0xA9, 0xAA,
        0x8D, 0x00, 0xC2,
        0x38, 0xFB,             # SEC; XCE -> emu
        0xA9, 0x55,             # LDA #$55 (sets A for next test, in emu so should always succeed)
    ])

    # ---- Test B: XCE then NOP; LDA #$BB; STA $C201 -----------------------
    # If drop affects only first opcode after XCE, NOP dropped → LDA #$BB runs → $C201=$BB
    # If drop affects 1-instruction (NOP entirely), still LDA #$BB runs.
    code += bytes([
        0x18, 0xFB,             # CLC; XCE -> native
        0xEA,                   # NOP
        0xA9, 0xBB,
        0x8D, 0x01, 0xC2,
        0x38, 0xFB,             # SEC; XCE -> emu
    ])

    # ---- Test C: XCE then JMP target; target writes #$CC -----------------
    # If JMP dropped, fall-through (LDA #$CC; STA $C202) runs from immediately after JMP.
    # Layout JMP target right after fall-through.
    code += bytes([
        0x18, 0xFB,             # CLC; XCE -> native
        0x4C,                   # JMP abs
    ])
    # placeholder operand bytes to be patched later
    jmp_operand_offset = len(code)
    code += bytes([0x00, 0x00])
    # Fall-through (location right after JMP), writes 0xDD:
    code += bytes([
        0xA9, 0xDD,
        0x8D, 0x02, 0xC2,
        0x38, 0xFB,             # SEC; XCE -> emu
        0x4C, 0xFF, 0xFF,       # JMP <end-of-test-C> placeholder to skip target if reached
    ])
    skip_target_offset = len(code) - 2
    # JMP target location (writes 0xCC):
    target_addr = 0x0801 + len(code)
    code += bytes([
        0xA9, 0xCC,
        0x8D, 0x02, 0xC2,
        0x38, 0xFB,             # SEC; XCE -> emu
    ])
    # End of test-C
    end_c_addr = 0x0801 + len(code)

    # Patch JMP operand
    code[jmp_operand_offset+0] = target_addr & 0xFF
    code[jmp_operand_offset+1] = (target_addr >> 8) & 0xFF
    # Patch skip-target JMP operand
    code[skip_target_offset+0] = end_c_addr & 0xFF
    code[skip_target_offset+1] = (end_c_addr >> 8) & 0xFF

    # ---- Test D: XCE then STA $C203 (no preceding LDA — A holds pre-XCE) -
    # Sets A to known $77 first.
    code += bytes([
        0xA9, 0x77,             # LDA #$77 (in emu after exits)
        0x18, 0xFB,             # CLC; XCE -> native
        0x8D, 0x03, 0xC2,       # STA $C203 (no LDA between — A should be $77 in either case)
        0x38, 0xFB,             # SEC; XCE -> emu
    ])

    # ---- Test E: XCE then SEI; LDA #$EE; STA $C204 -----------------------
    # If drop kills SEI, LDA $EE still runs → $C204=$EE
    code += bytes([
        0x18, 0xFB,             # CLC; XCE -> native
        0x78,                   # SEI (1-byte)
        0xA9, 0xEE,
        0x8D, 0x04, 0xC2,
        0x38, 0xFB,             # SEC; XCE -> emu
    ])

    # final cleanup
    code += bytes([0x58, 0x60])  # CLI; RTS

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xce_chars_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    end_addr = 0x0801 + len(code) - 1
    print(f'Wrote {out}: {len(prg)} bytes ($0801..${end_addr:04X})')
    print(f'  JMP target = ${target_addr:04X}, end-of-C = ${end_c_addr:04X}')

if __name__ == '__main__':
    sys.exit(main() or 0)
