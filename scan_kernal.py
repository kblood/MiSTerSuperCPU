import re

rom = bytearray(0x4000)
with open(r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\roms\dol_C64.mif') as f:
    for line in f:
        line = line.strip()
        m = re.match(r'\[([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\]\s*:\s*([0-9A-Fa-f]+)', line)
        if m:
            lo,hi,val = int(m.group(1),16), int(m.group(2),16), int(m.group(3),16)
            for i in range(lo,hi+1): rom[i]=val
            continue
        # Multi-byte row: ADDR: BB BB BB ...
        m = re.match(r'([0-9A-Fa-f]+)\s*:\s*((?:[0-9A-Fa-f]{2}\s*)+)', line)
        if m:
            addr = int(m.group(1),16)
            bytes_ = [int(x,16) for x in m.group(2).split()]
            for i,b in enumerate(bytes_):
                if addr+i < 0x4000: rom[addr+i]=b

def r(c64addr): return rom[c64addr-0xC000]

DANGER = {
    0x80: 'BRA (was 2-byte NOP)',
    0x64: 'STZ zp (was 2-byte NOP)',
    0x74: 'STZ zp,X (was 2-byte NOP)',
    0x9C: 'STZ abs (was SHY)',
    0x9E: 'STZ abs,X (was SHX)',
    0x44: 'MVP (was 3-byte NOP)',
    0x54: 'MVN (was 3-byte NOP)',
    0x5C: 'JML (was 4-byte NOP)',
    0xFC: 'JSR (abs,X) (was 3-byte NOP)',
    0x89: 'BIT imm (was 2-byte NOP)',
}

# Simple length table for 6502
LENS = {
    0xEA:1,0x18:1,0x58:1,0x78:1,0xD8:1,0xF8:1,0x38:1,0xBA:1,0x8A:1,0x98:1,0xA8:1,
    0x9A:1,0x48:1,0x68:1,0x40:1,0x60:1,0xCA:1,0xE8:1,0xC8:1,0x88:1,0xAA:1,0xA8:1,
    0xE6:2,0xC6:2,0xA6:2,0xA4:2,0x86:2,0x84:2,0x85:2,
    0xA9:2,0xA2:2,0xA0:2,0xC9:2,0xE0:2,0xC0:2,0x29:2,0x09:2,0x49:2,
    0xD0:2,0xF0:2,0xB0:2,0x90:2,0x10:2,0x30:2,0x50:2,0x70:2,0x80:2,
    0x24:2,0x65:2,0x25:2,0x45:2,0x05:2,0xA5:2,0xC5:2,0xE5:2,
    0x75:2,0x35:2,0x55:2,0x15:2,0x95:2,0xB5:2,0xD5:2,0xF5:2,
    0x64:2,0x74:2,0x89:2,
    0xBD:3,0x9D:3,0x20:3,0x4C:3,0x6C:3,0x7C:3,0xAD:3,0x8D:3,0xCD:3,0xED:3,
    0x0D:3,0x2D:3,0x6D:3,0x4E:3,0x0E:3,0xCC:3,0xEC:3,0xAC:3,0xBC:3,0xAE:3,
    0xBE:3,0x8E:3,0x8C:3,0xEE:3,0xCE:3,0x2C:3,0x9C:3,0x9E:3,0x44:3,0x54:3,
    0x5C:4,0xFC:3,
}

def disasm_range(start, end, label=''):
    if label: print(f'\n=== {label} (${start:04X}-${end:04X}) ===')
    addr = start
    while addr < end and addr <= 0xFFFF:
        b = r(addr)
        ln = LENS.get(b, 1)
        bs = ' '.join(f'{r(addr+i):02X}' for i in range(min(ln, end-addr+1)))
        flag = '  *** 65C816 DANGER ***' if b in DANGER else ''
        if b in DANGER:
            dname = DANGER[b]
            # Show target address for abs opcodes
            if ln == 3:
                tgt = r(addr+1) | (r(addr+2)<<8)
                print(f'  ${addr:04X}: {bs:<10} [{dname}] -> target ${tgt:04X}{flag}')
            else:
                print(f'  ${addr:04X}: {bs:<10} [{dname}]{flag}')
        addr += ln

print('=== 65C816 DANGER opcode scan - JiffyDOS KERNAL ===\n')

# Scan critical regions
regions = [
    ('KERNAL IRQ entry', 0xFF48, 0xFF60),
    ('BASIC IRQ handler $FA65', 0xFA65, 0xFAFF),
    ('CIA/cursor/kbd area $FA00', 0xFA00, 0xFA65),
    ('KERNAL IOINIT $FDA3', 0xFDA3, 0xFE00),
    ('KERNAL init CINT $FF5B', 0xFF5B, 0xFF95),
    ('Screen init area $E544', 0xE544, 0xE600),
    ('VIC init $EA31', 0xEA31, 0xEB00),
]

for name, start, end in regions:
    hits = []
    for addr in range(start, end):
        b = r(addr)
        if b in DANGER:
            ctx = ' '.join(f'{r(addr+i):02X}' for i in range(min(4, 0x10000-addr)))
            if b in (0x9C, 0x9E) and len(ctx) >= 6:
                tgt = r(addr+1)|(r(addr+2)<<8)
                hits.append(f'  ${addr:04X}: {ctx}  [{DANGER[b]}] -> ${tgt:04X}')
            else:
                hits.append(f'  ${addr:04X}: {ctx}  [{DANGER[b]}]')
    if hits:
        print(f'[{name}]')
        for h in hits: print(h)
        print()

# Full scan - all dangerous opcodes in entire KERNAL
print('\n[Full KERNAL scan $E000-$FFFF]')
for addr in range(0xE000, 0x10000):
    b = r(addr)
    if b in DANGER:
        ctx = ' '.join(f'{r(addr+i):02X}' for i in range(min(4, 0x10000-addr)))
        if b in (0x9C, 0x9E, 0x44, 0x54, 0x5C, 0xFC) and len(ctx) >= 4:
            if b == 0x9C or b == 0x9E:
                tgt = r(addr+1)|(r(addr+2)<<8)
                print(f'  ${addr:04X}: {ctx}  [{DANGER[b]}] -> TARGET ${tgt:04X}')
            else:
                print(f'  ${addr:04X}: {ctx}  [{DANGER[b]}]')
        elif b == 0x80:
            offset = r(addr+1)
            if offset >= 0x80: offset -= 0x100
            branch_target = (addr + 2 + offset) & 0xFFFF
            print(f'  ${addr:04X}: {ctx}  [BRA -> ${branch_target:04X}] (was NOP)')
        elif b == 0x89:
            print(f'  ${addr:04X}: {ctx}  [BIT #{r(addr+1):02X}] (was NOP, flags differ)')
        elif b == 0x64 or b == 0x74:
            print(f'  ${addr:04X}: {ctx}  [{DANGER[b]}]')
