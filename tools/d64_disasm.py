#!/usr/bin/env python3
"""
Extract PRG from D64 disk image and disassemble 65C816 code around $82E0.
Also search for SuperCPU DMAGic register references ($D070-$D07F).
"""

import sys
import struct

# D64 track/sector layout: tracks 1-17 have 21 sectors, 18-24 have 19, 25-30 have 18, 31-35 have 17
SECTORS_PER_TRACK = []
for t in range(1, 36):
    if t <= 17:
        SECTORS_PER_TRACK.append(21)
    elif t <= 24:
        SECTORS_PER_TRACK.append(19)
    elif t <= 30:
        SECTORS_PER_TRACK.append(18)
    else:
        SECTORS_PER_TRACK.append(17)

def track_sector_to_offset(track, sector):
    """Convert track/sector to byte offset in D64 image."""
    if track < 1 or track > 35:
        return None
    offset = 0
    for t in range(1, track):
        offset += SECTORS_PER_TRACK[t - 1] * 256
    offset += sector * 256
    return offset

def read_d64(filename):
    with open(filename, 'rb') as f:
        return f.read()

def list_directory(data):
    """List all directory entries."""
    # Directory starts at track 18, sector 1
    track, sector = 18, 1
    entries = []
    while track != 0:
        offset = track_sector_to_offset(track, sector)
        if offset is None:
            break
        # Next track/sector link
        next_track = data[offset]
        next_sector = data[offset + 1]
        # 8 directory entries per sector, each 32 bytes
        for i in range(8):
            entry_offset = offset + (i * 32)
            if i == 0 and track == 18 and sector == 1:
                entry_offset = offset  # First entry starts at beginning
            file_type = data[entry_offset + 2]
            if file_type == 0:
                continue
            file_track = data[entry_offset + 3]
            file_sector = data[entry_offset + 4]
            filename = data[entry_offset + 5:entry_offset + 21]
            # Decode filename (PETSCII, strip $A0 padding)
            fname = ''
            for b in filename:
                if b == 0xA0:
                    break
                if 0x41 <= b <= 0x5A:
                    fname += chr(b)  # uppercase
                elif 0xC1 <= b <= 0xDA:
                    fname += chr(b - 0x80)  # shifted uppercase
                elif 0x20 <= b <= 0x7E:
                    fname += chr(b)
                else:
                    fname += f'[{b:02X}]'
            file_size = data[entry_offset + 30] | (data[entry_offset + 31] << 8)
            type_str = ['DEL', 'SEQ', 'PRG', 'USR', 'REL'][file_type & 0x07] if (file_type & 0x07) < 5 else f'?{file_type:02X}'
            entries.append({
                'name': fname,
                'type': type_str,
                'type_byte': file_type,
                'track': file_track,
                'sector': file_sector,
                'size': file_size,
            })
        track, sector = next_track, next_sector
    return entries

def extract_file(data, track, sector):
    """Follow track/sector chain to extract file data."""
    result = bytearray()
    visited = set()
    while track != 0:
        if (track, sector) in visited:
            print(f"  WARNING: circular chain at T{track} S{sector}")
            break
        visited.add((track, sector))
        offset = track_sector_to_offset(track, sector)
        if offset is None:
            print(f"  WARNING: invalid track {track}")
            break
        next_track = data[offset]
        next_sector = data[offset + 1]
        if next_track == 0:
            # Last sector, next_sector = number of bytes used + 1
            result.extend(data[offset + 2:offset + next_sector + 1])
        else:
            result.extend(data[offset + 2:offset + 256])
        track, sector = next_track, next_sector
    return bytes(result)

# 65C816 opcode table: (mnemonic, addressing mode)
# Addressing modes determine instruction length
# Modes: imp=1, imm8=2, imm16=3, abs=3, abslong=4, dp=2, dpind=2, dpindlong=2
# absx=3, absy=3, abslongx=4, dpx=2, dpy=2, dpindx=2, dpindy=2, dpindlongy=2
# rel8=2, rel16=3, sr=2, sriy=2, bm=3

OPCODES = {
    0x00: ('BRK', 'imm8', 2),
    0x01: ('ORA', '(dp,X)', 2),
    0x02: ('COP', 'imm8', 2),
    0x03: ('ORA', 'sr,S', 2),
    0x04: ('TSB', 'dp', 2),
    0x05: ('ORA', 'dp', 2),
    0x06: ('ASL', 'dp', 2),
    0x07: ('ORA', '[dp]', 2),
    0x08: ('PHP', 'imp', 1),
    0x09: ('ORA', 'imm', -1),  # M-flag dependent
    0x0A: ('ASL', 'A', 1),
    0x0B: ('PHD', 'imp', 1),
    0x0C: ('TSB', 'abs', 3),
    0x0D: ('ORA', 'abs', 3),
    0x0E: ('ASL', 'abs', 3),
    0x0F: ('ORA', 'abslong', 4),
    0x10: ('BPL', 'rel8', 2),
    0x11: ('ORA', '(dp),Y', 2),
    0x12: ('ORA', '(dp)', 2),
    0x13: ('ORA', '(sr,S),Y', 2),
    0x14: ('TRB', 'dp', 2),
    0x15: ('ORA', 'dp,X', 2),
    0x16: ('ASL', 'dp,X', 2),
    0x17: ('ORA', '[dp],Y', 2),
    0x18: ('CLC', 'imp', 1),
    0x19: ('ORA', 'abs,Y', 3),
    0x1A: ('INC', 'A', 1),
    0x1B: ('TCS', 'imp', 1),
    0x1C: ('TRB', 'abs', 3),
    0x1D: ('ORA', 'abs,X', 3),
    0x1E: ('ASL', 'abs,X', 3),
    0x1F: ('ORA', 'abslong,X', 4),
    0x20: ('JSR', 'abs', 3),
    0x21: ('AND', '(dp,X)', 2),
    0x22: ('JSL', 'abslong', 4),
    0x23: ('AND', 'sr,S', 2),
    0x24: ('BIT', 'dp', 2),
    0x25: ('AND', 'dp', 2),
    0x26: ('ROL', 'dp', 2),
    0x27: ('AND', '[dp]', 2),
    0x28: ('PLP', 'imp', 1),
    0x29: ('AND', 'imm', -1),  # M-flag dependent
    0x2A: ('ROL', 'A', 1),
    0x2B: ('PLD', 'imp', 1),
    0x2C: ('BIT', 'abs', 3),
    0x2D: ('AND', 'abs', 3),
    0x2E: ('ROL', 'abs', 3),
    0x2F: ('AND', 'abslong', 4),
    0x30: ('BMI', 'rel8', 2),
    0x31: ('AND', '(dp),Y', 2),
    0x32: ('AND', '(dp)', 2),
    0x33: ('AND', '(sr,S),Y', 2),
    0x34: ('BIT', 'dp,X', 2),
    0x35: ('AND', 'dp,X', 2),
    0x36: ('ROL', 'dp,X', 2),
    0x37: ('AND', '[dp],Y', 2),
    0x38: ('SEC', 'imp', 1),
    0x39: ('AND', 'abs,Y', 3),
    0x3A: ('DEC', 'A', 1),
    0x3B: ('TSC', 'imp', 1),
    0x3C: ('BIT', 'abs,X', 3),
    0x3D: ('AND', 'abs,X', 3),
    0x3E: ('ROL', 'abs,X', 3),
    0x3F: ('AND', 'abslong,X', 4),
    0x40: ('RTI', 'imp', 1),
    0x41: ('EOR', '(dp,X)', 2),
    0x42: ('WDM', 'imm8', 2),
    0x43: ('EOR', 'sr,S', 2),
    0x44: ('MVP', 'bm', 3),
    0x45: ('EOR', 'dp', 2),
    0x46: ('LSR', 'dp', 2),
    0x47: ('EOR', '[dp]', 2),
    0x48: ('PHA', 'imp', 1),
    0x49: ('EOR', 'imm', -1),  # M-flag dependent
    0x4A: ('LSR', 'A', 1),
    0x4B: ('PHK', 'imp', 1),
    0x4C: ('JMP', 'abs', 3),
    0x4D: ('EOR', 'abs', 3),
    0x4E: ('LSR', 'abs', 3),
    0x4F: ('EOR', 'abslong', 4),
    0x50: ('BVC', 'rel8', 2),
    0x51: ('EOR', '(dp),Y', 2),
    0x52: ('EOR', '(dp)', 2),
    0x53: ('EOR', '(sr,S),Y', 2),
    0x54: ('MVN', 'bm', 3),
    0x55: ('EOR', 'dp,X', 2),
    0x56: ('LSR', 'dp,X', 2),
    0x57: ('EOR', '[dp],Y', 2),
    0x58: ('CLI', 'imp', 1),
    0x59: ('EOR', 'abs,Y', 3),
    0x5A: ('PHY', 'imp', 1),
    0x5B: ('TCD', 'imp', 1),
    0x5C: ('JML', 'abslong', 4),
    0x5D: ('EOR', 'abs,X', 3),
    0x5E: ('LSR', 'abs,X', 3),
    0x5F: ('EOR', 'abslong,X', 4),
    0x60: ('RTS', 'imp', 1),
    0x61: ('ADC', '(dp,X)', 2),
    0x62: ('PER', 'rel16', 3),
    0x63: ('ADC', 'sr,S', 2),
    0x64: ('STZ', 'dp', 2),
    0x65: ('ADC', 'dp', 2),
    0x66: ('ROR', 'dp', 2),
    0x67: ('ADC', '[dp]', 2),
    0x68: ('PLA', 'imp', 1),
    0x69: ('ADC', 'imm', -1),  # M-flag dependent
    0x6A: ('ROR', 'A', 1),
    0x6B: ('RTL', 'imp', 1),
    0x6C: ('JMP', '(abs)', 3),
    0x6D: ('ADC', 'abs', 3),
    0x6E: ('ROR', 'abs', 3),
    0x6F: ('ADC', 'abslong', 4),
    0x70: ('BVS', 'rel8', 2),
    0x71: ('ADC', '(dp),Y', 2),
    0x72: ('ADC', '(dp)', 2),
    0x73: ('ADC', '(sr,S),Y', 2),
    0x74: ('STZ', 'dp,X', 2),
    0x75: ('ADC', 'dp,X', 2),
    0x76: ('ROR', 'dp,X', 2),
    0x77: ('ADC', '[dp],Y', 2),
    0x78: ('SEI', 'imp', 1),
    0x79: ('ADC', 'abs,Y', 3),
    0x7A: ('PLY', 'imp', 1),
    0x7B: ('TDC', 'imp', 1),
    0x7C: ('JMP', '(abs,X)', 3),
    0x7D: ('ADC', 'abs,X', 3),
    0x7E: ('ROR', 'abs,X', 3),
    0x7F: ('ADC', 'abslong,X', 4),
    0x80: ('BRA', 'rel8', 2),
    0x81: ('STA', '(dp,X)', 2),
    0x82: ('BRL', 'rel16', 3),
    0x83: ('STA', 'sr,S', 2),
    0x84: ('STY', 'dp', 2),
    0x85: ('STA', 'dp', 2),
    0x86: ('STX', 'dp', 2),
    0x87: ('STA', '[dp]', 2),
    0x88: ('DEY', 'imp', 1),
    0x89: ('BIT', 'imm', -1),  # M-flag dependent
    0x8A: ('TXA', 'imp', 1),
    0x8B: ('PHB', 'imp', 1),
    0x8C: ('STY', 'abs', 3),
    0x8D: ('STA', 'abs', 3),
    0x8E: ('STX', 'abs', 3),
    0x8F: ('STA', 'abslong', 4),
    0x90: ('BCC', 'rel8', 2),
    0x91: ('STA', '(dp),Y', 2),
    0x92: ('STA', '(dp)', 2),
    0x93: ('STA', '(sr,S),Y', 2),
    0x94: ('STY', 'dp,X', 2),
    0x95: ('STA', 'dp,X', 2),
    0x96: ('STX', 'dp,Y', 2),
    0x97: ('STA', '[dp],Y', 2),
    0x98: ('TYA', 'imp', 1),
    0x99: ('STA', 'abs,Y', 3),
    0x9A: ('TXS', 'imp', 1),
    0x9B: ('TXY', 'imp', 1),
    0x9C: ('STZ', 'abs', 3),
    0x9D: ('STA', 'abs,X', 3),
    0x9E: ('STZ', 'abs,X', 3),
    0x9F: ('STA', 'abslong,X', 4),
    0xA0: ('LDY', 'imm_xy', -2),  # X-flag dependent
    0xA1: ('LDA', '(dp,X)', 2),
    0xA2: ('LDX', 'imm_xy', -2),  # X-flag dependent
    0xA3: ('LDA', 'sr,S', 2),
    0xA4: ('LDY', 'dp', 2),
    0xA5: ('LDA', 'dp', 2),
    0xA6: ('LDX', 'dp', 2),
    0xA7: ('LDA', '[dp]', 2),
    0xA8: ('TAY', 'imp', 1),
    0xA9: ('LDA', 'imm', -1),  # M-flag dependent
    0xAA: ('TAX', 'imp', 1),
    0xAB: ('PLB', 'imp', 1),
    0xAC: ('LDY', 'abs', 3),
    0xAD: ('LDA', 'abs', 3),
    0xAE: ('LDX', 'abs', 3),
    0xAF: ('LDA', 'abslong', 4),
    0xB0: ('BCS', 'rel8', 2),
    0xB1: ('LDA', '(dp),Y', 2),
    0xB2: ('LDA', '(dp)', 2),
    0xB3: ('LDA', '(sr,S),Y', 2),
    0xB4: ('LDY', 'dp,X', 2),
    0xB5: ('LDA', 'dp,X', 2),
    0xB6: ('LDX', 'dp,Y', 2),
    0xB7: ('LDA', '[dp],Y', 2),
    0xB8: ('CLV', 'imp', 1),
    0xB9: ('LDA', 'abs,Y', 3),
    0xBA: ('TSX', 'imp', 1),
    0xBB: ('TYX', 'imp', 1),
    0xBC: ('LDY', 'abs,X', 3),
    0xBD: ('LDA', 'abs,X', 3),
    0xBE: ('LDX', 'abs,Y', 3),
    0xBF: ('LDA', 'abslong,X', 4),
    0xC0: ('CPY', 'imm_xy', -2),  # X-flag dependent
    0xC1: ('CMP', '(dp,X)', 2),
    0xC2: ('REP', 'imm8', 2),
    0xC3: ('CMP', 'sr,S', 2),
    0xC4: ('CPY', 'dp', 2),
    0xC5: ('CMP', 'dp', 2),
    0xC6: ('DEC', 'dp', 2),
    0xC7: ('CMP', '[dp]', 2),
    0xC8: ('INY', 'imp', 1),
    0xC9: ('CMP', 'imm', -1),  # M-flag dependent
    0xCA: ('DEX', 'imp', 1),
    0xCB: ('WAI', 'imp', 1),
    0xCC: ('CPY', 'abs', 3),
    0xCD: ('CMP', 'abs', 3),
    0xCE: ('DEC', 'abs', 3),
    0xCF: ('CMP', 'abslong', 4),
    0xD0: ('BNE', 'rel8', 2),
    0xD1: ('CMP', '(dp),Y', 2),
    0xD2: ('CMP', '(dp)', 2),
    0xD3: ('CMP', '(sr,S),Y', 2),
    0xD4: ('PEI', '(dp)', 2),
    0xD5: ('CMP', 'dp,X', 2),
    0xD6: ('DEC', 'dp,X', 2),
    0xD7: ('CMP', '[dp],Y', 2),
    0xD8: ('CLD', 'imp', 1),
    0xD9: ('CMP', 'abs,Y', 3),
    0xDA: ('PHX', 'imp', 1),
    0xDB: ('STP', 'imp', 1),
    0xDC: ('JML', '[abs]', 3),
    0xDD: ('CMP', 'abs,X', 3),
    0xDE: ('DEC', 'abs,X', 3),
    0xDF: ('CMP', 'abslong,X', 4),
    0xE0: ('CPX', 'imm_xy', -2),  # X-flag dependent
    0xE1: ('SBC', '(dp,X)', 2),
    0xE2: ('SEP', 'imm8', 2),
    0xE3: ('SBC', 'sr,S', 2),
    0xE4: ('CPX', 'dp', 2),
    0xE5: ('SBC', 'dp', 2),
    0xE6: ('INC', 'dp', 2),
    0xE7: ('SBC', '[dp]', 2),
    0xE8: ('INX', 'imp', 1),
    0xE9: ('SBC', 'imm', -1),  # M-flag dependent
    0xEA: ('NOP', 'imp', 1),
    0xEB: ('XBA', 'imp', 1),
    0xEC: ('CPX', 'abs', 3),
    0xED: ('SBC', 'abs', 3),
    0xEE: ('INC', 'abs', 3),
    0xEF: ('SBC', 'abslong', 4),
    0xF0: ('BEQ', 'rel8', 2),
    0xF1: ('SBC', '(dp),Y', 2),
    0xF2: ('SBC', '(dp)', 2),
    0xF3: ('SBC', '(sr,S),Y', 2),
    0xF4: ('PEA', 'abs', 3),
    0xF5: ('SBC', 'dp,X', 2),
    0xF6: ('INC', 'dp,X', 2),
    0xF7: ('SBC', '[dp],Y', 2),
    0xF8: ('SED', 'imp', 1),
    0xF9: ('SBC', 'abs,Y', 3),
    0xFA: ('PLX', 'imp', 1),
    0xFB: ('XCE', 'imp', 1),
    0xFC: ('JSR', '(abs,X)', 3),
    0xFD: ('SBC', 'abs,X', 3),
    0xFE: ('INC', 'abs,X', 3),
    0xFF: ('SBC', 'abslong,X', 4),
}

def disassemble(data, base_addr, start_offset, length, m_flag=True, x_flag=True):
    """Disassemble 65C816 code. m_flag/x_flag assume 8-bit mode by default."""
    lines = []
    i = start_offset
    end = min(start_offset + length, len(data))
    while i < end:
        addr = base_addr + i
        opcode = data[i]
        if opcode not in OPCODES:
            lines.append(f"${addr:04X}: {opcode:02X}          ???")
            i += 1
            continue
        mnem, mode, size = OPCODES[opcode]

        # Handle flag-dependent immediate sizes
        if size == -1:  # M-flag dependent (8-bit accumulator)
            size = 2 if m_flag else 3
        elif size == -2:  # X-flag dependent (8-bit index)
            size = 2 if x_flag else 3

        # Track flag changes
        if opcode == 0xC2:  # REP
            if i + 1 < end:
                val = data[i + 1]
                if val & 0x20: m_flag = False  # 16-bit M
                if val & 0x10: x_flag = False  # 16-bit X
        elif opcode == 0xE2:  # SEP
            if i + 1 < end:
                val = data[i + 1]
                if val & 0x20: m_flag = True  # 8-bit M
                if val & 0x10: x_flag = True  # 8-bit X
        elif opcode == 0xFB:  # XCE - assume going to emulation = 8-bit
            m_flag = True
            x_flag = True

        if i + size > end:
            hex_bytes = ' '.join(f'{data[j]:02X}' for j in range(i, min(i + size, end)))
            lines.append(f"${addr:04X}: {hex_bytes:<12s} {mnem} (incomplete)")
            break

        hex_bytes = ' '.join(f'{data[j]:02X}' for j in range(i, i + size))

        # Format operand
        if size == 1:
            operand = ''
        elif mode == 'rel8':
            rel = data[i + 1]
            if rel >= 0x80:
                rel -= 256
            target = addr + 2 + rel
            operand = f'${target:04X}'
        elif mode == 'rel16':
            rel = data[i + 1] | (data[i + 2] << 8)
            if rel >= 0x8000:
                rel -= 0x10000
            target = addr + 3 + rel
            operand = f'${target:04X}'
        elif mode == 'imm8':
            operand = f'#${data[i+1]:02X}'
        elif mode in ('imm', 'imm_xy'):
            if size == 2:
                operand = f'#${data[i+1]:02X}'
            else:
                operand = f'#${data[i+2]:02X}{data[i+1]:02X}'
        elif mode == 'dp':
            operand = f'${data[i+1]:02X}'
        elif mode == 'dp,X':
            operand = f'${data[i+1]:02X},X'
        elif mode == 'dp,Y':
            operand = f'${data[i+1]:02X},Y'
        elif mode == '(dp,X)':
            operand = f'(${data[i+1]:02X},X)'
        elif mode == '(dp),Y':
            operand = f'(${data[i+1]:02X}),Y'
        elif mode == '(dp)':
            operand = f'(${data[i+1]:02X})'
        elif mode == '[dp]':
            operand = f'[${data[i+1]:02X}]'
        elif mode == '[dp],Y':
            operand = f'[${data[i+1]:02X}],Y'
        elif mode == 'abs':
            val = data[i+1] | (data[i+2] << 8)
            operand = f'${val:04X}'
        elif mode == 'abs,X':
            val = data[i+1] | (data[i+2] << 8)
            operand = f'${val:04X},X'
        elif mode == 'abs,Y':
            val = data[i+1] | (data[i+2] << 8)
            operand = f'${val:04X},Y'
        elif mode == '(abs)':
            val = data[i+1] | (data[i+2] << 8)
            operand = f'(${val:04X})'
        elif mode == '(abs,X)':
            val = data[i+1] | (data[i+2] << 8)
            operand = f'(${val:04X},X)'
        elif mode == '[abs]':
            val = data[i+1] | (data[i+2] << 8)
            operand = f'[${val:04X}]'
        elif mode == 'abslong':
            val = data[i+1] | (data[i+2] << 8) | (data[i+3] << 16)
            operand = f'${val:06X}'
        elif mode == 'abslong,X':
            val = data[i+1] | (data[i+2] << 8) | (data[i+3] << 16)
            operand = f'${val:06X},X'
        elif mode == 'sr,S':
            operand = f'${data[i+1]:02X},S'
        elif mode == '(sr,S),Y':
            operand = f'(${data[i+1]:02X},S),Y'
        elif mode == 'bm':
            operand = f'${data[i+1]:02X},${data[i+2]:02X}'
        elif mode == 'A':
            operand = 'A'
        else:
            operand = mode

        marker = '  <--- STUCK HERE' if addr == 0x82E0 else ''
        lines.append(f"${addr:04X}: {hex_bytes:<12s} {mnem} {operand}{marker}")
        i += size

    return lines

def find_register_refs(data, base_addr):
    """Search for $D07x register references in binary data."""
    refs = []
    # Search for the byte sequences that represent $D070-$D07F as absolute addresses
    for reg in range(0xD070, 0xD080):
        lo = reg & 0xFF
        hi = (reg >> 8) & 0xFF
        # Search for lo,hi pattern (little-endian address)
        for i in range(len(data) - 1):
            if data[i] == lo and data[i + 1] == hi:
                addr = base_addr + i
                # Look at preceding byte for context
                if i > 0:
                    prev_opcode = data[i - 1]
                    if prev_opcode in OPCODES:
                        mnem, mode, size = OPCODES[prev_opcode]
                        if size == 3 and 'abs' in mode:
                            refs.append((addr - 1, reg, f"{mnem} ${reg:04X}"))
                            continue
                    # Could be abs,X or abs,Y with opcode 2 bytes back
                    if i > 1:
                        prev2 = data[i - 1]
                        # Check if this is part of a 4-byte long address
                        pass
                refs.append((addr, reg, f"raw bytes at ${addr:04X}"))

    # Also search for $D0B0-$D0BF (SCPU v2 registers)
    for reg in range(0xD0B0, 0xD0C0):
        lo = reg & 0xFF
        hi = (reg >> 8) & 0xFF
        for i in range(len(data) - 1):
            if data[i] == lo and data[i + 1] == hi:
                addr = base_addr + i
                if i > 0:
                    prev_opcode = data[i - 1]
                    if prev_opcode in OPCODES:
                        mnem, mode, size = OPCODES[prev_opcode]
                        if size == 3 and 'abs' in mode:
                            refs.append((addr - 1, reg, f"{mnem} ${reg:04X}"))
                            continue
                refs.append((addr, reg, f"raw bytes at ${addr:04X}"))

    return refs

def main():
    d64_file = "C:/LLM/C64/MiSTerSuperCPU/SCPU1.D64"
    data = read_d64(d64_file)
    print(f"D64 image: {len(data)} bytes")

    # List directory
    entries = list_directory(data)
    print(f"\nDirectory ({len(entries)} files):")
    for e in entries:
        print(f"  {e['type']} \"{e['name']}\" - {e['size']} blocks, T{e['track']}:S{e['sector']}")

    # Extract the first PRG file (likely the main program)
    # Try to find "SCPU KICKS" or similar
    target = None
    for e in entries:
        if 'SCPU' in e['name'].upper() or 'KICK' in e['name'].upper() or 'DMA' in e['name'].upper():
            target = e
            break

    if target is None and entries:
        # Just use first PRG
        for e in entries:
            if e['type'] == 'PRG':
                target = e
                break

    if target is None:
        print("No PRG file found!")
        return

    print(f"\nExtracting: \"{target['name']}\" ({target['type']}, {target['size']} blocks)")
    file_data = extract_file(data, target['track'], target['sector'])
    print(f"Extracted {len(file_data)} bytes")

    if len(file_data) < 2:
        print("File too small!")
        return

    load_addr = file_data[0] | (file_data[1] << 8)
    prg_data = file_data[2:]  # Strip load address header
    end_addr = load_addr + len(prg_data) - 1
    print(f"Load address: ${load_addr:04X}, End: ${end_addr:04X}, Size: {len(prg_data)} bytes")

    # Check if $82E0 is within range
    target_addr = 0x82E0
    if load_addr <= target_addr <= end_addr:
        offset = target_addr - load_addr
        # Disassemble a window around $82E0
        start = max(0, offset - 64)
        start_addr_disp = load_addr + start
        print(f"\n{'='*60}")
        print(f"Disassembly around ${target_addr:04X} (offset {offset} in file):")
        print(f"{'='*60}")

        # We don't know flag state, try both assumptions
        # Start with 8-bit (emulation-like) as default
        print("\n--- Assuming 8-bit A/XY (M=1, X=1) ---")
        lines = disassemble(prg_data, load_addr, start, 160, m_flag=True, x_flag=True)
        for line in lines:
            print(line)

        # Also show raw hex around $82E0
        print(f"\n{'='*60}")
        print(f"Raw hex dump at ${target_addr:04X}-${target_addr+31:04X}:")
        print(f"{'='*60}")
        for row in range(0, 32, 16):
            hex_str = ' '.join(f'{prg_data[offset+row+j]:02X}' for j in range(min(16, len(prg_data)-offset-row)))
            ascii_str = ''.join(chr(prg_data[offset+row+j]) if 0x20 <= prg_data[offset+row+j] <= 0x7E else '.' for j in range(min(16, len(prg_data)-offset-row)))
            print(f"${target_addr+row:04X}: {hex_str}  {ascii_str}")
    else:
        print(f"\n${target_addr:04X} is NOT within file range ${load_addr:04X}-${end_addr:04X}")
        # Still disassemble the beginning
        print(f"\nDisassembly from ${load_addr:04X}:")
        lines = disassemble(prg_data, load_addr, 0, 128, m_flag=True, x_flag=True)
        for line in lines:
            print(line)

    # Search for SuperCPU register references
    print(f"\n{'='*60}")
    print("SuperCPU register references ($D07x, $D0Bx):")
    print(f"{'='*60}")
    refs = find_register_refs(prg_data, load_addr)
    if refs:
        for addr, reg, desc in sorted(refs):
            reg_name = {
                0xD070: 'DMA source low', 0xD071: 'DMA source high', 0xD072: 'DMA dest low',
                0xD073: 'DMA dest high', 0xD074: 'DMA length low', 0xD075: 'DMA length high',
                0xD076: 'DMA command', 0xD077: 'DMA status',
                0xD078: 'Cache flush', 0xD079: '1MHz enable',
                0xD07A: 'Turbo disable', 0xD07B: 'Turbo enable',
                0xD07C: 'VIC bank opt', 0xD07D: 'Regs disable/mirror',
                0xD07E: 'Regs enable/ROM vis', 0xD07F: 'Regs disable',
                0xD0B0: 'SCPU HW version', 0xD0B2: 'SCPU HW status',
                0xD0B4: 'Optim mode', 0xD0B5: 'Speed/JiffyDOS',
                0xD0B6: 'Emu mode', 0xD0B8: 'Speed status',
                0xD0BC: 'SCPU ID ($C9)',
            }.get(reg, f'reg ${reg:04X}')
            print(f"  ${addr:04X}: {desc} ({reg_name})")
    else:
        print("  No references found.")

    # Also extract ALL PRG files and check if $82E0 is in any of them
    print(f"\n{'='*60}")
    print("Checking all files for $82E0 coverage:")
    print(f"{'='*60}")
    for e in entries:
        if e['type'] != 'PRG':
            continue
        fd = extract_file(data, e['track'], e['sector'])
        if len(fd) < 2:
            continue
        la = fd[0] | (fd[1] << 8)
        pd = fd[2:]
        ea = la + len(pd) - 1
        covers = "*** COVERS $82E0 ***" if la <= 0x82E0 <= ea else ""
        print(f"  \"{e['name']}\": ${la:04X}-${ea:04X} ({len(pd)} bytes) {covers}")

        if la <= 0x82E0 <= ea and e['name'] != target['name']:
            offset = 0x82E0 - la
            print(f"\n  Disassembly of \"{e['name']}\" around $82E0:")
            start = max(0, offset - 64)
            lines = disassemble(pd, la, start, 160, m_flag=True, x_flag=True)
            for line in lines:
                print(f"    {line}")

            print(f"\n  Register references in \"{e['name']}\":")
            refs2 = find_register_refs(pd, la)
            for addr, reg, desc in sorted(refs2):
                print(f"    ${addr:04X}: {desc}")

if __name__ == '__main__':
    main()
