#!/usr/bin/env python3
"""Minimal 65C816 disassembler with M/X flag tracking via REP/SEP.

Usage:
  python dis65816.py <reu_image> <bank_hex>:<addr_hex> <count>
  python dis65816.py doom.reu 2A:5596 80
  python dis65816.py doom.reu 2C:85A1 60

E flag is assumed 0 (native mode) since Doom runs native after the
loader's CLC; XCE.

Initial M=0, X=0 unless --m1 or --x1 flags are given.

REP #imm: clears flag bits → for the M/X bits in imm, clears (16-bit)
SEP #imm: sets flag bits → for the M/X bits, sets (8-bit)

This isn't an exhaustive disassembler — covers the opcodes Doom uses.
Unknown opcodes shown as ".db $XX".
"""
import sys

# ---------------------------------------------------------------------------
# Opcode table. Each entry: (mnemonic, size_or_callable, addr_kind)
# size_or_callable: int (fixed) OR 'M' (2 if M=1, 3 if M=0) OR 'X' (2 vs 3)
#                    OR 'M+1' / 'X+1' for 16-bit immediate variants
# addr_kind: lambda(operand_bytes, m, x) -> formatted operand string
# ---------------------------------------------------------------------------

def fmt_imm_m(b, m, x):
    return ('#$%02x' % b[0]) if m else ('#$%02x%02x' % (b[1], b[0]))

def fmt_imm_x(b, m, x):
    return ('#$%02x' % b[0]) if x else ('#$%02x%02x' % (b[1], b[0]))

def fmt_imm8(b, m, x): return '#$%02x' % b[0]
def fmt_zp(b, m, x):   return '$%02x' % b[0]
def fmt_zpx(b, m, x):  return '$%02x,X' % b[0]
def fmt_zpy(b, m, x):  return '$%02x,Y' % b[0]
def fmt_indzp(b, m, x): return '($%02x)' % b[0]
def fmt_indzpx(b, m, x): return '($%02x,X)' % b[0]
def fmt_indzpy(b, m, x): return '($%02x),Y' % b[0]
def fmt_ind_long_zp(b, m, x): return '[$%02x]' % b[0]
def fmt_ind_long_zpy(b, m, x): return '[$%02x],Y' % b[0]
def fmt_sr(b, m, x): return '$%02x,S' % b[0]
def fmt_sr_indy(b, m, x): return '($%02x,S),Y' % b[0]
def fmt_abs(b, m, x): return '$%02x%02x' % (b[1], b[0])
def fmt_absx(b, m, x): return '$%02x%02x,X' % (b[1], b[0])
def fmt_absy(b, m, x): return '$%02x%02x,Y' % (b[1], b[0])
def fmt_ind_abs(b, m, x): return '($%02x%02x)' % (b[1], b[0])
def fmt_ind_abs_x(b, m, x): return '($%02x%02x,X)' % (b[1], b[0])
def fmt_ind_abs_long(b, m, x): return '[$%02x%02x]' % (b[1], b[0])
def fmt_long(b, m, x): return '$%02x%02x%02x' % (b[2], b[1], b[0])
def fmt_longx(b, m, x): return '$%02x%02x%02x,X' % (b[2], b[1], b[0])
def fmt_pcrel(b, m, x):
    off = b[0]
    if off >= 0x80: off -= 0x100
    return ('$%+d' % off, off)
def fmt_pcrel_long(b, m, x):
    off = b[0] | (b[1]<<8)
    if off >= 0x8000: off -= 0x10000
    return ('$%+d' % off, off)
def fmt_block_move(b, m, x):
    return '#$%02x,#$%02x' % (b[0], b[1])

# Fixed-size operand kinds (size in bytes excluding opcode)
ADDR_FIXED = {
    'imm8': (1, fmt_imm8),
    'imm16': (2, lambda b,m,x: '#$%02x%02x' % (b[1], b[0])),
    'zp':    (1, fmt_zp),
    'zpx':   (1, fmt_zpx),
    'zpy':   (1, fmt_zpy),
    'indzp': (1, fmt_indzp),
    'indzpx': (1, fmt_indzpx),
    'indzpy': (1, fmt_indzpy),
    'longzp': (1, fmt_ind_long_zp),
    'longzpy': (1, fmt_ind_long_zpy),
    'sr': (1, fmt_sr),
    'sry': (1, fmt_sr_indy),
    'abs': (2, fmt_abs),
    'absx': (2, fmt_absx),
    'absy': (2, fmt_absy),
    'indabs': (2, fmt_ind_abs),
    'indabsx': (2, fmt_ind_abs_x),
    'longabs': (2, fmt_ind_abs_long),
    'long': (3, fmt_long),
    'longx': (3, fmt_longx),
    'rel8': (1, fmt_pcrel),
    'rel16': (2, fmt_pcrel_long),
    'mvn': (2, fmt_block_move),
    'impl': (0, lambda b,m,x: ''),
    'acc':  (0, lambda b,m,x: 'A'),
    'stk':  (1, lambda b,m,x: '$%02x,S' % b[0]),
}

# (mnemonic, kind_or_special). kind_or_special string: kind name OR
# 'mImm' (immediate sized by M flag) / 'xImm' (sized by X flag)
TBL = [None] * 256

def s(op, mn, kind): TBL[op] = (mn, kind)

# Adapted from standard 65C816 opcode chart
s(0x00, 'BRK', 'imm8')
s(0x01, 'ORA', 'indzpx')
s(0x02, 'COP', 'imm8')
s(0x03, 'ORA', 'sr')
s(0x04, 'TSB', 'zp')
s(0x05, 'ORA', 'zp')
s(0x06, 'ASL', 'zp')
s(0x07, 'ORA', 'longzp')
s(0x08, 'PHP', 'impl')
s(0x09, 'ORA', 'mImm')
s(0x0A, 'ASL', 'acc')
s(0x0B, 'PHD', 'impl')
s(0x0C, 'TSB', 'abs')
s(0x0D, 'ORA', 'abs')
s(0x0E, 'ASL', 'abs')
s(0x0F, 'ORA', 'long')
s(0x10, 'BPL', 'rel8')
s(0x11, 'ORA', 'indzpy')
s(0x12, 'ORA', 'indzp')
s(0x13, 'ORA', 'sry')
s(0x14, 'TRB', 'zp')
s(0x15, 'ORA', 'zpx')
s(0x16, 'ASL', 'zpx')
s(0x17, 'ORA', 'longzpy')
s(0x18, 'CLC', 'impl')
s(0x19, 'ORA', 'absy')
s(0x1A, 'INC', 'acc')
s(0x1B, 'TCS', 'impl')
s(0x1C, 'TRB', 'abs')
s(0x1D, 'ORA', 'absx')
s(0x1E, 'ASL', 'absx')
s(0x1F, 'ORA', 'longx')
s(0x20, 'JSR', 'abs')
s(0x21, 'AND', 'indzpx')
s(0x22, 'JSL', 'long')
s(0x23, 'AND', 'sr')
s(0x24, 'BIT', 'zp')
s(0x25, 'AND', 'zp')
s(0x26, 'ROL', 'zp')
s(0x27, 'AND', 'longzp')
s(0x28, 'PLP', 'impl')
s(0x29, 'AND', 'mImm')
s(0x2A, 'ROL', 'acc')
s(0x2B, 'PLD', 'impl')
s(0x2C, 'BIT', 'abs')
s(0x2D, 'AND', 'abs')
s(0x2E, 'ROL', 'abs')
s(0x2F, 'AND', 'long')
s(0x30, 'BMI', 'rel8')
s(0x31, 'AND', 'indzpy')
s(0x32, 'AND', 'indzp')
s(0x33, 'AND', 'sry')
s(0x34, 'BIT', 'zpx')
s(0x35, 'AND', 'zpx')
s(0x36, 'ROL', 'zpx')
s(0x37, 'AND', 'longzpy')
s(0x38, 'SEC', 'impl')
s(0x39, 'AND', 'absy')
s(0x3A, 'DEC', 'acc')
s(0x3B, 'TSC', 'impl')
s(0x3C, 'BIT', 'absx')
s(0x3D, 'AND', 'absx')
s(0x3E, 'ROL', 'absx')
s(0x3F, 'AND', 'longx')
s(0x40, 'RTI', 'impl')
s(0x41, 'EOR', 'indzpx')
s(0x42, 'WDM', 'imm8')
s(0x43, 'EOR', 'sr')
s(0x44, 'MVP', 'mvn')
s(0x45, 'EOR', 'zp')
s(0x46, 'LSR', 'zp')
s(0x47, 'EOR', 'longzp')
s(0x48, 'PHA', 'impl')
s(0x49, 'EOR', 'mImm')
s(0x4A, 'LSR', 'acc')
s(0x4B, 'PHK', 'impl')
s(0x4C, 'JMP', 'abs')
s(0x4D, 'EOR', 'abs')
s(0x4E, 'LSR', 'abs')
s(0x4F, 'EOR', 'long')
s(0x50, 'BVC', 'rel8')
s(0x51, 'EOR', 'indzpy')
s(0x52, 'EOR', 'indzp')
s(0x53, 'EOR', 'sry')
s(0x54, 'MVN', 'mvn')
s(0x55, 'EOR', 'zpx')
s(0x56, 'LSR', 'zpx')
s(0x57, 'EOR', 'longzpy')
s(0x58, 'CLI', 'impl')
s(0x59, 'EOR', 'absy')
s(0x5A, 'PHY', 'impl')
s(0x5B, 'TCD', 'impl')
s(0x5C, 'JMP', 'long')   # JML
s(0x5D, 'EOR', 'absx')
s(0x5E, 'LSR', 'absx')
s(0x5F, 'EOR', 'longx')
s(0x60, 'RTS', 'impl')
s(0x61, 'ADC', 'indzpx')
s(0x62, 'PER', 'rel16')
s(0x63, 'ADC', 'sr')
s(0x64, 'STZ', 'zp')
s(0x65, 'ADC', 'zp')
s(0x66, 'ROR', 'zp')
s(0x67, 'ADC', 'longzp')
s(0x68, 'PLA', 'impl')
s(0x69, 'ADC', 'mImm')
s(0x6A, 'ROR', 'acc')
s(0x6B, 'RTL', 'impl')
s(0x6C, 'JMP', 'indabs')
s(0x6D, 'ADC', 'abs')
s(0x6E, 'ROR', 'abs')
s(0x6F, 'ADC', 'long')
s(0x70, 'BVS', 'rel8')
s(0x71, 'ADC', 'indzpy')
s(0x72, 'ADC', 'indzp')
s(0x73, 'ADC', 'sry')
s(0x74, 'STZ', 'zpx')
s(0x75, 'ADC', 'zpx')
s(0x76, 'ROR', 'zpx')
s(0x77, 'ADC', 'longzpy')
s(0x78, 'SEI', 'impl')
s(0x79, 'ADC', 'absy')
s(0x7A, 'PLY', 'impl')
s(0x7B, 'TDC', 'impl')
s(0x7C, 'JMP', 'indabsx')
s(0x7D, 'ADC', 'absx')
s(0x7E, 'ROR', 'absx')
s(0x7F, 'ADC', 'longx')
s(0x80, 'BRA', 'rel8')
s(0x81, 'STA', 'indzpx')
s(0x82, 'BRL', 'rel16')
s(0x83, 'STA', 'sr')
s(0x84, 'STY', 'zp')
s(0x85, 'STA', 'zp')
s(0x86, 'STX', 'zp')
s(0x87, 'STA', 'longzp')
s(0x88, 'DEY', 'impl')
s(0x89, 'BIT', 'mImm')
s(0x8A, 'TXA', 'impl')
s(0x8B, 'PHB', 'impl')
s(0x8C, 'STY', 'abs')
s(0x8D, 'STA', 'abs')
s(0x8E, 'STX', 'abs')
s(0x8F, 'STA', 'long')
s(0x90, 'BCC', 'rel8')
s(0x91, 'STA', 'indzpy')
s(0x92, 'STA', 'indzp')
s(0x93, 'STA', 'sry')
s(0x94, 'STY', 'zpx')
s(0x95, 'STA', 'zpx')
s(0x96, 'STX', 'zpy')
s(0x97, 'STA', 'longzpy')
s(0x98, 'TYA', 'impl')
s(0x99, 'STA', 'absy')
s(0x9A, 'TXS', 'impl')
s(0x9B, 'TXY', 'impl')
s(0x9C, 'STZ', 'abs')
s(0x9D, 'STA', 'absx')
s(0x9E, 'STZ', 'absx')
s(0x9F, 'STA', 'longx')
s(0xA0, 'LDY', 'xImm')
s(0xA1, 'LDA', 'indzpx')
s(0xA2, 'LDX', 'xImm')
s(0xA3, 'LDA', 'sr')
s(0xA4, 'LDY', 'zp')
s(0xA5, 'LDA', 'zp')
s(0xA6, 'LDX', 'zp')
s(0xA7, 'LDA', 'longzp')
s(0xA8, 'TAY', 'impl')
s(0xA9, 'LDA', 'mImm')
s(0xAA, 'TAX', 'impl')
s(0xAB, 'PLB', 'impl')
s(0xAC, 'LDY', 'abs')
s(0xAD, 'LDA', 'abs')
s(0xAE, 'LDX', 'abs')
s(0xAF, 'LDA', 'long')
s(0xB0, 'BCS', 'rel8')
s(0xB1, 'LDA', 'indzpy')
s(0xB2, 'LDA', 'indzp')
s(0xB3, 'LDA', 'sry')
s(0xB4, 'LDY', 'zpx')
s(0xB5, 'LDA', 'zpx')
s(0xB6, 'LDX', 'zpy')
s(0xB7, 'LDA', 'longzpy')
s(0xB8, 'CLV', 'impl')
s(0xB9, 'LDA', 'absy')
s(0xBA, 'TSX', 'impl')
s(0xBB, 'TYX', 'impl')
s(0xBC, 'LDY', 'absx')
s(0xBD, 'LDA', 'absx')
s(0xBE, 'LDX', 'absy')
s(0xBF, 'LDA', 'longx')
s(0xC0, 'CPY', 'xImm')
s(0xC1, 'CMP', 'indzpx')
s(0xC2, 'REP', 'imm8')
s(0xC3, 'CMP', 'sr')
s(0xC4, 'CPY', 'zp')
s(0xC5, 'CMP', 'zp')
s(0xC6, 'DEC', 'zp')
s(0xC7, 'CMP', 'longzp')
s(0xC8, 'INY', 'impl')
s(0xC9, 'CMP', 'mImm')
s(0xCA, 'DEX', 'impl')
s(0xCB, 'WAI', 'impl')
s(0xCC, 'CPY', 'abs')
s(0xCD, 'CMP', 'abs')
s(0xCE, 'DEC', 'abs')
s(0xCF, 'CMP', 'long')
s(0xD0, 'BNE', 'rel8')
s(0xD1, 'CMP', 'indzpy')
s(0xD2, 'CMP', 'indzp')
s(0xD3, 'CMP', 'sry')
s(0xD4, 'PEI', 'zp')
s(0xD5, 'CMP', 'zpx')
s(0xD6, 'DEC', 'zpx')
s(0xD7, 'CMP', 'longzpy')
s(0xD8, 'CLD', 'impl')
s(0xD9, 'CMP', 'absy')
s(0xDA, 'PHX', 'impl')
s(0xDB, 'STP', 'impl')
s(0xDC, 'JMP', 'longabs')   # JML [abs]
s(0xDD, 'CMP', 'absx')
s(0xDE, 'DEC', 'absx')
s(0xDF, 'CMP', 'longx')
s(0xE0, 'CPX', 'xImm')
s(0xE1, 'SBC', 'indzpx')
s(0xE2, 'SEP', 'imm8')
s(0xE3, 'SBC', 'sr')
s(0xE4, 'CPX', 'zp')
s(0xE5, 'SBC', 'zp')
s(0xE6, 'INC', 'zp')
s(0xE7, 'SBC', 'longzp')
s(0xE8, 'INX', 'impl')
s(0xE9, 'SBC', 'mImm')
s(0xEA, 'NOP', 'impl')
s(0xEB, 'XBA', 'impl')
s(0xEC, 'CPX', 'abs')
s(0xED, 'SBC', 'abs')
s(0xEE, 'INC', 'abs')
s(0xEF, 'SBC', 'long')
s(0xF0, 'BEQ', 'rel8')
s(0xF1, 'SBC', 'indzpy')
s(0xF2, 'SBC', 'indzp')
s(0xF3, 'SBC', 'sry')
s(0xF4, 'PEA', 'imm16')
s(0xF5, 'SBC', 'zpx')
s(0xF6, 'INC', 'zpx')
s(0xF7, 'SBC', 'longzpy')
s(0xF8, 'SED', 'impl')
s(0xF9, 'SBC', 'absy')
s(0xFA, 'PLX', 'impl')
s(0xFB, 'XCE', 'impl')
s(0xFC, 'JSR', 'indabsx')   # JSR (abs,X)
s(0xFD, 'SBC', 'absx')
s(0xFE, 'INC', 'absx')
s(0xFF, 'SBC', 'longx')


def disasm(rom, bank, addr, count, m=0, x=0):
    """Disassemble `count` instructions starting at bank:addr.

    rom: bytes (the full image, addressed as image[(bank<<16) | addr])
    Returns list of (addr, hex_bytes, mnemonic, operand, m, x) tuples.
    """
    out = []
    cur = (bank << 16) | addr
    for _ in range(count):
        op = rom[cur]
        ent = TBL[op]
        if ent is None:
            out.append((cur, '%02x' % op, '.db', '$%02x' % op, m, x))
            cur += 1
            continue
        mn, kind = ent
        if kind == 'mImm':
            sz = 1 if m else 2
            ob = bytes([rom[cur+1+i] for i in range(sz)])
            opnd = ('#$%02x' % ob[0]) if sz == 1 else ('#$%02x%02x' % (ob[1], ob[0]))
            cur_addr = cur
            cur += 1 + sz
        elif kind == 'xImm':
            sz = 1 if x else 2
            ob = bytes([rom[cur+1+i] for i in range(sz)])
            opnd = ('#$%02x' % ob[0]) if sz == 1 else ('#$%02x%02x' % (ob[1], ob[0]))
            cur_addr = cur
            cur += 1 + sz
        else:
            sz, fmt = ADDR_FIXED[kind]
            ob = bytes([rom[cur+1+i] for i in range(sz)]) if sz else b''
            r = fmt(ob, m, x)
            if kind == 'rel8':
                opnd_str, off = r
                tgt = ((cur + 2 + off) & 0xFFFF) | (cur & 0xFF0000)
                opnd = '$%04x' % (tgt & 0xFFFF)
            elif kind == 'rel16':
                opnd_str, off = r
                tgt = ((cur + 3 + off) & 0xFFFF) | (cur & 0xFF0000)
                opnd = '$%04x' % (tgt & 0xFFFF)
            else:
                opnd = r
            cur_addr = cur
            cur += 1 + sz

        # hex bytes
        hb = ' '.join('%02x' % rom[cur_addr + i] for i in range(cur - cur_addr))
        out.append((cur_addr, hb, mn, opnd, m, x))

        # Track M/X flag changes via REP/SEP
        if op == 0xC2:  # REP #imm
            imm = rom[cur_addr + 1]
            if imm & 0x20: m = 0
            if imm & 0x10: x = 0
        elif op == 0xE2:  # SEP #imm
            imm = rom[cur_addr + 1]
            if imm & 0x20: m = 1
            if imm & 0x10: x = 1

        # Stop on terminal flow control
        if op in (0x6B, 0x60, 0x40, 0x80, 0x82, 0x4C, 0x5C, 0x6C, 0x7C, 0xDC):
            # RTL/RTS/RTI/BRA/BRL/JMP/JML/JMP(ind)/JMP(ind,X)/JML[abs]
            # Continue past — caller decides; just keep going
            pass

    return out, m, x


def main():
    if len(sys.argv) < 4:
        print("usage: dis65816.py <reu_image> <bank>:<addr> <count> [--m1] [--x1]")
        sys.exit(1)
    image_path = sys.argv[1]
    bank_addr = sys.argv[2]
    count = int(sys.argv[3])
    m = 1 if '--m1' in sys.argv else 0
    x = 1 if '--x1' in sys.argv else 0

    bank_s, addr_s = bank_addr.split(':')
    bank = int(bank_s, 16)
    addr = int(addr_s, 16)

    with open(image_path, 'rb') as f:
        rom = f.read()

    print(f"Disassembly of {image_path} at ${bank:02X}:${addr:04X}, count={count}, M={m} X={x}")
    print("=" * 70)
    out, m_end, x_end = disasm(rom, bank, addr, count, m, x)
    for ad, hb, mn, op, m_at, x_at in out:
        bk = (ad >> 16) & 0xFF
        ofs = ad & 0xFFFF
        flags = '%sM%s X%s' % (' ' if m_at == 0 and x_at == 0 else '', m_at, x_at)
        print(f"{bk:02X}:{ofs:04X}  {hb:<14}  {mn:<4} {op:<20}  ; {flags}")
    print(f"\nfinal flags: M={m_end} X={x_end}")


if __name__ == '__main__':
    main()
