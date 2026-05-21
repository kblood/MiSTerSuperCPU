#!/usr/bin/env python3
"""Generate a BASIC program that POKEs a small REU FETCH test routine
into RAM and SYS-runs it. Output is a list of BASIC lines we can pipe
through mtype.py.

The routine:
  - Disables IRQs (SEI)
  - Sets $01 = $35 (no ROMs, I/O on)
  - Configures REU to FETCH 256 bytes from REU $020000 -> C64 $0400
  - Triggers FETCH ($DF01 = $91)
  - Delays
  - Sets border = green ($D020 = 5)
  - Halts (JMP $)
"""

# Code starting at $C000 (49152)
code_start = 0xC000
code = bytearray()

def emit(*bs):
    code.extend(bs)

# SEI; LDA #$35; STA $01
emit(0x78, 0xA9, 0x35, 0x85, 0x01)
# border purple ($04) — sentinel: routine started
emit(0xA9, 0x04, 0x8D, 0x20, 0xD0)
# Clear $0400-$04FF to $20 (space)
emit(0xA2, 0x00)              # LDX #$00
clr = code_start + len(code)
emit(0xA9, 0x20, 0x9D, 0x00, 0x04, 0xE8, 0xD0, 0xF8)  # LDA/STA/INX/BNE
# REU FETCH setup
emit(0xA9, 0x00, 0x8D, 0x02, 0xDF)  # C64 lo = 0
emit(0xA9, 0x04, 0x8D, 0x03, 0xDF)  # C64 hi = 4 -> $0400
emit(0xA9, 0x00, 0x8D, 0x04, 0xDF)  # REU lo
emit(0x8D, 0x05, 0xDF)              # REU mid (=0 from above)
emit(0xA9, 0x02, 0x8D, 0x06, 0xDF)  # REU hi -> $020000
emit(0xA9, 0x00, 0x8D, 0x07, 0xDF)  # length lo
emit(0xA9, 0x01, 0x8D, 0x08, 0xDF)  # length hi -> $0100
emit(0xA9, 0x91, 0x8D, 0x01, 0xDF)  # cmd = $91 (FETCH immediate)
# Delay ~64K iterations
emit(0xA0, 0xFF)
delay_y = code_start + len(code)
emit(0xA2, 0xFF)
delay_x = code_start + len(code)
emit(0xCA, 0xD0, 0xFD)              # DEX; BNE -3
emit(0x88, 0xD0, 0xF8)              # DEY; BNE -6
# border = green ($05) — sentinel: REU FETCH completed
emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)

# Verify multiple expected bytes from REU $020000:
#   $0400=$00, $0401=$01, $0410=$04, $0411=$05, $0420=$04, $0421=$06
# If all match -> bg green ($05). Otherwise -> bg red ($02) AND copy first 16
# bytes of $0400 into screen RAM at $0428 (line 1) so we can see what we got.
checks = [
    (0x00, 0x00),
    (0x01, 0x01),
    (0x10, 0x04),
    (0x11, 0x05),
    (0x20, 0x04),
    (0x21, 0x06),
]
fail_jumps = []
for offset, expected in checks:
    emit(0xAD, offset, 0x04)            # LDA $0400+offset
    emit(0xC9, expected)                # CMP #expected
    fail_jumps.append(len(code))
    emit(0xD0, 0x00)                    # BNE fail (patch)

# Success: bg green, halt
emit(0xA9, 0x05, 0x8D, 0x21, 0xD0)      # LDA #$05; STA $D021
success_halt = code_start + len(code)
emit(0x4C, success_halt & 0xFF, (success_halt >> 8) & 0xFF)

# Fail: bg red, copy first 16 bytes of $0400 to screen RAM at $0428 (line 1)
fail_addr = code_start + len(code)
emit(0xA9, 0x02, 0x8D, 0x21, 0xD0)      # LDA #$02; STA $D021
emit(0xA2, 0x00)                        # LDX #$00
copy16 = code_start + len(code)
emit(0xBD, 0x00, 0x04)                  # LDA $0400,X
emit(0x9D, 0x28, 0x04)                  # STA $0428,X (no hex conversion — visible as PETSCII glyphs)
emit(0xE8, 0xE0, 0x10, 0xD0, 0xF7)      # INX; CPX #$10; BNE -7
fail_halt = code_start + len(code)
emit(0x4C, fail_halt & 0xFF, (fail_halt >> 8) & 0xFF)

# Patch the fail-branches to jump to fail_addr
for j in fail_jumps:
    delta = (fail_addr - (code_start + j + 2)) & 0xFF
    code[j + 1] = delta
halt_addr = success_halt

print(f"Code size: {len(code)} bytes")
print(f"Code range: ${code_start:04X}..${code_start + len(code) - 1:04X}")
print(f"Halt addr:  ${halt_addr:04X}")

# Generate BASIC POKE program with chunked DATA lines (BASIC line max ~80 chars)
lines = ["10 FORI=0TO" + str(len(code) - 1) + ":READA:POKE" + str(code_start) + "+I,A:NEXT",
         "20 SYS" + str(code_start)]

# DATA lines starting at line 100
data_line_no = 100
i = 0
while i < len(code):
    chunk = []
    while i < len(code) and len(','.join(str(b) for b in chunk)) < 60:
        chunk.append(code[i])
        i += 1
    lines.append(f"{data_line_no} DATA{','.join(str(b) for b in chunk)}")
    data_line_no += 10

# Write to file
with open('reu_basic_test.txt', 'w') as f:
    for line in lines:
        f.write(line + '\n')
    print(f"\nGenerated {len(lines)} BASIC lines")
    print('\n'.join(lines))
