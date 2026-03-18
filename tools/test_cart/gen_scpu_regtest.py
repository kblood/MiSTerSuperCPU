#!/usr/bin/env python3
"""
SuperCPU Register & Feature Test PRG Generator
================================================
Creates a PRG that tests SuperCPU register behavior and 65816 features.
Displays PASS/FAIL for each test on screen.

Tests:
 1. $D0BC SuperCPU detect (non-$FF when regs enabled)
 2. $D0B0 mode detect ($40 = SCPU v2 C64 mode)
 3. $D07E/$D07F register enable/disable gating
 4. $D07A/$D07B speed switching (sw 1MHz / turbo)
 5. $D0B8 speed status readback
 6. $D072/$D073 system 1MHz enable/disable
 7. $D074-$D077 optimization mode + $D0B4 readback
 8. 65C816 native mode: CLC/XCE enter, SEC/XCE return
 9. $D0B6 emulation mode flag readback
10. 65C816 16-bit accumulator (REP #$20, LDA #$1234)

Results are written to screen RAM at $0400 and also to fixed ZP locations
so UART debug can read the pass/fail status.
"""

import struct
import os
import sys

# Add parent's Asm6502 class
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

CODE_BASE = 0x0900
BASIC_START = 0x0801
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SCREEN = 0x0400
ROW = 40

# ZP scratch
ZP_TMP    = 0x02
ZP_TMP2   = 0x03
ZP_RESULT = 0x04  # bit field: bit N = test N passed
ZP_RESULT2 = 0x05
ZP_TESTNUM = 0x06
ZP_STORE16_LO = 0x07
ZP_STORE16_HI = 0x08

# SuperCPU registers
SCPU_DETECT  = 0xD0BC
SCPU_MODE    = 0xD0B0
SCPU_B2      = 0xD0B2
SCPU_B4      = 0xD0B4
SCPU_B5      = 0xD0B5
SCPU_B6      = 0xD0B6
SCPU_B8      = 0xD0B8
SCPU_07E     = 0xD07E
SCPU_07F     = 0xD07F
SCPU_07A     = 0xD07A
SCPU_07B     = 0xD07B
SCPU_072     = 0xD072
SCPU_073     = 0xD073
SCPU_074     = 0xD074
SCPU_075     = 0xD075
SCPU_076     = 0xD076
SCPU_077     = 0xD077

# PETSCII screen codes
def petscii(s):
    """Convert ASCII string to C64 screen codes."""
    result = []
    for c in s:
        if 'A' <= c <= 'Z':
            result.append(ord(c) - 65 + 1)
        elif 'a' <= c <= 'z':
            result.append(ord(c) - 97 + 1)
        elif '0' <= c <= '9':
            result.append(ord(c) - 48 + 48)
        elif c == ' ':
            result.append(32)
        elif c == ':':
            result.append(58)
        elif c == '$':
            result.append(36)
        elif c == '#':
            result.append(35)
        elif c == '/':
            result.append(47)
        elif c == '-':
            result.append(45)
        elif c == '=':
            result.append(61)
        elif c == '.':
            result.append(46)
        elif c == '!':
            result.append(33)
        elif c == '(':
            result.append(40)
        elif c == ')':
            result.append(41)
        else:
            result.append(32)
    return result


class Asm6502:
    """Simple 6502/65816 assembler."""
    def __init__(self, base):
        self._buf = bytearray()
        self._base = base

    def raw(self, *bs):
        self._buf.extend(bs)
        return self

    @property
    def pos(self):
        return len(self._buf)

    @property
    def addr(self):
        return self._base + self.pos

    def build(self):
        return bytes(self._buf)

    # 6502 instructions
    def SEI(self): return self.raw(0x78)
    def CLI(self): return self.raw(0x58)
    def CLD(self): return self.raw(0xD8)
    def CLC(self): return self.raw(0x18)
    def SEC(self): return self.raw(0x38)
    def NOP(self): return self.raw(0xEA)
    def RTS(self): return self.raw(0x60)
    def PHA(self): return self.raw(0x48)
    def PLA(self): return self.raw(0x68)
    def INX(self): return self.raw(0xE8)
    def DEX(self): return self.raw(0xCA)
    def INY(self): return self.raw(0xC8)
    def DEY(self): return self.raw(0x88)
    def TAX(self): return self.raw(0xAA)
    def TXA(self): return self.raw(0x8A)
    def TAY(self): return self.raw(0xA8)
    def TYA(self): return self.raw(0x98)
    def LSR_A(self): return self.raw(0x4A)

    def LDA_imm(self, v): return self.raw(0xA9, v & 0xFF)
    def LDX_imm(self, v): return self.raw(0xA2, v & 0xFF)
    def LDY_imm(self, v): return self.raw(0xA0, v & 0xFF)
    def CMP_imm(self, v): return self.raw(0xC9, v & 0xFF)
    def AND_imm(self, v): return self.raw(0x29, v & 0xFF)
    def ORA_imm(self, v): return self.raw(0x09, v & 0xFF)
    def EOR_imm(self, v): return self.raw(0x49, v & 0xFF)

    def LDA_zp(self, a): return self.raw(0xA5, a & 0xFF)
    def STA_zp(self, a): return self.raw(0x85, a & 0xFF)
    def LDA_abs(self, a): return self.raw(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_abs(self, a): return self.raw(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def LDA_absx(self, a): return self.raw(0xBD, a & 0xFF, (a >> 8) & 0xFF)
    def STA_absx(self, a): return self.raw(0x9D, a & 0xFF, (a >> 8) & 0xFF)
    def STX_abs(self, a): return self.raw(0x8E, a & 0xFF, (a >> 8) & 0xFF)
    def STY_abs(self, a): return self.raw(0x8C, a & 0xFF, (a >> 8) & 0xFF)

    def JMP(self, addr): return self.raw(0x4C, addr & 0xFF, (addr >> 8) & 0xFF)
    def JSR(self, addr): return self.raw(0x20, addr & 0xFF, (addr >> 8) & 0xFF)

    def BNE_back(self, target):
        off = target - (self.pos + 2)
        assert -128 <= off < 0, f"BNE back out of range: {off}"
        return self.raw(0xD0, off & 0xFF)

    def BEQ_fwd(self):
        idx = self.pos; self.raw(0xF0, 0x00); return idx
    def BNE_fwd(self):
        idx = self.pos; self.raw(0xD0, 0x00); return idx
    def BCS_fwd(self):
        idx = self.pos; self.raw(0xB0, 0x00); return idx
    def BCC_fwd(self):
        idx = self.pos; self.raw(0x90, 0x00); return idx

    def fixup_branch(self, placeholder_pos):
        off = self.pos - (placeholder_pos + 2)
        assert 0 < off <= 127, f"Fwd branch offset {off} out of range"
        self._buf[placeholder_pos + 1] = off

    # 65C816 instructions
    def XCE(self): return self.raw(0xFB)      # Exchange Carry and Emulation
    def REP(self, v): return self.raw(0xC2, v & 0xFF)  # Reset Processor Status
    def SEP(self, v): return self.raw(0xE2, v & 0xFF)  # Set Processor Status


def write_screen_string(a, text, row, col):
    """Write PETSCII string to screen RAM."""
    codes = petscii(text)
    pos = SCREEN + row * ROW + col
    for i, code in enumerate(codes):
        a.LDA_imm(code)
        a.STA_abs(pos + i)


def write_pass_fail(a, test_num, row):
    """Write PASS or FAIL at column 34 of given row based on ZP_TMP."""
    pos = SCREEN + row * ROW + 34
    # ZP_TMP: 0 = fail, nonzero = pass
    a.LDA_zp(ZP_TMP)
    br = a.BEQ_fwd()
    # PASS
    for i, code in enumerate(petscii("PASS")):
        a.LDA_imm(code)
        a.STA_abs(pos + i)
    # Set bit in result
    a.LDA_zp(ZP_RESULT)
    a.ORA_imm(1 << (test_num & 7))
    a.STA_zp(ZP_RESULT)
    done = a.BNE_fwd()  # always taken (ORA result nonzero)
    a.fixup_branch(br)
    # FAIL
    for i, code in enumerate(petscii("FAIL")):
        a.LDA_imm(code)
        a.STA_abs(pos + i)
    a.fixup_branch(done)


def write_hex_byte(a, screen_pos):
    """Write A as 2 hex digits to screen. Destroys A, uses ZP_TMP2."""
    hex_chars = petscii("0123456789ABCDEF")
    a.STA_zp(ZP_TMP2)
    # High nibble
    a.LSR_A(); a.LSR_A(); a.LSR_A(); a.LSR_A()
    a.TAX()
    # Write high nibble using indexed lookup
    for i in range(16):
        a.CMP_imm(i)
        br = a.BNE_fwd()
        a.LDA_imm(hex_chars[i])
        a.STA_abs(screen_pos)
        skip = a.BNE_fwd()  # jump to low nibble (always taken since char != 0)
        a.fixup_branch(br)
    # This path shouldn't execute, but fixup the last skip
    # Actually let's simplify - just use a lookup table approach
    # ... the above is too complex. Let me use a simpler hex display.
    pass


def generate():
    a = Asm6502(CODE_BASE)

    # Init
    a.SEI()
    a.CLD()

    # Clear result
    a.LDA_imm(0x00)
    a.STA_zp(ZP_RESULT)
    a.STA_zp(ZP_RESULT2)

    # Set screen colors
    a.LDA_imm(0x00)  # black background
    a.STA_abs(0xD021)
    a.LDA_imm(0x06)  # blue border
    a.STA_abs(0xD020)

    # Clear screen
    a.LDX_imm(0x00)
    loop_clear = a.pos
    a.LDA_imm(0x20)  # space
    a.STA_absx(0x0400)
    a.STA_absx(0x0500)
    a.STA_absx(0x0600)
    a.STA_absx(0x0700)
    a.LDA_imm(0x01)  # white text
    a.STA_absx(0xD800)
    a.STA_absx(0xD900)
    a.STA_absx(0xDA00)
    a.STA_absx(0xDB00)
    a.INX()
    a.BNE_back(loop_clear)

    # Title
    write_screen_string(a, "SUPERCPU REGISTER TEST", 0, 9)
    # Color title yellow
    for i in range(22):
        a.LDA_imm(0x07)
        a.STA_abs(0xD800 + 9 + i)

    # --- TEST 1: $D0BC detect (non-$FF) ---
    write_screen_string(a, "1 D0BC DETECT", 2, 1)
    a.STA_abs(SCPU_07E)  # enable regs first (any write)
    a.LDA_abs(SCPU_DETECT)
    a.CMP_imm(0xFF)
    br = a.BEQ_fwd()
    a.LDA_imm(1)  # pass: not $FF
    a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br)
    a.LDA_imm(0)  # fail: was $FF
    a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 0, 2)

    # Also show the value read
    # (simple: store high/low nibble as screen codes at fixed pos)

    # --- TEST 2: $D0B0 = $40 ---
    write_screen_string(a, "2 D0B0 MODE=$40", 3, 1)
    a.LDA_abs(SCPU_MODE)
    a.CMP_imm(0x40)
    br = a.BEQ_fwd()
    a.LDA_imm(0); a.STA_zp(ZP_TMP); skip = a.BNE_fwd()
    a.fixup_branch(br)
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 1, 3)

    # --- TEST 3: $D07E/$D07F reg enable/disable ---
    write_screen_string(a, "3 D07E/7F REG GATE", 4, 1)
    # Enable regs, read $D0B0 (should be $40)
    a.STA_abs(SCPU_07E)
    a.LDA_abs(SCPU_MODE)
    a.STA_zp(ZP_TMP)  # save enabled value
    # Disable regs
    a.STA_abs(SCPU_07F)
    a.LDA_abs(SCPU_MODE)
    a.STA_zp(ZP_TMP2)  # save disabled value
    # Re-enable for rest of tests
    a.STA_abs(SCPU_07E)
    # Pass if enabled=$40 and disabled != $40
    a.LDA_zp(ZP_TMP)
    a.CMP_imm(0x40)
    br1 = a.BNE_fwd()
    a.LDA_zp(ZP_TMP2)
    a.CMP_imm(0x40)
    br2 = a.BEQ_fwd()
    # Both conditions met: pass
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br1)
    a.fixup_branch(br2)
    a.LDA_imm(0); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 2, 4)

    # --- TEST 4: $D07A/$D07B speed switch ---
    write_screen_string(a, "4 D07A/7B SPEED SW", 5, 1)
    # Write $D07A (force 1MHz), read $D0B8
    a.STA_abs(SCPU_07A)
    a.LDA_abs(SCPU_B8)
    a.STA_zp(ZP_TMP)  # should have bit 7 set ($80 or $C0)
    # Write $D07B (turbo), read $D0B8
    a.STA_abs(SCPU_07B)
    a.LDA_abs(SCPU_B8)
    a.STA_zp(ZP_TMP2)  # should have bit 7 clear
    # Pass if tmp has bit 7 and tmp2 doesn't
    a.LDA_zp(ZP_TMP)
    a.AND_imm(0x80)
    br1 = a.BEQ_fwd()  # fail if bit 7 not set after $D07A
    a.LDA_zp(ZP_TMP2)
    a.AND_imm(0x80)
    br2 = a.BNE_fwd()  # fail if bit 7 still set after $D07B
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br1)
    a.fixup_branch(br2)
    a.LDA_imm(0); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 3, 5)

    # --- TEST 5: $D0B8 combined 1MHz ---
    write_screen_string(a, "5 D0B8 COMBINED 1MHZ", 6, 1)
    # $D0B8 bit6 = combined (sw OR sys). After $D07B, should be 0
    a.STA_abs(SCPU_07B)  # ensure turbo
    a.STA_abs(SCPU_073)  # ensure sys turbo
    a.LDA_abs(SCPU_B8)
    a.AND_imm(0xC0)
    a.CMP_imm(0x00)  # both bits should be 0
    br = a.BNE_fwd()
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br)
    a.LDA_imm(0); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 4, 6)

    # --- TEST 6: $D072/$D073 system 1MHz ---
    write_screen_string(a, "6 D072/73 SYS 1MHZ", 7, 1)
    # Write $D072 (sys 1MHz), check $D0B2 or $D0B8
    a.STA_abs(SCPU_07B)  # ensure sw turbo
    a.STA_abs(SCPU_072)  # sys 1MHz on
    a.LDA_abs(SCPU_B8)
    a.AND_imm(0x40)  # bit 6 = combined should be set (sys is on)
    a.STA_zp(ZP_TMP)
    # Disable sys 1MHz
    a.STA_abs(SCPU_073)
    a.LDA_abs(SCPU_B8)
    a.AND_imm(0x40)  # should be clear now
    a.STA_zp(ZP_TMP2)
    # Pass if tmp nonzero and tmp2 zero
    a.LDA_zp(ZP_TMP)
    br1 = a.BEQ_fwd()
    a.LDA_zp(ZP_TMP2)
    br2 = a.BNE_fwd()
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br1)
    a.fixup_branch(br2)
    a.LDA_imm(0); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 5, 7)

    # --- TEST 7: $D074-$D077 optim modes ---
    write_screen_string(a, "7 D074-77 OPTIM MODE", 8, 1)
    # Write $D074 (mode 00), read $D0B4
    a.STA_abs(SCPU_074)
    a.LDA_abs(SCPU_B4)
    a.AND_imm(0x03)
    a.CMP_imm(0x00)
    br1 = a.BNE_fwd()
    # Write $D077 (mode 11), read $D0B4
    a.STA_abs(SCPU_077)
    a.LDA_abs(SCPU_B4)
    a.AND_imm(0x03)
    a.CMP_imm(0x03)
    br2 = a.BNE_fwd()
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br1)
    a.fixup_branch(br2)
    a.LDA_imm(0); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 6, 8)

    # --- TEST 8: 65C816 native mode enter/exit ---
    write_screen_string(a, "8 CLC/XCE NATIVE MODE", 9, 1)
    # CLC + XCE = enter native mode (carry gets old E flag = 1)
    a.CLC()
    a.XCE()   # Now in native mode, C=1 (old E was 1)
    # Read carry into A: if C=1, we were in emulation before
    a.LDA_imm(0x00)
    # ADC #0 adds carry
    a.raw(0x69, 0x00)  # ADC #$00
    a.STA_zp(ZP_TMP)   # should be 1 (carry was set from old E=1)
    # Return to emulation
    a.SEC()
    a.XCE()   # Back to emulation, C=0 (old E was 0, native)
    # Check: ZP_TMP should be 1
    a.LDA_zp(ZP_TMP)
    write_pass_fail(a, 7, 9)

    # --- TEST 9: $D0B6 emulation mode flag ---
    write_screen_string(a, "9 D0B6 EMU MODE FLAG", 10, 1)
    # In emulation mode, $D0B6 bit 7 should be 1
    a.LDA_abs(SCPU_B6)
    a.AND_imm(0x80)
    a.STA_zp(ZP_TMP)   # should be $80
    # Enter native
    a.CLC()
    a.XCE()
    # $D0B6 bit 7 should be 0
    a.LDA_abs(SCPU_B6)
    a.AND_imm(0x80)
    a.STA_zp(ZP_TMP2)  # should be $00
    # Return to emulation
    a.SEC()
    a.XCE()
    # Pass if tmp=$80 and tmp2=$00
    a.LDA_zp(ZP_TMP)
    a.CMP_imm(0x80)
    br1 = a.BNE_fwd()
    a.LDA_zp(ZP_TMP2)
    br2 = a.BNE_fwd()
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br1)
    a.fixup_branch(br2)
    a.LDA_imm(0); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 0, 10)  # bit 0 of RESULT2

    # --- TEST 10: 65C816 16-bit accumulator ---
    write_screen_string(a, "10 16BIT ACCUM TEST", 11, 1)
    # Enter native mode
    a.CLC()
    a.XCE()
    # REP #$20 = 16-bit accumulator
    a.REP(0x20)
    # LDA #$1234 (16-bit immediate: low byte first)
    a.raw(0xA9, 0x34, 0x12)  # LDA #$1234
    # STA $07/$08 (16-bit store to ZP)
    a.raw(0x85, ZP_STORE16_LO)  # STA ZP_STORE16_LO (stores 2 bytes)
    # SEP #$20 = back to 8-bit accumulator
    a.SEP(0x20)
    # Return to emulation
    a.SEC()
    a.XCE()
    # Check: ZP_STORE16_LO should be $34, ZP_STORE16_HI should be $12
    a.LDA_zp(ZP_STORE16_LO)
    a.CMP_imm(0x34)
    br1 = a.BNE_fwd()
    a.LDA_zp(ZP_STORE16_HI)
    a.CMP_imm(0x12)
    br2 = a.BNE_fwd()
    a.LDA_imm(1); a.STA_zp(ZP_TMP)
    skip = a.BNE_fwd()
    a.fixup_branch(br1)
    a.fixup_branch(br2)
    a.LDA_imm(0); a.STA_zp(ZP_TMP)
    a.fixup_branch(skip)
    write_pass_fail(a, 1, 11)  # bit 1 of RESULT2

    # --- Summary line ---
    write_screen_string(a, "RESULT:", 13, 1)
    # Store result byte at a known screen location for UART reading
    a.LDA_zp(ZP_RESULT)
    a.STA_abs(SCREEN + 13 * ROW + 10)  # raw byte visible

    # --- Color PASS green, FAIL red ---
    # Tests are on rows 2-11, PASS/FAIL at column 34
    for row in range(2, 12):
        color_pos = 0xD800 + row * ROW + 34
        # Read screen code at that position
        a.LDA_abs(SCREEN + row * ROW + 34)
        a.CMP_imm(petscii("P")[0])  # 'P' = first char of PASS
        br = a.BNE_fwd()
        # Green for PASS
        a.LDA_imm(0x05)
        for i in range(4):
            a.STA_abs(color_pos + i)
        skip = a.BNE_fwd()
        a.fixup_branch(br)
        # Red for FAIL
        a.LDA_imm(0x02)
        for i in range(4):
            a.STA_abs(color_pos + i)
        a.fixup_branch(skip)

    # Ensure turbo is back on for normal operation
    a.STA_abs(SCPU_07B)
    a.STA_abs(SCPU_073)

    # Infinite loop (halt here)
    halt = a.pos
    a.JMP(a._base + halt)

    # Build PRG
    code = a.build()

    # BASIC stub: 10 SYS 2304
    basic = bytearray()
    # Next line pointer
    next_line = BASIC_START + 12
    basic.extend(struct.pack('<H', next_line))
    # Line number 10
    basic.extend(struct.pack('<H', 10))
    # SYS token + "2304" + null
    basic.append(0x9E)  # SYS token
    basic.extend(b'2304')
    basic.append(0x00)
    # End of program
    basic.extend(b'\x00\x00')

    # Pad from end of BASIC to CODE_BASE
    pad_len = CODE_BASE - (BASIC_START + len(basic))
    assert pad_len >= 0, f"BASIC stub too large: {len(basic)}"
    basic.extend(b'\x00' * pad_len)

    # Full PRG = load address + basic + code
    prg = struct.pack('<H', BASIC_START) + bytes(basic) + code

    os.makedirs(OUT_DIR, exist_ok=True)
    out_path = os.path.join(OUT_DIR, "scpu_regtest.prg")
    with open(out_path, 'wb') as f:
        f.write(prg)
    print(f"Generated {out_path} ({len(prg)} bytes)")
    print(f"  Code at ${CODE_BASE:04X}, {len(code)} bytes")
    print(f"  Tests: 10 (register readback, speed switching, native mode, 16-bit)")
    return out_path


if __name__ == '__main__':
    generate()
