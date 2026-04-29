"""Build memzap.prg: a small C64 program that fills $C000-$FFEF with $EA (NOP)
then JMPs to $0820 (asterix phase-1 entry).

Theory: Asterix's bench reaches $CB00 because bench's `mem` array is initialised
to (others => x"EA") so $C000-$FFFF is full of NOPs. If hardware's $C0xx
contains real garbage (e.g. $FF $XX $XX $XX $80 ... = SBC al,X + BRA loop),
then a wrong-turn to $C003 stalls forever.

memzap.prg fills the danger area with NOPs, then jumps to phase-1 entry. If
asterix now progresses past where it was getting stuck, the bug is
"bank $00 $C0xx contains executable garbage that's reachable via wrong jump".

Layout:
  $0801: BASIC stub: 10 SYS 2061
  $080D: real entry — ends with JMP $0820

Code at $080D:
  LDA #$EA           ; A=NOP opcode
  LDX #$00           ; low byte = 0
  STX $FB            ; ZP ptr lo
  LDX #$C0           ; high byte = $C0
  STX $FC            ; ZP ptr hi
  LDY #$00
loop_inner:
  STA ($FB),Y
  INY
  BNE loop_inner
  INC $FC
  LDX $FC
  CPX #$00           ; wrap to $00 means we filled through $FF
  BNE loop_inner
  JMP $0820          ; chain to asterix
"""
import struct

# Assemble manually
prog = bytearray()

# BASIC header at $0801: linked list with line "10 SYS 2061"
# Format: $0801 next_lo next_hi line_lo line_hi token<rest>0 next_lo=0 next_hi=0
# 2061 = $080D
basic = bytes([
    0x0B, 0x08,           # next-line ptr ($080B is wrong, needs to be $080B+ for end-of-program)
    0x0A, 0x00,           # line# 10
    0x9E,                 # SYS
    0x32, 0x30, 0x36, 0x31,  # "2061"
    0x00,                 # end of line
    0x00, 0x00            # end of program
])

prog += basic
assert len(prog) == 13, f"basic header len {len(prog)}"
# Now at offset 13 ($080D in C64 mem since $0801 + 12)

# Code at $080D
code = bytes([
    0xA9, 0xEA,           # LDA #$EA
    0xA2, 0x00,           # LDX #$00
    0x86, 0xFB,           # STX $FB  (ZP ptr lo = 0)
    0xA2, 0xC0,           # LDX #$C0
    0x86, 0xFC,           # STX $FC  (ZP ptr hi = $C0)
    0xA0, 0x00,           # LDY #$00
    # loop_inner at $0819
    0x91, 0xFB,           # STA ($FB),Y
    0xC8,                 # INY
    0xD0, 0xFB,           # BNE loop_inner (to $0819)
    0xE6, 0xFC,           # INC $FC
    0xA6, 0xFC,           # LDX $FC
    0xE0, 0x00,           # CPX #$00
    0xD0, 0xF5,           # BNE loop_inner (to $0819)
    0x4C, 0x20, 0x08,     # JMP $0820 (asterix phase-1 entry)
])

prog += code

# Prepend PRG load address $0801
out = bytes([0x01, 0x08]) + bytes(prog)

with open(r'C:\LLM\C64\MiSTerSuperCPU\memzap.prg', 'wb') as f:
    f.write(out)

print(f"Wrote memzap.prg: {len(out)} bytes (load $0801 - ${0x0801 + len(prog) - 1:04X})")
print(f"  BASIC stub: $0801-$080C  (10 SYS 2061)")
print(f"  Code:       $080D-${0x080D + len(code) - 1:04X}")
print(f"  Loop body:  $0819 (STA/INY/BNE)")
print(f"  Final JMP:  ${0x080D + len(code) - 3:04X} -> $0820")
