#!/usr/bin/env python3
"""SuperRAM-resident CPU-bound bench (polling, no IRQ, no native mode).

The cpu_bound_bench.prg measures a ZP loop in bank 0, so it doesn't
exercise Step 7b's alt-fire (which only fires for scpu_fast_path =
SuperRAM bank != $00). This bench moves both the inner loop CODE
*and* the 3-byte counter to bank $20, so every instruction fetch and
counter INC goes through SuperRAM and is eligible for alt-fire.

Stays in EMULATION mode the whole time:
  - 65816 long opcodes (LDA al, STA al,X, JML, PHK, PLB) work in emu
  - DBR is honored for abs/abs,X in emu mode, so PHK; PLB to set DBR=$20
    makes INC abs target $20:$NNNN
  - PB stays $20 across JMP within bank
  - No IRQ entanglement — poll Timer A ICR directly

Flow:
  1. Bank-0 loader at $0801 (BASIC SYS 2061 stub)
  2. Loader copies 198 bytes to $20:$8000 via STA $208000,X (long-X)
  3. Loader JML $20:$8000
  4. Payload sets DBR=$20, loops:
       - Timer A one-shot $4000 phi2 cycles
       - inner: INC $0003 / BNE / INC $0004 / BNE / INC $0005
                LDA $00DC0D (poll ICR via long); AND #$01; BEQ inner
       - increment pass counter, display count + pass on screen
       - JMP main_loop
"""
import os

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
PRG_LOAD = 0x0801
PAYLOAD_BANK = 0x20
PAYLOAD_ADDR = 0x8000
PAYLOAD_LONG = (PAYLOAD_BANK << 16) | PAYLOAD_ADDR

CIA1_TA_LO = 0x00DC04
CIA1_TA_HI = 0x00DC05
CIA1_ICR   = 0x00DC0D
CIA1_CRA   = 0x00DC0E
SCPU_CACHE_FLUSH = 0xD078

# bank-$20 counter cells (abs in DBR=$20)
B20_COUNT_LO = 0x0003
B20_COUNT_MI = 0x0004
B20_COUNT_HI = 0x0005
B20_PASS_LO  = 0x0006
B20_PASS_HI  = 0x0007
B20_TMP      = 0x000E

SCREEN = 0x0400
ROW = 40

SCREEN_HEX = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6]


def screen_char(c):
    c = c.upper()
    table = {' ': 32, '$': 36, ':': 58, '-': 45, '.': 46, '(': 40, ')': 41}
    if c in table:
        return table[c]
    if '0' <= c <= '9':
        return ord(c) - ord('0') + 48
    if 'A' <= c <= 'Z':
        return ord(c) - ord('A') + 1
    return 32


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.buf = bytearray()

    @property
    def pc(self):
        return self.origin + len(self.buf)

    def b(self, *vals):
        for v in vals:
            self.buf.append(v & 0xFF)

    def w(self, v):
        self.b(v & 0xFF, (v >> 8) & 0xFF)

    def long(self, v):
        self.b(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF)

    # 6502 / shared opcodes
    def sei(self):        self.b(0x78)
    def cli(self):        self.b(0x58)
    def cld(self):        self.b(0xD8)
    def rts(self):        self.b(0x60)
    def txs(self):        self.b(0x9A)
    def tax(self):        self.b(0xAA)
    def tya(self):        self.b(0x98)
    def inx(self):        self.b(0xE8)
    def lsr_a(self):      self.b(0x4A)
    def and_imm(self, v): self.b(0x29, v)
    def lda_imm(self, v): self.b(0xA9, v)
    def ldx_imm(self, v): self.b(0xA2, v)
    def ldy_imm(self, v): self.b(0xA0, v)
    def lda_zp(self, a):  self.b(0xA5, a)
    def sta_zp(self, a):  self.b(0x85, a)
    def stx_zp(self, a):  self.b(0x86, a)
    def lda_abs(self, a): self.b(0xAD); self.w(a)
    def sta_abs(self, a): self.b(0x8D); self.w(a)
    def lda_absx(self, a):self.b(0xBD); self.w(a)
    def sta_absx(self, a):self.b(0x9D); self.w(a)
    def cpx_imm(self, v): self.b(0xE0, v)
    def jmp(self, a):     self.b(0x4C); self.w(a)
    def inc_abs(self, a): self.b(0xEE); self.w(a)
    def cmp_imm(self, v): self.b(0xC9, v)

    # 65816 opcodes (valid in emulation mode)
    def phk(self):           self.b(0x4B)
    def plb(self):           self.b(0xAB)
    def jml(self, lng):      self.b(0x5C); self.long(lng)
    def lda_al(self, lng):   self.b(0xAF); self.long(lng)
    def sta_al(self, lng):   self.b(0x8F); self.long(lng)
    def sta_alx(self, lng):  self.b(0x9F); self.long(lng)
    def lda_alx(self, lng):  self.b(0xBF); self.long(lng)

    def bne_back(self, target):
        off = target - (self.pc + 2)
        assert -128 <= off < 0, f"BNE back out of range {off}"
        self.b(0xD0, off & 0xFF)

    def beq_back(self, target):
        off = target - (self.pc + 2)
        assert -128 <= off < 0, f"BEQ back out of range {off}"
        self.b(0xF0, off & 0xFF)

    def bne_fwd(self):
        i = len(self.buf); self.b(0xD0, 0); return i

    def beq_fwd(self):
        i = len(self.buf); self.b(0xF0, 0); return i

    def fixup(self, idx):
        off = self.pc - (self.origin + idx + 2)
        assert 0 < off <= 127, f"Fwd branch off {off} out of range"
        self.buf[idx + 1] = off


def build_payload():
    """Bench body resident at bank $20:$8000."""
    a = Asm(PAYLOAD_ADDR)

    # PB=$20 (from JML), DBR=0 → set to $20
    a.phk()
    a.plb()

    main_loop = a.pc

    # Stop Timer A + ack pending ICR
    a.lda_imm(0x00);  a.sta_al(CIA1_CRA)
    a.lda_al(CIA1_ICR)               # read = ack

    # Clear counters (bank-$20 via DBR=$20)
    a.lda_imm(0)
    a.sta_abs(B20_COUNT_LO)
    a.sta_abs(B20_COUNT_MI)
    a.sta_abs(B20_COUNT_HI)

    # Timer A one-shot latch = $4000
    a.lda_imm(0x00);  a.sta_al(CIA1_TA_LO)
    a.lda_imm(0x40);  a.sta_al(CIA1_TA_HI)

    # Start Timer A one-shot (no IRQ enable; we poll)
    a.lda_imm(0x19);  a.sta_al(CIA1_CRA)

    # Inner loop — bank-$20 INC abs + 1 bank-0 long poll per iter
    inner = a.pc
    a.inc_abs(B20_COUNT_LO)
    nc1 = a.bne_fwd()
    a.inc_abs(B20_COUNT_MI)
    nc2 = a.bne_fwd()
    a.inc_abs(B20_COUNT_HI)
    a.fixup(nc2)
    a.fixup(nc1)
    a.lda_al(CIA1_ICR)               # poll Timer A underflow flag
    a.and_imm(0x01)
    a.beq_back(inner)

    a.lda_imm(0x00); a.sta_al(CIA1_CRA)

    # Pass++ (bank $20)
    a.inc_abs(B20_PASS_LO)
    skp = a.bne_fwd()
    a.inc_abs(B20_PASS_HI)
    a.fixup(skp)

    # Display via subroutine
    DISP_PLACEHOLDER = 0xFFFF
    hex_calls = []

    def call_disp(b20_addr, screen_addr):
        a.lda_abs(b20_addr)
        a.ldx_imm(screen_addr & 0xFF)
        a.ldy_imm((screen_addr >> 8) & 0xFF)
        i = len(a.buf) + 1
        a.b(0x20); a.w(DISP_PLACEHOLDER)
        hex_calls.append(i)

    call_disp(B20_COUNT_HI, SCREEN + 2*ROW + 15)
    call_disp(B20_COUNT_MI, SCREEN + 2*ROW + 17)
    call_disp(B20_COUNT_LO, SCREEN + 2*ROW + 19)
    call_disp(B20_PASS_HI,  SCREEN + 4*ROW + 15)
    call_disp(B20_PASS_LO,  SCREEN + 4*ROW + 17)

    a.jmp(main_loop & 0xFFFF)         # JMP within bank $20 (PB stays $20)

    # display_byte at bank $20 — uses STA [$FB],Y (long indirect Y)
    # A=byte, X=screen_lo, Y=screen_hi.
    disp_addr = a.pc & 0xFFFF
    a.sta_abs(B20_TMP)
    a.stx_zp(0xFB)
    a.tya(); a.sta_zp(0xFC)
    a.lda_imm(0x00); a.sta_zp(0xFD)   # 24-bit ptr bank byte = $00

    # high nibble
    a.lda_abs(B20_TMP)
    a.lsr_a(); a.lsr_a(); a.lsr_a(); a.lsr_a()
    a.tax()
    p_hi = len(a.buf) + 1
    a.lda_absx(0)                     # patched -> HEX_TBL
    a.ldy_imm(0)
    a.b(0x97, 0xFB)                   # STA [$FB],Y

    # low nibble
    a.lda_abs(B20_TMP)
    a.and_imm(0x0F)
    a.tax()
    p_lo = len(a.buf) + 1
    a.lda_absx(0)                     # patched -> HEX_TBL
    a.ldy_imm(1)
    a.b(0x97, 0xFB)
    a.rts()

    # HEX_TBL in bank $20
    hex_tbl_addr = a.pc & 0xFFFF
    for v in SCREEN_HEX:
        a.b(v)

    # Patches
    a.buf[p_hi]     = hex_tbl_addr & 0xFF
    a.buf[p_hi + 1] = (hex_tbl_addr >> 8) & 0xFF
    a.buf[p_lo]     = hex_tbl_addr & 0xFF
    a.buf[p_lo + 1] = (hex_tbl_addr >> 8) & 0xFF
    for i in hex_calls:
        a.buf[i]     = disp_addr & 0xFF
        a.buf[i + 1] = (disp_addr >> 8) & 0xFF

    return bytes(a.buf)


def build_loader(payload_bytes):
    """Bank-0 loader: copy payload to bank $20 via long,X; JML $20:$8000."""
    a = Asm(PRG_LOAD)

    # BASIC SYS 2061 stub
    a.buf += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    assert a.pc == 0x080D

    a.sei()
    a.cld()
    a.ldx_imm(0xFF); a.txs()

    # Black screen + cyan
    a.lda_imm(0x00); a.sta_abs(0xD020); a.sta_abs(0xD021)
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.sta_absx(0x0400); a.sta_absx(0x0500)
    a.sta_absx(0x0600); a.sta_absx(0x0700)
    a.inx(); a.bne_back(cl)
    a.lda_imm(0x03); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)

    def draw(text, screen_addr):
        for i, ch in enumerate(text):
            a.lda_imm(screen_char(ch))
            a.sta_abs(screen_addr + i)

    draw("SUPERRAM BENCH BANK $20", SCREEN + 0*ROW + 7)
    draw("COUNT $------",            SCREEN + 2*ROW + 8)
    draw("PASS  $----",              SCREEN + 4*ROW + 8)
    draw("STEP 7B ALT-FIRE TEST",    SCREEN + 22*ROW + 5)

    # Cache flush (writes go through writeback cache; force them out)
    a.lda_imm(0x01)
    a.sta_al(0x000000 | SCPU_CACHE_FLUSH)

    # 8-bit copy loop: payload <= 256 bytes (assert below)
    size = len(payload_bytes)
    assert size <= 256, f"Payload {size} bytes exceeds 8-bit copy loop"

    a.ldx_imm(0x00)
    copy_loop = a.pc
    # LDA payload_src,X (bank-0 abs,X)
    src_lo_patch = len(a.buf) + 1
    a.lda_absx(0x0000)
    # STA $208000,X (long,X $9F)
    a.sta_alx(PAYLOAD_LONG)
    a.inx()
    a.cpx_imm(size & 0xFF)
    off = (copy_loop - (a.pc + 2))
    assert -128 <= off < 0, f"copy BNE out of range {off}"
    a.b(0xD0, off & 0xFF)

    # Cache flush again to push copied data out
    a.lda_imm(0x01)
    a.sta_al(0x000000 | SCPU_CACHE_FLUSH)

    # JML $20:$8000
    a.jml(PAYLOAD_LONG)

    # Payload bytes appended right here
    payload_local_addr = a.pc
    a.buf += bytes(payload_bytes)

    # Patch payload_src in copy loop
    a.buf[src_lo_patch]     = payload_local_addr & 0xFF
    a.buf[src_lo_patch + 1] = (payload_local_addr >> 8) & 0xFF

    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    payload = build_payload()
    prg = build_loader(payload)
    out = os.path.join(OUT_DIR, "superram_bench.prg")
    with open(out, "wb") as f:
        f.write(prg)
    print(f"Payload size: {len(payload)} bytes")
    print(f"PRG total:    {len(prg)} bytes -> {out}")


if __name__ == "__main__":
    main()
