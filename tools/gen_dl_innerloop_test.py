#!/usr/bin/env python3
"""Generate dl_innerloop.prg

Replicates the EXACT inner copy loop from DL's relocated decompressor at
$0130-$0139 (after relocation from $1422-$142B):

    DEY              ; 88
    BCC noskip       ; 90 ?? — taken on C clear; we set C=1 always so SKIP
    LDA ($AE),Y      ; B1 AE
    STA ($FE),Y      ; 91 FE
    TYA              ; 98
    BNE loop         ; D0 ??

Reproduces the loop with known source data and checks the dest matches
expectation. If T65 and P65C816 produce different result bytes at the
dest area, the inner-loop primitive itself has a CPU divergence.

Source: $C400-$C4FF = 0,1,2,...,255
Dest:   $C600-$C6FF = expected to be IDENTICAL after copy

Run on T65 (SCPU=off) and P65C816 (SCPU=on) and compare $C600 region
indirectly via screen RAM at $0400.

We display:
  $0400 = source[$00]  (control: must be $00)
  $0401 = source[$80]  (control: must be $80)
  $0402 = dest[$00]    (after copy: must be $00)
  $0403 = dest[$80]    (after copy: must be $80)
  $0404 = byte at $C5FF (a one-after-end source byte: must NOT change)
  $0405 = byte at $C601 (one-after dest start: should be $01)

If any cell != expected, that's the divergent byte.
"""
import sys

RUNTIME = 0xC000
SRC = 0xC400
DST = 0xC600
PTR_AE = 0xAE
PTR_FE = 0xFE

code = []
def emit(*bs):
    code.extend(bs)

# Setup
emit(0x78)               # SEI
emit(0xD8)               # CLD
emit(0xA2, 0xFF)         # LDX #$FF
emit(0x9A)               # TXS

# $AE,$AF = $C400 (source pointer)
emit(0xA9, SRC & 0xFF)
emit(0x85, PTR_AE)
emit(0xA9, (SRC >> 8) & 0xFF)
emit(0x85, PTR_AE + 1)

# $FE,$FF = $C600 (dest pointer)
emit(0xA9, DST & 0xFF)
emit(0x85, PTR_FE)
emit(0xA9, (DST >> 8) & 0xFF)
emit(0x85, PTR_FE + 1)

# Y = $00 (will wrap to $FF on first DEY)
emit(0xA0, 0x00)
# Carry = 1 (so BCC at start of loop is NOT taken — literal copy path)
emit(0x38)               # SEC

# loop:
loop_start = len(code)
emit(0x88)               # DEY
emit(0x90, 0x00)         # BCC +0 (never taken since C=1) — patched offset = 0 (skip nothing)
emit(0xB1, PTR_AE)       # LDA ($AE),Y
emit(0x91, PTR_FE)       # STA ($FE),Y
emit(0x98)               # TYA
back = (loop_start - (len(code) + 2)) & 0xFF
emit(0xD0, back)         # BNE loop

# Display: source[0], source[$80], dest[0], dest[$80], $C5FF, $C601
emit(0xAD, 0x00, 0xC4)   # LDA $C400 (source[0])
emit(0x8D, 0x00, 0x04)
emit(0xAD, 0x80, 0xC4)   # LDA $C480 (source[$80])
emit(0x8D, 0x01, 0x04)
emit(0xAD, 0x00, 0xC6)   # LDA $C600 (dest[0])
emit(0x8D, 0x02, 0x04)
emit(0xAD, 0x80, 0xC6)   # LDA $C680 (dest[$80])
emit(0x8D, 0x03, 0x04)
emit(0xAD, 0xFF, 0xC5)   # LDA $C5FF (one past source end)
emit(0x8D, 0x04, 0x04)
emit(0xAD, 0x01, 0xC6)   # LDA $C601 (dest[1])
emit(0x8D, 0x05, 0x04)

# halt
halt = RUNTIME + len(code)
emit(0x4C, halt & 0xFF, (halt >> 8) & 0xFF)

body_len = len(code)
print(f"; body ends at ${RUNTIME + body_len:04X}", file=sys.stderr)

# Pad to source area
pad = (SRC - RUNTIME) - body_len
code.extend([0xEA] * pad)

# Source data: 0..255 at $C400..$C4FF
for i in range(256):
    code.append(i)

# Pad to $C600 if not already (we should have pad to $C500, then more)
while len(code) < (DST - RUNTIME):
    code.append(0)
# Dest area pre-init to $FF (so we can detect un-copied bytes)
for _ in range(256):
    code.append(0xFF)

# BASIC stub
basic_stub = bytes([
    0x0C, 0x08, 0x0A, 0x00, 0x9E,
    0x34, 0x39, 0x31, 0x35, 0x32,
    0x00, 0x00, 0x00,
])
load_addr = 0x0801
gap = RUNTIME - (load_addr + len(basic_stub))
content = bytearray(basic_stub) + bytearray([0x00] * gap) + bytearray(code)
prg = bytes([load_addr & 0xFF, (load_addr >> 8) & 0xFF]) + bytes(content)

with open("tools/dl_innerloop.prg", "wb") as f:
    f.write(prg)
print(f"; wrote tools/dl_innerloop.prg ({len(prg)} bytes)", file=sys.stderr)
print(f"; expected screen $0400..$0405:", file=sys.stderr)
print(f";   $00 (src[0]), $80 (src[$80]), $00 (dst[0]), $80 (dst[$80]), $FF (untouched $C5FF), $01 (dst[1])", file=sys.stderr)
