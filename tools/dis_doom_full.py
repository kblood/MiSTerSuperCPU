#!/usr/bin/env python3
"""Disassemble doom.reu from the game entry point at offset $200000."""
import sys

with open('doom.reu', 'rb') as f:
    f.seek(0x200000)
    data = f.read(2048)

# Full 65C816 opcode table: (mnemonic, addr_mode, base_size)
# addr_mode: 'imp'=implied, 'imm_a'=imm accum, 'imm_x'=imm index, 
#            'dp', 'abs', 'long', 'rel8', 'rel16', etc.
OPCODES = {
    0x00: ('BRK', 'imm', 2), 0x01: ('ORA', '(dp,X)', 2), 0x02: ('COP', 'imm', 2),
    0x03: ('ORA', 'sr,S', 2), 0x04: ('TSB', 'dp', 2), 0x05: ('ORA', 'dp', 2),
    0x06: ('ASL', 'dp', 2), 0x07: ('ORA', '[dp]', 2), 0x08: ('PHP', 'imp', 1),
    0x09: ('ORA', 'imm_a', 2), 0x0A: ('ASL', 'A', 1), 0x0B: ('PHD', 'imp', 1),
    0x0C: ('TSB', 'abs', 3), 0x0D: ('ORA', 'abs', 3), 0x0E: ('ASL', 'abs', 3),
    0x0F: ('ORA', 'long', 4), 0x10: ('BPL', 'rel8', 2),
    0x11: ('ORA', '(dp),Y', 2), 0x12: ('ORA', '(dp)', 2), 0x13: ('ORA', '(sr,S),Y', 2),
    0x14: ('TRB', 'dp', 2), 0x15: ('ORA', 'dp,X', 2), 0x16: ('ASL', 'dp,X', 2),
    0x17: ('ORA', '[dp],Y', 2), 0x18: ('CLC', 'imp', 1), 0x19: ('ORA', 'abs,Y', 3),
    0x1A: ('INC', 'A', 1), 0x1B: ('TCS', 'imp', 1), 0x1C: ('TRB', 'abs', 3),
    0x1D: ('ORA', 'abs,X', 3), 0x1E: ('ASL', 'abs,X', 3), 0x1F: ('ORA', 'long,X', 4),
    0x20: ('JSR', 'abs', 3), 0x21: ('AND', '(dp,X)', 2), 0x22: ('JSL', 'long', 4),
    0x23: ('AND', 'sr,S', 2), 0x24: ('BIT', 'dp', 2), 0x25: ('AND', 'dp', 2),
    0x26: ('ROL', 'dp', 2), 0x27: ('AND', '[dp]', 2), 0x28: ('PLP', 'imp', 1),
    0x29: ('AND', 'imm_a', 2), 0x2A: ('ROL', 'A', 1), 0x2B: ('PLD', 'imp', 1),
    0x2C: ('BIT', 'abs', 3), 0x2D: ('AND', 'abs', 3), 0x2E: ('ROL', 'abs', 3),
    0x2F: ('AND', 'long', 4), 0x30: ('BMI', 'rel8', 2),
    0x31: ('AND', '(dp),Y', 2), 0x32: ('AND', '(dp)', 2), 0x33: ('AND', '(sr,S),Y', 2),
    0x34: ('BIT', 'dp,X', 2), 0x35: ('AND', 'dp,X', 2), 0x36: ('ROL', 'dp,X', 2),
    0x37: ('AND', '[dp],Y', 2), 0x38: ('SEC', 'imp', 1), 0x39: ('AND', 'abs,Y', 3),
    0x3A: ('DEC', 'A', 1), 0x3B: ('TSC', 'imp', 1), 0x3C: ('BIT', 'abs,X', 3),
    0x3D: ('AND', 'abs,X', 3), 0x3E: ('ROL', 'abs,X', 3), 0x3F: ('AND', 'long,X', 4),
    0x40: ('RTI', 'imp', 1), 0x41: ('EOR', '(dp,X)', 2), 0x42: ('WDM', 'imm', 2),
    0x43: ('EOR', 'sr,S', 2), 0x44: ('MVP', 'src,dst', 3), 0x45: ('EOR', 'dp', 2),
    0x46: ('LSR', 'dp', 2), 0x47: ('EOR', '[dp]', 2), 0x48: ('PHA', 'imp', 1),
    0x49: ('EOR', 'imm_a', 2), 0x4A: ('LSR', 'A', 1), 0x4B: ('PHK', 'imp', 1),
    0x4C: ('JMP', 'abs', 3), 0x4D: ('EOR', 'abs', 3), 0x4E: ('LSR', 'abs', 3),
    0x4F: ('EOR', 'long', 4), 0x50: ('BVC', 'rel8', 2),
    0x51: ('EOR', '(dp),Y', 2), 0x52: ('EOR', '(dp)', 2), 0x53: ('EOR', '(sr,S),Y', 2),
    0x54: ('MVN', 'src,dst', 3), 0x55: ('EOR', 'dp,X', 2), 0x56: ('LSR', 'dp,X', 2),
    0x57: ('EOR', '[dp],Y', 2), 0x58: ('CLI', 'imp', 1), 0x59: ('EOR', 'abs,Y', 3),
    0x5A: ('PHY', 'imp', 1), 0x5B: ('TCD', 'imp', 1), 0x5C: ('JML', 'long', 4),
    0x5D: ('EOR', 'abs,X', 3), 0x5E: ('LSR', 'abs,X', 3), 0x5F: ('EOR', 'long,X', 4),
    0x60: ('RTS', 'imp', 1), 0x61: ('ADC', '(dp,X)', 2), 0x62: ('PER', 'rel16', 3),
    0x63: ('ADC', 'sr,S', 2), 0x64: ('STZ', 'dp', 2), 0x65: ('ADC', 'dp', 2),
    0x66: ('ROR', 'dp', 2), 0x67: ('ADC', '[dp]', 2), 0x68: ('PLA', 'imp', 1),
    0x69: ('ADC', 'imm_a', 2), 0x6A: ('ROR', 'A', 1), 0x6B: ('RTL', 'imp', 1),
    0x6C: ('JMP', '(abs)', 3), 0x6D: ('ADC', 'abs', 3), 0x6E: ('ROR', 'abs', 3),
    0x6F: ('ADC', 'long', 4), 0x70: ('BVS', 'rel8', 2),
    0x71: ('ADC', '(dp),Y', 2), 0x72: ('ADC', '(dp)', 2), 0x73: ('ADC', '(sr,S),Y', 2),
    0x74: ('STZ', 'dp,X', 2), 0x75: ('ADC', 'dp,X', 2), 0x76: ('ROR', 'dp,X', 2),
    0x77: ('ADC', '[dp],Y', 2), 0x78: ('SEI', 'imp', 1), 0x79: ('ADC', 'abs,Y', 3),
    0x7A: ('PLY', 'imp', 1), 0x7B: ('TDC', 'imp', 1), 0x7C: ('JMP', '(abs,X)', 3),
    0x7D: ('ADC', 'abs,X', 3), 0x7E: ('ROR', 'abs,X', 3), 0x7F: ('ADC', 'long,X', 4),
    0x80: ('BRA', 'rel8', 2), 0x81: ('STA', '(dp,X)', 2), 0x82: ('BRL', 'rel16', 3),
    0x83: ('STA', 'sr,S', 2), 0x84: ('STY', 'dp', 2), 0x85: ('STA', 'dp', 2),
    0x86: ('STX', 'dp', 2), 0x87: ('STA', '[dp]', 2), 0x88: ('DEY', 'imp', 1),
    0x89: ('BIT', 'imm_a', 2), 0x8A: ('TXA', 'imp', 1), 0x8B: ('PHB', 'imp', 1),
    0x8C: ('STY', 'abs', 3), 0x8D: ('STA', 'abs', 3), 0x8E: ('STX', 'abs', 3),
    0x8F: ('STA', 'long', 4), 0x90: ('BCC', 'rel8', 2),
    0x91: ('STA', '(dp),Y', 2), 0x92: ('STA', '(dp)', 2), 0x93: ('STA', '(sr,S),Y', 2),
    0x94: ('STY', 'dp,X', 2), 0x95: ('STA', 'dp,X', 2), 0x96: ('STX', 'dp,Y', 2),
    0x97: ('STA', '[dp],Y', 2), 0x98: ('TYA', 'imp', 1), 0x99: ('STA', 'abs,Y', 3),
    0x9A: ('TXS', 'imp', 1), 0x9B: ('TXY', 'imp', 1), 0x9C: ('STZ', 'abs', 3),
    0x9D: ('STA', 'abs,X', 3), 0x9E: ('STZ', 'abs,X', 3), 0x9F: ('STA', 'long,X', 4),
    0xA0: ('LDY', 'imm_x', 2), 0xA1: ('LDA', '(dp,X)', 2), 0xA2: ('LDX', 'imm_x', 2),
    0xA3: ('LDA', 'sr,S', 2), 0xA4: ('LDY', 'dp', 2), 0xA5: ('LDA', 'dp', 2),
    0xA6: ('LDX', 'dp', 2), 0xA7: ('LDA', '[dp]', 2), 0xA8: ('TAY', 'imp', 1),
    0xA9: ('LDA', 'imm_a', 2), 0xAA: ('TAX', 'imp', 1), 0xAB: ('PLB', 'imp', 1),
    0xAC: ('LDY', 'abs', 3), 0xAD: ('LDA', 'abs', 3), 0xAE: ('LDX', 'abs', 3),
    0xAF: ('LDA', 'long', 4), 0xB0: ('BCS', 'rel8', 2),
    0xB1: ('LDA', '(dp),Y', 2), 0xB2: ('LDA', '(dp)', 2), 0xB3: ('LDA', '(sr,S),Y', 2),
    0xB4: ('LDY', 'dp,X', 2), 0xB5: ('LDA', 'dp,X', 2), 0xB6: ('LDX', 'dp,Y', 2),
    0xB7: ('LDA', '[dp],Y', 2), 0xB8: ('CLV', 'imp', 1), 0xB9: ('LDA', 'abs,Y', 3),
    0xBA: ('TSX', 'imp', 1), 0xBB: ('TYX', 'imp', 1), 0xBC: ('LDY', 'abs,X', 3),
    0xBD: ('LDA', 'abs,X', 3), 0xBE: ('LDX', 'abs,Y', 3), 0xBF: ('LDA', 'long,X', 4),
    0xC0: ('CPY', 'imm_x', 2), 0xC1: ('CMP', '(dp,X)', 2), 0xC2: ('REP', 'imm', 2),
    0xC3: ('CMP', 'sr,S', 2), 0xC4: ('CPY', 'dp', 2), 0xC5: ('CMP', 'dp', 2),
    0xC6: ('DEC', 'dp', 2), 0xC7: ('CMP', '[dp]', 2), 0xC8: ('INY', 'imp', 1),
    0xC9: ('CMP', 'imm_a', 2), 0xCA: ('DEX', 'imp', 1), 0xCB: ('WAI', 'imp', 1),
    0xCC: ('CPY', 'abs', 3), 0xCD: ('CMP', 'abs', 3), 0xCE: ('DEC', 'abs', 3),
    0xCF: ('CMP', 'long', 4), 0xD0: ('BNE', 'rel8', 2),
    0xD1: ('CMP', '(dp),Y', 2), 0xD2: ('CMP', '(dp)', 2), 0xD3: ('CMP', '(sr,S),Y', 2),
    0xD4: ('PEI', '(dp)', 2), 0xD5: ('CMP', 'dp,X', 2), 0xD6: ('DEC', 'dp,X', 2),
    0xD7: ('CMP', '[dp],Y', 2), 0xD8: ('CLD', 'imp', 1), 0xD9: ('CMP', 'abs,Y', 3),
    0xDA: ('PHX', 'imp', 1), 0xDB: ('STP', 'imp', 1), 0xDC: ('JML', '[abs]', 3),
    0xDD: ('CMP', 'abs,X', 3), 0xDE: ('DEC', 'abs,X', 3), 0xDF: ('CMP', 'long,X', 4),
    0xE0: ('CPX', 'imm_x', 2), 0xE1: ('SBC', '(dp,X)', 2), 0xE2: ('SEP', 'imm', 2),
    0xE3: ('SBC', 'sr,S', 2), 0xE4: ('CPX', 'dp', 2), 0xE5: ('SBC', 'dp', 2),
    0xE6: ('INC', 'dp', 2), 0xE7: ('SBC', '[dp]', 2), 0xE8: ('INX', 'imp', 1),
    0xE9: ('SBC', 'imm_a', 2), 0xEA: ('NOP', 'imp', 1), 0xEB: ('XBA', 'imp', 1),
    0xEC: ('CPX', 'abs', 3), 0xED: ('SBC', 'abs', 3), 0xEE: ('INC', 'abs', 3),
    0xEF: ('SBC', 'long', 4), 0xF0: ('BEQ', 'rel8', 2),
    0xF1: ('SBC', '(dp),Y', 2), 0xF2: ('SBC', '(dp)', 2), 0xF3: ('SBC', '(sr,S),Y', 2),
    0xF4: ('PEA', 'abs', 3), 0xF5: ('SBC', 'dp,X', 2), 0xF6: ('INC', 'dp,X', 2),
    0xF7: ('SBC', '[dp],Y', 2), 0xF8: ('SED', 'imp', 1), 0xF9: ('SBC', 'abs,Y', 3),
    0xFA: ('PLX', 'imp', 1), 0xFB: ('XCE', 'imp', 1), 0xFC: ('JSR', '(abs,X)', 3),
    0xFD: ('SBC', 'abs,X', 3), 0xFE: ('INC', 'abs,X', 3), 0xFF: ('SBC', 'long,X', 4),
}

m_flag = 1  # 8-bit accumulator (emulation default)
x_flag = 1  # 8-bit index
pc = 0
base = 0x200000
count = 0

while pc < len(data) and count < 200:
    if pc >= len(data):
        break
    b = data[pc]
    
    if b not in OPCODES:
        print(f'  {base+pc:06X}: {b:02X}           ???')
        pc += 1
        count += 1
        continue
    
    mnem, mode, size = OPCODES[b]
    
    # Adjust size for 16-bit immediate
    if mode == 'imm_a' and m_flag == 0:
        size = 3
    elif mode == 'imm_x' and x_flag == 0:
        size = 3
    
    if pc + size > len(data):
        break
    
    raw = ' '.join(f'{data[pc+i]:02X}' for i in range(size))
    
    comment = ''
    if size == 1:
        operand = ''
    elif mode == 'rel8':
        op1 = data[pc+1]
        target = base + pc + 2 + (op1 if op1 < 128 else op1 - 256)
        operand = f'${target:06X}'
    elif mode == 'rel16':
        lo, hi = data[pc+1], data[pc+2]
        offset = (hi << 8) | lo
        if offset >= 0x8000: offset -= 0x10000
        target = base + pc + 3 + offset
        operand = f'${target:06X}'
    elif mode in ('imm', 'imm_a', 'imm_x'):
        if size == 2:
            operand = f'#${data[pc+1]:02X}'
        else:
            operand = f'#${data[pc+2]:02X}{data[pc+1]:02X}'
    elif mode == 'dp':
        operand = f'${data[pc+1]:02X}'
    elif mode in ('dp,X', 'dp,Y'):
        operand = f'${data[pc+1]:02X},{mode[-1]}'
    elif mode == '(dp)':
        operand = f'(${data[pc+1]:02X})'
    elif mode == '(dp,X)':
        operand = f'(${data[pc+1]:02X},X)'
    elif mode == '(dp),Y':
        operand = f'(${data[pc+1]:02X}),Y'
    elif mode == '[dp]':
        operand = f'[${data[pc+1]:02X}]'
    elif mode == '[dp],Y':
        operand = f'[${data[pc+1]:02X}],Y'
    elif mode == 'sr,S':
        operand = f'${data[pc+1]:02X},S'
    elif mode == '(sr,S),Y':
        operand = f'(${data[pc+1]:02X},S),Y'
    elif mode == 'abs':
        addr = data[pc+1] | (data[pc+2] << 8)
        operand = f'${addr:04X}'
        if addr == 0xD021: comment = '; BG color'
        elif addr == 0xD020: comment = '; border color'
        elif addr == 0xD07A: comment = '; SCPU 1MHz'
        elif addr == 0xD07B: comment = '; SCPU 20MHz'
        elif addr == 0xD078: comment = '; SCPU cache flush'
        elif addr == 0xD07E: comment = '; SCPU SIMM cfg'
        elif addr == 0xD07F: comment = '; SCPU speed reg'
        elif 0xDC00 <= addr <= 0xDC0F: comment = f'; CIA1'
        elif 0xDD00 <= addr <= 0xDD0F: comment = f'; CIA2'
        elif 0xD000 <= addr <= 0xD02E: comment = f'; VIC-II'
    elif mode in ('abs,X', 'abs,Y'):
        addr = data[pc+1] | (data[pc+2] << 8)
        operand = f'${addr:04X},{mode[-1]}'
    elif mode == '(abs)':
        addr = data[pc+1] | (data[pc+2] << 8)
        operand = f'(${addr:04X})'
    elif mode == '(abs,X)':
        addr = data[pc+1] | (data[pc+2] << 8)
        operand = f'(${addr:04X},X)'
    elif mode == '[abs]':
        addr = data[pc+1] | (data[pc+2] << 8)
        operand = f'[${addr:04X}]'
    elif mode == 'long':
        addr = data[pc+1] | (data[pc+2] << 8) | (data[pc+3] << 16)
        operand = f'${addr:06X}'
    elif mode == 'long,X':
        addr = data[pc+1] | (data[pc+2] << 8) | (data[pc+3] << 16)
        operand = f'${addr:06X},X'
    elif mode == 'src,dst':
        operand = f'${data[pc+1]:02X},${data[pc+2]:02X}'
        comment = f'; {mnem} dst=${data[pc+2]:02X} src=${data[pc+1]:02X}'
    elif mode in ('A', 'imp'):
        operand = ''
    else:
        operand = f'???({mode})'
    
    # Track flag changes
    if b == 0xC2:  # REP
        v = data[pc+1]
        if v & 0x20: m_flag = 0; comment += ' ; M=16bit'
        if v & 0x10: x_flag = 0; comment += ' ; X=16bit'
    elif b == 0xE2:  # SEP
        v = data[pc+1]
        if v & 0x20: m_flag = 1; comment += ' ; M=8bit'
        if v & 0x10: x_flag = 1; comment += ' ; X=8bit'
    elif b == 0xFB:  # XCE
        comment = '; swap C<->E'
    
    line = f'  {base+pc:06X}: {raw:12s} {mnem} {operand}'.rstrip()
    if comment:
        line = f'{line:50s} {comment}'
    print(line)
    
    pc += size
    count += 1
    
    # Stop at unconditional jumps for readability
    if b in (0x4C, 0x5C, 0x6C, 0x80, 0x82) and count > 50:
        print(f'  ... (unconditional branch, stopping)')
        break
