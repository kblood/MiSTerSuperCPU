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

# RTI fingerprint bytes: chosen so all tested permutations stay in ROM ($E000-$FFFF)
# Keep P with I=1 to avoid unrelated IRQ re-entry during standalone RTI.
RTI_SIG_H = 0xE0
RTI_SIG_L = 0xEC
RTI_SIG_P = 0xFC
RTI_SIG_N0 = 0xF0  # stack wrap byte at $0100
RTI_SIG_N1 = 0xF4  # stack wrap byte at $0101

# (target_address, marker_screen_code)
RTI_TRAMPOLINES = [
    ((RTI_SIG_H << 8) | RTI_SIG_L, 0x31),  # expected: H:L
    ((RTI_SIG_L << 8) | RTI_SIG_H, 0x32),  # swapped: L:H
    ((RTI_SIG_H << 8) | RTI_SIG_P, 0x33),  # off-by-one: H:P
    ((RTI_SIG_P << 8) | RTI_SIG_H, 0x34),  # off-by-one: P:H
    ((RTI_SIG_L << 8) | RTI_SIG_P, 0x35),  # off-by-one: L:P
    ((RTI_SIG_P << 8) | RTI_SIG_L, 0x36),  # off-by-one: P:L
    ((RTI_SIG_N0 << 8) | RTI_SIG_H, 0x37), # wrap (+1): N0:H
    ((RTI_SIG_N1 << 8) | RTI_SIG_N0, 0x38),# wrap (+2): N1:N0
]

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

# Place handlers at $FF00-$FF70 area (before vectors at $FFFA)
RTI_ADDR = 0xFF40
# Marker RTI stub at $FF40:
# if CPU mistakenly returns to $FF40, this writes '9' at $043E and hard-loops.
wb(RTI_ADDR,   0xA9, 0x02)            # LDA #red
wb(RTI_ADDR+2, 0x8D, 0x20, 0xD0)      # STA $D020
wb(RTI_ADDR+5, 0xA9, 0x39)            # LDA #'9'
wb(RTI_ADDR+7, 0x8D, 0x3E, 0x04)      # STA $043E
wb(RTI_ADDR+10, 0x4C, lo(RTI_ADDR), hi(RTI_ADDR))  # JMP $FF40

NMI_ADDR = 0xFF60
# Dedicated NMI trap (separate from $FF40 return trap) so we can distinguish sources.
wb(NMI_ADDR,   0xA9, 0x03)            # LDA #cyan
wb(NMI_ADDR+2, 0x8D, 0x20, 0xD0)      # STA $D020
wb(NMI_ADDR+5, 0xA9, 0x0E)            # LDA #'N' (screen code)
wb(NMI_ADDR+7, 0x8D, 0x3D, 0x04)      # STA $043D
wb(NMI_ADDR+10, 0x40)                 # RTI

# IRQ/BRK handler for diagnostics:
# - increments $02 on each entry
# - acknowledges CIA1 IRQ flags
# - conditionally stops Timer A when ZP $04 != 0 (one-shot mode)
# - captures pushed bytes from stack
# - returns via RTI
IRQ_HANDLER = 0xFF00
wb(IRQ_HANDLER,    0xE6, 0x02)              # INC $02
wb(IRQ_HANDLER+2,  0xAD, 0x0D, 0xDC)        # LDA $DC0D (ack CIA IRQ flags)
wb(IRQ_HANDLER+5,  0xA5, 0x04)              # LDA $04 (IRQ mode)
wb(IRQ_HANDLER+7,  0xF0, 0x05)              # BEQ skip_stop
wb(IRQ_HANDLER+9,  0xA9, 0x00)              # LDA #$00
wb(IRQ_HANDLER+11, 0x8D, 0x0E, 0xDC)        # STA $DC0E (stop Timer A)
wb(IRQ_HANDLER+14, 0xAD, 0xFD, 0x01)        # skip_stop: LDA pushed P
wb(IRQ_HANDLER+17, 0x8D, 0x43, 0x04)        # STA $0443
wb(IRQ_HANDLER+20, 0xAD, 0xFE, 0x01)        # LDA pushed PCL
wb(IRQ_HANDLER+23, 0x8D, 0x40, 0x04)        # STA $0440
wb(IRQ_HANDLER+26, 0xAD, 0xFF, 0x01)        # LDA pushed PCH
wb(IRQ_HANDLER+29, 0x8D, 0x41, 0x04)        # STA $0441
wb(IRQ_HANDLER+32, 0x40)                    # RTI

# Subroutine for test 5 (must not overlap IRQ handler bytes at $FF00-$FF29)
SUBR_ADDR = 0xFF30
wb(SUBR_ADDR,   0xA9, 0x77)  # LDA #$77
wb(SUBR_ADDR+2, 0x60)        # RTS

# RTI fingerprint trampolines (patched later to jump back into test code)
for addr, marker in RTI_TRAMPOLINES:
    wb(addr, 0xA9, marker, 0x85, 0x03, 0x8D, 0x3E, 0x04, 0x4C, 0x00, 0x00)  # LDA #m; STA $03/$043E; JMP ????

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
emit_lda_imm(0x04); emit_sta_abs(0xD020)  # border=purple (ROM signature)
emit_lda_imm(0x00); emit_sta_abs(0xD021)  # bg=black (ROM signature)
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

# --- Header (explicit ROM signature) ---
emit_str(0x0400, "ROM V22 ACTIVE", 0xD800, 0x07)

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

# === Phase 1 complete: "P1 V22" ===
emit_str(0x0450, "P1 V22")
# Border green = phase 1 pass
emit_lda_imm(0x05); emit_sta_abs(0xD020)

# === Phase 1H: Hold test — loop WITHOUT IRQs, check screen integrity ===
# Place sentinels at multiple locations
emit_lda_imm(SENTINEL_VAL2); emit_sta_abs(SENTINEL_ADDR2)
emit_lda_imm(SENTINEL_VAL3); emit_sta_abs(SENTINEL_ADDR3)
emit_str(0x0478, "V22 HOLD")

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
hold_fail_branch1 = p - 1  # remember branch offset byte for patching
# Check sentinel 2
emit_lda_abs(SENTINEL_ADDR2)
emit(0xC9, SENTINEL_VAL2)
emit(0xD0, 0x14)  # BNE hold_fail (will patch)
hold_fail_branch2 = p - 1
# Check sentinel 3 (non-screen RAM)
emit_lda_abs(SENTINEL_ADDR3)
emit(0xC9, SENTINEL_VAL3)
emit(0xD0, 0x0C)  # BNE hold_fail (will patch)
hold_fail_branch3 = p - 1
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

# Hold PASS (orange border = new ROM signature reached hold-pass)
hold_pass = p
emit_str(0x0478, "V22 PASS")
emit_lda_imm(0x08); emit_sta_abs(0xD020)  # orange border

# Patch branches
rom[hold_fail_branch1] = (hold_fail - hold_fail_branch1 - 1) & 0xFF
rom[hold_fail_branch2] = (hold_fail - hold_fail_branch2 - 1) & 0xFF
rom[hold_fail_branch3] = (hold_fail - hold_fail_branch3 - 1) & 0xFF
rom[hold_pass_jmp] = lo(hold_pass)
rom[hold_pass_jmp + 1] = hi(hold_pass)

# === TEST 7: RTI fingerprint ===
# Pre-fill stack bytes directly (no PHA/PHP), execute RTI, and let ROM
# trampolines report which byte pair became the restored PC.
emit_lda_imm(0x00); emit(0x85, 0x03)  # clear marker
emit_lda_imm(0x20); emit_sta_abs(0x043E)  # clear on-screen RTI marker
emit_lda_imm(0x07); emit_sta_abs(0xD020)  # yellow: entered test 7
emit_lda_imm(RTI_SIG_N0); emit_sta_abs(0x0100)  # wrap byte +1
emit_lda_imm(RTI_SIG_N1); emit_sta_abs(0x0101)  # wrap byte +2
emit_lda_imm(RTI_SIG_P); emit_sta_abs(0x01FD)  # stack P
emit_lda_imm(RTI_SIG_L); emit_sta_abs(0x01FE)  # stack PCL
emit_lda_imm(RTI_SIG_H); emit_sta_abs(0x01FF)  # stack PCH
emit(0xA2, 0xFC); emit(0x9A)  # LDX #$FC / TXS

# Pre-checks: confirm TXS and stack writes before executing RTI.
emit(0xBA)            # TSX
emit(0xE0, 0xFC)      # CPX #$FC
emit(0xD0, 0x00)      # BNE tsx_fail (patched)
tsx_fail_branch = p - 1

emit_lda_abs(0x01FD)
emit(0xC9, RTI_SIG_P)
emit(0xD0, 0x00)      # BNE p_fail (patched)
p_fail_branch = p - 1

emit_lda_abs(0x01FE)
emit(0xC9, RTI_SIG_L)
emit(0xD0, 0x00)      # BNE l_fail (patched)
l_fail_branch = p - 1

emit_lda_abs(0x01FF)
emit(0xC9, RTI_SIG_H)
emit(0xD0, 0x00)      # BNE h_fail (patched)
h_fail_branch = p - 1

emit_jmp(0)           # jump over fail handlers (patched)
precheck_ok_jmp = p - 2

tsx_fail = p
emit_lda_imm(0x02); emit_sta_abs(0xD020)
emit_lda_imm(0x18); emit_sta_abs(0x043E)  # 'X' = TXS/SP mismatch
halt_tsx = p
emit_jmp(halt_tsx)

p_fail = p
emit_lda_imm(0x02); emit_sta_abs(0xD020)
emit_lda_imm(0x01); emit_sta_abs(0x043E)  # 'A' = $01FD mismatch
halt_p = p
emit_jmp(halt_p)

l_fail = p
emit_lda_imm(0x02); emit_sta_abs(0xD020)
emit_lda_imm(0x02); emit_sta_abs(0x043E)  # 'B' = $01FE mismatch
halt_l = p
emit_jmp(halt_l)

h_fail = p
emit_lda_imm(0x02); emit_sta_abs(0xD020)
emit_lda_imm(0x03); emit_sta_abs(0x043E)  # 'C' = $01FF mismatch
halt_h = p
emit_jmp(halt_h)

rti_execute = p
rom[precheck_ok_jmp] = lo(rti_execute)
rom[precheck_ok_jmp + 1] = hi(rti_execute)
rom[tsx_fail_branch] = (tsx_fail - tsx_fail_branch - 1) & 0xFF
rom[p_fail_branch] = (p_fail - p_fail_branch - 1) & 0xFF
rom[l_fail_branch] = (l_fail - l_fail_branch - 1) & 0xFF
rom[h_fail_branch] = (h_fail - h_fail_branch - 1) & 0xFF

emit(0x40)                            # RTI
# If RTI somehow falls through, store marker '0'
emit_lda_imm(0x30); emit(0x85, 0x03)

# Trampolines jump back here
test7_probe_return = p
for addr, _marker in RTI_TRAMPOLINES:
    rom[addr + 8] = lo(test7_probe_return)
    rom[addr + 9] = hi(test7_probe_return)

emit_lda_imm(0x0E); emit_sta_abs(0xD020)  # light blue: returned from RTI
emit(0xA5, 0x03)                      # LDA $03 (digit '1'..'6' / '0')
emit_sta_abs(0x043E)                  # show RTI path marker on screen
emit(0xC9, 0x31)                      # expected marker = '1' (H:L)
emit(0xD0, 0x07)                      # BNE fail
emit_lda_imm(0x10); emit_sta_abs(0x042E)  # 'P' for test 7
emit_jmp(p + 8)
emit_lda_imm(0x06); emit_sta_abs(0x042E)  # 'F'

# === TEST 8: Single BRK ===
# Do exactly ONE BRK. If we reach the instruction after the signature
# byte, BRK+RTI works. Show result on screen.
# Clear BRK diagnostics region
emit_lda_imm(0x00); emit(0x85, 0x02)      # clear counter
emit_lda_imm(0x20); emit_sta_abs(0x043F)  # low-byte class marker
emit_lda_imm(0x20); emit_sta_abs(0x0440)  # captured pushed PCL (raw)
emit_lda_imm(0x20); emit_sta_abs(0x0441)  # captured pushed PCH (raw)
emit_lda_imm(0x20); emit_sta_abs(0x0442)  # high-byte class marker
emit_lda_imm(0x20); emit_sta_abs(0x0443)  # captured pushed P (raw)
emit(0xA2, 0xFF); emit(0x9A)              # force SP=$01FF before BRK

# Record where the BRK return should land
emit(0x00, 0xEA)  # BRK + signature byte ($EA = NOP, just as padding)
# *** RTI should return HERE ***
brk_return = p
# Classify captured BRK low byte at $043F:
# '0' exact, '1' expected-1, '2' expected+1, '3' expected+2, 'X' other
emit_lda_abs(0x0440)
emit(0xC9, lo(brk_return))
emit(0xF0, 0x00); beq_low_exact = p - 1
emit(0xC9, (lo(brk_return) - 1) & 0xFF)
emit(0xF0, 0x00); beq_low_m1 = p - 1
emit(0xC9, (lo(brk_return) + 1) & 0xFF)
emit(0xF0, 0x00); beq_low_p1 = p - 1
emit(0xC9, (lo(brk_return) + 2) & 0xFF)
emit(0xF0, 0x00); beq_low_p2 = p - 1
emit_lda_imm(0x18)  # 'X'
emit(0xD0, 0x00); bne_low_store_x = p - 1
low_exact = p
emit_lda_imm(0x30)  # '0'
emit(0xD0, 0x00); bne_low_store_0 = p - 1
low_m1 = p
emit_lda_imm(0x31)  # '1'
emit(0xD0, 0x00); bne_low_store_1 = p - 1
low_p1 = p
emit_lda_imm(0x32)  # '2'
emit(0xD0, 0x00); bne_low_store_2 = p - 1
low_p2 = p
emit_lda_imm(0x33)  # '3'
low_store = p
emit_sta_abs(0x043F)

# Classify captured BRK high byte at $0442: '0' exact, 'X' other
emit_lda_abs(0x0441)
emit(0xC9, hi(brk_return))
emit(0xF0, 0x00); beq_high_exact = p - 1
emit_lda_imm(0x18)  # 'X'
emit(0xD0, 0x00); bne_high_store_x = p - 1
high_exact = p
emit_lda_imm(0x30)  # '0'
high_store = p
emit_sta_abs(0x0442)

# Patch BRK classification branches
rom[beq_low_exact] = (low_exact - beq_low_exact - 1) & 0xFF
rom[beq_low_m1] = (low_m1 - beq_low_m1 - 1) & 0xFF
rom[beq_low_p1] = (low_p1 - beq_low_p1 - 1) & 0xFF
rom[beq_low_p2] = (low_p2 - beq_low_p2 - 1) & 0xFF
rom[bne_low_store_x] = (low_store - bne_low_store_x - 1) & 0xFF
rom[bne_low_store_0] = (low_store - bne_low_store_0 - 1) & 0xFF
rom[bne_low_store_1] = (low_store - bne_low_store_1 - 1) & 0xFF
rom[bne_low_store_2] = (low_store - bne_low_store_2 - 1) & 0xFF
rom[beq_high_exact] = (high_exact - beq_high_exact - 1) & 0xFF
rom[bne_high_store_x] = (high_store - bne_high_store_x - 1) & 0xFF

# Test 8 pass criteria: one BRK hit + exact low/high pushed return bytes
emit(0xA5, 0x02)       # LDA $02
emit(0xC9, 0x01)       # CMP #$01
emit(0xD0, 0x00); t8_fail_1 = p - 1
emit_lda_abs(0x043F)
emit(0xC9, 0x30)       # low class '0'
emit(0xD0, 0x00); t8_fail_2 = p - 1
emit_lda_abs(0x0442)
emit(0xC9, 0x30)       # high class '0'
emit(0xD0, 0x00); t8_fail_3 = p - 1
emit_lda_imm(0x10); emit_sta_abs(0x042F)  # 'P' for test 8
emit_jmp(0)
t8_pass_jmp = p - 2
t8_fail = p
emit_lda_imm(0x06); emit_sta_abs(0x042F)  # 'F'
t8_done = p
rom[t8_fail_1] = (t8_fail - t8_fail_1 - 1) & 0xFF
rom[t8_fail_2] = (t8_fail - t8_fail_2 - 1) & 0xFF
rom[t8_fail_3] = (t8_fail - t8_fail_3 - 1) & 0xFF
rom[t8_pass_jmp] = lo(t8_done)
rom[t8_pass_jmp + 1] = hi(t8_done)

# === TEST 9: Single hardware IRQ (CIA Timer A) ===
# Validate hardware IRQ push/return path (separate from BRK).
emit_lda_imm(0x0E); emit_sta_abs(0xD020)   # light blue: entering test 9
emit_lda_imm(0x00); emit(0x85, 0x02)       # clear IRQ counter
emit_lda_imm(0x20); emit_sta_abs(0x0444)   # T9 low-byte class
emit_lda_imm(0x20); emit_sta_abs(0x0445)   # T9 high-byte class
emit_lda_imm(0x20); emit_sta_abs(0x0446)   # T9 raw PCL copy
emit_lda_imm(0x20); emit_sta_abs(0x0447)   # T9 raw PCH copy
emit_lda_imm(0x01); emit(0x85, 0x04)       # IRQ mode: one-shot stop in handler

# Configure CIA1 Timer A one-shot IRQ
emit_lda_imm(0x7F); emit_sta_abs(0xDC0D)   # clear/disable CIA IRQ sources
emit_lda_imm(0x20); emit_sta_abs(0xDC04)   # TA low
emit_lda_imm(0x00); emit_sta_abs(0xDC05)   # TA high
emit_lda_imm(0x81); emit_sta_abs(0xDC0D)   # enable TA IRQ
emit_lda_imm(0x19); emit_sta_abs(0xDC0E)   # force-load + start + one-shot
emit(0x58)                                  # CLI

# Poll until first IRQ increments $02
irq_poll = p
emit(0xA5, 0x02)                            # LDA $02
emit(0xD0, 0x00)                            # BNE irq_done (patched)
bne_irq_done = p - 1
emit(0xEA)                                  # NOP
emit_jmp(irq_poll)
irq_done = p
rom[bne_irq_done] = (irq_done - bne_irq_done - 1) & 0xFF
emit(0x78)                                  # SEI

# Copy raw pushed bytes for hardware IRQ display
emit_lda_abs(0x0440); emit_sta_abs(0x0446)
emit_lda_abs(0x0441); emit_sta_abs(0x0447)

# Low-byte class against expected poll-loop return points:
# irq_poll+0, +2, +4, +5 => class '0','1','2','3'; else 'X'
irq_low0 = lo(irq_poll)
irq_low1 = (irq_low0 + 2) & 0xFF
irq_low2 = (irq_low0 + 4) & 0xFF
irq_low3 = (irq_low0 + 5) & 0xFF
emit_lda_abs(0x0440)
emit(0xC9, irq_low0); emit(0xF0, 0x00); beq_irq_low0 = p - 1
emit(0xC9, irq_low1); emit(0xF0, 0x00); beq_irq_low1 = p - 1
emit(0xC9, irq_low2); emit(0xF0, 0x00); beq_irq_low2 = p - 1
emit(0xC9, irq_low3); emit(0xF0, 0x00); beq_irq_low3 = p - 1
emit_lda_imm(0x18)                          # 'X'
emit(0xD0, 0x00); bne_irq_low_x = p - 1
irq_low_case0 = p
emit_lda_imm(0x30)                          # '0'
emit(0xD0, 0x00); bne_irq_low_s0 = p - 1
irq_low_case1 = p
emit_lda_imm(0x31)                          # '1'
emit(0xD0, 0x00); bne_irq_low_s1 = p - 1
irq_low_case2 = p
emit_lda_imm(0x32)                          # '2'
emit(0xD0, 0x00); bne_irq_low_s2 = p - 1
irq_low_case3 = p
emit_lda_imm(0x33)                          # '3'
irq_low_store = p
emit_sta_abs(0x0444)

rom[beq_irq_low0] = (irq_low_case0 - beq_irq_low0 - 1) & 0xFF
rom[beq_irq_low1] = (irq_low_case1 - beq_irq_low1 - 1) & 0xFF
rom[beq_irq_low2] = (irq_low_case2 - beq_irq_low2 - 1) & 0xFF
rom[beq_irq_low3] = (irq_low_case3 - beq_irq_low3 - 1) & 0xFF
rom[bne_irq_low_x] = (irq_low_store - bne_irq_low_x - 1) & 0xFF
rom[bne_irq_low_s0] = (irq_low_store - bne_irq_low_s0 - 1) & 0xFF
rom[bne_irq_low_s1] = (irq_low_store - bne_irq_low_s1 - 1) & 0xFF
rom[bne_irq_low_s2] = (irq_low_store - bne_irq_low_s2 - 1) & 0xFF

# High-byte class: expected = hi(irq_poll) => '0', else 'X'
emit_lda_abs(0x0441)
emit(0xC9, hi(irq_poll)); emit(0xF0, 0x00); beq_irq_high0 = p - 1
emit_lda_imm(0x18)                          # 'X'
emit(0xD0, 0x00); bne_irq_high_x = p - 1
irq_high_case0 = p
emit_lda_imm(0x30)                          # '0'
irq_high_store = p
emit_sta_abs(0x0445)
rom[beq_irq_high0] = (irq_high_case0 - beq_irq_high0 - 1) & 0xFF
rom[bne_irq_high_x] = (irq_high_store - bne_irq_high_x - 1) & 0xFF

# Test 9 pass criteria: exactly one IRQ, high class '0', low class not 'X'
emit(0xA5, 0x02)                            # LDA $02
emit(0xC9, 0x01)                            # CMP #$01
emit(0xD0, 0x00); t9_fail_1 = p - 1
emit_lda_abs(0x0445)
emit(0xC9, 0x30)                            # high class '0'
emit(0xD0, 0x00); t9_fail_2 = p - 1
emit_lda_abs(0x0444)
emit(0xC9, 0x18)                            # low class 'X'
emit(0xF0, 0x00); t9_fail_3 = p - 1
emit_lda_imm(0x10); emit_sta_abs(0x0430)    # 'P' for test 9
emit_jmp(0)
t9_pass_jmp = p - 2
t9_fail = p
emit_lda_imm(0x06); emit_sta_abs(0x0430)    # 'F'
t9_done = p
rom[t9_fail_1] = (t9_fail - t9_fail_1 - 1) & 0xFF
rom[t9_fail_2] = (t9_fail - t9_fail_2 - 1) & 0xFF
rom[t9_fail_3] = (t9_fail - t9_fail_3 - 1) & 0xFF
rom[t9_pass_jmp] = lo(t9_done)
rom[t9_pass_jmp + 1] = hi(t9_done)

# === TEST 10: Continuous hardware IRQ stress ===
# Run repeated IRQs and verify stack pointer returns to $FF.
emit_lda_imm(0x0B); emit_sta_abs(0xD020)    # light green: entering test 10
emit_lda_imm(0x00); emit(0x85, 0x02)        # clear IRQ counter
emit_lda_imm(0x00); emit(0x85, 0x04)        # IRQ mode: continuous (do not stop)
emit_lda_imm(0x20); emit_sta_abs(0x0448)    # T10 status marker

# Configure CIA1 Timer A continuous IRQ
emit_lda_imm(0x7F); emit_sta_abs(0xDC0D)    # clear/disable IRQ sources
emit_lda_imm(0x80); emit_sta_abs(0xDC04)    # TA low
emit_lda_imm(0x00); emit_sta_abs(0xDC05)    # TA high
emit_lda_imm(0x81); emit_sta_abs(0xDC0D)    # enable TA IRQ
emit_lda_imm(0x11); emit_sta_abs(0xDC0E)    # force-load + start + continuous
emit(0x58)                                   # CLI

t10_loop = p
emit(0xBA)                                   # TSX
emit(0xE0, 0xFF)                             # CPX #$FF
emit(0xD0, 0x00); t10_sp_fail_branch = p - 1
emit(0xA5, 0x02)                             # LDA $02
emit(0xC9, 0x20)                             # CMP #$20
emit(0xB0, 0x00); t10_done_branch = p - 1    # BCS t10_done
emit(0xEA)                                   # NOP
emit_jmp(t10_loop)

t10_sp_fail = p
emit_lda_imm(0x13); emit_sta_abs(0x0448)     # 'S' stack mismatch
emit_lda_imm(0x06); emit_sta_abs(0x0431)     # 'F' test 10
emit(0x78)                                   # SEI
emit_lda_imm(0x00); emit_sta_abs(0xDC0E)     # stop timer
emit_jmp(0)
t10_fail_jmp = p - 2

t10_done = p
emit(0x78)                                   # SEI
emit_lda_imm(0x00); emit_sta_abs(0xDC0E)     # stop timer
emit_lda_imm(0x10); emit_sta_abs(0x0431)     # 'P' test 10
t10_done_exit = p
rom[t10_sp_fail_branch] = (t10_sp_fail - t10_sp_fail_branch - 1) & 0xFF
rom[t10_done_branch] = (t10_done - t10_done_branch - 1) & 0xFF
rom[t10_fail_jmp] = lo(t10_done_exit)
rom[t10_fail_jmp + 1] = hi(t10_done_exit)

# Final halt
emit_lda_imm(0x01); emit_sta_abs(0xD020)    # white border
emit_str(0x04A0, "ALL DONE")
halt_all = p
emit_jmp(halt_all)

print(f"Code ends at ${p:04X} ({p - 0xFC00} bytes used)")
assert p < 0xFF00, f"Overflow at ${p:04X}!"

# ---- Vectors ----
wb(0xFFFA, lo(NMI_ADDR), hi(NMI_ADDR))      # NMI
wb(0xFFFC, 0x00, 0xFA)                       # RESET -> $FA00
wb(0xFFFE, lo(IRQ_HANDLER), hi(IRQ_HANDLER)) # IRQ

wb(0xFFEA, lo(NMI_ADDR), hi(NMI_ADDR))      # NMI native
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
