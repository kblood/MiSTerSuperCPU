#!/usr/bin/env python3
"""Minimal draw-only test isolating gen_superram_bench's PASS wedge.

Same loader sequence as gen_superram_bench (SEI/CLD/TXS, black border,
screen clear, color RAM=cyan, then draws), but ONLY the 3 draws + halt.
No cache flush, no payload copy, no JML — strips everything past the
draws to test whether the "PA" wedge is in the draws themselves or in
instruction-prefetch reaching the trailing code.

If this wedges identically -> wedge is in the draw bytecode (SEI cleared?
some opcode at $04AA address?).
If this renders cleanly -> wedge involves prefetch crossing into the
trailing code (cache flush at $D078, copy loop, JML to $208000).
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_superram_bench import (Asm, screen_char, SCREEN, ROW,
                                PRG_LOAD, OUT_DIR)


def draw(a, text, screen_addr):
    for i, ch in enumerate(text):
        a.lda_imm(screen_char(ch))
        a.sta_abs(screen_addr + i)


def build():
    a = Asm(PRG_LOAD)
    # BASIC SYS 2061 stub
    a.buf += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    assert a.pc == 0x080D

    a.sei()
    a.cld()
    a.ldx_imm(0xFF); a.txs()

    # Black border + screen
    a.lda_imm(0x00); a.sta_abs(0xD020); a.sta_abs(0xD021)

    # Screen clear to spaces
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.sta_absx(0x0400); a.sta_absx(0x0500)
    a.sta_absx(0x0600); a.sta_absx(0x0700)
    a.inx(); a.bne_back(cl)

    # Color RAM = cyan
    a.lda_imm(0x03); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)

    # Same 3 draws as gen_superram_bench
    draw(a, "SUPERRAM BENCH BANK $20", SCREEN + 0*ROW + 7)
    draw(a, "COUNT $------",           SCREEN + 2*ROW + 8)
    draw(a, "PASS  $----",             SCREEN + 4*ROW + 8)
    # 4th draw is "STEP 7B ALT-FIRE TEST" in the real bench; include it
    # to keep this fully equivalent to the loader's draws section.
    draw(a, "STEP 7B ALT-FIRE TEST",   SCREEN + 22*ROW + 5)

    # Halt — infinite JMP-to-self
    halt = a.pc
    a.jmp(halt & 0xFFFF)

    out = os.path.join(OUT_DIR, "pass_draw_only.prg")
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(out, "wb") as f:
        f.write(bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF])
                + bytes(a.buf))
    print(f"Wrote {len(a.buf)+2} bytes -> {out}")


if __name__ == "__main__":
    build()
