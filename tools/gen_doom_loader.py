#!/usr/bin/env python3
"""Generate PRG skip loaders for Doom testing.

Generates two PRGs at $C000:
1. doom_loader.prg  - Minimal: disable IRQ/NMI + JML $200000
2. doom_patched.prg - NOP out SuperCPU register writes ($D07B etc) + JML $200000

Both work in emulation mode (game handles native mode switch itself).
Run with SYS49152 after mbc load_rom injection.
"""
import struct, sys

load_addr = 0xC000

def disasm(code, base):
    """Simple disassembler for verification."""
    pc = 0
    while pc < len(code):
        b = code[pc]
        addr = base + pc
        if b == 0x78: print(f"  ${addr:04X}: 78       SEI"); pc += 1
        elif b == 0x18: print(f"  ${addr:04X}: 18       CLC"); pc += 1
        elif b == 0x38: print(f"  ${addr:04X}: 38       SEC"); pc += 1
        elif b == 0xEA: print(f"  ${addr:04X}: EA       NOP"); pc += 1
        elif b == 0xFB: print(f"  ${addr:04X}: FB       XCE"); pc += 1
        elif b == 0xA9: print(f"  ${addr:04X}: A9 {code[pc+1]:02X}    LDA #${code[pc+1]:02X}"); pc += 2
        elif b == 0x8D: 
            a = code[pc+1] | (code[pc+2] << 8)
            print(f"  ${addr:04X}: 8D {code[pc+1]:02X} {code[pc+2]:02X} STA ${a:04X}")
            pc += 3
        elif b == 0xAD:
            a = code[pc+1] | (code[pc+2] << 8)
            print(f"  ${addr:04X}: AD {code[pc+1]:02X} {code[pc+2]:02X} LDA ${a:04X}")
            pc += 3
        elif b == 0xE2: print(f"  ${addr:04X}: E2 {code[pc+1]:02X}    SEP #${code[pc+1]:02X}"); pc += 2
        elif b == 0x8F:
            a = code[pc+1] | (code[pc+2] << 8) | (code[pc+3] << 16)
            print(f"  ${addr:04X}: 8F {code[pc+1]:02X} {code[pc+2]:02X} {code[pc+3]:02X} STA ${a:06X}")
            pc += 4
        elif b == 0x5C:
            a = code[pc+1] | (code[pc+2] << 8) | (code[pc+3] << 16)
            print(f"  ${addr:04X}: 5C {code[pc+1]:02X} {code[pc+2]:02X} {code[pc+3]:02X} JML ${a:06X}")
            pc += 4
        else:
            print(f"  ${addr:04X}: {b:02X}       ???"); pc += 1

def write_prg(filename, code):
    prg = struct.pack('<H', load_addr) + bytes(code)
    with open(filename, 'wb') as f:
        f.write(prg)
    print(f"\n{'='*60}")
    print(f"Generated {filename}: {len(prg)} bytes (load ${load_addr:04X}, {len(code)} code bytes)")
    print(f"Run: SYS {load_addr}")
    disasm(code, load_addr)

# Common preamble: SEI + disable both CIAs + acknowledge pending
def preamble():
    code = bytearray()
    code.append(0x78)                                    # SEI
    code += bytes([0xA9, 0x7F, 0x8D, 0x0D, 0xDD])      # LDA #$7F; STA $DD0D (CIA2 NMI mask)
    code += bytes([0xAD, 0x0D, 0xDD])                   # LDA $DD0D (ack pending)
    code += bytes([0xA9, 0x7F, 0x8D, 0x0D, 0xDC])      # LDA #$7F; STA $DC0D (CIA1 IRQ mask)
    code += bytes([0xAD, 0x0D, 0xDC])                   # LDA $DC0D (ack pending)
    return code

# --- PRG 1: Minimal jump ---
code1 = preamble()
code1 += bytes([0x5C, 0x00, 0x00, 0x20])               # JML $200000
write_prg('doom_loader.prg', code1)

# --- PRG 2: Patch out SuperCPU register writes, then jump ---
# Game code at $200041-$20004C writes STA to $D07E/$D07B/$D076/$D07F.
# We NOP all 12 bytes (4 × STA abs = 4 × 3 bytes).
# STA long ($8F) works in emulation mode on 65C816.
code2 = preamble()
code2 += bytes([0xA9, 0xEA])                            # LDA #$EA (NOP opcode)
for addr in range(0x200041, 0x20004D):                   # $200041..$20004C (12 bytes)
    code2 += bytes([0x8F, addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF])
# Add NOPs between patches and jump for pipeline settle time
for _ in range(8):
    code2.append(0xEA)                                   # NOP ×8
code2 += bytes([0x5C, 0x00, 0x00, 0x20])               # JML $200000
write_prg('doom_patched.prg', code2)

# --- PRG 3: Force 1MHz then jump (write $D07A instead of patching game) ---
code3 = preamble()
code3 += bytes([0x8D, 0x7A, 0xD0])                     # STA $D07A (force 1MHz)
# NOP sled for register settle
for _ in range(8):
    code3.append(0xEA)
code3 += bytes([0x5C, 0x00, 0x00, 0x20])               # JML $200000
write_prg('doom_1mhz.prg', code3)
