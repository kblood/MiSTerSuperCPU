import re, sys

rom = bytearray(65536)
with open('C64_MiSTer/rtl/roms/scpu64.mif', 'r') as f:
    content = f.read()
m = re.search(r'CONTENT BEGIN(.*?)END;', content, re.DOTALL)
for line in m.group(1).strip().split('\n'):
    line = line.strip().rstrip(';')
    if ':' in line:
        parts = line.split(':')
        try:
            addr = int(parts[0].strip(), 16)
            data = int(parts[1].strip(), 16)
            if 0 <= addr < 65536:
                rom[addr] = data
        except:
            pass

def dis(addr, n=100):
    i = addr
    out = []
    while i < 0x10000 and len(out) < n:
        op = rom[i]
        base = '$%04X: %02X' % (i, op)
        if op == 0xE2:
            out.append('%s %02X    SEP #$%02X' % (base, rom[i+1], rom[i+1])); i+=2
        elif op == 0xC2:
            out.append('%s %02X    REP #$%02X' % (base, rom[i+1], rom[i+1])); i+=2
        elif op == 0x4C:
            out.append('%s %02X%02X  JMP $%04X' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0x5C:
            out.append('%s %02X%02X%02X JML $%02X:%04X' % (base,rom[i+1],rom[i+2],rom[i+3],rom[i+3],rom[i+1]|(rom[i+2]<<8))); i+=4
        elif op == 0x20:
            out.append('%s %02X%02X  JSR $%04X' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0x22:
            out.append('%s %02X%02X%02X JSL $%02X:%04X' % (base,rom[i+1],rom[i+2],rom[i+3],rom[i+3],rom[i+1]|(rom[i+2]<<8))); i+=4
        elif op == 0x54:
            out.append('%s %02X%02X  MVN dst=$%02X src=$%02X' % (base,rom[i+1],rom[i+2],rom[i+1],rom[i+2])); i+=3
        elif op == 0x44:
            out.append('%s %02X%02X  MVP dst=$%02X src=$%02X' % (base,rom[i+1],rom[i+2],rom[i+1],rom[i+2])); i+=3
        elif op in (0xA9, 0xA0, 0xA2, 0xC9, 0xE0, 0xC0, 0x09, 0x29, 0x49, 0x69, 0xE9):
            out.append('%s %02X    %s #$%02X' % (base, rom[i+1],
                {0xA9:'LDA',0xA0:'LDY',0xA2:'LDX',0xC9:'CMP',0xE0:'CPX',
                 0xC0:'CPY',0x09:'ORA',0x29:'AND',0x49:'EOR',0x69:'ADC',0xE9:'SBC'}[op], rom[i+1])); i+=2
        elif op == 0xA5:
            out.append('%s %02X    LDA $%02X' % (base, rom[i+1], rom[i+1])); i+=2
        elif op == 0xAD:
            out.append('%s %02X%02X  LDA $%04X' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0xAF:
            out.append('%s %02X%02X%02X LDA $%02X:%04X' % (base,rom[i+1],rom[i+2],rom[i+3],rom[i+3],rom[i+1]|(rom[i+2]<<8))); i+=4
        elif op == 0x85:
            out.append('%s %02X    STA $%02X' % (base, rom[i+1], rom[i+1])); i+=2
        elif op == 0x8D:
            out.append('%s %02X%02X  STA $%04X' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0x8F:
            out.append('%s %02X%02X%02X STA $%02X:%04X' % (base,rom[i+1],rom[i+2],rom[i+3],rom[i+3],rom[i+1]|(rom[i+2]<<8))); i+=4
        elif op == 0x9D:
            out.append('%s %02X%02X  STA $%04X,X' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0x99:
            out.append('%s %02X%02X  STA $%04X,Y' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0xBD:
            out.append('%s %02X%02X  LDA $%04X,X' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0xB9:
            out.append('%s %02X%02X  LDA $%04X,Y' % (base, rom[i+1], rom[i+2], rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op in (0xA6,0xA4):
            out.append('%s %02X    %s $%02X' % (base, rom[i+1], {0xA6:'LDX',0xA4:'LDY'}[op], rom[i+1])); i+=2
        elif op in (0xAE, 0xAC, 0x8E, 0x8C, 0x2C, 0x0D, 0x2D, 0x4D):
            n2 = {0xAE:'LDX',0xAC:'LDY',0x8E:'STX',0x8C:'STY',0x2C:'BIT',0x0D:'ORA',0x2D:'AND',0x4D:'EOR'}[op]
            out.append('%s %02X%02X  %s $%04X' % (base, rom[i+1], rom[i+2], n2, rom[i+1]|(rom[i+2]<<8))); i+=3
        elif op == 0xE2:
            out.append('%s %02X    SEP #$%02X' % (base, rom[i+1], rom[i+1])); i+=2
        elif op in (0xF0,0xD0,0x90,0xB0,0x10,0x30,0x50,0x70,0x80):
            rel = rom[i+1]; rel = rel-256 if rel>=128 else rel
            mn = {0xF0:'BEQ',0xD0:'BNE',0x90:'BCC',0xB0:'BCS',0x10:'BPL',
                  0x30:'BMI',0x50:'BVC',0x70:'BVS',0x80:'BRA'}[op]
            out.append('%s %02X    %s $%04X' % (base, rom[i+1], mn, (i+2+rel)&0xFFFF)); i+=2
        elif op == 0x82:
            rel = rom[i+1]|(rom[i+2]<<8); rel=rel-65536 if rel>=32768 else rel
            out.append('%s %02X%02X  BRL $%04X' % (base,rom[i+1],rom[i+2],(i+3+rel)&0xFFFF)); i+=3
        elif op in (0x1A,0x3A,0xE8,0xC8,0xCA,0x88):
            out.append('%s       %s' % (base, {0x1A:'INA',0x3A:'DEA',0xE8:'INX',0xC8:'INY',0xCA:'DEX',0x88:'DEY'}[op])); i+=1
        elif op in {0x00:'BRK',0x18:'CLC',0x38:'SEC',0x58:'CLI',0x78:'SEI',
                    0x08:'PHP',0x28:'PLP',0x48:'PHA',0x68:'PLA',0xDA:'PHX',0xFA:'PLX',
                    0x5A:'PHY',0x7A:'PLY',0xAA:'TAX',0xA8:'TAY',0x8A:'TXA',0x98:'TYA',
                    0x9A:'TXS',0xBA:'TSX',0xEB:'XBA',0x1B:'TCS',0x3B:'TSC',
                    0x5B:'TCD',0x7B:'TDC',0xFB:'XCE',0x4B:'PHK',0x8B:'PHB',
                    0xAB:'PLB',0xDB:'STP',0xCB:'WAI',0x60:'RTS',0x6B:'RTL',
                    0x40:'RTI',0xEA:'NOP'}:
            out.append('%s       %s' % (base, {0x00:'BRK',0x18:'CLC',0x38:'SEC',0x58:'CLI',0x78:'SEI',
                    0x08:'PHP',0x28:'PLP',0x48:'PHA',0x68:'PLA',0xDA:'PHX',0xFA:'PLX',
                    0x5A:'PHY',0x7A:'PLY',0xAA:'TAX',0xA8:'TAY',0x8A:'TXA',0x98:'TYA',
                    0x9A:'TXS',0xBA:'TSX',0xEB:'XBA',0x1B:'TCS',0x3B:'TSC',
                    0x5B:'TCD',0x7B:'TDC',0xFB:'XCE',0x4B:'PHK',0x8B:'PHB',
                    0xAB:'PLB',0xDB:'STP',0xCB:'WAI',0x60:'RTS',0x6B:'RTL',
                    0x40:'RTI',0xEA:'NOP'}[op])); i+=1
        else:
            out.append('%s       ??? (%02X)' % (base, op)); i+=1
    return out

start = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x80C1
count = int(sys.argv[2]) if len(sys.argv) > 2 else 80
print("=== Disassembly from $%04X ===" % start)
for l in dis(start, count):
    print(l)
