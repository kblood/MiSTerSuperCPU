#!/usr/bin/env python3
"""
SuperRAM Code Execution Test v2
================================
Tests instruction fetch from SuperRAM using native mode + JML.
Uses 65816 long STA to write routine directly to SuperRAM (no DMA).
Then CLC/XCE to enter native mode, JML to SuperRAM, execute, return.

Screen markers at $0400: T=started, W=written, N=native, J=JML
$0401: 'B' if SuperRAM routine ran (writes $42='B')
Border: RED=started, YELLOW=about to JML, GREEN=success
"""

import struct
import os

CODE_BASE = 0x0900
BASIC_START = 0x0801
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SCREEN = 0x0400


def build_prg():
    basic = bytearray()
    basic += struct.pack('<H', BASIC_START + 12)
    basic += struct.pack('<H', 10)
    basic += bytes([0x9E]) + b'2304' + bytes([0x00])
    basic += struct.pack('<H', 0x0000)

    pad = CODE_BASE - (BASIC_START + len(basic))

    main = bytearray()
    pc = CODE_BASE

    def emit(*bs):
        nonlocal pc
        for b in bs:
            main.append(b & 0xFF)
            pc += 1

    def emit_at(offset, *bs):
        for i, b in enumerate(bs):
            main[offset + i] = b & 0xFF

    # SEI
    emit(0x78)

    # I/O visible
    emit(0xA9, 0x2F, 0x85, 0x00)  # LDA #$2F; STA $00
    emit(0xA9, 0x37, 0x85, 0x01)  # LDA #$37; STA $01

    # Red border
    emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)

    # Marker T at $0400
    emit(0xA9, 0x14, 0x8D, 0x00, 0x04)

    # === Write test routine to SuperRAM bank $02 addr $2000 using long STA ===
    # We use bank $02 (not $01) to avoid any overlap with page 0 mapping
    # The routine (runs in 8-bit mode):
    #   LDA #$42          ; A9 42       - load 'B'
    #   STA $0401         ; 8D 01 04    - store to screen pos 1
    #   LDA #$05          ; A9 05       - green
    #   STA $D020         ; 8D 20 D0    - green border
    #   SEC               ; 38          - prepare to return to emulation
    #   XCE               ; FB          - back to emulation mode
    #   JML $00:xxxx      ; 5C lo hi 00 - return to bank $00
    # Total: 15 bytes

    # We'll write each byte using STA long ($8F = STA addr24)
    # STA long: opcode $8F, addr_lo, addr_hi, bank
    routine_bytes = [
        0xA9, 0x42,             # LDA #$42 ('B')
        0x85, 0x02,             # STA $02 (ZP — always bank $00)
        0x38,                   # SEC
        0xFB,                   # XCE (back to emulation)
    ]
    # JML $00:return_addr will be added after we know return_addr
    # For now, placeholder 5C xx xx 00
    jml_return_placeholder_start = len(routine_bytes)
    routine_bytes += [0x5C, 0x00, 0x00, 0x00]  # JML $00:????

    target_bank = 0x02
    target_addr = 0x2000

    for i, b in enumerate(routine_bytes):
        # STA $02:$2000+i using long addressing (opcode $8F)
        addr = target_addr + i
        emit(0xA9, b)                          # LDA #byte
        emit(0x8F, addr & 0xFF, (addr >> 8) & 0xFF, target_bank)  # STA long

    # Marker W at $0400 (write done)
    emit(0xA9, 0x17, 0x8D, 0x00, 0x04)  # 'W'

    # === Readback verification: read first 4 bytes from SuperRAM, display as hex ===
    # Read $02:$2000 using LDA long ($AF)
    for read_idx in range(4):
        ra = target_addr + read_idx
        emit(0xAF, ra & 0xFF, (ra >> 8) & 0xFF, target_bank)  # LDA long $02:$200x
        # Display high nibble at screen row 13 + read_idx*3
        spos = SCREEN + 13 * 40 + read_idx * 3
        emit(0x48)  # PHA
        emit(0x4A, 0x4A, 0x4A, 0x4A)  # LSR x4
        emit(0x09, 0x30)  # ORA #$30
        emit(0x8D, spos & 0xFF, (spos >> 8) & 0xFF)  # STA screen
        emit(0x68)  # PLA
        emit(0x29, 0x0F)  # AND #$0F
        emit(0x09, 0x30)  # ORA #$30
        emit(0x8D, (spos+1) & 0xFF, ((spos+1) >> 8) & 0xFF)  # STA screen+1

    # === Enter native mode ===
    emit(0x18)  # CLC
    emit(0xFB)  # XCE

    # In native mode now. Set 8-bit A/X/Y (SEP #$30)
    emit(0xE2, 0x30)  # SEP #$30

    # Marker N at $0400 (native mode)
    emit(0xA9, 0x0E, 0x8D, 0x00, 0x04)  # 'N'

    # Yellow border (about to JML)
    emit(0xA9, 0x07, 0x8D, 0x20, 0xD0)

    # === JML to SuperRAM ===
    # JML $02:$2000 = opcode $5C, $00, $20, $02
    jml_pos = pc
    emit(0x5C, target_addr & 0xFF, (target_addr >> 8) & 0xFF, target_bank)

    # === Return point (back in emulation mode from SuperRAM routine) ===
    return_addr = pc

    # Marker R at $0402
    emit(0xA9, 0x12, 0x8D, 0x02, 0x04)  # 'R'

    # Check ZP $02: if $42, write 'B' at $0401 and set green border
    emit(0xA5, 0x02)  # LDA $02
    emit(0xC9, 0x42)  # CMP #$42
    emit(0xD0, 0x07)  # BNE +7 (skip success)
    emit(0xA9, 0x02, 0x8D, 0x01, 0x04)  # LDA #'B'; STA $0401
    emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)  # LDA #5; STA $D020 (green)

    # Also display the actual ZP $02 value as hex digit at $0403
    emit(0xA5, 0x02)  # LDA $02
    emit(0x4A, 0x4A, 0x4A, 0x4A)  # LSR x4
    emit(0x09, 0x30)  # ORA #$30 (to digit)
    emit(0x8D, 0x03, 0x04)  # STA $0403
    emit(0xA5, 0x02)  # LDA $02
    emit(0x29, 0x0F)  # AND #$0F
    emit(0x09, 0x30)  # ORA #$30
    emit(0x8D, 0x04, 0x04)  # STA $0404

    # Infinite halt
    halt = pc
    emit(0x4C, halt & 0xFF, (halt >> 8) & 0xFF)

    # === Patch return address in the routine ===
    # The routine's JML $00:return_addr
    # routine_bytes offset for the JML operand: jml_return_placeholder_start + 1
    # But we wrote these bytes using STA long, so we need to find the STA instruction
    # that wrote byte jml_return_placeholder_start+1 (return addr lo)
    # and patch its LDA #imm operand.

    # Each byte of the routine is written by: LDA #byte (2 bytes) + STA long (4 bytes) = 6 bytes
    # The routine_bytes start being written after the initial setup code.
    # Let's find the exact offset in main[].

    # Actually, simpler: patch the routine_bytes before writing the STA instructions.
    # But we already emitted them. Let me patch the main[] array.

    # The routine starts being written at a certain offset in main[].
    # Each routine byte i is written by: LDA #byte at main_offset + i*6 + 1 (the immediate value)
    # The first routine byte starts after: SEI(1) + I/O setup(8) + border(5) + marker(5) = 19 bytes
    routine_write_start = 19  # offset in main[] where first LDA #routine_byte is

    # Patch return address lo byte (routine_bytes index jml_return_placeholder_start + 1)
    patch_idx_lo = jml_return_placeholder_start + 1
    patch_idx_hi = jml_return_placeholder_start + 2
    # bank is already 0x00 (index +3)

    # Each routine byte uses 6 bytes in main (LDA #imm=2 + STA long=4)
    main[routine_write_start + patch_idx_lo * 6 + 1] = return_addr & 0xFF
    main[routine_write_start + patch_idx_hi * 6 + 1] = (return_addr >> 8) & 0xFF

    # Build PRG
    prg = bytearray()
    prg += struct.pack('<H', BASIC_START)
    prg += basic
    prg += bytes(pad)
    prg += main

    print(f"Return address: ${return_addr:04X}")
    print(f"JML target: ${target_bank:02X}:${target_addr:04X}")
    print(f"Total code size: {len(main)} bytes")

    return prg


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    prg = build_prg()
    out_path = os.path.join(OUT_DIR, "superram_exec_test2.prg")
    with open(out_path, 'wb') as f:
        f.write(prg)
    print(f"Generated {out_path} ({len(prg)} bytes)")
