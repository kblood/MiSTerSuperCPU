#!/usr/bin/env python3
"""
REU Register Write Test PRG Generator
======================================
Tests whether REU registers ($DF00-$DF0A) accept writes and read back correctly.
Also tests a 1-byte STASH+FETCH round-trip through SDRAM.

Screen output:
  Row 1: REG WRITE TEST
  Row 2: DF04=xx (expect AA)
  Row 3: DF06=xx (expect BB)
  Row 4: DF07=xx (expect 01)
  Row 5: DF08=xx (expect 00)
  Row 6: DF00=xx (status, pre-DMA)
  Row 7: STASH...
  Row 8: DF00=xx (status, post-STASH, expect 50)
  Row 9: FETCH...
  Row 10: DF00=xx (status, post-FETCH, expect 50)
  Row 11: C64[$5800]=xx (expect 58 if round-trip works)

Border: GREEN=all pass, RED=reg write fail, YELLOW=regs ok but DMA fail
"""

import struct
import os
import sys

CODE_BASE = 0x0900
BASIC_START = 0x0801
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SCREEN = 0x0400
ROW = 40
COLOR_RAM = 0xD800

# REU registers
REU_STATUS  = 0xDF00
REU_CMD     = 0xDF01
REU_C64LO   = 0xDF02
REU_C64HI   = 0xDF03
REU_RAMLO   = 0xDF04
REU_RAMMID  = 0xDF05
REU_RAMHI   = 0xDF06
REU_LENLO   = 0xDF07
REU_LENHI   = 0xDF08
REU_INTR    = 0xDF09
REU_CTL     = 0xDF0A


class Asm6502:
    def __init__(self, org=0x0900):
        self.code = bytearray()
        self.org = org
        self.labels = {}
        self.fixups = []

    def pos(self):
        return self.org + len(self.code)

    def label(self, name):
        self.labels[name] = self.pos()

    def emit(self, *bs):
        for b in bs:
            self.code.append(b & 0xFF)

    # Addressing modes
    def lda_imm(self, v):   self.emit(0xA9, v)
    def ldx_imm(self, v):   self.emit(0xA2, v)
    def ldy_imm(self, v):   self.emit(0xA0, v)
    def sta_abs(self, a):   self.emit(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def sta_absx(self, a):  self.emit(0x9D, a & 0xFF, (a >> 8) & 0xFF)
    def stx_abs(self, a):   self.emit(0x8E, a & 0xFF, (a >> 8) & 0xFF)
    def sty_abs(self, a):   self.emit(0x8C, a & 0xFF, (a >> 8) & 0xFF)
    def lda_abs(self, a):   self.emit(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def ldx_abs(self, a):   self.emit(0xAE, a & 0xFF, (a >> 8) & 0xFF)
    def ldy_abs(self, a):   self.emit(0xAC, a & 0xFF, (a >> 8) & 0xFF)
    def sta_zp(self, a):    self.emit(0x85, a)
    def lda_zp(self, a):    self.emit(0xA5, a)
    def cmp_imm(self, v):   self.emit(0xC9, v)
    def cpx_imm(self, v):   self.emit(0xE0, v)
    def bne(self, label):
        self.fixups.append((len(self.code) + 1, label, 'rel'))
        self.emit(0xD0, 0x00)
    def beq(self, label):
        self.fixups.append((len(self.code) + 1, label, 'rel'))
        self.emit(0xF0, 0x00)
    def jmp(self, label):
        self.fixups.append((len(self.code) + 1, label, 'abs'))
        self.emit(0x4C, 0x00, 0x00)
    def jsr(self, label):
        self.fixups.append((len(self.code) + 1, label, 'abs'))
        self.emit(0x20, 0x00, 0x00)
    def rts(self):          self.emit(0x60)
    def nop(self):          self.emit(0xEA)
    def sei(self):          self.emit(0x78)
    def inx(self):          self.emit(0xE8)
    def iny(self):          self.emit(0xC8)
    def dex(self):          self.emit(0xCA)
    def dey(self):          self.emit(0x88)
    def pha(self):          self.emit(0x48)
    def pla(self):          self.emit(0x68)
    def lsr_a(self):        self.emit(0x4A)
    def and_imm(self, v):   self.emit(0x29, v)
    def ora_imm(self, v):   self.emit(0x09, v)
    def tax(self):          self.emit(0xAA)
    def txa(self):          self.emit(0x8A)

    def resolve(self):
        for offset, label, kind in self.fixups:
            addr = self.labels[label]
            if kind == 'rel':
                rel = addr - (self.org + offset + 1)
                if rel < -128 or rel > 127:
                    raise ValueError(f"Branch to {label} out of range: {rel}")
                self.code[offset] = rel & 0xFF
            elif kind == 'abs':
                self.code[offset] = addr & 0xFF
                self.code[offset + 1] = (addr >> 8) & 0xFF


def petscii(s):
    """Convert ASCII string to C64 screen codes."""
    result = []
    for c in s:
        if 'A' <= c <= 'Z':
            result.append(ord(c) - 0x40)
        elif 'a' <= c <= 'z':
            result.append(ord(c) - 0x60)
        elif c == '=':
            result.append(0x3D)
        elif c == ' ':
            result.append(0x20)
        elif c == '$':
            result.append(0x24)
        elif c == '(':
            result.append(0x28)
        elif c == ')':
            result.append(0x29)
        elif c == '.':
            result.append(0x2E)
        elif c == ':':
            result.append(0x3A)
        elif c == '!':
            result.append(0x21)
        elif c == '?':
            result.append(0x3F)
        elif c == ',':
            result.append(0x2C)
        elif c == '-':
            result.append(0x2D)
        elif c == '>':
            result.append(0x3E)
        elif '0' <= c <= '9':
            result.append(ord(c))
        else:
            result.append(0x20)
    return result


def hex_chars(val):
    """Return two screen codes for a hex byte."""
    hi = (val >> 4) & 0xF
    lo = val & 0xF
    return [hi + 0x30 if hi < 10 else hi - 10 + 1,  # screen code for 0-9, A-F
            lo + 0x30 if lo < 10 else lo - 10 + 1]


def build_prg():
    a = Asm6502(CODE_BASE)

    # ZP locations for tracking pass/fail
    ZP_PASS = 0x02      # all-pass flag
    ZP_ROW  = 0x03      # current screen row
    ZP_TMP  = 0xFB      # temp

    # --- BASIC stub: 10 SYS 2304 ---
    basic = bytearray()
    basic += struct.pack('<H', BASIC_START + 12)  # next line ptr
    basic += struct.pack('<H', 10)                # line number
    basic += bytes([0x9E])                        # SYS token
    basic += b'2304'                              # address
    basic += bytes([0x00])                        # end of line
    basic += struct.pack('<H', 0x0000)            # end of program

    # --- Main code ---
    a.sei()

    # Set I/O visible: $0000=$2F, $0001=$37
    a.lda_imm(0x2F)
    a.sta_abs(0x0000)
    a.lda_imm(0x37)
    a.sta_abs(0x0001)

    # Init pass flag
    a.lda_imm(1)
    a.sta_zp(ZP_PASS)

    # Clear screen
    a.ldx_imm(0)
    a.lda_imm(0x20)  # space
    a.label('clr_loop')
    a.sta_absx(SCREEN + 0x000)
    a.sta_absx(SCREEN + 0x100)
    a.sta_absx(SCREEN + 0x200)
    a.sta_absx(SCREEN + 0x300)
    a.inx()
    a.bne('clr_loop')

    # Set border to white initially
    a.lda_imm(1)  # white
    a.sta_abs(0xD020)

    # ======== ROW 0: Title ========
    title = petscii("REU REGISTER WRITE TEST")
    for i, ch in enumerate(title):
        a.lda_imm(ch)
        a.sta_abs(SCREEN + i)

    # ======== Test 1: Write $AA to $DF04 (REU RAM addr lo), read back ========
    a.lda_imm(0xAA)
    a.sta_abs(REU_RAMLO)
    a.lda_abs(REU_RAMLO)
    a.sta_zp(ZP_TMP)  # save result

    # Display "DF04=xx"
    row1 = SCREEN + ROW * 2
    msg = petscii("DF04=")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row1 + i)

    # Display hex value
    a.lda_zp(ZP_TMP)
    a.jsr('print_hex_at_row2')

    # Check
    a.lda_zp(ZP_TMP)
    a.cmp_imm(0xAA)
    a.beq('test1_ok')
    a.lda_imm(0)
    a.sta_zp(ZP_PASS)
    a.label('test1_ok')

    # ======== Test 2: Write $BB to $DF06 (REU RAM addr hi), read back ========
    a.lda_imm(0xBB)
    a.sta_abs(REU_RAMHI)
    a.lda_abs(REU_RAMHI)
    a.sta_zp(ZP_TMP)

    row2 = SCREEN + ROW * 3
    msg = petscii("DF06=")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row2 + i)
    a.lda_zp(ZP_TMP)
    a.jsr('print_hex_at_row3')

    a.lda_zp(ZP_TMP)
    a.cmp_imm(0xBB)
    a.beq('test2_ok')
    a.lda_imm(0)
    a.sta_zp(ZP_PASS)
    a.label('test2_ok')

    # ======== Test 3: Write $01 to $DF07 (length lo), read back ========
    a.lda_imm(0x01)
    a.sta_abs(REU_LENLO)
    a.lda_abs(REU_LENLO)
    a.sta_zp(ZP_TMP)

    row3 = SCREEN + ROW * 4
    msg = petscii("DF07=")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row3 + i)
    a.lda_zp(ZP_TMP)
    a.jsr('print_hex_at_row4')

    a.lda_zp(ZP_TMP)
    a.cmp_imm(0x01)
    a.beq('test3_ok')
    a.lda_imm(0)
    a.sta_zp(ZP_PASS)
    a.label('test3_ok')

    # ======== Test 4: Write $00 to $DF08 (length hi), read back ========
    a.lda_imm(0x00)
    a.sta_abs(REU_LENHI)
    a.lda_abs(REU_LENHI)
    a.sta_zp(ZP_TMP)

    row4 = SCREEN + ROW * 5
    msg = petscii("DF08=")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row4 + i)
    a.lda_zp(ZP_TMP)
    a.jsr('print_hex_at_row5')

    a.lda_zp(ZP_TMP)
    a.cmp_imm(0x00)
    a.beq('test4_ok')
    a.lda_imm(0)
    a.sta_zp(ZP_PASS)
    a.label('test4_ok')

    # ======== DMA Round-Trip Test ========
    # Store $58 at C64 $5800
    a.lda_imm(0x58)
    a.sta_abs(0x5800)

    # Setup REU for STASH: C64 $5800 → REU $000000, length 1
    a.lda_imm(0x00)
    a.sta_abs(REU_C64LO)   # C64 addr lo = $00
    a.lda_imm(0x58)
    a.sta_abs(REU_C64HI)   # C64 addr hi = $58
    a.lda_imm(0x00)
    a.sta_abs(REU_RAMLO)   # REU addr lo = $00
    a.sta_abs(REU_RAMMID)  # REU addr mid = $00
    a.sta_abs(REU_RAMHI)   # REU addr hi = $00
    a.lda_imm(0x01)
    a.sta_abs(REU_LENLO)   # length lo = 1
    a.lda_imm(0x00)
    a.sta_abs(REU_LENHI)   # length hi = 0

    # Show "STASH..." on row 7
    row7 = SCREEN + ROW * 7
    msg = petscii("STASH...")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row7 + i)

    # Execute STASH (cmd=0x90: execute + STASH)
    a.lda_imm(0x90)
    a.sta_abs(REU_CMD)

    # Wait a bit for DMA to complete
    a.ldx_imm(0)
    a.label('stash_wait')
    a.nop()
    a.nop()
    a.nop()
    a.nop()
    a.dex()
    a.bne('stash_wait')

    # Read status after STASH
    a.lda_abs(REU_STATUS)
    a.sta_zp(ZP_TMP)

    row8 = SCREEN + ROW * 8
    msg = petscii("STASH DF00=")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row8 + i)
    a.lda_zp(ZP_TMP)
    a.jsr('print_hex_at_row8')

    # Clear C64 $5800 to prove FETCH works
    a.lda_imm(0x00)
    a.sta_abs(0x5800)

    # Setup REU for FETCH: REU $000000 → C64 $5800, length 1
    a.lda_imm(0x00)
    a.sta_abs(REU_C64LO)
    a.lda_imm(0x58)
    a.sta_abs(REU_C64HI)
    a.lda_imm(0x00)
    a.sta_abs(REU_RAMLO)
    a.sta_abs(REU_RAMMID)
    a.sta_abs(REU_RAMHI)
    a.lda_imm(0x01)
    a.sta_abs(REU_LENLO)
    a.lda_imm(0x00)
    a.sta_abs(REU_LENHI)

    # Show "FETCH..." on row 9
    row9 = SCREEN + ROW * 9
    msg = petscii("FETCH...")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row9 + i)

    # Execute FETCH (cmd=0x91: execute + FETCH)
    a.lda_imm(0x91)
    a.sta_abs(REU_CMD)

    # Wait for DMA
    a.ldx_imm(0)
    a.label('fetch_wait')
    a.nop()
    a.nop()
    a.nop()
    a.nop()
    a.dex()
    a.bne('fetch_wait')

    # Read status after FETCH
    a.lda_abs(REU_STATUS)
    a.sta_zp(ZP_TMP)

    row10 = SCREEN + ROW * 10
    msg = petscii("FETCH DF00=")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row10 + i)
    a.lda_zp(ZP_TMP)
    a.jsr('print_hex_at_row10')

    # Read C64 $5800 — should be $58 if round-trip worked
    a.lda_abs(0x5800)
    a.sta_zp(ZP_TMP)

    row11 = SCREEN + ROW * 12
    msg = petscii("C64 5800=")
    for i, ch in enumerate(msg):
        a.lda_imm(ch)
        a.sta_abs(row11 + i)
    a.lda_zp(ZP_TMP)
    a.jsr('print_hex_at_row12')

    # ======== Set border color based on results ========
    # Check ZP_PASS for register tests
    a.lda_zp(ZP_PASS)
    a.beq('regs_fail')

    # Registers passed — check DMA result
    a.lda_abs(0x5800)
    a.cmp_imm(0x58)
    a.beq('all_pass')

    # Regs OK but DMA failed → YELLOW border
    a.lda_imm(7)  # yellow
    a.sta_abs(0xD020)
    a.jmp('done')

    a.label('regs_fail')
    a.lda_imm(2)  # red
    a.sta_abs(0xD020)
    a.jmp('done')

    a.label('all_pass')
    a.lda_imm(5)  # green
    a.sta_abs(0xD020)

    a.label('done')
    # Also store result summary at $5801 for UART
    a.lda_zp(ZP_TMP)
    a.sta_abs(0x5801)
    a.jmp('done')

    # ======== Hex print subroutines ========
    # Each one prints A as 2-char hex at a fixed screen position

    def make_hex_print(label, screen_pos):
        a.label(label)
        a.pha()
        # High nibble
        a.lsr_a()
        a.lsr_a()
        a.lsr_a()
        a.lsr_a()
        a.and_imm(0x0F)
        a.cmp_imm(0x0A)
        a.emit(0x90, 0x02)  # BCC +2
        a.emit(0x69, 0x06)  # ADC #6 (carry already set from CMP)
        a.emit(0x69, 0x30)  # ADC #$30
        a.sta_abs(screen_pos)
        # Low nibble
        a.pla()
        a.and_imm(0x0F)
        a.cmp_imm(0x0A)
        a.emit(0x90, 0x02)  # BCC +2
        a.emit(0x69, 0x06)  # ADC #6
        a.emit(0x69, 0x30)  # ADC #$30
        a.sta_abs(screen_pos + 1)
        a.rts()

    make_hex_print('print_hex_at_row2', SCREEN + ROW * 2 + 5)
    make_hex_print('print_hex_at_row3', SCREEN + ROW * 3 + 5)
    make_hex_print('print_hex_at_row4', SCREEN + ROW * 4 + 5)
    make_hex_print('print_hex_at_row5', SCREEN + ROW * 5 + 5)
    make_hex_print('print_hex_at_row8', SCREEN + ROW * 8 + 11)
    make_hex_print('print_hex_at_row10', SCREEN + ROW * 10 + 11)
    make_hex_print('print_hex_at_row12', SCREEN + ROW * 12 + 9)

    # Resolve all labels
    a.resolve()

    # Build PRG file (load address + BASIC + code)
    prg = bytearray()
    prg += struct.pack('<H', BASIC_START)  # load address
    prg += basic
    # Pad from end of BASIC to CODE_BASE
    pad_needed = CODE_BASE - (BASIC_START + len(basic))
    prg += bytes(pad_needed)
    prg += a.code

    return prg


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    prg = build_prg()
    out_path = os.path.join(OUT_DIR, "reu_regwrite_test.prg")
    with open(out_path, 'wb') as f:
        f.write(prg)
    print(f"Generated {out_path} ({len(prg)} bytes)")
