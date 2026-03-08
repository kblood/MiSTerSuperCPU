#!/usr/bin/env python3
"""
SCPU Diagnostic Counter CRT Generator
======================================
Creates an Ultimax-mode CRT that:
1. Triggers the '@' artifact via indirect-indexed reads (like M8)
2. Periodically reads the 4 diagnostic counters ($D07C-$D080)
3. Displays counter values as hex digits on screen
4. Auto-clears counters each sampling cycle

Diagnostic counters (implemented in fpga64_sid_iec.vhd):
  $D07C: Hold fire count (hold gate activations at CPUF)
  $D07D: Mismatch count (held != live vicDi at CPUF)
  $D07F: Held-zero count (held data = $00 at CPUF)
  $D080: Live-zero count (live vicDi = $00 at CPUF)

Screen layout (using RAM chars at $0800):
  Row 0:  "SCPU DIAG COUNTERS"
  Row 2:  "FIRE  xx"       ($D07C)
  Row 3:  "MISM  xx"       ($D07D)
  Row 4:  "HZRO  xx"       ($D07F)
  Row 5:  "LZRO  xx"       ($D080)
  Row 7:  "PASS  xxxx"     (sample iteration count)
  Row 9-24: filled with $01 (white blocks for artifact visibility)

Interpretation:
  HZRO high + LZRO high = SDRAM actually corrupted
  HZRO low  + LZRO high = Hold register works but VIC not seeing it
  HZRO high + LZRO low  = Early CE reads wrong data
  HZRO low  + LZRO low  = '@' has different cause

Memory map:
  $00-$0F: ZP variables
  $0400-$07E7: Screen RAM
  $0800-$0FFF: Character RAM (custom font for hex digits + labels)
  $D07C-$D080: Diagnostic counter registers (read/write)
  $E000-$FFFF: Cartridge ROM
"""

import struct
import os
import sys

ROM_SIZE = 0x2000
ROM_BASE = 0xE000
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# Screen layout constants
SCREEN = 0x0400
ROW = 40  # bytes per row

# ZP variables
ZP_PTR_LO = 0x04
ZP_PTR_HI = 0x05
ZP_DELAY_LO = 0x06
ZP_DELAY_HI = 0x07
ZP_PASS_LO = 0x08
ZP_PASS_HI = 0x09
ZP_TMP = 0x0A

# Diagnostic counter addresses
DIAG_FIRE = 0xD07C
DIAG_MISM = 0xD07D
DIAG_HZRO = 0xD07F
DIAG_LZRO = 0xD080

# 5x7 pixel font for hex digits 0-F and label chars
# Each char is 8 bytes (8 rows of 8 pixels, top-aligned)
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
    'W': [0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00],
    'X': [0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00],
    'Z': [0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00],
    ':': [0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00],
    '+': [0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00],
    '=': [0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00],
    # Solid block
    '#': [0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF],
}

# Character allocation table: maps chars to screen codes
# Screen codes 0x00-0x0F = hex digits '0'-'F'
# Screen codes 0x10+ = label characters
CHAR_MAP = {}
_next_code = 0
for c in '0123456789ABCDEF ':
    CHAR_MAP[c] = _next_code
    _next_code += 1
# 0x00='0', ..., 0x0F='F', 0x10=' '
# Now label chars
for c in 'GHILMNOPRSTUWXZ:+=':
    if c not in CHAR_MAP:
        CHAR_MAP[c] = _next_code
        _next_code += 1
# Solid block for fill area
CHAR_MAP['#'] = _next_code
_next_code += 1


def char_ram_data():
    """Build character RAM content: 8 bytes per char, indexed by screen code."""
    data = bytearray(2048)  # 256 chars * 8 bytes
    for ch, code in CHAR_MAP.items():
        if ch in FONT:
            offset = code * 8
            for i, b in enumerate(FONT[ch]):
                data[offset + i] = b
    return data


def encode_string(s):
    """Convert ASCII string to screen codes using CHAR_MAP."""
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

    # Zero page
    def LDA_zp(self, a): return self.raw(0xA5, a & 0xFF)
    def STA_zp(self, a): return self.raw(0x85, a & 0xFF)
    def INC_zp(self, a): return self.raw(0xE6, a & 0xFF)
    def DEC_zp(self, a): return self.raw(0xC6, a & 0xFF)

    # Zero page indirect indexed
    def LDA_indy(self, zp): return self.raw(0xB1, zp & 0xFF)
    def STA_indy(self, zp): return self.raw(0x91, zp & 0xFF)

    # Absolute
    def LDA_abs(self, a): return self.raw(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_abs(self, a): return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)

    # Jumps
    def JMP(self, addr): return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)
    def JSR(self, addr): return self.raw(0x20, addr & 0xFF, (addr >> 8) & 0xFF)
    def RTS(self): return self.raw(0x60)

    # Branches
    def BNE_back(self, target_buf_pos):
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0, f"BNE back out of range: {off}"
        return self.raw(0xD0, off & 0xFF)

    def BEQ_back(self, target_buf_pos):
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0, f"BEQ back out of range: {off}"
        return self.raw(0xF0, off & 0xFF)

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

    def BCC_back(self, target_buf_pos):
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0, f"BCC back out of range: {off}"
        return self.raw(0x90, off & 0xFF)

    def BCS_fwd(self):
        idx = self.pos
        self.raw(0xB0, 0x00)
        return idx

    def fixup_branch(self, placeholder_pos):
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127, f"Fwd branch offset {off} out of range"
        self._buf[placeholder_pos + 1] = off


def assemble():
    """Assemble the diagnostic counter test."""
    a = Asm6502()

    # ── Init ──
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()

    # 6510 processor port
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # Init ZP vars
    a.LDA_imm(0x00)
    a.STA_zp(ZP_PASS_LO)
    a.STA_zp(ZP_PASS_HI)

    # ── VIC-II setup ──
    a.LDA_imm(0x0B); a.STA_abs(0xD011)   # screen off
    a.LDA_imm(0x12); a.STA_abs(0xD018)   # screen@$0400, chars@$0800
    a.LDA_imm(0x00); a.STA_abs(0xD020)   # black border
    a.LDA_imm(0x00); a.STA_abs(0xD021)   # black background
    a.LDA_imm(0xC8); a.STA_abs(0xD016)   # 40 col

    # ── Character RAM at $0800: copy from ROM table ──
    # First clear all char RAM
    a.LDA_imm(0x00)
    a.LDX_imm(0x00)
    char_clear = a.pos
    a.STA_absx(0x0800)
    a.STA_absx(0x0900)
    a.STA_absx(0x0A00)
    a.STA_absx(0x0B00)
    a.STA_absx(0x0C00)
    a.STA_absx(0x0D00)
    a.STA_absx(0x0E00)
    a.STA_absx(0x0F00)
    a.INX()
    a.BNE_back(char_clear)

    # Copy font data from ROM table to char RAM
    # Font table will be placed at a known ROM address (we'll record it)
    # For now, use JSR to a copy routine that we'll place after main code
    # Actually, let's inline it: copy from ROM table using absolute indexed

    # We'll emit the font copy as a subroutine call later.
    # For now, record where we need the JSR target.
    font_copy_jsr = a.pos
    a.JSR(0x0000)  # placeholder — will fixup

    # ── Clear screen RAM ──
    a.LDA_imm(CHAR_MAP[' '])  # space
    a.LDX_imm(0x00)
    scr_clear = a.pos
    a.STA_absx(0x0400)
    a.STA_absx(0x0500)
    a.STA_absx(0x0600)
    a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(scr_clear)

    # ── Fill color RAM with WHITE ──
    a.LDA_imm(0x01)  # white
    a.LDX_imm(0x00)
    col_fill = a.pos
    a.STA_absx(0xD800)
    a.STA_absx(0xD900)
    a.STA_absx(0xDA00)
    a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(col_fill)

    # ── Draw static labels ──
    # Row 0: "SCPU DIAG"
    for i, code in enumerate(encode_string("SCPU DIAG")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 0 * ROW + i)

    # Row 2: "FIRE:"
    for i, code in enumerate(encode_string("FIRE:")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 2 * ROW + i)

    # Row 3: "MISM:"
    for i, code in enumerate(encode_string("MISM:")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 3 * ROW + i)

    # Row 4: "HZRO:"
    for i, code in enumerate(encode_string("HZRO:")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 4 * ROW + i)

    # Row 5: "LZRO:"
    for i, code in enumerate(encode_string("LZRO:")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 5 * ROW + i)

    # Row 7: "PASS:"
    for i, code in enumerate(encode_string("PASS:")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 7 * ROW + i)

    # Fill rows 10-24 with solid block for artifact visibility
    block_code = CHAR_MAP['#']
    a.LDA_imm(block_code)
    a.LDX_imm(0x00)
    fill_bottom = a.pos
    # Rows 10-13 ($0400 + 10*40 = $0590)
    a.STA_absx(SCREEN + 10 * ROW)       # $0590
    a.STA_absx(SCREEN + 10 * ROW + 256) # $0690
    a.INX()
    a.BNE_back(fill_bottom)
    # Handle remaining rows with smaller loop
    a.LDX_imm(0x00)
    fill_rest = a.pos
    a.STA_absx(SCREEN + 10 * ROW + 512) # $0790 (partial)
    a.INX()
    a.CPX_imm(0x58)  # up to row 24 end = $07E7 - $0790 + 1 = 88 = $58
    a.BNE_back(fill_rest)

    # Color the label area (rows 0-7) — use green for labels
    a.LDA_imm(0x05)  # green
    a.LDX_imm(0x00)
    lbl_col = a.pos
    a.STA_absx(0xD800)  # first 256 bytes of color RAM covers rows 0-6+
    a.INX()
    a.BNE_back(lbl_col)
    # Counter value positions: use yellow
    for row in range(2, 6):
        a.LDA_imm(0x07)  # yellow
        for col in range(6, 8):
            a.STA_abs(0xD800 + row * ROW + col)
    # Pass counter: yellow
    a.LDA_imm(0x07)
    for col in range(6, 10):
        a.STA_abs(0xD800 + 7 * ROW + col)

    # ── Turn screen on ──
    a.LDA_imm(0x1B); a.STA_abs(0xD011)
    a.LDA_imm(0x05); a.STA_abs(0xD020)  # green border = init complete

    # ════════════════════════════════════════════════════════════
    # Main loop: trigger artifact + sample counters
    # ════════════════════════════════════════════════════════════

    main_loop = a.pos

    # Step 1: Clear diagnostic counters (write any value to $D07C)
    a.LDA_imm(0x00)
    a.STA_abs(DIAG_FIRE)

    # Step 2: Run indirect-indexed reads for ~1 second to trigger artifact
    # Outer loop: 256 iterations of inner (24 lines * 40 cols = 960 reads each)
    # Total: 256 * 960 = ~245K indirect reads
    a.LDX_imm(0x00)  # outer counter (256 iters)

    outer_loop = a.pos
    # Set pointer to $0400 (screen RAM)
    a.LDA_imm(0x00); a.STA_zp(ZP_PTR_LO)
    a.LDA_imm(0x04); a.STA_zp(ZP_PTR_HI)

    # Inner: 4 "lines" of 40 indirect reads
    a.LDY_imm(0x00)
    inner_loop = a.pos
    a.LDA_indy(ZP_PTR_LO)  # THE trigger: indirect-indexed read
    a.INY()
    a.CPY_imm(160)  # 4 * 40 = 160 reads per inner iter
    a.BCC_back(inner_loop)

    a.INX()
    a.BNE_back(outer_loop)

    # Step 3: Read and display the 4 counters
    # Read $D07C (fire) → display at row 2, col 6-7
    a.LDA_abs(DIAG_FIRE)
    a.STA_zp(ZP_TMP)
    # High nibble
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(SCREEN + 2 * ROW + 6)
    # Low nibble
    a.LDA_zp(ZP_TMP)
    a.AND_imm(0x0F)
    a.STA_abs(SCREEN + 2 * ROW + 7)

    # Read $D07D (mismatch) → row 3, col 6-7
    a.LDA_abs(DIAG_MISM)
    a.STA_zp(ZP_TMP)
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(SCREEN + 3 * ROW + 6)
    a.LDA_zp(ZP_TMP)
    a.AND_imm(0x0F)
    a.STA_abs(SCREEN + 3 * ROW + 7)

    # Read $D07F (held-zero) → row 4, col 6-7
    a.LDA_abs(DIAG_HZRO)
    a.STA_zp(ZP_TMP)
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(SCREEN + 4 * ROW + 6)
    a.LDA_zp(ZP_TMP)
    a.AND_imm(0x0F)
    a.STA_abs(SCREEN + 4 * ROW + 7)

    # Read $D080 (live-zero) → row 5, col 6-7
    a.LDA_abs(DIAG_LZRO)
    a.STA_zp(ZP_TMP)
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(SCREEN + 5 * ROW + 6)
    a.LDA_zp(ZP_TMP)
    a.AND_imm(0x0F)
    a.STA_abs(SCREEN + 5 * ROW + 7)

    # Step 4: Increment and display pass counter (16-bit)
    a.INC_zp(ZP_PASS_LO)
    skip_hi_inc = a.BNE_fwd()
    a.INC_zp(ZP_PASS_HI)
    a.fixup_branch(skip_hi_inc)

    # Display pass_hi high nibble
    a.LDA_zp(ZP_PASS_HI)
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(SCREEN + 7 * ROW + 6)
    # Display pass_hi low nibble
    a.LDA_zp(ZP_PASS_HI)
    a.AND_imm(0x0F)
    a.STA_abs(SCREEN + 7 * ROW + 7)
    # Display pass_lo high nibble
    a.LDA_zp(ZP_PASS_LO)
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.STA_abs(SCREEN + 7 * ROW + 8)
    # Display pass_lo low nibble
    a.LDA_zp(ZP_PASS_LO)
    a.AND_imm(0x0F)
    a.STA_abs(SCREEN + 7 * ROW + 9)

    # Loop forever
    a.JMP(ROM_BASE + main_loop)

    # ════════════════════════════════════════════════════════════
    # Font copy subroutine
    # ════════════════════════════════════════════════════════════
    font_copy_addr = a.addr
    # Fixup the JSR placeholder
    a._buf[font_copy_jsr + 1] = font_copy_addr & 0xFF
    a._buf[font_copy_jsr + 2] = (font_copy_addr >> 8) & 0xFF

    # Copy font table (at end of ROM) to $0800-$09FF (first 64 chars * 8 = 512 bytes)
    # Font table ROM address will be recorded, copy 2 pages
    # We use self-modifying code... but we're in ROM. Use absolute indexed instead.
    # Font table is at a known ROM address. Copy 512 bytes (64 chars * 8 bytes).
    font_table_addr = None  # will be set after we know the position

    # Use two loops: page 0 ($0800-$08FF) and page 1 ($0900-$09FF)
    # Source: font_table_addr (ROM), Dest: $0800
    # LDA font_table+X / STA $0800+X / LDA font_table+$100+X / STA $0900+X
    font_copy_loop_pos = a.pos
    # We need to know font_table_addr to emit LDA abs,X
    # Emit placeholder LDA abs,X instructions — fixup after placing font table
    lda_p0_pos = a.pos
    a.LDA_absx(0x0000)  # placeholder: font_table page 0
    a.STA_absx(0x0800)
    lda_p1_pos = a.pos
    a.LDA_absx(0x0000)  # placeholder: font_table page 1
    a.STA_absx(0x0900)
    a.INX()
    a.BNE_back(font_copy_loop_pos)
    a.RTS()

    # ════════════════════════════════════════════════════════════
    # Font table data (appended to ROM)
    # ════════════════════════════════════════════════════════════
    font_data = char_ram_data()
    font_table_rom_pos = a.pos
    font_table_rom_addr = ROM_BASE + font_table_rom_pos
    # Only need first 512 bytes (64 chars)
    a.raw(*font_data[:512])

    # Fixup font copy LDA addresses
    a._buf[lda_p0_pos + 1] = font_table_rom_addr & 0xFF
    a._buf[lda_p0_pos + 2] = (font_table_rom_addr >> 8) & 0xFF
    a._buf[lda_p1_pos + 1] = (font_table_rom_addr + 256) & 0xFF
    a._buf[lda_p1_pos + 2] = ((font_table_rom_addr + 256) >> 8) & 0xFF

    return a


def make_rom(asm):
    """Wrap assembled code in 8KB ROM with vectors."""
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6, \
        f"Code too large: {len(code)} bytes (max {ROM_SIZE - 6})"

    rom = bytearray(b"\xAA" * ROM_SIZE)
    rom[:len(code)] = code

    entry = ROM_BASE
    # NMI
    rom[0x1FFA] = entry & 0xFF
    rom[0x1FFB] = (entry >> 8) & 0xFF
    # RESET
    rom[0x1FFC] = entry & 0xFF
    rom[0x1FFD] = (entry >> 8) & 0xFF
    # IRQ (no IRQ handler — just point to entry)
    rom[0x1FFE] = entry & 0xFF
    rom[0x1FFF] = (entry >> 8) & 0xFF

    return bytes(rom)


def make_crt(rom, name):
    """Wrap ROM in Ultimax CRT format."""
    assert len(rom) == ROM_SIZE
    sig = b"C64 CARTRIDGE   "
    hdr_len = struct.pack(">I", 64)
    version = struct.pack(">H", 0x0100)
    hw_type = struct.pack(">H", 0)
    exrom = b"\x01"
    game = b"\x00"
    reserved = b"\x00" * 6
    crt_name = name.encode("ascii", errors="replace")[:32].ljust(32, b"\x00")
    header = sig + hdr_len + version + hw_type + exrom + game + reserved + crt_name

    chip_sig = b"CHIP"
    pkt_len = struct.pack(">I", 16 + ROM_SIZE)
    chip_type = struct.pack(">H", 0)
    bank = struct.pack(">H", 0)
    load_addr = struct.pack(">H", ROM_BASE)
    chip_size = struct.pack(">H", ROM_SIZE)
    chip = chip_sig + pkt_len + chip_type + bank + load_addr + chip_size

    return header + chip + rom


def main():
    asm = assemble()
    rom = make_rom(asm)
    crt = make_crt(rom, "SCPU DIAG COUNTERS")

    os.makedirs(OUT_DIR, exist_ok=True)
    stem = "scpu_diag_counters"
    crt_path = os.path.join(OUT_DIR, f"{stem}.crt")
    bin_path = os.path.join(OUT_DIR, f"{stem}.bin")

    with open(crt_path, "wb") as f:
        f.write(crt)
    with open(bin_path, "wb") as f:
        f.write(rom)

    code = asm.build()
    print(f"SCPU Diagnostic Counter Test CRT")
    print(f"Code:   {len(code)} bytes at $E000")
    print(f"Output: {crt_path}")
    print(f"        {bin_path}")
    print()
    print("=== What This Tests ===")
    print("Reads hold-register diagnostic counters after triggering artifact")
    print("via indirect-indexed reads (same as M8).")
    print()
    print("Counter addresses:")
    print("  $D07C = FIRE  (hold gate activations)")
    print("  $D07D = MISM  (held != live at CPUF)")
    print("  $D07F = HZRO  (held data = $00)")
    print("  $D080 = LZRO  (live data = $00)")
    print()
    print("=== Interpretation ===")
    print("  HZRO high + LZRO high = SDRAM actually contains $00")
    print("  HZRO low  + LZRO high = Hold works, VIC not seeing it")
    print("  HZRO high + LZRO low  = Early CE timing problem")
    print("  HZRO low  + LZRO low  = Different root cause")
    print()
    print("=== Usage ===")
    print("1. Load CRT on MiSTer with SuperCPU enabled")
    print("2. Watch counter values update each ~1-2 sec")
    print("3. Bottom half shows white blocks — watch for '@' artifacts")


if __name__ == "__main__":
    main()
