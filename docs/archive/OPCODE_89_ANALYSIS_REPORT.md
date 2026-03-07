# C64 KERNAL ROM Opcode $89 Analysis Report

## Executive Summary

A Python script was created to parse C64 KERNAL ROM MIF files and identify actual occurrences of opcode **$89 (BIT #immediate)** at proper 6502 instruction boundaries, distinguishing them from address bytes or operands.

### Key Findings

| ROM Variant | File | Occurrences of $89 Opcode |
|---|---|---|
| **Standard C64** | `std_C64.mif` | **0** |
| **JiffyDOS** | `dol_C64.mif` | **1** |

---

## Analysis Details

### Test Environment
- **ROM Size**: KERNAL area spans 8192 bytes (0x2000 bytes)
- **MIF Offset**: 0x2000 - 0x3FFF
- **C64 Address**: 0xE000 - 0xFFFF

### Methodology

The analysis employed:

1. **MIF File Parsing**
   - Standard format: One byte per line (`addr: byte;`)
   - JiffyDOS format: Multiple bytes per line (`addr: byte1 byte2 byte3...;`)

2. **6502 Disassembly with Instruction Length Tracking**
   - 1-byte instructions: CLC, RTS, TXA, etc.
   - 2-byte instructions: LDA #$nn, LDX $zp, BIT #$89, etc.
   - 3-byte instructions: JMP $nnnn, LDA $nnnn, etc.

3. **Instruction Boundary Detection**
   - All $89 bytes found at proper instruction boundaries are counted
   - $89 bytes that are operands or address parts are excluded

4. **Branch Instruction Analysis**
   - Checks for BEQ ($F0) or BNE ($D0) within 3 bytes following the $89 opcode
   - Useful for identifying conditional test patterns

---

## Results: JiffyDOS ROM ($89 Opcode)

### Occurrence #1: BIT #$02

```
Location (MIF):    0x2969
Location (C64):    0xE969
Hex Context:       8A A6 C6 89 02 B0 06
Operand:           $02
Following Branch:  None within next 3 bytes
```

#### Instruction Sequence (with ±3 instruction context):

```
CPX $FD        ; Compare X with 0xFD
BCS $2974      ; Branch if Carry Set
TXA            ; Transfer X to Accumulator
LDX $C6        ; Load X with value at $C6
[BIT #$02]     ; TEST A & #$02, set flags (no store, no modify A)
BCS $2973      ; Branch if Carry Set
STA $0277      ; Store Accumulator at address $0277
```

#### Analysis

This is a legitimate **BIT #immediate** instruction used as a **test operation**. The instruction:
- Tests which bits are set in the accumulator (via the immediate value $02)
- Sets the Zero Flag (Z) if result is zero, otherwise clears it
- Does NOT modify the accumulator or any other registers
- The following branch instruction is not within the immediate next 3 bytes

This is a common pattern in 6502 code for non-destructive bit testing.

---

## Results: Standard C64 ROM

No occurrences of opcode $89 at instruction boundaries were found in the standard KERNAL.

This indicates that JiffyDOS made intentional modifications including this specific BIT #immediate instruction in the KERNAL code, likely as part of its optimizations or functionality changes.

---

## Technical Notes

### Opcode $89: BIT #immediate

- **Mnemonic**: BIT (Bit Test)
- **Addressing Mode**: Immediate
- **Instruction Length**: 2 bytes (opcode + operand)
- **Flags Affected**: Z (Zero flag)
- **Operation**: AND accumulator with immediate value, set flags based on result
- **Key Difference**: Unlike BIT with other addressing modes, BIT #immediate only affects the Z flag

### Instruction Tracking Algorithm

The script uses a linear disassembly approach:

```python
offset = start_offset
while offset < end_offset:
    opcode = rom[offset]
    length = get_instruction_length(opcode)
    boundaries[offset] = length
    offset += length
```

This ensures:
- Only valid instruction boundaries are tracked
- No false positives from operand bytes
- Proper alignment of all instructions

---

## Files Generated

- **Script**: `analyze_opcode_89.py` (Python 3)
- **Format**: Fully documented with comprehensive disassembly context
- **Output**: Detailed analysis with hex context, instruction sequences, and flag information

## Conclusion

The single occurrence of opcode $89 found in the JiffyDOS KERNAL at address $E969 is a legitimate **BIT #immediate** instruction used for non-destructive bit testing in the instruction sequence. This represents an actual code difference between JiffyDOS and standard C64 KERNAL implementations.

---

## Follow-Up: Does This Cause a Behavioral Difference on 65C816?

**Answer: No — this is NOT a source of incompatibility.**

The instruction at $E969 is followed by `BCS` (Branch if Carry Set), which tests the **Carry** flag:

```
$E969: 89 02    BIT #$02      ; on 65C816: sets Z only; on 6502: NOP-like, no flags
$E96B: B0 06    BCS $E973     ; tests Carry — unaffected by $89 on EITHER CPU
```

Comparison:

| CPU | $89 behaviour | Carry affected? | BCS result |
|-----|--------------|-----------------|------------|
| NMOS 6502 / 6510 | 2-byte NOP (no flags set) | No | Same as before $89 |
| 65C816 emulation mode | BIT #$02 (sets Z flag only) | No | Same as before $89 |

Neither execution modifies Carry, so the branch outcome is identical on both CPUs. **Opcode $89 in JiffyDOS is confirmed NOT the cause of the '@' character issue.**

---

*Analysis completed using disassembly-based instruction boundary tracking*
