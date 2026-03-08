#!/usr/bin/env python3
"""
SCPU Speed Test CRT Generator
==============================
Creates an Ultimax-mode CRT that measures CPU speed using CIA Timer A.

Method:
  CIA1 Timer A runs at the system phi2 clock (~1MHz) regardless of CPU
  turbo mode. We load the timer with $FFFF (65535 cycles = ~65ms), start
  it in one-shot mode, then run a tight counting loop until the timer
  underflows. The iteration count is proportional to CPU speed.

  MHz = count * 17 / 65535 = count / 3855
  (since 65535 / 17 = 3855 exactly)

Test sequence (repeats continuously):
  1. Write $D07A to engage 1MHz mode, measure -> "SLOW" count
  2. Write $D07B to engage 20MHz mode, measure -> "FAST" count
  3. Compute MHz (xx.x) for both via division by 3855
  4. Read $D0B8 speed status register
  5. Display all values, increment pass counter, repeat

Screen layout (custom chars at $0800):
  Row 0:  "SPEED TEST"
  Row 2:  "SLOW  xxxx  xx.x MHZ"   (hex count + computed MHz)
  Row 3:  "FAST  xxxx  xx.x MHZ"   (hex count + computed MHz)
  Row 5:  "D0B8  xx"                (speed status register)
  Row 7:  "PASS  xxxx"              (measurement cycle counter)

Memory map:
  $00-$13: ZP variables
  $0400-$07E7: Screen RAM
  $0800-$0FFF: Character RAM (custom font)
  $DC04-$DC0E: CIA1 Timer A
  $D07A/$D07B: SuperCPU speed control (write-only)
  $D0B8: SuperCPU speed status (read)
  $E000-$FFFF: Cartridge ROM
"""

import struct
import os

ROM_SIZE = 0x2000
ROM_BASE = 0xE000
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# Screen layout
SCREEN = 0x0400
ROW = 40

# MHz calibration: at 1 MHz, the loop runs 65535/17 = 3855 iterations exactly
TICKS_PER_MHZ = 3855  # $0F0F

# ZP variables
ZP_RESULT_LO  = 0x02
ZP_RESULT_HI  = 0x03
ZP_SLOW_LO    = 0x04
ZP_SLOW_HI    = 0x05
ZP_FAST_LO    = 0x06
ZP_FAST_HI    = 0x07
ZP_PASS_LO    = 0x08
ZP_PASS_HI    = 0x09
ZP_TMP        = 0x0A
ZP_DIV_LO     = 0x0C
ZP_DIV_HI     = 0x0D
ZP_MHZ_INT    = 0x0E   # integer part of MHz (0-17)
ZP_MHZ_TENTH  = 0x0F   # tenths digit of MHz (0-9)
ZP_MUL_LO     = 0x10   # temp for multiply
ZP_MUL_HI     = 0x11

# CIA1 registers
CIA1_TA_LO = 0xDC04
CIA1_TA_HI = 0xDC05
CIA1_ICR   = 0xDC0D
CIA1_CRA   = 0xDC0E

# SuperCPU registers
SCPU_1MHZ  = 0xD07A
SCPU_20MHZ = 0xD07B
SCPU_STAT  = 0xD0B8

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
for c in 'GHILMNOPRSTUVWXZ:.':
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
    def CLI(self): return self.raw(0x58)
    def CLD(self): return self.raw(0xD8)
    def CLC(self): return self.raw(0x18)
    def SEC(self): return self.raw(0x38)
    def TXS(self): return self.raw(0x9A)
    def INX(self): return self.raw(0xE8)
    def INY(self): return self.raw(0xC8)
    def DEX(self): return self.raw(0xCA)
    def DEY(self): return self.raw(0x88)
    def NOP(self): return self.raw(0xEA)
    def PHA(self): return self.raw(0x48)
    def PLA(self): return self.raw(0x68)
    def TXA(self): return self.raw(0x8A)
    def TAX(self): return self.raw(0xAA)
    def TYA(self): return self.raw(0x98)
    def TAY(self): return self.raw(0xA8)
    def RTI(self): return self.raw(0x40)
    def RTS(self): return self.raw(0x60)
    def LSR_A(self): return self.raw(0x4A)
    def ASL_A(self): return self.raw(0x0A)
    def ROR_A(self): return self.raw(0x6A)

    # Immediate
    def LDA_imm(self, v): return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v): return self.raw(0xA2, v & 0xFF)
    def LDY_imm(self, v): return self.raw(0xA0, v & 0xFF)
    def CMP_imm(self, v): return self.raw(0xC9, v & 0xFF)
    def CPX_imm(self, v): return self.raw(0xE0, v & 0xFF)
    def CPY_imm(self, v): return self.raw(0xC0, v & 0xFF)
    def ADC_imm(self, v): return self.raw(0x69, v & 0xFF)
    def AND_imm(self, v): return self.raw(0x29, v & 0xFF)
    def ORA_imm(self, v): return self.raw(0x09, v & 0xFF)
    def EOR_imm(self, v): return self.raw(0x49, v & 0xFF)
    def SBC_imm(self, v): return self.raw(0xE9, v & 0xFF)

    # Zero page
    def LDA_zp(self, a): return self.raw(0xA5, a & 0xFF)
    def STA_zp(self, a): return self.raw(0x85, a & 0xFF)
    def STX_zp(self, a): return self.raw(0x86, a & 0xFF)
    def INC_zp(self, a): return self.raw(0xE6, a & 0xFF)
    def DEC_zp(self, a): return self.raw(0xC6, a & 0xFF)
    def SBC_zp(self, a): return self.raw(0xE5, a & 0xFF)
    def ORA_zp(self, a): return self.raw(0x05, a & 0xFF)
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

    def fixup_branch(self, placeholder_pos):
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127, f"Fwd branch offset {off} out of range"
        self._buf[placeholder_pos + 1] = off


def display_hex_byte(a, zp_src, screen_pos):
    """Emit code to display a ZP byte as 2 hex digits at screen_pos."""
    a.LDA_zp(zp_src)
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(screen_pos)
    a.LDA_zp(zp_src)
    a.AND_imm(0x0F)
    a.STA_abs(screen_pos + 1)


def display_hex_word(a, zp_hi, zp_lo, screen_pos):
    """Emit code to display a 16-bit ZP value as 4 hex digits."""
    display_hex_byte(a, zp_hi, screen_pos)
    display_hex_byte(a, zp_lo, screen_pos + 2)


def assemble():
    a = Asm6502()

    # ── Init ──
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()

    # 6510 processor port
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # Init ZP vars
    a.LDA_imm(0x00)
    for zp in [ZP_RESULT_LO, ZP_RESULT_HI, ZP_SLOW_LO, ZP_SLOW_HI,
               ZP_FAST_LO, ZP_FAST_HI, ZP_PASS_LO, ZP_PASS_HI,
               ZP_MHZ_INT, ZP_MHZ_TENTH]:
        a.STA_zp(zp)

    # ── VIC-II setup ──
    a.LDA_imm(0x0B); a.STA_abs(0xD011)   # screen off
    a.LDA_imm(0x12); a.STA_abs(0xD018)   # screen@$0400, chars@$0800
    a.LDA_imm(0x00); a.STA_abs(0xD020)   # black border
    a.LDA_imm(0x00); a.STA_abs(0xD021)   # black background
    a.LDA_imm(0xC8); a.STA_abs(0xD016)   # 40 col

    # ── Clear char RAM ──
    a.LDA_imm(0x00)
    a.LDX_imm(0x00)
    cc = a.pos
    for page in range(0x08, 0x10):
        a.STA_absx(page * 256)
    a.INX()
    a.BNE_back(cc)

    # ── Copy font from ROM table ──
    font_copy_jsr = a.pos
    a.JSR(0x0000)  # placeholder

    # ── Clear screen ──
    a.LDA_imm(CHAR_MAP[' '])
    a.LDX_imm(0x00)
    sc = a.pos
    a.STA_absx(0x0400); a.STA_absx(0x0500)
    a.STA_absx(0x0600); a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(sc)

    # ── Color RAM: white ──
    a.LDA_imm(0x01)
    a.LDX_imm(0x00)
    cf = a.pos
    a.STA_absx(0xD800); a.STA_absx(0xD900)
    a.STA_absx(0xDA00); a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(cf)

    # ── Draw static labels ──
    # Row 0: title
    for i, code in enumerate(encode_string("SPEED TEST")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 0 * ROW + i)

    # Row 2: "SLOW" label + static "." and "MHZ"
    for i, code in enumerate(encode_string("SLOW")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 2 * ROW + i)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 2 * ROW + 14)
    for i, code in enumerate(encode_string("MHZ")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 2 * ROW + 17 + i)

    # Row 3: "FAST" label + static "." and "MHZ"
    for i, code in enumerate(encode_string("FAST")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 3 * ROW + i)
    a.LDA_imm(CHAR_MAP['.']); a.STA_abs(SCREEN + 3 * ROW + 14)
    for i, code in enumerate(encode_string("MHZ")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 3 * ROW + 17 + i)

    # Row 5: "D0B8"
    for i, code in enumerate(encode_string("D0B8")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 5 * ROW + i)

    # Row 7: "PASS"
    for i, code in enumerate(encode_string("PASS")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 7 * ROW + i)

    # ── Colors ──
    # Green for labels (rows 0-8)
    a.LDA_imm(0x05)  # green
    a.LDX_imm(0x00)
    lc = a.pos
    a.STA_absx(0xD800)
    a.INX()
    a.BNE_back(lc)
    a.LDX_imm(0x00)
    lc2 = a.pos
    a.STA_absx(0xD900)
    a.INX()
    a.CPX_imm(0x68)
    a.BNE_back(lc2)

    # Yellow for hex count positions (col 6-9)
    a.LDA_imm(0x07)  # yellow
    for row in [2, 3]:
        for col in range(6, 10):
            a.STA_abs(0xD800 + row * ROW + col)
    for col in range(6, 8):
        a.STA_abs(0xD800 + 5 * ROW + col)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 7 * ROW + col)

    # Cyan for MHz display (col 12-19) — stands out
    a.LDA_imm(0x03)  # cyan
    for row in [2, 3]:
        for col in range(12, 20):
            a.STA_abs(0xD800 + row * ROW + col)

    # Title in light blue
    a.LDA_imm(0x0E)  # light blue
    for col in range(10):
        a.STA_abs(0xD800 + col)

    # ── Screen on ──
    a.LDA_imm(0x1B); a.STA_abs(0xD011)

    # ══════════════════════════════════════════════════════
    # Main measurement loop
    # ══════════════════════════════════════════════════════

    main_loop = a.pos

    # ── Step 1: Engage 1MHz, measure ──
    a.LDA_imm(0x00); a.STA_abs(SCPU_1MHZ)  # write $D07A
    a.LDX_imm(0x10)
    d1 = a.pos
    a.DEX(); a.BNE_back(d1)

    # Border = red during slow measurement
    a.LDA_imm(0x02); a.STA_abs(0xD020)

    measure1_jsr = a.pos
    a.JSR(0x0000)  # placeholder -> measure_speed

    # Store slow result
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_SLOW_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_SLOW_HI)

    # Display hex count at row 2, col 6
    display_hex_word(a, ZP_SLOW_HI, ZP_SLOW_LO, SCREEN + 2 * ROW + 6)

    # Compute and display MHz for slow: copy count to DIV, call compute_mhz
    a.LDA_zp(ZP_SLOW_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_SLOW_HI); a.STA_zp(ZP_DIV_HI)
    compute_mhz1_jsr = a.pos
    a.JSR(0x0000)  # placeholder -> compute_mhz

    # Display MHz at row 2: [tens][ones].[tenth] at col 12-15
    # Tens digit (or space if 0)
    a.LDA_zp(ZP_MHZ_INT)
    a.CMP_imm(10)
    tens_skip1 = a.BCC_fwd()
    # >= 10: compute tens and ones
    a.LDX_imm(0x00)  # tens counter
    tens_loop1 = a.pos
    a.CMP_imm(10)
    tens_done1 = a.BCC_fwd()
    a.SBC_imm(10)  # carry already set from CMP >= 10
    a.INX()
    a.JMP(ROM_BASE + tens_loop1)
    a.fixup_branch(tens_done1)
    # X = tens digit, A = ones digit
    a.STA_abs(SCREEN + 2 * ROW + 13)  # ones
    a.TXA()
    a.STA_abs(SCREEN + 2 * ROW + 12)  # tens
    tens_end1 = a.JMP(0x0000)  # placeholder -> skip single-digit path
    tens_end1_pos = a.pos - 2  # address of the jump target bytes

    a.fixup_branch(tens_skip1)
    # < 10: space + ones
    a.LDA_imm(CHAR_MAP[' '])
    a.STA_abs(SCREEN + 2 * ROW + 12)  # space for tens
    a.LDA_zp(ZP_MHZ_INT)
    a.STA_abs(SCREEN + 2 * ROW + 13)  # ones

    # Fixup the JMP that skips single-digit path
    after_tens1 = a.addr
    a._buf[tens_end1_pos] = after_tens1 & 0xFF
    a._buf[tens_end1_pos + 1] = (after_tens1 >> 8) & 0xFF

    # Tenths digit at col 15
    a.LDA_zp(ZP_MHZ_TENTH)
    a.STA_abs(SCREEN + 2 * ROW + 15)

    # ── Step 2: Engage 20MHz, measure ──
    a.LDA_imm(0x00); a.STA_abs(SCPU_20MHZ)  # write $D07B
    a.LDX_imm(0x10)
    d2 = a.pos
    a.DEX(); a.BNE_back(d2)

    # Border = green during fast measurement
    a.LDA_imm(0x05); a.STA_abs(0xD020)

    measure2_jsr = a.pos
    a.JSR(0x0000)  # placeholder -> measure_speed

    # Store fast result
    a.LDA_zp(ZP_RESULT_LO); a.STA_zp(ZP_FAST_LO)
    a.LDA_zp(ZP_RESULT_HI); a.STA_zp(ZP_FAST_HI)

    # Display hex count at row 3, col 6
    display_hex_word(a, ZP_FAST_HI, ZP_FAST_LO, SCREEN + 3 * ROW + 6)

    # Compute and display MHz for fast
    a.LDA_zp(ZP_FAST_LO); a.STA_zp(ZP_DIV_LO)
    a.LDA_zp(ZP_FAST_HI); a.STA_zp(ZP_DIV_HI)
    compute_mhz2_jsr = a.pos
    a.JSR(0x0000)  # placeholder -> compute_mhz

    # Display MHz at row 3: [tens][ones].[tenth] at col 12-15
    a.LDA_zp(ZP_MHZ_INT)
    a.CMP_imm(10)
    tens_skip2 = a.BCC_fwd()
    a.LDX_imm(0x00)
    tens_loop2 = a.pos
    a.CMP_imm(10)
    tens_done2 = a.BCC_fwd()
    a.SBC_imm(10)
    a.INX()
    a.JMP(ROM_BASE + tens_loop2)
    a.fixup_branch(tens_done2)
    a.STA_abs(SCREEN + 3 * ROW + 13)
    a.TXA()
    a.STA_abs(SCREEN + 3 * ROW + 12)
    tens_end2 = a.JMP(0x0000)
    tens_end2_pos = a.pos - 2

    a.fixup_branch(tens_skip2)
    a.LDA_imm(CHAR_MAP[' '])
    a.STA_abs(SCREEN + 3 * ROW + 12)
    a.LDA_zp(ZP_MHZ_INT)
    a.STA_abs(SCREEN + 3 * ROW + 13)

    after_tens2 = a.addr
    a._buf[tens_end2_pos] = after_tens2 & 0xFF
    a._buf[tens_end2_pos + 1] = (after_tens2 >> 8) & 0xFF

    a.LDA_zp(ZP_MHZ_TENTH)
    a.STA_abs(SCREEN + 3 * ROW + 15)

    # ── Step 3: Read $D0B8 speed status ──
    a.LDA_abs(SCPU_STAT)
    a.STA_zp(ZP_TMP)
    display_hex_byte(a, ZP_TMP, SCREEN + 5 * ROW + 6)

    # ── Step 4: Increment pass counter ──
    a.INC_zp(ZP_PASS_LO)
    skip_hi = a.BNE_fwd()
    a.INC_zp(ZP_PASS_HI)
    a.fixup_branch(skip_hi)
    display_hex_word(a, ZP_PASS_HI, ZP_PASS_LO, SCREEN + 7 * ROW + 6)

    # Border back to black
    a.LDA_imm(0x00); a.STA_abs(0xD020)

    a.JMP(ROM_BASE + main_loop)

    # ══════════════════════════════════════════════════════
    # measure_speed subroutine
    # ══════════════════════════════════════════════════════
    # Uses CIA1 Timer A ($FFFF countdown, one-shot).
    # Counts iterations of a tight loop until timer underflows.
    # Result: ZP_RESULT_LO/HI = iteration count.
    # Clobbers: A. Preserves X/Y.

    measure_addr = a.addr
    a._buf[measure1_jsr + 1] = measure_addr & 0xFF
    a._buf[measure1_jsr + 2] = (measure_addr >> 8) & 0xFF
    a._buf[measure2_jsr + 1] = measure_addr & 0xFF
    a._buf[measure2_jsr + 2] = (measure_addr >> 8) & 0xFF

    # Save X/Y
    a.PHA(); a.TXA(); a.PHA(); a.TYA(); a.PHA()

    # Stop timer
    a.LDA_imm(0x00); a.STA_abs(CIA1_CRA)
    # Clear pending ICR flags
    a.LDA_abs(CIA1_ICR)
    # Load timer latch: $FFFF
    a.LDA_imm(0xFF)
    a.STA_abs(CIA1_TA_LO)
    a.STA_abs(CIA1_TA_HI)
    # Clear result counter
    a.LDA_imm(0x00)
    a.STA_zp(ZP_RESULT_LO)
    a.STA_zp(ZP_RESULT_HI)
    # Start timer: one-shot + force load + start (bits 0,3,4 = $19)
    a.LDA_imm(0x19); a.STA_abs(CIA1_CRA)

    # Counting loop: 17 cycles per iteration (no carry)
    count_loop = a.pos
    a.INC_zp(ZP_RESULT_LO)       # 5
    count_skip = a.BNE_fwd()      # 3 (taken) / 2 (fall)
    a.INC_zp(ZP_RESULT_HI)       # 5 (rare)
    a.fixup_branch(count_skip)
    a.LDA_abs(CIA1_ICR)           # 4
    a.AND_imm(0x01)               # 2
    a.BEQ_back(count_loop)        # 3

    # Restore X/Y
    a.PLA(); a.TAY(); a.PLA(); a.TAX(); a.PLA()
    a.RTS()

    # ══════════════════════════════════════════════════════
    # compute_mhz subroutine
    # ══════════════════════════════════════════════════════
    # Input:  ZP_DIV_LO/HI = iteration count
    # Output: ZP_MHZ_INT = integer MHz (0-17)
    #         ZP_MHZ_TENTH = tenths digit (0-9)
    # Method: divide by 3855 ($0F0F) via repeated subtraction
    # Clobbers: A, X

    compute_mhz_addr = a.addr
    a._buf[compute_mhz1_jsr + 1] = compute_mhz_addr & 0xFF
    a._buf[compute_mhz1_jsr + 2] = (compute_mhz_addr >> 8) & 0xFF
    a._buf[compute_mhz2_jsr + 1] = compute_mhz_addr & 0xFF
    a._buf[compute_mhz2_jsr + 2] = (compute_mhz_addr >> 8) & 0xFF

    # ── Integer part: count / 3855 ──
    a.LDA_imm(0x00)
    a.STA_zp(ZP_MHZ_INT)

    int_loop = a.pos
    # Tentative subtract: DIV -= 3855 ($0F0F)
    a.SEC()
    a.LDA_zp(ZP_DIV_LO)
    a.SBC_imm(0x0F)        # low byte of 3855
    a.TAX()                 # save tentative low in X
    a.LDA_zp(ZP_DIV_HI)
    a.SBC_imm(0x0F)        # high byte of 3855
    int_borrow = a.BCC_fwd()  # borrow -> count < 3855, done
    # Commit subtraction
    a.STA_zp(ZP_DIV_HI)
    a.STX_zp(ZP_DIV_LO)
    a.INC_zp(ZP_MHZ_INT)
    # Safety cap at 19
    a.LDA_zp(ZP_MHZ_INT)
    a.CMP_imm(20)
    int_cap = a.BCS_fwd()
    a.JMP(ROM_BASE + int_loop)

    a.fixup_branch(int_borrow)
    a.fixup_branch(int_cap)
    # ZP_DIV_LO/HI now = remainder (0..3854)

    # ── Tenths: remainder * 10 / 3855 ──
    # Multiply remainder by 10 using repeated addition (10 iterations)
    # Max remainder = 3854, * 10 = 38540 = $968C, fits in 16 bits
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

    # Divide (remainder * 10) by 3855 -> tenths digit
    a.LDA_imm(0x00)
    a.STA_zp(ZP_MHZ_TENTH)

    tenth_loop = a.pos
    a.SEC()
    a.LDA_zp(ZP_DIV_LO)
    a.SBC_imm(0x0F)
    a.TAX()
    a.LDA_zp(ZP_DIV_HI)
    a.SBC_imm(0x0F)
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

    # ══════════════════════════════════════════════════════
    # Font copy subroutine
    # ══════════════════════════════════════════════════════
    font_copy_addr = a.addr
    a._buf[font_copy_jsr + 1] = font_copy_addr & 0xFF
    a._buf[font_copy_jsr + 2] = (font_copy_addr >> 8) & 0xFF

    a.LDX_imm(0x00)
    fc_loop = a.pos
    lda_p0 = a.pos
    a.LDA_absx(0x0000)  # placeholder -> font page 0
    a.STA_absx(0x0800)
    lda_p1 = a.pos
    a.LDA_absx(0x0000)  # placeholder -> font page 1
    a.STA_absx(0x0900)
    a.INX()
    a.BNE_back(fc_loop)
    a.RTS()

    # ══════════════════════════════════════════════════════
    # Font table data
    # ══════════════════════════════════════════════════════
    font_data = char_ram_data()
    font_rom_pos = a.pos
    font_rom_addr = ROM_BASE + font_rom_pos
    a.raw(*font_data[:512])

    # Fixup font copy addresses
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
    rom[0x1FFA] = entry & 0xFF; rom[0x1FFB] = (entry >> 8) & 0xFF  # NMI
    rom[0x1FFC] = entry & 0xFF; rom[0x1FFD] = (entry >> 8) & 0xFF  # RESET
    rom[0x1FFE] = entry & 0xFF; rom[0x1FFF] = (entry >> 8) & 0xFF  # IRQ
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
    crt = make_crt(rom, "SCPU SPEED TEST")

    os.makedirs(OUT_DIR, exist_ok=True)
    stem = "scpu_speedtest"
    crt_path = os.path.join(OUT_DIR, f"{stem}.crt")
    bin_path = os.path.join(OUT_DIR, f"{stem}.bin")

    with open(crt_path, "wb") as f:
        f.write(crt)
    with open(bin_path, "wb") as f:
        f.write(rom)

    code = asm.build()
    print(f"SCPU Speed Test CRT")
    print(f"Code:   {len(code)} bytes at $E000")
    print(f"Output: {crt_path}")
    print(f"        {bin_path}")
    print()
    print("=== How It Works ===")
    print("Uses CIA1 Timer A as a fixed ~1MHz wall-clock reference.")
    print("Counts iterations of a tight loop (17 cycles/iter) during a")
    print("$FFFF (65535) cycle countdown. More iterations = faster CPU.")
    print("MHz = count / 3855  (since 65535 / 17 = 3855 exactly)")
    print()
    print("=== Test Sequence (repeats) ===")
    print("1. Write $D07A -> engage 1MHz, measure (red border)")
    print("2. Write $D07B -> engage 20MHz, measure (green border)")
    print("3. Compute xx.x MHz for both, read $D0B8, display all")
    print()
    print("=== Screen Layout ===")
    print("  SLOW  xxxx  xx.x MHZ   Hex count + computed MHz at 1MHz mode")
    print("  FAST  xxxx  xx.x MHZ   Hex count + computed MHz at turbo")
    print("  D0B8  xx                Speed status register")
    print("  PASS  xxxx              Test cycle counter")
    print()
    print("=== Calibration ===")
    print(f"  TICKS_PER_MHZ = {TICKS_PER_MHZ} ($%04X)" % TICKS_PER_MHZ)
    print("  At 1 MHz: count ~ 3855 -> display  1.0 MHZ")
    print("  At 3.2x:  count ~12336 -> display  3.2 MHZ")
    print("  Max display: 17.0 MHZ (16-bit counter limit)")


if __name__ == "__main__":
    main()
