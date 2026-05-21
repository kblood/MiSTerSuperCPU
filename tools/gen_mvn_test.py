#!/usr/bin/env python3
"""Minimal MVN test: copy 4 bytes from $5000 to $02:2000, verify via LDA long"""

# Setup: POKE $5000-$5003 with $DE,$AD,$BE,$EF from BASIC first
# At $C000:
#   CLC           18
#   XCE           FB       ; native mode
#   REP #$30      C2 30    ; 16-bit A,X,Y
#   LDX #$5000    A2 00 50 ; src in bank $00
#   LDY #$2000    A0 00 20 ; dst in bank $02
#   LDA #$0003    A9 03 00 ; 4 bytes - 1
#   MVN $02,$00   54 02 00 ; dst bank, src bank
#   SEP #$20      E2 20    ; 8-bit A
#   ; Read back 4 bytes from bank $02
#   LDA $022000   AF 00 20 02
#   STA $F0       85 F0
#   LDA $022001   AF 01 20 02
#   STA $F1       85 F1
#   LDA $022002   AF 02 20 02
#   STA $F2       85 F2
#   LDA $022003   AF 03 20 02
#   STA $F3       85 F3
#   SEC           38
#   XCE           FB
#   RTS           60

code = [
    0x18,                   # CLC
    0xFB,                   # XCE  
    0xC2, 0x30,             # REP #$30
    0xA2, 0x00, 0x50,       # LDX #$5000
    0xA0, 0x00, 0x20,       # LDY #$2000
    0xA9, 0x03, 0x00,       # LDA #$0003
    0x54, 0x02, 0x00,       # MVN $02,$00
    0xE2, 0x20,             # SEP #$20
    0xAF, 0x00, 0x20, 0x02, # LDA long $022000
    0x85, 0xF0,             # STA $F0
    0xAF, 0x01, 0x20, 0x02, # LDA long $022001
    0x85, 0xF1,             # STA $F1
    0xAF, 0x02, 0x20, 0x02, # LDA long $022002
    0x85, 0xF2,             # STA $F2
    0xAF, 0x03, 0x20, 0x02, # LDA long $022003
    0x85, 0xF3,             # STA $F3
    0x38,                   # SEC
    0xFB,                   # XCE
    0x60,                   # RTS
]

base = 0xC000
line = ""
pokes = []
for i, b in enumerate(code):
    p = f"POKE{base+i},{b}"
    if line:
        if len(line) + 1 + len(p) > 65:
            pokes.append(line)
            line = p
        else:
            line += ":" + p
    else:
        line = p
if line:
    pokes.append(line)

# Setup source data
print("POKE20480,222:POKE20481,173:POKE20482,190:POKE20483,239")
for p in pokes:
    print(p)
print(f"SYS{base}")
print("PRINT PEEK(240);PEEK(241);PEEK(242);PEEK(243)")
