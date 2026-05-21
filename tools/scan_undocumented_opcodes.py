#!/usr/bin/env python3
"""Scan a PRG/binary for opcodes whose meaning differs between NMOS 6502
(what T65 implements) and 65C816 emulation mode (what P65C816 implements).

NMOS undocumented opcodes (KIL, SLO, RLA, SRE, RRA, SAX, AHX, LAX, DCP, ISC,
NOP-undocs, ASR/ARR/ANE/SBX) are redefined by 65C816 as legitimate
instructions (ORA s,r, AND s,r, MVN, MVP, COP, etc.)

If a program relies on NMOS undocumented behavior, the 65C816 emu-mode
interpretation will diverge.

This list is the opcode bytes whose semantics differ between NMOS 6502
and 65C816 emu-mode. Hits in a program suggest a likely culprit for
T65-vs-P65C816 divergence.

Reference: http://www.6502.org/tutorials/65c816opcodes.html
"""
import sys

# Bytes where NMOS does undocumented/unique thing and 65C816 does
# something else. Includes NOP variants and "kill" bytes that became
# legit on 65C816.
# Conservative list — every byte the W65C816 datasheet defines as a
# different mnemonic from MOS 6502 NMOS undocumented behavior.
DIVERGENT = {
    # NMOS KIL/JAM bytes -> 65C816 various
    0x02: "NMOS:KIL    65C816:COP #imm",
    0x03: "NMOS:SLO    65C816:ORA dp,s",
    0x04: "NMOS:NOP zp 65C816:TSB zp",
    0x07: "NMOS:SLO zp 65C816:ORA [dp]",
    0x0B: "NMOS:ANC#   65C816:PHD",
    0x0C: "NMOS:NOPabs 65C816:TSB abs",
    0x0F: "NMOS:SLO abs 65C816:ORA long",
    0x12: "NMOS:KIL    65C816:ORA (dp)",
    0x13: "NMOS:SLO    65C816:ORA (dp,s),y",
    0x14: "NMOS:NOPzpx 65C816:TRB zp",
    0x17: "NMOS:SLO    65C816:ORA [dp],y",
    0x1A: "NMOS:NOP    65C816:INC A",
    0x1B: "NMOS:SLO    65C816:TCS",
    0x1C: "NMOS:NOPabs 65C816:TRB abs",
    0x1F: "NMOS:SLO    65C816:ORA long,x",
    0x22: "NMOS:KIL    65C816:JSR long",
    0x23: "NMOS:RLA    65C816:AND dp,s",
    0x27: "NMOS:RLA    65C816:AND [dp]",
    0x2B: "NMOS:ANC#   65C816:PLD",
    0x2F: "NMOS:RLA    65C816:AND long",
    0x32: "NMOS:KIL    65C816:AND (dp)",
    0x33: "NMOS:RLA    65C816:AND (dp,s),y",
    0x34: "NMOS:NOPzpx 65C816:BIT zp,x",
    0x37: "NMOS:RLA    65C816:AND [dp],y",
    0x3A: "NMOS:NOP    65C816:DEC A",
    0x3B: "NMOS:RLA    65C816:TSC",
    0x3C: "NMOS:NOPabs 65C816:BIT abs,x",
    0x3F: "NMOS:RLA    65C816:AND long,x",
    0x42: "NMOS:KIL    65C816:WDM",
    0x43: "NMOS:SRE    65C816:EOR dp,s",
    0x44: "NMOS:NOPzpx 65C816:MVP src,dst",
    0x47: "NMOS:SRE    65C816:EOR [dp]",
    0x4B: "NMOS:ASR#   65C816:PHK",
    0x4F: "NMOS:SRE abs 65C816:EOR long",
    0x52: "NMOS:KIL    65C816:EOR (dp)",
    0x53: "NMOS:SRE    65C816:EOR (dp,s),y",
    0x54: "NMOS:NOPzpx 65C816:MVN src,dst",
    0x57: "NMOS:SRE    65C816:EOR [dp],y",
    0x5A: "NMOS:NOP    65C816:PHY",
    0x5B: "NMOS:SRE    65C816:TCD",
    0x5C: "NMOS:NOPabs 65C816:JMP long",
    0x5F: "NMOS:SRE abs,x 65C816:EOR long,x",
    0x62: "NMOS:KIL    65C816:PER",
    0x63: "NMOS:RRA    65C816:ADC dp,s",
    0x64: "NMOS:NOPzp  65C816:STZ zp",
    0x67: "NMOS:RRA    65C816:ADC [dp]",
    0x6B: "NMOS:ARR#   65C816:RTL",
    0x6F: "NMOS:RRA abs 65C816:ADC long",
    0x72: "NMOS:KIL    65C816:ADC (dp)",
    0x73: "NMOS:RRA    65C816:ADC (dp,s),y",
    0x74: "NMOS:NOPzpx 65C816:STZ zp,x",
    0x77: "NMOS:RRA    65C816:ADC [dp],y",
    0x7A: "NMOS:NOP    65C816:PLY",
    0x7B: "NMOS:RRA    65C816:TDC",
    0x7C: "NMOS:NOPabs 65C816:JMP (abs,x)",
    0x7F: "NMOS:RRA abs,x 65C816:ADC long,x",
    0x80: "NMOS:NOP#   65C816:BRA rel",
    0x82: "NMOS:NOP#   65C816:BRL rel16",
    0x83: "NMOS:SAX    65C816:STA dp,s",
    0x87: "NMOS:SAX zp 65C816:STA [dp]",
    0x89: "NMOS:NOP#   65C816:BIT #imm",
    0x8B: "NMOS:ANE    65C816:PHB",
    0x8F: "NMOS:SAX abs 65C816:STA long",
    0x92: "NMOS:KIL    65C816:STA (dp)",
    0x93: "NMOS:AHX    65C816:STA (dp,s),y",
    0x97: "NMOS:SAX    65C816:STA [dp],y",
    0x9B: "NMOS:TAS    65C816:TXY",
    0x9C: "NMOS:SHY    65C816:STZ abs",
    0x9E: "NMOS:SHX    65C816:STZ abs,x",
    0x9F: "NMOS:AHX abs 65C816:STA long,x",
    0xA3: "NMOS:LAX    65C816:LDA dp,s",
    0xA7: "NMOS:LAX zp 65C816:LDA [dp]",
    0xAB: "NMOS:LAX#   65C816:PLB",
    0xAF: "NMOS:LAX abs 65C816:LDA long",
    0xB2: "NMOS:KIL    65C816:LDA (dp)",
    0xB3: "NMOS:LAX    65C816:LDA (dp,s),y",
    0xB7: "NMOS:LAX    65C816:LDA [dp],y",
    0xBB: "NMOS:LAS    65C816:TYX",
    0xBF: "NMOS:LAX abs,y 65C816:LDA long,x",
    0xC2: "NMOS:NOP#   65C816:REP #imm",
    0xC3: "NMOS:DCP    65C816:CMP dp,s",
    0xC7: "NMOS:DCP zp 65C816:CMP [dp]",
    0xCB: "NMOS:SBX    65C816:WAI",
    0xCF: "NMOS:DCP abs 65C816:CMP long",
    0xD2: "NMOS:KIL    65C816:CMP (dp)",
    0xD3: "NMOS:DCP    65C816:CMP (dp,s),y",
    0xD4: "NMOS:NOPzpx 65C816:PEI",
    0xD7: "NMOS:DCP    65C816:CMP [dp],y",
    0xDA: "NMOS:NOP    65C816:PHX",
    0xDB: "NMOS:DCP    65C816:STP",
    0xDC: "NMOS:NOPabs 65C816:JMP [abs]",
    0xDF: "NMOS:DCP abs,x 65C816:CMP long,x",
    0xE2: "NMOS:NOP#   65C816:SEP #imm",
    0xE3: "NMOS:ISC    65C816:SBC dp,s",
    0xE7: "NMOS:ISC zp 65C816:SBC [dp]",
    0xEB: "NMOS:NOP    65C816:SBC #imm (alt)",  # XBA on actual? double-check
    0xEF: "NMOS:ISC abs 65C816:SBC long",
    0xF2: "NMOS:KIL    65C816:SBC (dp)",
    0xF3: "NMOS:ISC    65C816:SBC (dp,s),y",
    0xF4: "NMOS:NOPzpx 65C816:PEA",
    0xF7: "NMOS:ISC    65C816:SBC [dp],y",
    0xFA: "NMOS:NOP    65C816:PLX",
    0xFB: "NMOS:ISC    65C816:XCE",
    0xFC: "NMOS:NOPabs 65C816:JSR (abs,x)",
    0xFF: "NMOS:ISC abs,x 65C816:SBC long,x",
}

def scan(path):
    with open(path, "rb") as f:
        data = f.read()
    # Strip 2-byte PRG load address
    if path.endswith(".prg") or path.endswith(".PRG"):
        load = data[0] | (data[1] << 8)
        body = data[2:]
        print(f"PRG load $: {load:04X}, body {len(body)} bytes")
    else:
        load = 0
        body = data

    # Just count bytes (without disassembling — many will be data, not code,
    # but high count of a divergent byte is still informative).
    counts = {}
    for b in body:
        if b in DIVERGENT:
            counts[b] = counts.get(b, 0) + 1
    if not counts:
        print("No divergent opcodes present in the binary.")
        return
    print("Divergent opcode bytes found (count, opcode, NMOS-vs-65C816 meaning):")
    for op, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  ${op:02X}  x{n:5d}  {DIVERGENT[op]}")

if __name__ == "__main__":
    for path in sys.argv[1:]:
        print(f"=== {path} ===")
        scan(path)
        print()
