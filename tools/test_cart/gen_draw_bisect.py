#!/usr/bin/env python3
"""Variant draws to bisect the PA-wedge.

If the wedge is at fixed CHAR INDEX (e.g., always 3rd char of 3rd draw),
varying the strings tells us nothing — wedge stays at char 3.
If the wedge is at fixed ADDRESS (e.g., always at PC = $08FC), varying
the strings (changing instruction byte counts) moves the wedge.
If the wedge is at fixed SCREEN ADDRESS ($04AA), reordering draws moves
the wedge to whichever draw lands at row 4.
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


def base_loader(a):
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
    a.lda_imm(0x03); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)


def build_variant(name, draws):
    """draws: list of (text, screen_addr) tuples."""
    a = Asm(PRG_LOAD)
    base_loader(a)
    for text, addr in draws:
        draw(a, text, addr)
    halt = a.pc
    a.jmp(halt & 0xFFFF)
    out = os.path.join(OUT_DIR, name + '.prg')
    with open(out, 'wb') as f:
        f.write(bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF])
                + bytes(a.buf))
    print(f"  {name}: {len(a.buf)+2} bytes -> {out}")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # V1 baseline: just one short string at row 4 col 8 (same screen addr
    # as the failing PASS draw). If THIS wedges → screen address $04Ax
    # is the trigger. If clean → wedge needs multiple prior draws.
    build_variant('draw_v1_just_pass', [
        ('PASS  $----', SCREEN + 4*ROW + 8),
    ])

    # V2: only the FIRST two draws (which were known to render OK).
    build_variant('draw_v2_first_two', [
        ('SUPERRAM BENCH BANK $20', SCREEN + 0*ROW + 7),
        ('COUNT $------',           SCREEN + 2*ROW + 8),
    ])

    # V3: 4 draws but PASS goes LAST (was 3rd). If wedge follows PASS
    # to row 22, the trigger is the PASS string content.
    build_variant('draw_v3_pass_last', [
        ('SUPERRAM BENCH BANK $20', SCREEN + 0*ROW + 7),
        ('COUNT $------',           SCREEN + 2*ROW + 8),
        ('STEP 7B ALT-FIRE TEST',   SCREEN + 22*ROW + 5),
        ('PASS  $----',             SCREEN + 4*ROW + 8),
    ])

    # V4: 4 draws but PASS at row 4 replaced with a shorter, ASCII-A-only
    # string. If wedge moves position, the trigger is char count or
    # specific char.
    build_variant('draw_v4_pass_short', [
        ('SUPERRAM BENCH BANK $20', SCREEN + 0*ROW + 7),
        ('COUNT $------',           SCREEN + 2*ROW + 8),
        ('AAA',                     SCREEN + 4*ROW + 8),
        ('STEP 7B ALT-FIRE TEST',   SCREEN + 22*ROW + 5),
    ])


if __name__ == '__main__':
    main()
