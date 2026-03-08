#!/usr/bin/env python3
"""
SCPU VIC Bitmap Read Test - Detects H23/H27 corruption in bitmap mode.

Uses bitmap mode (no character ROM dependency) to test whether VIC-II receives
corrupted SDRAM data during read access while CPU reads correct data.

Test logic:
  1. Fill bitmap RAM ($2000-$3FFF) with alternating pattern (rows of $AA and $55)
  2. Fill color RAM ($D800-$DBFF) with alternating colors (white and black)
  3. CPU loop: continuously read back bitmap and color RAM
     - GREEN border: all reads match expected values
     - RED border: any read returned wrong data
  4. VIC-II simultaneously reads same RAM to display bitmap

Interpretation:
  Visual pattern OK + GREEN border    → No corruption, system working
  Visual pattern corrupted + GREEN    → H23/H27 CONFIRMED: VIC read corruption
  Visual pattern corrupted + RED      → CPU also reads wrong (write-side issue)

Usage:
  python gen_scpu_bitmap_test.py
"""

import struct
import os
import sys

ROM_SIZE = 0x2000    # 8 KB
ROM_BASE = 0xE000    # Ultimax cartridge

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# VIC-II registers
D011 = 0xD011   # screen control
D016 = 0xD016   # horizontal control
D018 = 0xD018   # memory layout (bitmap mode)
D020 = 0xD020   # border color
D021 = 0xD021   # background color

# Colors
BLACK  = 0x00
WHITE  = 0x01
RED    = 0x02
GREEN  = 0x05


class Asm6502:
    """Minimal 6502 assembler."""
    def __init__(self):
        self._buf = bytearray()

    def raw(self, *bs: int) -> "Asm6502":
        self._buf.extend(bs)
        return self

    @property
    def pos(self) -> int:
        return len(self._buf)

    @property
    def addr(self) -> int:
        return ROM_BASE + self.pos

    def SEI(self):   return self.raw(0x78)
    def CLD(self):   return self.raw(0xD8)
    def TXS(self):   return self.raw(0x9A)
    def INX(self):   return self.raw(0xE8)
    def DEX(self):   return self.raw(0xCA)
    def NOP(self):   return self.raw(0xEA)

    def LDA_imm(self, v):  return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v):  return self.raw(0xA2, v & 0xFF)
    def LDY_imm(self, v):  return self.raw(0xA0, v & 0xFF)
    def CMP_imm(self, v):  return self.raw(0xC9, v & 0xFF)
    def CPX_imm(self, v):  return self.raw(0xE0, v & 0xFF)

    def STA_zp(self, a):   return self.raw(0x85, a & 0xFF)
    def STA_abs(self, a):  return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_abs(self, a):  return self.raw(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)

    def JMP(self, addr: int):
        return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)

    def BNE_back(self, target_buf_pos: int) -> "Asm6502":
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0, f"BNE backward out of range: {off}"
        return self.raw(0xD0, off & 0xFF)

    def BNE_fwd(self) -> int:
        idx = self.pos
        self.raw(0xD0, 0x00)
        return idx

    def BEQ_fwd(self) -> int:
        idx = self.pos
        self.raw(0xF0, 0x00)
        return idx

    def fixup_branch(self, placeholder_pos: int):
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127, f"Forward branch offset {off} out of range"
        self._buf[placeholder_pos + 1] = off

    def build(self) -> bytes:
        return bytes(self._buf)


def assemble_bitmap_test() -> Asm6502:
    """
    Bitmap mode VIC test - detects H23/H27 SDRAM corruption.

    The test fills bitmap and color RAM with distinctive patterns,
    then loops verifying the CPU reads match expected values while
    VIC displays the bitmap. Visual corruption + GREEN border = H23/H27.
    """
    a = Asm6502()

    # ── Init ─────────────────────────────────────────────────────────────────
    a.SEI()
    a.LDX_imm(0xFF)
    a.TXS()
    a.CLD()

    # 6510 processor port
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # ── VIC-II setup: BITMAP mode ────────────────────────────────────────────
    # D018 = $18: bitmap mode, screen@$0400, bitmap@$2000
    a.LDA_imm(0x0B); a.STA_abs(D011)    # screen off briefly
    a.LDA_imm(0x18); a.STA_abs(D018)    # BITMAP MODE
    a.LDA_imm(BLACK); a.STA_abs(D020)   # black border
    a.LDA_imm(BLACK); a.STA_abs(D021)   # black background
    a.LDA_imm(0x1B); a.STA_abs(D011)    # screen on, bitmap mode
    a.LDA_imm(0xC8); a.STA_abs(D016)    # 40 col

    # ── Fill bitmap RAM with test pattern ────────────────────────────────────
    # Bitmap is 8KB ($2000-$3FFF): 4 pages of 2KB each
    # Fill with $AA (10101010) = checkerboard pattern
    a.LDA_imm(0xAA)

    # Fill page 1: $2000-$27FF (2048 bytes)
    a.LDX_imm(0x00)
    fill_page1 = a.pos
    a.STA_absx(0x2000)
    a.INX()
    a.BNE_back(fill_page1)

    # Fill page 2: $2800-$2FFF
    a.LDX_imm(0x00)
    fill_page2 = a.pos
    a.STA_absx(0x2800)
    a.INX()
    a.BNE_back(fill_page2)

    # Fill page 3: $3000-$37FF
    a.LDX_imm(0x00)
    fill_page3 = a.pos
    a.STA_absx(0x3000)
    a.INX()
    a.BNE_back(fill_page3)

    # Fill page 4: $3800-$3FFF
    a.LDX_imm(0x00)
    fill_page4 = a.pos
    a.STA_absx(0x3800)
    a.INX()
    a.BNE_back(fill_page4)

    # ── Fill color RAM with alternating pattern ──────────────────────────────
    # Odd bytes: white (for $AA bitmap rows)
    # Even bytes: black (for $55 bitmap rows)
    # This makes pattern visually distinctive
    a.LDA_imm(WHITE)
    a.LDX_imm(0x00)

    color_fill = a.pos
    a.STA_absx(0xD800)
    a.STA_absx(0xD900)
    a.STA_absx(0xDA00)
    a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(color_fill)

    # ── Main verify loop ────────────────────────────────────────────────────
    # Read back 256 bytes of bitmap RAM each pass.
    # GREEN border = all reads matched $AA (CPU sees correct data)
    # RED border   = CPU read wrong value
    #
    # Key diagnostic:
    #   Flickering lines on screen + GREEN border = H23/H27 CONFIRMED
    #   Flickering lines on screen + RED border   = write-side / timing issue

    main_loop = a.pos
    a.LDX_imm(0x00)

    verify_loop = a.pos
    a.LDA_absx(0x2000)
    a.CMP_imm(0xAA)
    fail = a.BNE_fwd()
    a.INX()
    a.BNE_back(verify_loop)

    # All 256 reads matched $AA — CPU data is correct
    a.LDA_imm(GREEN); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    # At least one read returned wrong value — CPU data corrupted
    a.fixup_branch(fail)
    a.LDA_imm(RED); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    return a


def make_rom(asm: Asm6502) -> bytes:
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6

    rom = bytearray(b"\xAA" * ROM_SIZE)
    rom[:len(code)] = code

    entry = ROM_BASE
    for offset in (0x1FFA, 0x1FFC, 0x1FFE):
        rom[offset]     = entry & 0xFF
        rom[offset + 1] = (entry >> 8) & 0xFF

    return bytes(rom)


def make_crt(rom: bytes, name: str) -> bytes:
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


def main():
    asm  = assemble_bitmap_test()
    stem = "scpu_bitmap_test"

    rom = make_rom(asm)
    crt = make_crt(rom, "SCPU BITMAP TEST")

    os.makedirs(OUT_DIR, exist_ok=True)
    crt_path = os.path.join(OUT_DIR, f"{stem}.crt")
    bin_path = os.path.join(OUT_DIR, f"{stem}.bin")

    with open(crt_path, "wb") as f: f.write(crt)
    with open(bin_path, "wb") as f: f.write(rom)

    print(f"Test:   Bitmap Mode VIC Read Test (H23/H27 detection)")
    print(f"Code:   {len(asm.build())} bytes at $E000")
    print(f"Output: {crt_path}")
    print(f"        {bin_path}")
    print()
    print("=== Expected Behavior ===")
    print()
    print("  Visual: Horizontal striped bitmap pattern (white stripes on black)")
    print("  Border: Should cycle GREEN -> BLACK -> GREEN...")
    print()
    print("=== Interpreting Results ===")
    print()
    print("  Pattern OK + GREEN border")
    print("    -> No corruption, system working normally")
    print()
    print("  Pattern VISUALLY CORRUPTED + GREEN border")
    print("    -> H23 or H27 CONFIRMED!")
    print("    -> VIC reads corrupted data, CPU reads correct data")
    print("    -> SDRAM dout_r clobbered between c-access read and VIC latch")
    print()
    print("  Pattern CORRUPTED + RED border")
    print("    -> CPU also reads wrong values")
    print("    -> Issue is write-side or RAM initialization, not VIC read path")
    print()
    print("=== Test Conditions ===")
    print("  Run with SuperCPU ENABLED to reproduce artifact")
    print("  Toggle SuperCPU OFF to see baseline (should show clean pattern)")


if __name__ == "__main__":
    main()
