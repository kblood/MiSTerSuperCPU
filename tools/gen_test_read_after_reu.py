#!/usr/bin/env python3
"""Test: load doom.reu, then immediately read SuperRAM bank $2A:$6C00 via LDA long.
NO writes. If REU and SuperRAM share SDRAM, this should return $3E.
"""
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_read_after_reu.prg')
basic_stub = bytes([0x0B,0x08,0x0A,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
code = []
def emit(*bs): code.extend(bs)
emit(0x78)
emit(0xA9, 0x35, 0x85, 0x01)
emit(0x8D, 0x7E, 0xD0)               # SCPU regs en
emit(0x8D, 0x7B, 0xD0)               # turbo on
emit(0xA9, 0x03, 0x8D, 0x20, 0xD0)   # cyan
# Native + 16-bit M; LDA long $2A:$6C00 directly (NO long-store first)
emit(0x18, 0xFB)                     # CLC; XCE
emit(0xC2, 0x20)                     # REP #$20
emit(0xAF, 0x00, 0x6C, 0x2A)         # LDA $2A:$6C00
emit(0xE2, 0x20)                     # SEP #$20
emit(0xC9, 0x3E)
bne_pos=len(code); emit(0xD0, 0x00)
emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)
pj=len(code); emit(0x4C, 0x00, 0x00)
red=len(code)
emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)
fj=len(code); emit(0x4C, 0x00, 0x00)
code[bne_pos+1] = (red - (bne_pos+2)) & 0xFF
addr=0x080D+pj; code[pj+1]=addr&0xFF; code[pj+2]=(addr>>8)&0xFF
addr=0x080D+fj; code[fj+1]=addr&0xFF; code[fj+2]=(addr>>8)&0xFF
prg = bytes([0x01,0x08]) + basic_stub + bytes(code)
with open(OUT,'wb') as f: f.write(prg)
print('wrote',OUT,len(prg),'bytes')
