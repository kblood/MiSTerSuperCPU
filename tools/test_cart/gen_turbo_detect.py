#!/usr/bin/env python3
"""
Turbo Detect CRT Generator
============================
Creates an Ultimax-mode CRT that detects and measures CPU turbo type.

Uses TWO independent reference clocks:
  1. CIA Timer A - runs at phi2 clock rate
  2. VIC Raster  - runs at fixed video display rate (50/60 Hz)

Detection logic:
  - "EXTRA CYCLES" turbo (SuperCPU/MiSTer): CIA shows > 1 MHz (CPU gets
    more phi2 edges but each edge is still 1 MHz). VIC also shows > 1 MHz.
  - "FAST PHI2" turbo (Ultimate 64): CIA shows ~1 MHz (phi2 is faster but
    CIA timer scales proportionally). VIC shows actual speed since raster
    is tied to fixed video output rate.
  - No turbo: Both show ~1 MHz.

Screen layout:
  Row 0:  TURBO DETECT
  Row 2:  CIA   xxxx  xx.x MHZ   (CIA timer measurement)
  Row 3:  VIC   xxxx  xx.x MHZ   (VIC raster measurement)
  Row 5:  TYPE  EXTRA CYC / FAST PHI / NONE
  Row 7:  D0BC  xx                (SuperCPU detect register)
  Row 8:  PASS  xxxx

CIA method: 65535-cycle countdown, 17-cycle counting loop.
  MHz = count / 3855

VIC method: Count loop iterations from raster 0 to raster 200.
  NTSC: 200 lines × 65 cycles = 13000 cycles. MHz = count / 765.
  (PAL: 200 × 63 = 12600 → ~3% error, acceptable)
"""

import struct
import os

ROM_SIZE = 0x2000
ROM_BASE = 0xE000
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

SCREEN = 0x0400
ROW = 40

CIA_TICKS_PER_MHZ = 3855    # $0F0F
VIC_TICKS_PER_MHZ = 765     # $02FD (NTSC: 200 lines × 65 cycles / 17)

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
ZP_CIA_MHZ    = 0x12   # CIA integer MHz for type detection
ZP_VIC_MHZ    = 0x13   # VIC integer MHz for type detection

# CIA1 registers
CIA1_TA_LO = 0xDC04
CIA1_TA_HI = 0xDC05
CIA1_ICR   = 0xDC0D
CIA1_CRA   = 0xDC0E

SCPU_DETECT = 0xD0BC

# 5x7 pixel font
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

# Character allocation: 0x00-0x0F = hex, 0x10+ = labels
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
    """Minimal 6502 assembler."""

    def __init__(self):
        self._buf = bytearray()

    def raw(self, *bs):
        self._buf.extend(bs)
        return self

    @property
    def pos(self):
        return len(self._buf)

    @property
    def addr(self):
        return ROM_BASE + self.pos

    def build(self):
        return bytes(self._buf)

    # Implied
    def SEI(self): return self.raw(0x78)
    def CLD(self): return self.raw(0xD8)
    def CLC(self): return self.raw(0x18)
    def SEC(self): return self.raw(0x38)
    def TXS(self): return self.raw(0x9A)
    def INX(self): return self.raw(0xE8)
    def DEX(self): return self.raw(0xCA)
    def DEY(self): return self.raw(0x88)
    def NOP(self): return self.raw(0xEA)
    def PHA(self): return self.raw(0x48)
    def PLA(self): return self.raw(0x68)
    def TXA(self): return self.raw(0x8A)
    def TAX(self): return self.raw(0xAA)
    def TYA(self): return self.raw(0x98)
    def TAY(self): return self.raw(0xA8)
    def RTS(self): return self.raw(0x60)
    def LSR_A(self): return self.raw(0x4A)
    def BMI(self, target):
        off = target - (self.pos + 2)
        assert -128 <= off < 0, f"BMI back out of range: {off}"
        return self.raw(0x30, off & 0xFF)

    # Immediate
    def LDA_imm(self, v): return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v): return self.raw(0xA2, v & 0xFF)
    def LDY_imm(self, v): return self.raw(0xA0, v & 0xFF)
    def CMP_imm(self, v): return self.raw(0xC9, v & 0xFF)
    def CPX_imm(self, v): return self.raw(0xE0, v & 0xFF)
    def ADC_imm(self, v): return self.raw(0x69, v & 0xFF)
    def AND_imm(self, v): return self.raw(0x29, v & 0xFF)
    def ORA_imm(self, v): return self.raw(0x09, v & 0xFF)
    def SBC_imm(self, v): return self.raw(0xE9, v & 0xFF)

    # Zero page
    def LDA_zp(self, a): return self.raw(0xA5, a & 0xFF)
    def STA_zp(self, a): return self.raw(0x85, a & 0xFF)
    def STX_zp(self, a): return self.raw(0x86, a & 0xFF)
    def INC_zp(self, a): return self.raw(0xE6, a & 0xFF)
    def DEC_zp(self, a): return self.raw(0xC6, a & 0xFF)
    def SBC_zp(self, a): return self.raw(0xE5, a & 0xFF)
    def ADC_zp(self, a): return self.raw(0x65, a & 0xFF)

    # Absolute
    def LDA_abs(self, a): return self.raw(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_abs(self, a): return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)

    # Jumps
    def JMP(self, addr): return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)
    def JSR(self, addr): return self.raw(0x20, addr & 0xFF, (addr >> 8) & 0xFF)

    # Branches
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
        idx = self.pos
        self.raw(0xD0, 0x00)
        return idx

    def BEQ_fwd(self):
        idx = self.pos
        self.raw(0xF0, 0x00)
        return idx

    def BCC_fwd(self):
        idx = self.pos
        self.raw(0x90, 0x00)
        return idx

    def BCS_fwd(self):
        idx = self.pos
        self.raw(0xB0, 0x00)
        return idx

    def BMI_fwd(self):
        idx = self.pos
        self.raw(0x30, 0x00)
        return idx

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


def write_string_to_screen(a, text, screen_pos):
    """Emit code to write a string to screen memory."""
    for i, code in enumerate(encode_string(text)):
        a.LDA_imm(code)
        a.STA_abs(screen_pos + i)


def emit_mhz_display(a, zp_mhz_int_src, zp_mhz_tenth_src, screen_row_base):
    """Emit code to display [tens][ones].[tenth] at col 12-15."""
    a.LDA_zp(zp_mhz_int_src)
    a.CMP_imm(10)
    tens_skip = a.BCC_fwd()
    # >= 10
    a.LDX_imm(0x00)
    tens_loop = a.pos
    a.CMP_imm(10)
    tens_done = a.BCC_fwd()
    a.SBC_imm(10)  # carry set from CMP
    a.INX()
    a.JMP(ROM_BASE + tens_loop)
    a.fixup_branch(tens_done)
    a.STA_abs(screen_row_base + 13)  # ones
    a.TXA()
    a.STA_abs(screen_row_base + 12)  # tens
    tens_end = a.JMP(0x0000)
    tens_end_pos = a.pos - 2
    a.fixup_branch(tens_skip)
    # < 10
    a.LDA_imm(CHAR_MAP[' '])
    a.STA_abs(screen_row_base + 12)
    a.LDA_zp(zp_mhz_int_src)
    a.STA_abs(screen_row_base + 13)
    after_tens = a.addr
    a._buf[tens_end_pos] = after_tens & 0xFF
    a._buf[tens_end_pos + 1] = (after_tens >> 8) & 0xFF
    # Tenths
    a.LDA_zp(zp_mhz_tenth_src)
    a.STA_abs(screen_row_base + 15)


def emit_compute_mhz(a, divisor_lo, divisor_hi, max_mhz=70):
    """Emit compute_mhz subroutine for a given divisor.
    Input: ZP_DIV_LO/HI. Output: ZP_MHZ_INT, ZP_MHZ_TENTH."""
    # Integer part: count / divisor
    a.LDA_imm(0x00)
    a.STA_zp(ZP_MHZ_INT)

    int_loop = a.pos
    a.SEC()
    a.LDA_zp(ZP_DIV_LO)
    a.SBC_imm(divisor_lo)
    a.TAX()
    a.LDA_zp(ZP_DIV_HI)
    a.SBC_imm(divisor_hi)
    int_borrow = a.BCC_fwd()
    a.STA_zp(ZP_DIV_HI)
    a.STX_zp(ZP_DIV_LO)
    a.INC_zp(ZP_MHZ_INT)
    a.LDA_zp(ZP_MHZ_INT)
    a.CMP_imm(max_mhz)
    int_cap = a.BCS_fwd()
    a.JMP(ROM_BASE + int_loop)
    a.fixup_branch(int_borrow)
    a.fixup_branch(int_cap)

    # Tenths: remainder * 10 / divisor
    a.LDA_zp(ZP_DIV_LO); a.STA_zp(ZP_MUL_LO)
    a.LDA_zp(ZP_DIV_HI); a.STA_zp(ZP_MUL_HI)
    a.LDA_imm(0x00)
    a.STA_zp(ZP_DIV_LO)
    a.STA_zp(ZP_DIV_HI)
    a.LDX_imm(10)
    mul10_loop = a.pos
    a.CLC()
    a.LDA_zp(ZP_DIV_LO)
    a.ADC_zp(ZP_MUL_LO)
    a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_DIV_HI)
    a.ADC_zp(ZP_MUL_HI)
    a.STA_zp(ZP_DIV_HI)
    a.DEX()
    a.BNE_back(mul10_loop)

    a.LDA_imm(0x00)
    a.STA_zp(ZP_MHZ_TENTH)
    tenth_loop = a.pos
    a.SEC()
    a.LDA_zp(ZP_DIV_LO)
    a.SBC_imm(divisor_lo)
    a.TAX()
    a.LDA_zp(ZP_DIV_HI)
    a.SBC_imm(divisor_hi)
    tenth_borrow = a.BCC_fwd()
    a.STA_zp(ZP_DIV_HI)
    a.STX_zp(ZP_DIV_LO)
    a.INC_zp(ZP_MHZ_TENTH)
    a.LDA_zp(ZP_MHZ_TENTH)
    a.CMP_imm(10)
    tenth_cap = a.BCS_fwd()
    a.JMP(ROM_BASE + tenth_loop)
    a.fixup_branch(tenth_borrow)
    a.fixup_branch(tenth_cap)

    a.RTS()


def assemble():
    a = Asm6502()

    # ── Init ──
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # Init ZP
    a.LDA_imm(0x00)
    for zp in [ZP_CIA_LO, ZP_CIA_HI, ZP_VIC_LO, ZP_VIC_HI,
               ZP_RESULT_LO, ZP_RESULT_HI, ZP_PASS_LO, ZP_PASS_HI,
               ZP_MHZ_INT, ZP_MHZ_TENTH, ZP_CIA_MHZ, ZP_VIC_MHZ]:
        a.STA_zp(zp)

    # ── VIC-II setup ──
    a.LDA_imm(0x0B); a.STA_abs(0xD011)   # screen off
    a.LDA_imm(0x12); a.STA_abs(0xD018)   # screen@$0400, chars@$0800
    a.LDA_imm(0x00); a.STA_abs(0xD020)
    a.LDA_imm(0x00); a.STA_abs(0xD021)
    a.LDA_imm(0xC8); a.STA_abs(0xD016)

    # ── Clear char RAM ──
    a.LDA_imm(0x00)
    a.LDX_imm(0x00)
    cc = a.pos
    for page in range(0x08, 0x10):
        a.STA_absx(page * 256)
    a.INX()
    a.BNE_back(cc)

    # ── Copy font ──
    font_copy_jsr = a.pos
    a.JSR(0x0000)

    # ── Clear screen ──
    a.LDA_imm(CHAR_MAP[' '])
    a.LDX_imm(0x00)
    sc = a.pos
    a.STA_absx(0x0400); a.STA_absx(0x0500)
    a.STA_absx(0x0600); a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(sc)

    # ── Color RAM: green ──
    a.LDA_imm(0x05)
    a.LDX_imm(0x00)
    cf = a.pos
    a.STA_absx(0xD800); a.STA_absx(0xD900)
    a.STA_absx(0xDA00); a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(cf)

    # ── Static labels ──
    write_string_to_screen(a, "TURBO DETECT", SCREEN + 0 * ROW)
    write_string_to_screen(a, "CIA", SCREEN + 2 * ROW)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 2 * ROW + 14)
    write_string_to_screen(a, "MHZ", SCREEN + 2 * ROW + 17)
    write_string_to_screen(a, "VIC", SCREEN + 3 * ROW)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 3 * ROW + 14)
    write_string_to_screen(a, "MHZ", SCREEN + 3 * ROW + 17)
    write_string_to_screen(a, "TYPE", SCREEN + 5 * ROW)
    write_string_to_screen(a, "D0BC", SCREEN + 7 * ROW)
    write_string_to_screen(a, "PASS", SCREEN + 8 * ROW)

    # ── Colors ──
    # Title in light blue
    a.LDA_imm(0x0E)
    for col in range(12):
        a.STA_abs(0xD800 + col)

    # Yellow for hex values
    a.LDA_imm(0x07)
    for row in [2, 3]:
        for col in range(6, 10):
            a.STA_abs(0xD800 + row * ROW + col)
    for col in range(6, 8):
        a.STA_abs(0xD800 + 7 * ROW + col)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 8 * ROW + col)

    # Cyan for MHz
    a.LDA_imm(0x03)
    for row in [2, 3]:
        for col in range(12, 20):
            a.STA_abs(0xD800 + row * ROW + col)

    # White for TYPE value
    a.LDA_imm(0x01)
    for col in range(6, 20):
        a.STA_abs(0xD800 + 5 * ROW + col)

    # ── Screen on ──
    a.LDA_imm(0x1B); a.STA_abs(0xD011)

    # ════════════════════════════════════════
    # Main loop
    # ════════════════════════════════════════
    main_loop = a.pos

    # ── CIA measurement ──
    a.LDA_imm(0x02); a.STA_abs(0xD020)  # red border
    measure_cia_jsr = a.pos
    a.JSR(0x0000)  # placeholder
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_CIA_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_CIA_HI)
    display_hex_word(a, ZP_CIA_HI, ZP_CIA_LO, SCREEN + 2 * ROW + 6)

    # CIA MHz computation
    a.LDA_zp(ZP_CIA_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_CIA_HI); a.STA_zp(ZP_DIV_HI)
    compute_cia_mhz_jsr = a.pos
    a.JSR(0x0000)  # placeholder
    a.LDA_zp(ZP_MHZ_INT); a.STA_zp(ZP_CIA_MHZ)  # save for detection
    emit_mhz_display(a, ZP_MHZ_INT, ZP_MHZ_TENTH, SCREEN + 2 * ROW)

    # ── VIC measurement ──
    a.LDA_imm(0x05); a.STA_abs(0xD020)  # green border
    measure_vic_jsr = a.pos
    a.JSR(0x0000)  # placeholder
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_VIC_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_VIC_HI)
    display_hex_word(a, ZP_VIC_HI, ZP_VIC_LO, SCREEN + 3 * ROW + 6)

    # VIC MHz computation
    a.LDA_zp(ZP_VIC_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_VIC_HI); a.STA_zp(ZP_DIV_HI)
    compute_vic_mhz_jsr = a.pos
    a.JSR(0x0000)  # placeholder
    a.LDA_zp(ZP_MHZ_INT); a.STA_zp(ZP_VIC_MHZ)  # save for detection
    emit_mhz_display(a, ZP_MHZ_INT, ZP_MHZ_TENTH, SCREEN + 3 * ROW)

    # ── Type detection ──
    # Clear type area first (col 6-19 of row 5)
    a.LDA_imm(CHAR_MAP[' '])
    for col in range(6, 20):
        a.STA_abs(SCREEN + 5 * ROW + col)

    # Check CIA MHz >= 2 → extra cycles turbo
    a.LDA_zp(ZP_CIA_MHZ)
    a.CMP_imm(2)
    type_not_extra = a.BCC_fwd()
    # CIA >= 2: EXTRA CYC
    write_string_to_screen(a, "EXTRA CYC", SCREEN + 5 * ROW + 6)
    # Color: green
    a.LDA_imm(0x05)
    for col in range(6, 15):
        a.STA_abs(0xD800 + 5 * ROW + col)
    type_extra_done = a.JMP(0x0000)
    type_extra_done_pos = a.pos - 2

    a.fixup_branch(type_not_extra)

    # Check VIC MHz >= 2 → fast phi2
    a.LDA_zp(ZP_VIC_MHZ)
    a.CMP_imm(2)
    type_not_fast = a.BCC_fwd()
    # VIC >= 2 but CIA < 2: FAST PHI2
    write_string_to_screen(a, "FAST PHI2", SCREEN + 5 * ROW + 6)
    # Color: cyan
    a.LDA_imm(0x03)
    for col in range(6, 15):
        a.STA_abs(0xD800 + 5 * ROW + col)
    type_fast_done = a.JMP(0x0000)
    type_fast_done_pos = a.pos - 2

    a.fixup_branch(type_not_fast)

    # Neither: NONE
    write_string_to_screen(a, "NONE", SCREEN + 5 * ROW + 6)
    # Color: light grey
    a.LDA_imm(0x0F)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 5 * ROW + col)

    # Fixup JMPs
    type_end = a.addr
    a._buf[type_extra_done_pos] = type_end & 0xFF
    a._buf[type_extra_done_pos + 1] = (type_end >> 8) & 0xFF
    a._buf[type_fast_done_pos] = type_end & 0xFF
    a._buf[type_fast_done_pos + 1] = (type_end >> 8) & 0xFF

    # ── D0BC register ──
    a.LDA_abs(SCPU_DETECT)
    a.STA_zp(ZP_TMP)
    display_hex_byte(a, ZP_TMP, SCREEN + 7 * ROW + 6)

    # ── Pass counter ──
    a.INC_zp(ZP_PASS_LO)
    skip_hi = a.BNE_fwd()
    a.INC_zp(ZP_PASS_HI)
    a.fixup_branch(skip_hi)
    display_hex_word(a, ZP_PASS_HI, ZP_PASS_LO, SCREEN + 8 * ROW + 6)

    # Border black
    a.LDA_imm(0x00); a.STA_abs(0xD020)

    a.JMP(ROM_BASE + main_loop)

    # ════════════════════════════════════════
    # measure_cia subroutine
    # ════════════════════════════════════════
    measure_cia_addr = a.addr
    a._buf[measure_cia_jsr + 1] = measure_cia_addr & 0xFF
    a._buf[measure_cia_jsr + 2] = (measure_cia_addr >> 8) & 0xFF

    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()
    a.LDA_imm(0x00); a.STA_abs(CIA1_CRA)
    a.LDA_abs(CIA1_ICR)
    a.LDA_imm(0xFF)
    a.STA_abs(CIA1_TA_LO)
    a.STA_abs(CIA1_TA_HI)
    a.LDA_imm(0x00)
    a.STA_zp(ZP_RESULT_LO)
    a.STA_zp(ZP_RESULT_HI)
    a.LDA_imm(0x19); a.STA_abs(CIA1_CRA)

    # 17-cycle counting loop
    cia_count = a.pos
    a.INC_zp(ZP_RESULT_LO)
    cia_skip = a.BNE_fwd()
    a.INC_zp(ZP_RESULT_HI)
    a.fixup_branch(cia_skip)
    a.LDA_abs(CIA1_ICR)
    a.AND_imm(0x01)
    a.BEQ_back(cia_count)

    a.PLA(); a.TAY(); a.PLA(); a.TAX(); a.PLA()
    a.RTS()

    # ════════════════════════════════════════
    # measure_vic subroutine
    # ════════════════════════════════════════
    # Counts loop iterations from raster line 0 to raster line 200.
    # Result in ZP_RESULT_LO/HI.
    measure_vic_addr = a.addr
    a._buf[measure_vic_jsr + 1] = measure_vic_addr & 0xFF
    a._buf[measure_vic_jsr + 2] = (measure_vic_addr >> 8) & 0xFF

    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()

    # Wait for raster >= 200 (ensure we're past our target line)
    wait_bottom = a.pos
    a.LDA_abs(0xD012)
    a.CMP_imm(200)
    a.BCC_back(wait_bottom)

    # Wait for raster line 0 (MSB must be 0 too)
    wait_top = a.pos
    a.LDA_abs(0xD011)
    a.AND_imm(0x80)
    a.BNE_back(wait_top)       # wait while raster > 255
    a.LDA_abs(0xD012)
    a.CMP_imm(2)
    a.BCS_fwd()                # need BCS back to wait_top...
    # Hmm, wait_top might be too far for a branch. Let me restructure.

    # Actually, let me redo this more carefully
    a._buf = a._buf[:measure_vic_addr - ROM_BASE]  # rewind

    measure_vic_addr = a.addr
    a._buf[measure_vic_jsr + 1] = measure_vic_addr & 0xFF
    a._buf[measure_vic_jsr + 2] = (measure_vic_addr >> 8) & 0xFF

    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()

    # Wait for raster >= 210 (ensure we're past target line 200)
    wait_bot = a.pos
    a.LDA_abs(0xD012)
    a.CMP_imm(210)
    a.BCC_back(wait_bot)   # loop while raster < 210

    # Wait for raster < 2 with MSB=0 (top of frame)
    wait_top2 = a.pos
    a.LDA_abs(0xD011)
    a.AND_imm(0x80)
    bne_wait_top2 = a.pos
    a.raw(0xD0, 0x00)  # BNE placeholder -> wait_top2
    a.LDA_abs(0xD012)
    a.CMP_imm(2)
    bcs_wait_top2 = a.pos
    a.raw(0xB0, 0x00)  # BCS placeholder -> wait_top2
    # Fix up branches
    a._buf[bne_wait_top2 + 1] = (wait_top2 - (bne_wait_top2 + 2)) & 0xFF
    a._buf[bcs_wait_top2 + 1] = (wait_top2 - (bcs_wait_top2 + 2)) & 0xFF

    # At raster 0-1 now. Clear counter.
    a.LDA_imm(0x00)
    a.STA_zp(ZP_RESULT_LO)
    a.STA_zp(ZP_RESULT_HI)

    # Count until raster >= 200 (17-cycle loop, same as CIA)
    vic_count = a.pos
    a.INC_zp(ZP_RESULT_LO)       # 5
    vic_skip = a.BNE_fwd()        # 3
    a.INC_zp(ZP_RESULT_HI)       # 5
    a.fixup_branch(vic_skip)
    a.LDA_abs(0xD012)             # 4
    a.CMP_imm(200)                # 2
    a.BCC_back(vic_count)          # 3 = 17 total

    a.PLA(); a.TAY(); a.PLA(); a.TAX(); a.PLA()
    a.RTS()

    # ════════════════════════════════════════
    # compute_cia_mhz subroutine (divisor = 3855 = $0F0F)
    # ════════════════════════════════════════
    compute_cia_addr = a.addr
    a._buf[compute_cia_mhz_jsr + 1] = compute_cia_addr & 0xFF
    a._buf[compute_cia_mhz_jsr + 2] = (compute_cia_addr >> 8) & 0xFF
    emit_compute_mhz(a, 0x0F, 0x0F, max_mhz=20)  # 3855 = $0F0F

    # ════════════════════════════════════════
    # compute_vic_mhz subroutine (divisor = 765 = $02FD)
    # ════════════════════════════════════════
    compute_vic_addr = a.addr
    a._buf[compute_vic_mhz_jsr + 1] = compute_vic_addr & 0xFF
    a._buf[compute_vic_mhz_jsr + 2] = (compute_vic_addr >> 8) & 0xFF
    emit_compute_mhz(a, 0xFD, 0x02, max_mhz=70)  # 765 = $02FD

    # ════════════════════════════════════════
    # Font copy subroutine
    # ════════════════════════════════════════
    font_copy_addr = a.addr
    a._buf[font_copy_jsr + 1] = font_copy_addr & 0xFF
    a._buf[font_copy_jsr + 2] = (font_copy_addr >> 8) & 0xFF

    a.LDX_imm(0x00)
    fc_loop = a.pos
    lda_p0 = a.pos
    a.LDA_absx(0x0000)
    a.STA_absx(0x0800)
    lda_p1 = a.pos
    a.LDA_absx(0x0000)
    a.STA_absx(0x0900)
    a.INX()
    a.BNE_back(fc_loop)
    a.RTS()

    # ════════════════════════════════════════
    # Font data
    # ════════════════════════════════════════
    font_data = char_ram_data()
    font_rom_pos = a.pos
    font_rom_addr = ROM_BASE + font_rom_pos
    a.raw(*font_data[:512])

    a._buf[lda_p0 + 1] = font_rom_addr & 0xFF
    a._buf[lda_p0 + 2] = (font_rom_addr >> 8) & 0xFF
    a._buf[lda_p1 + 1] = (font_rom_addr + 256) & 0xFF
    a._buf[lda_p1 + 2] = ((font_rom_addr + 256) >> 8) & 0xFF

    return a


def make_rom(asm):
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6, \
        f"Code too large: {len(code)} bytes (max {ROM_SIZE - 6})"

    rom = bytearray(b"\xAA" * ROM_SIZE)
    rom[:len(code)] = code

    entry = ROM_BASE
    rom[0x1FFA] = entry & 0xFF; rom[0x1FFB] = (entry >> 8) & 0xFF
    rom[0x1FFC] = entry & 0xFF; rom[0x1FFD] = (entry >> 8) & 0xFF
    rom[0x1FFE] = entry & 0xFF; rom[0x1FFF] = (entry >> 8) & 0xFF
    return bytes(rom)


def make_crt(rom, name):
    assert len(rom) == ROM_SIZE
    sig = b"C64 CARTRIDGE   "
    hdr = sig + struct.pack(">I", 64) + struct.pack(">H", 0x0100)
    hdr += struct.pack(">H", 0) + b"\x01\x00" + b"\x00" * 6
    hdr += name.encode("ascii")[:32].ljust(32, b"\x00")

    chip = b"CHIP" + struct.pack(">I", 16 + ROM_SIZE)
    chip += struct.pack(">HHH", 0, 0, ROM_BASE) + struct.pack(">H", ROM_SIZE)
    return hdr + chip + rom


def main():
    asm = assemble()
    rom = make_rom(asm)
    crt = make_crt(rom, "TURBO DETECT")

    os.makedirs(OUT_DIR, exist_ok=True)
    stem = "turbo_detect"
    crt_path = os.path.join(OUT_DIR, f"{stem}.crt")
    bin_path = os.path.join(OUT_DIR, f"{stem}.bin")

    with open(crt_path, "wb") as f:
        f.write(crt)
    with open(bin_path, "wb") as f:
        f.write(rom)

    code = asm.build()
    print(f"Turbo Detect CRT")
    print(f"Code:   {len(code)} bytes at $E000")
    print(f"Output: {crt_path}")
    print(f"        {bin_path}")
    print()
    print("=== Dual-Reference Speed Detection ===")
    print(f"CIA ref:  65535-cycle timer, {CIA_TICKS_PER_MHZ} iters/MHz")
    print(f"VIC ref:  200 raster lines, {VIC_TICKS_PER_MHZ} iters/MHz (NTSC)")
    print()
    print("=== Type Detection Logic ===")
    print("CIA >= 2 MHz:                    EXTRA CYC (SuperCPU/MiSTer)")
    print("CIA ~1 MHz, VIC >= 2 MHz:        FAST PHI2 (Ultimate 64)")
    print("Both ~1 MHz:                     NONE")


if __name__ == "__main__":
    main()
