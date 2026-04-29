#!/usr/bin/env python3
"""
Deep analysis of SCPU Kicks D64 - trace the loader and find what runs at $82E0.
Also search for BEQ patterns and DMA-related code.
"""

import struct

# D64 track/sector layout
SECTORS_PER_TRACK = []
for t in range(1, 36):
    if t <= 17: SECTORS_PER_TRACK.append(21)
    elif t <= 24: SECTORS_PER_TRACK.append(19)
    elif t <= 30: SECTORS_PER_TRACK.append(18)
    else: SECTORS_PER_TRACK.append(17)

def ts_to_offset(track, sector):
    if track < 1 or track > 35: return None
    offset = 0
    for t in range(1, track): offset += SECTORS_PER_TRACK[t-1] * 256
    return offset + sector * 256

def extract_file(data, track, sector):
    result = bytearray()
    visited = set()
    while track != 0:
        if (track, sector) in visited: break
        visited.add((track, sector))
        offset = ts_to_offset(track, sector)
        if offset is None: break
        nt, ns = data[offset], data[offset+1]
        if nt == 0:
            result.extend(data[offset+2:offset+ns+1])
        else:
            result.extend(data[offset+2:offset+256])
        track, sector = nt, ns
    return bytes(result)

def list_dir(data):
    track, sector = 18, 1
    entries = []
    while track != 0:
        offset = ts_to_offset(track, sector)
        if offset is None: break
        nt, ns = data[offset], data[offset+1]
        for i in range(8):
            eo = offset + i * 32
            ft = data[eo+2]
            if ft == 0: continue
            fname = ''
            for b in data[eo+5:eo+21]:
                if b == 0xA0: break
                if 0x41 <= b <= 0x5A: fname += chr(b)
                elif 0xC1 <= b <= 0xDA: fname += chr(b-0x80)
                elif 0x20 <= b <= 0x7E: fname += chr(b)
                else: fname += f'[{b:02X}]'
            fsize = data[eo+30] | (data[eo+31] << 8)
            type_str = ['DEL','SEQ','PRG','USR','REL'][ft & 7] if (ft & 7) < 5 else f'?{ft:02X}'
            if type_str == 'PRG':
                entries.append({'name': fname, 'track': data[eo+3], 'sector': data[eo+4], 'size': fsize})
        track, sector = nt, ns
    return entries

# 65C816 opcode info: (mnemonic, size) -- simplified, assume 8-bit M/X
OP_SIZE = {}
# Size 1: implied/accumulator
for op in [0x08,0x0A,0x0B,0x18,0x1A,0x1B,0x28,0x2A,0x2B,0x38,0x3A,0x3B,
           0x40,0x48,0x4A,0x4B,0x58,0x5A,0x5B,0x60,0x68,0x6A,0x6B,0x78,
           0x7A,0x7B,0x88,0x8A,0x8B,0x98,0x9A,0x9B,0xA8,0xAA,0xAB,0xB8,
           0xBA,0xBB,0xC8,0xCA,0xCB,0xD8,0xDA,0xDB,0xE8,0xEA,0xEB,0xF8,
           0xFA,0xFB]:
    OP_SIZE[op] = 1
# Size 2: immediate 8-bit, dp, rel8, etc
for op in [0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x09,0x10,0x11,0x12,
           0x13,0x14,0x15,0x16,0x17,0x21,0x23,0x24,0x25,0x26,0x27,0x29,
           0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x41,0x42,0x43,0x45,
           0x46,0x47,0x49,0x50,0x51,0x52,0x53,0x55,0x56,0x57,0x61,0x63,
           0x64,0x65,0x66,0x67,0x69,0x70,0x71,0x72,0x73,0x74,0x75,0x76,
           0x77,0x80,0x81,0x83,0x84,0x85,0x86,0x87,0x89,0x90,0x91,0x92,
           0x93,0x94,0x95,0x96,0x97,0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0xA6,
           0xA7,0xA9,0xB0,0xB1,0xB2,0xB3,0xB4,0xB5,0xB6,0xB7,0xC0,0xC1,
           0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC9,0xD0,0xD1,0xD2,0xD3,0xD4,
           0xD5,0xD6,0xD7,0xE0,0xE1,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,0xE9,
           0xF0,0xF1,0xF2,0xF3,0xF5,0xF6,0xF7]:
    OP_SIZE[op] = 2
# Size 3: absolute, rel16, etc
for op in [0x0C,0x0D,0x0E,0x19,0x1C,0x1D,0x1E,0x20,0x2C,0x2D,0x2E,0x39,
           0x3C,0x3D,0x3E,0x44,0x4C,0x4D,0x4E,0x54,0x59,0x5D,0x5E,0x62,
           0x6C,0x6D,0x6E,0x79,0x7C,0x7D,0x7E,0x8C,0x8D,0x8E,0x99,0x9C,
           0x9D,0x9E,0xAC,0xAD,0xAE,0xB9,0xBC,0xBD,0xBE,0xCC,0xCD,0xCE,
           0xD9,0xDC,0xDD,0xDE,0xEC,0xED,0xEE,0xF4,0xF9,0xFC,0xFD,0xFE]:
    OP_SIZE[op] = 3
# Size 4: absolute long
for op in [0x0F,0x1F,0x22,0x2F,0x3F,0x4F,0x5C,0x5F,0x6F,0x7F,0x8F,0x9F,
           0xAF,0xBF,0xCF,0xDF,0xEF,0xFF]:
    OP_SIZE[op] = 4

MNEMONICS = {
    0x00:'BRK',0x01:'ORA',0x02:'COP',0x03:'ORA',0x04:'TSB',0x05:'ORA',0x06:'ASL',0x07:'ORA',
    0x08:'PHP',0x09:'ORA',0x0A:'ASL',0x0B:'PHD',0x0C:'TSB',0x0D:'ORA',0x0E:'ASL',0x0F:'ORA',
    0x10:'BPL',0x11:'ORA',0x12:'ORA',0x13:'ORA',0x14:'TRB',0x15:'ORA',0x16:'ASL',0x17:'ORA',
    0x18:'CLC',0x19:'ORA',0x1A:'INC',0x1B:'TCS',0x1C:'TRB',0x1D:'ORA',0x1E:'ASL',0x1F:'ORA',
    0x20:'JSR',0x21:'AND',0x22:'JSL',0x23:'AND',0x24:'BIT',0x25:'AND',0x26:'ROL',0x27:'AND',
    0x28:'PLP',0x29:'AND',0x2A:'ROL',0x2B:'PLD',0x2C:'BIT',0x2D:'AND',0x2E:'ROL',0x2F:'AND',
    0x30:'BMI',0x31:'AND',0x32:'AND',0x33:'AND',0x34:'BIT',0x35:'AND',0x36:'ROL',0x37:'AND',
    0x38:'SEC',0x39:'AND',0x3A:'DEC',0x3B:'TSC',0x3C:'BIT',0x3D:'AND',0x3E:'ROL',0x3F:'AND',
    0x40:'RTI',0x41:'EOR',0x42:'WDM',0x43:'EOR',0x44:'MVP',0x45:'EOR',0x46:'LSR',0x47:'EOR',
    0x48:'PHA',0x49:'EOR',0x4A:'LSR',0x4B:'PHK',0x4C:'JMP',0x4D:'EOR',0x4E:'LSR',0x4F:'EOR',
    0x50:'BVC',0x51:'EOR',0x52:'EOR',0x53:'EOR',0x54:'MVN',0x55:'EOR',0x56:'LSR',0x57:'EOR',
    0x58:'CLI',0x59:'EOR',0x5A:'PHY',0x5B:'TCD',0x5C:'JML',0x5D:'EOR',0x5E:'LSR',0x5F:'EOR',
    0x60:'RTS',0x61:'ADC',0x62:'PER',0x63:'ADC',0x64:'STZ',0x65:'ADC',0x66:'ROR',0x67:'ADC',
    0x68:'PLA',0x69:'ADC',0x6A:'ROR',0x6B:'RTL',0x6C:'JMP',0x6D:'ADC',0x6E:'ROR',0x6F:'ADC',
    0x70:'BVS',0x71:'ADC',0x72:'ADC',0x73:'ADC',0x74:'STZ',0x75:'ADC',0x76:'ROR',0x77:'ADC',
    0x78:'SEI',0x79:'ADC',0x7A:'PLY',0x7B:'TDC',0x7C:'JMP',0x7D:'ADC',0x7E:'ROR',0x7F:'ADC',
    0x80:'BRA',0x81:'STA',0x82:'BRL',0x83:'STA',0x84:'STY',0x85:'STA',0x86:'STX',0x87:'STA',
    0x88:'DEY',0x89:'BIT',0x8A:'TXA',0x8B:'PHB',0x8C:'STY',0x8D:'STA',0x8E:'STX',0x8F:'STA',
    0x90:'BCC',0x91:'STA',0x92:'STA',0x93:'STA',0x94:'STY',0x95:'STA',0x96:'STX',0x97:'STA',
    0x98:'TYA',0x99:'STA',0x9A:'TXS',0x9B:'TXY',0x9C:'STZ',0x9D:'STA',0x9E:'STZ',0x9F:'STA',
    0xA0:'LDY',0xA1:'LDA',0xA2:'LDX',0xA3:'LDA',0xA4:'LDY',0xA5:'LDA',0xA6:'LDX',0xA7:'LDA',
    0xA8:'TAY',0xA9:'LDA',0xAA:'TAX',0xAB:'PLB',0xAC:'LDY',0xAD:'LDA',0xAE:'LDX',0xAF:'LDA',
    0xB0:'BCS',0xB1:'LDA',0xB2:'LDA',0xB3:'LDA',0xB4:'LDY',0xB5:'LDA',0xB6:'LDX',0xB7:'LDA',
    0xB8:'CLV',0xB9:'LDA',0xBA:'TSX',0xBB:'TYX',0xBC:'LDY',0xBD:'LDA',0xBE:'LDX',0xBF:'LDA',
    0xC0:'CPY',0xC1:'CMP',0xC2:'REP',0xC3:'CMP',0xC4:'CPY',0xC5:'CMP',0xC6:'DEC',0xC7:'CMP',
    0xC8:'INY',0xC9:'CMP',0xCA:'DEX',0xCB:'WAI',0xCC:'CPY',0xCD:'CMP',0xCE:'DEC',0xCF:'CMP',
    0xD0:'BNE',0xD1:'CMP',0xD2:'CMP',0xD3:'CMP',0xD4:'PEI',0xD5:'CMP',0xD6:'DEC',0xD7:'CMP',
    0xD8:'CLD',0xD9:'CMP',0xDA:'PHX',0xDB:'STP',0xDC:'JML',0xDD:'CMP',0xDE:'DEC',0xDF:'CMP',
    0xE0:'CPX',0xE1:'SBC',0xE2:'SEP',0xE3:'SBC',0xE4:'CPX',0xE5:'SBC',0xE6:'INC',0xE7:'SBC',
    0xE8:'INX',0xE9:'SBC',0xEA:'NOP',0xEB:'XBA',0xEC:'CPX',0xED:'SBC',0xEE:'INC',0xEF:'SBC',
    0xF0:'BEQ',0xF1:'SBC',0xF2:'SBC',0xF3:'SBC',0xF4:'PEA',0xF5:'SBC',0xF6:'INC',0xF7:'SBC',
    0xF8:'SED',0xF9:'SBC',0xFA:'PLX',0xFB:'XCE',0xFC:'JSR',0xFD:'SBC',0xFE:'INC',0xFF:'SBC',
}

def disasm_range(data, base, start_off, end_off):
    """Simple disassembly with fixed 8-bit M/X assumption."""
    lines = []
    i = start_off
    while i < end_off and i < len(data):
        op = data[i]
        addr = base + i
        sz = OP_SIZE.get(op, 1)
        mn = MNEMONICS.get(op, '???')

        if i + sz > len(data):
            break

        raw = ' '.join(f'{data[i+j]:02X}' for j in range(sz))

        if sz == 1:
            operand = ''
        elif op in (0x10,0x30,0x50,0x70,0x80,0x90,0xB0,0xD0,0xF0):  # rel8
            rel = data[i+1]
            if rel >= 0x80: rel -= 256
            target = addr + 2 + rel
            operand = f'${target:04X}'
        elif op in (0x62,0x82):  # rel16
            rel = data[i+1] | (data[i+2] << 8)
            if rel >= 0x8000: rel -= 0x10000
            target = addr + 3 + rel
            operand = f'${target:04X}'
        elif sz == 2:
            operand = f'#${data[i+1]:02X}' if op in (0x00,0x02,0x09,0x29,0x49,0x69,0x89,0xA0,0xA2,0xA9,0xC0,0xC2,0xC9,0xE0,0xE2,0xE9) else f'${data[i+1]:02X}'
        elif sz == 3:
            val = data[i+1] | (data[i+2] << 8)
            operand = f'${val:04X}'
        elif sz == 4:
            val = data[i+1] | (data[i+2] << 8) | (data[i+3] << 16)
            operand = f'${val:06X}'
        else:
            operand = ''

        marker = '  <--- PC STUCK HERE' if addr == 0x82E0 else ''
        lines.append((addr, raw, f'{mn} {operand}'.strip(), marker))
        i += sz
    return lines

# Load D64
d64 = open("C:/LLM/C64/MiSTerSuperCPU/SCPU1.D64", 'rb').read()
entries = list_dir(d64)

print("="*70)
print("SCPU KICKS D64 - Deep Analysis")
print("="*70)

# Extract all PRGs
files = {}
for e in entries:
    fd = extract_file(d64, e['track'], e['sector'])
    if len(fd) < 2: continue
    la = fd[0] | (fd[1] << 8)
    pd = fd[2:]
    files[e['name']] = {'load': la, 'data': pd, 'end': la + len(pd) - 1}
    print(f"\n{e['name']}: ${la:04X}-${la+len(pd)-1:04X} ({len(pd)} bytes, {e['size']} blocks)")

# Analyze the loader (SCPU KICKS !/DMA)
print("\n" + "="*70)
print("LOADER ANALYSIS: SCPU KICKS !/DMA")
print("="*70)

loader = files['SCPU KICKS !/DMA']
ld = loader['data']
la = loader['load']

# The BASIC header at $0801 has a SYS line
# $0801: 0B 08 EF 00 9E 32 30 36 31 00 00 00
# This is BASIC: line number $08EF ($080B-$0801=10, next line ptr), "9E2061" = SYS 2061
# Actually: bytes 0B 08 = next line pointer ($080B)
# EF 00 = line number ($00EF = 239)
# 9E = SYS token
# 32 30 36 31 = "2061"
# 00 = end of line
# 00 00 = end of program
print(f"\nBASIC line at ${la:04X}:")
# Parse BASIC tokens
ptr = ld[0] | (ld[1] << 8)
linenum = ld[2] | (ld[3] << 8)
i = 4
basic_text = ""
while i < len(ld) and ld[i] != 0:
    b = ld[i]
    if b == 0x9E:
        basic_text += "SYS"
    elif 0x20 <= b <= 0x7E:
        basic_text += chr(b)
    else:
        basic_text += f"[{b:02X}]"
    i += 1
print(f"  Line {linenum}: {basic_text}")

# Find the SYS address
import re
m = re.search(r'SYS\s*(\d+)', basic_text)
if m:
    sys_addr = int(m.group(1))
    print(f"  SYS target: ${sys_addr:04X} = {sys_addr}")

# The actual code starts after BASIC stub
# JMP $7854 is at $080D
print(f"\nCode analysis from entry point:")
print(f"  ${la+0x0C:04X}: {ld[0x0C]:02X} {ld[0x0D]:02X} {ld[0x0E]:02X} = JMP ${ld[0x0D] | (ld[0x0E] << 8):04X}")

# Disassemble from $7854 (the JMP target, within the loader's range)
jmp_target = 0x7854
if la <= jmp_target <= loader['end']:
    off = jmp_target - la
    print(f"\nDisassembly at ${jmp_target:04X} (JMP target from entry):")
    lines = disasm_range(ld, la, off, off + 128)
    for addr, raw, dis, marker in lines:
        print(f"  ${addr:04X}: {raw:<14s} {dis}{marker}")

# Search for references to $82E0 in all files
print("\n" + "="*70)
print("SEARCHING FOR REFERENCES TO $82E0")
print("="*70)

for name, f in files.items():
    d = f['data']
    la = f['load']
    # Search for $82E0 as little-endian address
    for i in range(len(d) - 1):
        if d[i] == 0xE0 and d[i+1] == 0x82:
            addr = la + i
            # Show context
            ctx_start = max(0, i - 5)
            ctx_end = min(len(d), i + 10)
            ctx = ' '.join(f'{d[j]:02X}' for j in range(ctx_start, ctx_end))
            print(f"  {name} at ${addr:04X}: ...{ctx}...")
            # Try to disassemble around it
            ds = max(0, i - 8)
            lines = disasm_range(d, la, ds, min(i + 16, len(d)))
            for a, r, dis, marker in lines:
                if la + i - 2 <= a <= la + i + 2:
                    print(f"    ${a:04X}: {r:<14s} {dis}")

# Search for SuperCPU DMA registers specifically
print("\n" + "="*70)
print("SUPERCPU DMA REGISTER REFERENCES")
print("="*70)
print("(Looking for $D071-$D07F as absolute addresses in code)")

dma_regs = {
    0xD071: 'DMA source addr byte 0',
    0xD072: 'DMA source addr byte 1',
    0xD073: 'DMA source addr byte 2',
    0xD074: 'DMA dest addr byte 0',
    0xD075: 'DMA dest addr byte 1',
    0xD076: 'DMA dest addr byte 2',
    0xD077: 'DMA length byte 0',
    0xD078: 'DMA length byte 1',
    0xD079: 'DMA command / Software 1MHz',
    0xD07A: 'Speed: slow (1MHz)',
    0xD07B: 'Speed: fast (20MHz)',
    0xD07C: 'VIC bank optimization',
    0xD07D: 'Regs disable mirror',
    0xD07E: 'Regs enable / ROM visible',
    0xD07F: 'Regs disable',
}

for name, f in files.items():
    d = f['data']
    la = f['load']
    found = []
    for i in range(len(d) - 1):
        val = d[i] | (d[i+1] << 8)
        if 0xD070 <= val <= 0xD07F:
            addr = la + i
            # Check if this looks like an instruction operand
            if i > 0:
                prev_op = d[i-1]
                sz = OP_SIZE.get(prev_op, 0)
                mn = MNEMONICS.get(prev_op, '???')
                if sz == 3:  # This is likely an operand of a 3-byte instruction
                    found.append((addr-1, val, f"{mn} ${val:04X}"))
                    continue
            # Also check 2 bytes back for indexed modes
            if i > 1:
                prev2_op = d[i-1]  # This would be X/Y index byte for abs,X/Y
                # Actually the opcode is at i-1 for 3-byte instr, so operand starts at i
                pass
            found.append((addr, val, f"raw ref"))

    if found:
        print(f"\n  {name}:")
        for addr, reg, desc in found:
            reg_name = dma_regs.get(reg, f'${reg:04X}')
            print(f"    ${addr:04X}: {desc} - {reg_name}")

# Search specifically for BEQ patterns in the code that would create wait loops
print("\n" + "="*70)
print("BEQ WAIT LOOP PATTERNS (F0 FE = BEQ to self)")
print("="*70)

for name, f in files.items():
    d = f['data']
    la = f['load']
    for i in range(len(d) - 1):
        if d[i] == 0xF0 and d[i+1] == 0xFE:  # BEQ $-2 (branch to self)
            addr = la + i
            # Show surrounding context
            ctx_start = max(0, i - 10)
            ctx_end = min(len(d), i + 10)
            print(f"\n  {name} at ${addr:04X}: BEQ ${addr:04X} (self-loop)")
            lines = disasm_range(d, la, max(0, i-16), min(i+10, len(d)))
            for a, r, dis, marker in lines:
                flag = " <<<" if a == addr else ""
                print(f"    ${a:04X}: {r:<14s} {dis}{flag}")

# Also search for BEQ FD, FC (small backward branches that could be wait loops)
print("\n" + "="*70)
print("BEQ SMALL BACKWARD BRANCH PATTERNS")
print("="*70)

for name, f in files.items():
    d = f['data']
    la = f['load']
    for i in range(len(d) - 1):
        if d[i] == 0xF0 and d[i+1] >= 0xF8:  # BEQ backward by <= 8 bytes
            addr = la + i
            rel = d[i+1] - 256
            target = addr + 2 + rel
            # Only show if it looks like it's in a code region
            # Check if preceding bytes make sense as instructions
            if i >= 2:
                ctx_start = max(0, i - 20)
                lines = disasm_range(d, la, ctx_start, min(i+10, len(d)))
                # Filter: only show if the preceding instructions look reasonable
                has_lda_cmp = False
                for a, r, dis, marker in lines:
                    if any(x in dis for x in ['LDA','CMP','LDX','LDY','BIT','AND','ORA','EOR','ADC','SBC','CPX','CPY']):
                        has_lda_cmp = True
                if has_lda_cmp:
                    print(f"\n  {name} at ${addr:04X}: BEQ ${target:04X} (back {-rel} bytes)")
                    for a, r, dis, marker in lines:
                        flag = " <<<" if a == addr else ""
                        print(f"    ${a:04X}: {r:<14s} {dis}{flag}")

# Look at where code that runs near $8200 might be loaded
print("\n" + "="*70)
print("CODE SETUP: Tracing what ends up at $82E0")
print("="*70)

# The loader copies code from $7754+X to $982A+X (seen at $082C-$082F)
# Let's analyze this more carefully
print("\nLoader memory operations (STA to absolute addresses):")
lines = disasm_range(ld, 0x0801, 0, len(ld))
for addr, raw, dis, marker in lines:
    if 'STA $' in dis and len(dis) > 5:
        # Extract target address
        try:
            target_str = dis.split('$')[1][:4]
            target = int(target_str, 16)
            if 0x8000 <= target <= 0x8FFF:
                print(f"  ${addr:04X}: {raw:<14s} {dis}")
        except:
            pass

# The code at $0115 (jumped to from $083E) is probably the decompressor
# that was copied to ZP/$0100 area. Let's look at what was copied there.
print("\n\nData copied to $0100-$0252 (from $08F0+X):")
src_off = 0x08F0 - 0x0801
if src_off + 0x54 <= len(ld):
    # 0x53 bytes copied to $01FF downward (X from $53 to 1)
    # Actually: LDX #$53; LDA $08F0,X; STA $01FF,X; DEX; BNE
    # So copies $08F1-$0943 to $0200-$0252
    print("  Copied to $0200-$0252:")
    lines = disasm_range(ld, 0x0200, src_off + 1, src_off + 0x54)
    for addr, raw, dis, marker in lines:
        print(f"    ${addr:04X}: {raw:<14s} {dis}")

print("\nData copied to $00F7-$01A7 (from $0841+X):")
src_off2 = 0x0841 - 0x0801
if src_off2 + 0xB2 <= len(ld):
    # LDX #$B1; LDA $0840,X; STA $00F6,X; DEX; BNE
    # Copies $0841-$08F1 to $00F7-$01A7
    print("  Copied to $00F7-$01A7:")
    lines = disasm_range(ld, 0x00F7, src_off2, src_off2 + 0xB2)
    for addr, raw, dis, marker in lines:
        print(f"    ${addr:04X}: {raw:<14s} {dis}")

# Look at the main decompression loop that writes to $9800+ area
# The copy loop at $0829-$083E copies $70 pages from $7754 down to $982A down
# That's 0x70 * 256 = 28672 bytes
print(f"\nMain data copy: $7754 region -> $982A region ({0x70} pages = {0x70*256} bytes)")
print(f"  Source: $0754-${0x7754+0x70*256-1:04X}")
print(f"  Dest:   $182A-${0x982A+0x70*256-1:04X}")
# Wait - the loop DECs the high bytes, so it copies downward
# Starting at $7754+X → $982A+X, X counts 0-255, then dec high bytes
# Y starts at $70, so 112 pages = 28672 bytes
# The source high byte ($7754) gets decremented: $7754, $7654, $7554...
# The dest high byte ($982A) gets decremented: $982A, $972A, $962A...
# After Y=0: source = $(77-70)54 = $0754, dest = $(98-70)2A = $282A

# Hmm, this means the copy is:
# $7754-$77FF → $982A-$98FF (page 0)
# $7654-$76FF → $972A-$97FF (page 1)
# ...
# $0854-$08FF → $292A-$29FF (page 112)
# This doesn't directly copy to $82E0.

# Actually wait, the dest is $982A decremented. Let me re-read:
# The initial copy is X=0..255, LDA $7754,X STA $982A,X
# Then DEC $0831 (source high), DEC $082E (dest high), DEY, BNE
# So it starts with the high bytes at $77 and $98, goes down.
# After 1st iteration: source=$7654, dest=$972A
# The $82xx region would be:  $98 - ($98 - $82) = $82, so iteration $98-$82=$16
# At iteration $16: source = $77-$16=$61, offset $2A
# So $82xx gets data from $61xx region of the loader!

src_page_for_82 = 0x77 - (0x98 - 0x82)
print(f"\n$82xx data comes from source page ${src_page_for_82:02X}xx (offset $2A)")
print(f"Specifically $82E0 comes from source ${src_page_for_82:02X}{0xE0-0x2A+0x54:02X}")
# Hmm, the offset isn't quite right. Let me think again.
# The copy: STA $982A,X where X goes 0..255
# So dest addresses are $982A+0 through $982A+255 = $982A-$9929
# Wait no, X wraps: $982A+0 to $982A+$FF = $9829+$100 = $9929
# But that spans a page boundary.
# Actually LDA abs,X with X=0..255 reads $7754 through $7853
# STA abs,X writes $982A through $9929
# Then high bytes get decremented:
# Next: reads $7654-$7753, writes $972A-$9829
# ...etc

# For the dest range containing $82E0:
# We need $982A + X = addr, reduced by page decrements
# After k decrements: dest_base = ($98-k)*256 + $2A
# Range: ($98-k)*256 + $2A to ($98-k)*256 + $2A + 255
# For $82E0 to be in range: ($98-k)*256 + $2A <= $82E0 < ($98-k)*256 + $2A + 256
# ($98-k)*256 <= $82E0 - $2A = $82B6
# $98-k <= $82 (since $82B6/256 = $82.B6, so floor = $82)
# k >= $98 - $82 = $16 = 22

k = 0x98 - 0x82  # = 22 ($16)
dest_base = (0x98 - k) * 256 + 0x2A  # = $822A
src_base_page = 0x77 - k  # = $61
src_base = src_base_page * 256 + 0x54  # = $6154

# Offset within the 256-byte block for $82E0:
offset_in_block = 0x82E0 - dest_base  # = $82E0 - $822A = $B6 = 182
x_value = offset_in_block

print(f"\nFor $82E0:")
print(f"  Copy iteration k={k} ($16)")
print(f"  Dest base: ${dest_base:04X}, offset: ${offset_in_block:02X}")
print(f"  Source: ${src_base+x_value:04X} = LDA ${src_base_page * 256 + 0x54:04X} + X=${x_value:02X}")
print(f"  Source addr: ${src_base_page * 256 + 0x54 + x_value:04X}")

src_addr = src_base_page * 256 + 0x54 + x_value
print(f"\nBUT WAIT - this is the COMPRESSED data, not the final code!")
print("The loader copies data, but it also runs a decompressor at $0115.")
print("The decompressor modifies the data in place or writes to different locations.")
print("We cannot determine the final runtime code at $82E0 from the D64 alone.")
print("The code at $82E0 is the result of decompression of parts B and C.")

# Let's look for common SCPU demo patterns in part C (which covers $82E0)
print("\n" + "="*70)
print("ANALYSIS OF 'SUPERCPU KICKS C' ($2200-$E9FF)")
print("="*70)

c_data = files['SUPERCPU KICKS C']['data']
c_load = files['SUPERCPU KICKS C']['load']

# This is 51200 bytes of compressed/packed data
# Look for any plaintext or recognizable patterns
print(f"File size: {len(c_data)} bytes")
print(f"Load range: ${c_load:04X}-${c_load+len(c_data)-1:04X}")

# Check entropy/compression: count unique bytes, look for runs
from collections import Counter
byte_counts = Counter(c_data)
print(f"Unique byte values: {len(byte_counts)}/256")

# Look for common SCPU register patterns even in compressed data
# $D07A = slow, $D07B = fast are the key speed registers
print("\nSearching for $D07A/$D07B (speed register) patterns in all parts:")
for name, f in files.items():
    d = f['data']
    la = f['load']
    for i in range(len(d) - 1):
        if d[i] == 0x7A and d[i+1] == 0xD0:
            addr = la + i
            if i > 0:
                op = d[i-1]
                mn = MNEMONICS.get(op, '???')
                sz = OP_SIZE.get(op, 0)
                if sz == 3:
                    print(f"  {name} ${addr-1:04X}: {mn} $D07A (speed: slow/1MHz)")
        if d[i] == 0x7B and d[i+1] == 0xD0:
            addr = la + i
            if i > 0:
                op = d[i-1]
                mn = MNEMONICS.get(op, '???')
                sz = OP_SIZE.get(op, 0)
                if sz == 3:
                    print(f"  {name} ${addr-1:04X}: {mn} $D07B (speed: fast/20MHz)")

# Also look for $D012 (VIC raster register) - common wait target
print("\nSearching for $D012 (VIC raster) references:")
for name, f in files.items():
    d = f['data']
    la = f['load']
    count = 0
    for i in range(len(d) - 1):
        if d[i] == 0x12 and d[i+1] == 0xD0:
            addr = la + i
            if i > 0:
                op = d[i-1]
                mn = MNEMONICS.get(op, '???')
                sz = OP_SIZE.get(op, 0)
                if sz == 3:
                    count += 1
                    if count <= 10:
                        print(f"  {name} ${addr-1:04X}: {mn} $D012")
    if count > 10:
        print(f"  {name}: ... and {count-10} more references")

# Search for $D011 (VIC control register)
print("\nSearching for $D011 (VIC control) references:")
for name, f in files.items():
    d = f['data']
    la = f['load']
    count = 0
    for i in range(len(d) - 1):
        if d[i] == 0x11 and d[i+1] == 0xD0:
            addr = la + i
            if i > 0:
                op = d[i-1]
                mn = MNEMONICS.get(op, '???')
                sz = OP_SIZE.get(op, 0)
                if sz == 3:
                    count += 1
                    if count <= 10:
                        print(f"  {name} ${addr-1:04X}: {mn} $D011")
    if count > 10:
        print(f"  {name}: ... and {count-10} more references")

# The demo title says "!/DMA" - this suggests it uses SuperCPU DMA
# The SuperCPU DMA registers are at $D070-$D07F on the real SuperCPU
# Let's search for those more carefully
print("\n" + "="*70)
print("SUPERCPU-SPECIFIC REGISTER ANALYSIS")
print("="*70)

scpu_regs = {
    0xD070: 'DMA err addr/SIMM cfg',
    0xD071: 'DMA source byte 0',
    0xD072: 'DMA source byte 1',
    0xD073: 'DMA source byte 2',
    0xD074: 'DMA dest byte 0',
    0xD075: 'DMA dest byte 1',
    0xD076: 'DMA dest byte 2',
    0xD077: 'DMA length byte 0',
    0xD078: 'DMA length byte 1 / start',
    0xD079: 'Software 1MHz enable',
    0xD07A: 'Speed: slow',
    0xD07B: 'Speed: fast',
    0xD07C: 'VIC bank opt',
    0xD07D: 'Mirror disable regs / SCPU disable',
    0xD07E: 'Enable regs / ROM visible read',
    0xD07F: 'Disable regs',
    0xD0B0: 'HW version',
    0xD0B2: 'HW status/SIMM',
    0xD0B4: 'Optim mode',
    0xD0B5: 'Speed/JiffyDOS status',
    0xD0B6: 'Emulation mode flag',
    0xD0B8: 'Speed status combined',
    0xD0BC: 'SCPU ID ($C9)',
}

for name, f in files.items():
    d = f['data']
    la = f['load']
    file_refs = []
    for i in range(len(d) - 1):
        val = d[i] | (d[i+1] << 8)
        if val in scpu_regs:
            addr = la + i
            if i > 0:
                op = d[i-1]
                mn = MNEMONICS.get(op, '???')
                sz = OP_SIZE.get(op, 0)
                if sz == 3:
                    file_refs.append((addr-1, val, mn))
    if file_refs:
        print(f"\n  {name}:")
        for addr, reg, mn in sorted(file_refs):
            print(f"    ${addr:04X}: {mn} ${reg:04X}  ({scpu_regs[reg]})")
