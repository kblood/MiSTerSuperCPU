#!/usr/bin/env python3
"""Generate cpu_modes_test.prg

Exercises 16 distinct addressing-mode / arithmetic / RMW test cases.
Each test writes one result byte to $0400+N. Visible characters on the
top-left corner of the screen reveal which (if any) test diverges
between T65 (SCPU=off) and P65C816 emu-mode (SCPU=on).

Layout (each cell N at $0400+N, expected screen-poke value in parens):
  T0  immediate -> abs            ($01)
  T1  abs read                    ($02)
  T2  abs,X read                  ($03)
  T3  abs,Y read                  ($04)
  T4  (zp),Y read                 ($05)
  T5  zp,X read                   ($06)
  T6  abs,X with page cross       ($07)
  T7  BCD ADC ($25 + $48)         ($73)
  T8  BCD SBC ($50 - $13)         ($37)
  T9  INC abs                     ($0A)
  T10 ASL A                       ($0B)
  T11 ROR A with carry in         ($81)
  T12 PHA / PLA round-trip        ($0D)
  T13 JSR/RTS return value        ($0E)
  T14 (zp,X) read                 ($0F)
  T15 indirect JMP                ($10)

The C64 character ROM maps screen poke values 0..63 to standard glyphs
(@ A B C D ... etc), so divergent values are visible. SCPU=on baseline
should match SCPU=off baseline if all 16 instruction classes are clean.
"""
import sys

# ---------- Runtime code at $C000 ----------
RUNTIME = 0xC000
DATA_C100 = 0xC100      # test data table
SUB_RTS  = 0xC200       # subroutine for T13
JMP_TGT  = 0xC210       # target for indirect JMP T15
PTR_FB   = 0xFB         # ZP pointer used in (zp),Y and (zp,X)

code = []

def emit(*bs):
    code.extend(bs)

# --- Setup: SEI, clear D, X=Y=0 ---
emit(0x78)                   # SEI
emit(0xD8)                   # CLD (start in binary mode)
emit(0xA2, 0xFF)             # LDX #$FF
emit(0x9A)                   # TXS
# Setup ZP pointer $FB,$FC = $C100
emit(0xA9, 0x00)             # LDA #$00
emit(0x85, PTR_FB)           # STA $FB
emit(0xA9, 0xC1)             # LDA #$C1
emit(0x85, PTR_FB+1)         # STA $FC
# Setup ZP $03..$08 = $05,$06,$07,$08,$09,$0A (for zp,X test)
for i, v in enumerate([0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]):
    emit(0xA9, v)            # LDA #v
    emit(0x85, 0x03+i)       # STA $03+i

# --- T0: immediate -> abs.  Expect $0400 = $01 ---
emit(0xA9, 0x01)             # LDA #$01
emit(0x8D, 0x00, 0x04)       # STA $0400

# --- T1: abs read (uses $C100 = $02). Expect $0401 = $02 ---
emit(0xAD, 0x00, 0xC1)       # LDA $C100
emit(0x8D, 0x01, 0x04)       # STA $0401

# --- T2: abs,X read with X=$01. $C101 = $03. Expect $0402 = $03 ---
emit(0xA2, 0x01)             # LDX #$01
emit(0xBD, 0x00, 0xC1)       # LDA $C100,X  -> $C101
emit(0x8D, 0x02, 0x04)       # STA $0402

# --- T3: abs,Y read with Y=$04. $C104 = $04. Expect $0403 = $04 ---
emit(0xA0, 0x04)             # LDY #$04
emit(0xB9, 0x00, 0xC1)       # LDA $C100,Y  -> $C104
emit(0x8D, 0x03, 0x04)       # STA $0403

# --- T4: (zp),Y read with $FB,$FC=$C100, Y=$05. $C105 = $05. Expect $0404 = $05 ---
emit(0xA0, 0x05)             # LDY #$05
emit(0xB1, PTR_FB)           # LDA ($FB),Y
emit(0x8D, 0x04, 0x04)       # STA $0404

# --- T5: zp,X read.  X=$03, ZP $03+X = $06. Expect $0405 = $06 ---
# Wait — we want to read ZP $03+X with X=3, so we're reading $06 which is $08.
# Better: X=0, read $03 -> $05. But we want $06 visible. Set X=1, read $03+1=$04 -> $06.
emit(0xA2, 0x01)             # LDX #$01
emit(0xB5, 0x03)             # LDA $03,X  -> ZP $04 = $06
emit(0x8D, 0x05, 0x04)       # STA $0405

# --- T6: abs,X with page cross. $C0FF + X=8 -> $C107 (in $C100 page). Expect $0406 = $07 ---
# $C107 should equal $07.
emit(0xA2, 0x08)             # LDX #$08
emit(0xBD, 0xFF, 0xC0)       # LDA $C0FF,X  -> $C107 (carries)
emit(0x8D, 0x06, 0x04)       # STA $0406

# --- T7: BCD ADC.  SED ; CLC ; LDA #$25 ; ADC #$48 ; CLD.  Expect $73 ---
emit(0xF8)                   # SED
emit(0x18)                   # CLC
emit(0xA9, 0x25)             # LDA #$25
emit(0x69, 0x48)             # ADC #$48
emit(0xD8)                   # CLD
emit(0x8D, 0x07, 0x04)       # STA $0407

# --- T8: BCD SBC.  SED ; SEC ; LDA #$50 ; SBC #$13 ; CLD.  Expect $37 ---
emit(0xF8)                   # SED
emit(0x38)                   # SEC
emit(0xA9, 0x50)             # LDA #$50
emit(0xE9, 0x13)             # SBC #$13
emit(0xD8)                   # CLD
emit(0x8D, 0x08, 0x04)       # STA $0408

# --- T9: INC abs.  Pre-store $09 at $0409, then INC $0409.  Expect $0A ---
emit(0xA9, 0x09)             # LDA #$09
emit(0x8D, 0x09, 0x04)       # STA $0409
emit(0xEE, 0x09, 0x04)       # INC $0409

# --- T10: ASL A.  LDA #$05 ; ASL A.  Expect $0B (0x05<<1 + carry-into-bit0? no, just shift = $0A. Hmm) ---
# We want exact byte $0B. Use #$05 -> ASL = $0A. Want $0B so: LDA #$05 then ASL then ORA #$01? Or simpler use LDA #$06 then ASL = $0C, no.
# Let me just adjust expectation. Store ASL of #$05 = $0A. But T9 already produced $0A.
# Use unique value. LDA #$0B ; ASL A = $16. No that's also unique but doesn't test ASL meaningfully.
# Just use a different test: ROL with carry clear.
# CLC ; LDA #$05 ; ROL A = $0A. Already same.
# Let me just do ASL of $05 and accept $0A. Use cell $040A; the byte distinguishes from cell $0409 by position.
emit(0x18)                   # CLC
emit(0xA9, 0x05)             # LDA #$05
emit(0x0A)                   # ASL A   -> $0A
emit(0x09, 0x01)             # ORA #$01 -> $0B
emit(0x8D, 0x0A, 0x04)       # STA $040A

# --- T11: ROR A with carry in.  SEC ; LDA #$02 ; ROR A.  Expect $81 ---
emit(0x38)                   # SEC
emit(0xA9, 0x02)             # LDA #$02
emit(0x6A)                   # ROR A
emit(0x8D, 0x0B, 0x04)       # STA $040B

# --- T12: PHA / PLA round-trip.  Expect $0D ---
emit(0xA9, 0x0D)             # LDA #$0D
emit(0x48)                   # PHA
emit(0xA9, 0xFF)             # LDA #$FF (clobber)
emit(0x68)                   # PLA
emit(0x8D, 0x0C, 0x04)       # STA $040C

# --- T13: JSR/RTS.  Expect $0E ---
emit(0x20, SUB_RTS & 0xFF, (SUB_RTS >> 8) & 0xFF)   # JSR $C200
emit(0x8D, 0x0D, 0x04)       # STA $040D

# --- T14: (zp,X) read.  Pointer table at $20.. ; X=$00 picks $20/$21 = $C108 -> $C108 = $0F.  Expect $0F ---
# Setup ZP $20,$21 = lo/hi of $C108
emit(0xA9, 0x08)             # LDA #$08
emit(0x85, 0x20)             # STA $20
emit(0xA9, 0xC1)             # LDA #$C1
emit(0x85, 0x21)             # STA $21
emit(0xA2, 0x00)             # LDX #$00
emit(0xA1, 0x20)             # LDA ($20,X)  -> *((u16*)$20) = $C108 -> $0F
emit(0x8D, 0x0E, 0x04)       # STA $040E

# --- T15: indirect JMP via $C200's target store.  Expect $10 ---
# Set $0E,$0F = lo/hi of JMP_TGT, then JMP ($00xx)? Actually we need a fixed indirection address.
# Use $0030 = $C210
emit(0xA9, JMP_TGT & 0xFF)   # LDA #lo
emit(0x85, 0x30)             # STA $30
emit(0xA9, (JMP_TGT >> 8) & 0xFF)  # LDA #hi
emit(0x85, 0x31)             # STA $31
emit(0x6C, 0x30, 0x00)       # JMP ($0030)  -> $C210

# At this point execution has jumped away. The remaining "halt" loop is at the end.

# Pad code to known offset by tracking position; we've emitted the runtime body.
# Length so far is len(code). The body ends with the indirect JMP, so what follows here
# is unreachable from the JMP path. We'll use the bytes after to host SUB_RTS at $C200
# and JMP_TGT at $C210, by padding.

# Compute current length
body_len = len(code)
print(f"; body_len = {body_len} bytes (ends at ${RUNTIME + body_len:04X})", file=sys.stderr)

# Pad to $C200 (SUB_RTS)
pad_to_c200 = (SUB_RTS - RUNTIME) - body_len
if pad_to_c200 < 0:
    raise RuntimeError(f"Code overran $C200: body ends at ${RUNTIME+body_len:04X}")
code.extend([0xEA] * pad_to_c200)        # NOP padding

# At $C200: subroutine for T13 — load $0E and RTS
sub_at = len(code)
emit(0xA9, 0x0E)             # LDA #$0E
emit(0x60)                   # RTS

# Pad to $C210 (JMP_TGT)
pad_to_c210 = (JMP_TGT - RUNTIME) - len(code)
code.extend([0xEA] * pad_to_c210)

# At $C210: indirect JMP target — store $10 to $040F, then halt
emit(0xA9, 0x10)             # LDA #$10
emit(0x8D, 0x0F, 0x04)       # STA $040F
# Halt loop
emit(0x4C, (JMP_TGT + 5) & 0xFF, ((JMP_TGT + 5) >> 8) & 0xFF)  # JMP self

# ---------- Pad to $D000 to be safe (won't go that far) ----------
# Now stitch in DATA_C100 region by patching.
# We've laid out [0..body_len] runtime, then pad-NOPs, then SUB at $C200, pad-NOPs, then JMP_TGT at $C210.
# But DATA_C100 = $C100 falls inside the NOP-pad region between body and $C200.
# Patch the table bytes at offset (DATA_C100 - RUNTIME) = $0100.
data_offset = DATA_C100 - RUNTIME
# Write DATA bytes
data = [0x00]*16
data[0] = 0x02      # T1: $C100
data[1] = 0x03      # T2: $C101
# data[2] = 0x00
# data[3] = 0x00
data[4] = 0x04      # T3: $C104
data[5] = 0x05      # T4: $C105
# data[6] = 0x00
data[7] = 0x07      # T6: $C107  (page-cross result)
data[8] = 0x0F      # T14: $C108 ((zp,X) result)
for i, v in enumerate(data):
    code[data_offset + i] = v

# ---------- BASIC stub at $0801: SYS 49152 ----------
# 0B 08 0A 00 9E "49152" 00 00 00 -> 13 bytes
basic_stub = bytes([
    0x0C, 0x08,   # next-line ptr = $080C
    0x0A, 0x00,   # line 10
    0x9E,         # SYS token
    0x34, 0x39, 0x31, 0x35, 0x32,   # "49152"
    0x00,         # end-of-line
    0x00, 0x00,   # end-of-program
])

# ---------- Build PRG file ----------
# PRG layout: 2-byte load addr + content from that addr.
# Load addr = $0801. Content = basic_stub (13 bytes from $0801..$080D),
# then NOP fill from $080E..$BFFF, then runtime code at $C000.
load_addr = 0x0801
gap_to_runtime = RUNTIME - (load_addr + len(basic_stub))
content = bytearray(basic_stub) + bytearray([0x00] * gap_to_runtime) + bytearray(code)

prg = bytes([load_addr & 0xFF, (load_addr >> 8) & 0xFF]) + bytes(content)

out = "tools/cpu_modes_test.prg"
with open(out, "wb") as f:
    f.write(prg)

print(f"; wrote {out} ({len(prg)} bytes total)", file=sys.stderr)
print(f"; runtime starts at $C000, ends near ${RUNTIME + len(code):04X}", file=sys.stderr)
print(f"; expected screen $0400..$040F = 01 02 03 04 05 06 07 73 37 0A 0B 81 0D 0E 0F 10", file=sys.stderr)
