#!/usr/bin/env python3
"""Pure-READ test: doesn't write anything to bank $2A. Just LDA long and report.
If SDRAM has $3E from prior write, this confirms reads work and prior writes
landed. If it returns $00, either SDRAM was cleared OR reads from SuperRAM
bank $2A return junk.
"""
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_passive_read.prg')
basic_stub = bytes([0x0B,0x08,0x0A,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
code = []
def emit(*bs): code.extend(bs)
emit(0x78)
emit(0xA9, 0x35, 0x85, 0x01)
emit(0x8D, 0x7E, 0xD0)
emit(0x8D, 0x7A, 0xD0)               # 1MHz
emit(0x8D, 0x7B, 0xD0)               # turbo
emit(0xA9, 0x03, 0x8D, 0x20, 0xD0)   # cyan
# native 16-bit M, LDA long ONLY (no STA)
emit(0x18, 0xFB)
emit(0xC2, 0x20)
emit(0xAF, 0x00, 0x6C, 0x2A)
emit(0xE2, 0x20)
# Don't compare; just write A_low to $D020 so border colour reflects what we read
emit(0x8D, 0x20, 0xD0)               # STA $D020 (border = read value & $0F)
fj=len(code); emit(0x4C, 0x00, 0x00) # JMP self forever
addr=0x080D+fj; code[fj+1]=addr&0xFF; code[fj+2]=(addr>>8)&0xFF
prg = bytes([0x01,0x08]) + basic_stub + bytes(code)
with open(OUT,'wb') as f: f.write(prg)
print('wrote',OUT,len(prg),'bytes')
