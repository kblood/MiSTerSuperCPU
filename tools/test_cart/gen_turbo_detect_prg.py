#!/usr/bin/env python3
"""
Turbo Detect PRG Generator
============================
Creates a PRG that detects and measures CPU turbo type using dual references.
Loads at $0801 with a BASIC stub (SYS 2304) and ML code at $0900.
Custom chars at $2000 (to avoid overlap with code at $0900+).

Works on: MiSTer C64, Ultimate 64, real C64.
"""

import struct
import os

CODE_BASE = 0x0900     # ML code starts here
BASIC_START = 0x0801   # BASIC program area
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

SCREEN = 0x0400
CHAR_BASE = 0x2000     # Custom chars here (not $0800, to avoid code overlap)
ROW = 40

CIA_TICKS_PER_MHZ = 3855    # $0F0F
VIC_TICKS_PER_MHZ = 765     # $02FD (NTSC)

# ZP variables
ZP_CIA_LO     = 0x02
ZP_CIA_HI     = 0x03
ZP_VIC_LO     = 0x04
ZP_VIC_HI     = 0x05
ZP_RESULT_LO  = 0x06
ZP_RESULT_HI  = 0x07
ZP_PASS_LO    = 0x08
ZP_PASS_HI    = 0x09
ZP_TMP        = 0x0A
ZP_DIV_LO     = 0x0C
ZP_DIV_HI     = 0x0D
ZP_MHZ_INT    = 0x0E
ZP_MHZ_TENTH  = 0x0F
ZP_MUL_LO     = 0x10
ZP_MUL_HI     = 0x11
ZP_CIA_MHZ    = 0x12
ZP_VIC_MHZ    = 0x13

CIA1_TA_LO = 0xDC04
CIA1_TA_HI = 0xDC05
CIA1_ICR   = 0xDC0D
CIA1_CRA   = 0xDC0E
SCPU_DETECT = 0xD0BC

FONT = {
    '0': [0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00],
    '1': [0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00],
    '2': [0x3C,0x66,0x06,0x1C,0x30,0x60,0x7E,0x00],
    '3': [0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00],
    '4': [0x0C,0x1C,0x2C,0x4C,0x7E,0x0C,0x0C,0x00],
    '5': [0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00],
    '6': [0x3C,0x66,0x60,0x7C,0x66,0x66,0x3C,0x00],
    '7': [0x7E,0x06,0x0C,0x18,0x30,0x30,0x30,0x00],
    '8': [0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00],
    '9': [0x3C,0x66,0x66,0x3E,0x06,0x66,0x3C,0x00],
    'A': [0x3C,0x66,0x66,0x7E,0x66,0x66,0x66,0x00],
    'B': [0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00],
    'C': [0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00],
    'D': [0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00],
    'E': [0x7E,0x60,0x60,0x7C,0x60,0x60,0x7E,0x00],
    'F': [0x7E,0x60,0x60,0x7C,0x60,0x60,0x60,0x00],
    ' ': [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00],
    'G': [0x3C,0x66,0x60,0x6E,0x66,0x66,0x3E,0x00],
    'H': [0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00],
    'I': [0x7E,0x18,0x18,0x18,0x18,0x18,0x7E,0x00],
    'K': [0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00],
    'L': [0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00],
    'M': [0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00],
    'N': [0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00],
    'O': [0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00],
    'P': [0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00],
    'R': [0x7C,0x66,0x66,0x7C,0x6C,0x66,0x66,0x00],
    'S': [0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00],
    'T': [0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00],
    'U': [0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00],
    'V': [0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00],
    'W': [0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00],
    'X': [0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00],
    'Y': [0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00],
    'Z': [0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00],
    ':': [0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00],
    '.': [0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00],
}

CHAR_MAP = {}
_next = 0
for c in '0123456789ABCDEF ':
    CHAR_MAP[c] = _next
    _next += 1
for c in 'GHIKLMNOPRSTUVWXYZ:.':
    if c not in CHAR_MAP:
        CHAR_MAP[c] = _next
        _next += 1


def char_ram_data():
    data = bytearray(2048)
    for ch, code in CHAR_MAP.items():
        if ch in FONT:
            off = code * 8
            for i, b in enumerate(FONT[ch]):
                data[off + i] = b
    return data


def encode_string(s):
    return [CHAR_MAP.get(c, CHAR_MAP[' ']) for c in s.upper()]


class Asm6502:
    def __init__(self, base):
        self._buf = bytearray()
        self._base = base

    def raw(self, *bs):
        self._buf.extend(bs)
        return self

    @property
    def pos(self):
        return len(self._buf)

    @property
    def addr(self):
        return self._base + self.pos

    def build(self):
        return bytes(self._buf)

    def SEI(self): return self.raw(0x78)
    def CLD(self): return self.raw(0xD8)
    def CLC(self): return self.raw(0x18)
    def SEC(self): return self.raw(0x38)
    def TXS(self): return self.raw(0x9A)
    def INX(self): return self.raw(0xE8)
    def DEX(self): return self.raw(0xCA)
    def NOP(self): return self.raw(0xEA)
    def PHA(self): return self.raw(0x48)
    def PLA(self): return self.raw(0x68)
    def TXA(self): return self.raw(0x8A)
    def TAX(self): return self.raw(0xAA)
    def TYA(self): return self.raw(0x98)
    def TAY(self): return self.raw(0xA8)
    def RTS(self): return self.raw(0x60)
    def LSR_A(self): return self.raw(0x4A)

    def LDA_imm(self, v): return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v): return self.raw(0xA2, v & 0xFF)
    def LDY_imm(self, v): return self.raw(0xA0, v & 0xFF)
    def CMP_imm(self, v): return self.raw(0xC9, v & 0xFF)
    def CPX_imm(self, v): return self.raw(0xE0, v & 0xFF)
    def ADC_imm(self, v): return self.raw(0x69, v & 0xFF)
    def AND_imm(self, v): return self.raw(0x29, v & 0xFF)
    def SBC_imm(self, v): return self.raw(0xE9, v & 0xFF)

    def LDA_zp(self, a): return self.raw(0xA5, a & 0xFF)
    def STA_zp(self, a): return self.raw(0x85, a & 0xFF)
    def STX_zp(self, a): return self.raw(0x86, a & 0xFF)
    def INC_zp(self, a): return self.raw(0xE6, a & 0xFF)
    def ADC_zp(self, a): return self.raw(0x65, a & 0xFF)

    def LDA_abs(self, a): return self.raw(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_abs(self, a): return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)

    def JMP(self, addr): return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)
    def JSR(self, addr): return self.raw(0x20, addr & 0xFF, (addr >> 8) & 0xFF)

    def BNE_back(self, target):
        off = target - (self.pos + 2)
        assert -128 <= off < 0, f"BNE back out of range: {off}"
        return self.raw(0xD0, off & 0xFF)

    def BEQ_back(self, target):
        off = target - (self.pos + 2)
        assert -128 <= off < 0, f"BEQ back out of range: {off}"
        return self.raw(0xF0, off & 0xFF)

    def BCC_back(self, target):
        off = target - (self.pos + 2)
        assert -128 <= off < 0, f"BCC back out of range: {off}"
        return self.raw(0x90, off & 0xFF)

    def BNE_fwd(self):
        idx = self.pos; self.raw(0xD0, 0x00); return idx
    def BEQ_fwd(self):
        idx = self.pos; self.raw(0xF0, 0x00); return idx
    def BCC_fwd(self):
        idx = self.pos; self.raw(0x90, 0x00); return idx
    def BCS_fwd(self):
        idx = self.pos; self.raw(0xB0, 0x00); return idx

    def fixup_branch(self, placeholder_pos):
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127, f"Fwd branch offset {off} out of range"
        self._buf[placeholder_pos + 1] = off


def display_hex_byte(a, zp_src, screen_pos):
    a.LDA_zp(zp_src)
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(screen_pos)
    a.LDA_zp(zp_src)
    a.AND_imm(0x0F)
    a.STA_abs(screen_pos + 1)

def display_hex_word(a, zp_hi, zp_lo, screen_pos):
    display_hex_byte(a, zp_hi, screen_pos)
    display_hex_byte(a, zp_lo, screen_pos + 2)

def write_string(a, text, screen_pos):
    for i, code in enumerate(encode_string(text)):
        a.LDA_imm(code); a.STA_abs(screen_pos + i)

def emit_mhz_display(a, zp_int, zp_tenth, row_base):
    a.LDA_zp(zp_int)
    a.CMP_imm(10)
    skip = a.BCC_fwd()
    a.LDX_imm(0x00)
    tl = a.pos
    a.CMP_imm(10)
    td = a.BCC_fwd()
    a.SBC_imm(10)
    a.INX()
    a.JMP(a._base + tl)
    a.fixup_branch(td)
    a.STA_abs(row_base + 13)
    a.TXA()
    a.STA_abs(row_base + 12)
    te = a.JMP(0x0000)
    te_pos = a.pos - 2
    a.fixup_branch(skip)
    a.LDA_imm(CHAR_MAP[' '])
    a.STA_abs(row_base + 12)
    a.LDA_zp(zp_int)
    a.STA_abs(row_base + 13)
    after = a.addr
    a._buf[te_pos] = after & 0xFF
    a._buf[te_pos + 1] = (after >> 8) & 0xFF
    a.LDA_zp(zp_tenth)
    a.STA_abs(row_base + 15)

def emit_compute_mhz(a, div_lo, div_hi, max_mhz=70):
    a.LDA_imm(0x00); a.STA_zp(ZP_MHZ_INT)
    il = a.pos
    a.SEC()
    a.LDA_zp(ZP_DIV_LO); a.SBC_imm(div_lo); a.TAX()
    a.LDA_zp(ZP_DIV_HI); a.SBC_imm(div_hi)
    ib = a.BCC_fwd()
    a.STA_zp(ZP_DIV_HI); a.STX_zp(ZP_DIV_LO)
    a.INC_zp(ZP_MHZ_INT)
    a.LDA_zp(ZP_MHZ_INT); a.CMP_imm(max_mhz)
    ic = a.BCS_fwd()
    a.JMP(a._base + il)
    a.fixup_branch(ib); a.fixup_branch(ic)
    # tenths
    a.LDA_zp(ZP_DIV_LO); a.STA_zp(ZP_MUL_LO)
    a.LDA_zp(ZP_DIV_HI); a.STA_zp(ZP_MUL_HI)
    a.LDA_imm(0x00); a.STA_zp(ZP_DIV_LO); a.STA_zp(ZP_DIV_HI)
    a.LDX_imm(10)
    ml = a.pos
    a.CLC()
    a.LDA_zp(ZP_DIV_LO); a.ADC_zp(ZP_MUL_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_DIV_HI); a.ADC_zp(ZP_MUL_HI); a.STA_zp(ZP_DIV_HI)
    a.DEX(); a.BNE_back(ml)
    a.LDA_imm(0x00); a.STA_zp(ZP_MHZ_TENTH)
    tl = a.pos
    a.SEC()
    a.LDA_zp(ZP_DIV_LO); a.SBC_imm(div_lo); a.TAX()
    a.LDA_zp(ZP_DIV_HI); a.SBC_imm(div_hi)
    tb = a.BCC_fwd()
    a.STA_zp(ZP_DIV_HI); a.STX_zp(ZP_DIV_LO)
    a.INC_zp(ZP_MHZ_TENTH)
    a.LDA_zp(ZP_MHZ_TENTH); a.CMP_imm(10)
    tc = a.BCS_fwd()
    a.JMP(a._base + tl)
    a.fixup_branch(tb); a.fixup_branch(tc)
    a.RTS()


def assemble():
    a = Asm6502(CODE_BASE)

    # ── Init ──
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x36); a.STA_zp(0x01)  # KERNAL + I/O, no BASIC ROM

    a.LDA_imm(0x00)
    for zp in [ZP_CIA_LO, ZP_CIA_HI, ZP_VIC_LO, ZP_VIC_HI,
               ZP_RESULT_LO, ZP_RESULT_HI, ZP_PASS_LO, ZP_PASS_HI,
               ZP_MHZ_INT, ZP_MHZ_TENTH, ZP_CIA_MHZ, ZP_VIC_MHZ]:
        a.STA_zp(zp)

    # ── VIC setup: screen off, chars at $2000 ──
    a.LDA_imm(0x0B); a.STA_abs(0xD011)
    # $D018: screen at $0400 (0001), chars at $2000 (100) → 0001_1000 = $18
    a.LDA_imm(0x18); a.STA_abs(0xD018)
    a.LDA_imm(0x00); a.STA_abs(0xD020)
    a.LDA_imm(0x00); a.STA_abs(0xD021)
    a.LDA_imm(0xC8); a.STA_abs(0xD016)

    # ── Clear char RAM at $2000 ──
    a.LDA_imm(0x00); a.LDX_imm(0x00)
    cc = a.pos
    for page in range(0x20, 0x28):  # $2000-$27FF
        a.STA_absx(page * 256)
    a.INX(); a.BNE_back(cc)

    # ── Copy font to $2000 ──
    font_copy_jsr = a.pos
    a.JSR(0x0000)

    # ── Clear screen ──
    a.LDA_imm(CHAR_MAP[' ']); a.LDX_imm(0x00)
    sc = a.pos
    a.STA_absx(0x0400); a.STA_absx(0x0500)
    a.STA_absx(0x0600); a.STA_absx(0x0700)
    a.INX(); a.BNE_back(sc)

    # ── Color RAM: green ──
    a.LDA_imm(0x05); a.LDX_imm(0x00)
    cf = a.pos
    a.STA_absx(0xD800); a.STA_absx(0xD900)
    a.STA_absx(0xDA00); a.STA_absx(0xDB00)
    a.INX(); a.BNE_back(cf)

    # ── Labels ──
    write_string(a, "TURBO DETECT", SCREEN + 0 * ROW)
    write_string(a, "CIA", SCREEN + 2 * ROW)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 2 * ROW + 14)
    write_string(a, "MHZ", SCREEN + 2 * ROW + 17)
    write_string(a, "VIC", SCREEN + 3 * ROW)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 3 * ROW + 14)
    write_string(a, "MHZ", SCREEN + 3 * ROW + 17)
    write_string(a, "TYPE", SCREEN + 5 * ROW)
    write_string(a, "D0BC", SCREEN + 7 * ROW)
    write_string(a, "PASS", SCREEN + 8 * ROW)

    # ── Colors ──
    a.LDA_imm(0x0E)  # title: light blue
    for col in range(12):
        a.STA_abs(0xD800 + col)
    a.LDA_imm(0x07)  # hex values: yellow
    for row in [2, 3]:
        for col in range(6, 10):
            a.STA_abs(0xD800 + row * ROW + col)
    for col in range(6, 8):
        a.STA_abs(0xD800 + 7 * ROW + col)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 8 * ROW + col)
    a.LDA_imm(0x03)  # MHz: cyan
    for row in [2, 3]:
        for col in range(12, 20):
            a.STA_abs(0xD800 + row * ROW + col)
    a.LDA_imm(0x01)  # TYPE value: white
    for col in range(6, 20):
        a.STA_abs(0xD800 + 5 * ROW + col)

    # ── Screen on ──
    a.LDA_imm(0x1B); a.STA_abs(0xD011)

    # ════════ Main loop ════════
    main_loop = a.pos

    # CIA measurement
    a.LDA_imm(0x02); a.STA_abs(0xD020)
    measure_cia_jsr = a.pos
    a.JSR(0x0000)
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_CIA_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_CIA_HI)
    display_hex_word(a, ZP_CIA_HI, ZP_CIA_LO, SCREEN + 2 * ROW + 6)
    a.LDA_zp(ZP_CIA_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_CIA_HI); a.STA_zp(ZP_DIV_HI)
    compute_cia_jsr = a.pos
    a.JSR(0x0000)
    a.LDA_zp(ZP_MHZ_INT); a.STA_zp(ZP_CIA_MHZ)
    emit_mhz_display(a, ZP_MHZ_INT, ZP_MHZ_TENTH, SCREEN + 2 * ROW)

    # VIC measurement
    a.LDA_imm(0x05); a.STA_abs(0xD020)
    measure_vic_jsr = a.pos
    a.JSR(0x0000)
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_VIC_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_VIC_HI)
    display_hex_word(a, ZP_VIC_HI, ZP_VIC_LO, SCREEN + 3 * ROW + 6)
    a.LDA_zp(ZP_VIC_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_VIC_HI); a.STA_zp(ZP_DIV_HI)
    compute_vic_jsr = a.pos
    a.JSR(0x0000)
    a.LDA_zp(ZP_MHZ_INT); a.STA_zp(ZP_VIC_MHZ)
    emit_mhz_display(a, ZP_MHZ_INT, ZP_MHZ_TENTH, SCREEN + 3 * ROW)

    # Type detection
    a.LDA_imm(CHAR_MAP[' '])
    for col in range(6, 20):
        a.STA_abs(SCREEN + 5 * ROW + col)
    # CIA >= 2?
    a.LDA_zp(ZP_CIA_MHZ); a.CMP_imm(2)
    not_extra = a.BCC_fwd()
    write_string(a, "EXTRA CYC", SCREEN + 5 * ROW + 6)
    a.LDA_imm(0x05)
    for col in range(6, 15):
        a.STA_abs(0xD800 + 5 * ROW + col)
    je = a.JMP(0x0000); je_pos = a.pos - 2
    a.fixup_branch(not_extra)
    # VIC >= 2?
    a.LDA_zp(ZP_VIC_MHZ); a.CMP_imm(2)
    not_fast = a.BCC_fwd()
    write_string(a, "FAST PHI2", SCREEN + 5 * ROW + 6)
    a.LDA_imm(0x03)
    for col in range(6, 15):
        a.STA_abs(0xD800 + 5 * ROW + col)
    jf = a.JMP(0x0000); jf_pos = a.pos - 2
    a.fixup_branch(not_fast)
    write_string(a, "NONE", SCREEN + 5 * ROW + 6)
    a.LDA_imm(0x0F)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 5 * ROW + col)
    type_end = a.addr
    a._buf[je_pos] = type_end & 0xFF; a._buf[je_pos + 1] = (type_end >> 8) & 0xFF
    a._buf[jf_pos] = type_end & 0xFF; a._buf[jf_pos + 1] = (type_end >> 8) & 0xFF

    # D0BC
    a.LDA_abs(SCPU_DETECT); a.STA_zp(ZP_TMP)
    display_hex_byte(a, ZP_TMP, SCREEN + 7 * ROW + 6)

    # Pass
    a.INC_zp(ZP_PASS_LO)
    sh = a.BNE_fwd(); a.INC_zp(ZP_PASS_HI); a.fixup_branch(sh)
    display_hex_word(a, ZP_PASS_HI, ZP_PASS_LO, SCREEN + 8 * ROW + 6)

    a.LDA_imm(0x00); a.STA_abs(0xD020)
    a.JMP(a._base + main_loop)

    # ════════ measure_cia ════════
    mcia = a.addr
    a._buf[measure_cia_jsr + 1] = mcia & 0xFF
    a._buf[measure_cia_jsr + 2] = (mcia >> 8) & 0xFF
    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()
    a.LDA_imm(0x00); a.STA_abs(CIA1_CRA)
    a.LDA_abs(CIA1_ICR)
    a.LDA_imm(0xFF); a.STA_abs(CIA1_TA_LO); a.STA_abs(CIA1_TA_HI)
    a.LDA_imm(0x00); a.STA_zp(ZP_RESULT_LO); a.STA_zp(ZP_RESULT_HI)
    a.LDA_imm(0x19); a.STA_abs(CIA1_CRA)
    cl = a.pos
    a.INC_zp(ZP_RESULT_LO)
    cs = a.BNE_fwd(); a.INC_zp(ZP_RESULT_HI); a.fixup_branch(cs)
    a.LDA_abs(CIA1_ICR); a.AND_imm(0x01)
    a.BEQ_back(cl)
    a.PLA(); a.TAY(); a.PLA(); a.TAX(); a.PLA()
    a.RTS()

    # ════════ measure_vic ════════
    mvic = a.addr
    a._buf[measure_vic_jsr + 1] = mvic & 0xFF
    a._buf[measure_vic_jsr + 2] = (mvic >> 8) & 0xFF
    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()
    # Wait for raster >= 210
    wb = a.pos
    a.LDA_abs(0xD012); a.CMP_imm(210)
    a.BCC_back(wb)
    # Wait for raster < 2 with MSB=0
    wt = a.pos
    a.LDA_abs(0xD011); a.AND_imm(0x80)
    bne_wt = a.pos; a.raw(0xD0, 0x00)  # BNE -> wt
    a.LDA_abs(0xD012); a.CMP_imm(2)
    bcs_wt = a.pos; a.raw(0xB0, 0x00)  # BCS -> wt
    a._buf[bne_wt + 1] = (wt - (bne_wt + 2)) & 0xFF
    a._buf[bcs_wt + 1] = (wt - (bcs_wt + 2)) & 0xFF
    # Count from raster 0 to 200
    a.LDA_imm(0x00); a.STA_zp(ZP_RESULT_LO); a.STA_zp(ZP_RESULT_HI)
    vl = a.pos
    a.INC_zp(ZP_RESULT_LO)
    vs = a.BNE_fwd(); a.INC_zp(ZP_RESULT_HI); a.fixup_branch(vs)
    a.LDA_abs(0xD012); a.CMP_imm(200)
    a.BCC_back(vl)
    a.PLA(); a.TAY(); a.PLA(); a.TAX(); a.PLA()
    a.RTS()

    # ════════ compute_cia_mhz (/ 3855 = $0F0F) ════════
    ccia = a.addr
    a._buf[compute_cia_jsr + 1] = ccia & 0xFF
    a._buf[compute_cia_jsr + 2] = (ccia >> 8) & 0xFF
    emit_compute_mhz(a, 0x0F, 0x0F, max_mhz=20)

    # ════════ compute_vic_mhz (/ 765 = $02FD) ════════
    cvic = a.addr
    a._buf[compute_vic_jsr + 1] = cvic & 0xFF
    a._buf[compute_vic_jsr + 2] = (cvic >> 8) & 0xFF
    emit_compute_mhz(a, 0xFD, 0x02, max_mhz=70)

    # ════════ Font copy ($2000-$21FF) ════════
    fca = a.addr
    a._buf[font_copy_jsr + 1] = fca & 0xFF
    a._buf[font_copy_jsr + 2] = (fca >> 8) & 0xFF
    a.LDX_imm(0x00)
    fcl = a.pos
    lda_p0 = a.pos; a.LDA_absx(0x0000); a.STA_absx(CHAR_BASE)
    lda_p1 = a.pos; a.LDA_absx(0x0000); a.STA_absx(CHAR_BASE + 0x100)
    a.INX(); a.BNE_back(fcl)
    a.RTS()

    # ════════ Font data ════════
    font_data = char_ram_data()
    font_pos = a.pos
    font_addr = a._base + font_pos
    a.raw(*font_data[:512])
    a._buf[lda_p0 + 1] = font_addr & 0xFF
    a._buf[lda_p0 + 2] = (font_addr >> 8) & 0xFF
    a._buf[lda_p1 + 1] = (font_addr + 256) & 0xFF
    a._buf[lda_p1 + 2] = ((font_addr + 256) >> 8) & 0xFF

    return a


def make_basic_stub():
    """BASIC stub: 10 SYS 2304 ($0900)"""
    stub = bytearray()
    sys_addr = str(CODE_BASE).encode('ascii')
    next_line = BASIC_START + 4 + 1 + len(sys_addr) + 1  # ptr + linenum + SYS + digits + EOL
    stub.extend(struct.pack("<H", next_line))  # next line pointer
    stub.extend(struct.pack("<H", 10))         # line number 10
    stub.append(0x9E)                          # SYS token
    stub.extend(sys_addr)                      # "2304"
    stub.append(0x00)                          # end of line
    stub.extend(b'\x00\x00')                   # end of program
    return bytes(stub)


def main():
    asm = assemble()
    code = asm.build()
    stub = make_basic_stub()

    # PRG = load_addr + BASIC_stub + padding + ML_code
    load_addr = struct.pack("<H", BASIC_START)
    padding = b'\x00' * (CODE_BASE - BASIC_START - len(stub))
    prg = load_addr + stub + padding + code

    os.makedirs(OUT_DIR, exist_ok=True)
    prg_path = os.path.join(OUT_DIR, "turbo_detect.prg")

    with open(prg_path, "wb") as f:
        f.write(prg)

    # Also make CRT version
    crt_asm = assemble_crt()
    crt_rom = make_crt_rom(crt_asm)
    crt = make_crt(crt_rom, "TURBO DETECT")
    crt_path = os.path.join(OUT_DIR, "turbo_detect.crt")
    with open(crt_path, "wb") as f:
        f.write(crt)

    print(f"Turbo Detect")
    print(f"PRG:  {len(prg)} bytes, loads at ${BASIC_START:04X}, SYS {CODE_BASE}")
    print(f"      {prg_path}")
    print(f"CRT:  {len(crt)} bytes (Ultimax)")
    print(f"      {crt_path}")
    print(f"ML:   {len(code)} bytes at ${CODE_BASE:04X}")


def assemble_crt():
    """Assemble CRT version with $E000 base and chars at $0800."""
    # Reuse same logic but for CRT (ROM at $E000, chars at $0800)
    a = Asm6502(0xE000)

    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    a.LDA_imm(0x00)
    for zp in [ZP_CIA_LO, ZP_CIA_HI, ZP_VIC_LO, ZP_VIC_HI,
               ZP_RESULT_LO, ZP_RESULT_HI, ZP_PASS_LO, ZP_PASS_HI,
               ZP_MHZ_INT, ZP_MHZ_TENTH, ZP_CIA_MHZ, ZP_VIC_MHZ]:
        a.STA_zp(zp)

    a.LDA_imm(0x0B); a.STA_abs(0xD011)
    a.LDA_imm(0x12); a.STA_abs(0xD018)  # chars at $0800
    a.LDA_imm(0x00); a.STA_abs(0xD020)
    a.LDA_imm(0x00); a.STA_abs(0xD021)
    a.LDA_imm(0xC8); a.STA_abs(0xD016)

    a.LDA_imm(0x00); a.LDX_imm(0x00)
    cc = a.pos
    for page in range(0x08, 0x10):
        a.STA_absx(page * 256)
    a.INX(); a.BNE_back(cc)

    font_copy_jsr = a.pos; a.JSR(0x0000)

    a.LDA_imm(CHAR_MAP[' ']); a.LDX_imm(0x00)
    sc = a.pos
    a.STA_absx(0x0400); a.STA_absx(0x0500)
    a.STA_absx(0x0600); a.STA_absx(0x0700)
    a.INX(); a.BNE_back(sc)

    a.LDA_imm(0x05); a.LDX_imm(0x00)
    cf = a.pos
    a.STA_absx(0xD800); a.STA_absx(0xD900)
    a.STA_absx(0xDA00); a.STA_absx(0xDB00)
    a.INX(); a.BNE_back(cf)

    write_string(a, "TURBO DETECT", SCREEN)
    write_string(a, "CIA", SCREEN + 2*ROW)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 2*ROW + 14)
    write_string(a, "MHZ", SCREEN + 2*ROW + 17)
    write_string(a, "VIC", SCREEN + 3*ROW)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 3*ROW + 14)
    write_string(a, "MHZ", SCREEN + 3*ROW + 17)
    write_string(a, "TYPE", SCREEN + 5*ROW)
    write_string(a, "D0BC", SCREEN + 7*ROW)
    write_string(a, "PASS", SCREEN + 8*ROW)

    a.LDA_imm(0x0E)
    for col in range(12):
        a.STA_abs(0xD800 + col)
    a.LDA_imm(0x07)
    for row in [2, 3]:
        for col in range(6, 10):
            a.STA_abs(0xD800 + row*ROW + col)
    for col in range(6, 8):
        a.STA_abs(0xD800 + 7*ROW + col)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 8*ROW + col)
    a.LDA_imm(0x03)
    for row in [2, 3]:
        for col in range(12, 20):
            a.STA_abs(0xD800 + row*ROW + col)
    a.LDA_imm(0x01)
    for col in range(6, 20):
        a.STA_abs(0xD800 + 5*ROW + col)

    a.LDA_imm(0x1B); a.STA_abs(0xD011)

    main_loop = a.pos
    a.LDA_imm(0x02); a.STA_abs(0xD020)
    mcia_jsr = a.pos; a.JSR(0x0000)
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_CIA_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_CIA_HI)
    display_hex_word(a, ZP_CIA_HI, ZP_CIA_LO, SCREEN + 2*ROW + 6)
    a.LDA_zp(ZP_CIA_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_CIA_HI); a.STA_zp(ZP_DIV_HI)
    ccia_jsr = a.pos; a.JSR(0x0000)
    a.LDA_zp(ZP_MHZ_INT); a.STA_zp(ZP_CIA_MHZ)
    emit_mhz_display(a, ZP_MHZ_INT, ZP_MHZ_TENTH, SCREEN + 2*ROW)

    a.LDA_imm(0x05); a.STA_abs(0xD020)
    mvic_jsr = a.pos; a.JSR(0x0000)
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_VIC_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_VIC_HI)
    display_hex_word(a, ZP_VIC_HI, ZP_VIC_LO, SCREEN + 3*ROW + 6)
    a.LDA_zp(ZP_VIC_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_VIC_HI); a.STA_zp(ZP_DIV_HI)
    cvic_jsr = a.pos; a.JSR(0x0000)
    a.LDA_zp(ZP_MHZ_INT); a.STA_zp(ZP_VIC_MHZ)
    emit_mhz_display(a, ZP_MHZ_INT, ZP_MHZ_TENTH, SCREEN + 3*ROW)

    a.LDA_imm(CHAR_MAP[' '])
    for col in range(6, 20):
        a.STA_abs(SCREEN + 5*ROW + col)
    a.LDA_zp(ZP_CIA_MHZ); a.CMP_imm(2)
    ne = a.BCC_fwd()
    write_string(a, "EXTRA CYC", SCREEN + 5*ROW + 6)
    a.LDA_imm(0x05)
    for col in range(6, 15):
        a.STA_abs(0xD800 + 5*ROW + col)
    j1 = a.JMP(0); j1p = a.pos - 2
    a.fixup_branch(ne)
    a.LDA_zp(ZP_VIC_MHZ); a.CMP_imm(2)
    nf = a.BCC_fwd()
    write_string(a, "FAST PHI2", SCREEN + 5*ROW + 6)
    a.LDA_imm(0x03)
    for col in range(6, 15):
        a.STA_abs(0xD800 + 5*ROW + col)
    j2 = a.JMP(0); j2p = a.pos - 2
    a.fixup_branch(nf)
    write_string(a, "NONE", SCREEN + 5*ROW + 6)
    a.LDA_imm(0x0F)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 5*ROW + col)
    te = a.addr
    a._buf[j1p] = te & 0xFF; a._buf[j1p+1] = (te>>8) & 0xFF
    a._buf[j2p] = te & 0xFF; a._buf[j2p+1] = (te>>8) & 0xFF

    a.LDA_abs(SCPU_DETECT); a.STA_zp(ZP_TMP)
    display_hex_byte(a, ZP_TMP, SCREEN + 7*ROW + 6)
    a.INC_zp(ZP_PASS_LO)
    sh = a.BNE_fwd(); a.INC_zp(ZP_PASS_HI); a.fixup_branch(sh)
    display_hex_word(a, ZP_PASS_HI, ZP_PASS_LO, SCREEN + 8*ROW + 6)
    a.LDA_imm(0x00); a.STA_abs(0xD020)
    a.JMP(a._base + main_loop)

    # Subroutines
    mcia_a = a.addr
    a._buf[mcia_jsr+1] = mcia_a & 0xFF; a._buf[mcia_jsr+2] = (mcia_a>>8) & 0xFF
    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()
    a.LDA_imm(0x00); a.STA_abs(CIA1_CRA); a.LDA_abs(CIA1_ICR)
    a.LDA_imm(0xFF); a.STA_abs(CIA1_TA_LO); a.STA_abs(CIA1_TA_HI)
    a.LDA_imm(0x00); a.STA_zp(ZP_RESULT_LO); a.STA_zp(ZP_RESULT_HI)
    a.LDA_imm(0x19); a.STA_abs(CIA1_CRA)
    cl = a.pos
    a.INC_zp(ZP_RESULT_LO)
    cs = a.BNE_fwd(); a.INC_zp(ZP_RESULT_HI); a.fixup_branch(cs)
    a.LDA_abs(CIA1_ICR); a.AND_imm(0x01); a.BEQ_back(cl)
    a.PLA(); a.TAY(); a.PLA(); a.TAX(); a.PLA(); a.RTS()

    mvic_a = a.addr
    a._buf[mvic_jsr+1] = mvic_a & 0xFF; a._buf[mvic_jsr+2] = (mvic_a>>8) & 0xFF
    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()
    wb = a.pos
    a.LDA_abs(0xD012); a.CMP_imm(210); a.BCC_back(wb)
    wt = a.pos
    a.LDA_abs(0xD011); a.AND_imm(0x80)
    bn = a.pos; a.raw(0xD0, 0x00)
    a.LDA_abs(0xD012); a.CMP_imm(2)
    bc = a.pos; a.raw(0xB0, 0x00)
    a._buf[bn+1] = (wt - (bn+2)) & 0xFF
    a._buf[bc+1] = (wt - (bc+2)) & 0xFF
    a.LDA_imm(0x00); a.STA_zp(ZP_RESULT_LO); a.STA_zp(ZP_RESULT_HI)
    vl = a.pos
    a.INC_zp(ZP_RESULT_LO)
    vs2 = a.BNE_fwd(); a.INC_zp(ZP_RESULT_HI); a.fixup_branch(vs2)
    a.LDA_abs(0xD012); a.CMP_imm(200); a.BCC_back(vl)
    a.PLA(); a.TAY(); a.PLA(); a.TAX(); a.PLA(); a.RTS()

    cc_a = a.addr
    a._buf[ccia_jsr+1] = cc_a & 0xFF; a._buf[ccia_jsr+2] = (cc_a>>8) & 0xFF
    emit_compute_mhz(a, 0x0F, 0x0F, 20)
    cv_a = a.addr
    a._buf[cvic_jsr+1] = cv_a & 0xFF; a._buf[cvic_jsr+2] = (cv_a>>8) & 0xFF
    emit_compute_mhz(a, 0xFD, 0x02, 70)

    fc_a = a.addr
    a._buf[font_copy_jsr+1] = fc_a & 0xFF; a._buf[font_copy_jsr+2] = (fc_a>>8) & 0xFF
    a.LDX_imm(0x00)
    fcl = a.pos
    lp0 = a.pos; a.LDA_absx(0x0000); a.STA_absx(0x0800)
    lp1 = a.pos; a.LDA_absx(0x0000); a.STA_absx(0x0900)
    a.INX(); a.BNE_back(fcl); a.RTS()

    fd = char_ram_data()
    fp = a.pos; fa = a._base + fp
    a.raw(*fd[:512])
    a._buf[lp0+1] = fa & 0xFF; a._buf[lp0+2] = (fa>>8) & 0xFF
    a._buf[lp1+1] = (fa+256) & 0xFF; a._buf[lp1+2] = ((fa+256)>>8) & 0xFF

    return a


def make_crt_rom(asm):
    code = asm.build()
    rom = bytearray(b"\xAA" * 0x2000)
    rom[:len(code)] = code
    entry = 0xE000
    rom[0x1FFA] = entry & 0xFF; rom[0x1FFB] = (entry >> 8) & 0xFF
    rom[0x1FFC] = entry & 0xFF; rom[0x1FFD] = (entry >> 8) & 0xFF
    rom[0x1FFE] = entry & 0xFF; rom[0x1FFF] = (entry >> 8) & 0xFF
    return bytes(rom)


def make_crt(rom, name):
    sig = b"C64 CARTRIDGE   "
    hdr = sig + struct.pack(">I", 64) + struct.pack(">H", 0x0100)
    hdr += struct.pack(">H", 0) + b"\x01\x00" + b"\x00" * 6
    hdr += name.encode("ascii")[:32].ljust(32, b"\x00")
    chip = b"CHIP" + struct.pack(">I", 16 + len(rom))
    chip += struct.pack(">HHH", 0, 0, 0xE000) + struct.pack(">H", len(rom))
    return hdr + chip + rom


if __name__ == "__main__":
    main()
