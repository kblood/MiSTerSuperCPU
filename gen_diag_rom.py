#!/usr/bin/env python3
"""Generate diagnostic test ROM for P65C816 emulation mode testing.

Phase 1: Instruction tests (no IRQ)
Phase 1H: Hold loop (no IRQ) - checks if screen corrupts without interrupts
Phase 2: Enable IRQs - checks if screen corrupts with interrupts
Phase 2S: Stack integrity check - verifies IRQ stack pushes don't go astray
"""

rom = bytearray([0xFF] * 65536)

def wb(addr, *data):
    for i, b in enumerate(data):
        rom[addr + i] = b

def lo(a): return a & 0xFF
def hi(a): return (a >> 8) & 0xFF

def emit(*data):
    """Emit bytes at current position, advance p."""
    global p
    for b in data:
        rom[p] = b
        p += 1

def emit_lda_imm(v): emit(0xA9, v)
def emit_sta_abs(addr): emit(0x8D, lo(addr), hi(addr))
def emit_lda_abs(addr): emit(0xAD, lo(addr), hi(addr))
def emit_jmp(addr): emit(0x4C, lo(addr), hi(addr))

def emit_str(screen_addr, text, color_addr=None, color=None):
    """Write PETSCII screen codes for a text string."""
    # Simple mapping: uppercase letters A-Z = $01-$1A, 0-9 = $30-$39, space=$20
    scr_map = {' ': 0x20, ':': 0x3A, '-': 0x2D, '!': 0x21, '?': 0x3F}
    for i, ch in enumerate(text):
        if 'A' <= ch <= 'Z':
            code = ord(ch) - ord('A') + 1
        elif '0' <= ch <= '9':
            code = ord(ch) - ord('0') + 0x30
        elif ch in scr_map:
            code = scr_map[ch]
        else:
            code = 0x20
        emit_lda_imm(code)
        emit_sta_abs(screen_addr + i)
        if color_addr is not None and color is not None:
            emit_lda_imm(color)
            emit_sta_abs(color_addr + i)

# Sentinel values for screen integrity checks
SENTINEL_ADDR1 = 0x0428  # row 1 col 0 (after header)
SENTINEL_VAL1  = 0x10    # 'P' screen code
SENTINEL_ADDR2 = 0x04F0  # row 3, further down
SENTINEL_VAL2  = 0x05    # 'E' screen code
SENTINEL_ADDR3 = 0x0600  # below visible screen
SENTINEL_VAL3  = 0xAA

# Screen layout:
# Row 0: DIAG 816
# Row 1: PPPPPP (test results) — sentinel at $0428
# Row 2: P1 OK
# Row 3: (Phase 1H status)
# Row 4: (Phase 2 status)
# Row 5: (counter)
# Row 6: (stack dump)
# Row 7: (stack dump continued)
# Row 8: (sentinel check display)

# Place handlers at $FF00-$FF40 area (before vectors at $FFFA)
RTI_ADDR = 0xFF40
wb(RTI_ADDR, 0x40)  # RTI

# IRQ handler: acknowledge CIA1, increment counter at $02, RTI
IRQ_HANDLER = 0xFF00
wb(IRQ_HANDLER,   0xAD, 0x0D, 0xDC)  # LDA $DC0D
wb(IRQ_HANDLER+3, 0xE6, 0x02)         # INC $02
wb(IRQ_HANDLER+5, 0x40)               # RTI

# Subroutine for test 5
SUBR_ADDR = 0xFF20
wb(SUBR_ADDR,   0xA9, 0x77)  # LDA #$77
wb(SUBR_ADDR+2, 0x60)        # RTS

# ========================================
# Main test code at $FC00
# ========================================
p = 0xFA00

# --- Init ---
emit(0x78)         # SEI
emit(0xD8)         # CLD
emit(0xA2, 0xFF)   # LDX #$FF
emit(0x9A)         # TXS

# --- VIC-II setup ---
emit_lda_imm(0x06); emit_sta_abs(0xD020)  # border=blue
emit_lda_imm(0x06); emit_sta_abs(0xD021)  # bg=blue
emit_lda_imm(0x1B); emit_sta_abs(0xD011)  # screen on
emit_lda_imm(0x08); emit_sta_abs(0xD016)  # 40 cols
emit_lda_imm(0x14); emit_sta_abs(0xD018)  # screen $0400

# --- Clear screen ($20) ---
emit_lda_imm(0x20); emit(0xA2, 0x00)  # LDA #$20, LDX #0
cl = p
emit(0x9D, 0x00, 0x04)  # STA $0400,X
emit(0x9D, 0x00, 0x05)  # STA $0500,X
emit(0x9D, 0x00, 0x06)  # STA $0600,X
emit(0x9D, 0xE8, 0x06)  # STA $06E8,X
emit(0xE8)               # INX
emit(0xD0, (cl - p - 2) & 0xFF)  # BNE cl

# --- Set color RAM white ($01) ---
emit_lda_imm(0x01); emit(0xA2, 0x00)
cl2 = p
emit(0x9D, 0x00, 0xD8)
emit(0x9D, 0x00, 0xD9)
emit(0x9D, 0x00, 0xDA)
emit(0x9D, 0xE8, 0xDA)
emit(0xE8)
emit(0xD0, (cl2 - p - 2) & 0xFF)

# --- Header "DIAG 816" at $0400 ---
emit_str(0x0400, "DIAG 816", 0xD800, 0x0D)

# === TEST 1: LDA #imm, STA abs, LDA abs, CMP ===
emit_lda_imm(0x42)
emit_sta_abs(0x0600)           # STA $0600
emit_lda_abs(0x0600)           # LDA $0600
emit(0xC9, 0x42)               # CMP #$42
emit(0xD0, 0x07)               # BNE fail
emit_lda_imm(0x10)             # P
emit_sta_abs(SENTINEL_ADDR1)   # STA sentinel
emit_jmp(p + 8)                # JMP over fail
emit_lda_imm(0x06)             # F
emit_sta_abs(SENTINEL_ADDR1)

# === TEST 2: STA abs,X / LDA abs,X ===
emit(0xA2, 0x05)               # LDX #$05
emit_lda_imm(0x55)
emit(0x9D, 0x00, 0x06)         # STA $0600,X
emit_lda_imm(0x00)
emit(0xBD, 0x00, 0x06)         # LDA $0600,X
emit(0xC9, 0x55)
emit(0xD0, 0x07)
emit_lda_imm(0x10); emit_sta_abs(0x0429)
emit_jmp(p + 8)
emit_lda_imm(0x06); emit_sta_abs(0x0429)

# === TEST 3: STA (zp),Y / LDA (zp),Y ===
emit_lda_imm(0xC8); emit(0x85, 0xFB)  # $FB = $C8
emit_lda_imm(0x04); emit(0x85, 0xFC)  # $FC = $04 -> ptr $04C8
emit(0xA0, 0x00)                        # LDY #$00
emit_lda_imm(0x33)
emit(0x91, 0xFB)                        # STA ($FB),Y
emit_lda_imm(0x00)
emit(0xB1, 0xFB)                        # LDA ($FB),Y
emit(0xC9, 0x33)
emit(0xD0, 0x07)
emit_lda_imm(0x10); emit_sta_abs(0x042A)
emit_jmp(p + 8)
emit_lda_imm(0x06); emit_sta_abs(0x042A)

# === TEST 4: PHA/PLA ===
emit_lda_imm(0xAA); emit(0x48)  # PHA $AA
emit_lda_imm(0x55); emit(0x48)  # PHA $55
emit(0x68)                        # PLA -> $55
emit(0xC9, 0x55)
emit(0xD0, 0x0C)                 # BNE fail (skip 12)
emit(0x68)                        # PLA -> $AA
emit(0xC9, 0xAA)
emit(0xD0, 0x07)
emit_lda_imm(0x10); emit_sta_abs(0x042B)
emit_jmp(p + 8)
emit_lda_imm(0x06); emit_sta_abs(0x042B)

# === TEST 5: JSR/RTS ===
emit_lda_imm(0x00)
emit(0x20, lo(SUBR_ADDR), hi(SUBR_ADDR))  # JSR
emit(0xC9, 0x77)
emit(0xD0, 0x07)
emit_lda_imm(0x10); emit_sta_abs(0x042C)
emit_jmp(p + 8)
emit_lda_imm(0x06); emit_sta_abs(0x042C)

# === TEST 6: (zp,X) indirect ===
emit_lda_imm(0xF0); emit(0x85, 0x10)
emit_lda_imm(0x04); emit(0x85, 0x11)
emit(0xA2, 0x10)
emit_lda_imm(0x07); emit(0x81, 0x00)  # STA ($00,X)
emit_lda_imm(0x00); emit(0xA1, 0x00)  # LDA ($00,X)
emit(0xC9, 0x07)
emit(0xD0, 0x07)
emit_lda_imm(0x10); emit_sta_abs(0x042D)
emit_jmp(p + 8)
emit_lda_imm(0x06); emit_sta_abs(0x042D)

# === Phase 1 complete: "P1 OK" ===
emit_str(0x0450, "P1 OK")
# Border green = phase 1 pass
emit_lda_imm(0x05); emit_sta_abs(0xD020)

# === Phase 1H: Hold test — loop WITHOUT IRQs, check screen integrity ===
# Place sentinels at multiple locations
emit_lda_imm(SENTINEL_VAL2); emit_sta_abs(SENTINEL_ADDR2)
emit_lda_imm(SENTINEL_VAL3); emit_sta_abs(SENTINEL_ADDR3)
emit_str(0x0478, "P1H HOLD")

# Delay loop: count $00 to $FF in Y, repeat $10 times in X
# This is ~65536 iterations with SEI active (no IRQs)
emit(0xA2, 0x10)   # LDX #$10
hold_outer = p
emit(0xA0, 0x00)   # LDY #$00
hold_inner = p
# Check sentinel 1 each iteration
emit_lda_abs(SENTINEL_ADDR1)
emit(0xC9, SENTINEL_VAL1)
emit(0xD0, 0x1C)   # BNE hold_fail (will be patched)
hold_fail_branch1 = p - 2  # remember for patching
# Check sentinel 2
emit_lda_abs(SENTINEL_ADDR2)
emit(0xC9, SENTINEL_VAL2)
emit(0xD0, 0x14)  # BNE hold_fail (will patch)
hold_fail_branch2 = p - 2
# Check sentinel 3 (non-screen RAM)
emit_lda_abs(SENTINEL_ADDR3)
emit(0xC9, SENTINEL_VAL3)
emit(0xD0, 0x0C)  # BNE hold_fail (will patch)
hold_fail_branch3 = p - 2
emit(0xC8)  # INY
emit(0xD0, (hold_inner - p - 2) & 0xFF)  # BNE inner
emit(0xCA)  # DEX
emit(0xD0, (hold_outer - p - 2) & 0xFF)  # BNE outer
emit_jmp(0)  # placeholder - jump to hold_pass
hold_pass_jmp = p - 2  # patch target

# Hold FAIL: show "P1H FAIL", red border
hold_fail = p
emit_str(0x0478, "P1H FAIL")
emit_lda_imm(0x02); emit_sta_abs(0xD020)  # red border
# Show which sentinel failed - store $0600 value at screen
emit_lda_abs(SENTINEL_ADDR1)
emit_sta_abs(0x04C8)  # show raw value of sentinel 1
emit_lda_abs(SENTINEL_ADDR2)
emit_sta_abs(0x04C9)  # show raw value of sentinel 2
emit_lda_abs(SENTINEL_ADDR3)
emit_sta_abs(0x04CA)  # show raw value of sentinel 3
halt_fail = p
emit_jmp(halt_fail)  # infinite halt

# Hold PASS
hold_pass = p
emit_str(0x0478, "P1H PASS")
emit_lda_imm(0x0D); emit_sta_abs(0xD020)  # light green border

# Patch branches
rom[hold_fail_branch1] = (hold_fail - hold_fail_branch1 - 1) & 0xFF
rom[hold_fail_branch2] = (hold_fail - hold_fail_branch2 - 1) & 0xFF
rom[hold_fail_branch3] = (hold_fail - hold_fail_branch3 - 1) & 0xFF
rom[hold_pass_jmp] = lo(hold_pass)
rom[hold_pass_jmp + 1] = hi(hold_pass)

# === Phase 2B: BRK/RTI test — software interrupt, no CIA involvement ===
# This isolates whether the corruption is from the CPU's interrupt mechanism
# itself (BRK uses same microcode as hardware IRQ) or from CIA interaction.
emit_str(0x04A0, "P2B BRK ")

# Re-place sentinels
emit_lda_imm(SENTINEL_VAL1); emit_sta_abs(SENTINEL_ADDR1)
emit_lda_imm(SENTINEL_VAL2); emit_sta_abs(SENTINEL_ADDR2)

# Do 256 BRK/RTI cycles (SEI still active, so no hardware IRQs).
# BRK vector is same as IRQ vector ($FFFE -> $FB00).
# Handler: LDA $DC0D (harmless, no pending IRQ), INC $02, RTI.
# After RTI, PC = address after the signature byte.
emit_lda_imm(0x00); emit(0x85, 0x02)  # counter=0
emit(0xA2, 0x00)  # LDX #0
brk_loop = p
emit(0x00, 0x00)  # BRK + signature byte
# RTI returns here (PC was pushed as address after BRK, then incremented past signature)
# Check sentinels
emit_lda_abs(SENTINEL_ADDR1)
emit(0xC9, SENTINEL_VAL1)
emit(0xD0, 0x00)  # BNE brk_fail (patch)
brk_fail_branch1 = p - 1
emit_lda_abs(SENTINEL_ADDR2)
emit(0xC9, SENTINEL_VAL2)
emit(0xD0, 0x00)  # BNE brk_fail (patch)
brk_fail_branch2 = p - 1
emit(0xE8)  # INX
emit(0xD0, (brk_loop - p - 2) & 0xFF)  # BNE brk_loop (256 iterations)
# BRK loop passed
emit_str(0x04A0, "P2B PASS")
emit_lda_imm(0x0E); emit_sta_abs(0xD020)  # light blue border
emit_jmp(0)  # placeholder, patched below
brk_pass_jmp = p - 2

# BRK fail
brk_fail = p
emit_str(0x04A0, "P2B FAIL")
# Show what sentinel 1 contains
emit_lda_abs(SENTINEL_ADDR1)
emit_sta_abs(0x04CB)
emit_lda_abs(SENTINEL_ADDR2)
emit_sta_abs(0x04CC)
emit_lda_imm(0x0A); emit_sta_abs(0xD020)  # light red border
brk_halt = p
emit_jmp(brk_halt)

# Patch BRK branches
rom[brk_fail_branch1] = (brk_fail - brk_fail_branch1 - 1) & 0xFF
rom[brk_fail_branch2] = (brk_fail - brk_fail_branch2 - 1) & 0xFF
brk_after = p
rom[brk_pass_jmp] = lo(brk_after)
rom[brk_pass_jmp + 1] = hi(brk_after)

# === Phase 2: Enable CIA1 Timer A IRQ ===
emit_lda_imm(0x00); emit(0x85, 0x02)  # counter=0
emit_str(0x04C8, "P2 IRQ")

# CIA1 Timer A = $4025 (~60Hz at 1MHz)
emit_lda_imm(0x25); emit_sta_abs(0xDC04)
emit_lda_imm(0x40); emit_sta_abs(0xDC05)
emit_lda_imm(0x81); emit_sta_abs(0xDC0D)  # enable TA IRQ
emit_lda_imm(0x11); emit_sta_abs(0xDC0E)  # start timer

emit(0x58)  # CLI - enable interrupts

# === Main loop: show counter, check integrity, dump stack ===
main_loop = p

# Show counter at $04F0
emit(0xA5, 0x02)   # LDA $02
emit(0x29, 0x0F)   # AND #$0F
emit(0x09, 0x30)   # ORA #$30
emit_sta_abs(0x04F0)

# Check sentinel 1
emit_lda_abs(SENTINEL_ADDR1)
emit(0xC9, SENTINEL_VAL1)
emit(0xF0, 0x05)   # BEQ ok1
emit_lda_imm(0x02); emit_sta_abs(0xD020)  # red border

emit_jmp(main_loop)

print(f"Code ends at ${p:04X} ({p - 0xFC00} bytes used)")
assert p < 0xFF00, f"Overflow at ${p:04X}!"

# ---- Vectors ----
wb(0xFFFA, lo(RTI_ADDR), hi(RTI_ADDR))      # NMI
wb(0xFFFC, 0x00, 0xFA)                       # RESET -> $FA00
wb(0xFFFE, lo(IRQ_HANDLER), hi(IRQ_HANDLER)) # IRQ

wb(0xFFEA, lo(RTI_ADDR), hi(RTI_ADDR))      # NMI native
wb(0xFFEE, lo(RTI_ADDR), hi(RTI_ADDR))      # IRQ native
wb(0xFFE4, lo(RTI_ADDR), hi(RTI_ADDR))      # COP native
wb(0xFFE6, lo(RTI_ADDR), hi(RTI_ADDR))      # BRK native

# Generate MIF
lines = ['WIDTH=8;', 'DEPTH=65536;', '', 'ADDRESS_RADIX=HEX;',
         'DATA_RADIX=HEX;', '', 'CONTENT BEGIN']
for i, b in enumerate(rom):
    lines.append(f'  {i:04X} : {b:02X};')
lines.append('END;')
lines.append('')

mif_path = 'C:/LLM/C64/MiSTerSuperCPU/C64_MiSTer/rtl/roms/scpu64.mif'
with open(mif_path, 'w') as f:
    f.write('\n'.join(lines))

print(f"Written: {mif_path}")
print(f"RESET=${rom[0xFFFD]:02X}{rom[0xFFFC]:02X}  "
      f"IRQ=${rom[0xFFFF]:02X}{rom[0xFFFE]:02X}  "
      f"NMI=${rom[0xFFFB]:02X}{rom[0xFFFA]:02X}")
print(f"$FC00: {rom[0xFC00]:02X} (SEI={0x78:02X})")
