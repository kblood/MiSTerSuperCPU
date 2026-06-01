#!/usr/bin/env python3
"""Minimal 6502/65C816 disassembler for the SCPU-Kicks depack analysis.
Defaults to 8-bit M/X. Usage: disasm.py <file> <start_hex> <count> [--m16] [--x16]
File is a PRG-style dump (first 2 bytes = load addr)."""
import sys

# opcode table: mnemonic, addressing mode
# modes: imp, imm, immM, immX, zp, zpx, zpy, abs, abx, aby, ind, izx, izy,
#        rel, rell(16-bit BRL), absl(24), ablx, indl(izy long [d]), al, stk, sr, sry, bm(block move)
OPS = {
0x00:('BRK','imp'),0x01:('ORA','izx'),0x02:('COP','imm'),0x03:('ORA','sr'),
0x04:('TSB','zp'),0x05:('ORA','zp'),0x06:('ASL','zp'),0x07:('ORA','indl'),
0x08:('PHP','imp'),0x09:('ORA','immM'),0x0A:('ASL','imp'),0x0B:('PHD','imp'),
0x0C:('TSB','abs'),0x0D:('ORA','abs'),0x0E:('ASL','abs'),0x0F:('ORA','absl'),
0x10:('BPL','rel'),0x11:('ORA','izy'),0x12:('ORA','ind'),0x13:('ORA','sry'),
0x14:('TRB','zp'),0x15:('ORA','zpx'),0x16:('ASL','zpx'),0x17:('ORA','indly'),
0x18:('CLC','imp'),0x19:('ORA','aby'),0x1A:('INC','imp'),0x1B:('TCS','imp'),
0x1C:('TRB','abs'),0x1D:('ORA','abx'),0x1E:('ASL','abx'),0x1F:('ORA','ablx'),
0x20:('JSR','abs'),0x21:('AND','izx'),0x22:('JSL','absl'),0x23:('AND','sr'),
0x24:('BIT','zp'),0x25:('AND','zp'),0x26:('ROL','zp'),0x27:('AND','indl'),
0x28:('PLP','imp'),0x29:('AND','immM'),0x2A:('ROL','imp'),0x2B:('PLD','imp'),
0x2C:('BIT','abs'),0x2D:('AND','abs'),0x2E:('ROL','abs'),0x2F:('AND','absl'),
0x30:('BMI','rel'),0x31:('AND','izy'),0x32:('AND','ind'),0x33:('AND','sry'),
0x34:('BIT','zpx'),0x35:('AND','zpx'),0x36:('ROL','zpx'),0x37:('AND','indly'),
0x38:('SEC','imp'),0x39:('AND','aby'),0x3A:('DEC','imp'),0x3B:('TSC','imp'),
0x3C:('BIT','abx'),0x3D:('AND','abx'),0x3E:('ROL','abx'),0x3F:('AND','ablx'),
0x40:('RTI','imp'),0x41:('EOR','izx'),0x42:('WDM','imm'),0x43:('EOR','sr'),
0x44:('MVP','bm'),0x45:('EOR','zp'),0x46:('LSR','zp'),0x47:('EOR','indl'),
0x48:('PHA','imp'),0x49:('EOR','immM'),0x4A:('LSR','imp'),0x4B:('PHK','imp'),
0x4C:('JMP','abs'),0x4D:('EOR','abs'),0x4E:('LSR','abs'),0x4F:('EOR','absl'),
0x50:('BVC','rel'),0x51:('EOR','izy'),0x52:('EOR','ind'),0x53:('EOR','sry'),
0x54:('MVN','bm'),0x55:('EOR','zpx'),0x56:('LSR','zpx'),0x57:('EOR','indly'),
0x58:('CLI','imp'),0x59:('EOR','aby'),0x5A:('PHY','imp'),0x5B:('TCD','imp'),
0x5C:('JML','absl'),0x5D:('EOR','abx'),0x5E:('LSR','abx'),0x5F:('EOR','ablx'),
0x60:('RTS','imp'),0x61:('ADC','izx'),0x62:('PER','rell'),0x63:('ADC','sr'),
0x64:('STZ','zp'),0x65:('ADC','zp'),0x66:('ROR','zp'),0x67:('ADC','indl'),
0x68:('PLA','imp'),0x69:('ADC','immM'),0x6A:('ROR','imp'),0x6B:('RTL','imp'),
0x6C:('JMP','ind'),0x6D:('ADC','abs'),0x6E:('ROR','abs'),0x6F:('ADC','absl'),
0x70:('BVS','rel'),0x71:('ADC','izy'),0x72:('ADC','ind'),0x73:('ADC','sry'),
0x74:('STZ','zpx'),0x75:('ADC','zpx'),0x76:('ROR','zpx'),0x77:('ADC','indly'),
0x78:('SEI','imp'),0x79:('ADC','aby'),0x7A:('PLY','imp'),0x7B:('TDC','imp'),
0x7C:('JMP','iabx'),0x7D:('ADC','abx'),0x7E:('ROR','abx'),0x7F:('ADC','ablx'),
0x80:('BRA','rel'),0x81:('STA','izx'),0x82:('BRL','rell'),0x83:('STA','sr'),
0x84:('STY','zp'),0x85:('STA','zp'),0x86:('STX','zp'),0x87:('STA','indl'),
0x88:('DEY','imp'),0x89:('BIT','immM'),0x8A:('TXA','imp'),0x8B:('PHB','imp'),
0x8C:('STY','abs'),0x8D:('STA','abs'),0x8E:('STX','abs'),0x8F:('STA','absl'),
0x90:('BCC','rel'),0x91:('STA','izy'),0x92:('STA','ind'),0x93:('STA','sry'),
0x94:('STY','zpx'),0x95:('STA','zpx'),0x96:('STX','zpy'),0x97:('STA','indly'),
0x98:('TYA','imp'),0x99:('STA','aby'),0x9A:('TXS','imp'),0x9B:('TXY','imp'),
0x9C:('STZ','abs'),0x9D:('STA','abx'),0x9E:('STZ','abx'),0x9F:('STA','ablx'),
0xA0:('LDY','immX'),0xA1:('LDA','izx'),0xA2:('LDX','immX'),0xA3:('LDA','sr'),
0xA4:('LDY','zp'),0xA5:('LDA','zp'),0xA6:('LDX','zp'),0xA7:('LDA','indl'),
0xA8:('TAY','imp'),0xA9:('LDA','immM'),0xAA:('TAX','imp'),0xAB:('PLB','imp'),
0xAC:('LDY','abs'),0xAD:('LDA','abs'),0xAE:('LDX','abs'),0xAF:('LDA','absl'),
0xB0:('BCS','rel'),0xB1:('LDA','izy'),0xB2:('LDA','ind'),0xB3:('LDA','sry'),
0xB4:('LDY','zpx'),0xB5:('LDA','zpx'),0xB6:('LDX','zpy'),0xB7:('LDA','indly'),
0xB8:('CLV','imp'),0xB9:('LDA','aby'),0xBA:('TSX','imp'),0xBB:('TYX','imp'),
0xBC:('LDY','abx'),0xBD:('LDA','abx'),0xBE:('LDX','aby'),0xBF:('LDA','ablx'),
0xC0:('CPY','immX'),0xC1:('CMP','izx'),0xC2:('REP','imm'),0xC3:('CMP','sr'),
0xC4:('CPY','zp'),0xC5:('CMP','zp'),0xC6:('DEC','zp'),0xC7:('CMP','indl'),
0xC8:('INY','imp'),0xC9:('CMP','immM'),0xCA:('DEX','imp'),0xCB:('WAI','imp'),
0xCC:('CPY','abs'),0xCD:('CMP','abs'),0xCE:('DEC','abs'),0xCF:('CMP','absl'),
0xD0:('BNE','rel'),0xD1:('CMP','izy'),0xD2:('CMP','ind'),0xD3:('CMP','sry'),
0xD4:('PEI','zp'),0xD5:('CMP','zpx'),0xD6:('DEC','zpx'),0xD7:('CMP','indly'),
0xD8:('CLD','imp'),0xD9:('CMP','aby'),0xDA:('PHX','imp'),0xDB:('STP','imp'),
0xDC:('JML','ind'),0xDD:('CMP','abx'),0xDE:('DEC','abx'),0xDF:('CMP','ablx'),
0xE0:('CPX','immX'),0xE1:('SBC','izx'),0xE2:('SEP','imm'),0xE3:('SBC','sr'),
0xE4:('CPX','zp'),0xE5:('SBC','zp'),0xE6:('INC','zp'),0xE7:('SBC','indl'),
0xE8:('INX','imp'),0xE9:('SBC','immM'),0xEA:('NOP','imp'),0xEB:('XBA','imp'),
0xEC:('CPX','abs'),0xED:('SBC','abs'),0xEE:('INC','abs'),0xEF:('SBC','absl'),
0xF0:('BEQ','rel'),0xF1:('SBC','izy'),0xF2:('SBC','ind'),0xF3:('SBC','sry'),
0xF4:('PEA','abs'),0xF5:('SBC','zpx'),0xF6:('INC','zpx'),0xF7:('SBC','indly'),
0xF8:('SED','imp'),0xF9:('SBC','aby'),0xFA:('PLX','imp'),0xFB:('XCE','imp'),
0xFC:('JSR','iabx'),0xFD:('SBC','abx'),0xFE:('INC','abx'),0xFF:('SBC','ablx'),
}

def main():
    fn=sys.argv[1]; start=int(sys.argv[2],16); count=int(sys.argv[3])
    m16='--m16' in sys.argv; x16='--x16' in sys.argv
    data=open(fn,'rb').read(); load=data[0]|(data[1]<<8); body=data[2:]
    pc=start
    n=0
    while n<count:
        off=pc-load
        if off<0 or off>=len(body): break
        op=body[off]; mn,mode=OPS.get(op,('???','imp'))
        # operand sizing
        if mode=='immM': sz=2 if m16 else 1
        elif mode=='immX': sz=2 if x16 else 1
        elif mode in('imm',): sz=1
        elif mode in('zp','zpx','zpy','izx','izy','ind','indl','indly','sr','sry','rel'): sz=1
        elif mode in('abs','abx','aby','iabx','rell','bm'): sz=2
        elif mode in('absl','ablx'): sz=3
        else: sz=0
        ops=body[off+1:off+1+sz]
        b=' '.join('%02X'%x for x in body[off:off+1+sz])
        # format operand
        def w(): return ops[0]|(ops[1]<<8) if sz>=2 else ops[0]
        txt=''
        if mode=='imp': txt=''
        elif mode in('imm','immM','immX'): txt='#$%02X'%ops[0] if sz==1 else '#$%04X'%w()
        elif mode=='zp': txt='$%02X'%ops[0]
        elif mode=='zpx': txt='$%02X,X'%ops[0]
        elif mode=='zpy': txt='$%02X,Y'%ops[0]
        elif mode=='izx': txt='($%02X,X)'%ops[0]
        elif mode=='izy': txt='($%02X),Y'%ops[0]
        elif mode=='ind': txt='($%02X)'%ops[0]
        elif mode=='indl': txt='[$%02X]'%ops[0]
        elif mode=='indly': txt='[$%02X],Y'%ops[0]
        elif mode=='sr': txt='$%02X,S'%ops[0]
        elif mode=='sry': txt='($%02X,S),Y'%ops[0]
        elif mode=='abs': txt='$%04X'%w()
        elif mode=='abx': txt='$%04X,X'%w()
        elif mode=='aby': txt='$%04X,Y'%w()
        elif mode=='iabx': txt='($%04X,X)'%w()
        elif mode=='absl': txt='$%06X'%(ops[0]|(ops[1]<<8)|(ops[2]<<16))
        elif mode=='ablx': txt='$%06X,X'%(ops[0]|(ops[1]<<8)|(ops[2]<<16))
        elif mode=='rel':
            d=ops[0]; d=d-256 if d>127 else d; txt='$%04X'%((pc+2+d)&0xFFFF)
        elif mode=='rell':
            d=w(); d=d-65536 if d>32767 else d; txt='$%04X'%((pc+3+d)&0xFFFF)
        elif mode=='bm': txt='$%02X,$%02X'%(ops[1],ops[0])
        print('$%04X: %-10s %s %s'%(pc,b,mn,txt))
        pc+=1+sz; n+=1

main()
