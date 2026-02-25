#!/usr/bin/env python3
"""
Parse C64 KERNAL ROM MIF files and find occurrences of opcode $89 (BIT #immediate)
that are actual opcodes, not operands or address bytes.

This script:
1. Parses both standard and JiffyDOS MIF files into byte arrays
2. Disassembles the KERNAL area ($2000-$3FFF) using 6502 instruction length tracking
3. Finds all occurrences where $89 is an actual OPCODE at an instruction boundary
4. Shows context and checks if BEQ/BNE follow within 3 bytes
"""

import re
from typing import List, Dict, Tuple

# 6502 instruction lengths (more comprehensive)
# 1-byte instructions (implied/accumulator)
ONE_BYTE = {
    0x00, 0x08, 0x18, 0x28, 0x38, 0x40, 0x48, 0x58, 0x60, 0x68, 0x78, 0x88, 0x8A,
    0x98, 0x9A, 0xA8, 0xAA, 0xB8, 0xBA, 0xC8, 0xCA, 0xD8, 0xE8, 0xEA, 0xF8,
    # Additional implied instructions (invalid/undocumented)
    0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x82, 0x92, 0xB2, 0xD2, 0xF2,
    0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA, 0x04, 0x14, 0x34, 0x44, 0x54, 0x64, 0x74,
    0x80, 0xC2, 0xE2,
}

# 2-byte instructions (immediate, zero page, etc.)
TWO_BYTE = {
    0x05, 0x06, 0x09, 0x10, 0x11, 0x15, 0x16, 0x20, 0x21, 0x24, 0x25, 0x26, 0x29, 0x2A,
    0x2C, 0x30, 0x31, 0x35, 0x36, 0x45, 0x46, 0x49, 0x50, 0x51, 0x55, 0x56, 0x65, 0x66,
    0x69, 0x70, 0x71, 0x75, 0x76, 0x81, 0x84, 0x85, 0x86, 0x90, 0x91, 0x94, 0x95, 0xA0,
    0xA1, 0xA2, 0xA4, 0xA5, 0xA6, 0xA9, 0xB0, 0xB1, 0xB4, 0xB5, 0xB6, 0xC0, 0xC1, 0xC4,
    0xC5, 0xC6, 0xC9, 0xD0, 0xD1, 0xD5, 0xD6, 0xE0, 0xE1, 0xE4, 0xE5, 0xE6, 0xE9, 0xF0,
    0xF1, 0xF5, 0xF6,
    # BIT #immediate ($89)
    0x89,
}

# 3-byte instructions (absolute addressing)
THREE_BYTE = {
    0x01, 0x0D, 0x0E, 0x19, 0x1D, 0x2D, 0x2E, 0x39, 0x3D, 0x4C, 0x4D, 0x4E, 0x59, 0x5D,
    0x6D, 0x6E, 0x79, 0x7D, 0x8C, 0x8D, 0x8E, 0x99, 0x9D, 0xAC, 0xAD, 0xAE, 0xB9, 0xBC,
    0xBD, 0xBE, 0xCC, 0xCD, 0xCE, 0xD9, 0xDD, 0xDE, 0xEC, 0xED, 0xEE, 0xF9, 0xFD, 0xFE,
}

def get_instruction_length(opcode: int) -> int:
    """Get the instruction length for a given opcode."""
    if opcode in ONE_BYTE:
        return 1
    elif opcode in TWO_BYTE:
        return 2
    elif opcode in THREE_BYTE:
        return 3
    else:
        # Default to 1 if unknown
        return 1

def parse_std_mif(filepath: str) -> List[int]:
    """Parse the standard MIF file (one byte per line)."""
    rom = []
    with open(filepath, 'r') as f:
        in_content = False
        for line in f:
            line = line.strip()
            if line == 'CONTENT BEGIN':
                in_content = True
                continue
            if line == 'END;':
                break
            if not in_content or not line or line.startswith('--'):
                continue
            
            # Parse lines like: "0000  :   94;"
            match = re.match(r'\s*[0-9A-Fa-f]+\s*:\s*([0-9A-Fa-f]+);', line)
            if match:
                byte_val = int(match.group(1), 16)
                rom.append(byte_val)
    
    return rom

def parse_dol_mif(filepath: str) -> List[int]:
    """Parse the JiffyDOS MIF file (multiple bytes per line)."""
    rom = []
    with open(filepath, 'r') as f:
        in_content = False
        for line in f:
            line = line.strip()
            if line == 'CONTENT BEGIN':
                in_content = True
                continue
            if line == 'END;':
                break
            if not in_content or not line or line.startswith('--'):
                continue
            
            # Parse lines like: "0000: 94 E3 7B E3 43 42 4D 42 41 53 49 43 30 A8 41 A7"
            if ':' not in line:
                continue
            
            parts = line.split(':')
            if len(parts) < 2:
                continue
            
            # Parse all bytes after the colon
            byte_str = parts[1].strip()
            bytes_list = byte_str.split()
            for byte_hex in bytes_list:
                if byte_hex and byte_hex[-1] != ';':  # Skip empty or END marker
                    try:
                        byte_val = int(byte_hex, 16)
                        rom.append(byte_val)
                    except ValueError:
                        pass
    
    return rom

def disassemble_with_boundaries(rom: List[int], start_offset: int, end_offset: int) -> Dict[int, int]:
    """
    Disassemble ROM to find instruction boundaries.
    Returns a dict mapping offset -> instruction length
    """
    boundaries = {}
    offset = start_offset
    
    while offset < end_offset and offset < len(rom):
        opcode = rom[offset]
        length = get_instruction_length(opcode)
        boundaries[offset] = length
        offset += length
    
    return boundaries

def format_instruction_disasm(rom: List[int], boundaries: Dict[int, int], 
                              offset: int) -> str:
    """Format a single instruction for display."""
    if offset not in boundaries:
        return f"${rom[offset]:02X}  (unknown/boundary)"
    
    opcode = rom[offset]
    length = boundaries[offset]
    
    mnemonic_map = {
        # Two-byte instructions
        0x89: 'BIT', 0xA6: 'LDX', 0xC6: 'DEC', 0x06: 'ASL', 0xA9: 'LDA',
        0xC9: 'CMP', 0xE9: 'SBC', 0x69: 'ADC', 0x49: 'EOR', 0x29: 'AND', 0x09: 'ORA',
        0xA5: 'LDA', 0xA4: 'LDY', 0xC5: 'CMP', 0xE5: 'SBC', 0x65: 'ADC', 0x45: 'EOR',
        0x25: 'AND', 0x05: 'ORA', 0x84: 'STY', 0x85: 'STA', 0x86: 'STX', 0xC0: 'CPY',
        0xE0: 'CPX', 0xE4: 'CPX', 0x24: 'BIT', 0x04: 'TSB', 0xA2: 'LDX', 0xA0: 'LDY',
        # Three-byte instructions
        0xAD: 'LDA', 0xAC: 'LDY', 0xAE: 'LDX', 0xCD: 'CMP', 0xED: 'SBC', 0x6D: 'ADC',
        0x4D: 'EOR', 0x2D: 'AND', 0x0D: 'ORA', 0x8D: 'STA', 0x8C: 'STY', 0x8E: 'STX',
        0xCC: 'CPY', 0xEC: 'CPX', 0xBC: 'LDY', 0xBE: 'LDX', 0xBD: 'LDA', 0x2C: 'BIT',
        # Implied/One-byte
        0x8A: 'TXA', 0x98: 'TYA', 0xA8: 'TAY', 0xAA: 'TAX', 0xBA: 'TSX', 0x9A: 'TXS',
        0x68: 'PLA', 0x48: 'PHA', 0x60: 'RTS', 0x40: 'RTI', 0xEA: 'NOP', 0xC8: 'INY',
        0xE8: 'INX', 0x88: 'DEY', 0xCA: 'DEX', 0x18: 'CLC', 0x38: 'SEC', 0x58: 'CLI',
        0x78: 'SEI', 0xD8: 'CLD', 0xF8: 'SED', 0xB8: 'CLV',
        # Relative/Branch
        0xF0: 'BEQ', 0xD0: 'BNE', 0x10: 'BPL', 0x30: 'BMI', 0x50: 'BVC', 0x70: 'BVS',
        0x90: 'BCC', 0xB0: 'BCS', 0x80: 'BRA',
        # Indirect/Indexed
        0xB1: 'LDA', 0xA1: 'LDA', 0x91: 'STA', 0x81: 'STA', 0xB5: 'LDA',
        0x95: 'STA', 0x99: 'STA', 0xB9: 'LDA', 0x9D: 'STA', 0xBD: 'LDA',
        0xA1: 'LDA', 0x11: 'ORA', 0x31: 'AND', 0x51: 'EOR', 0x71: 'ADC',
        0xD1: 'CMP', 0xF1: 'SBC',
        # JSR/JMP
        0x20: 'JSR', 0x4C: 'JMP', 0x6C: 'JMP',
    }
    
    mnem = mnemonic_map.get(opcode, f'${opcode:02X}')
    
    if length == 1:
        return f"{mnem}"
    elif length == 2:
        if offset + 1 < len(rom):
            operand = rom[offset + 1]
            if opcode in (0xF0, 0xD0, 0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0x80):  # Branch
                # Treat as signed offset
                signed = operand if operand < 128 else operand - 256
                target = offset + 2 + signed
                return f"{mnem} ${target:04X}"
            else:
                return f"{mnem} #${operand:02X}" if opcode == 0x89 else f"{mnem} ${operand:02X}"
        return f"{mnem}"
    elif length == 3:
        if offset + 2 < len(rom):
            low = rom[offset + 1]
            high = rom[offset + 2]
            addr = (high << 8) | low
            return f"{mnem} ${addr:04X}"
        return f"{mnem}"
    
    return f"${opcode:02X}"

def find_opcode_89_occurrences(rom: List[int], boundaries: Dict[int, int], 
                                start_offset: int, end_offset: int) -> List[Tuple]:
    """
    Find all occurrences of $89 opcode at instruction boundaries.
    Returns list of (offset, c64_addr, context, has_beq_after, has_bne_after, disasm_context)
    """
    results = []
    
    for offset in boundaries:
        if offset < start_offset or offset >= end_offset:
            continue
        
        if rom[offset] == 0x89:
            # Calculate C64 address ($E000 + offset from $2000)
            c64_offset = offset - start_offset
            c64_addr = 0xE000 + c64_offset
            
            # Get context: ±3 bytes
            start_ctx = max(0, offset - 3)
            end_ctx = min(len(rom), offset + 4)
            context_bytes = rom[start_ctx:end_ctx]
            context_str = ' '.join(f'{b:02X}' for b in context_bytes)
            
            # Build disassembly context (±3 instructions)
            disasm_parts = []
            for ctx_offset in range(max(start_offset, offset - 9), min(end_offset, offset + 5)):
                if ctx_offset in boundaries:
                    instr = format_instruction_disasm(rom, boundaries, ctx_offset)
                    if ctx_offset == offset:
                        disasm_parts.append(f"[{instr}]")  # Mark the $89 instruction
                    else:
                        disasm_parts.append(instr)
            disasm_context = " -> ".join(disasm_parts)
            
            # Check for BEQ ($F0) or BNE ($D0) within next 3 bytes after this instruction
            has_beq = False
            has_bne = False
            next_offset = offset + 2  # BIT #immediate is 2 bytes
            
            for check_offset in boundaries:
                if next_offset <= check_offset < next_offset + 3:
                    if rom[check_offset] == 0xF0:  # BEQ
                        has_beq = True
                    elif rom[check_offset] == 0xD0:  # BNE
                        has_bne = True
            
            results.append((offset, c64_addr, context_str, has_beq, has_bne, disasm_context))
    
    return results

def main():
    print("=" * 90)
    print("C64 KERNAL ROM Opcode $89 (BIT #immediate) Analysis")
    print("=" * 90)
    
    # Parse both MIF files
    print("\nParsing MIF files...")
    std_rom = parse_std_mif(r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\roms\std_C64.mif')
    dol_rom = parse_dol_mif(r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\roms\dol_C64.mif')
    
    print(f"  Standard C64: {len(std_rom)} bytes")
    print(f"  JiffyDOS C64: {len(dol_rom)} bytes")
    
    # KERNAL occupies addresses $2000-$3FFF in MIF (C64 address $E000-$FFFF)
    kernal_start = 0x2000
    kernal_end = 0x4000
    
    print(f"\nKERNAL Address Range:")
    print(f"  MIF Offset:  0x2000 - 0x3FFF ({kernal_end - kernal_start} bytes)")
    print(f"  C64 Address: 0xE000 - 0xFFFF")
    
    print(f"\nDisassembling with 6502 instruction length tracking...")
    
    # Process Standard C64 ROM
    print("\n" + "=" * 90)
    print("STANDARD C64 ROM (std_C64.mif)")
    print("=" * 90)
    
    std_boundaries = disassemble_with_boundaries(std_rom, kernal_start, kernal_end)
    std_results = find_opcode_89_occurrences(std_rom, std_boundaries, kernal_start, kernal_end)
    
    if std_results:
        print(f"\n[FOUND] {len(std_results)} occurrence(s) of opcode $89:\n")
        for i, (offset, c64_addr, context, has_beq, has_bne, disasm) in enumerate(std_results, 1):
            print(f"  [{i}] Offset: 0x{offset:04X} | C64 Address: 0x{c64_addr:04X}")
            print(f"      Hex Context: {context}")
            print(f"      Disassembly: {disasm}")
            branch_info = []
            if has_beq:
                branch_info.append("BEQ ($F0)")
            if has_bne:
                branch_info.append("BNE ($D0)")
            if branch_info:
                print(f"      Branch Instruction: {', '.join(branch_info)} follows within 3 bytes")
            else:
                print(f"      Branch Instruction: None within next 3 bytes")
            print()
    else:
        print("\n[NOT FOUND] No occurrences of opcode $89 found in KERNAL area.")
    
    # Process JiffyDOS ROM
    print("=" * 90)
    print("JIFFYDOS C64 ROM (dol_C64.mif)")
    print("=" * 90)
    
    dol_boundaries = disassemble_with_boundaries(dol_rom, kernal_start, kernal_end)
    dol_results = find_opcode_89_occurrences(dol_rom, dol_boundaries, kernal_start, kernal_end)
    
    if dol_results:
        print(f"\n[FOUND] {len(dol_results)} occurrence(s) of opcode $89:\n")
        for i, (offset, c64_addr, context, has_beq, has_bne, disasm) in enumerate(dol_results, 1):
            print(f"  [{i}] Offset: 0x{offset:04X} | C64 Address: 0x{c64_addr:04X}")
            print(f"      Hex Context: {context}")
            print(f"      Disassembly: {disasm}")
            branch_info = []
            if has_beq:
                branch_info.append("BEQ ($F0)")
            if has_bne:
                branch_info.append("BNE ($D0)")
            if branch_info:
                print(f"      Branch Instruction: {', '.join(branch_info)} follows within 3 bytes")
            else:
                print(f"      Branch Instruction: None within next 3 bytes")
            print()
    else:
        print("\n[NOT FOUND] No occurrences of opcode $89 found in KERNAL area.")
    
    # Summary
    print("=" * 90)
    print("SUMMARY")
    print("=" * 90)
    print(f"\nStandard C64 KERNAL:  {len(std_results)} occurrence(s) of opcode $89")
    print(f"JiffyDOS C64 KERNAL:  {len(dol_results)} occurrence(s) of opcode $89")
    print("\nNote: The BIT #immediate ($89) instruction tests bits in the immediate value")
    print("      against the accumulator and sets flags without modifying either operand.")
    print("=" * 90)

if __name__ == '__main__':
    main()
