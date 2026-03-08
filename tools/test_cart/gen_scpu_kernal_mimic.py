#!/usr/bin/env python3
"""
SCPU KERNAL-Mimic Test Cartridge Generator
===========================================
Generates Ultimax-mode CRT files that progressively add KERNAL-like behavior
to isolate which specific operation triggers the '@' scrolling artifact.

Modes:
  0: Baseline (charram test clone) — known-good reference
  1: + CIA1 Timer A IRQ at ~60Hz — tests if periodic interrupts trigger it
  2: + Cursor blink in IRQ handler — tests if screen RAM writes during IRQ
  3: + Screen scroll (40-byte block copy) — **confirmed trigger**
  4: + CIA1 keyboard matrix scan (I/O bus activity during IRQ)
  5: All combined — full KERNAL-like workload
  6: Main-loop continuous screen RAM refill (no IRQ) — write volume test
  7: Main-loop scroll copy (no IRQ) — same as M3 but no interrupt context
  8: Main-loop indirect-indexed READ-ONLY (no STA) — **TRIGGERS** (confirmed)
  9: Main-loop absolute-indexed READ+WRITE (LDA/STA absx) — clean
 10: Dense absolute-indexed reads (back-to-back LDA absx) — clean (not density)
 11: Alternating ZP+screen absolute reads — address pattern test
 12: Indirect reads from char RAM ($0800) — ZP reads vs screen RAM target

Memory layout (Ultimax mode):
  $0000-$000F: Zero-page variables (blink state, scroll pointers)
  $0100-$01FF: Stack
  $0400-$07E7: Screen RAM (filled with $01 = solid white block)
  $0800-$0FFF: Character RAM (char $00=blank, char $01=filled, char $20=blank)
  $D000-$DFFF: I/O (VIC, CIA)
  $E000-$FFFF: Cartridge ROM (code + vectors)

Usage:
  python gen_scpu_kernal_mimic.py --mode 0   # baseline
  python gen_scpu_kernal_mimic.py --mode 3   # scroll test (confirmed trigger)
  python gen_scpu_kernal_mimic.py --mode 5   # all combined
  python gen_scpu_kernal_mimic.py --mode 6   # write volume test (no IRQ)
  python gen_scpu_kernal_mimic.py --mode 7   # scroll from main loop (no IRQ)
  python gen_scpu_kernal_mimic.py --mode 8   # indirect read-only — TRIGGERS
  python gen_scpu_kernal_mimic.py --mode 9   # absolute-indexed read+write — clean
  python gen_scpu_kernal_mimic.py --mode 10  # dense absolute reads — bus density test
"""

import struct
import os
import sys

ROM_SIZE = 0x2000
ROM_BASE = 0xE000
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# VIC-II registers
D011 = 0xD011
D016 = 0xD016
D018 = 0xD018
D020 = 0xD020
D021 = 0xD021

# CIA1 registers
DC00 = 0xDC00  # Port A (keyboard column select)
DC01 = 0xDC01  # Port B (keyboard row read)
DC04 = 0xDC04  # Timer A low
DC05 = 0xDC05  # Timer A high
DC0D = 0xDC0D  # Interrupt control/status
DC0E = 0xDC0E  # Timer A control

# Colors
BLACK = 0x00
WHITE = 0x01
RED   = 0x02
GREEN = 0x05
BLUE  = 0x06

# Zero-page variables
ZP_BLINK_CTR = 0x02    # Blink frame counter (counts down from 30)
ZP_BLINK_STATE = 0x03  # Current blink char ($01 or $20)
ZP_SCROLL_SRC_LO = 0x04
ZP_SCROLL_SRC_HI = 0x05
ZP_SCROLL_DST_LO = 0x06
ZP_SCROLL_DST_HI = 0x07
ZP_SCROLL_FLAG = 0x08  # Set to 1 when scroll is requested

# Screen constants
SCREEN_BASE = 0x0400
SCREEN_FILL = 0x01     # Solid block character
CURSOR_POS  = 0x05F4   # ~line 12, col 20 — visible cursor position
LINES       = 24       # Lines to scroll (line 0..23; line 24 = bottom, refilled)
COLS        = 40


class Asm6502:
    """Append-only 6502 assembler with enough instructions for KERNAL-mimic tests."""

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

    # ── Implied ──────────────────────────────────────────────────────────────
    def SEI(self):   return self.raw(0x78)
    def CLI(self):   return self.raw(0x58)
    def CLD(self):   return self.raw(0xD8)
    def CLC(self):   return self.raw(0x18)
    def TXS(self):   return self.raw(0x9A)
    def INX(self):   return self.raw(0xE8)
    def INY(self):   return self.raw(0xC8)
    def DEX(self):   return self.raw(0xCA)
    def DEY(self):   return self.raw(0x88)
    def NOP(self):   return self.raw(0xEA)
    def PHA(self):   return self.raw(0x48)
    def PLA(self):   return self.raw(0x68)
    def TXA(self):   return self.raw(0x8A)
    def TAX(self):   return self.raw(0xAA)
    def TYA(self):   return self.raw(0x98)
    def TAY(self):   return self.raw(0xA8)
    def RTI(self):   return self.raw(0x40)

    # ── Immediate ────────────────────────────────────────────────────────────
    def LDA_imm(self, v):  return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v):  return self.raw(0xA2, v & 0xFF)
    def LDY_imm(self, v):  return self.raw(0xA0, v & 0xFF)
    def CMP_imm(self, v):  return self.raw(0xC9, v & 0xFF)
    def CPX_imm(self, v):  return self.raw(0xE0, v & 0xFF)
    def CPY_imm(self, v):  return self.raw(0xC0, v & 0xFF)
    def ADC_imm(self, v):  return self.raw(0x69, v & 0xFF)
    def EOR_imm(self, v):  return self.raw(0x49, v & 0xFF)
    def AND_imm(self, v):  return self.raw(0x29, v & 0xFF)
    def ORA_imm(self, v):  return self.raw(0x09, v & 0xFF)

    # ── Zero page ────────────────────────────────────────────────────────────
    def LDA_zp(self, a):   return self.raw(0xA5, a & 0xFF)
    def STA_zp(self, a):   return self.raw(0x85, a & 0xFF)
    def INC_zp(self, a):   return self.raw(0xE6, a & 0xFF)
    def DEC_zp(self, a):   return self.raw(0xC6, a & 0xFF)

    # ── Zero page indirect indexed: LDA (zp),Y / STA (zp),Y ─────────────────
    def LDA_indy(self, zp):  return self.raw(0xB1, zp & 0xFF)
    def STA_indy(self, zp):  return self.raw(0x91, zp & 0xFF)

    # ── Absolute ─────────────────────────────────────────────────────────────
    def LDA_abs(self, a):  return self.raw(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_abs(self, a):  return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)

    # ── Jumps ────────────────────────────────────────────────────────────────
    def JMP(self, addr):
        return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)

    def JSR(self, addr):
        return self.raw(0x20, addr & 0xFF, (addr >> 8) & 0xFF)

    def RTS(self):
        return self.raw(0x60)

    # ── Branch helpers ───────────────────────────────────────────────────────
    def BNE_back(self, target_buf_pos):
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0, f"BNE backward out of range: {off}"
        return self.raw(0xD0, off & 0xFF)

    def BEQ_back(self, target_buf_pos):
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0, f"BEQ backward out of range: {off}"
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
        assert -128 <= off < 0, f"BCC backward out of range: {off}"
        return self.raw(0x90, off & 0xFF)

    def BCS_fwd(self):
        idx = self.pos
        self.raw(0xB0, 0x00)
        return idx

    def fixup_branch(self, placeholder_pos):
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127, f"Forward branch offset {off} out of range"
        self._buf[placeholder_pos + 1] = off


def assemble(mode):
    """Assemble code for the given mode (0-7)."""
    a = Asm6502()

    # ── Init ─────────────────────────────────────────────────────────────────
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()

    # 6510 processor port
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # Initialize zero-page variables
    a.LDA_imm(30); a.STA_zp(ZP_BLINK_CTR)
    a.LDA_imm(SCREEN_FILL); a.STA_zp(ZP_BLINK_STATE)
    a.LDA_imm(0x00); a.STA_zp(ZP_SCROLL_FLAG)

    # ── VIC-II setup ─────────────────────────────────────────────────────────
    a.LDA_imm(0x0B); a.STA_abs(D011)    # screen off
    a.LDA_imm(0x12); a.STA_abs(D018)    # screen@$0400, chars@$0800 (RAM)
    a.LDA_imm(BLACK); a.STA_abs(D020)   # black border initially
    a.LDA_imm(BLUE); a.STA_abs(D021)    # blue background
    a.LDA_imm(0xC8); a.STA_abs(D016)    # 40 col

    # ── Character RAM at $0800 ───────────────────────────────────────────────
    # Clear all character RAM
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

    # Char $01 at $0808-$080F: solid filled block ($FF)
    a.LDA_imm(0xFF)
    for addr in range(0x0808, 0x0810):
        a.STA_abs(addr)

    # Char $20 (space) at $0900-$0907: blank (already zero from clear above)
    # No action needed — char $20 = 32*8 = offset $100, which is at $0900

    # ── Fill screen RAM with $01 ─────────────────────────────────────────────
    a.LDA_imm(SCREEN_FILL)
    a.LDX_imm(0x00)
    screen_fill = a.pos
    a.STA_absx(0x0400)
    a.STA_absx(0x0500)
    a.STA_absx(0x0600)
    a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(screen_fill)

    # ── Fill color RAM with WHITE ────────────────────────────────────────────
    a.LDA_imm(WHITE)
    a.LDX_imm(0x00)
    color_fill = a.pos
    a.STA_absx(0xD800)
    a.STA_absx(0xD900)
    a.STA_absx(0xDA00)
    a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(color_fill)

    # ── Turn screen on ───────────────────────────────────────────────────────
    a.LDA_imm(0x1B); a.STA_abs(D011)
    a.LDA_imm(GREEN); a.STA_abs(D020)  # green = fill complete

    # ── CIA1 IRQ setup (modes 1-5 only) ──────────────────────────────────────
    irq_handler_pos = None
    if 1 <= mode <= 5:
        # Set CIA1 Timer A to ~60Hz: 985248 / 60 ≈ 16421 = $4025
        a.LDA_imm(0x25); a.STA_abs(DC04)   # Timer A low = $25
        a.LDA_imm(0x40); a.STA_abs(DC05)   # Timer A high = $40
        # Enable CIA1 Timer A IRQ
        a.LDA_imm(0x81); a.STA_abs(DC0D)   # Set bit 0 (Timer A) + bit 7 (set)
        # Start Timer A: continuous mode
        a.LDA_imm(0x01); a.STA_abs(DC0E)   # bit 0 = start, bit 4 = 0 (continuous)
        # Enable interrupts
        a.CLI()

    # ════════════════════════════════════════════════════════════════════════
    # Modes 6-7: Main-loop write tests (no IRQ, no verify — just write)
    # ════════════════════════════════════════════════════════════════════════

    if mode == 6:
        # Mode 6: Continuous screen RAM refill from main loop (no IRQ)
        # Tight loop: write $01 to all of $0400-$07FF, then repeat forever.
        # This generates the same write volume as the KERNAL scroll but
        # without any IRQ context — tests if raw write volume is the trigger.
        main_loop = a.pos
        a.LDA_imm(SCREEN_FILL)
        a.LDX_imm(0x00)
        refill_loop = a.pos
        a.STA_absx(0x0400)
        a.STA_absx(0x0500)
        a.STA_absx(0x0600)
        a.STA_absx(0x0700)
        a.INX()
        a.BNE_back(refill_loop)
        a.JMP(ROM_BASE + main_loop)

        return a, None

    if mode == 7:
        # Mode 7: Scroll copy from main loop (no IRQ)
        # Same scroll algorithm as mode 3 but runs continuously in the
        # main loop instead of once per IRQ.  Interrupts stay disabled.
        # If this triggers blue lines, it's not IRQ-specific.
        main_loop = a.pos

        # Set up scroll pointers
        a.LDA_imm(0x00); a.STA_zp(ZP_SCROLL_DST_LO)  # dst = $0400
        a.LDA_imm(0x04); a.STA_zp(ZP_SCROLL_DST_HI)
        a.LDA_imm(0x28); a.STA_zp(ZP_SCROLL_SRC_LO)  # src = $0428
        a.LDA_imm(0x04); a.STA_zp(ZP_SCROLL_SRC_HI)

        a.LDX_imm(LINES)  # 24 lines

        scroll_line = a.pos
        a.LDY_imm(0x00)

        copy_byte = a.pos
        a.LDA_indy(ZP_SCROLL_SRC_LO)
        a.STA_indy(ZP_SCROLL_DST_LO)
        a.INY()
        a.CPY_imm(COLS)
        a.BCC_back(copy_byte)

        # dst += 40
        a.CLC()
        a.LDA_zp(ZP_SCROLL_DST_LO)
        a.ADC_imm(COLS)
        a.STA_zp(ZP_SCROLL_DST_LO)
        skip_dst = a.BCC_fwd()
        a.INC_zp(ZP_SCROLL_DST_HI)
        a.fixup_branch(skip_dst)

        # src += 40
        a.CLC()
        a.LDA_zp(ZP_SCROLL_SRC_LO)
        a.ADC_imm(COLS)
        a.STA_zp(ZP_SCROLL_SRC_LO)
        skip_src = a.BCC_fwd()
        a.INC_zp(ZP_SCROLL_SRC_HI)
        a.fixup_branch(skip_src)

        a.DEX()
        a.BNE_back(scroll_line)

        # Refill bottom line with $01
        a.LDY_imm(0x00)
        a.LDA_imm(SCREEN_FILL)
        refill = a.pos
        a.STA_indy(ZP_SCROLL_DST_LO)
        a.INY()
        a.CPY_imm(COLS)
        a.BCC_back(refill)

        a.JMP(ROM_BASE + main_loop)

        return a, None

    if mode == 8:
        # Mode 8: Indirect-indexed READ-ONLY from screen RAM (no writes)
        # Same traversal as M7 scroll but only does LDA (zp),Y — no STA.
        # If this triggers blue lines → CPU reads from screen RAM are sufficient.
        # If clean → the writes are required (possibly the write changes SDRAM state).
        main_loop = a.pos

        a.LDA_imm(0x00); a.STA_zp(ZP_SCROLL_SRC_LO)  # ptr = $0400
        a.LDA_imm(0x04); a.STA_zp(ZP_SCROLL_SRC_HI)

        a.LDX_imm(LINES)  # 24 iterations

        read_line = a.pos
        a.LDY_imm(0x00)

        read_byte = a.pos
        a.LDA_indy(ZP_SCROLL_SRC_LO)  # read from screen RAM (result discarded)
        a.INY()
        a.CPY_imm(COLS)
        a.BCC_back(read_byte)

        # Advance pointer by 40
        a.CLC()
        a.LDA_zp(ZP_SCROLL_SRC_LO)
        a.ADC_imm(COLS)
        a.STA_zp(ZP_SCROLL_SRC_LO)
        skip_hi = a.BCC_fwd()
        a.INC_zp(ZP_SCROLL_SRC_HI)
        a.fixup_branch(skip_hi)

        a.DEX()
        a.BNE_back(read_line)

        a.JMP(ROM_BASE + main_loop)

        return a, None

    if mode == 9:
        # Mode 9: Absolute-indexed READ+WRITE to screen RAM (LDA/STA absx)
        # Simpler addressing than indirect-indexed (fewer bus cycles per op).
        # Reads screen RAM byte then writes it back (same value).
        # Result: CLEAN — absolute-indexed r+w doesn't trigger.
        main_loop = a.pos
        a.LDX_imm(0x00)

        rw_loop = a.pos
        a.LDA_absx(0x0400); a.STA_absx(0x0400)
        a.LDA_absx(0x0500); a.STA_absx(0x0500)
        a.LDA_absx(0x0600); a.STA_absx(0x0600)
        a.LDA_absx(0x0700); a.STA_absx(0x0700)
        a.INX()
        a.BNE_back(rw_loop)

        a.JMP(ROM_BASE + main_loop)

        return a, None

    if mode == 10:
        # Mode 10: Dense absolute-indexed reads from screen RAM (no writes)
        # Back-to-back LDA absx — 8 reads per loop iteration, minimal overhead.
        # M8 triggers with indirect reads (~3 SDRAM accesses per 12 cycles).
        # M0/M9 are clean with ~1 read per 8-10 cycles.
        # This test packs ~8 reads per ~30 cycles to match M8's bus density.
        # If this triggers → it's purely about SDRAM read density/frequency.
        # If clean → indirect addressing specifically causes the problem
        #   (maybe ZP reads from $00xx conflict with screen RAM $04xx in SDRAM).
        main_loop = a.pos
        a.LDX_imm(0x00)

        dense_loop = a.pos
        # 8 back-to-back reads from screen RAM pages
        a.LDA_absx(0x0400)
        a.LDA_absx(0x0500)
        a.LDA_absx(0x0600)
        a.LDA_absx(0x0700)
        a.LDA_absx(0x0400)
        a.LDA_absx(0x0500)
        a.LDA_absx(0x0600)
        a.LDA_absx(0x0700)
        a.INX()
        a.BNE_back(dense_loop)

        a.JMP(ROM_BASE + main_loop)

        return a, None

    if mode == 11:
        # Mode 11: Alternating ZP + screen RAM reads using ABSOLUTE addressing
        # Read $0004 (abs), then $0400+X (absx) — mimics the address alternation
        # pattern of LDA (zp),Y ($00xx then $04xx) but using absolute mode.
        # LDA $0004 = 3-byte instruction, reads from $0004 in RAM
        # This isolates whether the trigger is:
        #   - The $00xx↔$04xx address alternation itself (triggers)
        #   - Something internal to the indirect addressing mode (clean)
        main_loop = a.pos
        a.LDX_imm(0x00)

        alt_loop = a.pos
        a.LDA_abs(0x0004)       # read ZP address (absolute, 4 cycles, 1 SDRAM)
        a.LDA_absx(0x0400)     # read screen RAM (absolute indexed, 4 cycles, 1 SDRAM)
        a.LDA_abs(0x0005)       # read ZP address
        a.LDA_absx(0x0500)     # read screen RAM
        a.LDA_abs(0x0004)       # read ZP address
        a.LDA_absx(0x0600)     # read screen RAM
        a.LDA_abs(0x0005)       # read ZP address
        a.LDA_absx(0x0700)     # read screen RAM
        a.INX()
        a.BNE_back(alt_loop)

        a.JMP(ROM_BASE + main_loop)

        return a, None

    if mode == 12:
        # Mode 12: Indirect-indexed reads from CHARACTER RAM ($0800), not screen RAM
        # Same LDA (zp),Y loop as M8 but pointer targets $0800-$0BFF instead of
        # $0400-$07E7. The ZP reads are identical ($0004/$0005). Only the final
        # data read address changes.
        # If this triggers → the ZP reads ($00xx) are causing the clobber,
        #   regardless of what address the final data comes from
        # If clean → reading from screen RAM ($0400-$07FF) specifically is required
        #   (maybe VIC c-access vs CPU read to same address range)

        # Set pointer to $0800 (character RAM) instead of $0400
        a.LDA_imm(0x00); a.STA_zp(ZP_SCROLL_SRC_LO)  # ptr = $0800
        a.LDA_imm(0x08); a.STA_zp(ZP_SCROLL_SRC_HI)

        main_loop = a.pos

        # Reset pointer to $0800 each iteration
        a.LDA_imm(0x00); a.STA_zp(ZP_SCROLL_SRC_LO)
        a.LDA_imm(0x08); a.STA_zp(ZP_SCROLL_SRC_HI)

        a.LDX_imm(LINES)  # 24 iterations

        read_line = a.pos
        a.LDY_imm(0x00)

        read_byte = a.pos
        a.LDA_indy(ZP_SCROLL_SRC_LO)  # read from char RAM (result discarded)
        a.INY()
        a.CPY_imm(COLS)
        a.BCC_back(read_byte)

        # Advance pointer by 40
        a.CLC()
        a.LDA_zp(ZP_SCROLL_SRC_LO)
        a.ADC_imm(COLS)
        a.STA_zp(ZP_SCROLL_SRC_LO)
        skip_hi = a.BCC_fwd()
        a.INC_zp(ZP_SCROLL_SRC_HI)
        a.fixup_branch(skip_hi)

        a.DEX()
        a.BNE_back(read_line)

        a.JMP(ROM_BASE + main_loop)

        return a, None

    # ════════════════════════════════════════════════════════════════════════
    # Modes 0-5: Verify loop + optional IRQ handler
    # ════════════════════════════════════════════════════════════════════════

    # Main verify loop: read screen RAM and check for $01
    # GREEN border = CPU reads correct, RED = CPU reads wrong
    # Mode 2-5 skips $0500 page (cursor at $05F4 may contain $20)
    main_loop = a.pos
    a.LDX_imm(0x00)

    verify = a.pos
    # Page $0400
    a.LDA_absx(0x0400)
    a.CMP_imm(SCREEN_FILL)
    fail1 = a.BNE_fwd()

    # Page $0500 — skip in modes 2+ (cursor blink writes $20 here)
    if 2 <= mode <= 5:
        pass
    else:
        a.LDA_absx(0x0500)
        a.CMP_imm(SCREEN_FILL)
        fail2 = a.BNE_fwd()

    # Page $0600
    a.LDA_absx(0x0600)
    a.CMP_imm(SCREEN_FILL)
    fail3 = a.BNE_fwd()

    # Page $0700
    a.LDA_absx(0x0700)
    a.CMP_imm(SCREEN_FILL)
    fail4 = a.BNE_fwd()

    a.INX()
    a.BNE_back(verify)

    # All OK — green border, loop
    a.LDA_imm(GREEN); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    # CPU read mismatch — red border
    fail_targets = [fail1, fail3, fail4]
    if not (2 <= mode <= 5):
        fail_targets.insert(1, fail2)
    for f in fail_targets:
        a.fixup_branch(f)
    a.LDA_imm(RED); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    # ── IRQ handler (modes 1-5) ──────────────────────────────────────────────
    if 1 <= mode <= 5:
        irq_handler_pos = a.pos

        # Save registers
        a.PHA()
        a.TXA(); a.PHA()
        a.TYA(); a.PHA()

        # Acknowledge CIA1 IRQ (read $DC0D clears interrupt flags)
        a.LDA_abs(DC0D)

        # ── Mode 2+: Cursor blink ───────────────────────────────────────────
        if mode >= 2:
            # Decrement blink counter
            a.DEC_zp(ZP_BLINK_CTR)
            skip_blink = a.BNE_fwd()

            # Counter reached 0 — toggle blink state
            a.LDA_imm(30); a.STA_zp(ZP_BLINK_CTR)  # reset counter
            a.LDA_zp(ZP_BLINK_STATE)
            a.EOR_imm(SCREEN_FILL ^ 0x20)  # toggle between $01 and $20
            a.STA_zp(ZP_BLINK_STATE)
            a.STA_abs(CURSOR_POS)  # write to screen RAM

            a.fixup_branch(skip_blink)

        # ── Mode 3+: Screen scroll ──────────────────────────────────────────
        if mode >= 3:
            a.LDA_imm(0x00); a.STA_zp(ZP_SCROLL_DST_LO)  # dst = $0400
            a.LDA_imm(0x04); a.STA_zp(ZP_SCROLL_DST_HI)
            a.LDA_imm(0x28); a.STA_zp(ZP_SCROLL_SRC_LO)  # src = $0428
            a.LDA_imm(0x04); a.STA_zp(ZP_SCROLL_SRC_HI)

            a.LDX_imm(LINES)  # 24 lines to scroll

            scroll_line = a.pos
            a.LDY_imm(0x00)  # byte index within line (0..39)

            copy_byte = a.pos
            a.LDA_indy(ZP_SCROLL_SRC_LO)  # load from (src),Y
            a.STA_indy(ZP_SCROLL_DST_LO)  # store to (dst),Y
            a.INY()
            a.CPY_imm(COLS)  # done 40 bytes?
            a.BCC_back(copy_byte)

            # dst += 40
            a.CLC()
            a.LDA_zp(ZP_SCROLL_DST_LO)
            a.ADC_imm(COLS)
            a.STA_zp(ZP_SCROLL_DST_LO)
            skip_dst_hi = a.BCC_fwd()
            a.INC_zp(ZP_SCROLL_DST_HI)
            a.fixup_branch(skip_dst_hi)

            # src += 40
            a.CLC()
            a.LDA_zp(ZP_SCROLL_SRC_LO)
            a.ADC_imm(COLS)
            a.STA_zp(ZP_SCROLL_SRC_LO)
            skip_src_hi = a.BCC_fwd()
            a.INC_zp(ZP_SCROLL_SRC_HI)
            a.fixup_branch(skip_src_hi)

            a.DEX()
            a.BNE_back(scroll_line)

            # Refill bottom line with $01
            a.LDY_imm(0x00)
            a.LDA_imm(SCREEN_FILL)
            refill = a.pos
            a.STA_indy(ZP_SCROLL_DST_LO)
            a.INY()
            a.CPY_imm(COLS)
            a.BCC_back(refill)

        # ── Mode 4+: Keyboard matrix scan ───────────────────────────────────
        if mode >= 4:
            a.LDA_imm(0xFF); a.STA_abs(DC00)  # deselect all first
            a.LDA_imm(0xFE)  # select column 0 (bit 0 low)
            a.LDX_imm(0x08)  # 8 columns

            keyscan = a.pos
            a.STA_abs(DC00)         # select column
            a.NOP(); a.NOP()        # settle time
            a.LDA_abs(DC01)         # read row result (discarded)

            a.LDA_abs(DC00)         # re-read current column
            a.CLC()
            a.raw(0x0A)            # ASL A
            a.ORA_imm(0x01)        # set bit 0

            a.DEX()
            a.BNE_back(keyscan)

            a.LDA_imm(0xFF); a.STA_abs(DC00)  # deselect all columns

        # Restore registers and return
        a.PLA(); a.TAY()
        a.PLA(); a.TAX()
        a.PLA()
        a.RTI()

    return a, irq_handler_pos


def make_rom(asm, irq_addr=None):
    """Wrap assembled code in 8KB ROM with vectors."""
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6, \
        f"Code too large: {len(code)} bytes (max {ROM_SIZE - 6})"

    rom = bytearray(b"\xAA" * ROM_SIZE)
    rom[:len(code)] = code

    entry = ROM_BASE
    irq = (ROM_BASE + irq_addr) if irq_addr is not None else entry

    # NMI vector at $FFFA
    rom[0x1FFA] = entry & 0xFF
    rom[0x1FFB] = (entry >> 8) & 0xFF
    # RESET vector at $FFFC
    rom[0x1FFC] = entry & 0xFF
    rom[0x1FFD] = (entry >> 8) & 0xFF
    # IRQ vector at $FFFE
    rom[0x1FFE] = irq & 0xFF
    rom[0x1FFF] = (irq >> 8) & 0xFF

    return bytes(rom)


def make_crt(rom, name):
    """Wrap ROM in Ultimax CRT format."""
    assert len(rom) == ROM_SIZE
    sig      = b"C64 CARTRIDGE   "
    hdr_len  = struct.pack(">I", 64)
    version  = struct.pack(">H", 0x0100)
    hw_type  = struct.pack(">H", 0)
    exrom    = b"\x01"
    game     = b"\x00"
    reserved = b"\x00" * 6
    crt_name = name.encode("ascii", errors="replace")[:32].ljust(32, b"\x00")
    header = sig + hdr_len + version + hw_type + exrom + game + reserved + crt_name

    chip_sig  = b"CHIP"
    pkt_len   = struct.pack(">I", 16 + ROM_SIZE)
    chip_type = struct.pack(">H", 0)
    bank      = struct.pack(">H", 0)
    load_addr = struct.pack(">H", ROM_BASE)
    chip_size = struct.pack(">H", ROM_SIZE)
    chip = chip_sig + pkt_len + chip_type + bank + load_addr + chip_size

    return header + chip + rom


MODE_LABELS = {
    0: "Baseline (charram clone)",
    1: "CIA1 Timer A IRQ ~60Hz",
    2: "Cursor blink in IRQ",
    3: "Screen scroll in IRQ",
    4: "Keyboard scan in IRQ",
    5: "All combined",
    6: "Main-loop screen refill (no IRQ)",
    7: "Main-loop scroll copy (no IRQ)",
    8: "Indirect-indexed read-only (no writes)",
    9: "Absolute-indexed read+write (LDA/STA absx)",
    10: "Dense absolute-indexed reads (8x back-to-back)",
    11: "Alternating ZP+screen absolute reads",
    12: "Indirect reads from char RAM ($0800)",
}


def main():
    # Parse --mode N
    mode = None
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == "--mode" and i + 1 < len(args):
            mode = int(args[i + 1])
            break
    if mode is None:
        print("Usage: python gen_scpu_kernal_mimic.py --mode N  (N=0..5)")
        sys.exit(1)
    if mode < 0 or mode > 12:
        print(f"Error: mode must be 0-12, got {mode}")
        sys.exit(1)

    asm, irq_pos = assemble(mode)
    rom = make_rom(asm, irq_addr=irq_pos)
    stem = f"scpu_kernal_mimic_m{mode}"
    crt = make_crt(rom, f"KERNAL MIMIC M{mode}")

    os.makedirs(OUT_DIR, exist_ok=True)
    crt_path = os.path.join(OUT_DIR, f"{stem}.crt")
    bin_path = os.path.join(OUT_DIR, f"{stem}.bin")

    with open(crt_path, "wb") as f: f.write(crt)
    with open(bin_path, "wb") as f: f.write(rom)

    label = MODE_LABELS[mode]
    print(f"Mode:   {mode} — {label}")
    print(f"Code:   {len(asm.build())} bytes at $E000")
    if irq_pos is not None:
        print(f"IRQ:    ${ROM_BASE + irq_pos:04X}")
    print(f"Output: {crt_path}")
    print(f"        {bin_path}")
    print()
    print("=== Mode Details ===")
    for m, desc in MODE_LABELS.items():
        marker = " <<" if m == mode else ""
        print(f"  {m}: {desc}{marker}")
    print()
    print("=== Testing ===")
    print("  1. Load CRT with SuperCPU OFF — should show solid white + GREEN border")
    print("  2. Enable SuperCPU — look for '@' artifacts or RED border")
    print(f"  3. If artifact appears at mode {mode}, this operation is the trigger")


if __name__ == "__main__":
    main()
