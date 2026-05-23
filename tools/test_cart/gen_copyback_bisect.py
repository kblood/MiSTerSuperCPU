#!/usr/bin/env python3
"""Incremental bisect of the bank-$20 copyback wedge.

Starts from build_emu_sta_superram (known-good "AAA BBBB CCC" probe) and
adds copyback features one at a time. Each variant emits an extra
post-step marker at a later column so the screenshot tells us how far
the CPU got:

  pos 0-3   "AAAA" white  : reached start
  pos 4-7   "BBBB" green  : NOPs/pre-op ran
  pos 8-11  "CCC " orange : STA al $200080 survived
  pos 12-15 "DDDD" yellow : after $D078 cache flush (v1+)
  pos 16-19 "EEEE" cyan   : LDA al $200080 returned (v2+, $5A in A)
  pos 20-23 "FFFF" purple : raw STA $0400+col wrote (v3+) — readback shown at pos 24
  pos 24    raw screen byte from LDA al (v3+)
  pos 26    hex high nibble of readback (v4+)
  pos 27    hex low  nibble of readback (v4+)
  pos 30-33 "GGGG" red    : header-draw loop completed (v5+)
  pos 34-37 "HHHH" blue   : $D020/$D021 writes completed (v6+)

First variant where the trailing marker fails to appear identifies the
trigger.

Output PRGs are intended to be wrapped with prg_to_crt.py and deployed
via load_crt.py / deploy_copyback.py-style helpers.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_stalong_probe import Asm, base, marker, halt, sc, SCREEN, COL_RAM

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
PRG_LOAD = 0x0801
SCPU_CACHE_FLUSH = 0xD078


def write_marker_raw(a, col, char, color, count=4):
    """Same as marker() but inlined here for clarity / future tweaks."""
    for i in range(count):
        a.lda_imm(sc(char)); a.sta_abs(SCREEN + col + i)
        a.lda_imm(color); a.sta_abs(COL_RAM + col + i)


def emit_prefix(a):
    """AAAA + BBBB + LDA #$5A; STA al $200080 + CCC."""
    base(a)
    write_marker_raw(a, 0, 'A', 0x01)
    write_marker_raw(a, 4, 'B', 0x05)
    a.lda_imm(0x5A)
    a.sta_al(0x200080)
    write_marker_raw(a, 8, 'C', 0x0A)


def emit_cache_flush(a):
    """STA al $00D078 #$01 — cache flush via helper (same as working probe)."""
    a.lda_imm(0x01)
    a.sta_al(0x00D078)


def emit_lda_readback(a):
    """LDA al $200080 — A gets readback byte."""
    a.lda_al(0x200080)


def build_v0_baseline():
    a = Asm(PRG_LOAD)
    emit_prefix(a)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v1_flush():
    a = Asm(PRG_LOAD)
    emit_prefix(a)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v2_readback():
    a = Asm(PRG_LOAD)
    emit_prefix(a)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v3_screen_store():
    a = Asm(PRG_LOAD)
    emit_prefix(a)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    # New: LDA again then STA to screen so the byte value shows
    emit_lda_readback(a)
    a.sta_abs(SCREEN + 24)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v4_hex_split():
    """Add the LSR*4 / TAX / LDA HEX_TBL,X / STA pattern from copyback."""
    a = Asm(PRG_LOAD)
    emit_prefix(a)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    emit_lda_readback(a)
    a.sta_abs(SCREEN + 24)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)
    # Hex display: save byte at ZP $02
    emit_lda_readback(a)
    a.sta_zp(0x02)
    # high nibble
    a.b(0x4A); a.b(0x4A); a.b(0x4A); a.b(0x4A)  # LSR*4
    a.b(0xAA)  # TAX
    hi_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)  # LDA HEX_TBL,X (patched)
    a.sta_abs(SCREEN + 26)
    # low nibble
    a.lda_zp(0x02)
    a.b(0x29, 0x0F)  # AND #$0F
    a.b(0xAA)  # TAX
    lo_patch = len(a.buf) + 1
    a.b(0xBD, 0x00, 0x00)  # LDA HEX_TBL,X (patched)
    a.sta_abs(SCREEN + 27)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 26)
    a.sta_abs(COL_RAM + 27)
    write_marker_raw(a, 30, 'G', 0x02)
    halt_pc = a.pc
    a.jmp(halt_pc)
    # HEX_TBL placed after halt
    tbl_addr = a.pc
    HEX_SC = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6]
    for v in HEX_SC:
        a.b(v)
    a.buf[hi_patch]     = tbl_addr & 0xFF
    a.buf[hi_patch + 1] = (tbl_addr >> 8) & 0xFF
    a.buf[lo_patch]     = tbl_addr & 0xFF
    a.buf[lo_patch + 1] = (tbl_addr >> 8) & 0xFF
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v5_header_draw():
    """v4 + a "COPY READBACK PROBE" draw loop placed BEFORE the STA al.

    Drawing on row 1 (cols 10..29) so it doesn't clobber the marker row.
    """
    a = Asm(PRG_LOAD)
    base(a)
    # Header on row 1
    msg = "COPY READBACK PROBE"
    for i, ch in enumerate(msg):
        a.lda_imm(sc(ch)); a.sta_abs(SCREEN + 40 + 10 + i)
    write_marker_raw(a, 0, 'A', 0x01)
    write_marker_raw(a, 4, 'B', 0x05)
    a.lda_imm(0x5A); a.sta_al(0x200080)
    write_marker_raw(a, 8, 'C', 0x0A)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    emit_lda_readback(a)
    a.sta_abs(SCREEN + 24)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)
    emit_lda_readback(a)
    a.sta_zp(0x02)
    a.b(0x4A); a.b(0x4A); a.b(0x4A); a.b(0x4A)
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
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 26); a.sta_abs(COL_RAM + 27)
    write_marker_raw(a, 30, 'G', 0x02)
    halt_pc = a.pc
    a.jmp(halt_pc)
    tbl_addr = a.pc
    for v in [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6]:
        a.b(v)
    a.buf[hi_patch]     = tbl_addr & 0xFF
    a.buf[hi_patch + 1] = (tbl_addr >> 8) & 0xFF
    a.buf[lo_patch]     = tbl_addr & 0xFF
    a.buf[lo_patch + 1] = (tbl_addr >> 8) & 0xFF
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def build_v6_d020_writes():
    """v5 + black-screen writes ($D020/$D021 = 0) before drawing."""
    a = Asm(PRG_LOAD)
    base(a)
    # $D020/$D021 writes
    a.lda_imm(0x00); a.sta_abs(0xD020); a.sta_abs(0xD021)
    msg = "COPY READBACK PROBE"
    for i, ch in enumerate(msg):
        a.lda_imm(sc(ch)); a.sta_abs(SCREEN + 40 + 10 + i)
    write_marker_raw(a, 0, 'A', 0x01)
    write_marker_raw(a, 4, 'B', 0x05)
    a.lda_imm(0x5A); a.sta_al(0x200080)
    write_marker_raw(a, 8, 'C', 0x0A)
    emit_cache_flush(a)
    write_marker_raw(a, 12, 'D', 0x07)
    emit_lda_readback(a)
    write_marker_raw(a, 16, 'E', 0x03)
    emit_lda_readback(a)
    a.sta_abs(SCREEN + 24)
    a.lda_imm(0x07); a.sta_abs(COL_RAM + 24)
    write_marker_raw(a, 20, 'F', 0x04)
    write_marker_raw(a, 34, 'H', 0x06)
    halt(a)
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


VARIANTS = [
    ("cbk_v0_baseline",      build_v0_baseline),
    ("cbk_v1_flush",         build_v1_flush),
    ("cbk_v2_readback",      build_v2_readback),
    ("cbk_v3_screen_store",  build_v3_screen_store),
    ("cbk_v4_hex_split",     build_v4_hex_split),
    ("cbk_v5_header_draw",   build_v5_header_draw),
    ("cbk_v6_d020_writes",   build_v6_d020_writes),
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
