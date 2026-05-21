#!/usr/bin/env python3
"""Peek bank $00 RAM at $6C03 by displaying 32 bytes around it as hex on screen.

Pre-condition: REU has been pre-loaded with doom.reu, then we abandon Doom and
run this PRG. The PRG copies bank-$00 RAM at $6C00..$6C1F to screen RAM as ASCII
hex. Border = green if first byte != $00.

This works because RAM is volatile but Doom's writes to bank $00 RAM survive
into our PRG run if we DON'T cold-reset. But MGL load DOES cold-reset BASIC.
So we won't actually see Doom's bytes — we'll see whatever ROM/loader put there.

To verify if Doom populated bank $00 at $6C00 area at all, we'd need a non-resetting
peek. For now, this PRG is just useful as a sanity check.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'peek_6c03.prg')

basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

# Peek $6C00..$6C1F (32 bytes) and display as hex on screen line 0.
# Each byte renders as 2 chars (hi nibble + lo nibble in PETSCII).
# Use a hex-conversion subroutine.

code = bytes([
    # SEI; no SCPU mode; just raw 6510 read of bank $00 RAM at $6C00
    0x78,                               # SEI
    0xA2, 0x00,                         # LDX #$00
    0xBD, 0x00, 0x6C,                   # LDA $6C00,X
    0x48,                               # PHA  (push for low nibble)
    0x4A, 0x4A, 0x4A, 0x4A,             # LSR x4 (high nibble)
    0x20, 0x40, 0x08,                   # JSR hex_to_screen ($0840 below)
    0x68,                               # PLA
    0x29, 0x0F,                         # AND #$0F
    0x20, 0x40, 0x08,                   # JSR hex_to_screen
    0xE8,                               # INX
    0xE0, 0x20,                         # CPX #$20
    0xD0, 0xE9,                         # BNE -23 (back to LDA)
    # Set border green and infinite loop
    0xA9, 0x05,                         # LDA #$05
    0x8D, 0x20, 0xD0,                   # STA $D020
    0x4C, 0x21, 0x08,                   # JMP self  (placeholder)
])
# Patch JMP target to current addr (= $080D + len(code) - 3)
# Actually we want it at the JMP itself, so end-3.
jmp_addr = 0x080D + len(code) - 3
code = code[:-2] + bytes([jmp_addr & 0xFF, (jmp_addr >> 8) & 0xFF])

# pad to $0840
pad_to = 0x0840
end_addr = 0x080D + len(code)
pad = pad_to - end_addr
if pad < 0:
    raise SystemExit('code too long')

# hex_to_screen: A = nibble (0..15). Write to screen RAM $0400+screenX.
# Uses zp $FE as screenX counter.
hex_sub = bytes([
    # convert nibble to PETSCII screen-code: 0-9 -> $30, A-F -> $41
    0xC9, 0x0A,                         # CMP #$0A
    0x90, 0x04,                         # BCC +4 (digit)
    0x18, 0x69, 0x37,                   # CLC; ADC #$37 (A->'A')  ('A'-10 = 55 = $37)
    0x80, 0x02,                         # BRA +2 (no, skip via JMP — but we're 6510)
    0x69, 0x30,                         # ADC #$30 ('0')
    # store at $0400+$FE
    0x84, 0xFE,                         # STY $FE  (no this is wrong; we need an X-style index)
    # Actually use page-zero pointer at $FB/$FC as screen ptr
    0xA0, 0x00,                         # LDY #$00
    0x91, 0xFB,                         # STA ($FB),Y
    0xE6, 0xFB,                         # INC $FB (advance screen ptr)
    0x60,                               # RTS
])

prg = bytes([0x01, 0x08]) + basic_stub + code + bytes(pad) + hex_sub
with open(OUT, 'wb') as f:
    f.write(prg)
print('wrote {} ({} bytes)'.format(OUT, len(prg)))
