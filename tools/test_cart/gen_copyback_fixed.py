#!/usr/bin/env python3
"""Workaround-validated copyback probe: insert NOP after every LDA al.

Demonstrates that the bisect-pinpointed pipeline hazard is software-
workable. The original copyback_probe wedged at the hex-display block
because LDA al $200080 was immediately followed by STA $02 (sta_zp).
A single NOP between the long load and the next memory op restores
correctness.

Output: row 4 col 26/27 should show the hex of $5A = '5A' (screen
codes 53, 1).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_stalong_probe import Asm, base, sc, SCREEN, COL_RAM
from gen_copyback_bisect import (
    write_marker_raw, emit_prefix, emit_cache_flush, emit_lda_readback,
    PRG_LOAD, OUT_DIR
)


def lda_al_then_nop(a, addr):
    """LDA al + NOP — the workaround pattern."""
    a.lda_al(addr)
    a.b(0xEA)


def build():
    a = Asm(PRG_LOAD)
    emit_prefix(a)                               # AAAA + BBBB + STA al $20:80 + CCCC
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)

    lda_al_then_nop(a, 0x200080)                 # 1st readback, NOP pad
    write_marker_raw(a, 16, 'E', 0x03)

    lda_al_then_nop(a, 0x200080)                 # 2nd readback, NOP pad
    a.sta_abs(SCREEN + 24)                       # raw screen-code at col 24
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)

    # Hex display: LDA al + NOP + sta_zp $02
    a.lda_al(0x200080); a.b(0xEA)
    a.sta_zp(0x02)
    a.b(0x4A, 0x4A, 0x4A, 0x4A)                  # LSR*4 (high nibble)
    a.b(0xAA)                                    # TAX
    hi_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)                        # LDA HEX_TBL,X (patched)
    a.sta_abs(SCREEN + 26)
    a.lda_zp(0x02)
    a.b(0x29, 0x0F)                              # AND #$0F
    a.b(0xAA)                                    # TAX
    lo_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)                        # LDA HEX_TBL,X (patched)
    a.sta_abs(SCREEN + 27)
    a.lda_imm(0x07)
    a.sta_abs(COL_RAM + 26); a.sta_abs(COL_RAM + 27)

    write_marker_raw(a, 30, 'G', 0x02)
    halt_pc = a.pc
    a.jmp(halt_pc)

    # HEX_TBL placed after halt
    tbl_addr = a.pc
    for v in [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6]:
        a.b(v)
    a.buf[hi_patch]     = tbl_addr & 0xFF
    a.buf[hi_patch + 1] = (tbl_addr >> 8) & 0xFF
    a.buf[lo_patch]     = tbl_addr & 0xFF
    a.buf[lo_patch + 1] = (tbl_addr >> 8) & 0xFF
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


VARIANTS = [("copyback_fixed_nopped", build)]


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
