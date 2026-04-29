#!/usr/bin/env python3
"""
SuperRAM Read Diagnostic CRT
==============================
Reads specific addresses from SuperRAM (loaded via REU/ioctl) using
65816 LDA long ($AF) and displays the values on screen.

Tests addresses around the Doom crash point ($20:20FC) and compares
with known doom.reu file contents.

Screen layout:
  Row 0: "SUPERRAM READ DIAG"
  Row 2+: BB:HHHH=XX [EX=YY OK/FAIL]

Border: GREEN=all pass, RED=any fail, YELLOW=running

Uses Ultimax mode (ROMH at $E000) — hardware vectors point directly
to code, no CBM80/KERNAL dependency.
"""

import struct
import os

ROM_SIZE = 0x2000   # 8 KB
ROM_BASE = 0xE000   # Ultimax ROMH
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
CRT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "..", "crt")

SCREEN = 0x0400
D020 = 0xD020
D021 = 0xD021

# Addresses to test with expected values from doom.reu
TEST_ADDRESSES = [
    # (bank, addr, expected_byte, description)
    # Early init (known to work from UART traces)
    (0x20, 0x0000, 0x78, "SEI"),
    (0x20, 0x0001, 0xD8, "CLD"),
    (0x20, 0x0002, 0x18, "CLC"),
    (0x20, 0x0003, 0xFB, "XCE"),
    (0x20, 0x0004, 0xC2, "REP"),
    # Crash point area
    (0x20, 0x20F8, None, "20F8"),
    (0x20, 0x20F9, None, "20F9"),
    (0x20, 0x20FA, None, "20FA"),
    (0x20, 0x20FB, None, "20FB"),
    (0x20, 0x20FC, 0x85, "CRASH"),     # THE crash point (should be STA dp = $85)
    (0x20, 0x20FD, None, "20FD"),
    (0x20, 0x20FE, None, "20FE"),
    (0x20, 0x20FF, None, "20FF"),
    (0x20, 0x2100, None, "2100"),
    # Other banks
    (0x02, 0x0000, None, "B02"),
    (0x01, 0x0000, None, "B01"),
]


def hex_char(n):
    """Return PETSCII screen code for hex digit 0-F."""
    if n < 10:
        return 0x30 + n  # '0'-'9'
    else:
        return 0x01 + (n - 10)  # 'A'-'F' in screen codes


def build_rom():
    rom = bytearray(ROM_SIZE)
    pc = 0  # offset into rom

    def emit(*bs):
        nonlocal pc
        for b in bs:
            rom[pc] = b & 0xFF
            pc += 1

    # -- Init --
    emit(0x78)              # SEI
    emit(0xA2, 0xFF, 0x9A)  # LDX #$FF; TXS
    emit(0xD8)              # CLD

    # Processor port (RAM visible)
    emit(0xA9, 0x2F, 0x85, 0x00)  # LDA #$2F; STA $00
    emit(0xA9, 0x35, 0x85, 0x01)  # LDA #$35; STA $01 (I/O + RAM)

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
    emit(0x8D, 0x7B, 0xD0)  # STA $D07B (value doesn't matter)

    # Use ZP $10 as fail counter
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
        emit(0xA9, 0x3A)  # ':'
        emit(0x8D, (screen_pos+2) & 0xFF, ((screen_pos+2) >> 8) & 0xFF)
        emit(0xA9, hex_char((addr >> 12) & 0xF))
        emit(0x8D, (screen_pos+3) & 0xFF, ((screen_pos+3) >> 8) & 0xFF)
        emit(0xA9, hex_char((addr >> 8) & 0xF))
        emit(0x8D, (screen_pos+4) & 0xFF, ((screen_pos+4) >> 8) & 0xFF)
        emit(0xA9, hex_char((addr >> 4) & 0xF))
        emit(0x8D, (screen_pos+5) & 0xFF, ((screen_pos+5) >> 8) & 0xFF)
        emit(0xA9, hex_char(addr & 0xF))
        emit(0x8D, (screen_pos+6) & 0xFF, ((screen_pos+6) >> 8) & 0xFF)
        emit(0xA9, 0x3D)  # '='
        emit(0x8D, (screen_pos+7) & 0xFF, ((screen_pos+7) >> 8) & 0xFF)

        # LDA long bank:addr (opcode $AF)
        emit(0xAF, addr & 0xFF, (addr >> 8) & 0xFF, bank)

        # Display read value as hex at pos+8,+9
        emit(0x48)  # PHA
        emit(0x4A, 0x4A, 0x4A, 0x4A)  # LSR x4 (high nibble)
        # Convert to hex screen code
        emit(0xC9, 0x0A)  # CMP #$0A
        bcc1 = pc; emit(0x90, 0x00)  # BCC +2 (is digit)
        emit(0x69, 0x06)  # ADC #6 (A-F: skip from '9' to 'A')
        rom[bcc1 + 1] = (pc - bcc1 - 2) & 0xFF
        emit(0x09, 0x30)  # ORA #$30
        emit(0x8D, (screen_pos+8) & 0xFF, ((screen_pos+8) >> 8) & 0xFF)
        emit(0x68)  # PLA
        emit(0x29, 0x0F)  # AND #$0F (low nibble)
        emit(0xC9, 0x0A)
        bcc2 = pc; emit(0x90, 0x00)
        emit(0x69, 0x06)
        rom[bcc2 + 1] = (pc - bcc2 - 2) & 0xFF
        emit(0x09, 0x30)
        emit(0x8D, (screen_pos+9) & 0xFF, ((screen_pos+9) >> 8) & 0xFF)

        # If we have an expected value, compare and show OK/FAIL
        if expected is not None:
            # Re-read the value
            emit(0xAF, addr & 0xFF, (addr >> 8) & 0xFF, bank)
            emit(0xC9, expected)  # CMP #expected
            beq = pc; emit(0xF0, 0x00)  # BEQ ok
            # FAIL
            emit(0xA9, 0x06)  # 'F'
            emit(0x8D, (screen_pos+11) & 0xFF, ((screen_pos+11) >> 8) & 0xFF)
            emit(0xE6, 0x10)  # INC $10 (fail counter)
            jmp_skip = pc; emit(0x4C, 0x00, 0x00)  # JMP skip (placeholder)
            # OK
            rom[beq + 1] = (pc - beq - 2) & 0xFF
            emit(0xA9, 0x0F)  # 'O'
            emit(0x8D, (screen_pos+11) & 0xFF, ((screen_pos+11) >> 8) & 0xFF)
            emit(0xA9, 0x0B)  # 'K'
            emit(0x8D, (screen_pos+12) & 0xFF, ((screen_pos+12) >> 8) & 0xFF)
            # Patch JMP
            skip_addr = ROM_BASE + pc
            rom[jmp_skip + 1] = skip_addr & 0xFF
            rom[jmp_skip + 2] = (skip_addr >> 8) & 0xFF

            # Show expected value
            emit(0xA9, hex_char((expected >> 4) & 0xF))
            emit(0x8D, (screen_pos+14) & 0xFF, ((screen_pos+14) >> 8) & 0xFF)
            emit(0xA9, hex_char(expected & 0xF))
            emit(0x8D, (screen_pos+15) & 0xFF, ((screen_pos+15) >> 8) & 0xFF)

        row += 1

    # -- Result: check fail counter --
    emit(0xA5, 0x10)  # LDA $10 (fail count)
    beq_pass = pc; emit(0xF0, 0x00)  # BEQ all_pass
    # Some failed — red border
    emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)
    jmp_halt = pc; emit(0x4C, 0x00, 0x00)
    # All pass — green border
    rom[beq_pass + 1] = (pc - beq_pass - 2) & 0xFF
    emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)
    # Halt
    halt = pc
    rom[jmp_halt + 1] = (ROM_BASE + halt) & 0xFF
    rom[jmp_halt + 2] = ((ROM_BASE + halt) >> 8) & 0xFF
    emit(0x4C, (ROM_BASE + halt) & 0xFF, ((ROM_BASE + halt) >> 8) & 0xFF)

    # -- Hardware vectors at $FFFA-$FFFF (end of 8K ROM) --
    entry = ROM_BASE  # $E000 = start of code
    rom[0x1FFA] = entry & 0xFF        # NMI
    rom[0x1FFB] = (entry >> 8) & 0xFF
    rom[0x1FFC] = entry & 0xFF        # RESET
    rom[0x1FFD] = (entry >> 8) & 0xFF
    rom[0x1FFE] = entry & 0xFF        # IRQ
    rom[0x1FFF] = (entry >> 8) & 0xFF

    print(f"Code size: {pc} bytes of {ROM_SIZE}")
    return bytes(rom)


def make_crt(rom_data, name="SuperRAM Read Diag"):
    """Wrap ROM in CRT format (Ultimax — ROMH at $E000)."""
    assert len(rom_data) == ROM_SIZE

    # CRT header (64 bytes)
    sig      = b"C64 CARTRIDGE   "
    hdr_len  = struct.pack(">I", 64)
    version  = struct.pack(">H", 0x0100)
    hw_type  = struct.pack(">H", 0)       # type 0 = normal
    exrom    = b"\x01"                     # EXROM=1 (inactive)
    game     = b"\x00"                     # GAME=0 (active) → Ultimax mode
    reserved = b"\x00" * 6
    crt_name = name.encode("ascii")[:32].ljust(32, b"\x00")
    header = sig + hdr_len + version + hw_type + exrom + game + reserved + crt_name
    assert len(header) == 64

    # CHIP packet (16-byte header + ROM data)
    chip_sig  = b"CHIP"
    pkt_len   = struct.pack(">I", 16 + ROM_SIZE)
    chip_type = struct.pack(">H", 0)       # ROM
    bank      = struct.pack(">H", 0)
    load_addr = struct.pack(">H", ROM_BASE)
    chip_size = struct.pack(">H", ROM_SIZE)
    chip = chip_sig + pkt_len + chip_type + bank + load_addr + chip_size

    return header + chip + rom_data


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(CRT_DIR, exist_ok=True)

    rom = build_rom()
    crt = make_crt(rom)

    crt_path = os.path.join(CRT_DIR, "superram_read_diag.crt")
    with open(crt_path, 'wb') as f:
        f.write(crt)
    print(f"Generated {crt_path} ({len(crt)} bytes)")

    # Also write to out/ for reference
    out_path = os.path.join(OUT_DIR, "superram_read_diag.crt")
    with open(out_path, 'wb') as f:
        f.write(crt)

    # MGL: loads doom.reu then our CRT
    mgl_path = os.path.join(CRT_DIR, "superram_read_diag.mgl")
    with open(mgl_path, 'w') as f:
        f.write('<mistergamedescription>\n')
        f.write('  <rbf>_Test/C64</rbf>\n')
        f.write('  <file delay="15" type="f" index="1" path="../games/C64/doom.reu"/>\n')
        f.write(f'  <file delay="2" type="f" index="5" path="../crt/superram_read_diag.crt"/>\n')
        f.write('</mistergamedescription>\n')
    print(f"Generated {mgl_path}")
