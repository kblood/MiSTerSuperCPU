#!/usr/bin/env python3
"""Disassemble the start of doom.reu (65C816 native mode code)."""
import sys

with open('doom.reu', 'rb') as f:
    data = f.read(512)

opcodes = {
    0x78: ('SEI', 1), 0xD8: ('CLD', 1), 0x18: ('CLC', 1), 0xFB: ('XCE', 1),
    0x38: ('SEC', 1), 0xEA: ('NOP', 1), 0x60: ('RTS', 1), 0x6B: ('RTL', 1),
    0x40: ('RTI', 1), 0xDB: ('STP', 1), 0xCB: ('WAI', 1),
    0xC2: ('REP', 2), 0xE2: ('SEP', 2),
    0xA9: ('LDA imm', 2), 0xA2: ('LDX imm', 2), 0xA0: ('LDY imm', 2),
    0x8D: ('STA abs', 3), 0x8F: ('STA long', 4), 0x9C: ('STZ abs', 3),
    0x85: ('STA dp', 2), 0x64: ('STZ dp', 2), 0x86: ('STX dp', 2), 0x84: ('STY dp', 2),
    0xAD: ('LDA abs', 3), 0xAF: ('LDA long', 4),
    0xA5: ('LDA dp', 2), 0xA6: ('LDX dp', 2), 0xA4: ('LDY dp', 2),
    0x4C: ('JMP abs', 3), 0x5C: ('JML long', 4), 0x6C: ('JMP (abs)', 3),
    0x20: ('JSR abs', 3), 0x22: ('JSL long', 4),
    0xF0: ('BEQ rel', 2), 0xD0: ('BNE rel', 2), 0x90: ('BCC rel', 2), 0xB0: ('BCS rel', 2),
    0x30: ('BMI rel', 2), 0x10: ('BPL rel', 2), 0x80: ('BRA rel', 2),
    0x48: ('PHA', 1), 0x68: ('PLA', 1), 0x08: ('PHP', 1), 0x28: ('PLP', 1),
    0x8B: ('PHB', 1), 0xAB: ('PLB', 1), 0x0B: ('PHD', 1), 0x2B: ('PLD', 1),
    0x4B: ('PHK', 1), 0x5B: ('TCD', 1), 0x1B: ('TCS', 1), 0x3B: ('TSC', 1),
    0x7B: ('TDC', 1), 0xAA: ('TAX', 1), 0xA8: ('TAY', 1), 0x8A: ('TXA', 1),
    0x98: ('TYA', 1), 0xBA: ('TSX', 1), 0x9A: ('TXS', 1),
    0x29: ('AND imm', 2), 0x09: ('ORA imm', 2), 0x49: ('EOR imm', 2), 
    0xC9: ('CMP imm', 2), 0xE0: ('CPX imm', 2), 0xC0: ('CPY imm', 2),
    0x1A: ('INC A', 1), 0x3A: ('DEC A', 1), 0xE8: ('INX', 1), 0xCA: ('DEX', 1),
    0xC8: ('INY', 1), 0x88: ('DEY', 1),
    0x0A: ('ASL A', 1), 0x4A: ('LSR A', 1), 0x2A: ('ROL A', 1), 0x6A: ('ROR A', 1),
    0xEB: ('XBA', 1),
    0x9D: ('STA abs,X', 3), 0x99: ('STA abs,Y', 3),
    0xBD: ('LDA abs,X', 3), 0xB9: ('LDA abs,Y', 3),
    0x9F: ('STA long,X', 4), 0xBF: ('LDA long,X', 4),
    0xB5: ('LDA dp,X', 2), 0x95: ('STA dp,X', 2),
    0x54: ('MVN', 3), 0x44: ('MVP', 3),
    0x00: ('BRK', 2),  # BRK is 2 bytes (BRK + signature)
}

m_flag = 1  # 8-bit accum
x_flag = 1  # 8-bit index
pc = 0
base = 0x200000

while pc < 300 and pc < len(data):
    b = data[pc]
    if b in opcodes:
        name, size = opcodes[b]
        # Adjust immediate operand size for 16-bit modes
        if b in (0xA9, 0x29, 0x09, 0x49, 0xC9) and m_flag == 0:
            size = 3
        if b in (0xA2, 0xA0, 0xE0, 0xC0) and x_flag == 0:
            size = 3
        
        raw = ' '.join(f'{data[pc+i]:02X}' for i in range(min(size, len(data)-pc)))
        
        if size == 1:
            print(f'  {base+pc:06X}: {raw:12s} {name}')
        elif size == 2:
            op1 = data[pc+1] if pc+1 < len(data) else 0
            if 'rel' in name:
                target = base + pc + 2 + (op1 if op1 < 128 else op1 - 256)
                print(f'  {base+pc:06X}: {raw:12s} {name.split()[0]} ${target:06X}')
            else:
                print(f'  {base+pc:06X}: {raw:12s} {name} #${op1:02X}')
            if b == 0xC2:
                if op1 & 0x20: m_flag = 0
                if op1 & 0x10: x_flag = 0
            elif b == 0xE2:
                if op1 & 0x20: m_flag = 1
                if op1 & 0x10: x_flag = 1
        elif size == 3:
            lo = data[pc+1] if pc+1 < len(data) else 0
            hi = data[pc+2] if pc+2 < len(data) else 0
            addr = (hi << 8) | lo
            print(f'  {base+pc:06X}: {raw:12s} {name} ${addr:04X}')
        elif size == 4:
            lo = data[pc+1] if pc+1 < len(data) else 0
            hi = data[pc+2] if pc+2 < len(data) else 0
            bk = data[pc+3] if pc+3 < len(data) else 0
            addr = (bk << 16) | (hi << 8) | lo
            print(f'  {base+pc:06X}: {raw:12s} {name} ${addr:06X}')
        
        if b == 0xFB:  # XCE resets to safe
            pass  # track separately if needed
        pc += size
    else:
        print(f'  {base+pc:06X}: {b:02X}           .byte ${b:02X}')
        pc += 1
