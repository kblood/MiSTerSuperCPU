#!/usr/bin/env python3
"""CPU-bound speed bench PRG.

The existing gen_scpu_speedtest's inner loop polls $D012 / $DC0D every
iteration, so the loop is I/O-bound and reports $0001DC at every OSD
turbo setting. This bench replaces the I/O poll with a CIA1 Timer A
one-shot + custom IRQ that flips a ZP "done" flag. The inner loop is
then pure ZP: `inc lo / bne / inc mi / bne / inc hi / lda done / beq`.

Result: COUNT scales with CPU MHz. Operator toggles OSD turbo and
watches the value change.

Output (screen $0400):
  Row 0 col 12: CPU-BOUND BENCH
  Row 2 col  8: COUNT $XXXXXX
  Row 4 col  8: PASS  $XXXX
  Row 22 col 3: CHANGE OSD TURBO SEE COUNT VARY
"""
import os

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
PRG_LOAD = 0x0801

CIA1_TA_LO = 0xDC04
CIA1_TA_HI = 0xDC05
CIA1_ICR   = 0xDC0D
CIA1_CRA   = 0xDC0E

ZP_DONE     = 0x02
ZP_COUNT_LO = 0x03
ZP_COUNT_MI = 0x04
ZP_COUNT_HI = 0x05
ZP_PASS_LO  = 0x06
ZP_PASS_HI  = 0x07
ZP_TMP      = 0x0E
ZP_PTR_LO   = 0xFB
ZP_PTR_HI   = 0xFC

SCREEN = 0x0400
ROW = 40

# PETSCII screen codes 0-9 A-F
SCREEN_HEX = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6]


def screen_char(c):
    c = c.upper()
    table = {' ': 32, '$': 36, ':': 58, '-': 45, '.': 46}
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

    # opcodes
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
    def inc_zp(self, a):  self.b(0xE6, a)
    def lda_abs(self, a): self.b(0xAD); self.w(a)
    def sta_abs(self, a): self.b(0x8D); self.w(a)
    def lda_absx(self, a):self.b(0xBD); self.w(a)
    def sta_absx(self, a):self.b(0x9D); self.w(a)
    def sta_indy(self, a):self.b(0x91, a)
    def jsr(self, a):     self.b(0x20); self.w(a)
    def jmp(self, a):     self.b(0x4C); self.w(a)

    def bne_back(self, target):
        off = target - (self.pc + 2)
        assert -128 <= off < 0, f"BNE back out of range {off}"
        self.b(0xD0, off & 0xFF)

    def beq_back(self, target):
        off = target - (self.pc + 2)
        assert -128 <= off < 0, f"BEQ back out of range {off}"
        self.b(0xF0, off & 0xFF)

    def bne_fwd(self):
        i = len(self.buf)
        self.b(0xD0, 0)
        return i

    def fixup(self, idx):
        off = self.pc - (self.origin + idx + 2)
        assert 0 < off <= 127, f"Fwd branch off {off} out of range"
        self.buf[idx + 1] = off


def build_prg():
    a = Asm(PRG_LOAD)

    # BASIC stub: 10 SYS 2061
    a.buf += bytes([0x0C, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    assert a.pc == 0x080D, f"Code starts at ${a.pc:04X}, expected $080D"

    hex_calls = []

    # ─── Init ───
    a.sei()
    a.cld()
    a.ldx_imm(0xFF); a.txs()

    # CINV ($0314/$0315) → handler (addr patched at end)
    a.lda_imm(0); cinv_lo_idx = len(a.buf) - 1
    a.sta_abs(0x0314)
    a.lda_imm(0); cinv_hi_idx = len(a.buf) - 1
    a.sta_abs(0x0315)

    # Black border + bg
    a.lda_imm(0); a.sta_abs(0xD020); a.sta_abs(0xD021)

    # Clear screen
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.sta_absx(0x0400); a.sta_absx(0x0500)
    a.sta_absx(0x0600); a.sta_absx(0x0700)
    a.inx(); a.bne_back(cl)

    # Color RAM = light cyan ($03)
    a.lda_imm(0x03); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)

    def draw(text, screen_addr):
        for i, ch in enumerate(text):
            a.lda_imm(screen_char(ch))
            a.sta_abs(screen_addr + i)

    draw("CPU-BOUND BENCH",           SCREEN + 0*ROW + 12)
    draw("COUNT $------",              SCREEN + 2*ROW + 8)
    draw("PASS  $----",                SCREEN + 4*ROW + 8)
    draw("CHANGE OSD TURBO SEE COUNT", SCREEN + 22*ROW + 3)

    a.lda_imm(0); a.sta_zp(ZP_PASS_LO); a.sta_zp(ZP_PASS_HI)

    # ─── Main loop ───
    main_loop = a.pc

    a.lda_imm(0x00); a.sta_abs(CIA1_CRA)    # stop Timer A
    a.lda_abs(CIA1_ICR)                      # ack any pending IRQs
    a.lda_imm(0); a.sta_zp(ZP_DONE)
    a.sta_zp(ZP_COUNT_LO)
    a.sta_zp(ZP_COUNT_MI)
    a.sta_zp(ZP_COUNT_HI)

    # Timer A latch = $4000 = 16384 phi2 cycles = ~16.4 ms at 1 MHz
    a.lda_imm(0x00); a.sta_abs(CIA1_TA_LO)
    a.lda_imm(0x40); a.sta_abs(CIA1_TA_HI)

    # Enable Timer A IRQ (ICR write: set | TA = $81)
    a.lda_imm(0x81); a.sta_abs(CIA1_ICR)
    # One-shot + force-load + start = $19
    a.lda_imm(0x19); a.sta_abs(CIA1_CRA)

    a.cli()

    # Pure-ZP inner loop
    inner = a.pc
    a.inc_zp(ZP_COUNT_LO)
    nc1 = a.bne_fwd()
    a.inc_zp(ZP_COUNT_MI)
    nc2 = a.bne_fwd()
    a.inc_zp(ZP_COUNT_HI)
    a.fixup(nc2)
    a.fixup(nc1)
    a.lda_zp(ZP_DONE)
    a.beq_back(inner)

    a.sei()
    a.lda_imm(0); a.sta_abs(CIA1_CRA)

    # Pass++
    a.inc_zp(ZP_PASS_LO)
    skp = a.bne_fwd()
    a.inc_zp(ZP_PASS_HI)
    a.fixup(skp)

    # Display
    DISP_PLACEHOLDER = 0xFFFF

    def call_disp(zp, screen_addr):
        a.lda_zp(zp)
        a.ldx_imm(screen_addr & 0xFF)
        a.ldy_imm((screen_addr >> 8) & 0xFF)
        i = len(a.buf) + 1
        a.jsr(DISP_PLACEHOLDER)
        hex_calls.append(i)

    call_disp(ZP_COUNT_HI, SCREEN + 2*ROW + 15)
    call_disp(ZP_COUNT_MI, SCREEN + 2*ROW + 17)
    call_disp(ZP_COUNT_LO, SCREEN + 2*ROW + 19)
    call_disp(ZP_PASS_HI,  SCREEN + 4*ROW + 15)
    call_disp(ZP_PASS_LO,  SCREEN + 4*ROW + 17)

    a.jmp(main_loop)

    # ─── IRQ handler (CINV) ───
    # KERNAL $FF48 already pushed A/X/Y. We set done, ack ICR,
    # then jump to KERNAL default IRQ at $EA31 which finishes
    # (scan keys, advance time, restore regs, RTI).
    handler_addr = a.pc
    a.lda_imm(0x80); a.sta_zp(ZP_DONE)
    a.lda_abs(CIA1_ICR)
    a.jmp(0xEA31)

    # ─── display_byte ───
    # In: A = byte, X = screen_lo, Y = screen_hi
    # Out: writes 2 hex chars to (screen)
    disp_addr = a.pc
    a.sta_zp(ZP_TMP)
    a.stx_zp(ZP_PTR_LO)
    a.tya(); a.sta_zp(ZP_PTR_HI)
    # high nibble
    a.lda_zp(ZP_TMP); a.lsr_a(); a.lsr_a(); a.lsr_a(); a.lsr_a()
    a.tax()
    p_hi = len(a.buf) + 1
    a.lda_absx(0)
    a.ldy_imm(0)
    a.sta_indy(ZP_PTR_LO)
    # low nibble
    a.lda_zp(ZP_TMP); a.and_imm(0x0F)
    a.tax()
    p_lo = len(a.buf) + 1
    a.lda_absx(0)
    a.ldy_imm(1)
    a.sta_indy(ZP_PTR_LO)
    a.rts()

    # ─── HEX table ───
    hex_tbl_addr = a.pc
    for v in SCREEN_HEX:
        a.b(v)

    # Patches
    a.buf[p_hi]     = hex_tbl_addr & 0xFF
    a.buf[p_hi + 1] = (hex_tbl_addr >> 8) & 0xFF
    a.buf[p_lo]     = hex_tbl_addr & 0xFF
    a.buf[p_lo + 1] = (hex_tbl_addr >> 8) & 0xFF
    a.buf[cinv_lo_idx] = handler_addr & 0xFF
    a.buf[cinv_hi_idx] = (handler_addr >> 8) & 0xFF
    for i in hex_calls:
        a.buf[i]     = disp_addr & 0xFF
        a.buf[i + 1] = (disp_addr >> 8) & 0xFF

    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    prg = build_prg()
    out = os.path.join(OUT_DIR, "cpu_bound_bench.prg")
    with open(out, "wb") as f:
        f.write(prg)
    print(f"Wrote {len(prg)} bytes -> {out}")


if __name__ == "__main__":
    main()
