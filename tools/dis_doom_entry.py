#!/usr/bin/env python3
"""Disassemble the doom.reu entry point at bank $20:$0000"""

import sys

with open('doom.reu', 'rb') as f:
    f.seek(0x200000)
    data = f.read(512)

pc = 0x200000
i = 0
m16 = False
x16 = False

opcodes = {
    0x78: ('SEI', 'imp', 1), 0xD8: ('CLD', 'imp', 1), 0x18: ('CLC', 'imp', 1),
    0xFB: ('XCE', 'imp', 1), 0x38: ('SEC', 'imp', 1), 0x58: ('CLI', 'imp', 1),
    0xC2: ('REP', 'imm8', 2), 0xE2: ('SEP', 'imm8', 2),
    0xA9: ('LDA', 'imm', None), 0xA2: ('LDX', 'imm_x', None),
    0xA0: ('LDY', 'imm_x', None),
    0x5B: ('TCD', 'imp', 1), 0x1B: ('TCS', 'imp', 1),
    0x64: ('STZ', 'dp', 2), 0x74: ('STZ', 'dpx', 2),
    0x9C: ('STZ', 'abs', 3), 0x9E: ('STZ', 'absx', 3),
    0x8D: ('STA', 'abs', 3), 0x85: ('STA', 'dp', 2), 0x8F: ('STA', 'long', 4),
    0xAD: ('LDA', 'abs', 3), 0xA5: ('LDA', 'dp', 2), 0xAF: ('LDA', 'long', 4),
    0x48: ('PHA', 'imp', 1), 0xAB: ('PLB', 'imp', 1),
    0x4C: ('JMP', 'abs', 3), 0x5C: ('JML', 'long', 4), 0x6C: ('JMP', 'ind', 3),
    0x20: ('JSR', 'abs', 3), 0x22: ('JSL', 'long', 4), 0x60: ('RTS', 'imp', 1),
    0x6B: ('RTL', 'imp', 1), 0x40: ('RTI', 'imp', 1),
    0xDA: ('PHX', 'imp', 1), 0xFA: ('PLX', 'imp', 1),
    0x29: ('AND', 'imm', None), 0x09: ('ORA', 'imm', None),
    0xC9: ('CMP', 'imm', None), 0xE0: ('CPX', 'imm_x', None),
    0xF0: ('BEQ', 'rel', 2), 0xD0: ('BNE', 'rel', 2),
    0x10: ('BPL', 'rel', 2), 0x30: ('BMI', 'rel', 2),
    0x90: ('BCC', 'rel', 2), 0xB0: ('BCS', 'rel', 2),
    0x80: ('BRA', 'rel', 2), 0x82: ('BRL', 'rell', 3),
    0xCA: ('DEX', 'imp', 1), 0xE8: ('INX', 'imp', 1),
    0x88: ('DEY', 'imp', 1), 0xC8: ('INY', 'imp', 1),
    0xEA: ('NOP', 'imp', 1),
    0x54: ('MVN', 'mvn', 3), 0x44: ('MVP', 'mvn', 3),
    0x00: ('BRK', 'imm8', 2),
    0x8E: ('STX', 'abs', 3), 0x8C: ('STY', 'abs', 3),
    0xAE: ('LDX', 'abs', 3), 0xAC: ('LDY', 'abs', 3),
    0xA6: ('LDX', 'dp', 2), 0xA4: ('LDY', 'dp', 2),
    0x86: ('STX', 'dp', 2), 0x84: ('STY', 'dp', 2),
    0xCE: ('DEC', 'abs', 3), 0xEE: ('INC', 'abs', 3),
    0xC6: ('DEC', 'dp', 2), 0xE6: ('INC', 'dp', 2),
    0x3A: ('DEC', 'imp', 1), 0x1A: ('INC', 'imp', 1),
    0x0A: ('ASL', 'imp', 1), 0x4A: ('LSR', 'imp', 1),
    0x2A: ('ROL', 'imp', 1), 0x6A: ('ROR', 'imp', 1),
    0xAA: ('TAX', 'imp', 1), 0xA8: ('TAY', 'imp', 1),
    0x8A: ('TXA', 'imp', 1), 0x98: ('TYA', 'imp', 1),
    0x9A: ('TXS', 'imp', 1), 0xBA: ('TSX', 'imp', 1),
    0xEB: ('XBA', 'imp', 1),
    0xF4: ('PEA', 'abs', 3), 0xD4: ('PEI', 'dp', 2),
    0x4B: ('PHK', 'imp', 1), 0x0B: ('PHD', 'imp', 1),
    0x2B: ('PLD', 'imp', 1),
    0x7A: ('PLY', 'imp', 1), 0x5A: ('PHY', 'imp', 1),
    0x68: ('PLA', 'imp', 1), 0x28: ('PLP', 'imp', 1),
    0x08: ('PHP', 'imp', 1),
    0xCD: ('CMP', 'abs', 3), 0xC5: ('CMP', 'dp', 2),
    0x2C: ('BIT', 'abs', 3), 0x24: ('BIT', 'dp', 2),
    0x0D: ('ORA', 'abs', 3), 0x05: ('ORA', 'dp', 2),
    0x2D: ('AND', 'abs', 3), 0x25: ('AND', 'dp', 2),
    0x4D: ('EOR', 'abs', 3), 0x45: ('EOR', 'dp', 2),
    0x6D: ('ADC', 'abs', 3), 0x65: ('ADC', 'dp', 2),
    0xED: ('SBC', 'abs', 3), 0xE5: ('SBC', 'dp', 2),
    0x69: ('ADC', 'imm', None), 0xE9: ('SBC', 'imm', None),
    0x49: ('EOR', 'imm', None),
    0x0E: ('ASL', 'abs', 3), 0x4E: ('LSR', 'abs', 3),
    0x2E: ('ROL', 'abs', 3), 0x6E: ('ROR', 'abs', 3),
    0x91: ('STA', 'idy', 2), 0xB1: ('LDA', 'idy', 2),
    0x81: ('STA', 'idx', 2), 0xA1: ('LDA', 'idx', 2),
    0x92: ('STA', 'idp', 2), 0xB2: ('LDA', 'idp', 2),
    0x87: ('STA', 'idl', 2), 0xA7: ('LDA', 'idl', 2),
    0x97: ('STA', 'idly', 2), 0xB7: ('LDA', 'idly', 2),
    0x95: ('STA', 'dpx', 2), 0xB5: ('LDA', 'dpx', 2),
    0x9D: ('STA', 'absx', 3), 0xBD: ('LDA', 'absx', 3),
    0x99: ('STA', 'absy', 3), 0xB9: ('LDA', 'absy', 3),
    0x9F: ('STA', 'longx', 4), 0xBF: ('LDA', 'longx', 4),
    0xBE: ('LDX', 'absy', 3), 0xBC: ('LDY', 'absx', 3),
    0x96: ('STX', 'dpy', 2), 0xB6: ('LDX', 'dpy', 2),
    0x94: ('STY', 'dpx', 2), 0xB4: ('LDY', 'dpx', 2),
    0xFC: ('JSR', 'indx', 3),
    0x7C: ('JMP', 'indx', 3),
    0xDC: ('JML', 'indl', 3),
}

addr_comments = {
    0xDC0E: 'CIA1 CRA', 0xDC0F: 'CIA1 CRB', 0xDC0D: 'CIA1 ICR',
    0xDD0E: 'CIA2 CRA', 0xDD0F: 'CIA2 CRB', 0xDD0D: 'CIA2 ICR',
    0xD015: 'VIC sprite enable', 0xD01A: 'VIC IRQ mask',
    0xD019: 'VIC IRQ flags', 0xD020: 'VIC border color',
    0xD021: 'VIC bg color', 0xD011: 'VIC ctrl1', 0xD016: 'VIC ctrl2',
    0xD018: 'VIC memory', 0xD012: 'VIC raster',
    0xD078: 'SCPU cache flush', 0xD07A: 'SCPU sw 1MHz',
    0xD07B: 'SCPU sw turbo', 0xD07E: 'SCPU ROM vis+reg enable',
    0xD07F: 'SCPU reg disable',
}

while i < min(300, len(data)):
    op = data[i]
    if op in opcodes:
        name, mode, size = opcodes[op]
        if size is None:
            if mode == 'imm':
                size = 3 if m16 else 2
            elif mode == 'imm_x':
                size = 3 if x16 else 2

        if i + size > len(data):
            break

        operand_bytes = data[i+1:i+size]

        if mode == 'imp': operand = ''
        elif mode == 'imm8': operand = ' #$%02X' % operand_bytes[0]
        elif mode == 'imm':
            if m16:
                val = operand_bytes[0] | (operand_bytes[1] << 8)
                operand = ' #$%04X' % val
            else:
                operand = ' #$%02X' % operand_bytes[0]
        elif mode == 'imm_x':
            if x16:
                val = operand_bytes[0] | (operand_bytes[1] << 8)
                operand = ' #$%04X' % val
            else:
                operand = ' #$%02X' % operand_bytes[0]
        elif mode == 'dp': operand = ' $%02X' % operand_bytes[0]
        elif mode == 'dpx': operand = ' $%02X,X' % operand_bytes[0]
        elif mode == 'dpy': operand = ' $%02X,Y' % operand_bytes[0]
        elif mode == 'abs':
            val = operand_bytes[0] | (operand_bytes[1] << 8)
            operand = ' $%04X' % val
        elif mode == 'absx':
            val = operand_bytes[0] | (operand_bytes[1] << 8)
            operand = ' $%04X,X' % val
        elif mode == 'absy':
            val = operand_bytes[0] | (operand_bytes[1] << 8)
            operand = ' $%04X,Y' % val
        elif mode == 'long':
            val = operand_bytes[0] | (operand_bytes[1] << 8) | (operand_bytes[2] << 16)
            operand = ' $%06X' % val
        elif mode == 'longx':
            val = operand_bytes[0] | (operand_bytes[1] << 8) | (operand_bytes[2] << 16)
            operand = ' $%06X,X' % val
        elif mode == 'rel':
            offset_val = operand_bytes[0]
            if offset_val >= 0x80: offset_val -= 256
            target = (pc + i + 2 + offset_val) & 0xFFFFFF
            operand = ' $%06X' % target
        elif mode == 'rell':
            offset_val = operand_bytes[0] | (operand_bytes[1] << 8)
            if offset_val >= 0x8000: offset_val -= 0x10000
            target = (pc + i + 3 + offset_val) & 0xFFFFFF
            operand = ' $%06X' % target
        elif mode == 'ind':
            val = operand_bytes[0] | (operand_bytes[1] << 8)
            operand = ' ($%04X)' % val
        elif mode == 'indx':
            val = operand_bytes[0] | (operand_bytes[1] << 8)
            operand = ' ($%04X,X)' % val
        elif mode == 'indl':
            val = operand_bytes[0] | (operand_bytes[1] << 8)
            operand = ' [$%04X]' % val
        elif mode == 'mvn':
            operand = ' $%02X,$%02X' % (operand_bytes[0], operand_bytes[1])
        elif mode in ('idy',):
            operand = ' ($%02X),Y' % operand_bytes[0]
        elif mode in ('idx',):
            operand = ' ($%02X,X)' % operand_bytes[0]
        elif mode in ('idp',):
            operand = ' ($%02X)' % operand_bytes[0]
        elif mode in ('idl',):
            operand = ' [$%02X]' % operand_bytes[0]
        elif mode in ('idly',):
            operand = ' [$%02X],Y' % operand_bytes[0]
        else:
            operand = ' ???'

        # Track mode changes
        if op == 0xC2:  # REP
            if operand_bytes[0] & 0x20: m16 = True
            if operand_bytes[0] & 0x10: x16 = True
        elif op == 0xE2:  # SEP
            if operand_bytes[0] & 0x20: m16 = False
            if operand_bytes[0] & 0x10: x16 = False
        elif op == 0xFB:  # XCE
            m16 = False; x16 = False

        hex_bytes = ' '.join('%02X' % data[i+j] for j in range(size))
        comment = ''
        if mode in ('abs', 'absx', 'absy') and size == 3:
            val = operand_bytes[0] | (operand_bytes[1] << 8)
            if val in addr_comments:
                comment = '  ; ' + addr_comments[val]

        print('$%06X: %-20s %s%s%s' % (pc+i, hex_bytes, name, operand, comment))
        i += size
    else:
        print('$%06X: %02X                   .byte $%02X' % (pc+i, data[i], data[i]))
        i += 1
