#!/usr/bin/env python3
"""Disassemble the Doom loader at its execution address ($0700).

Loader copies $0820..$08DA -> $0700..$07BA, then JMP $0700.
"""
import sys

with open(r'C:\LLM\C64\MiSTerSuperCPU\loader.prg', 'rb') as f:
    raw = f.read()

# Strip 2-byte load address
load_addr = raw[0] | (raw[1] << 8)  # $0801
data = raw[2:]
# data[0] is at memory $0801

# Slice $0820..$08DA which lands at $0700..$07BA after copy
src_start = 0x0820 - load_addr   # offset 0x1F
src_end   = 0x08DA - load_addr + 1
copy = data[src_start:src_end]

# Simple 6502 disassembler (covers what loader uses)
op_table = {
    0x00: ('BRK', 0), 0x18: ('CLC', 0), 0x40: ('RTI', 0), 0x60: ('RTS', 0),
    0x78: ('SEI', 0), 0xA8: ('TAY', 0), 0xAA: ('TAX', 0), 0xC8: ('INY', 0),
    0xCA: ('DEX', 0), 0xE8: ('INX', 0), 0xEA: ('NOP', 0), 0xFB: ('XCE', 0),
    0xD8: ('CLD', 0), 0xF8: ('SED', 0),
    0x5B: ('TCD', 0), 0x1B: ('TCS', 0), 0x80: ('BRA', 1),
    0x10: ('BPL', 1), 0x30: ('BMI', 1), 0x50: ('BVC', 1), 0x70: ('BVS', 1),
    0x90: ('BCC', 1), 0xB0: ('BCS', 1), 0xD0: ('BNE', 1), 0xF0: ('BEQ', 1),
    0xA9: ('LDA #', 1), 0xA2: ('LDX #', 1), 0xA0: ('LDY #', 1),
    0xC9: ('CMP #', 1), 0xE0: ('CPX #', 1), 0xC0: ('CPY #', 1),
    0x29: ('AND #', 1), 0x09: ('ORA #', 1), 0x49: ('EOR #', 1),
    0x69: ('ADC #', 1), 0xE9: ('SBC #', 1),
    0xC2: ('REP #', 1), 0xE2: ('SEP #', 1),
    0x85: ('STA $', 1), 0x86: ('STX $', 1), 0x84: ('STY $', 1),
    0xA5: ('LDA $', 1), 0xA6: ('LDX $', 1), 0xA4: ('LDY $', 1),
    0xC6: ('DEC $', 1), 0xE6: ('INC $', 1),
    0x95: ('STA $,X', 1), 0xB5: ('LDA $,X', 1),
    0x97: ('STA [$],Y', 1), 0xB7: ('LDA [$],Y', 1),
    0x07: ('ORA [$]', 1), 0x87: ('STA [$]', 1),
    0x8D: ('STA $', 2), 0xAD: ('LDA $', 2),
    0x8E: ('STX $', 2), 0xAE: ('LDX $', 2),
    0x8C: ('STY $', 2), 0xAC: ('LDY $', 2),
    0xCE: ('DEC $', 2), 0xEE: ('INC $', 2),
    0x9D: ('STA $,X', 2), 0xBD: ('LDA $,X', 2),
    0x4C: ('JMP $', 2), 0x20: ('JSR $', 2),
    0x6C: ('JMP ($', 2),  # special: ($abs)
    0xDC: ('JML [$', 2),  # 65816 long indirect
    0x5C: ('JML $', 3),   # 65816 long abs (3-byte address)
    0xAF: ('LDA $:', 3),  # 65816 LDA long
    0x8F: ('STA $:', 3),
    0x6B: ('RTL', 0), 0x82: ('BRL', 2),
}

def fmt_op(pc, op, sz, b1=0, b2=0, b3=0):
    name, _ = op_table.get(op, ('???', 0))
    if sz == 0:
        return name
    if sz == 1:
        if name in ('BPL', 'BMI', 'BVC', 'BVS', 'BCC', 'BCS', 'BNE', 'BEQ', 'BRA'):
            off = b1 if b1 < 128 else b1 - 256
            return '{} ${:04X}'.format(name, pc + 2 + off)
        return '{}{:02X}'.format(name, b1)
    if sz == 2:
        return '{}{:04X}'.format(name, b1 | (b2 << 8))
    if sz == 3:
        return '{}{:02X}:{:02X}{:02X}'.format(name, b3, b2, b1)
    return '???'

# Disassemble starting at $0700
pc = 0x0700
end_pc = 0x07BB  # length of copied region
i = 0
while i < len(copy) and pc < end_pc:
    op = copy[i]
    name, sz = op_table.get(op, ('DB ${:02X}'.format(op), 0))
    if sz == 0:
        print('{:04X}: {:02X}            {}'.format(pc, op, fmt_op(pc, op, sz)))
        pc += 1; i += 1
    elif sz == 1:
        b1 = copy[i+1] if i+1 < len(copy) else 0
        print('{:04X}: {:02X} {:02X}         {}'.format(pc, op, b1, fmt_op(pc, op, sz, b1)))
        pc += 2; i += 2
    elif sz == 2:
        b1 = copy[i+1] if i+1 < len(copy) else 0
        b2 = copy[i+2] if i+2 < len(copy) else 0
        print('{:04X}: {:02X} {:02X} {:02X}      {}'.format(pc, op, b1, b2, fmt_op(pc, op, sz, b1, b2)))
        pc += 3; i += 3
    elif sz == 3:
        b1 = copy[i+1] if i+1 < len(copy) else 0
        b2 = copy[i+2] if i+2 < len(copy) else 0
        b3 = copy[i+3] if i+3 < len(copy) else 0
        print('{:04X}: {:02X} {:02X} {:02X} {:02X}   {}'.format(pc, op, b1, b2, b3, fmt_op(pc, op, sz, b1, b2, b3)))
        pc += 4; i += 4

# Print the data tail at $07B5..
print()
print('Data tail (last 6 bytes of copy at $07B5..$07BA):')
for k in range(0xB5, 0xBB):
    print('  ${:04X} = ${:02X}'.format(0x0700 + k, copy[k]))
