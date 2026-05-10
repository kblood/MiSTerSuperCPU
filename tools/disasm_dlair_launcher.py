#!/usr/bin/env python3
"""Disassemble dlair64ld.prg launcher starting from $080D (BASIC SYS entry)
through $13B3 (relocator JMP target) and follow control flow.

Output marks any byte that maps to a 65C816-emu-mode-divergent NMOS opcode
so we can spot where DL relies on undocumented behavior.
"""
import sys

# 6502 / NMOS opcode table — instruction byte => (mnemonic, mode, bytes)
# Mode codes: imp=implied, imm=immediate, zp=zeropage, zpx=zp,x, zpy=zp,y,
# izx=(zp,x), izy=(zp),y, abs=absolute, abx=abs,x, aby=abs,y,
# ind=(abs), rel=relative
OP = {}
def _add(byt, mnem, mode, n):
    OP[byt] = (mnem, mode, n)

# Standard 6502
_add(0x00,"BRK","imp",1); _add(0x01,"ORA","izx",2); _add(0x05,"ORA","zp",2)
_add(0x06,"ASL","zp",2); _add(0x08,"PHP","imp",1); _add(0x09,"ORA","imm",2)
_add(0x0A,"ASL","imp",1); _add(0x0D,"ORA","abs",3); _add(0x0E,"ASL","abs",3)
_add(0x10,"BPL","rel",2); _add(0x11,"ORA","izy",2); _add(0x15,"ORA","zpx",2)
_add(0x16,"ASL","zpx",2); _add(0x18,"CLC","imp",1); _add(0x19,"ORA","aby",3)
_add(0x1D,"ORA","abx",3); _add(0x1E,"ASL","abx",3)
_add(0x20,"JSR","abs",3); _add(0x21,"AND","izx",2); _add(0x24,"BIT","zp",2)
_add(0x25,"AND","zp",2); _add(0x26,"ROL","zp",2); _add(0x28,"PLP","imp",1)
_add(0x29,"AND","imm",2); _add(0x2A,"ROL","imp",1); _add(0x2C,"BIT","abs",3)
_add(0x2D,"AND","abs",3); _add(0x2E,"ROL","abs",3)
_add(0x30,"BMI","rel",2); _add(0x31,"AND","izy",2); _add(0x35,"AND","zpx",2)
_add(0x36,"ROL","zpx",2); _add(0x38,"SEC","imp",1); _add(0x39,"AND","aby",3)
_add(0x3D,"AND","abx",3); _add(0x3E,"ROL","abx",3)
_add(0x40,"RTI","imp",1); _add(0x41,"EOR","izx",2); _add(0x45,"EOR","zp",2)
_add(0x46,"LSR","zp",2); _add(0x48,"PHA","imp",1); _add(0x49,"EOR","imm",2)
_add(0x4A,"LSR","imp",1); _add(0x4C,"JMP","abs",3); _add(0x4D,"EOR","abs",3)
_add(0x4E,"LSR","abs",3); _add(0x50,"BVC","rel",2); _add(0x51,"EOR","izy",2)
_add(0x55,"EOR","zpx",2); _add(0x56,"LSR","zpx",2); _add(0x58,"CLI","imp",1)
_add(0x59,"EOR","aby",3); _add(0x5D,"EOR","abx",3); _add(0x5E,"LSR","abx",3)
_add(0x60,"RTS","imp",1); _add(0x61,"ADC","izx",2); _add(0x65,"ADC","zp",2)
_add(0x66,"ROR","zp",2); _add(0x68,"PLA","imp",1); _add(0x69,"ADC","imm",2)
_add(0x6A,"ROR","imp",1); _add(0x6C,"JMP","ind",3); _add(0x6D,"ADC","abs",3)
_add(0x6E,"ROR","abs",3); _add(0x70,"BVS","rel",2); _add(0x71,"ADC","izy",2)
_add(0x75,"ADC","zpx",2); _add(0x76,"ROR","zpx",2); _add(0x78,"SEI","imp",1)
_add(0x79,"ADC","aby",3); _add(0x7D,"ADC","abx",3); _add(0x7E,"ROR","abx",3)
_add(0x81,"STA","izx",2); _add(0x84,"STY","zp",2); _add(0x85,"STA","zp",2)
_add(0x86,"STX","zp",2); _add(0x88,"DEY","imp",1); _add(0x8A,"TXA","imp",1)
_add(0x8C,"STY","abs",3); _add(0x8D,"STA","abs",3); _add(0x8E,"STX","abs",3)
_add(0x90,"BCC","rel",2); _add(0x91,"STA","izy",2); _add(0x94,"STY","zpx",2)
_add(0x95,"STA","zpx",2); _add(0x96,"STX","zpy",2); _add(0x98,"TYA","imp",1)
_add(0x99,"STA","aby",3); _add(0x9A,"TXS","imp",1); _add(0x9D,"STA","abx",3)
_add(0xA0,"LDY","imm",2); _add(0xA1,"LDA","izx",2); _add(0xA2,"LDX","imm",2)
_add(0xA4,"LDY","zp",2); _add(0xA5,"LDA","zp",2); _add(0xA6,"LDX","zp",2)
_add(0xA8,"TAY","imp",1); _add(0xA9,"LDA","imm",2); _add(0xAA,"TAX","imp",1)
_add(0xAC,"LDY","abs",3); _add(0xAD,"LDA","abs",3); _add(0xAE,"LDX","abs",3)
_add(0xB0,"BCS","rel",2); _add(0xB1,"LDA","izy",2); _add(0xB4,"LDY","zpx",2)
_add(0xB5,"LDA","zpx",2); _add(0xB6,"LDX","zpy",2); _add(0xB8,"CLV","imp",1)
_add(0xB9,"LDA","aby",3); _add(0xBA,"TSX","imp",1); _add(0xBC,"LDY","abx",3)
_add(0xBD,"LDA","abx",3); _add(0xBE,"LDX","aby",3); _add(0xC0,"CPY","imm",2)
_add(0xC1,"CMP","izx",2); _add(0xC4,"CPY","zp",2); _add(0xC5,"CMP","zp",2)
_add(0xC6,"DEC","zp",2); _add(0xC8,"INY","imp",1); _add(0xC9,"CMP","imm",2)
_add(0xCA,"DEX","imp",1); _add(0xCC,"CPY","abs",3); _add(0xCD,"CMP","abs",3)
_add(0xCE,"DEC","abs",3); _add(0xD0,"BNE","rel",2); _add(0xD1,"CMP","izy",2)
_add(0xD5,"CMP","zpx",2); _add(0xD6,"DEC","zpx",2); _add(0xD8,"CLD","imp",1)
_add(0xD9,"CMP","aby",3); _add(0xDD,"CMP","abx",3); _add(0xDE,"DEC","abx",3)
_add(0xE0,"CPX","imm",2); _add(0xE1,"SBC","izx",2); _add(0xE4,"CPX","zp",2)
_add(0xE5,"SBC","zp",2); _add(0xE6,"INC","zp",2); _add(0xE8,"INX","imp",1)
_add(0xE9,"SBC","imm",2); _add(0xEA,"NOP","imp",1); _add(0xEC,"CPX","abs",3)
_add(0xED,"SBC","abs",3); _add(0xEE,"INC","abs",3); _add(0xF0,"BEQ","rel",2)
_add(0xF1,"SBC","izy",2); _add(0xF5,"SBC","zpx",2); _add(0xF6,"INC","zpx",2)
_add(0xF8,"SED","imp",1); _add(0xF9,"SBC","aby",3); _add(0xFD,"SBC","abx",3)
_add(0xFE,"INC","abx",3)

# Mark divergent (NMOS undoc -> 65C816 valid)
# Comprehensive set from W65C816 datasheet
DIVERGENT = {
    0x02,0x03,0x04,0x07,0x0B,0x0C,0x0F,
    0x12,0x13,0x14,0x17,0x1A,0x1B,0x1C,0x1F,
    0x22,0x23,0x27,0x2B,0x2F,
    0x32,0x33,0x34,0x37,0x3A,0x3B,0x3C,0x3F,
    0x42,0x43,0x44,0x47,0x4B,0x4F,
    0x52,0x53,0x54,0x57,0x5A,0x5B,0x5C,0x5F,
    0x62,0x63,0x64,0x67,0x6B,0x6F,
    0x72,0x73,0x74,0x77,0x7A,0x7B,0x7C,0x7F,
    0x80,0x82,0x83,0x87,0x89,0x8B,0x8F,
    0x92,0x93,0x97,0x9B,0x9C,0x9E,0x9F,
    0xA3,0xA7,0xAB,0xAF,
    0xB2,0xB3,0xB7,0xBB,0xBF,
    0xC2,0xC3,0xC7,0xCB,0xCF,
    0xD2,0xD3,0xD4,0xD7,0xDA,0xDB,0xDC,0xDF,
    0xE2,0xE3,0xE7,0xEB,0xEF,
    0xF2,0xF3,0xF4,0xF7,0xFA,0xFB,0xFC,0xFF,
}

def disasm(mem, base_addr, start_addr, end_addr):
    """Linear disassemble from start_addr through end_addr."""
    pc = start_addr
    while pc < end_addr:
        off = pc - base_addr
        if off < 0 or off >= len(mem):
            break
        opc = mem[off]
        if opc not in OP:
            n = 1
            mnem, mode = "???", "imp"
        else:
            mnem, mode, n = OP[opc]
        bytes_ = mem[off:off+n]
        operand = ""
        if n == 2:
            v = mem[off+1] if off+1 < len(mem) else 0
            if mode == "imm": operand = f"#${v:02X}"
            elif mode == "zp":  operand = f"${v:02X}"
            elif mode == "zpx": operand = f"${v:02X},X"
            elif mode == "zpy": operand = f"${v:02X},Y"
            elif mode == "izx": operand = f"(${v:02X},X)"
            elif mode == "izy": operand = f"(${v:02X}),Y"
            elif mode == "rel":
                if v & 0x80: v = v - 256
                tgt = pc + 2 + v
                operand = f"${tgt:04X}"
        elif n == 3:
            lo = mem[off+1] if off+1 < len(mem) else 0
            hi = mem[off+2] if off+2 < len(mem) else 0
            addr = lo | (hi << 8)
            if mode == "abs": operand = f"${addr:04X}"
            elif mode == "abx": operand = f"${addr:04X},X"
            elif mode == "aby": operand = f"${addr:04X},Y"
            elif mode == "ind": operand = f"(${addr:04X})"
        marker = " *DIV*" if opc in DIVERGENT else ""
        bs = " ".join(f"{b:02X}" for b in bytes_)
        print(f"  ${pc:04X}: {bs:10} {mnem} {operand}{marker}")
        pc += n
    return pc

if __name__ == "__main__":
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    load = data[0] | (data[1] << 8)
    mem = data[2:]
    base = load
    print(f"Load address: ${load:04X}")
    print()
    # SYS 49152 in BASIC stub jumps to $C000? Wait, dlair64ld stub is SYS 2061 which is $080D.
    # Disassemble the BASIC stub area:
    # First find SYS target by reading the BASIC line
    print("=== BASIC stub at $0801 ===")
    print("  raw:", " ".join(f"{b:02X}" for b in mem[0:14]))
    print()
    print("=== Launcher at $080D ===")
    pc = disasm(mem, base, 0x080D, 0x081A)
    print()
    print("=== JMP target at $13B3 (followed for 64 bytes) ===")
    disasm(mem, base, 0x13B3, 0x13B3 + 64)
    print()
    print("=== Region at $13EE (relocator source) ===")
    disasm(mem, base, 0x13EE, 0x13EE + 64)
