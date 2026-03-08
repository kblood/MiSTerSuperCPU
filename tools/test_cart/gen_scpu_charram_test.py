#!/usr/bin/env python3
"""
SCPU VIC Test - Text mode with character patterns in RAM.

Works in Ultimax mode by keeping ALL data within $0000-$0FFF (CPU-accessible).
Character patterns are stored at $0800-$0FFF instead of using character ROM.

Memory layout (all within CPU-accessible range):
  $0000-$00FF: Zero page (processor port at $00/$01)
  $0100-$01FF: Stack
  $0200-$03FF: Free
  $0400-$07E7: Screen RAM (1000 bytes, used by VIC for screencodes)
  $0800-$0FFF: Character RAM (2KB, custom character set)
  $D000-$DFFF: I/O (VIC, SID, CIA — always accessible)
  $E000-$FFFF: Cartridge ROM (this code)

VIC configuration:
  D018 = $12: screen@$0400, characters@$0800 (RAM, not ROM!)
  This means VIC reads character patterns from RAM we control.

Test logic:
  1. Define character patterns in RAM at $0800:
     - Char $00 = empty (all $00) — if VIC reads corrupted $00, screen shows blank
     - Char $01 = filled block ($FF) — our fill value, shows solid white block
  2. Fill screen RAM ($0400-$07E7) with $01
  3. Fill color RAM ($D800-$DBFF) with white
  4. Verify loop: CPU reads screen RAM, checks for $01
     - GREEN border = CPU reads correct
     - RED border = CPU reads wrong

Interpretation:
  All white blocks + GREEN border → Working correctly
  Black gaps appearing + GREEN border → H23/H27 CONFIRMED (VIC reads $00, CPU reads $01)
  Black gaps + RED border → CPU also reads wrong (write-side issue)

Usage:
  python gen_scpu_charram_test.py
"""

import struct
import os

ROM_SIZE = 0x2000
ROM_BASE = 0xE000
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# VIC-II registers
D011 = 0xD011
D016 = 0xD016
D018 = 0xD018
D020 = 0xD020
D021 = 0xD021

# Colors
BLACK = 0x00
WHITE = 0x01
RED   = 0x02
GREEN = 0x05
BLUE  = 0x06


class Asm6502:
    def __init__(self):
        self._buf = bytearray()

    def raw(self, *bs): self._buf.extend(bs); return self

    @property
    def pos(self): return len(self._buf)

    @property
    def addr(self): return ROM_BASE + self.pos

    def SEI(self):   return self.raw(0x78)
    def CLD(self):   return self.raw(0xD8)
    def TXS(self):   return self.raw(0x9A)
    def INX(self):   return self.raw(0xE8)
    def NOP(self):   return self.raw(0xEA)

    def LDA_imm(self, v):  return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v):  return self.raw(0xA2, v & 0xFF)
    def CMP_imm(self, v):  return self.raw(0xC9, v & 0xFF)

    def STA_zp(self, a):   return self.raw(0x85, a & 0xFF)
    def STA_abs(self, a):  return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)

    def JMP(self, addr):
        return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)

    def BNE_back(self, target_buf_pos):
        off = target_buf_pos - (self.pos + 2)
        assert -128 <= off < 0
        return self.raw(0xD0, off & 0xFF)

    def BNE_fwd(self):
        idx = self.pos
        self.raw(0xD0, 0x00)
        return idx

    def fixup_branch(self, placeholder_pos):
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127
        self._buf[placeholder_pos + 1] = off

    def build(self): return bytes(self._buf)


def assemble() -> Asm6502:
    a = Asm6502()

    # ── Init ─────────────────────────────────────────────────────────────────
    a.SEI()
    a.LDX_imm(0xFF); a.TXS(); a.CLD()

    # 6510 processor port
    a.LDA_imm(0x2F); a.STA_zp(0x00)
    a.LDA_imm(0x37); a.STA_zp(0x01)

    # ── VIC-II setup ─────────────────────────────────────────────────────────
    a.LDA_imm(0x0B); a.STA_abs(D011)    # screen off
    # D018 = $12: screen@$0400, chars@$0800 (RAM!)
    # bits 7-4 = 0001 (screen at $0400)
    # bits 3-1 = 001  (char data at $0800 — RAM, not ROM)
    a.LDA_imm(0x12); a.STA_abs(D018)
    a.LDA_imm(BLACK); a.STA_abs(D020)   # black border initially
    a.LDA_imm(BLUE); a.STA_abs(D021)    # blue background
    a.LDA_imm(0xC8); a.STA_abs(D016)    # 40 col

    # ── Step 1: Define character patterns in RAM at $0800 ────────────────────
    # Character $00 (8 bytes at $0800-$0807): ALL ZEROS = blank character
    # Character $01 (8 bytes at $0808-$080F): ALL $FF = solid filled block
    #
    # We fill $0800-$0FFF: first 8 bytes = $00, next 8 bytes = $FF,
    # rest = $00 (other chars are blank)

    # First: zero out all character RAM ($0800-$0FFF)
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

    # Now define character $01 at $0808-$080F: solid block ($FF)
    a.LDA_imm(0xFF)
    a.STA_abs(0x0808)
    a.STA_abs(0x0809)
    a.STA_abs(0x080A)
    a.STA_abs(0x080B)
    a.STA_abs(0x080C)
    a.STA_abs(0x080D)
    a.STA_abs(0x080E)
    a.STA_abs(0x080F)

    # ── Step 2: Fill screen RAM with $01 (our filled-block character) ────────
    # Screen RAM $0400-$07E7 (1000 bytes). Fill all 4 pages for simplicity.
    a.LDA_imm(0x01)
    a.LDX_imm(0x00)
    screen_fill = a.pos
    a.STA_absx(0x0400)
    a.STA_absx(0x0500)
    a.STA_absx(0x0600)
    a.STA_absx(0x0700)
    a.INX()
    a.BNE_back(screen_fill)

    # ── Step 3: Fill color RAM with WHITE ────────────────────────────────────
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
    a.LDA_imm(0x1B); a.STA_abs(D011)    # screen on, text mode

    # Border green = fill complete
    a.LDA_imm(GREEN); a.STA_abs(D020)

    # ── Step 4: Main verify loop ─────────────────────────────────────────────
    # Read back screen RAM, check all bytes = $01
    # GREEN border = CPU reads correct data
    # RED border = CPU reads wrong data
    #
    # LOOK AT THE SCREEN:
    #   All white = VIC reads $01, displays filled block → working
    #   Black gaps = VIC reads $00, displays blank char → H23/H27!
    main_loop = a.pos
    a.LDX_imm(0x00)

    verify = a.pos
    a.LDA_absx(0x0400)
    a.CMP_imm(0x01)
    fail = a.BNE_fwd()
    a.LDA_absx(0x0500)
    a.CMP_imm(0x01)
    fail2 = a.BNE_fwd()
    a.LDA_absx(0x0600)
    a.CMP_imm(0x01)
    fail3 = a.BNE_fwd()
    a.LDA_absx(0x0700)
    a.CMP_imm(0x01)
    fail4 = a.BNE_fwd()
    a.INX()
    a.BNE_back(verify)

    # All OK
    a.LDA_imm(GREEN); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    # CPU read mismatch
    for f in (fail, fail2, fail3, fail4):
        a.fixup_branch(f)
    a.LDA_imm(RED); a.STA_abs(D020)
    a.JMP(ROM_BASE + main_loop)

    return a


def make_rom(asm):
    code = asm.build()
    assert len(code) <= ROM_SIZE - 6
    rom = bytearray(b"\xAA" * ROM_SIZE)
    rom[:len(code)] = code
    entry = ROM_BASE
    for offset in (0x1FFA, 0x1FFC, 0x1FFE):
        rom[offset]     = entry & 0xFF
        rom[offset + 1] = (entry >> 8) & 0xFF
    return bytes(rom)


def make_crt(rom, name):
    assert len(rom) == ROM_SIZE
    sig      = b"C64 CARTRIDGE   "
    hdr_len  = struct.pack(">I", 64)
    version  = struct.pack(">H", 0x0100)
    hw_type  = struct.pack(">H", 0)
    exrom    = b"\x01"
    game     = b"\x00"
    reserved = b"\x00" * 6
    crt_name = name.encode("ascii")[:32].ljust(32, b"\x00")
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
    asm = assemble()
    rom = make_rom(asm)
    crt = make_crt(rom, "SCPU CHARRAM TEST")

    os.makedirs(OUT_DIR, exist_ok=True)
    crt_path = os.path.join(OUT_DIR, "scpu_charram_test.crt")
    bin_path = os.path.join(OUT_DIR, "scpu_charram_test.bin")

    with open(crt_path, "wb") as f: f.write(crt)
    with open(bin_path, "wb") as f: f.write(rom)

    print(f"Test:   Text mode with char patterns in RAM (Ultimax-safe)")
    print(f"Code:   {len(asm.build())} bytes at $E000")
    print(f"Output: {crt_path}")
    print(f"        {bin_path}")
    print()
    print("=== How it works ===")
    print("  Character $00 at $0800 = blank (all zeros)")
    print("  Character $01 at $0808 = solid white block ($FF)")
    print("  Screen RAM filled with $01 (solid blocks)")
    print("  D018 = $12: chars at $0800 (RAM), screen at $0400")
    print()
    print("=== Interpreting Results ===")
    print()
    print("  All white + GREEN border")
    print("    -> VIC reads $01, CPU reads $01 -> working correctly")
    print()
    print("  BLACK GAPS appearing + GREEN border")
    print("    -> H23/H27 CONFIRMED!")
    print("    -> VIC reads $00 (blank char), CPU reads $01 (correct)")
    print("    -> SDRAM data clobbered on VIC read path")
    print()
    print("  BLACK GAPS + RED border")
    print("    -> Both CPU and VIC read wrong (write-side issue)")


if __name__ == "__main__":
    main()
