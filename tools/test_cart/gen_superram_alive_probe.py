#!/usr/bin/env python3
"""Probe: does the bench's main_loop in bank $20 actually reach?

Same loader as gen_superram_bench, same payload copy to $208000, same
JML to $208000, same PHK/PLB. Then INSTEAD of the timed Timer-A loop +
display update, the payload just writes a fixed "ALIVE" string into
bank-$00 screen RAM via long indirect Y, then halts. Cache flush after
write to make screen update visible.

If "ALIVE" appears in row 6 -> JML and PHK/PLB and bank-$20 code +
indirect screen write all work. Subsequent failure of COUNT/PASS in
the real bench is in the per-iteration display routine.

If row 6 stays blank -> the JML/PHK/PLB path is broken and the bench
hangs before main_loop ever runs.
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
    """Bank-$20-resident: write 'ALIVE' to row 6 col 8, flush, halt."""
    a = Asm(PAYLOAD_ADDR)
    a.phk()         # push prog bank ($20)
    a.plb()         # data bank = $20
    # Write 'ALIVE' string at SCREEN+6*ROW+8 via STA al (long abs).
    # Use long STA ($8F) which encodes the bank in the operand and
    # ignores DBR. If this writes appear on screen, the bank-$20 payload
    # reaches main_loop and can write bank-$00 screen via long opcodes.
    msg = 'ALIVE BANK20'
    base = SCREEN + 6*ROW + 8
    for i, ch in enumerate(msg):
        a.lda_imm(screen_char(ch))
        # STA al $00:base+i (4-byte long-abs store)
        a.b(0x8F, (base + i) & 0xFF, ((base + i) >> 8) & 0xFF, 0x00)
    # Force cache flush in case bank-$20 writes to bank-$00 are cached.
    a.lda_imm(0x01)
    a.b(0x8F, SCPU_CACHE_FLUSH & 0xFF,
        (SCPU_CACHE_FLUSH >> 8) & 0xFF, 0x00)  # STA al $00D078
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
    # Screen clear
    a.lda_imm(32); a.ldx_imm(0)
    cl = a.pc
    a.sta_absx(0x0400); a.sta_absx(0x0500)
    a.sta_absx(0x0600); a.sta_absx(0x0700)
    a.inx(); a.bne_back(cl)
    # Color RAM
    a.lda_imm(0x05); a.ldx_imm(0)
    cf = a.pc
    a.sta_absx(0xD800); a.sta_absx(0xD900)
    a.sta_absx(0xDA00); a.sta_absx(0xDB00)
    a.inx(); a.bne_back(cf)
    # Header so we know loader ran
    text = "LOADER OK -> JML $200800"
    base = SCREEN + 0*ROW + 7
    for i, ch in enumerate(text):
        a.lda_imm(screen_char(ch))
        a.sta_abs(base + i)
    # Cache flush before bank $20 copy
    a.lda_imm(0x01)
    a.b(0x8F, SCPU_CACHE_FLUSH & 0xFF,
        (SCPU_CACHE_FLUSH >> 8) & 0xFF, 0x00)  # STA al $00D078
    # Copy payload to $208000 via long-X
    size = len(payload_bytes)
    assert size <= 256, f"payload {size} > 256 bytes"
    a.ldx_imm(0x00)
    copy = a.pc
    src_lo_patch = len(a.buf) + 1
    a.lda_absx(0x0000)              # BD ll hh
    a.b(0x9F, PAYLOAD_ADDR & 0xFF,  # STA al,X $208000
        (PAYLOAD_ADDR >> 8) & 0xFF, PAYLOAD_BANK)
    a.inx()
    a.cpx_imm(size & 0xFF)
    off = copy - (a.pc + 2)
    assert -128 <= off < 0
    a.b(0xD0, off & 0xFF)
    # Cache flush after copy
    a.lda_imm(0x01)
    a.b(0x8F, SCPU_CACHE_FLUSH & 0xFF,
        (SCPU_CACHE_FLUSH >> 8) & 0xFF, 0x00)
    # JML $20:8000
    a.jml(PAYLOAD_LONG)
    # Inline payload
    payload_local = a.pc
    a.buf += bytes(payload_bytes)
    # Patch src_lo
    a.buf[src_lo_patch]     = payload_local & 0xFF
    a.buf[src_lo_patch + 1] = (payload_local >> 8) & 0xFF
    return bytes([PRG_LOAD & 0xFF, (PRG_LOAD >> 8) & 0xFF]) + bytes(a.buf)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    payload = build_payload()
    print(f"payload {len(payload)} bytes")
    prg = build_loader(payload)
    out = os.path.join(OUT_DIR, "superram_alive_probe.prg")
    with open(out, 'wb') as f:
        f.write(prg)
    print(f"PRG {len(prg)} bytes -> {out}")


if __name__ == '__main__':
    main()
