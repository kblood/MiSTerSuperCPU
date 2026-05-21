#!/usr/bin/env python3
"""Simple 65816 disassembler for doom.reu analysis."""
import sys

opcodes = {
    0x00: ('BRK', 'imm8'), 0x01: ('ORA', 'indx'), 0x02: ('COP', 'imm8'),
    0x03: ('ORA', 'sr'), 0x04: ('TSB', 'dp'), 0x05: ('ORA', 'dp'),
    0x06: ('ASL', 'dp'), 0x07: ('ORA', 'indl'), 0x08: ('PHP', 'imp'),
    0x09: ('ORA', 'imm_a'), 0x0A: ('ASL', 'acc'), 0x0B: ('PHD', 'imp'),
    0x0C: ('TSB', 'abs'), 0x0D: ('ORA', 'abs'), 0x0E: ('ASL', 'abs'),
    0x0F: ('ORA', 'abl'), 0x10: ('BPL', 'rel8'), 0x11: ('ORA', 'indy'),
    0x12: ('ORA', 'ind'), 0x13: ('ORA', 'sry'), 0x14: ('TRB', 'dp'),
    0x15: ('ORA', 'dpx'), 0x16: ('ASL', 'dpx'), 0x17: ('ORA', 'indly'),
    0x18: ('CLC', 'imp'), 0x19: ('ORA', 'aby'), 0x1A: ('INC', 'acc'),
    0x1B: ('TCS', 'imp'), 0x1C: ('TRB', 'abs'), 0x1D: ('ORA', 'abx'),
    0x1E: ('ASL', 'abx'), 0x1F: ('ORA', 'ablx'),
    0x20: ('JSR', 'abs'), 0x21: ('AND', 'indx'), 0x22: ('JSL', 'abl'),
    0x23: ('AND', 'sr'), 0x24: ('BIT', 'dp'), 0x25: ('AND', 'dp'),
    0x26: ('ROL', 'dp'), 0x27: ('AND', 'indl'), 0x28: ('PLP', 'imp'),
    0x29: ('AND', 'imm_a'), 0x2A: ('ROL', 'acc'), 0x2B: ('PLD', 'imp'),
    0x2C: ('BIT', 'abs'), 0x2D: ('AND', 'abs'), 0x2E: ('ROL', 'abs'),
    0x2F: ('AND', 'abl'), 0x30: ('BMI', 'rel8'), 0x31: ('AND', 'indy'),
    0x32: ('AND', 'ind'), 0x33: ('AND', 'sry'), 0x34: ('BIT', 'dpx'),
    0x35: ('AND', 'dpx'), 0x36: ('ROL', 'dpx'), 0x37: ('AND', 'indly'),
    0x38: ('SEC', 'imp'), 0x39: ('AND', 'aby'), 0x3A: ('DEC', 'acc'),
    0x3B: ('TSC', 'imp'), 0x3C: ('BIT', 'abx'), 0x3D: ('AND', 'abx'),
    0x3E: ('ROL', 'abx'), 0x3F: ('AND', 'ablx'),
    0x40: ('RTI', 'imp'), 0x41: ('EOR', 'indx'), 0x42: ('WDM', 'imm8'),
    0x43: ('EOR', 'sr'), 0x44: ('MVP', 'mv'), 0x45: ('EOR', 'dp'),
    0x46: ('LSR', 'dp'), 0x47: ('EOR', 'indl'), 0x48: ('PHA', 'imp'),
    0x49: ('EOR', 'imm_a'), 0x4A: ('LSR', 'acc'), 0x4B: ('PHK', 'imp'),
    0x4C: ('JMP', 'abs'), 0x4D: ('EOR', 'abs'), 0x4E: ('LSR', 'abs'),
    0x4F: ('EOR', 'abl'), 0x50: ('BVC', 'rel8'), 0x51: ('EOR', 'indy'),
    0x52: ('EOR', 'ind'), 0x53: ('EOR', 'sry'), 0x54: ('MVN', 'mv'),
    0x55: ('EOR', 'dpx'), 0x56: ('LSR', 'dpx'), 0x57: ('EOR', 'indly'),
    0x58: ('CLI', 'imp'), 0x59: ('EOR', 'aby'), 0x5A: ('PHY', 'imp'),
    0x5B: ('TCD', 'imp'), 0x5C: ('JML', 'abl'), 0x5D: ('EOR', 'abx'),
    0x5E: ('LSR', 'abx'), 0x5F: ('EOR', 'ablx'),
    0x60: ('RTS', 'imp'), 0x61: ('ADC', 'indx'), 0x62: ('PER', 'rel16'),
    0x63: ('ADC', 'sr'), 0x64: ('STZ', 'dp'), 0x65: ('ADC', 'dp'),
    0x66: ('ROR', 'dp'), 0x67: ('ADC', 'indl'), 0x68: ('PLA', 'imp'),
    0x69: ('ADC', 'imm_a'), 0x6A: ('ROR', 'acc'), 0x6B: ('RTL', 'imp'),
    0x6C: ('JMP', 'abind'), 0x6D: ('ADC', 'abs'), 0x6E: ('ROR', 'abs'),
    0x6F: ('ADC', 'abl'), 0x70: ('BVS', 'rel8'), 0x71: ('ADC', 'indy'),
    0x72: ('ADC', 'ind'), 0x73: ('ADC', 'sry'), 0x74: ('STZ', 'dpx'),
    0x75: ('ADC', 'dpx'), 0x76: ('ROR', 'dpx'), 0x77: ('ADC', 'indly'),
    0x78: ('SEI', 'imp'), 0x79: ('ADC', 'aby'), 0x7A: ('PLY', 'imp'),
    0x7B: ('TDC', 'imp'), 0x7C: ('JMP', 'abindx'), 0x7D: ('ADC', 'abx'),
    0x7E: ('ROR', 'abx'), 0x7F: ('ADC', 'ablx'),
    0x80: ('BRA', 'rel8'), 0x81: ('STA', 'indx'), 0x82: ('BRL', 'rel16'),
    0x83: ('STA', 'sr'), 0x84: ('STY', 'dp'), 0x85: ('STA', 'dp'),
    0x86: ('STX', 'dp'), 0x87: ('STA', 'indl'), 0x88: ('DEY', 'imp'),
    0x89: ('BIT', 'imm_a'), 0x8A: ('TXA', 'imp'), 0x8B: ('PHB', 'imp'),
    0x8C: ('STY', 'abs'), 0x8D: ('STA', 'abs'), 0x8E: ('STX', 'abs'),
    0x8F: ('STA', 'abl'), 0x90: ('BCC', 'rel8'), 0x91: ('STA', 'indy'),
    0x92: ('STA', 'ind'), 0x93: ('STA', 'sry'), 0x94: ('STY', 'dpx'),
    0x95: ('STA', 'dpx'), 0x96: ('STX', 'dpy'), 0x97: ('STA', 'indly'),
    0x98: ('TYA', 'imp'), 0x99: ('STA', 'aby'), 0x9A: ('TXS', 'imp'),
    0x9B: ('TXY', 'imp'), 0x9C: ('STZ', 'abs'), 0x9D: ('STA', 'abx'),
    0x9E: ('STZ', 'abx'), 0x9F: ('STA', 'ablx'),
    0xA0: ('LDY', 'imm_x'), 0xA1: ('LDA', 'indx'), 0xA2: ('LDX', 'imm_x'),
    0xA3: ('LDA', 'sr'), 0xA4: ('LDY', 'dp'), 0xA5: ('LDA', 'dp'),
    0xA6: ('LDX', 'dp'), 0xA7: ('LDA', 'indl'), 0xA8: ('TAY', 'imp'),
    0xA9: ('LDA', 'imm_a'), 0xAA: ('TAX', 'imp'), 0xAB: ('PLB', 'imp'),
    0xAC: ('LDY', 'abs'), 0xAD: ('LDA', 'abs'), 0xAE: ('LDX', 'abs'),
    0xAF: ('LDA', 'abl'), 0xB0: ('BCS', 'rel8'), 0xB1: ('LDA', 'indy'),
    0xB2: ('LDA', 'ind'), 0xB3: ('LDA', 'sry'), 0xB4: ('LDY', 'dpx'),
    0xB5: ('LDA', 'dpx'), 0xB6: ('LDX', 'dpy'), 0xB7: ('LDA', 'indly'),
    0xB8: ('CLV', 'imp'), 0xB9: ('LDA', 'aby'), 0xBA: ('TSX', 'imp'),
    0xBB: ('TYX', 'imp'), 0xBC: ('LDY', 'abx'), 0xBD: ('LDA', 'abx'),
    0xBE: ('LDX', 'aby'), 0xBF: ('LDA', 'ablx'),
    0xC0: ('CPY', 'imm_x'), 0xC1: ('CMP', 'indx'), 0xC2: ('REP', 'imm8'),
    0xC3: ('CMP', 'sr'), 0xC4: ('CPY', 'dp'), 0xC5: ('CMP', 'dp'),
    0xC6: ('DEC', 'dp'), 0xC7: ('CMP', 'indl'), 0xC8: ('INY', 'imp'),
    0xC9: ('CMP', 'imm_a'), 0xCA: ('DEX', 'imp'), 0xCB: ('WAI', 'imp'),
    0xCC: ('CPY', 'abs'), 0xCD: ('CMP', 'abs'), 0xCE: ('DEC', 'abs'),
    0xCF: ('CMP', 'abl'), 0xD0: ('BNE', 'rel8'), 0xD1: ('CMP', 'indy'),
    0xD2: ('CMP', 'ind'), 0xD3: ('CMP', 'sry'), 0xD4: ('PEI', 'dp'),
    0xD5: ('CMP', 'dpx'), 0xD6: ('DEC', 'dpx'), 0xD7: ('CMP', 'indly'),
    0xD8: ('CLD', 'imp'), 0xD9: ('CMP', 'aby'), 0xDA: ('PHX', 'imp'),
    0xDB: ('STP', 'imp'), 0xDC: ('JML', 'abind'),
    0xDD: ('CMP', 'abx'), 0xDE: ('DEC', 'abx'), 0xDF: ('CMP', 'ablx'),
    0xE0: ('CPX', 'imm_x'), 0xE1: ('SBC', 'indx'), 0xE2: ('SEP', 'imm8'),
    0xE3: ('SBC', 'sr'), 0xE4: ('CPX', 'dp'), 0xE5: ('SBC', 'dp'),
    0xE6: ('INC', 'dp'), 0xE7: ('SBC', 'indl'), 0xE8: ('INX', 'imp'),
    0xE9: ('SBC', 'imm_a'), 0xEA: ('NOP', 'imp'), 0xEB: ('XBA', 'imp'),
    0xEC: ('CPX', 'abs'), 0xED: ('SBC', 'abs'), 0xEE: ('INC', 'abs'),
    0xEF: ('SBC', 'abl'), 0xF0: ('BEQ', 'rel8'), 0xF1: ('SBC', 'indy'),
    0xF2: ('SBC', 'ind'), 0xF3: ('SBC', 'sry'), 0xF4: ('PEA', 'abs'),
    0xF5: ('SBC', 'dpx'), 0xF6: ('INC', 'dpx'), 0xF7: ('SBC', 'indly'),
    0xF8: ('SED', 'imp'), 0xF9: ('SBC', 'aby'), 0xFA: ('PLX', 'imp'),
    0xFB: ('XCE', 'imp'), 0xFC: ('JSR', 'abindx'), 0xFD: ('SBC', 'abx'),
    0xFE: ('INC', 'abx'), 0xFF: ('SBC', 'ablx'),
}

def operand_size(mode, m_flag, x_flag):
    sizes = {
        'imp': 0, 'acc': 0,
        'imm8': 1, 'rel8': 1, 'dp': 1, 'dpx': 1, 'dpy': 1,
        'indx': 1, 'indy': 1, 'ind': 1, 'indl': 1, 'indly': 1,
        'sr': 1, 'sry': 1,
        'abs': 2, 'abx': 2, 'aby': 2, 'abind': 2, 'abindx': 2,
        'rel16': 2, 'mv': 2,
        'abl': 3, 'ablx': 3,
    }
    if mode in sizes:
        return sizes[mode]
    if mode == 'imm_a':
        return 2 if m_flag == 0 else 1
    if mode == 'imm_x':
        return 2 if x_flag == 0 else 1
    return 0

def format_operand(mode, b, pc, m_flag, x_flag):
    if mode in ('imp', 'acc'):
        return ''
    if mode == 'imm8':
        return '#$%02X' % b[0]
    if mode == 'imm_a':
        return '#$%04X' % (b[1]*256+b[0]) if m_flag==0 else '#$%02X' % b[0]
    if mode == 'imm_x':
        return '#$%04X' % (b[1]*256+b[0]) if x_flag==0 else '#$%02X' % b[0]
    if mode == 'dp':
        return '$%02X' % b[0]
    if mode == 'dpx':
        return '$%02X,X' % b[0]
    if mode == 'dpy':
        return '$%02X,Y' % b[0]
    if mode == 'abs':
        return '$%04X' % (b[1]*256+b[0])
    if mode == 'abx':
        return '$%04X,X' % (b[1]*256+b[0])
    if mode == 'aby':
        return '$%04X,Y' % (b[1]*256+b[0])
    if mode == 'abl':
        return '$%06X' % (b[2]*65536+b[1]*256+b[0])
    if mode == 'ablx':
        return '$%06X,X' % (b[2]*65536+b[1]*256+b[0])
    if mode == 'rel8':
        offset = b[0] if b[0] < 128 else b[0] - 256
        target = (pc + 2 + offset) & 0xFFFF
        return '$%04X' % target
    if mode == 'rel16':
        offset = b[0] + b[1]*256
        if offset >= 0x8000: offset -= 0x10000
        target = (pc + 3 + offset) & 0xFFFF
        return '$%04X' % target
    if mode == 'ind':
        return '($%02X)' % b[0]
    if mode == 'indx':
        return '($%02X,X)' % b[0]
    if mode == 'indy':
        return '($%02X),Y' % b[0]
    if mode == 'indl':
        return '[$%02X]' % b[0]
    if mode == 'indly':
        return '[$%02X],Y' % b[0]
    if mode == 'sr':
        return '$%02X,S' % b[0]
    if mode == 'sry':
        return '($%02X,S),Y' % b[0]
    if mode == 'abind':
        return '($%04X)' % (b[1]*256+b[0])
    if mode == 'abindx':
        return '($%04X,X)' % (b[1]*256+b[0])
    if mode == 'mv':
        return '$%02X,$%02X' % (b[0], b[1])
    return '???'

def annotate(mnem, mode, b, pc):
    if mode == 'abs' and len(b) >= 2:
        addr = b[1]*256+b[0]
        if 0xDF00 <= addr <= 0xDF0A:
            names = {0xDF00:'STATUS', 0xDF01:'CMD', 0xDF02:'C64_LO', 0xDF03:'C64_HI',
                     0xDF04:'EXT_LO', 0xDF05:'EXT_HI', 0xDF06:'EXT_BANK',
                     0xDF07:'LEN_LO', 0xDF08:'LEN_HI', 0xDF09:'IRQ_MASK', 0xDF0A:'ADDR_CTL'}
            return '  ; *** REU_%s ***' % names.get(addr, '%04X' % addr)
        if 0xD078 <= addr <= 0xD07F:
            names = {0xD078:'CACHE_FLUSH', 0xD079:'SW_TURBO', 0xD07A:'SW_1MHZ',
                     0xD07B:'SW_TURBO', 0xD07D:'HW_DIS', 0xD07E:'HW_EN', 0xD07F:'HW_DIS'}
            return '  ; *** SCPU_%s ***' % names.get(addr, '$%04X' % addr)
        if 0xD0B0 <= addr <= 0xD0BF:
            return '  ; *** SCPU_SIM $%04X ***' % addr
        if 0xDC00 <= addr <= 0xDC0F:
            names = {0xDC00:'PRA', 0xDC01:'PRB', 0xDC04:'TA_LO', 0xDC05:'TA_HI',
                     0xDC0D:'ICR', 0xDC0E:'CRA', 0xDC0F:'CRB'}
            return '  ; CIA1_%s' % names.get(addr, '$%04X' % addr)
        if 0xDD00 <= addr <= 0xDD0F:
            names = {0xDD00:'PRA', 0xDD01:'PRB', 0xDD0D:'ICR', 0xDD0E:'CRA', 0xDD0F:'CRB'}
            return '  ; CIA2_%s' % names.get(addr, '$%04X' % addr)
        if 0xD000 <= addr <= 0xD03F:
            return '  ; VIC-II'
        if 0xD400 <= addr <= 0xD7FF:
            return '  ; SID'
    if mode == 'abl' and len(b) >= 3:
        addr = b[2]*65536+b[1]*256+b[0]
        if mnem in ('JSL', 'JML'):
            return '  ; -> $%02X:%04X' % (addr>>16, addr&0xFFFF)
        return '  ; long $%06X' % addr
    if mnem == 'JSR' and mode == 'abs' and len(b) >= 2:
        return '  ; -> $20:%04X' % (b[1]*256+b[0])
    if mnem == 'JMP' and mode == 'abs' and len(b) >= 2:
        return '  ; -> $20:%04X' % (b[1]*256+b[0])
    return ''

def disasm_region(filepath, file_offset, bank, start_addr, nbytes, m_flag=1, x_flag=0):
    with open(filepath, 'rb') as f:
        f.seek(file_offset + start_addr)
        data = f.read(nbytes)

    i = 0
    pc = start_addr

    while i < len(data) and i < nbytes:
        op = data[i]
        if op not in opcodes:
            print("$%02X:%04X  %02X             .db $%02X" % (bank, pc, op, op))
            i += 1; pc += 1
            continue

        mnem, mode = opcodes[op]
        size = operand_size(mode, m_flag, x_flag)
        total = 1 + size

        if i + total > len(data):
            print("$%02X:%04X  ; end of data" % (bank, pc))
            break

        ob = data[i+1:i+1+size]
        hex_str = ' '.join('%02X' % data[i+j] for j in range(total))
        operand_str = format_operand(mode, ob, pc, m_flag, x_flag)
        ann = annotate(mnem, mode, ob, pc)

        if mnem == 'XCE':
            m_flag = 1; x_flag = 1
            ann += '  ; -> native, M=1 X=1'
        elif mnem == 'REP' and len(ob) >= 1:
            if ob[0] & 0x20: m_flag = 0
            if ob[0] & 0x10: x_flag = 0
            ann += '  ; M=%d X=%d' % (m_flag, x_flag)
        elif mnem == 'SEP' and len(ob) >= 1:
            if ob[0] & 0x20: m_flag = 1
            if ob[0] & 0x10: x_flag = 1
            ann += '  ; M=%d X=%d' % (m_flag, x_flag)
        elif mnem == 'PLP':
            ann += '  ; M/X unknown after PLP!'

        print("$%02X:%04X  %-14s %s %s%s" % (bank, pc, hex_str, mnem, operand_str, ann))

        i += total
        pc += total

FILEPATH = r'C:\LLM\C64\MiSTerSuperCPU\doom.reu'

if len(sys.argv) > 1 and sys.argv[1] == '--multi':
    # Disassemble multiple key regions
    regions = [
        (0x200000, 0x20, 0x0000, 0x600, 1, 1, "Init code (entry point)"),
        (0x800000, 0x80, 0x005C, 0x100, 1, 0, "Bank $80 (jumped from $20:03E6)"),
        (0x2D0000, 0x2D, 0x06A0, 0x100, 0, 0, "Bank $2D (jumped from $20:040E)"),
    ]
    for foff, bank, addr, nbytes, m, x, desc in regions:
        print("=" * 70)
        print(desc)
        print("=" * 70)
        disasm_region(FILEPATH, foff, bank, addr, nbytes, m, x)
        print()
else:
    # Default: just init code
    print("=" * 70)
    print("65816 Disassembly: doom.reu $20:0000 - $20:0600")
    print("M/X tracking: starts emulation (M=1,X=1), tracks REP/SEP/XCE")
    print("=" * 70)
    disasm_region(FILEPATH, 0x200000, 0x20, 0x0000, 0x600, 1, 1)
