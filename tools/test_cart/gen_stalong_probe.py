#!/usr/bin/env python3
"""HW bisect for STA al / LDA al crash.

Builds three PRGs that walk markers across the screen before/around a
long-mode opcode. The CRT-wrapped PRG runs from cart-boot so a fault
just freezes the CPU (no BASIC cold-start to mask the failure point).

Marker convention (writes to $0400 row 0):
  pos 0-3:  before STA al (#$01 white)
  pos 4-7:  STA al $0000xx fired (#$05 green if CPU survived through here)
  pos 8-11: after STA al    (#$0A orange if entire sequence completed)

Variants:
  step1_emu = emu-mode STA al $0000C0 (target known ZP RAM)
  step2_emu = emu-mode LDA al $0000C0
  step3_native = native mode (CLC; XCE) STA al $0000C0
"""
import os
import sys

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
PRG_LOAD = 0x0801

# screen char codes for digits + letters
def sc(c):
    c = c.upper()
    if c == ' ': return 32
    if '0' <= c <= '9': return ord(c) - ord('0') + 48
    if 'A' <= c <= 'Z': return ord(c) - ord('A') + 1
    return 32

SCREEN = 0x0400
COL_RAM = 0xD800


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.buf = bytearray()
    @property
    def pc(self): return self.origin + len(self.buf)
    def b(self, *vs):
        for v in vs: self.buf.append(v & 0xFF)
    # plain 6502
    def sei(self): self.b(0x78)
    def cld(self): self.b(0xD8)
    def lda_imm(self, v): self.b(0xA9, v)
    def ldx_imm(self, v): self.b(0xA2, v)
    def ldy_imm(self, v): self.b(0xA0, v)
    def txs(self): self.b(0x9A)
    def sta_abs(self, a): self.b(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def lda_abs(self, a): self.b(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def sta_zp(self, a): self.b(0x85, a)
    def lda_zp(self, a): self.b(0xA5, a)
    def nop(self): self.b(0xEA)
    def jmp(self, a): self.b(0x4C, a & 0xFF, (a >> 8) & 0xFF)
    def clc(self): self.b(0x18)
    def xce(self): self.b(0xFB)
    def rep(self, v): self.b(0xC2, v)
    def sep(self, v): self.b(0xE2, v)
    # long mode
    def sta_al(self, a24): self.b(0x8F, a24 & 0xFF, (a24 >> 8) & 0xFF, (a24 >> 16) & 0xFF)
    def lda_al(self, a24): self.b(0xAF, a24 & 0xFF, (a24 >> 8) & 0xFF, (a24 >> 16) & 0xFF)


def base(a):
    # BASIC stub (entry $080D when SYS-launched). Cart wrapper jumps to
    # $080D and skips this.
    a.buf += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    assert a.pc == 0x080D
    a.sei(); a.cld()
    a.ldx_imm(0xFF); a.txs()
    # Clear screen to spaces, color RAM = white
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.b(0x9D, 0x00, 0x04); a.b(0x9D, 0x00, 0x05)
    a.b(0x9D, 0x00, 0x06); a.b(0x9D, 0x00, 0x07)
    a.b(0xE8)              # INX
    a.b(0xD0, (cl - (a.pc + 2)) & 0xFF)
    a.lda_imm(0x01); a.ldx_imm(0)
    cf = a.pc
    a.b(0x9D, 0x00, 0xD8); a.b(0x9D, 0x00, 0xD9)
    a.b(0x9D, 0x00, 0xDA); a.b(0x9D, 0x00, 0xDB)
    a.b(0xE8)
    a.b(0xD0, (cf - (a.pc + 2)) & 0xFF)


def marker(a, col_start, char, color, count=4):
    """Draw `count` chars at row 0 starting at col, with color."""
    for i in range(count):
        a.lda_imm(sc(char)); a.sta_abs(SCREEN + col_start + i)
        a.lda_imm(color); a.sta_abs(COL_RAM + col_start + i)


def halt(a):
    h = a.pc
    a.jmp(h)


def build_variant(name, mode, op):
    """mode: 'emu' or 'native'. op: 'sta_al' or 'lda_al'."""
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)             # white A's: hit start
    for _ in range(10): a.nop()
    marker(a, 4, 'B', 0x05)             # green B's: NOPs ran
    for _ in range(10): a.nop()
    if mode == 'native':
        a.clc(); a.xce()                # E -> 0 = native mode
        a.sep(0x30)                     # 8-bit A/X/Y
    a.lda_imm(0x55)
    if op == 'sta_al':
        a.sta_al(0x0000C0)              # STA al $0000C0
    else:
        a.lda_al(0x0000C0)              # LDA al $0000C0
    marker(a, 8, 'C', 0x0A)             # orange C's: survived long-op
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_superram_roundtrip():
    """Native mode: STA al $200080 #$5A, then LDA al $200080.

    If STA + LDA round-trip works, we'll see the byte $5A read back. The
    bench writes the readback as a screen char into pos 12 of row 0
    (column 12). For char code $5A = 'X' shifted lowercase = look in PETSCII
    table; in screen-code it's 26 = 'Z'? Actually screen code $5A is not
    standard glyph — most importantly we just need to see that pos 12
    is non-space, which proves the LDA returned something.
    """
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)
    a.clc(); a.xce(); a.sep(0x30)
    a.lda_imm(0x5A)
    a.sta_al(0x200080)
    marker(a, 4, 'B', 0x05)
    a.lda_imm(0x00)
    a.lda_al(0x200080)
    a.sta_abs(SCREEN + 12)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 12)  # yellow
    marker(a, 13, 'D', 0x0A)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_superram_sta_only():
    """Just STA al $200080 in native mode, then markers and halt."""
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)
    a.clc(); a.xce(); a.sep(0x30)
    marker(a, 4, 'B', 0x05)
    a.lda_imm(0x5A)
    a.sta_al(0x200080)
    marker(a, 8, 'C', 0x0A)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_native_lda_superram_only():
    """Native mode LDA al $200080 alone (no prior write)."""
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)
    a.clc(); a.xce(); a.sep(0x30)
    marker(a, 4, 'B', 0x05)
    a.lda_al(0x200080)
    marker(a, 8, 'C', 0x0A)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_native_lda_tight_loop():
    """Native mode tight LDA al $200080 loop, 256 iterations, then halt.

    First step toward a SuperRAM throughput bench. If the inner loop
    runs stably (no screen corruption, markers C visible), the
    foundation is sound for a proper bench. NMI is explicitly masked
    via CIA2 ICR write.
    """
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)
    # Mask all IRQ/NMI sources
    a.lda_imm(0x7F); a.sta_abs(0xDC0D)   # CIA1 ICR mask all
    a.lda_abs(0xDC0D)                     # ack
    a.lda_imm(0x7F); a.sta_abs(0xDD0D)   # CIA2 ICR mask all (NMI)
    a.lda_abs(0xDD0D)                     # ack
    a.lda_imm(0x00); a.sta_abs(0xD01A)   # VIC IRQ disable
    marker(a, 4, 'B', 0x05)
    # Native mode + 8-bit + DBR=$00
    a.clc(); a.xce(); a.sep(0x30)
    a.b(0x4B, 0xAB)                       # PHK; PLB
    # Tight LDA al loop, 256 iterations
    a.ldx_imm(0x00)
    loop = a.pc
    a.lda_al(0x200080)
    a.b(0xE8)                             # INX
    a.b(0xD0, (loop - (a.pc + 2)) & 0xFF) # BNE loop
    marker(a, 8, 'C', 0x0A)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_native_roundtrip_phkplb():
    """Round-trip but with PHK/PLB to explicitly set DBR=PBR=$00 before
    any abs writes. Tests whether the round-trip corruption is a DBR
    issue."""
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)
    a.clc(); a.xce(); a.sep(0x30)
    # PHK / PLB to ensure DBR=PBR=$00
    a.b(0x4B)              # PHK (push program bank)
    a.b(0xAB)              # PLB (pull data bank)
    a.lda_imm(0x5A)
    a.sta_al(0x200080)
    marker(a, 4, 'B', 0x05)
    a.lda_al(0x200080)
    a.sta_abs(SCREEN + 12)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 12)
    marker(a, 13, 'D', 0x0A)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_native_two_long():
    """Native mode: two consecutive long ops separated only by NOPs."""
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)
    a.clc(); a.xce(); a.sep(0x30)
    a.lda_imm(0x5A)
    a.sta_al(0x200080)
    for _ in range(8): a.nop()
    a.lda_al(0x200080)
    marker(a, 8, 'C', 0x0A)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_emu_sta_superram():
    """EMU mode STA al $200080 — emu mode doesn't ordinarily emit non-$00
    banks via DBR, but $8F long takes the bank from the operand byte, so
    even emu CPU should reach SuperRAM."""
    a = Asm(PRG_LOAD)
    base(a)
    marker(a, 0, 'A', 0x01)
    marker(a, 4, 'B', 0x05)
    a.lda_imm(0x5A)
    a.sta_al(0x200080)
    marker(a, 8, 'C', 0x0A)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    variants = [
        ('probe_emu_sta',    'emu',    'sta_al'),
        ('probe_emu_lda',    'emu',    'lda_al'),
        ('probe_native_sta', 'native', 'sta_al'),
    ]
    for name, mode, op in variants:
        prg = build_variant(name, mode, op)
        path = os.path.join(OUT_DIR, name + '.prg')
        with open(path, 'wb') as f:
            f.write(prg)
        print(f"  {name}: {len(prg)} bytes -> {path}")

    # SuperRAM round-trip
    prg = build_superram_roundtrip()
    path = os.path.join(OUT_DIR, 'probe_superram_roundtrip.prg')
    with open(path, 'wb') as f:
        f.write(prg)
    print(f"  superram_roundtrip: {len(prg)} bytes -> {path}")

    prg = build_superram_sta_only()
    path = os.path.join(OUT_DIR, 'probe_superram_sta_only.prg')
    with open(path, 'wb') as f:
        f.write(prg)
    print(f"  superram_sta_only: {len(prg)} bytes -> {path}")

    prg = build_emu_sta_superram()
    path = os.path.join(OUT_DIR, 'probe_emu_sta_superram.prg')
    with open(path, 'wb') as f:
        f.write(prg)
    print(f"  emu_sta_superram: {len(prg)} bytes -> {path}")

    prg = build_native_lda_superram_only()
    path = os.path.join(OUT_DIR, 'probe_native_lda_only.prg')
    with open(path, 'wb') as f:
        f.write(prg)
    print(f"  native_lda_only: {len(prg)} bytes -> {path}")

    prg = build_native_two_long()
    path = os.path.join(OUT_DIR, 'probe_native_two_long.prg')
    with open(path, 'wb') as f:
        f.write(prg)
    print(f"  native_two_long: {len(prg)} bytes -> {path}")

    prg = build_native_roundtrip_phkplb()
    path = os.path.join(OUT_DIR, 'probe_native_roundtrip_phkplb.prg')
    with open(path, 'wb') as f:
        f.write(prg)
    print(f"  native_roundtrip_phkplb: {len(prg)} bytes -> {path}")

    prg = build_native_lda_tight_loop()
    path = os.path.join(OUT_DIR, 'probe_native_lda_tight_loop.prg')
    with open(path, 'wb') as f:
        f.write(prg)
    print(f"  native_lda_tight_loop: {len(prg)} bytes -> {path}")


if __name__ == '__main__':
    main()
