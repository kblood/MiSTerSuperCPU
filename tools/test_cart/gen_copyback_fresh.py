#!/usr/bin/env python3
"""Test whether the LDA-al hazard is always-on or triggered by prior state.

Variants — all start from base() (screen clear only, no STA al, no LDA
al prior), then:

  fresh_a: single LDA al $200080 + STA $02 + G  (no prior SuperRAM ops)
  fresh_b: STA al + LDA al + STA $02 + G        (1 STA before, 1 LDA)
  fresh_c: 2× LDA al + STA $02 + G              (no prior STA al, 2 LDA)
  fresh_d: 1× LDA al + STA $02 (only 1 LDA al)

If fresh_a wedges, the hazard is always-on (any LDA al + STA wedges).
If fresh_a works but fresh_c wedges, the hazard needs ≥2 LDA al's.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_stalong_probe import Asm, base, sc, SCREEN, COL_RAM
from gen_copyback_bisect import (
    write_marker_raw, PRG_LOAD, OUT_DIR
)


def wrap(a):
    halt_pc = a.pc
    a.jmp(halt_pc)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_fresh_a():
    """base + LDA al + STA $02 + marker (no prior STA al or LDA al)."""
    a = Asm(PRG_LOAD)
    base(a)
    write_marker_raw(a, 0, 'A', 0x01)
    a.lda_al(0x200080)
    a.sta_zp(0x02)
    write_marker_raw(a, 8, 'B', 0x05)
    return wrap(a)


def build_fresh_b():
    """base + STA al + LDA al + STA $02 + marker."""
    a = Asm(PRG_LOAD)
    base(a)
    write_marker_raw(a, 0, 'A', 0x01)
    a.lda_imm(0x5A); a.sta_al(0x200080)
    a.lda_al(0x200080)
    a.sta_zp(0x02)
    write_marker_raw(a, 8, 'B', 0x05)
    return wrap(a)


def build_fresh_c():
    """base + 2× LDA al + STA $02 + marker (no STA al prior)."""
    a = Asm(PRG_LOAD)
    base(a)
    write_marker_raw(a, 0, 'A', 0x01)
    a.lda_al(0x200080)
    a.lda_al(0x200080)
    a.sta_zp(0x02)
    write_marker_raw(a, 8, 'B', 0x05)
    return wrap(a)


def build_fresh_d():
    """base + 1× LDA al + STA $02 + marker (minimal repro)."""
    a = Asm(PRG_LOAD)
    base(a)
    write_marker_raw(a, 0, 'A', 0x01)
    a.lda_al(0x200080)
    a.sta_zp(0x02)
    write_marker_raw(a, 8, 'B', 0x05)
    return wrap(a)


def build_fresh_e():
    """base + STA al + STA al + STA al + LDA al + STA $02. Maybe the
    hazard needs multiple STA al's (which is what cache flush + payload
    write produce)."""
    a = Asm(PRG_LOAD)
    base(a)
    write_marker_raw(a, 0, 'A', 0x01)
    a.lda_imm(0x5A); a.sta_al(0x200080)
    a.lda_imm(0x01); a.sta_al(0x00D078)     # cache flush
    a.lda_imm(0x5A); a.sta_al(0x200081)
    a.lda_al(0x200080)
    a.sta_zp(0x02)
    write_marker_raw(a, 8, 'B', 0x05)
    return wrap(a)


VARIANTS = [
    ("fresh_a_just_lda_al_sta",          build_fresh_a),
    ("fresh_b_sta_al_then_lda_al_sta",   build_fresh_b),
    ("fresh_c_two_lda_al_sta",           build_fresh_c),
    ("fresh_d_one_lda_al_minimal",       build_fresh_d),
    ("fresh_e_sta_al_cache_flush_lda",   build_fresh_e),
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
