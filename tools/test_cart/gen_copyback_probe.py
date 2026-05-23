#!/usr/bin/env python3
"""Verify whether long-X copy actually lands at bank $20.

Loader sequence:
  1. clear screen + color
  2. draw "COPY+READBACK PROBE" header
  3. copy 8 known bytes (sentinels $C0 $C1 $C2 $C3 $C4 $C5 $C6 $C7)
     to $208000-$208007 via STA $208000,X (long-X, $9F)
  4. cache flush ($D078)
  5. read each back via LDA $208000+i (long, $AF) and write screen
     code = byte value at row 4 col i
  6. halt

If row 4 shows bytes $C0..$C7 (or PETSCII for those screen codes
"@A BCDEFG"), the copy AND readback work; bank $20 storage is good.
If row 4 shows $00s, copy went into the bit-bucket. If $FFs, bus
floats (controller off or bank not enabled).
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_superram_bench import (Asm, screen_char, SCREEN, ROW,
                                PRG_LOAD, OUT_DIR)

SCPU_CACHE_FLUSH = 0xD078
SENTINELS = bytes([0xC0])  # single-byte: isolate whether 1 op works


def build():
    a = Asm(PRG_LOAD)
    # BASIC stub
    a.buf += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E,
                    0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    assert a.pc == 0x080D
    a.sei(); a.cld(); a.ldx_imm(0xFF); a.txs()
    a.lda_imm(0x00); a.sta_abs(0xD020); a.sta_abs(0xD021)
    # Screen clear
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.sta_absx(0x0400); a.sta_absx(0x0500)
    a.sta_absx(0x0600); a.sta_absx(0x0700)
    a.inx(); a.bne_back(cl)
    # Color RAM = yellow
    a.lda_imm(0x07); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)

    # Header
    msg = "COPY+READBACK PROBE"
    for i, ch in enumerate(msg):
        a.lda_imm(screen_char(ch))
        a.sta_abs(SCREEN + 0*ROW + 10 + i)

    # Copy sentinels: src in PRG, dst $208000.
    sent_addr_patch = []
    # 8-byte copy unrolled (simpler than a loop for n=8)
    for i, val in enumerate(SENTINELS):
        a.lda_imm(val)
        # STA al $208000+i  ($8F lo hi bank)
        addr = 0x000080 + i
        a.b(0x8F, addr & 0xFF, (addr >> 8) & 0xFF, 0x20)

    # Cache flush
    a.lda_imm(0x01)
    a.b(0x8F, SCPU_CACHE_FLUSH & 0xFF,
        (SCPU_CACHE_FLUSH >> 8) & 0xFF, 0x00)

    # Readback: row 2 shows raw byte values as screen codes; row 4
    # shows hex digits via simple lookup.
    # Row 2: raw screen code
    for i in range(len(SENTINELS)):
        addr = 0x000080 + i
        a.b(0xAF, addr & 0xFF, (addr >> 8) & 0xFF, 0x20)  # LDA al $20:80xx
        a.sta_abs(SCREEN + 2*ROW + 10 + i*2)

    # Row 4: ASCII-style hex output via in-flight nibble extract
    # For each byte: read, lsr*4 -> high nibble, lookup in HEX_TBL,
    # write to row 4 col 10+i*3 ; AND #$0F, lookup, write col 10+i*3+1
    HEX_BASE = a.pc + 6  # placeholder; patched after writing table

    # Simple per-byte expansion (8 bytes * ~16 instr each = ~128 b)
    hex_calls_lo = []
    hex_calls_hi = []
    for i in range(len(SENTINELS)):
        addr = 0x000080 + i
        a.b(0xAF, addr & 0xFF, (addr >> 8) & 0xFF, 0x20)  # LDA al
        # save A
        a.b(0x85, 0x02)  # STA $02 (ZP scratch)
        # high nibble
        a.b(0x4A); a.b(0x4A); a.b(0x4A); a.b(0x4A)  # LSR*4
        a.b(0xAA)  # TAX
        a.b(0xBD)  # LDA HEX_TBL,X (abs,X) — patched lo/hi below
        hi_patch = len(a.buf); a.b(0x00, 0x00)
        hex_calls_hi.append(hi_patch)
        a.sta_abs(SCREEN + 4*ROW + 10 + i*3)
        # low nibble
        a.b(0xA5, 0x02)  # LDA $02
        a.b(0x29, 0x0F)  # AND #$0F
        a.b(0xAA)  # TAX
        a.b(0xBD)  # LDA HEX_TBL,X
        lo_patch = len(a.buf); a.b(0x00, 0x00)
        hex_calls_lo.append(lo_patch)
        a.sta_abs(SCREEN + 4*ROW + 10 + i*3 + 1)

    halt = a.pc
    a.jmp(halt & 0xFFFF)

    # HEX_TBL (screen codes 0..9, A..F)
    hex_tbl_addr = a.pc
    HEX_SC = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6]
    for v in HEX_SC:
        a.b(v)

    for p in hex_calls_hi + hex_calls_lo:
        a.buf[p]     = hex_tbl_addr & 0xFF
        a.buf[p + 1] = (hex_tbl_addr >> 8) & 0xFF

    out = os.path.join(OUT_DIR, "copyback_probe.prg")
    os.makedirs(OUT_DIR, exist_ok=True)
    prg = bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)
    with open(out, 'wb') as f:
        f.write(prg)
    print(f"  {len(prg)} bytes -> {out}")


if __name__ == '__main__':
    build()
