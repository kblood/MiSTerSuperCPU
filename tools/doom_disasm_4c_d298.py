#!/usr/bin/env python3
"""Decode bytes around bank $4C:$D298-$D2F0 — the runtime paging routine.

Each `JSL $00:$0700` is followed by 4 inline parameter bytes. We need to
determine what those bytes are (REU addr? dest addr?) and what the bank
$4C code does AFTER the loader returns.
"""
from __future__ import annotations
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DOOM_REU = REPO / "doom.reu"


def main():
    data = DOOM_REU.read_bytes()
    base = 0x4C * 0x10000

    # Print 256 bytes around $D298 with attempted disasm
    print("=== $4C:$D280-$D310 raw bytes ===\n")
    for off in range(0xD280, 0xD310, 16):
        chunk = data[base + off : base + off + 16]
        hex_part = " ".join(f"{b:02X}" for b in chunk)
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"  $4C:{off:04X}  {hex_part}  {ascii_part}")

    # Try to disasm $D2A8 sequence with knowledge that JSL is followed by inline args
    print("\n=== Manual disasm $4C:$D2A0-$D2F0 ===\n")
    # Recognize a few opcodes
    OP = {
        0x22: ("JSL", 4),  # 22 LL HH BB
        0xB4: ("LDY $zp,X", 2),  # B4 nn
        0x60: ("RTS", 1),
        0x6B: ("RTL", 1),
        0xA9: ("LDA #imm", 2),  # 8-bit M
        0x4C: ("JMP abs", 3),
        0x5C: ("JML long", 4),
        0xD0: ("BNE +imm", 2),
        0xF0: ("BEQ +imm", 2),
        0xB0: ("BCS +imm", 2),
        0x90: ("BCC +imm", 2),
        0xC9: ("CMP #imm", 2),
        0xE8: ("INX", 1),
        0xC8: ("INY", 1),
        0xCA: ("DEX", 1),
        0x88: ("DEY", 1),
        0xEA: ("NOP", 1),
        0x18: ("CLC", 1),
        0x38: ("SEC", 1),
        0xA2: ("LDX #imm", 2),
        0xA0: ("LDY #imm", 2),
        0x85: ("STA zp", 2),
        0x95: ("STA zp,X", 2),
        0x86: ("STX zp", 2),
        0x84: ("STY zp", 2),
        0xA5: ("LDA zp", 2),
        0xA6: ("LDX zp", 2),
        0xA4: ("LDY zp", 2),
        0x8D: ("STA abs", 3),
        0xAD: ("LDA abs", 3),
        0x9D: ("STA abs,X", 3),
        0xBD: ("LDA abs,X", 3),
        0x29: ("AND #imm", 2),
        0x09: ("ORA #imm", 2),
    }

    pc = 0xD298
    end = 0xD320
    while pc < end:
        b = data[base + pc]
        if b in OP:
            name, ln = OP[b]
            operand = data[base + pc + 1 : base + pc + ln]
            ophex = " ".join(f"{x:02X}" for x in [b] + list(operand))
            # If JSL, format target
            if b == 0x22 and len(operand) == 3:
                tgt = operand[0] | (operand[1] << 8)
                bank = operand[2]
                print(f"  $4C:{pc:04X}  {ophex:<14} {name} ${bank:02X}:${tgt:04X}")
            elif b in (0xD0, 0xF0, 0xB0, 0x90):  # branch
                disp = operand[0] if operand[0] < 128 else operand[0] - 256
                tgt = pc + 2 + disp
                print(f"  $4C:{pc:04X}  {ophex:<14} {name} -> $4C:${tgt & 0xFFFF:04X}")
            else:
                print(f"  $4C:{pc:04X}  {ophex:<14} {name}")
            pc += ln
        else:
            print(f"  $4C:{pc:04X}  {b:02X}             ???")
            pc += 1

    # Also check what's BEFORE $D298 (the wait might be earlier)
    print("\n=== $4C:$D250-$D298 (pre-paging) ===\n")
    for off in range(0xD250, 0xD298, 16):
        chunk = data[base + off : base + off + 16]
        hex_part = " ".join(f"{b:02X}" for b in chunk)
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"  $4C:{off:04X}  {hex_part}  {ascii_part}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
