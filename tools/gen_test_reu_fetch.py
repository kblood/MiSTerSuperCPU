#!/usr/bin/env python3
"""Generate test_reu_fetch.prg — verify REU FETCH from bank $2A:$6C00.

This is the EXACT path Doom uses to populate c64 bank $00:$6C00 with code:
  REU FETCH 16 bytes from REU bank $2A addr $6C00 to c64 $6C00.

Expected after FETCH: c64 $6C00..$6C0F = 3e 00 b7 f4 85 fe a0 38 00 b7 f4 85 cc a0 3a 00.

We display the first 16 bytes as PETSCII hex characters at the top of screen
and set border GREEN ($05) if all 16 match expected. RED ($02) otherwise.

This requires REU SDRAM to be pre-populated with doom.reu via MGL.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'test_reu_fetch.prg')

EXPECTED = bytes.fromhex('3e00b7f485fea03800b7f485cca03a00')  # 16 bytes

basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

# Build a constants block at $0900: 16-byte EXPECTED pattern
# We embed it via PAD and a separate copy in the PRG.

code = bytes([
    0x78,                         # SEI
    0xD8,                         # CLD
    0x8D, 0x7E, 0xD0,             # STA $D07E (SCPU enable)
    0x8D, 0x7B, 0xD0,             # STA $D07B (turbo)

    # Border = cyan to mark phase 1 entry
    0xA9, 0x03,
    0x8D, 0x20, 0xD0,

    # === Setup REU registers for FETCH ===
    # $DF0A = $00 (autoload mode, both addrs increment)
    0xA9, 0x00, 0x8D, 0x0A, 0xDF,
    # c64 base = $6C00
    0xA9, 0x00, 0x8D, 0x02, 0xDF,    # $DF02 = $00
    0xA9, 0x6C, 0x8D, 0x03, 0xDF,    # $DF03 = $6C
    # REU base = $2A:$6C00
    0xA9, 0x00, 0x8D, 0x04, 0xDF,    # $DF04 = $00 (REU lo)
    0xA9, 0x6C, 0x8D, 0x05, 0xDF,    # $DF05 = $6C (REU mid)
    0xA9, 0x2A, 0x8D, 0x06, 0xDF,    # $DF06 = $2A (REU hi/bank)
    # length = $0010
    0xA9, 0x10, 0x8D, 0x07, 0xDF,    # $DF07 = $10
    0xA9, 0x00, 0x8D, 0x08, 0xDF,    # $DF08 = $00
    # FETCH command
    0xA9, 0x91, 0x8D, 0x01, 0xDF,    # $DF01 = $91 (FETCH immediate type 1)

    # === Compare $6C00..$6C0F to expected at $0900 ===
    0xA2, 0x00,                      # LDX #$00
    # cmp loop:
    0xBD, 0x00, 0x6C,                # LDA $6C00,X (read from c64 RAM)
    0xDD, 0x00, 0x09,                # CMP $0900,X (compare to expected)
    0xD0, 0x0E,                      # BNE +14 (fail)
    0xE8,                            # INX
    0xE0, 0x10,                      # CPX #$10
    0xD0, 0xF3,                      # BNE -13 (back to LDA)
    # All 16 match: green
    0xA9, 0x05, 0x8D, 0x20, 0xD0,    # LDA #$05; STA $D020
    0x4C, 0x00, 0x00,                # JMP self (placeholder, patched)
    # Fail path: red + display first mismatch byte on screen
    0xA9, 0x02, 0x8D, 0x20, 0xD0,    # LDA #$02; STA $D020
    # Save mismatch byte to screen RAM for visual debug
    0xBD, 0x00, 0x6C,                # LDA $6C00,X (re-read)
    0x8D, 0x00, 0x04,                # STA $0400 (top-left)
    # store X to $0401 (which byte mismatched)
    0x8A,                            # TXA
    0x8D, 0x01, 0x04,                # STA $0401
    # store expected to $0402
    0xBD, 0x00, 0x09,                # LDA $0900,X
    0x8D, 0x02, 0x04,                # STA $0402
    0x4C, 0x00, 0x00,                # JMP self (placeholder)
])

# Patch both JMP placeholders to point to themselves
code_addr = 0x080D
# First JMP at offset where success path ends (3-byte JMP)
# Find both 4C 00 00 sequences
def find_all(data, pat):
    idxs = []
    i = 0
    while True:
        idx = data.find(pat, i)
        if idx < 0:
            break
        idxs.append(idx)
        i = idx + 1
    return idxs

jmp_idxs = find_all(code, bytes([0x4C, 0x00, 0x00]))
print('JMP placeholders at code offsets:', jmp_idxs)
# Patch each in place
code_arr = bytearray(code)
for idx in jmp_idxs:
    target = code_addr + idx
    code_arr[idx + 1] = target & 0xFF
    code_arr[idx + 2] = (target >> 8) & 0xFF
code = bytes(code_arr)

PAD_TO = 0x0900
end = code_addr + len(code)
pad = PAD_TO - end
if pad < 0:
    raise SystemExit('code too long')

prg = bytes([0x01, 0x08]) + basic_stub + code + bytes(pad) + EXPECTED
with open(OUT, 'wb') as f:
    f.write(prg)
print('code size={}, ends at ${:04X}, pad {} -> ${:04X}'.format(
    len(code), end, pad, PAD_TO))
print('wrote {} ({} bytes)'.format(OUT, len(prg)))
