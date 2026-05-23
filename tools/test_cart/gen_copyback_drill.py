#!/usr/bin/env python3
"""Drill into v4's hex display block to identify the wedging instruction.

Starts at the v3-style prefix (known-good through col 20-23 'FFFF') and
adds the hex display code one piece at a time, emitting a marker G after
each step. First step whose G marker is missing identifies the wedge.

Pos 30-33 'GGGG' red = post-step marker (appears = step OK).

  v4a = v3 + STA $02
  v4b = v4a + LSR*4
  v4c = v4b + TAX
  v4d = v4c + LDA HEX_TBL,X (out-of-line table after halt)
  v4e = v4d + STA $041A
  v4f = v4e + LDA $02; AND #$0F; TAX; LDA HEX_TBL,X; STA $041B
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_stalong_probe import Asm, base, sc, SCREEN, COL_RAM
from gen_copyback_bisect import (
    write_marker_raw, emit_prefix, emit_cache_flush, emit_lda_readback,
    PRG_LOAD, OUT_DIR
)


def common_through_F(a):
    """Reproduces v3 body up through marker F at col 20-23."""
    emit_prefix(a)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    emit_lda_readback(a)
    a.sta_abs(SCREEN + 24)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)


def finalize_with_table(a, table_patches):
    """Emit halt loop then HEX_TBL; apply patches."""
    halt_pc = a.pc
    a.jmp(halt_pc)
    tbl_addr = a.pc
    HEX_SC = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6]
    for v in HEX_SC:
        a.b(v)
    for p in table_patches:
        a.buf[p]     = tbl_addr & 0xFF
        a.buf[p + 1] = (tbl_addr >> 8) & 0xFF


def finalize_plain(a):
    halt_pc = a.pc
    a.jmp(halt_pc)


def build_v4a():
    """Through F + LDA al + STA $02 + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x02)
    write_marker_raw(a, 30, 'G', 0x02)
    finalize_plain(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v4b():
    """v4a + LSR*4 + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x02)
    a.b(0x4A, 0x4A, 0x4A, 0x4A)
    write_marker_raw(a, 30, 'G', 0x02)
    finalize_plain(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v4c():
    """v4b + TAX + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x02)
    a.b(0x4A, 0x4A, 0x4A, 0x4A)
    a.b(0xAA)
    write_marker_raw(a, 30, 'G', 0x02)
    finalize_plain(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v4d():
    """v4c + LDA HEX_TBL,X + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x02)
    a.b(0x4A, 0x4A, 0x4A, 0x4A)
    a.b(0xAA)
    hi_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)
    write_marker_raw(a, 30, 'G', 0x02)
    finalize_with_table(a, [hi_patch])
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v4e():
    """v4d + STA $041A + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x02)
    a.b(0x4A, 0x4A, 0x4A, 0x4A)
    a.b(0xAA)
    hi_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)
    a.sta_abs(SCREEN + 26)
    write_marker_raw(a, 30, 'G', 0x02)
    finalize_with_table(a, [hi_patch])
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v4f():
    """v4e + LDA $02 + AND + TAX + LDA HEX_TBL,X + STA $041B + G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_zp(0x02)
    a.b(0x4A, 0x4A, 0x4A, 0x4A)
    a.b(0xAA)
    hi_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)
    a.sta_abs(SCREEN + 26)
    a.lda_zp(0x02)
    a.b(0x29, 0x0F)
    a.b(0xAA)
    lo_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)
    a.sta_abs(SCREEN + 27)
    write_marker_raw(a, 30, 'G', 0x02)
    finalize_with_table(a, [hi_patch, lo_patch])
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


VARIANTS = [
    ("drill_v4a_sta_zp",     build_v4a),
    ("drill_v4b_lsr4",       build_v4b),
    ("drill_v4c_tax",        build_v4c),
    ("drill_v4d_lda_absx",   build_v4d),
    ("drill_v4e_sta_screen", build_v4e),
    ("drill_v4f_low_nibble", build_v4f),
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
