#!/usr/bin/env python3
"""Test: POKE $DF1D to write via io_cycle, then LDA long to read back"""

# At $C000:
#   ; Write $AB to SDRAM bank $02:$0000 via io_cycle test register
#   ; (already done via POKE 57117,171 in BASIC before SYS)
#   ; Now LDA long $02:0000 — should return $AB (bt fix)
#   CLC           18
#   XCE           FB
#   SEP #$20      E2 20
#   LDA $020000   AF 00 00 02   ; LDA long bank $02:$0000
#   STA $00F2     85 F2
#   SEC           38
#   XCE           FB
#   RTS           60

code = [
    0x18,                   # CLC
    0xFB,                   # XCE
    0xE2, 0x20,             # SEP #$20
    0xAF, 0x00, 0x00, 0x02, # LDA long $020000
    0x85, 0xF2,             # STA $F2
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
        if len(line) + 1 + len(p) > 70:
            pokes.append(line)
            line = p
        else:
            line += ":" + p
    else:
        line = p
if line:
    pokes.append(line)

# First write $AB via io_cycle, then run test
print("POKE57117,171")  # $DF1D = write $AB to bank $02:$0000
for p in pokes:
    print(p)
print(f"SYS{base}")
print("PRINTPEEK(242)")
