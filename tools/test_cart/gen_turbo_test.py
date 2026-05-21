#!/usr/bin/env python3
"""
Turbo Cache Test CRT Generator
================================
Creates an 8K game CRT ($8000) that measures turbo + cache speed
using a pure-computation loop (NO I/O reads in the hot loop).

Method:
  Run a tight ZP-only counting loop for a fixed number of raster lines.
  Wait for raster line 0 (top of screen), then count ZP increments until
  raster line 100 (100 raster lines = 100 * 63 = 6300 PHI2 cycles).
  The iteration count is proportional to CPU speed.

  At 1 MHz:  one ZP INC loop iter = 5 cycles -> 6300/5 = 1260 iters
  At 4 MHz:  ~5040 iters
  At 8 MHz:  ~10080 iters
  At 16 MHz: ~20160 iters

The hot loop:
  .loop  INC $02     ; 5 cycles  (ZP read + write)
         BNE .loop   ; 3 cycles taken / 2 fall through
         INC $03     ; 5 cycles
         JMP .loop   ; 3 cycles

This loop is 8 cycles per iter (with lo-byte rollover every 256 iters).
All accesses are ZP ($00xx) and code ($80xx) — fully cacheable.

Screen shows:
  Row 0: TURBO TEST
  Row 2: COUNT xxxx   (hex iteration count)
  Row 3: SPEED xx.x   (approximate MHz)

Uses raster polling (LDA $D012) only OUTSIDE the measurement loop.
"""

import struct
import os

ROM_SIZE = 0x2000
ROM_BASE = 0x8000
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

SCREEN = 0x0400
ROW = 40

# At ~8 cycles/iter avg, 1 MHz -> 6300/8 = 787 iters per measurement window
# Calibration: iters_per_mhz = 6300 / 8 = 787.5 ~ 788
ITERS_PER_MHZ = 788

# ZP variables
ZP_CNT_LO = 0x02
ZP_CNT_HI = 0x03
ZP_SAVE_LO = 0x04
ZP_SAVE_HI = 0x05
ZP_PASS_LO = 0x06
ZP_PASS_HI = 0x07
ZP_TMP = 0x08
ZP_MHZ_INT = 0x09
ZP_MHZ_TENTH = 0x0A
ZP_DIV_LO = 0x0C
ZP_DIV_HI = 0x0D
ZP_MUL_LO = 0x0E
ZP_MUL_HI = 0x0F

# Screen codes (PETSCII uppercase)
def petscii(s):
    out = []
    for c in s:
        if 'A' <= c <= 'Z':
            out.append(ord(c) - 0x40)
        elif '0' <= c <= '9':
            out.append(ord(c))
        elif c == ' ':
            out.append(0x20)
        elif c == '.':
            out.append(0x2E)
        elif c == ':':
            out.append(0x3A)
        else:
            out.append(0x20)
    return out


class Asm6502:
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
    def NOP(self): return self.raw(0xEA)
    def TXA(self): return self.raw(0x8A)
    def TAX(self): return self.raw(0xAA)

    # Immediate
    def LDA_imm(self, v): return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v): return self.raw(0xA2, v & 0xFF)
    def CMP_imm(self, v): return self.raw(0xC9, v & 0xFF)
    def ADC_imm(self, v): return self.raw(0x69, v & 0xFF)
    def AND_imm(self, v): return self.raw(0x29, v & 0xFF)
    def SBC_imm(self, v): return self.raw(0xE9, v & 0xFF)

    # Zero page
    def LDA_zp(self, a): return self.raw(0xA5, a & 0xFF)
    def STA_zp(self, a): return self.raw(0x85, a & 0xFF)
    def STX_zp(self, a): return self.raw(0x86, a & 0xFF)
    def INC_zp(self, a): return self.raw(0xE6, a & 0xFF)
    def ADC_zp(self, a): return self.raw(0x65, a & 0xFF)
    def SBC_zp(self, a): return self.raw(0xE5, a & 0xFF)

    # Absolute
    def LDA_abs(self, a): return self.raw(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_abs(self, a): return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)

    def JMP(self, addr): return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)
    def JSR(self, addr): return self.raw(0x20, addr & 0xFF, (addr >> 8) & 0xFF)
    def RTS(self): return self.raw(0x60)

    def BNE_back(self, target):
        off = target - (self.pos + 2)
        assert -128 <= off < 0
        return self.raw(0xD0, off & 0xFF)

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
        assert 0 < off <= 127
        self._buf[placeholder_pos + 1] = off


def display_hex_byte(a, zp_src, screen_pos):
    a.LDA_zp(zp_src)
    a.raw(0x4A); a.raw(0x4A); a.raw(0x4A); a.raw(0x4A)  # LSR x4
    a.STA_abs(screen_pos)
    a.LDA_zp(zp_src)
    a.AND_imm(0x0F)
    a.STA_abs(screen_pos + 1)


def display_hex_word(a, zp_hi, zp_lo, screen_pos):
    display_hex_byte(a, zp_hi, screen_pos)
    display_hex_byte(a, zp_lo, screen_pos + 2)


def assemble():
    a = Asm6502()

    # ── Init ──
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()

    # 6510 port: default banking
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # Clear ZP vars
    a.LDA_imm(0x00)
    for zp in [ZP_CNT_LO, ZP_CNT_HI, ZP_SAVE_LO, ZP_SAVE_HI,
               ZP_PASS_LO, ZP_PASS_HI]:
        a.STA_zp(zp)

    # ── VIC setup ──
    a.LDA_imm(0x1B); a.STA_abs(0xD011)   # screen on
    a.LDA_imm(0x14); a.STA_abs(0xD018)   # default screen/char
    a.LDA_imm(0x00); a.STA_abs(0xD020)   # black border
    a.LDA_imm(0x00); a.STA_abs(0xD021)   # black background

    # ── Clear screen ──
    a.LDA_imm(0x20)  # space
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

    # ── Draw labels using PETSCII screen codes ──
    # Row 0: "TURBO TEST"
    for i, code in enumerate(petscii("TURBO TEST")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 0 * ROW + i)

    # Row 2: "COUNT"
    for i, code in enumerate(petscii("COUNT")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 2 * ROW + i)

    # Row 3: "SPEED"
    for i, code in enumerate(petscii("SPEED")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 3 * ROW + i)

    # Row 5: "PASS"
    for i, code in enumerate(petscii("PASS")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 5 * ROW + i)

    # Row 7: "NO IO IN LOOP"
    for i, code in enumerate(petscii("NO IO IN LOOP")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 7 * ROW + i)

    # ══════════════════════════════════════════════════════
    # Main loop
    # ══════════════════════════════════════════════════════
    main_loop = a.pos

    # Border = red during measurement
    a.LDA_imm(0x02); a.STA_abs(0xD020)

    # ── Wait for raster line 0 ──
    # Wait for NOT line 0 first (to sync)
    wait_not0 = a.pos
    a.LDA_abs(0xD012)
    a.BEQ_fwd()  # if line 0, wait more
    skip1 = a.pos - 2
    a.JMP(ROM_BASE + wait_not0)
    a.fixup_branch(skip1)
    # Now wait FOR line 0
    wait_0 = a.pos
    a.LDA_abs(0xD012)
    cmp0 = a.BNE_fwd()
    a.JMP(ROM_BASE + wait_0)

    # Oops, the BEQ/BNE logic is inverted. Let me redo.
    # Actually the gen approach above is broken. Let me simplify:

    # Clear and restart
    a._buf = a._buf[:a.pos]  # trim

    # Actually let me just redo the wait loop properly.
    # Re-assemble from main_loop
    a._buf = a._buf[:main_loop - 0]  # Hmm, pos is relative. Let me restart.

    # I need to redo this properly. Let me just write it simply.
    pass

    # OK, let me restart the assembler with a cleaner approach
    a = Asm6502()

    # ── CBM80 autostart header (required for 8K game CRT) ──
    # $8000-$8001: Cold start vector (indirect JMP target)
    # $8002-$8003: Warm start vector (NMI)
    # $8004-$8008: "CBM80" signature (PETSCII: $C3 $C2 $CD $38 $30)
    # Code entry point is at $8009.
    a.raw(0x09, 0x80)  # Cold start -> $8009
    a.raw(0x09, 0x80)  # Warm start -> $8009
    a.raw(0xC3, 0xC2, 0xCD, 0x38, 0x30)  # "CBM80"

    # ── Init ──
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # Clear ZP vars
    a.LDA_imm(0x00)
    for zp in [ZP_CNT_LO, ZP_CNT_HI, ZP_SAVE_LO, ZP_SAVE_HI,
               ZP_PASS_LO, ZP_PASS_HI]:
        a.STA_zp(zp)

    # VIC setup
    a.LDA_imm(0x1B); a.STA_abs(0xD011)
    a.LDA_imm(0x14); a.STA_abs(0xD018)
    a.LDA_imm(0x00); a.STA_abs(0xD020)
    a.LDA_imm(0x00); a.STA_abs(0xD021)

    # Clear screen
    a.LDA_imm(0x20)
    a.LDX_imm(0x00)
    sc = a.pos
    a.STA_absx(0x0400); a.STA_absx(0x0500)
    a.STA_absx(0x0600); a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(sc)

    # Color RAM: white on black
    a.LDA_imm(0x01)
    a.LDX_imm(0x00)
    cf = a.pos
    a.STA_absx(0xD800); a.STA_absx(0xD900)
    a.STA_absx(0xDA00); a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(cf)

    # Labels (PETSCII screen codes)
    for i, code in enumerate(petscii("TURBO CACHE TEST")):
        a.LDA_imm(code); a.STA_abs(SCREEN + i)
    for i, code in enumerate(petscii("COUNT")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 2*ROW + i)
    for i, code in enumerate(petscii("SPEED")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 3*ROW + i)
    for i, code in enumerate(petscii("PASS")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 5*ROW + i)
    for i, code in enumerate(petscii("NO IO IN HOT LOOP")):
        a.LDA_imm(code); a.STA_abs(SCREEN + 7*ROW + i)

    # Cyan for values
    a.LDA_imm(0x03)
    for col in range(6, 14):
        a.STA_abs(0xD800 + 2*ROW + col)
        a.STA_abs(0xD800 + 3*ROW + col)
        a.STA_abs(0xD800 + 5*ROW + col)
    # Light blue title
    a.LDA_imm(0x0E)
    for col in range(16):
        a.STA_abs(0xD800 + col)

    # ══════════════════════════════════════════════════════
    # Main measurement loop
    # ══════════════════════════════════════════════════════
    main_loop = a.pos

    # Border red during measurement
    a.LDA_imm(0x02); a.STA_abs(0xD020)

    # Clear counter
    a.LDA_imm(0x00); a.STA_zp(ZP_CNT_LO); a.STA_zp(ZP_CNT_HI)

    # ── Wait for raster line 250 (bottom of screen) ──
    wait_250 = a.pos
    a.LDA_abs(0xD012)
    a.CMP_imm(250)
    a.raw(0xD0, 0x100 - (a.pos + 2 - wait_250) & 0xFF)  # BNE wait_250

    # ── Wait for raster line 0 (top of screen) ──
    wait_0 = a.pos
    a.LDA_abs(0xD012)
    a.CMP_imm(0)
    a.raw(0xD0, 0x100 - (a.pos + 2 - wait_0) & 0xFF)  # BNE wait_0

    # ── HOT LOOP: pure ZP counting, no I/O ──
    # Run until we manually break after N iterations.
    # We'll count for 50000 iterations (fixed), then measure time via
    # raster position. Actually, let's count until raster reaches line 100.
    # But checking raster IS an I/O read. Hmm.
    #
    # Alternative: just count for a fixed large number and measure how
    # many raster lines elapsed. But that also needs I/O.
    #
    # Simplest approach: count iterations for a fixed raster interval.
    # Check raster ONCE per 256 lo-byte rollovers (every 256 iters).
    # This makes I/O << 1% of the loop.

    hot_loop = a.pos
    a.INC_zp(ZP_CNT_LO)           # 5 cycles
    a.raw(0xD0, 0x100 - (a.pos + 2 - hot_loop) & 0xFF)  # BNE hot_loop (3 cyc taken)

    # Lo-byte rolled over — increment hi byte and check raster
    a.INC_zp(ZP_CNT_HI)           # 5 cycles
    # Check if we've counted enough: hi byte >= $40 (= 16384 iterations)
    a.LDA_zp(ZP_CNT_HI)
    a.CMP_imm(0x60)  # 24576 iterations ($6000)
    a.raw(0x90, 0x100 - (a.pos + 2 - hot_loop) & 0xFF)  # BCC hot_loop

    # ── Measurement done ──
    # Border green
    a.LDA_imm(0x05); a.STA_abs(0xD020)

    # Read final raster position (this tells us elapsed time)
    a.LDA_abs(0xD012)
    a.STA_zp(ZP_TMP)

    # Save count
    a.LDA_zp(ZP_CNT_LO); a.STA_zp(ZP_SAVE_LO)
    a.LDA_zp(ZP_CNT_HI); a.STA_zp(ZP_SAVE_HI)

    # Display count at row 2, col 6 (use screen codes 0-F for hex)
    # PETSCII digits 0-9 are $30-$39, A-F are $01-$06
    # Actually let's just show raw hex using PETSCII
    # High nibble -> screen code, low nibble -> screen code
    # For simplicity, show the hex count directly

    # Display hex count at row 2, col 6-9
    # Hi byte
    a.LDA_zp(ZP_SAVE_HI)
    a.raw(0x4A); a.raw(0x4A); a.raw(0x4A); a.raw(0x4A)  # >> 4
    a.JSR(0x0000)  # -> hex_to_screen (placeholder)
    hex_jsr1 = a.pos - 3
    a.STA_abs(SCREEN + 2*ROW + 6)

    a.LDA_zp(ZP_SAVE_HI)
    a.AND_imm(0x0F)
    a.JSR(0x0000)  # placeholder
    hex_jsr2 = a.pos - 3
    a.STA_abs(SCREEN + 2*ROW + 7)

    a.LDA_zp(ZP_SAVE_LO)
    a.raw(0x4A); a.raw(0x4A); a.raw(0x4A); a.raw(0x4A)
    a.JSR(0x0000)  # placeholder
    hex_jsr3 = a.pos - 3
    a.STA_abs(SCREEN + 2*ROW + 8)

    a.LDA_zp(ZP_SAVE_LO)
    a.AND_imm(0x0F)
    a.JSR(0x0000)  # placeholder
    hex_jsr4 = a.pos - 3
    a.STA_abs(SCREEN + 2*ROW + 9)

    # Display raster end position at row 3, col 6-7
    a.LDA_zp(ZP_TMP)
    a.raw(0x4A); a.raw(0x4A); a.raw(0x4A); a.raw(0x4A)
    a.JSR(0x0000)  # placeholder
    hex_jsr5 = a.pos - 3
    a.STA_abs(SCREEN + 3*ROW + 6)

    a.LDA_zp(ZP_TMP)
    a.AND_imm(0x0F)
    a.JSR(0x0000)  # placeholder
    hex_jsr6 = a.pos - 3
    a.STA_abs(SCREEN + 3*ROW + 7)

    # Increment pass counter
    a.INC_zp(ZP_PASS_LO)
    skip_hi = a.BNE_fwd()
    a.INC_zp(ZP_PASS_HI)
    a.fixup_branch(skip_hi)

    # Display pass at row 5, col 6-9
    a.LDA_zp(ZP_PASS_HI)
    a.raw(0x4A); a.raw(0x4A); a.raw(0x4A); a.raw(0x4A)
    a.JSR(0x0000)  # placeholder
    hex_jsr7 = a.pos - 3
    a.STA_abs(SCREEN + 5*ROW + 6)

    a.LDA_zp(ZP_PASS_HI)
    a.AND_imm(0x0F)
    a.JSR(0x0000)
    hex_jsr8 = a.pos - 3
    a.STA_abs(SCREEN + 5*ROW + 7)

    a.LDA_zp(ZP_PASS_LO)
    a.raw(0x4A); a.raw(0x4A); a.raw(0x4A); a.raw(0x4A)
    a.JSR(0x0000)
    hex_jsr9 = a.pos - 3
    a.STA_abs(SCREEN + 5*ROW + 8)

    a.LDA_zp(ZP_PASS_LO)
    a.AND_imm(0x0F)
    a.JSR(0x0000)
    hex_jsrA = a.pos - 3
    a.STA_abs(SCREEN + 5*ROW + 9)

    # Border black
    a.LDA_imm(0x00); a.STA_abs(0xD020)

    # Loop back
    a.JMP(ROM_BASE + main_loop)

    # ══════════════════════════════════════════════════════
    # hex_to_screen: convert nibble (0-F) in A to PETSCII screen code
    # 0-9 -> $30-$39, A-F -> $01-$06
    # ══════════════════════════════════════════════════════
    hex_sub = a.addr
    a.CMP_imm(0x0A)
    branch_letter = a.BCS_fwd()
    # 0-9: add $30
    a.ADC_imm(0x30)  # carry clear from CMP < 10
    a.RTS()
    a.fixup_branch(branch_letter)
    # A-F: value 10-15 -> screen code $01-$06
    a.SEC()
    a.SBC_imm(9)  # 10->1, 11->2, ...
    a.RTS()

    # Fixup all JSR placeholders
    for jsr_pos in [hex_jsr1, hex_jsr2, hex_jsr3, hex_jsr4,
                    hex_jsr5, hex_jsr6, hex_jsr7, hex_jsr8,
                    hex_jsr9, hex_jsrA]:
        a._buf[jsr_pos + 1] = hex_sub & 0xFF
        a._buf[jsr_pos + 2] = (hex_sub >> 8) & 0xFF

    return a


def make_rom(asm):
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6, \
        f"Code too large: {len(code)} bytes (max {ROM_SIZE - 6})"

    rom = bytearray(b"\xAA" * ROM_SIZE)
    rom[:len(code)] = code

    # Vectors at end of ROM ($9FFA-$9FFF)
    entry = ROM_BASE
    rom[0x1FFA] = entry & 0xFF; rom[0x1FFB] = (entry >> 8) & 0xFF  # NMI
    rom[0x1FFC] = entry & 0xFF; rom[0x1FFD] = (entry >> 8) & 0xFF  # RESET
    rom[0x1FFE] = entry & 0xFF; rom[0x1FFF] = (entry >> 8) & 0xFF  # IRQ
    return bytes(rom)


def make_crt(rom, name):
    """Create an 8K game CRT (EXROM=0, GAME=1 -> 8K game mode, ROML at $8000)."""
    assert len(rom) == ROM_SIZE
    sig = b"C64 CARTRIDGE   "
    hdr = sig + struct.pack(">I", 64) + struct.pack(">H", 0x0100)
    # Cart type 0, EXROM=0, GAME=1 -> 8K game mode (ROML at $8000-$9FFF)
    hdr += struct.pack(">H", 0) + b"\x00\x01" + b"\x00" * 6
    hdr += name.encode("ascii")[:32].ljust(32, b"\x00")

    chip = b"CHIP" + struct.pack(">I", 16 + ROM_SIZE)
    chip += struct.pack(">HHH", 0, 0, ROM_BASE) + struct.pack(">H", ROM_SIZE)
    return hdr + chip + rom


def main():
    asm = assemble()
    rom = make_rom(asm)
    crt = make_crt(rom, "TURBO CACHE TEST")

    os.makedirs(OUT_DIR, exist_ok=True)
    crt_path = os.path.join(OUT_DIR, "turbo_test.crt")
    with open(crt_path, "wb") as f:
        f.write(crt)

    code = asm.build()
    print(f"Turbo Cache Test CRT")
    print(f"Code:   {len(code)} bytes at ${ROM_BASE:04X}")
    print(f"Output: {crt_path}")
    print()
    print("=== How It Works ===")
    print("Hot loop: INC $02 / BNE (pure ZP, NO I/O)")
    print("Counts 24576 ($6000) iterations per measurement.")
    print("Raster end position shows elapsed time.")
    print("Lower raster = faster CPU.")
    print()
    print("Key metric: PASS counter increment rate (visible on screen).")
    print("With cache working: PASS increments noticeably faster than 4x turbo alone.")


if __name__ == "__main__":
    main()
