#!/usr/bin/env python3
"""Multi-value probe: write a variety of values to bank $2A:$6C00..$2A:$6C03,
then read back and report all 4. Latches mem_44_r and mem_45_r capture
$2A:$6C00 and $2A:$6C03 reads (not $6C01/$6C02). Use those two distinct
addresses to write/read 2 different values in same test.

If $3E reads as $3E but $A5 reads as $00, we'll see the asymmetry within a
single test (no cross-run state confusion).
"""
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_value_sweep.prg')
basic_stub = bytes([0x0B,0x08,0x0A,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
code = []
def emit(*bs): code.extend(bs)
emit(0x78)
emit(0xA9, 0x35, 0x85, 0x01)
emit(0x8D, 0x7E, 0xD0)
emit(0x8D, 0x7A, 0xD0)
emit(0x8D, 0x7B, 0xD0)
emit(0xA9, 0x03, 0x8D, 0x20, 0xD0)   # cyan
# zp pointer = $00:$6C00 base, native+8-bit M for indirect-long
emit(0xA9, 0x00, 0x85, 0xFB)
emit(0xA9, 0x6C, 0x85, 0xFC)
emit(0xA9, 0x2A, 0x85, 0xFD)
# Write $3E to $2A:$6C00 (Y=0)
emit(0xA9, 0x3E)
emit(0xA0, 0x00)
emit(0x97, 0xFB)
# Write $A5 to $2A:$6C03 (Y=3)
emit(0xA9, 0xA5)
emit(0xA0, 0x03)
emit(0x97, 0xFB)
# Cyan border, do a passive read via LDA so the latch updates
emit(0x18, 0xFB)                     # CLC; XCE -> native
emit(0xC2, 0x20)                     # REP M=16
emit(0xAF, 0x00, 0x6C, 0x2A)         # LDA $2A:$6C00 (low byte should latch as $3E)
emit(0xAF, 0x03, 0x6C, 0x2A)         # LDA $2A:$6C03 (low byte should latch as $A5)
emit(0xE2, 0x20)
# Border green and stay (we always go green; UART tells the truth)
emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)
fj=len(code); emit(0x4C, 0x00, 0x00)
addr=0x080D+fj; code[fj+1]=addr&0xFF; code[fj+2]=(addr>>8)&0xFF
prg = bytes([0x01,0x08]) + basic_stub + bytes(code)
with open(OUT,'wb') as f: f.write(prg)
print('wrote',OUT,len(prg),'bytes')
