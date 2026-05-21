#!/usr/bin/env python3
"""Dump dispatcher page $0100 as copied by Asterix phase-2 from src $0864."""
import sys

with open(sys.argv[1] if len(sys.argv) > 1 else 'asterix.prg', 'rb') as f:
    data = f.read()

load = data[0] | (data[1] << 8)
print(f'Load addr: ${load:04X}  file: {len(data)}  code: {len(data)-2}')
print(f'End addr : ${load + len(data) - 2:04X}')

src_off = 0x864 - load + 2
print(f'Dispatcher src file offset: 0x{src_off:x} (assuming src=$0864)')

if 0 <= src_off and src_off + 0x100 <= len(data):
    disp = data[src_off:src_off + 0x100]
    print()
    print('Full dispatcher page $0100 (as copied):')
    for row in range(16):
        base = row * 16
        hx = ' '.join(f'{disp[base+i]:02x}' for i in range(16))
        print(f'  $01{base:02X}: {hx}')
    print()
    # Simple 6502 disasm starting at $01A8
    OPS = {
        0xE0: ('CPX #', 1), 0xF0: ('BEQ', 1), 0xD0: ('BNE', 1), 0xB0: ('BCS', 1),
        0x90: ('BCC', 1), 0x10: ('BPL', 1), 0x30: ('BMI', 1), 0x50: ('BVC', 1),
        0x70: ('BVS', 1),
        0x2C: ('BIT abs', 2), 0x24: ('BIT zp', 1),
        0xA9: ('LDA #', 1), 0x85: ('STA zp', 1), 0x8D: ('STA abs', 2),
        0xA5: ('LDA zp', 1), 0xAD: ('LDA abs', 2),
        0x58: ('CLI', 0), 0x78: ('SEI', 0), 0x38: ('SEC', 0), 0x18: ('CLC', 0),
        0x60: ('RTS', 0), 0x20: ('JSR', 2), 0x4C: ('JMP', 2), 0x6C: ('JMP ()', 2),
        0xEA: ('NOP', 0), 0xAA: ('TAX', 0), 0xA8: ('TAY', 0), 0x8A: ('TXA', 0),
        0x98: ('TYA', 0), 0x48: ('PHA', 0), 0x68: ('PLA', 0), 0x28: ('PLP', 0),
        0x08: ('PHP', 0),
        0xA2: ('LDX #', 1), 0xA0: ('LDY #', 1), 0xE8: ('INX', 0), 0xC8: ('INY', 0),
        0xCA: ('DEX', 0), 0x88: ('DEY', 0),
    }
    def dis(offs, end):
        i = offs
        while i < end:
            op = disp[i]
            name, sz = OPS.get(op, (f'DB ${op:02X}', 0))
            ops = disp[i+1:i+1+sz]
            opstr = ''
            if sz == 1:
                opstr = f'${ops[0]:02X}'
                if name in ('BEQ','BNE','BCS','BCC','BPL','BMI','BVC','BVS'):
                    tgt = (0x0100 + i + 2 + (ops[0] if ops[0] < 0x80 else ops[0]-0x100)) & 0xFFFF
                    opstr = f'${tgt:04X}'
            elif sz == 2:
                opstr = f'${ops[1]:02X}{ops[0]:02X}'
            print(f'  $01{i:02X}: {op:02x} {" ".join(f"{b:02x}" for b in ops):<5s}  {name} {opstr}')
            i += 1 + sz
    print('Disasm from $01A8 to $01E0:')
    dis(0xA8, 0xE0)
    print()
    print('Disasm from $0197 to $01AC:')
    dis(0x97, 0xAC)
    print()
    print('Jump table @ $011A:')
    print('  ' + ' '.join(f'{disp[0x1A+i]:02X}' for i in range(8)))
