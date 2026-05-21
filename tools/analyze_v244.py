#!/usr/bin/env python3
"""
v244 analysis: decode T65/SCPU screenshots, disassemble $3380/$9F09
bytes, compare PC trace rings.

Usage:
  python tools/analyze_v244.py
"""
import os, sys, subprocess, glob

# Minimal 6502 disassembler — enough opcodes to interpret IRQ-handler
# code. Returns (mnemonic, length).
OPS = {
    0x00:('BRK',1),0x10:('BPL',2),0x18:('CLC',1),0x20:('JSR abs',3),
    0x24:('BIT zp',2),0x29:('AND #imm',2),0x2C:('BIT abs',3),
    0x30:('BMI',2),0x40:('RTI',1),0x48:('PHA',1),0x4A:('LSR A',1),
    0x49:('EOR #imm',2),0x4C:('JMP abs',3),0x50:('BVC',2),
    0x60:('RTS',1),0x68:('PLA',1),0x69:('ADC #imm',2),
    0x6C:('JMP (abs)',3),0x70:('BVS',2),0x78:('SEI',1),
    0x85:('STA zp',2),0x86:('STX zp',2),0x88:('DEY',1),0x8A:('TXA',1),
    0x8C:('STY abs',3),0x8D:('STA abs',3),0x8E:('STX abs',3),
    0x90:('BCC',2),0x91:('STA (zp),Y',2),0x95:('STA zp,X',2),
    0x98:('TYA',1),0x99:('STA abs,Y',3),0x9A:('TXS',1),
    0x9D:('STA abs,X',3),0xA0:('LDY #imm',2),0xA2:('LDX #imm',2),
    0xA5:('LDA zp',2),0xA8:('TAY',1),0xA9:('LDA #imm',2),
    0xAA:('TAX',1),0xAC:('LDY abs',3),0xAD:('LDA abs',3),
    0xAE:('LDX abs',3),0xB0:('BCS',2),0xB1:('LDA (zp),Y',2),
    0xB5:('LDA zp,X',2),0xB9:('LDA abs,Y',3),0xBC:('LDY abs,X',3),
    0xBD:('LDA abs,X',3),0xC0:('CPY #imm',2),0xC5:('CMP zp',2),
    0xC6:('DEC zp',2),0xC8:('INY',1),0xC9:('CMP #imm',2),
    0xCA:('DEX',1),0xCD:('CMP abs',3),0xD0:('BNE',2),
    0xD5:('CMP zp,X',2),0xD8:('CLD',1),0xDD:('CMP abs,X',3),
    0xE0:('CPX #imm',2),0xE6:('INC zp',2),0xE8:('INX',1),
    0xE9:('SBC #imm',2),0xEA:('NOP',1),0xEE:('INC abs',3),
    0xF0:('BEQ',2),0xF8:('SED',1),0x05:('ORA zp',2),0x06:('ASL zp',2),
    0x08:('PHP',1),0x09:('ORA #imm',2),0x0D:('ORA abs',3),
    0x0E:('ASL abs',3),0x16:('ASL zp,X',2),0x1D:('ORA abs,X',3),
    0x35:('AND zp,X',2),0x38:('SEC',1),0x3D:('AND abs,X',3),
    0x46:('LSR zp',2),0x4E:('LSR abs',3),0x66:('ROR zp',2),
    0x6E:('ROR abs',3),0x76:('ROR zp,X',2),0x7E:('ROR abs,X',3),
    0x84:('STY zp',2),0x94:('STY zp,X',2),0x96:('STX zp,Y',2),
    0xA1:('LDA (zp,X)',2),0xB6:('LDX zp,Y',2),0xC4:('CPY zp',2),
    0xE4:('CPX zp',2),0xEC:('CPX abs',3),
}

def disasm(bytes_, base=0x3380):
    """Disassemble byte list starting at `base`."""
    out = []
    i = 0
    pc = base
    while i < len(bytes_):
        op = bytes_[i]
        info = OPS.get(op, (f'?? ${op:02X}', 1))
        mnem, n = info
        operand = bytes_[i+1:i+n]
        if n == 1:
            line = f'  ${pc:04X}: {op:02X}             {mnem}'
        elif n == 2:
            v = operand[0] if operand else 0
            if mnem in ('BPL','BMI','BCC','BCS','BVC','BVS','BNE','BEQ'):
                # branches: signed offset
                off = v if v < 128 else v - 256
                tgt = pc + 2 + off
                line = f'  ${pc:04X}: {op:02X} {v:02X}          {mnem} ${tgt:04X}'
            else:
                line = f'  ${pc:04X}: {op:02X} {v:02X}          {mnem.replace("imm",f"${v:02X}").replace(" zp",f" ${v:02X}")}'
        else:
            lo = operand[0] if len(operand)>0 else 0
            hi = operand[1] if len(operand)>1 else 0
            addr = lo | (hi<<8)
            line = f'  ${pc:04X}: {op:02X} {lo:02X} {hi:02X}       {mnem.replace(" abs",f" ${addr:04X}").replace(" (abs)",f" (${addr:04X})")}'
        out.append(line)
        i += n
        pc += n
    return out

def parse_overlay(png):
    """Run decode_overlay.py and parse rows."""
    r = subprocess.run(['python','tools/decode_overlay.py',png], capture_output=True, text=True)
    rows = {}
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith('R') and ':' in line:
            tag, val = line.split(':',1)
            rows[tag.strip()] = val.strip()
    return rows

def hex_to_bytes(s):
    """Parse '3380 9F0AB1...' style — split at first space, take hex part."""
    parts = s.split(None,1)
    if len(parts) < 2: return []
    h = parts[1].replace(' ','')
    return [int(h[i:i+2],16) for i in range(0,len(h),2)]

def parse_pc(s):
    """Parse '0=003380 1=001234' → list of PCs."""
    pcs = []
    for tok in s.split():
        if '=' in tok:
            _, v = tok.split('=',1)
            try:
                pcs.append(int(v.strip(),16))
            except ValueError:
                pass
    return pcs

def analyze_dir(d, label):
    print(f'\n========== {label}: {d} ==========')
    pngs = sorted(glob.glob(os.path.join(d,'*.png')))
    if not pngs:
        print('  (no captures)')
        return
    # Use the most recent few captures
    seen_3380, seen_9F09, seen_t = set(), set(), set()
    last_rows = None
    for p in pngs:
        rows = parse_overlay(p)
        last_rows = rows
        b3380 = tuple(hex_to_bytes(rows.get('R4','')) + hex_to_bytes(rows.get('R5','')))
        b9F09 = tuple(hex_to_bytes(rows.get('R6','')) + hex_to_bytes(rows.get('R7','')))
        seen_3380.add(b3380[:16])
        seen_9F09.add(b9F09[:16])
        seen_t.add((rows.get('R8',''), rows.get('R9','')))

    print(f'  Distinct $3380-$338F byte patterns: {len(seen_3380)}')
    for b in sorted(seen_3380):
        print('   ', ' '.join(f'{x:02X}' for x in b))
    print(f'\n  $3380-$338F disassembly (first observed):')
    if seen_3380:
        b = list(next(iter(seen_3380)))
        for line in disasm(b, 0x3380): print(line)
    print(f'\n  Distinct $9F09-$9F18 byte patterns: {len(seen_9F09)}')
    for b in sorted(seen_9F09):
        print('   ', ' '.join(f'{x:02X}' for x in b))
    print(f'\n  $9F09-$9F18 disassembly (first observed):')
    if seen_9F09:
        b = list(next(iter(seen_9F09)))
        for line in disasm(b, 0x9F09): print(line)
    print(f'\n  PC trace rings ($33xx) seen ({len(seen_t)} unique):')
    for r8, r9 in sorted(seen_t):
        print(f'    R8={r8} R9={r9}')
    if last_rows:
        print(f'\n  Last-frame disp2/W0/W1: R10={last_rows.get("R10","")} R11={last_rows.get("R11","")}')

if __name__ == '__main__':
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(base)
    analyze_dir('tools/dl_screens_v244_t65', 'T65')
    analyze_dir('tools/dl_screens_v244_scpu', 'SCPU')
