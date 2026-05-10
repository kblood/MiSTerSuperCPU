#!/usr/bin/env python3
"""Definitive SuperRAM write-path test, native mode, absolute long.

Approach:
  - SCPU regs enabled, turbo on
  - CLC; XCE -> native mode
  - SEP #$30 -> M=X=8-bit
  - LDA #$A5
  - STA $2A:$6C00  (opcode $8F, direct absolute long, NO zp pointer)
  - LDA $2A:$6C00  (opcode $AF, direct absolute long load)
  - CMP #$A5 -> green if equal, red otherwise

Value $A5 chosen as unique (never used in prior tests; no REU residue match).
If this FAILS with bank $2A:$6C00 != $A5, SuperRAM write path is broken
for direct absolute long stores at bank $2A on this build. If PASSES, the
bug is specific to STA [zp],Y opcode $97 in emulation mode.
"""
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_abs_long_superram.prg')
basic_stub = bytes([0x0B,0x08,0x0A,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
code = []
def emit(*bs): code.extend(bs)
emit(0x78)                            # SEI
emit(0xA9, 0x35, 0x85, 0x01)          # $01 = $35
emit(0x8D, 0x7E, 0xD0)                # SCPU regs+HW enable
emit(0x8D, 0x7B, 0xD0)                # turbo on
emit(0xA9, 0x03, 0x8D, 0x20, 0xD0)    # cyan
# Native mode
emit(0x18, 0xFB)                      # CLC; XCE
emit(0xC2, 0x30)                      # REP #$30  (clear M and X first)
emit(0xE2, 0x30)                      # SEP #$30  (M=X=8-bit)
# Direct absolute long store
emit(0xA9, 0xA5)                      # LDA #$A5
emit(0x8F, 0x00, 0x6C, 0x2A)          # STA $2A:$6C00 (opcode $8F)
# Read back
emit(0xA9, 0x00)                      # LDA #$00 (clear A so we know read-back is real)
emit(0xAF, 0x00, 0x6C, 0x2A)          # LDA $2A:$6C00 (opcode $AF)
emit(0xC9, 0xA5)                      # CMP #$A5
bne_pos=len(code); emit(0xD0, 0x00)
emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)    # green
pj=len(code); emit(0x4C, 0x00, 0x00)
red=len(code)
emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)    # red
fj=len(code); emit(0x4C, 0x00, 0x00)
code[bne_pos+1] = (red - (bne_pos+2)) & 0xFF
addr=0x080D+pj; code[pj+1]=addr&0xFF; code[pj+2]=(addr>>8)&0xFF
addr=0x080D+fj; code[fj+1]=addr&0xFF; code[fj+2]=(addr>>8)&0xFF
prg = bytes([0x01,0x08]) + basic_stub + bytes(code)
with open(OUT,'wb') as f: f.write(prg)
print('wrote', OUT, len(prg), 'bytes')
