import re
import sys

mif_path = r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\roms\dol_C64.mif'

# ── Parse MIF ──────────────────────────────────────────────────────────────
with open(mif_path, 'r') as f:
    content = f.read()

rom = {}
data_section = content[content.find('BEGIN') + 5:]
for line in data_section.split(';'):
    line = line.strip()
    if not line or line.upper() == 'END':
        continue
    m = re.match(r'([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f\s]+)', line)
    if m:
        addr = int(m.group(1), 16)
        for i, v in enumerate(m.group(2).split()):
            rom[addr + i] = int(v, 16)

print(f"Parsed {len(rom)} bytes, MIF range {min(rom):04X}..{max(rom):04X}")
print(f"KERNAL starts at MIF 0x2000 = C64 $E000")
print()

# Report all $89 bytes in KERNAL
print("All $89 bytes in KERNAL (MIF 0x2000..0x3FFF):")
for a in range(0x2000, 0x4000):
    if rom.get(a) == 0x89:
        c64 = a - 0x2000 + 0xE000
        b1 = rom.get(a+1, 0xFF)
        b2 = rom.get(a+2, 0xFF)
        print(f"  MIF:{a:04X}  C64:${c64:04X}  =>  89 {b1:02X} {b2:02X}")
print()

# ── 6502 opcode table (opcode -> (mnemonic, addressing_mode, length)) ──────
# length in bytes (including opcode)
ops = {
    0x00: ('BRK', 'imp', 1), 0x01: ('ORA', 'izx', 2), 0x05: ('ORA', 'zp',  2),
    0x06: ('ASL', 'zp',  2), 0x08: ('PHP', 'imp', 1), 0x09: ('ORA', 'imm', 2),
    0x0A: ('ASL', 'acc', 1), 0x0D: ('ORA', 'abs', 3), 0x0E: ('ASL', 'abs', 3),
    0x10: ('BPL', 'rel', 2), 0x11: ('ORA', 'izy', 2), 0x15: ('ORA', 'zpx', 2),
    0x16: ('ASL', 'zpx', 2), 0x18: ('CLC', 'imp', 1), 0x19: ('ORA', 'aby', 3),
    0x1D: ('ORA', 'abx', 3), 0x1E: ('ASL', 'abx', 3),
    0x20: ('JSR', 'abs', 3), 0x21: ('AND', 'izx', 2), 0x24: ('BIT', 'zp',  2),
    0x25: ('AND', 'zp',  2), 0x26: ('ROL', 'zp',  2), 0x28: ('PLP', 'imp', 1),
    0x29: ('AND', 'imm', 2), 0x2A: ('ROL', 'acc', 1), 0x2C: ('BIT', 'abs', 3),
    0x2D: ('AND', 'abs', 3), 0x2E: ('ROL', 'abs', 3),
    0x30: ('BMI', 'rel', 2), 0x31: ('AND', 'izy', 2), 0x35: ('AND', 'zpx', 2),
    0x36: ('ROL', 'zpx', 2), 0x38: ('SEC', 'imp', 1), 0x39: ('AND', 'aby', 3),
    0x3D: ('AND', 'abx', 3), 0x3E: ('ROL', 'abx', 3),
    0x40: ('RTI', 'imp', 1), 0x41: ('EOR', 'izx', 2), 0x45: ('EOR', 'zp',  2),
    0x46: ('LSR', 'zp',  2), 0x48: ('PHA', 'imp', 1), 0x49: ('EOR', 'imm', 2),
    0x4A: ('LSR', 'acc', 1), 0x4C: ('JMP', 'abs', 3), 0x4D: ('EOR', 'abs', 3),
    0x4E: ('LSR', 'abs', 3),
    0x50: ('BVC', 'rel', 2), 0x51: ('EOR', 'izy', 2), 0x55: ('EOR', 'zpx', 2),
    0x56: ('LSR', 'zpx', 2), 0x58: ('CLI', 'imp', 1), 0x59: ('EOR', 'aby', 3),
    0x5D: ('EOR', 'abx', 3), 0x5E: ('LSR', 'abx', 3),
    0x60: ('RTS', 'imp', 1), 0x61: ('ADC', 'izx', 2), 0x65: ('ADC', 'zp',  2),
    0x66: ('ROR', 'zp',  2), 0x68: ('PLA', 'imp', 1), 0x69: ('ADC', 'imm', 2),
    0x6A: ('ROR', 'acc', 1), 0x6C: ('JMP', 'ind', 3), 0x6D: ('ADC', 'abs', 3),
    0x6E: ('ROR', 'abs', 3),
    0x70: ('BVS', 'rel', 2), 0x71: ('ADC', 'izy', 2), 0x75: ('ADC', 'zpx', 2),
    0x76: ('ROR', 'zpx', 2), 0x78: ('SEI', 'imp', 1), 0x79: ('ADC', 'aby', 3),
    0x7D: ('ADC', 'abx', 3), 0x7E: ('ROR', 'abx', 3),
    0x81: ('STA', 'izx', 2), 0x84: ('STY', 'zp',  2), 0x85: ('STA', 'zp',  2),
    0x86: ('STX', 'zp',  2), 0x88: ('DEY', 'imp', 1), 0x89: ('BIT', 'imm', 2),  # 65C816 / NOP on 6510
    0x8A: ('TXA', 'imp', 1), 0x8C: ('STY', 'abs', 3), 0x8D: ('STA', 'abs', 3),
    0x8E: ('STX', 'abs', 3),
    0x90: ('BCC', 'rel', 2), 0x91: ('STA', 'izy', 2), 0x94: ('STY', 'zpx', 2),
    0x95: ('STA', 'zpx', 2), 0x96: ('STX', 'zpy', 2), 0x98: ('TYA', 'imp', 1),
    0x99: ('STA', 'aby', 3), 0x9A: ('TXS', 'imp', 1), 0x9D: ('STA', 'abx', 3),
    0xA0: ('LDY', 'imm', 2), 0xA1: ('LDA', 'izx', 2), 0xA2: ('LDX', 'imm', 2),
    0xA4: ('LDY', 'zp',  2), 0xA5: ('LDA', 'zp',  2), 0xA6: ('LDX', 'zp',  2),
    0xA8: ('TAY', 'imp', 1), 0xA9: ('LDA', 'imm', 2), 0xAA: ('TAX', 'imp', 1),
    0xAC: ('LDY', 'abs', 3), 0xAD: ('LDA', 'abs', 3), 0xAE: ('LDX', 'abs', 3),
    0xB0: ('BCS', 'rel', 2), 0xB1: ('LDA', 'izy', 2), 0xB4: ('LDY', 'zpx', 2),
    0xB5: ('LDA', 'zpx', 2), 0xB6: ('LDX', 'zpy', 2), 0xB8: ('CLV', 'imp', 1),
    0xB9: ('LDA', 'aby', 3), 0xBA: ('TSX', 'imp', 1), 0xBC: ('LDY', 'abx', 3),
    0xBD: ('LDA', 'abx', 3), 0xBE: ('LDX', 'aby', 3),
    0xC0: ('CPY', 'imm', 2), 0xC1: ('CMP', 'izx', 2), 0xC4: ('CPY', 'zp',  2),
    0xC5: ('CMP', 'zp',  2), 0xC6: ('DEC', 'zp',  2), 0xC8: ('INY', 'imp', 1),
    0xC9: ('CMP', 'imm', 2), 0xCA: ('DEX', 'imp', 1), 0xCC: ('CPY', 'abs', 3),
    0xCD: ('CMP', 'abs', 3), 0xCE: ('DEC', 'abs', 3),
    0xD0: ('BNE', 'rel', 2), 0xD1: ('CMP', 'izy', 2), 0xD5: ('CMP', 'zpx', 2),
    0xD6: ('DEC', 'zpx', 2), 0xD8: ('CLD', 'imp', 1), 0xD9: ('CMP', 'aby', 3),
    0xDD: ('CMP', 'abx', 3), 0xDE: ('DEC', 'abx', 3),
    0xE0: ('CPX', 'imm', 2), 0xE1: ('SBC', 'izx', 2), 0xE4: ('CPX', 'zp',  2),
    0xE5: ('SBC', 'zp',  2), 0xE6: ('INC', 'zp',  2), 0xE8: ('INX', 'imp', 1),
    0xE9: ('SBC', 'imm', 2), 0xEA: ('NOP', 'imp', 1), 0xEC: ('CPX', 'abs', 3),
    0xED: ('SBC', 'abs', 3), 0xEE: ('INC', 'abs', 3),
    0xF0: ('BEQ', 'rel', 2), 0xF1: ('SBC', 'izy', 2), 0xF5: ('SBC', 'zpx', 2),
    0xF6: ('INC', 'zpx', 2), 0xF8: ('SED', 'imp', 1), 0xF9: ('SBC', 'aby', 3),
    0xFD: ('SBC', 'abx', 3), 0xFE: ('INC', 'abx', 3),
}

def mif_addr(c64_addr):
    """Convert C64 address to MIF address (KERNAL at $E000 = MIF 0x2000)."""
    return c64_addr - 0xE000 + 0x2000

def get_byte(c64_addr):
    return rom.get(mif_addr(c64_addr), None)

def format_operand(mode, pc, b1, b2):
    if mode == 'imp' or mode == 'acc':
        return ''
    if mode == 'imm':
        return f'#${b1:02X}'
    if mode == 'zp':
        return f'${b1:02X}'
    if mode == 'zpx':
        return f'${b1:02X},X'
    if mode == 'zpy':
        return f'${b1:02X},Y'
    if mode == 'abs':
        return f'${b2:02X}{b1:02X}'
    if mode == 'abx':
        return f'${b2:02X}{b1:02X},X'
    if mode == 'aby':
        return f'${b2:02X}{b1:02X},Y'
    if mode == 'ind':
        return f'(${b2:02X}{b1:02X})'
    if mode == 'izx':
        return f'(${b1:02X},X)'
    if mode == 'izy':
        return f'(${b1:02X}),Y'
    if mode == 'rel':
        offset = b1 if b1 < 0x80 else b1 - 0x100
        target = pc + 2 + offset
        return f'${target:04X}  [{offset:+d}]'
    return '???'

BRANCHES = {0xF0: 'BEQ', 0xD0: 'BNE', 0x90: 'BCC', 0xB0: 'BCS',
            0x10: 'BPL', 0x30: 'BMI', 0x50: 'BVC', 0x70: 'BVS'}

def disassemble_around(target_c64, context_before=50, context_after=40, label=None):
    """Disassemble ~context_before bytes before and context_after bytes after target_c64."""
    start = target_c64 - context_before
    end   = target_c64 + context_after
    lbl   = label or f"${target_c64:04X}"

    print("=" * 76)
    print(f"  6502 Disassembly around {lbl}  (${start:04X}..${end+4:04X})")
    print(f"  MIF offset: 0x{mif_addr(target_c64):04X}")
    print("=" * 76)
    print(f"  {'Addr':6}  {'Hex':12}  Mnemonic")
    print("-" * 76)

    pc = start
    instructions = []
    while pc <= end + 4:
        op = get_byte(pc)
        if op is None:
            break
        info = ops.get(op)
        if info is None:
            instructions.append((pc, [op], '???', f'${op:02X}', ''))
            pc += 1
            continue
        mnem, mode, length = info
        b1 = get_byte(pc + 1) if length >= 2 else 0
        b2 = get_byte(pc + 2) if length >= 3 else 0
        if b1 is None: b1 = 0
        if b2 is None: b2 = 0
        raw = [op] + ([b1] if length >= 2 else []) + ([b2] if length >= 3 else [])
        operand = format_operand(mode, pc, b1, b2)
        instructions.append((pc, raw, mnem, operand, mode))
        pc += length

    for addr, raw, mnem, operand, mode in instructions:
        hex_str = ' '.join(f'{b:02X}' for b in raw)
        flags = []
        if addr == target_c64:
            flags.append('<<<<< TARGET')
        if raw[0] in BRANCHES:
            if abs(addr - target_c64) <= 6:
                flags.append('<-- BRANCH NEAR TARGET')
            elif addr > target_c64:
                flags.append('<-- branch')
        if raw[0] == 0x89:
            flags.append('[opcode $89: NOP/2 on 6510; BIT #imm on 65C816]')
        annotation = '  ' + '  '.join(flags) if flags else ''
        print(f"  ${addr:04X}   {hex_str:12}  {mnem} {operand}{annotation}")

    print("=" * 76)
    print()

    # Per-site analysis
    op = get_byte(target_c64)
    print(f"ANALYSIS for ${target_c64:04X}:")
    print(f"  Byte at target  = ${op:02X}")
    if op == 0x89:
        imm = get_byte(target_c64 + 1) or 0
        print(f"  Instruction     = BIT #${imm:02X}  (opcode $89)")
        print(f"  On 6510:   $89 is a 2-byte NOP  -> Z flag NOT changed by this instruction")
        print(f"  On 65C816: BIT #${imm:02X} -> Z = (A & ${imm:02X}) == 0  -> Z flag IS changed")
        # Walk forward, report next branch
        next_pc = target_c64 + 2
        for _ in range(8):
            nop = get_byte(next_pc)
            if nop is None: break
            if nop in BRANCHES:
                ninfo = ops[nop]
                nb1 = get_byte(next_pc + 1) or 0
                offset = nb1 if nb1 < 0x80 else nb1 - 0x100
                taken = next_pc + 2 + offset
                print()
                print(f"  *** NEXT CONDITIONAL BRANCH at ${next_pc:04X}: {ninfo[0]} ${taken:04X}  [{offset:+d}]")
                print(f"      On 6510:   branch decision uses Z set by instruction BEFORE $89 NOP")
                print(f"      On 65C816: branch decision uses Z set by BIT #${imm:02X}")
                print(f"      RISK: if A & ${imm:02X} differs from what previous op left in Z -> different path!")
                break
            ninfo = ops.get(nop)
            next_pc += ninfo[2] if ninfo else 1
    else:
        print(f"  NOTE: byte at ${target_c64:04X} is ${op:02X}, NOT opcode $89.")
        print(f"  ${target_c64:04X} is the OPERAND byte of the preceding instruction.")
        print(f"  -> No $89 issue at this address.")
    print()


# ── Sites to analyse ───────────────────────────────────────────────────────
# 1. The address the user originally asked about ($E969) – $89 NOT here
disassemble_around(0xE969, label="$E969 (user-requested; $89 NOT here)")

# 2. All real $89 sites in KERNAL
opcode89_sites = [a - 0x2000 + 0xE000 for a in range(0x2000, 0x4000) if rom.get(a) == 0x89]
for c64addr in opcode89_sites:
    disassemble_around(c64addr, label=f"${c64addr:04X} [opcode $89 site]")
