#!/usr/bin/env python3
"""Test STA long ($8F) to both bank $00 and bank $02, then readback."""
import struct, os

CODE_BASE = 0x0900
BASIC_START = 0x0801
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

def build_prg():
    basic = bytearray()
    basic += struct.pack('<H', BASIC_START + 12)
    basic += struct.pack('<H', 10)
    basic += bytes([0x9E]) + b'2304' + bytes([0x00])
    basic += struct.pack('<H', 0x0000)
    pad = CODE_BASE - (BASIC_START + len(basic))

    m = bytearray()
    pc = CODE_BASE
    def emit(*bs):
        nonlocal pc
        for b in bs:
            m.append(b & 0xFF); pc += 1

    emit(0x78)  # SEI
    emit(0xA9, 0x2F, 0x85, 0x00)  # LDA #$2F; STA $00
    emit(0xA9, 0x37, 0x85, 0x01)  # LDA #$37; STA $01

    # Marker '1' at screen pos 0 to confirm code is running
    emit(0xA9, 0x31, 0x8D, 0x00, 0x04)  # LDA #'1'; STA $0400

    # Test 1: STA long $00:$5000 = $AA, then LDA long $00:$5000, display
    emit(0xA9, 0xAA)                     # LDA #$AA
    emit(0x8F, 0x00, 0x50, 0x00)         # STA $00:$5000

    # Marker '2' at screen pos 8 to confirm STA long didn't crash
    emit(0xA9, 0x32, 0x8D, 0x08, 0x04)  # LDA #'2'; STA $0408
    emit(0xAF, 0x00, 0x50, 0x00)         # LDA $00:$5000 (readback)
    # Display high nibble at $0400
    emit(0x48)  # PHA
    emit(0x4A, 0x4A, 0x4A, 0x4A)  # LSR x4
    emit(0x09, 0x30)  # ORA #$30
    emit(0x8D, 0x00, 0x04)  # STA $0400
    emit(0x68)  # PLA
    emit(0x29, 0x0F)  # AND #$0F
    emit(0x09, 0x30)  # ORA #$30
    emit(0x8D, 0x01, 0x04)  # STA $0401
    # Should show "AA" at $0400-$0401

    # Space separator
    emit(0xA9, 0x20, 0x8D, 0x02, 0x04)

    # Test 2: STA long $02:$5000 = $BB, then LDA long $02:$5000, display
    emit(0xA9, 0xBB)                     # LDA #$BB
    emit(0x8F, 0x00, 0x50, 0x02)         # STA $02:$5000
    emit(0xAF, 0x00, 0x50, 0x02)         # LDA $02:$5000 (readback)
    # Display at $0403-$0404
    emit(0x48)
    emit(0x4A, 0x4A, 0x4A, 0x4A)
    emit(0x09, 0x30)
    emit(0x8D, 0x03, 0x04)
    emit(0x68)
    emit(0x29, 0x0F)
    emit(0x09, 0x30)
    emit(0x8D, 0x04, 0x04)
    # Should show "BB" at $0403-$0404

    # Space
    emit(0xA9, 0x20, 0x8D, 0x05, 0x04)

    # Test 3: Regular STA abs $5001 = $CC, then LDA abs $5001, display
    emit(0xA9, 0xCC)         # LDA #$CC
    emit(0x8D, 0x01, 0x50)   # STA $5001
    emit(0xAD, 0x01, 0x50)   # LDA $5001
    emit(0x48)
    emit(0x4A, 0x4A, 0x4A, 0x4A)
    emit(0x09, 0x30)
    emit(0x8D, 0x06, 0x04)
    emit(0x68)
    emit(0x29, 0x0F)
    emit(0x09, 0x30)
    emit(0x8D, 0x07, 0x04)
    # Should show "CC" at $0406-$0407

    # Border green if bank $00 worked
    emit(0xAF, 0x00, 0x50, 0x00)  # LDA $00:$5000
    emit(0xC9, 0xAA)  # CMP #$AA
    emit(0xD0, 0x05)  # BNE skip
    emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)  # green border

    # Halt
    halt = pc
    emit(0x4C, halt & 0xFF, (halt >> 8) & 0xFF)

    prg = bytearray()
    prg += struct.pack('<H', BASIC_START)
    prg += basic + bytes(pad) + m
    return prg

if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    prg = build_prg()
    path = os.path.join(OUT_DIR, "sta_long_test.prg")
    with open(path, 'wb') as f: f.write(prg)
    print(f"Generated {path} ({len(prg)} bytes)")
