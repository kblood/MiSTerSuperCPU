"""
Linear disassembly from known KERNAL entry points to find dangerous opcodes
that behave differently on 65C816 vs NMOS 6502.
"""
import re

def load_mif(path):
    rom = bytearray(0x4000)
    with open(path) as f:
        for line in f:
            line = line.strip()
            m = re.match(r'\[([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\]\s*:\s*([0-9A-Fa-f]+)', line)
            if m:
                lo,hi,val = int(m.group(1),16), int(m.group(2),16), int(m.group(3),16)
                for i in range(lo,hi+1): rom[i]=val
                continue
            m = re.match(r'([0-9A-Fa-f]+)\s*:\s*((?:[0-9A-Fa-f]{2}\s*)+)', line)
            if m:
                addr = int(m.group(1),16)
                for i,b in enumerate(int(x,16) for x in m.group(2).split()):
                    if addr+i < 0x4000: rom[addr+i]=b
    return rom

def r(rom, a): return rom[a - 0xC000]

# Instruction lengths (6502 + 65C816 unified - use 6502 lengths since we're scanning for what
# the 6502/T65 thinks these instructions are, to get correct instruction boundaries)
LENS = {}
for op in [0xEA,0x18,0x38,0x58,0x78,0xB8,0xD8,0xF8,0x8A,0x98,0xA8,0xBA,0x48,0x68,0x40,0x60,
           0xCA,0xE8,0xC8,0x88,0xAA,0x9A,0x2A,0x0A,0x4A,0x6A,
           # These are 1-byte on 65C816 (implied) but also 1-byte effective on 6502 (NOPs/illegals)
           0x1A,0x3A,0xDA,0xFA,0x5A,0x7A,0xCB,0xEB,0xFB,0x0B,0x2B,0x3B,0x4B,0x5B,0x6B,0x7B,0x8B,0x9B,0xAB,0xBB]:
    LENS[op] = 1
for op in [0xA9,0xA2,0xA0,0xC9,0xE0,0xC0,0x29,0x09,0x49,0x69,0x89,
           0xA5,0xB5,0xA6,0xB6,0xA4,0xB4,0x85,0x95,0x86,0x96,0x84,0x94,
           0xC5,0xD5,0xC6,0xD6,0xE5,0xF5,0xE6,0xF6,0x25,0x35,0x05,0x15,0x45,0x55,0x65,0x75,
           0x24,0x26,0x46,0x66,
           0xD0,0xF0,0xB0,0x90,0x10,0x30,0x50,0x70,0x80,
           0x64,0x74,0xC2,0xE2,0xF4,0x62,0x82,0x00]:
    LENS[op] = 2
for op in [0xAD,0xBD,0xB9,0xAE,0xBE,0xAC,0xBC,0x8D,0x9D,0x99,0x8E,0x8C,
           0xCD,0xDD,0xD9,0xCE,0xDE,0xED,0xFD,0xF9,0xEE,0xFE,
           0x2D,0x3D,0x39,0x0D,0x1D,0x19,0x4D,0x5D,0x59,0x6D,0x7D,0x79,
           0x4E,0x5E,0x0E,0x1E,0x2E,0x3E,0x6E,0x7E,
           0xCC,0xEC,0x2C,0x3C,
           0x20,0x4C,0x6C,0x7C,
           0x9C,0x9E,0x44,0x54,0xFC]:
    LENS[op] = 3
LENS[0x5C] = 4

DANGEROUS = {
    0x80: 'BRA (was 2-byte NOP on NMOS)',
    0x64: 'STZ zp (was NOP on NMOS)',
    0x74: 'STZ zp,X (was NOP on NMOS)',
    0x9C: 'STZ abs (was SHY on NMOS)',
    0x9E: 'STZ abs,X (was SHX on NMOS)',
    0x5B: 'TCD -- CHANGES D REGISTER!',
    0x1B: 'TCS -- CHANGES STACK POINTER!',
    0xDA: 'PHX -- pushes X to stack',
    0xFA: 'PLX -- pops X from stack',
    0x5A: 'PHY -- pushes Y to stack',
    0x7A: 'PLY -- pops Y from stack',
    0xCB: 'WAI -- HALTS CPU!',
    0x5C: 'JML (was 4-byte NOP)',
    0xFC: 'JSR abs,X (was 3-byte NOP)',
    0x44: 'MVP (was 3-byte NOP)',
    0x54: 'MVN (was 3-byte NOP)',
    0x0B: 'PHD -- pushes D to stack',
    0x2B: 'PLD -- pops 2 bytes into D!',
    0x6B: 'RTL -- returns LONG!',
    0x8B: 'PHB',
    0xAB: 'PLB',
    0xEB: 'XBA -- swaps A and B!',
    0xC2: 'REP (changes status flags!)',
    0xE2: 'SEP (changes status flags!)',
    0x1A: 'INA (was NOP)',
    0x3A: 'DEA (was NOP)',
    0x9B: 'TXY',
    0xB2: 'LDA (dp) indirect',
    0xD2: 'CMP (dp) indirect',
    0xF2: 'SBC (dp) indirect',
    0xFB: 'XCE (mode switch)',
}

BRANCHES = {0xD0, 0xF0, 0xB0, 0x90, 0x10, 0x30, 0x50, 0x70, 0x80}

def scan_rom(rom_path, label, entry_points):
    rom = load_mif(rom_path)
    
    # Read reset and IRQ vectors
    reset_vec = r(rom, 0xFFFC) | (r(rom, 0xFFFD) << 8)
    irq_vec   = r(rom, 0xFFFE) | (r(rom, 0xFFFF) << 8)
    nmi_vec   = r(rom, 0xFFFA) | (r(rom, 0xFFFB) << 8)
    
    all_entries = entry_points + [reset_vec, irq_vec, nmi_vec]
    
    visited = set()
    dangerous_found = []
    to_visit = list(all_entries)
    
    while to_visit:
        addr = to_visit.pop(0)
        while 0xE000 <= addr <= 0xFFFF:
            if addr in visited: break
            visited.add(addr)
            op = r(rom, addr)
            ln = LENS.get(op, 1)
            if addr + ln > 0x10000: break
            raw = [r(rom, addr+i) for i in range(ln)]
            
            if op in DANGEROUS:
                extra = ''
                if op == 0x80:
                    off = raw[1]; off = off - 256 if off >= 128 else off
                    tgt = (addr + 2 + off) & 0xFFFF
                    extra = ' -> branch to $%04X' % tgt
                    if 0xE000 <= tgt <= 0xFFFF: to_visit.append(tgt)
                elif op in (0x9C, 0x9E) and ln >= 3:
                    tgt = raw[1] | (raw[2] << 8)
                    extra = ' -> writes to $%04X' % tgt
                elif op == 0x64 and ln >= 2:
                    extra = ' -> ZP $%02X' % raw[1]
                elif op == 0x74 and ln >= 2:
                    extra = ' -> ZP $%02X,X' % raw[1]
                bs = ' '.join('%02X' % b for b in raw)
                dangerous_found.append((addr, bs, DANGEROUS[op]+extra))
            
            # Follow all branches
            if op in BRANCHES and ln == 2:
                off = raw[1]; off = off - 256 if off >= 128 else off
                tgt = (addr + 2 + off) & 0xFFFF
                if 0xE000 <= tgt <= 0xFFFF: to_visit.append(tgt)
                if op == 0x80: break  # unconditional: stop this path
            
            # Follow JSR
            if op == 0x20 and ln == 3:
                tgt = raw[1] | (raw[2] << 8)
                if 0xE000 <= tgt <= 0xFFFF: to_visit.append(tgt)
            # JMP abs
            if op == 0x4C and ln == 3:
                tgt = raw[1] | (raw[2] << 8)
                if 0xE000 <= tgt <= 0xFFFF: to_visit.append(tgt)
                break
            # Can't follow JMP indirect - stop
            if op in (0x6C, 0x7C): break
            # RTS/RTI/BRK stop path
            if op in (0x60, 0x40, 0x00): break
            
            addr += ln
    
    print('=== %s ===' % label)
    print('  Reset: $%04X  IRQ: $%04X  NMI: $%04X' % (reset_vec, irq_vec, nmi_vec))
    print('  Visited %d instruction addresses' % len(visited))
    print('  DANGEROUS OPCODES IN CODE PATHS: %d' % len(dangerous_found))
    if dangerous_found:
        for addr, bs, info in sorted(dangerous_found):
            print('    $%04X: %-12s %s' % (addr, bs, info))
    else:
        print('    (none found)')
    print()

BASE = r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\roms'

scan_rom(BASE + r'\dol_C64.mif', 'JiffyDOS KERNAL',
    [0xFF48, 0xEA31, 0xFA65, 0xFA00, 0xEC50, 0xFCE2, 0xFF5B, 0xFFD2, 0xFFE4, 0xECB9, 0xFA30, 0xEA87, 0xF2A9])

scan_rom(BASE + r'\std_C64.mif', 'Standard C64 KERNAL',
    [0xFF48, 0xEA31, 0xFA65, 0xFA00, 0xEC50, 0xFCE2, 0xFF5B, 0xFFD2, 0xFFE4, 0xEA87])
