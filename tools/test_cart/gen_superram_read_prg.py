#!/usr/bin/env python3
"""
SuperRAM Read Diagnostic PRG
==============================
Generates a PRG that reads SuperRAM addresses via 65816 LDA long ($AF)
and displays the values on screen.

Load via: python tools/mister_debug.py load_prg tools/test_cart/out/superram_read_diag.prg
Run via:  SYS 49152

Tests addresses around the Doom crash point ($20:20FC) and compares
with known doom.reu file contents.

Screen layout:
  Row 0: "SUPERRAM READ DIAG"
  Row 2+: BB:HHHH=XX [EX=YY OK/FAIL]

Border: GREEN=all pass, RED=any fail, YELLOW=running
"""

import os

BASIC_START = 0x0801
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

SCREEN = 0x0400
D020 = 0xD020
D021 = 0xD021

# Test addresses with expected values from doom.reu
TEST_ADDRESSES = [
    # (bank, addr, expected_byte, description)
    (0x20, 0x0000, 0x78, "SEI"),
    (0x20, 0x0001, 0xD8, "CLD"),
    (0x20, 0x0002, 0x18, "CLC"),
    (0x20, 0x0003, 0xFB, "XCE"),
    (0x20, 0x0004, 0xC2, "REP"),
    (0x20, 0x20F8, None, "20F8"),
    (0x20, 0x20F9, None, "20F9"),
    (0x20, 0x20FA, None, "20FA"),
    (0x20, 0x20FB, None, "20FB"),
    (0x20, 0x20FC, 0x85, "CRASH"),
    (0x20, 0x20FD, None, "20FD"),
    (0x20, 0x20FE, None, "20FE"),
    (0x20, 0x20FF, None, "20FF"),
    (0x20, 0x2100, None, "2100"),
    (0x02, 0x0000, None, "B02"),
    (0x01, 0x0000, None, "B01"),
]


def hex_char(n):
    """Return PETSCII screen code for hex digit 0-F."""
    if n < 10:
        return 0x30 + n
    else:
        return 0x01 + (n - 10)


def build_prg():
    code = bytearray()
    pc = BASIC_START

    def emit(*bs):
        nonlocal pc
        for b in bs:
            code.append(b & 0xFF)
            pc += 1

    # -- BASIC SYS stub: 10 SYS <code_start> --
    # We'll patch the SYS address after we know it
    # BASIC line: next_ptr(2), line_num(2), SYS_token(1), address_string, 0, end(2)
    code_start_placeholder = len(code) + 2 + 2 + 1  # offset of address string in code
    # next line pointer (will patch)
    emit(0x00, 0x00)        # placeholder for next line ptr
    emit(0x0A, 0x00)        # line number 10
    emit(0x9E)              # SYS token
    # Address string placeholder (5 digits + null + end)
    addr_str_offset = len(code)
    emit(0x30, 0x30, 0x30, 0x30, 0x30)  # "00000" placeholder
    emit(0x00)              # end of line
    # End of BASIC program
    next_line_ptr = pc
    emit(0x00, 0x00)        # end of program marker
    # Patch next line pointer
    code[0] = next_line_ptr & 0xFF
    code[1] = (next_line_ptr >> 8) & 0xFF

    # Machine code starts here
    code_start = pc
    # Patch the SYS address string
    addr_str = f"{code_start:05d}"
    for i, ch in enumerate(addr_str):
        code[addr_str_offset + i] = ord(ch)

    # -- Init --
    emit(0x78)              # SEI
    emit(0xD8)              # CLD

    # Yellow border = running
    emit(0xA9, 0x07, 0x8D, 0x20, 0xD0)  # LDA #7; STA $D020
    emit(0xA9, 0x00, 0x8D, 0x21, 0xD0)  # LDA #0; STA $D021

    # Clear screen
    emit(0xA9, 0x20)        # LDA #$20 (space)
    emit(0xA2, 0x00)        # LDX #0
    clear_loop = pc
    emit(0x9D, 0x00, 0x04)  # STA $0400,X
    emit(0x9D, 0x00, 0x05)  # STA $0500,X
    emit(0x9D, 0x00, 0x06)  # STA $0600,X
    emit(0x9D, 0x00, 0x07)  # STA $0700,X
    emit(0xE8)              # INX
    emit(0xD0, (clear_loop - (pc + 2)) & 0xFF)  # BNE clear_loop

    # Title: "SUPERRAM READ DIAG" at row 0
    title = "SUPERRAM READ DIAG"
    for i, ch in enumerate(title):
        sc = ord(ch) - 0x40 if ch.isalpha() else ord(ch)
        emit(0xA9, sc)
        emit(0x8D, (SCREEN + i) & 0xFF, ((SCREEN + i) >> 8) & 0xFF)

    # Enter native mode for LDA long
    emit(0x18)        # CLC
    emit(0xFB)        # XCE — native mode
    emit(0xE2, 0x30)  # SEP #$30 — 8-bit A/X/Y

    # Enable turbo ($D07B)
    emit(0x8D, 0x7B, 0xD0)  # STA $D07B

    # Fail counter in ZP $10
    emit(0xA9, 0x00, 0x85, 0x10)  # LDA #0; STA $10

    # -- Read each test address --
    row = 2
    for idx, (bank, addr, expected, desc) in enumerate(TEST_ADDRESSES):
        screen_pos = SCREEN + row * 40

        # Display "BB:HHHH=" prefix
        emit(0xA9, hex_char((bank >> 4) & 0xF))
        emit(0x8D, screen_pos & 0xFF, (screen_pos >> 8) & 0xFF)
        emit(0xA9, hex_char(bank & 0xF))
        emit(0x8D, (screen_pos+1) & 0xFF, ((screen_pos+1) >> 8) & 0xFF)
        emit(0xA9, 0x3A)
        emit(0x8D, (screen_pos+2) & 0xFF, ((screen_pos+2) >> 8) & 0xFF)
        emit(0xA9, hex_char((addr >> 12) & 0xF))
        emit(0x8D, (screen_pos+3) & 0xFF, ((screen_pos+3) >> 8) & 0xFF)
        emit(0xA9, hex_char((addr >> 8) & 0xF))
        emit(0x8D, (screen_pos+4) & 0xFF, ((screen_pos+4) >> 8) & 0xFF)
        emit(0xA9, hex_char((addr >> 4) & 0xF))
        emit(0x8D, (screen_pos+5) & 0xFF, ((screen_pos+5) >> 8) & 0xFF)
        emit(0xA9, hex_char(addr & 0xF))
        emit(0x8D, (screen_pos+6) & 0xFF, ((screen_pos+6) >> 8) & 0xFF)
        emit(0xA9, 0x3D)
        emit(0x8D, (screen_pos+7) & 0xFF, ((screen_pos+7) >> 8) & 0xFF)

        # LDA long bank:addr (opcode $AF)
        emit(0xAF, addr & 0xFF, (addr >> 8) & 0xFF, bank)

        # Display read value as hex at pos+8,+9
        emit(0x48)  # PHA
        emit(0x4A, 0x4A, 0x4A, 0x4A)  # LSR x4 (high nibble)
        emit(0xC9, 0x0A)  # CMP #$0A
        bcc1 = pc; emit(0x90, 0x00)
        emit(0x69, 0x06)  # ADC #6
        code[bcc1 - BASIC_START + 1] = (pc - bcc1 - 2) & 0xFF
        emit(0x09, 0x30)  # ORA #$30
        emit(0x8D, (screen_pos+8) & 0xFF, ((screen_pos+8) >> 8) & 0xFF)
        emit(0x68)  # PLA
        emit(0x29, 0x0F)  # AND #$0F
        emit(0xC9, 0x0A)
        bcc2 = pc; emit(0x90, 0x00)
        emit(0x69, 0x06)
        code[bcc2 - BASIC_START + 1] = (pc - bcc2 - 2) & 0xFF
        emit(0x09, 0x30)
        emit(0x8D, (screen_pos+9) & 0xFF, ((screen_pos+9) >> 8) & 0xFF)

        if expected is not None:
            emit(0xAF, addr & 0xFF, (addr >> 8) & 0xFF, bank)
            emit(0xC9, expected)
            beq = pc; emit(0xF0, 0x00)
            # FAIL
            emit(0xA9, 0x06)  # 'F'
            emit(0x8D, (screen_pos+11) & 0xFF, ((screen_pos+11) >> 8) & 0xFF)
            emit(0xE6, 0x10)  # INC $10
            jmp_skip = pc; emit(0x4C, 0x00, 0x00)
            # OK
            code[beq - BASIC_START + 1] = (pc - beq - 2) & 0xFF
            emit(0xA9, 0x0F)  # 'O'
            emit(0x8D, (screen_pos+11) & 0xFF, ((screen_pos+11) >> 8) & 0xFF)
            emit(0xA9, 0x0B)  # 'K'
            emit(0x8D, (screen_pos+12) & 0xFF, ((screen_pos+12) >> 8) & 0xFF)
            # Patch JMP
            skip_addr = pc
            code[jmp_skip - BASIC_START + 1] = skip_addr & 0xFF
            code[jmp_skip - BASIC_START + 2] = (skip_addr >> 8) & 0xFF

            # Show expected value
            emit(0xA9, hex_char((expected >> 4) & 0xF))
            emit(0x8D, (screen_pos+14) & 0xFF, ((screen_pos+14) >> 8) & 0xFF)
            emit(0xA9, hex_char(expected & 0xF))
            emit(0x8D, (screen_pos+15) & 0xFF, ((screen_pos+15) >> 8) & 0xFF)

        row += 1

    # -- Result --
    emit(0xA5, 0x10)  # LDA $10
    beq_pass = pc; emit(0xF0, 0x00)
    emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)  # Red border
    jmp_halt = pc; emit(0x4C, 0x00, 0x00)
    code[beq_pass - BASIC_START + 1] = (pc - beq_pass - 2) & 0xFF
    emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)  # Green border
    halt = pc
    code[jmp_halt - BASIC_START + 1] = halt & 0xFF
    code[jmp_halt - BASIC_START + 2] = (halt >> 8) & 0xFF
    emit(0x4C, halt & 0xFF, (halt >> 8) & 0xFF)  # JMP halt

    print(f"Code size: {len(code)} bytes, ML starts at ${code_start:04X}")

    # PRG = 2-byte load address + code
    prg = bytearray(2)
    prg[0] = BASIC_START & 0xFF
    prg[1] = (BASIC_START >> 8) & 0xFF
    prg.extend(code)
    return bytes(prg)


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    prg = build_prg()
    prg_path = os.path.join(OUT_DIR, "superram_read_diag.prg")
    with open(prg_path, 'wb') as f:
        f.write(prg)
    print(f"Generated {prg_path} ({len(prg)} bytes)")
    print(f"Load & auto-run: python tools/mister_debug.py load_prg {prg_path}")
    print(f"  (auto-runs via BASIC SYS stub, no keyboard needed)")
