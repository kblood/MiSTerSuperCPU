#!/usr/bin/env python3
"""Generate doom_minlaunch.prg — minimal SCPU launcher for Doom that mimics
the 254-byte loader.prg's pre-XCE setup more closely.

The loader does:
  SEI
  LDA #$35; STA $01      ; mask kernal/basic; all RAM at $A000-$FFFF
  STA $D07A              ; SCPU sw 1MHz mode (NOT turbo!)
  ... (REU FETCH stuff which doesn't matter for empty doom.reu directory)
  STA $D07B              ; turbo on (later, after FETCH loop)
  ... finally JMP/JML to Doom

We hypothesize that Doom's bank-$20 prologue assumes:
- $01 = $35 (RAM banked in)
- 1MHz mode (or that turbo is OK; unsure)
- IRQ disabled

Our launcher sets $01=$35, $D07A (1MHz), $D07E (SCPU enable). Doom's prologue
itself does CLC; XCE; REP #$30, sets up its own state. Then our launcher does
the JML. We do NOT set $D07B (let Doom decide turbo).
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'doom_minlaunch.prg')

basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

code = bytes([
    0x78,                         # SEI
    0xA9, 0x35,                   # LDA #$35
    0x85, 0x01,                   # STA $01     (RAM banked in)
    0x8D, 0x7E, 0xD0,             # STA $D07E   (SCPU hwenable + reg enable)
    0x8D, 0x7A, 0xD0,             # STA $D07A   (1MHz mode)
    0x8D, 0x7B, 0xD0,             # STA $D07B   (turbo on)
    # Border to indicate we got this far
    0xA9, 0x0B,                   # LDA #$0B (gray)
    0x8D, 0x20, 0xD0,             # STA $D020
    # Switch to native and JML to Doom
    0x18,                         # CLC
    0xFB,                         # XCE -> native
    0x5C, 0x00, 0x00, 0x20,       # JML $20:$0000
])

prg = bytes([0x01, 0x08]) + basic_stub + code
with open(OUT, 'wb') as f:
    f.write(prg)
print('wrote {} ({} bytes)'.format(OUT, len(prg)))
