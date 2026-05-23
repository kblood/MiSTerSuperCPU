#!/usr/bin/env python3
"""Drill deeper: v4a wedged on (LDA al + STA $02). Find which one."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_stalong_probe import Asm, base, sc, SCREEN, COL_RAM
from gen_copyback_bisect import (
    write_marker_raw, emit_prefix, emit_cache_flush, emit_lda_readback,
    PRG_LOAD, OUT_DIR
)


def common_through_F(a):
    emit_prefix(a)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    emit_lda_readback(a)
    a.sta_abs(SCREEN + 24)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)


def halt_loop(a):
    halt_pc = a.pc
    a.jmp(halt_pc)


def wrap(a):
    halt_loop(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v4a0_just_G():
    """v3 + G marker (no LDA al, no STA $02). Sanity check."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_v4a1_lda_only():
    """v3 + 3rd LDA al + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_v4a2_sta_zp02_only():
    """v3 + STA $02 (A = stale color $0F from marker F) + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    a.sta_zp(0x02)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_v4a3_sta_zp03():
    """v3 + LDA al + STA $03 (different ZP addr) + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x03)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_v4a4_sta_zp10():
    """v3 + LDA al + STA $10 + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x10)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_v4a5_lda_imm_sta_zp02():
    """v3 + LDA #$5A + STA $02 + G (no LDA al, eliminates SuperRAM)."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    a.lda_imm(0x5A)
    a.sta_zp(0x02)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_v4a6_lda_al_pause_sta():
    """v3 + LDA al + 8 NOPs + STA $02 + G (test timing window)."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    for _ in range(8): a.b(0xEA)
    a.sta_zp(0x02)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


VARIANTS = [
    ("drill_v4a0_just_G",            build_v4a0_just_G),
    ("drill_v4a1_lda_only",          build_v4a1_lda_only),
    ("drill_v4a2_sta_zp02_stale",    build_v4a2_sta_zp02_only),
    ("drill_v4a3_sta_zp03",          build_v4a3_sta_zp03),
    ("drill_v4a4_sta_zp10",          build_v4a4_sta_zp10),
    ("drill_v4a5_lda_imm_sta_zp02",  build_v4a5_lda_imm_sta_zp02),
    ("drill_v4a6_lda_al_nop_sta_zp02", build_v4a6_lda_al_pause_sta),
]


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
