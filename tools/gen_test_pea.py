#!/usr/bin/env python3
"""Generate test_pea.prg — verify PEA $FE85 advances PC and pushes correctly.

Hypothesis: P65C816 has a bug with PEA (opcode $F4) under certain conditions
(maybe in 16-bit M mode at high turbo). Doom's bank-$20 prologue executes
PEA $FE85 at $6C03 and PC appears hard-locked there.

Test:
  - SCPU/turbo/native, REP #$30 (M=X=16)
  - Set up known SP
  - Issue PEA $FE85 (pushes $85 then $FE → S decrements by 2)
  - Verify SP decremented by 2 (in 16-bit native)
  - Verify $00:S+1 = $85, $00:S+2 = $FE (or appropriate stack location)
  - Border green if all match, else red.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'test_pea.prg')

basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

code = bytes([
    0x78,                            # SEI
    0x8D, 0x7E, 0xD0,                # STA $D07E
    0x8D, 0x7B, 0xD0,                # STA $D07B
    0xA9, 0x03, 0x8D, 0x20, 0xD0,    # border = cyan ($03)
    0x18, 0xFB,                      # CLC; XCE -> native
    0xC2, 0x30,                      # REP #$30 (M=X=16)
    # Known SP: SEP only saves SP when entering native; default native SP is $01FF.
    # Force SP=$0200 to give us room.
    0xA2, 0x00, 0x02,                # LDX #$0200
    0x9A,                            # TXS (transfer X to S; in native, 16-bit)
    # Now PEA $FE85
    0xF4, 0x85, 0xFE,                # PEA #$FE85
    # After PEA: SP should be $01FE (decremented by 2). Stack at $01FF=$FE, $01FE=$85.
    # Verify SP via TSX
    0xBA,                            # TSX (X = SP)
    0xE0, 0xFE, 0x01,                # CPX #$01FE
    0xD0, 0x14,                      # BNE +20 (red)
    # Verify $01FF and $01FE
    0xAF, 0xFF, 0x01, 0x00,          # LDA $00:$01FF (long, 16-bit M but reading byte... wait need SEP)
    # Actually 16-bit LDA reads 2 bytes at once. Let me SEP first.
    # Backtrack — change approach: SEP #$20 before reads.
    # Insert SEP here (use NOP padding to keep offsets, but easier to redo)
    # Hmm let me just read in 16-bit and check both halves
    0xC9, 0x85, 0xFE,                # CMP #$FE85 (16-bit imm — should match low at $01FE = $85, high at $01FF = $FE)
    0xD0, 0x09,                      # BNE +9 (red)
    # Pass: green
    0xE2, 0x20,                      # SEP #$20
    0xA9, 0x05, 0x8D, 0x20, 0xD0,    # border = green
    0x4C, 0x00, 0x00,                # JMP self (placeholder)
    # Red:
    0xE2, 0x20,                      # SEP #$20
    0xA9, 0x02, 0x8D, 0x20, 0xD0,    # border = red
    0x4C, 0x00, 0x00,                # JMP self (placeholder)
])

# Patch JMP placeholders
code_addr = 0x080D
code_arr = bytearray(code)
i = 0
while i < len(code_arr) - 2:
    if code_arr[i] == 0x4C and code_arr[i+1] == 0x00 and code_arr[i+2] == 0x00:
        target = code_addr + i
        code_arr[i+1] = target & 0xFF
        code_arr[i+2] = (target >> 8) & 0xFF
        i += 3
    else:
        i += 1
code = bytes(code_arr)

prg = bytes([0x01, 0x08]) + basic_stub + code
with open(OUT, 'wb') as f:
    f.write(prg)
print('wrote {} ({} bytes)'.format(OUT, len(prg)))
