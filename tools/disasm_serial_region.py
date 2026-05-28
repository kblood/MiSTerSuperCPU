#!/usr/bin/env python3
"""Minimal 6502 disassembler for the SCPU patched KERNAL serial region.

Loads tools/scpu64.bin (64KB SCPU EPROM). The $E000-$FFFF KERNAL image lives
at file offset $2100 (cpuAddr-$BF00). Disassembles requested CPU ranges so we
can inspect the original-Commodore serial send/handshake path that wedges in
65816 mode ($ED40 ISOUR, $EEA9 stable-read, $ED5A turnaround, $F3xx throttle
wrappers).
"""
import sys

BIN = "tools/scpu64.bin"
KERNAL_FILE_OFF = 0x2100   # file offset for cpu $E000
KERNAL_BASE = 0xE000

# 6502 opcode table: mnemonic, addressing-mode, length
OPS = {
    0x00: ("BRK", "imp", 1), 0x01: ("ORA", "izx", 2), 0x05: ("ORA", "zp", 2),
    0x06: ("ASL", "zp", 2), 0x08: ("PHP", "imp", 1), 0x09: ("ORA", "imm", 2),
    0x0A: ("ASL", "acc", 1), 0x0D: ("ORA", "abs", 3), 0x0E: ("ASL", "abs", 3),
    0x10: ("BPL", "rel", 2), 0x11: ("ORA", "izy", 2), 0x15: ("ORA", "zpx", 2),
    0x16: ("ASL", "zpx", 2), 0x18: ("CLC", "imp", 1), 0x19: ("ORA", "aby", 3),
    0x1D: ("ORA", "abx", 3), 0x1E: ("ASL", "abx", 3), 0x20: ("JSR", "abs", 3),
    0x21: ("AND", "izx", 2), 0x24: ("BIT", "zp", 2), 0x25: ("AND", "zp", 2),
    0x26: ("ROL", "zp", 2), 0x28: ("PLP", "imp", 1), 0x29: ("AND", "imm", 2),
    0x2A: ("ROL", "acc", 1), 0x2C: ("BIT", "abs", 3), 0x2D: ("AND", "abs", 3),
    0x2E: ("ROL", "abs", 3), 0x30: ("BMI", "rel", 2), 0x31: ("AND", "izy", 2),
    0x35: ("AND", "zpx", 2), 0x36: ("ROL", "zpx", 2), 0x38: ("SEC", "imp", 1),
    0x39: ("AND", "aby", 3), 0x3D: ("AND", "abx", 3), 0x3E: ("ROL", "abx", 3),
    0x40: ("RTI", "imp", 1), 0x41: ("EOR", "izx", 2), 0x45: ("EOR", "zp", 2),
    0x46: ("LSR", "zp", 2), 0x48: ("PHA", "imp", 1), 0x49: ("EOR", "imm", 2),
    0x4A: ("LSR", "acc", 1), 0x4C: ("JMP", "abs", 3), 0x4D: ("EOR", "abs", 3),
    0x4E: ("LSR", "abs", 3), 0x50: ("BVC", "rel", 2), 0x51: ("EOR", "izy", 2),
    0x55: ("EOR", "zpx", 2), 0x56: ("LSR", "zpx", 2), 0x58: ("CLI", "imp", 1),
    0x59: ("EOR", "aby", 3), 0x5D: ("EOR", "abx", 3), 0x5E: ("LSR", "abx", 3),
    0x60: ("RTS", "imp", 1), 0x61: ("ADC", "izx", 2), 0x65: ("ADC", "zp", 2),
    0x66: ("ROR", "zp", 2), 0x68: ("PLA", "imp", 1), 0x69: ("ADC", "imm", 2),
    0x6A: ("ROR", "acc", 1), 0x6C: ("JMP", "ind", 3), 0x6D: ("ADC", "abs", 3),
    0x6E: ("ROR", "abs", 3), 0x70: ("BVS", "rel", 2), 0x71: ("ADC", "izy", 2),
    0x75: ("ADC", "zpx", 2), 0x76: ("ROR", "zpx", 2), 0x78: ("SEI", "imp", 1),
    0x79: ("ADC", "aby", 3), 0x7D: ("ADC", "abx", 3), 0x7E: ("ROR", "abx", 3),
    0x81: ("STA", "izx", 2), 0x84: ("STY", "zp", 2), 0x85: ("STA", "zp", 2),
    0x86: ("STX", "zp", 2), 0x88: ("DEY", "imp", 1), 0x8A: ("TXA", "imp", 1),
    0x8C: ("STY", "abs", 3), 0x8D: ("STA", "abs", 3), 0x8E: ("STX", "abs", 3),
    0x90: ("BCC", "rel", 2), 0x91: ("STA", "izy", 2), 0x94: ("STY", "zpx", 2),
    0x95: ("STA", "zpx", 2), 0x96: ("STX", "zpy", 2), 0x98: ("TYA", "imp", 1),
    0x99: ("STA", "aby", 3), 0x9A: ("TXS", "imp", 1), 0x9D: ("STA", "abx", 3),
    0xA0: ("LDY", "imm", 2), 0xA1: ("LDA", "izx", 2), 0xA2: ("LDX", "imm", 2),
    0xA4: ("LDY", "zp", 2), 0xA5: ("LDA", "zp", 2), 0xA6: ("LDX", "zp", 2),
    0xA8: ("TAY", "imp", 1), 0xA9: ("LDA", "imm", 2), 0xAA: ("TAX", "imp", 1),
    0xAC: ("LDY", "abs", 3), 0xAD: ("LDA", "abs", 3), 0xAE: ("LDX", "abs", 3),
    0xB0: ("BCS", "rel", 2), 0xB1: ("LDA", "izy", 2), 0xB4: ("LDY", "zpx", 2),
    0xB5: ("LDA", "zpx", 2), 0xB6: ("LDX", "zpy", 2), 0xB8: ("CLV", "imp", 1),
    0xB9: ("LDA", "aby", 3), 0xBA: ("TSX", "imp", 1), 0xBC: ("LDY", "abx", 3),
    0xBD: ("LDA", "abx", 3), 0xBE: ("LDX", "aby", 3), 0xC0: ("CPY", "imm", 2),
    0xC1: ("CMP", "izx", 2), 0xC4: ("CPY", "zp", 2), 0xC5: ("CMP", "zp", 2),
    0xC6: ("DEC", "zp", 2), 0xC8: ("INY", "imp", 1), 0xC9: ("CMP", "imm", 2),
    0xCA: ("DEX", "imp", 1), 0xCC: ("CPY", "abs", 3), 0xCD: ("CMP", "abs", 3),
    0xCE: ("DEC", "abs", 3), 0xD0: ("BNE", "rel", 2), 0xD1: ("CMP", "izy", 2),
    0xD5: ("CMP", "zpx", 2), 0xD6: ("DEC", "zpx", 2), 0xD8: ("CLD", "imp", 1),
    0xD9: ("CMP", "aby", 3), 0xDD: ("CMP", "abx", 3), 0xDE: ("DEC", "abx", 3),
    0xE0: ("CPX", "imm", 2), 0xE1: ("SBC", "izx", 2), 0xE4: ("CPX", "zp", 2),
    0xE5: ("SBC", "zp", 2), 0xE6: ("INC", "zp", 2), 0xE8: ("INX", "imp", 1),
    0xE9: ("SBC", "imm", 2), 0xEA: ("NOP", "imp", 1), 0xEC: ("CPX", "abs", 3),
    0xED: ("SBC", "abs", 3), 0xEE: ("INC", "abs", 3), 0xF0: ("BEQ", "rel", 2),
    0xF1: ("SBC", "izy", 2), 0xF5: ("SBC", "zpx", 2), 0xF6: ("INC", "zpx", 2),
    0xF8: ("SED", "imp", 1), 0xF9: ("SBC", "aby", 3), 0xFD: ("SBC", "abx", 3),
    0xFE: ("INC", "abx", 3),
}


def fmt(pc, b, mn, mode, ln):
    raw = " ".join("%02X" % x for x in b[:ln])
    if mode == "imp" or mode == "acc":
        op = ""
    elif mode == "imm":
        op = "#$%02X" % b[1]
    elif mode == "zp":
        op = "$%02X" % b[1]
    elif mode == "zpx":
        op = "$%02X,X" % b[1]
    elif mode == "zpy":
        op = "$%02X,Y" % b[1]
    elif mode == "izx":
        op = "($%02X,X)" % b[1]
    elif mode == "izy":
        op = "($%02X),Y" % b[1]
    elif mode == "rel":
        tgt = (pc + 2 + ((b[1] ^ 0x80) - 0x80)) & 0xFFFF
        op = "$%04X" % tgt
    elif mode in ("abs", "ind", "abx", "aby"):
        addr = b[1] | (b[2] << 8)
        suf = {"abs": "", "ind": "", "abx": ",X", "aby": ",Y"}[mode]
        op = ("($%04X)" if mode == "ind" else "$%04X") % addr + suf
    else:
        op = "?"
    return "%04X: %-9s %s %s" % (pc, raw, mn, op)


def disasm(data, start, end):
    pc = start
    while pc < end:
        off = pc - KERNAL_BASE + KERNAL_FILE_OFF
        opc = data[off]
        if opc in OPS:
            mn, mode, ln = OPS[opc]
            b = data[off:off + ln]
            print(fmt(pc, b, mn, mode, ln))
            pc += ln
        else:
            print("%04X: %02X        .byte $%02X" % (pc, opc, opc))
            pc += 1


def main():
    with open(BIN, "rb") as f:
        data = f.read()
    ranges = [(0xED00, 0xED70), (0xEE85, 0xEEC0), (0xF3A0, 0xF3D0)]
    if len(sys.argv) > 2:
        ranges = [(int(sys.argv[1], 16), int(sys.argv[2], 16))]
    for s, e in ranges:
        print("=== $%04X-$%04X ===" % (s, e))
        disasm(data, s, e)
        print()


if __name__ == "__main__":
    main()
