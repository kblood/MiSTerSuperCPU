#!/usr/bin/env python3
"""Quick 65C816 disassembler focused on tracing the SCPU kickstart at $F8:$80C1.

Tracks M/X flag state through SEP/REP so immediate operand sizing is correct.
Starts in emu mode but kickstart enters native almost immediately.
"""
import sys

ROM = open('tools/scpu64.bin','rb').read()

OPS = {
    0x00:('BRK','imm8'), 0x02:('COP','imm8'), 0x42:('WDM','imm8'),
    0x18:('CLC','imp'), 0x38:('SEC','imp'), 0x58:('CLI','imp'),
    0x78:('SEI','imp'), 0xD8:('CLD','imp'), 0xF8:('SED','imp'),
    0xB8:('CLV','imp'), 0xFB:('XCE','imp'),
    0xEA:('NOP','imp'), 0xCB:('WAI','imp'), 0xDB:('STP','imp'),
    0xC2:('REP','imm8'), 0xE2:('SEP','imm8'),
    0xA9:('LDA','imm_m'), 0xA2:('LDX','imm_x'), 0xA0:('LDY','imm_x'),
    0x89:('BIT','imm_m'),
    0x8D:('STA','abs'), 0xAD:('LDA','abs'), 0xCD:('CMP','abs'),
    0xEC:('CPX','abs'), 0xCC:('CPY','abs'), 0xEE:('INC','abs'), 0xCE:('DEC','abs'),
    0xAE:('LDX','abs'), 0xAC:('LDY','abs'), 0x8E:('STX','abs'), 0x8C:('STY','abs'),
    0x6D:('ADC','abs'), 0xED:('SBC','abs'), 0x2D:('AND','abs'), 0x0D:('ORA','abs'),
    0x4D:('EOR','abs'),
    0x9D:('STA','abs_x'), 0xBD:('LDA','abs_x'), 0x99:('STA','abs_y'), 0xB9:('LDA','abs_y'),
    0x85:('STA','zp'), 0xA5:('LDA','zp'), 0x95:('STA','zp_x'), 0xB5:('LDA','zp_x'),
    0x86:('STX','zp'), 0xA6:('LDX','zp'), 0x84:('STY','zp'), 0xA4:('LDY','zp'),
    0xC5:('CMP','zp'), 0xE5:('SBC','zp'), 0x65:('ADC','zp'), 0x25:('AND','zp'),
    0x05:('ORA','zp'), 0x45:('EOR','zp'),
    0x4B:('PHK','imp'), 0xAB:('PLB','imp'), 0x8B:('PHB','imp'),
    0x0B:('PHD','imp'), 0x2B:('PLD','imp'),
    0x48:('PHA','imp'), 0x68:('PLA','imp'), 0xDA:('PHX','imp'), 0xFA:('PLX','imp'),
    0x5A:('PHY','imp'), 0x7A:('PLY','imp'), 0x08:('PHP','imp'), 0x28:('PLP','imp'),
    0xF4:('PEA','abs'), 0xD4:('PEI','zp'), 0x62:('PER','rel16'),
    0xC8:('INY','imp'), 0x88:('DEY','imp'), 0xE8:('INX','imp'), 0xCA:('DEX','imp'),
    0xAA:('TAX','imp'), 0xA8:('TAY','imp'), 0x8A:('TXA','imp'), 0x98:('TYA','imp'),
    0xBA:('TSX','imp'), 0x9A:('TXS','imp'), 0x9B:('TXY','imp'), 0xBB:('TYX','imp'),
    0x1B:('TCS','imp'), 0x3B:('TSC','imp'), 0x5B:('TCD','imp'), 0x7B:('TDC','imp'),
    0xEB:('XBA','imp'),
    0x1A:('INC','A'), 0x3A:('DEC','A'), 0x0A:('ASL','A'), 0x4A:('LSR','A'),
    0x2A:('ROL','A'), 0x6A:('ROR','A'),
    0x29:('AND','imm_m'), 0x09:('ORA','imm_m'), 0x49:('EOR','imm_m'),
    0x69:('ADC','imm_m'), 0xE9:('SBC','imm_m'), 0xC9:('CMP','imm_m'),
    0xE0:('CPX','imm_x'), 0xC0:('CPY','imm_x'),
    0x54:('MVN','mvn'), 0x44:('MVP','mvn'),
    0x5C:('JML','long'), 0x22:('JSL','long'),
    0x6B:('RTL','imp'), 0x60:('RTS','imp'), 0x40:('RTI','imp'),
    0x6C:('JMP','ind'),
    0x4C:('JMP','abs'), 0x20:('JSR','abs'),
    0x90:('BCC','rel8'), 0xB0:('BCS','rel8'), 0xD0:('BNE','rel8'), 0xF0:('BEQ','rel8'),
    0x10:('BPL','rel8'), 0x30:('BMI','rel8'), 0x50:('BVC','rel8'), 0x70:('BVS','rel8'),
    0x80:('BRA','rel8'), 0x82:('BRL','rel16'),
    0xAF:('LDA','long'), 0x8F:('STA','long'), 0xBF:('LDA','long_x'), 0x9F:('STA','long_x'),
    0xCF:('CMP','long'), 0xEF:('SBC','long'),
    0xA7:('LDA','dpi_long'), 0x87:('STA','dpi_long'),
    0xB7:('LDA','dpi_long_y'), 0x97:('STA','dpi_long_y'),
    0xA1:('LDA','dpi_x'), 0x81:('STA','dpi_x'),
    0xB1:('LDA','dpi_y'), 0x91:('STA','dpi_y'),
    0xB2:('LDA','dpi'), 0x92:('STA','dpi'),
    0x14:('TRB','zp'), 0x1C:('TRB','abs'),
    0x04:('TSB','zp'), 0x0C:('TSB','abs'),
    0x07:('ORA','dpi_long'), 0x03:('ORA','sr'),
    0x9C:('STZ','abs'), 0x64:('STZ','zp'), 0x9E:('STZ','abs_x'), 0x74:('STZ','zp_x'),
}

def disasm(pc, m8=True, x8=True, n=40):
    out = []
    for _ in range(n):
        op = ROM[pc & 0xFFFF]
        mn, mode = OPS.get(op, ('???','imp'))
        size = 1
        operand = ''
        if mode == 'imp' or mode == 'A':
            pass
        elif mode == 'imm8':
            v = ROM[(pc+1)&0xFFFF]; operand = f"#${v:02X}"; size = 2
            if mn == 'REP':
                # update flags ('1' bits clear in P)
                if v & 0x20: m8 = False
                if v & 0x10: x8 = False
            elif mn == 'SEP':
                if v & 0x20: m8 = True
                if v & 0x10: x8 = True
        elif mode == 'imm_m':
            if m8:
                v = ROM[(pc+1)&0xFFFF]; operand = f"#${v:02X}"; size = 2
            else:
                v = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF] << 8)
                operand = f"#${v:04X}"; size = 3
        elif mode == 'imm_x':
            if x8:
                v = ROM[(pc+1)&0xFFFF]; operand = f"#${v:02X}"; size = 2
            else:
                v = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF] << 8)
                operand = f"#${v:04X}"; size = 3
        elif mode == 'abs':
            v = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF] << 8)
            operand = f"${v:04X}"; size = 3
        elif mode == 'abs_x':
            v = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF] << 8)
            operand = f"${v:04X},X"; size = 3
        elif mode == 'abs_y':
            v = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF] << 8)
            operand = f"${v:04X},Y"; size = 3
        elif mode == 'zp':
            v = ROM[(pc+1)&0xFFFF]; operand = f"${v:02X}"; size = 2
        elif mode == 'zp_x':
            v = ROM[(pc+1)&0xFFFF]; operand = f"${v:02X},X"; size = 2
        elif mode == 'zp_y':
            v = ROM[(pc+1)&0xFFFF]; operand = f"${v:02X},Y"; size = 2
        elif mode == 'rel8':
            o = ROM[(pc+1)&0xFFFF]
            t = (pc + 2 + (o if o<0x80 else o-0x100)) & 0xFFFF
            operand = f"${t:04X}"; size = 2
        elif mode == 'rel16':
            o = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF]<<8)
            so = o if o<0x8000 else o-0x10000
            t = (pc + 3 + so) & 0xFFFF
            operand = f"${t:04X}"; size = 3
        elif mode == 'long' or mode == 'long_x':
            v = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF] << 8) | (ROM[(pc+3)&0xFFFF] << 16)
            suffix = ',X' if mode == 'long_x' else ''
            operand = f"${v:06X}{suffix}"; size = 4
        elif mode == 'mvn':
            dst = ROM[(pc+1)&0xFFFF]; src = ROM[(pc+2)&0xFFFF]
            operand = f"#${dst:02X},#${src:02X}"; size = 3
        elif mode == 'dpi_long':
            v = ROM[(pc+1)&0xFFFF]; operand = f"[${v:02X}]"; size = 2
        elif mode == 'dpi_long_y':
            v = ROM[(pc+1)&0xFFFF]; operand = f"[${v:02X}],Y"; size = 2
        elif mode == 'dpi':
            v = ROM[(pc+1)&0xFFFF]; operand = f"(${v:02X})"; size = 2
        elif mode == 'dpi_x':
            v = ROM[(pc+1)&0xFFFF]; operand = f"(${v:02X},X)"; size = 2
        elif mode == 'dpi_y':
            v = ROM[(pc+1)&0xFFFF]; operand = f"(${v:02X}),Y"; size = 2
        elif mode == 'sr':
            v = ROM[(pc+1)&0xFFFF]; operand = f"${v:02X},S"; size = 2
        elif mode == 'ind':
            v = ROM[(pc+1)&0xFFFF] | (ROM[(pc+2)&0xFFFF] << 8)
            operand = f"(${v:04X})"; size = 3

        # Print bytes
        bytes_str = ' '.join(f'{ROM[(pc+i)&0xFFFF]:02X}' for i in range(size))
        flags = f"m{8 if m8 else 16}x{8 if x8 else 16}"
        out.append(f"  ${pc:04X}: {bytes_str:<12}  {mn:<5} {operand:<20} ; {flags}")
        pc = (pc + size) & 0xFFFF
        if mn in ('RTL','RTS','RTI','JML','BRA','BRL') and not operand.startswith('$'):
            break
        if mn in ('JML','BRA','BRL'):
            # don't follow, just stop at unconditional jumps
            pass
    return out

# Disassemble kickstart entry $80C1
print("=== Kickstart entry $F8:$80C1 (assume emu mode at entry) ===")
print('\n'.join(disasm(0x80C1, m8=True, x8=True, n=60)))
print()
print("=== Reset stub at $F8:$00FC ===")
print('\n'.join(disasm(0x00FC, m8=True, x8=True, n=4)))
print()
print("=== Bank-0 EPROM at $00:$FC90 ===")
# scpu64.mif is the BANK-0 image? Or BANK-F8? Let me check both.
# Actually, since RESET vec was at $00:$FFFC = $90 $FC, the EPROM at offset 0xFFFC must contain $90 $FC
print("FFFC:", f"{ROM[0xFFFC]:02X} {ROM[0xFFFD]:02X}")
print("FFFA:", f"{ROM[0xFFFA]:02X} {ROM[0xFFFB]:02X}  (NMI)")
print("FFFE:", f"{ROM[0xFFFE]:02X} {ROM[0xFFFF]:02X}  (BRK/IRQ emu)")
print()
print("=== $FC90 (reset entry) ===")
print('\n'.join(disasm(0xFC90, m8=True, x8=True, n=4)))
print()
print("=== $0314 in EPROM (would be RAM normally) ===")
print(f"ROM[$0314..$0317] = {ROM[0x0314]:02X} {ROM[0x0315]:02X} {ROM[0x0316]:02X} {ROM[0x0317]:02X}")
