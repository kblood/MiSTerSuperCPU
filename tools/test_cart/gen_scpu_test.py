#!/usr/bin/env python3
"""
SCPU VIC Read Test Cartridge Generator
=======================================
Generates an Ultimax-mode CRT file that definitively tests whether the VIC-II
is receiving corrupted data during c-access (screen RAM read) cycles.

The key question this answers (H23 vs H24 from HYPOTHESIS_TRACKER.md):
  H23: SDRAM dout_r is clobbered between CPUC read and VIC2 consume
  H24: RAM genuinely contains $00 (CPU path wrote $00 earlier)

Test logic:
  1. Fill screen RAM ($0400-$07FF) with $01 ('A' screencode)
  2. Fill color RAM ($D800-$DBFF) with white ($01)
  3. Loop: CPU reads back every screen RAM byte, checks for $01
     - GREEN border: CPU reads correct data throughout
     - RED  border:  CPU reads $00 somewhere (RAM itself corrupted)

Interpretation:
  '@' on screen + GREEN border → VIC reads $00, CPU reads $01
                                  → H23 or H27 CONFIRMED (read-side bug in FPGA)
  '@' on screen + RED  border  → CPU also reads $00
                                  → Write-side or RAM issue, not VIC read path
  All 'A' + green              → No artifact without KERNAL
                                  → Artifact is KERNAL/workload-specific (H25)

Ultimax mode (GAME=0, EXROM=1):
  $E000-$FFFF: Cartridge ROM (this code) — replaces KERNAL entirely
  $0000-$0FFF: RAM accessible to CPU (includes screen RAM $0400-$07FF)
  $D000-$DFFF: I/O registers (VIC, SID, CIA)
  $1000-$7FFF: Open bus (not used by CPU in Ultimax mode)

Usage:
  python gen_scpu_test.py           # generates scpu_vic_test.crt + .bin
  python gen_scpu_test.py --stress  # adds I/O bus stress during verify loop
"""

import struct
import os
import sys

ROM_SIZE = 0x2000    # 8 KB
ROM_BASE = 0xE000    # Ultimax cartridge hi bank

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# VIC-II registers
D011 = 0xD011   # screen control
D016 = 0xD016   # horizontal control
D018 = 0xD018   # memory layout
D020 = 0xD020   # border color
D021 = 0xD021   # background color

# CIA1
DC0E = 0xDC0E   # CIA1 timer A control

# Colors (C64 palette index)
BLACK  = 0x00
WHITE  = 0x01
RED    = 0x02
CYAN   = 0x03
PURPLE = 0x04
GREEN  = 0x05
BLUE   = 0x06

SCREEN_FILL = 0x01  # 'A' screencode — differs visually from $00 ('@')
COLOR_FILL  = WHITE


# ─────────────────────────────────────────────────────────────────────────────
# Minimal 6502 assembler (enough for our needs)
# ─────────────────────────────────────────────────────────────────────────────

class Asm6502:
    """Append-only byte assembler with label/branch support."""

    def __init__(self):
        self._buf = bytearray()

    # ── Raw emit ────────────────────────────────────────────────────────────

    def raw(self, *bs: int) -> "Asm6502":
        self._buf.extend(bs)
        return self

    # ── Position helpers ────────────────────────────────────────────────────

    @property
    def pos(self) -> int:
        """Offset from start of buffer (= offset from ROM_BASE)."""
        return len(self._buf)

    @property
    def addr(self) -> int:
        """Absolute ROM address of next byte."""
        return ROM_BASE + self.pos

    # ── Instruction builders ─────────────────────────────────────────────────

    def SEI(self):   return self.raw(0x78)
    def CLD(self):   return self.raw(0xD8)
    def TXS(self):   return self.raw(0x9A)
    def INX(self):   return self.raw(0xE8)

    def LDA_imm(self, v):  return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v):  return self.raw(0xA2, v & 0xFF)
    def CMP_imm(self, v):  return self.raw(0xC9, v & 0xFF)

    def STA_zp(self, a):   return self.raw(0x85, a & 0xFF)
    def STA_abs(self, a):  return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)

    def JMP(self, addr: int):
        return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)

    # ── Branch helpers ───────────────────────────────────────────────────────

    def BNE_back(self, target_buf_pos: int) -> "Asm6502":
        """Emit BNE to a position earlier in the buffer (backward branch)."""
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0, f"BNE backward out of range: {off}"
        return self.raw(0xD0, off & 0xFF)

    def BNE_fwd(self) -> int:
        """Emit BNE with a zero-placeholder; return the fixup index."""
        idx = self.pos
        self.raw(0xD0, 0x00)
        return idx

    def fixup_BNE(self, placeholder_pos: int):
        """Patch a forward BNE placeholder to jump to current position."""
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127, f"Forward BNE offset {off} out of range"
        self._buf[placeholder_pos + 1] = off

    # ── Final output ─────────────────────────────────────────────────────────

    def build(self) -> bytes:
        return bytes(self._buf)


# ─────────────────────────────────────────────────────────────────────────────
# ROM assembly
# ─────────────────────────────────────────────────────────────────────────────

def assemble_test1_basic() -> Asm6502:
    """
    Test 1 — Fill & Verify (no extra bus stress)
    Definitive test for H23/H27 vs H24.
    """
    a = Asm6502()

    # ── Hard reset / init ────────────────────────────────────────────────────
    # Entry at $E000 (all vectors point here)
    a.SEI()
    a.LDX_imm(0xFF)
    a.TXS()                              # stack at $01FF
    a.CLD()

    # 6510 processor port: LORAM=1, HIRAM=1, CHAREN=1 (RAM+I/O visible)
    a.LDA_imm(0x2F); a.STA_zp(0x00)     # direction register
    a.LDA_imm(0x37); a.STA_zp(0x01)     # data register

    # ── VIC-II setup ─────────────────────────────────────────────────────────
    a.LDA_imm(0x0B); a.STA_abs(D011)    # screen off briefly (bit4=0)
    a.LDA_imm(0x14); a.STA_abs(D018)    # screen@$0400, chars@$1000
    a.LDA_imm(BLUE); a.STA_abs(D020)    # blue border
    a.LDA_imm(BLUE); a.STA_abs(D021)    # blue background
    a.LDA_imm(0x1B); a.STA_abs(D011)    # screen on, normal mode
    a.LDA_imm(0xC8); a.STA_abs(D016)    # 40 col, normal multicolor off

    # ── Fill screen RAM $0400-$07FF with SCREEN_FILL ($01 = 'A') ─────────────
    a.LDA_imm(SCREEN_FILL)
    a.LDX_imm(0x00)
    fill_loop = a.pos
    a.STA_absx(0x0400)
    a.STA_absx(0x0500)
    a.STA_absx(0x0600)
    a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(fill_loop)

    # ── Fill color RAM $D800-$DBFF with COLOR_FILL ($01 = white) ─────────────
    a.LDA_imm(COLOR_FILL)
    a.LDX_imm(0x00)
    color_loop = a.pos
    a.STA_absx(0xD800)
    a.STA_absx(0xD900)
    a.STA_absx(0xDA00)
    a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(color_loop)

    # Green border: fill complete, screen and color RAM initialized
    a.LDA_imm(GREEN); a.STA_abs(D020)

    # ── Main verify loop ─────────────────────────────────────────────────────
    # Continuously reads back all screen RAM and checks for $01.
    # Any byte ≠ $01 means the CPU sees corrupted data → red border.
    main_loop = a.pos
    a.LDX_imm(0x00)

    verify_loop = a.pos
    a.LDA_absx(0x0400); a.CMP_imm(SCREEN_FILL); bne1 = a.BNE_fwd()
    a.LDA_absx(0x0500); a.CMP_imm(SCREEN_FILL); bne2 = a.BNE_fwd()
    a.LDA_absx(0x0600); a.CMP_imm(SCREEN_FILL); bne3 = a.BNE_fwd()
    a.LDA_absx(0x0700); a.CMP_imm(SCREEN_FILL); bne4 = a.BNE_fwd()
    a.INX()
    a.BNE_back(verify_loop)

    # All 256×4 bytes verified OK → keep/restore green border
    a.LDA_imm(GREEN); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    # ── CPU read-back failure handler ─────────────────────────────────────────
    # Red border = CPU itself reads wrong data from screen RAM.
    # This is distinct from VIC reading wrong data (which shows '@' on screen).
    for fwd in (bne1, bne2, bne3, bne4):
        a.fixup_BNE(fwd)
    a.LDA_imm(RED); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    return a


def assemble_test2_stress() -> Asm6502:
    """
    Test 2 — Bus Stress variant
    Same as Test 1 but the verify loop also hammers CIA1 to generate
    extra I/O bus activity, stressing the EXT/DMA SDRAM access window.
    """
    a = Asm6502()

    # Same init as test 1
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)
    a.LDA_imm(0x0B); a.STA_abs(D011)
    a.LDA_imm(0x14); a.STA_abs(D018)
    a.LDA_imm(BLUE); a.STA_abs(D020)
    a.LDA_imm(BLUE); a.STA_abs(D021)
    a.LDA_imm(0x1B); a.STA_abs(D011)
    a.LDA_imm(0xC8); a.STA_abs(D016)

    a.LDA_imm(SCREEN_FILL); a.LDX_imm(0x00)
    fill_loop = a.pos
    a.STA_absx(0x0400); a.STA_absx(0x0500)
    a.STA_absx(0x0600); a.STA_absx(0x0700)
    a.INX(); a.BNE_back(fill_loop)

    a.LDA_imm(COLOR_FILL); a.LDX_imm(0x00)
    color_loop = a.pos
    a.STA_absx(0xD800); a.STA_absx(0xD900)
    a.STA_absx(0xDA00); a.STA_absx(0xDB00)
    a.INX(); a.BNE_back(color_loop)

    a.LDA_imm(GREEN); a.STA_abs(D020)

    # Main loop — with CIA1 I/O poke between each screen column check
    # This increases the density of I/O bus transactions, mimicking the
    # EXT/DMA-phase SDRAM access patterns that may clobber dout_r (H23).
    main_loop = a.pos
    a.LDX_imm(0x00)

    verify_loop = a.pos
    # Poke CIA1 control register (read-modify-write style I/O activity)
    # Use STA $DC0E (CIA1 Timer A control) — harmless: SEI means no IRQ fires
    a.LDA_imm(0x01); a.STA_abs(DC0E)    # CIA1 Timer A: start (harmless, IRQ masked)
    a.LDA_imm(0x00); a.STA_abs(DC0E)    # CIA1 Timer A: stop
    # Now verify screen RAM
    a.LDA_absx(0x0400); a.CMP_imm(SCREEN_FILL); bne1 = a.BNE_fwd()
    a.LDA_absx(0x0500); a.CMP_imm(SCREEN_FILL); bne2 = a.BNE_fwd()
    a.LDA_absx(0x0600); a.CMP_imm(SCREEN_FILL); bne3 = a.BNE_fwd()
    a.LDA_absx(0x0700); a.CMP_imm(SCREEN_FILL); bne4 = a.BNE_fwd()
    a.INX()
    a.BNE_back(verify_loop)

    a.LDA_imm(GREEN); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    for fwd in (bne1, bne2, bne3, bne4):
        a.fixup_BNE(fwd)
    a.LDA_imm(RED); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    return a


# ─────────────────────────────────────────────────────────────────────────────
# ROM + CRT packaging
# ─────────────────────────────────────────────────────────────────────────────

def make_rom(asm: Asm6502) -> bytes:
    """Wrap assembled code in an 8KB ROM image with correct vectors."""
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6, \
        f"Code too large: {len(code)} bytes (max {ROM_SIZE - 6})"

    rom = bytearray(b"\xAA" * ROM_SIZE)   # fill unused space with $AA
    rom[:len(code)] = code

    # Hardware vectors at $FFFA-$FFFF (all point to entry = $E000)
    entry = ROM_BASE
    for offset in (0x1FFA, 0x1FFC, 0x1FFE):   # NMI, RESET, IRQ
        rom[offset]     = entry & 0xFF
        rom[offset + 1] = (entry >> 8) & 0xFF

    return bytes(rom)


def make_crt(rom: bytes, name: str) -> bytes:
    """Wrap 8KB ROM in Ultimax CRT format (hardware type 0, EXROM=1, GAME=0)."""
    assert len(rom) == ROM_SIZE

    # ── 64-byte CRT file header ───────────────────────────────────────────────
    sig      = b"C64 CARTRIDGE   "           # 16 bytes (3 trailing spaces)
    hdr_len  = struct.pack(">I", 64)
    version  = struct.pack(">H", 0x0100)
    hw_type  = struct.pack(">H", 0)          # 0 = Generic cartridge
    exrom    = b"\x01"                        # Ultimax: EXROM=1
    game     = b"\x00"                        # Ultimax: GAME=0
    reserved = b"\x00" * 6
    crt_name = name.encode("ascii", errors="replace")[:32].ljust(32, b"\x00")

    header = sig + hdr_len + version + hw_type + exrom + game + reserved + crt_name
    assert len(header) == 64

    # ── 16-byte CHIP packet header + ROM data ─────────────────────────────────
    chip_sig  = b"CHIP"
    pkt_len   = struct.pack(">I", 16 + ROM_SIZE)
    chip_type = struct.pack(">H", 0)          # 0 = ROM
    bank      = struct.pack(">H", 0)
    load_addr = struct.pack(">H", ROM_BASE)   # $E000
    chip_size = struct.pack(">H", ROM_SIZE)   # $2000

    chip = chip_sig + pkt_len + chip_type + bank + load_addr + chip_size
    assert len(chip) == 16

    return header + chip + rom


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main():
    stress = "--stress" in sys.argv

    if stress:
        asm  = assemble_test2_stress()
        stem = "scpu_vic_stress"
        desc = "Bus Stress Test (I/O hammering during verify)"
    else:
        asm  = assemble_test1_basic()
        stem = "scpu_vic_test"
        desc = "Fill & Verify (definitive H23 vs H24 test)"

    rom = make_rom(asm)
    crt = make_crt(rom, stem.upper().replace("_", " ")[:32])

    os.makedirs(OUT_DIR, exist_ok=True)
    crt_path = os.path.join(OUT_DIR, f"{stem}.crt")
    bin_path = os.path.join(OUT_DIR, f"{stem}.bin")

    with open(crt_path, "wb") as f: f.write(crt)
    with open(bin_path, "wb") as f: f.write(rom)

    print(f"Test:   {desc}")
    print(f"Code:   {len(asm.build())} bytes at $E000")
    print(f"Output: {crt_path}")
    print(f"        {bin_path}")
    print()
    print("=== Interpretation ===")
    print("  All 'A' on screen + GREEN border")
    print("    -> No '@' artifact without KERNAL -> bug is KERNAL/workload-specific")
    print()
    print("  '@' on screen + GREEN border")
    print("    -> VIC reads $00, CPU reads $01 -> H23 or H27 CONFIRMED")
    print("    -> SDRAM dout_r is clobbered between c-access read and VIC consume")
    print("    -> Fix: implement dedicated VIC data hold register")
    print()
    print("  '@' on screen + RED border")
    print("    -> CPU also reads $00 -> write-side or RAM init issue")
    print()
    print("=== Deploy ===")
    print(f"  scp {crt_path} root@192.168.50.130:/media/fat/")
    print("  Then on MiSTer OSD: load cartridge -> scpu_vic_test.crt")
    print("  Run with SuperCPU ENABLED to reproduce the artifact condition.")


if __name__ == "__main__":
    main()
