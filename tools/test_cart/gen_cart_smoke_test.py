#!/usr/bin/env python3
"""
Cartridge smoke test — verifies basic Ultimax cart execution.

Uses bitmap mode to display a checkerboard pattern directly from memory,
avoiding any dependency on character ROM. Border color cycles to prove
the CPU is running.

Usage:
  python gen_cart_smoke_test.py
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

# Colors (C64 palette index)
BLACK  = 0x00
WHITE  = 0x01
RED    = 0x02
CYAN   = 0x03
PURPLE = 0x04
GREEN  = 0x05
BLUE   = 0x06
YELLOW = 0x07


# ─────────────────────────────────────────────────────────────────────────────
# Minimal 6502 assembler
# ─────────────────────────────────────────────────────────────────────────────

class Asm6502:
    """Append-only byte assembler with label/branch support."""

    def __init__(self):
        self._buf = bytearray()

    def raw(self, *bs: int) -> "Asm6502":
        self._buf.extend(bs)
        return self

    @property
    def pos(self) -> int:
        """Offset from start of buffer."""
        return len(self._buf)

    @property
    def addr(self) -> int:
        """Absolute ROM address of next byte."""
        return ROM_BASE + self.pos

    def SEI(self):   return self.raw(0x78)
    def CLD(self):   return self.raw(0xD8)
    def TXS(self):   return self.raw(0x9A)
    def INX(self):   return self.raw(0xE8)
    def NOP(self):   return self.raw(0xEA)
    def DEX(self):   return self.raw(0xCA)

    def LDA_imm(self, v):  return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v):  return self.raw(0xA2, v & 0xFF)
    def LDY_imm(self, v):  return self.raw(0xA0, v & 0xFF)
    def CMP_imm(self, v):  return self.raw(0xC9, v & 0xFF)

    def STA_zp(self, a):   return self.raw(0x85, a & 0xFF)
    def STA_abs(self, a):  return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)

    def JMP(self, addr: int):
        return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)

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

    def build(self) -> bytes:
        return bytes(self._buf)


# ─────────────────────────────────────────────────────────────────────────────
# ROM assembly
# ─────────────────────────────────────────────────────────────────────────────

def assemble_cart_smoke_test() -> Asm6502:
    """
    Cartridge Smoke Test — No character ROM required.

    Sets up bitmap mode and fills it with a checkerboard pattern.
    Cycles border colors to prove the CPU is executing.

    Test logic:
      1. Initialize VIC in bitmap mode (no character ROM needed)
      2. Fill bitmap RAM ($2000-$3FFF) with test pattern
      3. Cycle colors rapidly to show execution is ongoing
      4. Never depends on character ROM access
    """
    a = Asm6502()

    # ── Hard reset / init ────────────────────────────────────────────────────
    a.SEI()
    a.LDX_imm(0xFF)
    a.TXS()
    a.CLD()

    # 6510 processor port: LORAM=1, HIRAM=1, CHAREN=1
    a.LDA_imm(0x2F); a.STA_zp(0x00)     # direction register
    a.LDA_imm(0x37); a.STA_zp(0x01)     # data register

    # ── VIC-II setup: BITMAP mode (no character ROM needed) ──────────────────
    # D018 = 0x18: bitmap mode, screen at $0400, bitmap at $2000
    # This sets bit 3 (bitmap mode) in D018
    a.LDA_imm(0x0B); a.STA_abs(D011)    # screen off briefly (bit4=0)
    a.LDA_imm(0x18); a.STA_abs(D018)    # BITMAP MODE: screen@$0400, bitmap@$2000
    a.LDA_imm(BLUE); a.STA_abs(D020)    # blue border
    a.LDA_imm(BLUE); a.STA_abs(D021)    # blue background
    a.LDA_imm(0x1B); a.STA_abs(D011)    # screen on, BITMAP mode active
    a.LDA_imm(0xC8); a.STA_abs(D016)    # 40 col, multicolor off

    # ── Fill screen RAM $0400-$07FF with pattern (foreground/background colors) ─
    # In bitmap mode, screen RAM holds color info: low nibble=multicolor, high=opposite
    a.LDA_imm(0xFF)  # All bits on (white/bright)
    a.LDX_imm(0x00)
    screen_loop = a.pos
    a.STA_absx(0x0400)
    a.STA_absx(0x0500)
    a.STA_absx(0x0600)
    a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(screen_loop)

    # ── Fill bitmap RAM $2000-$3FFF with checkerboard pattern ────────────────
    # Bitmap RAM: each byte = 8 pixels. $AA = alternating pattern
    a.LDA_imm(0xAA)  # Checkerboard: 10101010
    a.LDX_imm(0x00)
    bitmap_loop_y = a.pos
    # Fill $2000-$27FF (one page)
    a.LDY_imm(0x00)
    bitmap_loop_x = a.pos
    a.STA_absx(0x2000)
    a.INX()
    a.BNE_back(bitmap_loop_x)

    # Second page: $2800-$2FFF
    a.LDX_imm(0x00)
    bitmap_loop_x2 = a.pos
    a.STA_absx(0x2800)
    a.INX()
    a.BNE_back(bitmap_loop_x2)

    # Third page: $3000-$37FF
    a.LDX_imm(0x00)
    bitmap_loop_x3 = a.pos
    a.STA_absx(0x3000)
    a.INX()
    a.BNE_back(bitmap_loop_x3)

    # Fourth page: $3800-$3FFF
    a.LDX_imm(0x00)
    bitmap_loop_x4 = a.pos
    a.STA_absx(0x3800)
    a.INX()
    a.BNE_back(bitmap_loop_x4)

    # ── Color cycling loop to show execution ──────────────────────────────────
    # Cycle border through colors to prove code is running
    color_loop = a.pos
    a.LDA_imm(RED); a.STA_abs(D020); a.LDX_imm(0xFF); a.INX(); a.BNE_back(a.pos - 1)
    a.LDA_imm(GREEN); a.STA_abs(D020); a.LDX_imm(0xFF); a.INX(); a.BNE_back(a.pos - 1)
    a.LDA_imm(CYAN); a.STA_abs(D020); a.LDX_imm(0xFF); a.INX(); a.BNE_back(a.pos - 1)
    a.LDA_imm(YELLOW); a.STA_abs(D020); a.LDX_imm(0xFF); a.INX(); a.BNE_back(a.pos - 1)
    a.JMP(ROM_BASE + color_loop)

    return a


# ─────────────────────────────────────────────────────────────────────────────
# ROM + CRT packaging
# ─────────────────────────────────────────────────────────────────────────────

def make_rom(asm: Asm6502) -> bytes:
    """Wrap assembled code in an 8KB ROM image with correct vectors."""
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6, \
        f"Code too large: {len(code)} bytes (max {ROM_SIZE - 6})"

    rom = bytearray(b"\xAA" * ROM_SIZE)
    rom[:len(code)] = code

    # Hardware vectors at $FFFA-$FFFF (all point to entry = $E000)
    entry = ROM_BASE
    for offset in (0x1FFA, 0x1FFC, 0x1FFE):
        rom[offset]     = entry & 0xFF
        rom[offset + 1] = (entry >> 8) & 0xFF

    return bytes(rom)


def make_crt(rom: bytes, name: str) -> bytes:
    """Wrap 8KB ROM in Ultimax CRT format."""
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
    assert len(header) == 64

    chip_sig  = b"CHIP"
    pkt_len   = struct.pack(">I", 16 + ROM_SIZE)
    chip_type = struct.pack(">H", 0)
    bank      = struct.pack(">H", 0)
    load_addr = struct.pack(">H", ROM_BASE)
    chip_size = struct.pack(">H", ROM_SIZE)

    chip = chip_sig + pkt_len + chip_type + bank + load_addr + chip_size

    return header + chip + rom


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main():
    asm  = assemble_cart_smoke_test()
    stem = "scpu_cart_smoke"
    desc = "Cart Smoke Test (bitmap mode, no character ROM)"

    rom = make_rom(asm)
    crt = make_crt(rom, "SCPU CART SMOKE")

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
    print("=== Expected Behavior ===")
    print("  Bitmap mode checkerboard pattern displayed")
    print("  Border cycles through: RED -> GREEN -> CYAN -> YELLOW (repeating)")
    print()
    print("  If you see the cycling colors:")
    print("    -> Cartridge loading and execution works!")
    print("    -> Character ROM issue is specific to text mode")
    print()
    print("  If you see no cycling colors:")
    print("    -> Cartridge loading or Ultimax mode is broken")


if __name__ == "__main__":
    main()
