#!/usr/bin/env python3
"""Build a small PRG that does a single REU FETCH and visualizes the result.

The PRG sets up a REU FETCH from REU $020000 (doom.reu bank $02 page $00) to
C64 $0400, length $0100. Then waits and renders the destination bytes as hex
in screen RAM, with border colors indicating success/failure.

Expected first 16 bytes at REU $020000 (verified from doom.reu):
    00 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01

Visual feedback:
- Border light blue + bg dark grey while waiting/setting up
- Border GREEN + first 16 bytes as hex pairs at top of screen on completion
- Border RED on early branch failure (currently unused — we always render)

Output: reu_fetch_test.prg (loadable via mbc load_rom)
"""

LOAD_ADDR = 0x0801

# BASIC stub: 10 SYS 2061
basic_stub = bytes([
    0x0B, 0x08,             # next line ptr
    0x0A, 0x00,             # line 10
    0x9E,                   # SYS
    0x32, 0x30, 0x36, 0x31, # "2061"
    0x00, 0x00, 0x00,       # end
])

CODE_START = LOAD_ADDR + len(basic_stub)  # = $080D

code = bytearray()
labels = {}

def org():
    return CODE_START + len(code)

def emit(*bs):
    code.extend(bs)

def label(name):
    labels[name] = org()

def patch16(offset, target):
    code[offset]   = target & 0xFF
    code[offset+1] = (target >> 8) & 0xFF

# --- entry ---
emit(0x78)                              # SEI
emit(0xA9, 0x35, 0x85, 0x01)            # LDA #$35; STA $01
emit(0xA9, 0x0E, 0x8D, 0x20, 0xD0)      # border light blue
emit(0xA9, 0x0B, 0x8D, 0x21, 0xD0)      # bg dark grey

# Clear $0400-$04FF to spaces ($20)
emit(0xA2, 0x00)                        # LDX #$00
clear_at = org()
emit(0xA9, 0x20, 0x9D, 0x00, 0x04)      # LDA #$20; STA $0400,X
emit(0xE8, 0xD0, 0xF8)                  # INX; BNE clear

# REU FETCH setup: C64 $0400, REU $020000, len $0100
emit(0xA9, 0x00, 0x8D, 0x02, 0xDF)      # STA $DF02
emit(0xA9, 0x04, 0x8D, 0x03, 0xDF)      # STA $DF03  -> C64 $0400
emit(0xA9, 0x00, 0x8D, 0x04, 0xDF)      # STA $DF04
emit(0x8D, 0x05, 0xDF)                  # STA $DF05
emit(0xA9, 0x02, 0x8D, 0x06, 0xDF)      # STA $DF06  -> REU $020000
emit(0xA9, 0x00, 0x8D, 0x07, 0xDF)      # STA $DF07
emit(0xA9, 0x01, 0x8D, 0x08, 0xDF)      # STA $DF08  -> length $0100
emit(0xA9, 0x91, 0x8D, 0x01, 0xDF)      # STA $DF01  -> FETCH cmd

# Delay: ~64K iterations
emit(0xA0, 0xFF)                        # LDY #$FF
delay_y = org()
emit(0xA2, 0xFF)                        # LDX #$FF
delay_x = org()
emit(0xCA, 0xD0, 0xFD)                  # DEX; BNE delay_x
emit(0x88, 0xD0, 0xF8)                  # DEY; BNE delay_y

# Border = green to show we got past the delay
emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)      # LDA #$05; STA $D020

# Dump first 16 bytes from $0400 to screen at $0428 (line 1)
# Each byte = 2 hex chars + space (3 cols), 16 bytes = 48 cols
emit(0xA2, 0x00)                        # LDX #$00 (byte index)
emit(0xA0, 0x00)                        # LDY #$00 (screen offset)
dump_loop_at = org()
emit(0xBD, 0x00, 0x04)                  # LDA $0400,X
emit(0x48)                              # PHA
# High nibble
emit(0x4A, 0x4A, 0x4A, 0x4A)            # LSR A x4
jsr_hi = len(code)
emit(0x20, 0x00, 0x00)                  # JSR to_hex (patch later)
emit(0x99, 0x28, 0x04)                  # STA $0428,Y
emit(0xC8)                              # INY
# Low nibble
emit(0x68)                              # PLA
emit(0x29, 0x0F)                        # AND #$0F
jsr_lo = len(code)
emit(0x20, 0x00, 0x00)                  # JSR to_hex (patch later)
emit(0x99, 0x28, 0x04)                  # STA $0428,Y
emit(0xC8, 0xC8)                        # INY (twice; column gap)
emit(0xE8)                              # INX
emit(0xE0, 0x10)                        # CPX #$10
# BNE dump_loop_at
back_offset = (dump_loop_at - (org() + 2)) & 0xFF
emit(0xD0, back_offset)

# Halt loop
halt_at = org()
emit(0x4C, halt_at & 0xFF, (halt_at >> 8) & 0xFF)

# to_hex: A = nibble (0..15), returns A = screen code
to_hex_at = org()
emit(0xC9, 0x0A)                        # CMP #$0A
emit(0x90, 0x04)                        # BCC +4 -> digit
# A-F: A - 9, returns $01-$06 (screen codes for A-F)
emit(0x38, 0xE9, 0x09, 0x60)            # SEC; SBC #$09; RTS
# digit: A + $30
emit(0x69, 0x30, 0x60)                  # ADC #$30; RTS  (carry=0 from CMP)

# Patch JSRs
patch16(jsr_hi + 1, to_hex_at)
patch16(jsr_lo + 1, to_hex_at)

# Build PRG
prg = bytes([LOAD_ADDR & 0xFF, (LOAD_ADDR >> 8) & 0xFF]) + basic_stub + bytes(code)

with open('reu_fetch_test.prg', 'wb') as f:
    f.write(prg)

print(f"Wrote reu_fetch_test.prg ({len(prg)} bytes)")
print(f"  Load addr: ${LOAD_ADDR:04X}")
print(f"  Code start: ${CODE_START:04X} (SYS {CODE_START})")
print(f"  Code size:  {len(code)} bytes")
print(f"  to_hex:     ${to_hex_at:04X}")
print(f"  halt:       ${halt_at:04X}")
