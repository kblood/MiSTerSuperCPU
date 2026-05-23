#!/usr/bin/env python3
"""Bank-$20 ALIVE probe with NOP padding between every memory op.

If the bank-$20 → bank-$00 STA al path also has a pipeline hazard
similar to the LDA al hazard, NOP padding might make ALIVE render.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_superram_bench import (Asm, screen_char, SCREEN, ROW,
                                PRG_LOAD, OUT_DIR)

PAYLOAD_BANK = 0x20
PAYLOAD_ADDR = 0x8000
PAYLOAD_LONG = (PAYLOAD_BANK << 16) | PAYLOAD_ADDR
SCPU_CACHE_FLUSH = 0xD078


def build_payload():
    """Bank-$20-resident: write 'ALIVE BANK20' with NOP after each STA al."""
    a = Asm(PAYLOAD_ADDR)
    a.phk()
    a.b(0xEA)               # NOP pad after PHK (just in case)
    a.plb()
    a.b(0xEA)               # NOP pad after PLB
    msg = 'ALIVE BANK20'
    base = SCREEN + 6*ROW + 8
    for i, ch in enumerate(msg):
        a.lda_imm(screen_char(ch))
        a.b(0xEA)           # NOP pad before STA al
        a.b(0x8F, (base + i) & 0xFF, ((base + i) >> 8) & 0xFF, 0x00)
        a.b(0xEA)           # NOP pad after STA al
    a.lda_imm(0x01)
    a.b(0xEA)
    a.b(0x8F, SCPU_CACHE_FLUSH & 0xFF,
        (SCPU_CACHE_FLUSH >> 8) & 0xFF, 0x00)
    a.b(0xEA)
    halt = a.pc
    a.jmp(halt & 0xFFFF)
    return bytes(a.buf)


def build_loader(payload_bytes):
    a = Asm(PRG_LOAD)
    a.buf += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    assert a.pc == 0x080D
    a.sei(); a.cld(); a.ldx_imm(0xFF); a.txs()
    a.lda_imm(0x00); a.sta_abs(0xD020); a.sta_abs(0xD021)
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.sta_absx(0x0400); a.sta_absx(0x0500)
    a.sta_absx(0x0600); a.sta_absx(0x0700)
    a.inx(); a.bne_back(cl)
    a.lda_imm(0x05); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)
    text = "LOADER OK -> JML  208000"
    bas = SCREEN + 0*ROW + 7
    for i, ch in enumerate(text):
        a.lda_imm(screen_char(ch))
        a.sta_abs(bas + i)
    a.lda_imm(0x01)
    a.b(0x8F, SCPU_CACHE_FLUSH & 0xFF,
        (SCPU_CACHE_FLUSH >> 8) & 0xFF, 0x00)
    size = len(payload_bytes)
    assert size <= 256, f"payload {size} > 256 bytes"
    a.ldx_imm(0x00)
    copy = a.pc
    src_lo_patch = len(a.buf) + 1
    a.lda_absx(0x0000)
    a.b(0x9F, PAYLOAD_ADDR & 0xFF,
        (PAYLOAD_ADDR >> 8) & 0xFF, PAYLOAD_BANK)
    a.inx()
    a.cpx_imm(size & 0xFF)
    off = copy - (a.pc + 2)
    assert -128 <= off < 0
    a.b(0xD0, off & 0xFF)
    a.lda_imm(0x01)
    a.b(0x8F, SCPU_CACHE_FLUSH & 0xFF,
        (SCPU_CACHE_FLUSH >> 8) & 0xFF, 0x00)
    a.jml(PAYLOAD_LONG)
    payload_local = a.pc
    a.buf += bytes(payload_bytes)
    a.buf[src_lo_patch]     = payload_local & 0xFF
    a.buf[src_lo_patch + 1] = (payload_local >> 8) & 0xFF
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


VARIANTS = [("superram_alive_probe_nopped",
             lambda: build_loader(build_payload()))]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, fn in VARIANTS:
        prg = fn()
        path = os.path.join(OUT_DIR, name + ".prg")
        with open(path, "wb") as f:
            f.write(prg)
        print(f"  {name}: {len(prg)} bytes -> {path}")


if __name__ == "__main__":
    main()
