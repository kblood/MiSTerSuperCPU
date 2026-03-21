#!/usr/bin/env python3
"""
SuperRAM Code Execution Test
=============================
Tests if the 65816 can execute instructions fetched from SuperRAM (SDRAM).

Strategy:
1. Write a small 65816 routine into C64 RAM at $5000
2. Use REU DMA STASH to copy it to REU/SuperRAM bank $01, offset $5000
3. Use JML $01:$5000 to execute the routine from SuperRAM
4. The routine writes $42 to screen RAM ($0400) and returns via JML $00:return_addr

If $0400 shows $42 ('B' on screen), SuperRAM execution works.
Border: GREEN = success, RED = never got there, YELLOW = partial
"""

import struct
import os
import sys

CODE_BASE = 0x0900
BASIC_START = 0x0801
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SCREEN = 0x0400

# REU registers
REU_STATUS = 0xDF00
REU_CMD    = 0xDF01
REU_C64LO  = 0xDF02
REU_C64HI  = 0xDF03
REU_RAMLO  = 0xDF04
REU_RAMMID = 0xDF05
REU_RAMHI  = 0xDF06
REU_LENLO  = 0xDF07
REU_LENHI  = 0xDF08


def build_prg():
    # The routine we'll place in SuperRAM:
    # Runs in 65816 native mode, 8-bit A/X/Y
    # LDA #$42         ; A9 42
    # STA $0400        ; 8D 00 04
    # JML $00:return   ; 5C lo hi 00  (absolute long jump back to bank $00)
    # Total: 9 bytes

    # We need to know the return address at assembly time.
    # The return address will be in the main code, after the JML $01:$5000.
    # JML $01:$5000 is 4 bytes (5C 00 50 01).
    # So return_addr = address_of_jml + 4.

    code = bytearray()

    # --- BASIC stub: 10 SYS 2304 ---
    basic = bytearray()
    basic += struct.pack('<H', BASIC_START + 12)  # next line ptr
    basic += struct.pack('<H', 10)                # line number
    basic += bytes([0x9E])                        # SYS token
    basic += b'2304'                              # address
    basic += bytes([0x00])                        # end of line
    basic += struct.pack('<H', 0x0000)            # end of program

    # Pad from BASIC end to CODE_BASE
    pad = CODE_BASE - (BASIC_START + len(basic))

    # Main code at $0900
    main = bytearray()
    pc = CODE_BASE

    def emit(*bs):
        nonlocal pc
        for b in bs:
            main.append(b & 0xFF)
            pc += 1

    # SEI
    emit(0x78)

    # Set I/O visible
    emit(0xA9, 0x2F)  # LDA #$2F
    emit(0x85, 0x00)  # STA $00
    emit(0xA9, 0x37)  # LDA #$37
    emit(0x85, 0x01)  # STA $01

    # Set border to RED (indicates "in progress")
    emit(0xA9, 0x02)  # LDA #2 (red)
    emit(0x8D, 0x20, 0xD0)  # STA $D020

    # Write marker "T" at screen pos 0 (we're starting)
    emit(0xA9, 0x14)  # 'T' screen code
    emit(0x8D, 0x00, 0x04)  # STA $0400

    # === Step 1: Write test routine to C64 RAM at $5000 ===
    # The test routine (to be copied to SuperRAM):
    #   LDA #$42         ; A9 42
    #   STA $0400        ; 8D 00 04
    #   LDA #$05         ; A9 05  (green border)
    #   STA $D020        ; 8D 20 D0
    #   JML $00:return   ; 5C lo hi 00
    # Total: 12 bytes

    # We'll calculate return_addr after we know where JML $01:5000 is
    # For now, place the routine data at $5000

    # Store the routine bytes to $5000-$500B
    routine_addr = 0x5000

    # First, compute where the JML to SuperRAM will be in our main code.
    # Count bytes from here to the JML instruction:
    #   12 STA instructions for routine bytes (3 bytes each = 36)
    #   + REU setup (many instructions)
    #   + DMA trigger
    #   + wait loop
    #   + JML instruction
    # This is complex. Let me use a different approach: embed the return
    # address as the LAST thing before emitting the JML.

    # Actually, simpler approach: put the return address in a ZP pointer
    # and have the SuperRAM routine use JML [ptr]. But JML indirect needs
    # the target address in bank $00 RAM, not SuperRAM.

    # Simplest: hardcode the return address. We know the layout.
    # Let me calculate exactly.

    # Current pc after the screen write above
    routine_bytes_start = pc

    # Write routine bytes to $5000
    # Byte 0: LDA #$42 → $A9
    emit(0xA9, 0xA9); emit(0x8D, 0x00, 0x50)  # LDA #$A9; STA $5000
    # Byte 1: $42
    emit(0xA9, 0x42); emit(0x8D, 0x01, 0x50)  # LDA #$42; STA $5001
    # Byte 2: STA abs → $8D
    emit(0xA9, 0x8D); emit(0x8D, 0x02, 0x50)
    # Byte 3: $00
    emit(0xA9, 0x00); emit(0x8D, 0x03, 0x50)
    # Byte 4: $04
    emit(0xA9, 0x04); emit(0x8D, 0x04, 0x50)
    # Byte 5: LDA #$05 → $A9
    emit(0xA9, 0xA9); emit(0x8D, 0x05, 0x50)
    # Byte 6: $05 (green)
    emit(0xA9, 0x05); emit(0x8D, 0x06, 0x50)
    # Byte 7: STA $D020 → $8D
    emit(0xA9, 0x8D); emit(0x8D, 0x07, 0x50)
    # Byte 8: $20
    emit(0xA9, 0x20); emit(0x8D, 0x08, 0x50)
    # Byte 9: $D0
    emit(0xA9, 0xD0); emit(0x8D, 0x09, 0x50)
    # Byte 10: JML abs → $5C
    emit(0xA9, 0x5C); emit(0x8D, 0x0A, 0x50)

    # Bytes 11-13: return address (lo, hi, bank)
    # We need to know where we'll be after the JML $01:$5000 instruction.
    # Let's calculate: from here, we still need to:
    #   - Write 3 more bytes to $500B-$500D (9 bytes)
    #   - REU setup (~45 bytes)
    #   - DMA trigger (5 bytes)
    #   - Wait loop (~8 bytes)
    #   - Write marker (5 bytes)
    #   - JML $01:$5000 (4 bytes)
    # So return_addr ≈ pc + 9 + 45 + 5 + 8 + 5 + 4
    # Let's just mark the position and patch later.

    return_addr_patch_offset = len(main) + 1  # +1 for the LDA #imm opcode
    emit(0xA9, 0x00); emit(0x8D, 0x0B, 0x50)  # placeholder for return lo
    return_addr_patch_offset2 = len(main) + 1
    emit(0xA9, 0x00); emit(0x8D, 0x0C, 0x50)  # placeholder for return hi
    # Bank $00 for return
    emit(0xA9, 0x00); emit(0x8D, 0x0D, 0x50)

    # === Step 2: REU DMA STASH: $5000 → REU bank $01 offset $5000, 14 bytes ===
    # C64 addr = $5000
    emit(0xA9, 0x00); emit(0x8D, 0x02, 0xDF)  # REU_C64LO = $00
    emit(0xA9, 0x50); emit(0x8D, 0x03, 0xDF)  # REU_C64HI = $50
    # REU addr = bank $01, offset $5000  → REU byte 0: $00, 1: $50, 2: $01
    emit(0xA9, 0x00); emit(0x8D, 0x04, 0xDF)  # REU_RAMLO = $00
    emit(0xA9, 0x50); emit(0x8D, 0x05, 0xDF)  # REU_RAMMID = $50
    emit(0xA9, 0x01); emit(0x8D, 0x06, 0xDF)  # REU_RAMHI = $01 (bank 1)
    # Length = 14 bytes
    emit(0xA9, 0x0E); emit(0x8D, 0x07, 0xDF)  # REU_LENLO = 14
    emit(0xA9, 0x00); emit(0x8D, 0x08, 0xDF)  # REU_LENHI = 0
    # Execute STASH (cmd $90)
    emit(0xA9, 0x90); emit(0x8D, 0x01, 0xDF)

    # Wait for DMA to complete
    emit(0xA2, 0x00)  # LDX #0
    wait_loop = pc
    emit(0xCA)        # DEX
    emit(0xD0, 0xFD)  # BNE -3 (loop)

    # Write marker "S" at screen pos 1 (STASH done)
    emit(0xA9, 0x13)  # 'S' screen code
    emit(0x8D, 0x01, 0x04)

    # Change border to YELLOW (about to JML)
    emit(0xA9, 0x07)  # yellow
    emit(0x8D, 0x20, 0xD0)

    # Write marker "J" at screen pos 2 (about to JML)
    emit(0xA9, 0x0A)  # 'J' screen code
    emit(0x8D, 0x02, 0x04)

    # === Step 3: JML to SuperRAM bank $01, offset $5000 ===
    # JML $01:$5000 = opcode $5C, operand lo=$00, hi=$50, bank=$01
    jml_addr = pc
    emit(0x5C, 0x00, 0x50, 0x01)

    # === Return point (after SuperRAM code executes) ===
    return_addr = pc

    # Write marker "R" at screen pos 3 (returned!)
    emit(0xA9, 0x12)  # 'R' screen code
    emit(0x8D, 0x03, 0x04)

    # Infinite loop
    halt = pc
    emit(0x4C, halt & 0xFF, (halt >> 8) & 0xFF)  # JMP self

    # Patch the return address in the routine
    main[return_addr_patch_offset] = return_addr & 0xFF
    main[return_addr_patch_offset2] = (return_addr >> 8) & 0xFF

    # Build PRG
    prg = bytearray()
    prg += struct.pack('<H', BASIC_START)  # load address
    prg += basic
    prg += bytes(pad)
    prg += main

    return prg


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    prg = build_prg()
    out_path = os.path.join(OUT_DIR, "superram_exec_test.prg")
    with open(out_path, 'wb') as f:
        f.write(prg)
    print(f"Generated {out_path} ({len(prg)} bytes)")

    # Verify the routine at $5000
    print(f"\nReturn address patch values:")
    routine_start = CODE_BASE
    print(f"  Code starts at ${CODE_BASE:04X}")
    print(f"  PRG size: {len(prg)} bytes")
