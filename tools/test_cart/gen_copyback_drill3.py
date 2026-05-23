#!/usr/bin/env python3
"""Characterize the LDA al → bank-0 STA hazard.

v4a1 (LDA al $200080, then LDA imm + STA abs for G marker) wedges.
v4a6 (LDA al + 8 NOPs + STA $02 + G) renders fine.

Hypothesis: a bank-0 STA immediately following LDA al $200080 wedges
the CPU. NOPs interleaved drain whatever pipeline state is the
hazard.

This probe set finds:
  - min NOPs needed
  - whether LDA al + JMP (no STA) wedges
  - whether LDA al + STA al (bank-$20 target) wedges
  - whether LDA #imm (no SuperRAM read) + STA $02 works
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
    emit_prefix(a)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    emit_lda_readback(a)
    a.sta_abs(SCREEN + 24)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)


def wrap(a):
    halt_pc = a.pc
    a.jmp(halt_pc)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_lda_then_jmp():
    """LDA al + JMP self (no follow-up STA). If this renders nothing
    past F, the bug is in the LDA al itself, not in a following STA."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    halt_pc = a.pc
    a.jmp(halt_pc)
    # Stick a G marker AFTER the JMP self — unreachable but proves the
    # CPU got stuck not just on the page boundary.
    write_marker_raw(a, 30, 'G', 0x02)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_lda_then_jmp_marker_after_jmp():
    """LDA al then immediately JMP marker_block (skip 0 NOPs); marker_block writes G."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    jmp_to = len(a.buf) + 3
    a.b(0x4C, 0x00, 0x00)  # JMP placeholder, patch below
    # Marker block
    target = a.pc
    a.buf[jmp_to - 2] = target & 0xFF
    a.buf[jmp_to - 1] = (target >> 8) & 0xFF
    write_marker_raw(a, 30, 'G', 0x02)
    halt_pc = a.pc
    a.jmp(halt_pc)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def _build_with_nop_pad(nops):
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    for _ in range(nops): a.b(0xEA)
    a.sta_zp(0x02)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_nop0():  return _build_with_nop_pad(0)
def build_nop1():  return _build_with_nop_pad(1)
def build_nop2():  return _build_with_nop_pad(2)
def build_nop3():  return _build_with_nop_pad(3)
def build_nop4():  return _build_with_nop_pad(4)
def build_nop6():  return _build_with_nop_pad(6)


def build_lda_al_then_sta_al():
    """3rd LDA al + STA al $200081 (bank-$20 target) + G marker.

    If this also wedges, the issue is in *any* memory op after LDA al.
    If it renders, the issue is specifically a bank-0 STA after LDA al."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    a.sta_al(0x200081)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_lda_imm_then_sta_zp02():
    """LDA #$5A (NO SuperRAM read) + STA $02 + G.

    Reference: same as v4a5 but kept here for ordering."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    a.lda_imm(0x5A)
    a.sta_zp(0x02)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


def build_lda_al_then_two_lda_al():
    """3rd LDA al + 4th LDA al + G marker. No STA between."""
    a = Asm(PRG_LOAD)
    common_through_F(a)
    emit_lda_readback(a)
    emit_lda_readback(a)
    write_marker_raw(a, 30, 'G', 0x02)
    return wrap(a)


VARIANTS = [
    ("drill3_a_lda_then_jmpself",      build_lda_then_jmp),
    ("drill3_b_lda_then_jmp_to_G",     build_lda_then_jmp_marker_after_jmp),
    ("drill3_c_nop0_stazp02",          build_nop0),
    ("drill3_d_nop1_stazp02",          build_nop1),
    ("drill3_e_nop2_stazp02",          build_nop2),
    ("drill3_f_nop3_stazp02",          build_nop3),
    ("drill3_g_nop4_stazp02",          build_nop4),
    ("drill3_h_nop6_stazp02",          build_nop6),
    ("drill3_i_lda_al_then_sta_al",    build_lda_al_then_sta_al),
    ("drill3_j_lda_imm_sta_zp02",      build_lda_imm_then_sta_zp02),
    ("drill3_k_two_lda_al",            build_lda_al_then_two_lda_al),
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
