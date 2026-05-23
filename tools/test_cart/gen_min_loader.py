#!/usr/bin/env python3
"""Minimal bank-0 sanity test — no bank-$20 access.
Clears screen, draws label, infinite loop. If this shows the label,
the loader + draw scaffolding works."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_superram_bench import Asm, screen_char, SCREEN, ROW, PRG_LOAD, OUT_DIR

def build():
    a = Asm(PRG_LOAD)
    a.buf += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    assert a.pc == 0x080D
    a.sei()
    a.cld()
    a.ldx_imm(0xFF); a.txs()
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
    text = "MIN LOADER OK"
    for i, ch in enumerate(text):
        a.lda_imm(screen_char(ch))
        a.sta_abs(SCREEN + 10*ROW + 13 + i)
    halt = a.pc
    a.jmp(halt)
    out = os.path.join(OUT_DIR, "min_loader.prg")
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(out, "wb") as f:
        f.write(bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf))
    print(f"Wrote {len(a.buf)+2} bytes -> {out}")

if __name__ == "__main__":
    build()
