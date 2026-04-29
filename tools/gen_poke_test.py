#!/usr/bin/env python3
"""Generate BASIC POKE lines for a minimal MVN/LDA long test at $C000"""

# Test program at $C000:
# First: STA long $42 to $02:2000 (write test pattern)
# Then: LDA long $02:2000 (read it back)
# Store result at $0400 (screen)
# 
# Sequence:
#   CLC           18
#   XCE           FB
#   SEP #$20      E2 20    ; 8-bit A
#   LDA #$42      A9 42    ; test value
#   STA $022000   8F 00 20 02  ; STA long to bank $02
#   LDA #$00      A9 00    ; clear A  
#   LDA $022000   AF 00 20 02  ; LDA long from bank $02
#   STA $00F2     85 F2    ; store result in ZP
#   SEC           38
#   XCE           FB
#   LDA $F2       A5 F2    ; get result back in emulation mode
#   STA $0400     8D 00 04 ; show on screen
#   RTS           60

code = [
    0x18,                   # CLC
    0xFB,                   # XCE
    0xE2, 0x20,             # SEP #$20
    0xA9, 0x42,             # LDA #$42
    0x8F, 0x00, 0x20, 0x02, # STA long $022000
    0xA9, 0x00,             # LDA #$00
    0xAF, 0x00, 0x20, 0x02, # LDA long $022000
    0x85, 0xF2,             # STA $F2
    0x38,                   # SEC
    0xFB,                   # XCE
    0xA5, 0xF2,             # LDA $F2
    0x8D, 0x00, 0x04,       # STA $0400
    0x60,                   # RTS
]

base = 0xC000
# Generate POKE commands, max ~70 chars per line for C64
line = ""
pokes = []
for i, b in enumerate(code):
    p = f"POKE{base+i},{b}"
    if line:
        if len(line) + 1 + len(p) > 70:
            pokes.append(line)
            line = p
        else:
            line += ":" + p
    else:
        line = p
if line:
    pokes.append(line)

for p in pokes:
    print(p)
print(f"SYS{base}")
