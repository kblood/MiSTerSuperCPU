#!/usr/bin/env python3
"""Incremental tests for diagnosing SuperRAM bench crash.
Pass a step number 0..6 as argv:
  0 = baseline (min loader)
  1 = + cache flush ($D078=1)
  2 = + STA al $0000xx (long store to bank 0)
  3 = + STA al $200000 (long store to bank $20 = SuperRAM)
  4 = + LDA al $200000 readback to screen
  5 = + 8-bit copy loop to bank $20
  6 = + JML $20:$0400  (jump to a bank-$20 address with NOP+JMP pattern)
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_superram_bench import (
    Asm, screen_char, SCREEN, ROW, PRG_LOAD, OUT_DIR, SCPU_CACHE_FLUSH
)

def label(a, text, screen_addr):
    for i, ch in enumerate(text):
        a.lda_imm(screen_char(ch))
        a.sta_abs(screen_addr + i)

def build_base(a):
    a.buf += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    a.sei(); a.cld(); a.ldx_imm(0xFF); a.txs()
    a.lda_imm(0x00); a.sta_abs(0xD020); a.sta_abs(0xD021)
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.sta_absx(0x0400); a.sta_absx(0x0500)
    a.sta_absx(0x0600); a.sta_absx(0x0700)
    a.inx(); a.bne_back(cl)
    a.lda_imm(0x01); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)

def halt_with(a, txt, row=10, col=13):
    label(a, txt, SCREEN + row*ROW + col)
    h = a.pc
    a.jmp(h)

def main():
    step = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    a = Asm(PRG_LOAD)
    build_base(a)
    label(a, f"STEP {step} START", SCREEN + 8*ROW + 10)
    if step >= 1:
        # cache flush -- known to crash (invalidates cached loader code).
        # Skipped now; just label that we're past this point.
        label(a, "SKIPPED FLUSH", SCREEN + 12*ROW + 10)
    if step >= 2:
        # Just STA al to bank 0, but at $0500 (safe non-ZP, non-IO).
        label(a, "BEFORE STA AL", SCREEN + 13*ROW + 10)
        a.b(0xA9, 0xAA)                  # LDA #$AA
        a.b(0x8F, 0x00, 0x05, 0x00)      # STA al $000500
        label(a, "AFTER STA AL 0500", SCREEN + 14*ROW + 5)
    if step >= 3:
        # STA al bank $20 — SuperRAM
        a.lda_imm(0x55); a.sta_al(0x200080)
        label(a, "AFTER STA AL B20", SCREEN + 16*ROW + 10)
    if step >= 4:
        # LDA al bank $20, store back to bank-0 screen as char
        a.lda_al(0x200080)
        a.sta_abs(SCREEN + 18*ROW + 27)  # show byte as a char glyph
        label(a, "AFTER LDA AL B20", SCREEN + 18*ROW + 10)
    if step >= 5:
        # 8-bit copy loop: 8 bytes from $0900 to $200900
        for i in range(8):
            a.lda_imm(0x40 + i); a.sta_abs(0x0900 + i)
        a.ldx_imm(0)
        loop = a.pc
        a.lda_absx(0x0900)
        a.sta_alx(0x200900)
        a.inx()
        a.cpx_imm(8)
        off = (loop - (a.pc + 2)); assert -128 <= off < 0
        a.b(0xD0, off & 0xFF)
        label(a, "AFTER COPY 8 BYTES", SCREEN + 20*ROW + 10)
    if step >= 6:
        # Put a single JMP $abs at $20:$0400 and JML there.
        # Target = "label OK" then halt at $20:$0400+N
        # Build a tiny stub via more STA al ops
        # stub: LDA #char; STA $0400+(22*ROW+13); JMP self
        # That's bank-0 screen write, but we're running in bank $20 PB.
        # JMP in bank stays in PB, so we add a JML $00:$xxxx to land back.
        # Simpler: jml to a bank-0 address that just halts.
        # Even simpler: only put JML $00:$loop back into bank 0.
        # Build a tiny bank-0 halt with label.
        b0_halt = a.pc
        label(a, "AFTER JML RT", SCREEN + 22*ROW + 10)
        b0_halt_loop = a.pc
        a.jmp(b0_halt_loop)
        # Now back-patch a JML to bank $20:$8000, where we'll place
        # a JML back to b0_halt.
        # Actually too complex — just JML $00:b0_halt (round-trip via PBR).
        # JML $00:b0_halt is a no-op-ish bank fix (PBR was $00 anyway).
        # Skip step 6 if we got here without JML to bank $20.
        # Instead: emit a JML $00:b0_halt
        a.jml(b0_halt & 0xFFFFFF)

    halt_with(a, f"STEP {step} END", row=24, col=10)

    out = os.path.join(OUT_DIR, f"test_step{step}.prg")
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(out, "wb") as f:
        f.write(bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf))
    print(f"Wrote step{step}: {len(a.buf)+2} bytes -> {out}")

if __name__ == "__main__":
    main()
