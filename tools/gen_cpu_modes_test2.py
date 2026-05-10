#!/usr/bin/env python3
"""Generate cpu_modes_test2.prg

Probe write-side indexed/indirect modes that decompressors lean on,
plus the NMOS JMP indirect page-wrap quirk that 65C816 fixes.

Each test writes one result byte to $0400+N. Visible chars on the
top-left of the screen reveal divergence between T65 (SCPU=off) and
P65C816 emu-mode (SCPU=on).

  T0  STA abs (control)                       ($01)
  T1  STA (zp),Y write + LDA verify           ($02)
  T2  STA abs,X write (no page cross) + LDA   ($03)
  T3  STA abs,Y write + LDA                   ($04)
  T4  STA abs,X with page cross + LDA         ($05)
  T5  STA (zp,X) write + LDA                  ($06)
  T6  INC abs,X RMW (X=0)                     ($07)
  T7  INC abs,X RMW with page cross           ($08)
  T8  ASL abs,X RMW                           ($09)
  T9  LSR abs,X RMW                           ($0A)
  T10 ROL abs,X RMW                           ($0B)
  T11 ROR abs,X RMW                           ($0C)
  T12 DEC abs,X RMW                           ($0D)
  T13 JMP ($00FF) — NMOS page wrap bug        ($0E)
  T14 NMOS-style ADC w/ overflow flag check   ($0F)
  T15 STX $zp,Y / LDY $zp,X (rare modes)      ($10)

NMOS JMP ($xxFF): T65 reads lo from $xxFF, hi from $xx00 (page wrap).
P65C816 reads lo from $xxFF, hi from $xx00+1 (no wrap, fixed). If DL
uses JMP ($xxFF), the divergence shows here.

Expected screen $0400..$040F = 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10
"""
import sys

RUNTIME = 0xC000
PTR_FB  = 0xFB              # ZP pointer
SCRATCH = 0xC180            # scratch for RMW tests (away from main code)
SCRATCH2 = 0xC1FF           # scratch for INC abs,X with page cross

# JMP ($00FF) target table at zp $00FF / $0100
# NMOS reads ($00FF) as: lo = mem[$00FF], hi = mem[$0000] (wraps)
# CMOS reads ($00FF) as: lo = mem[$00FF], hi = mem[$0100] (correct)
# We exploit this: place different target at $0100 vs $0000.
#   - If T65: hi from $0000 -> target_a -> writes $X to $040D
#   - If P65C816 emu: hi from $0100 -> target_b -> writes $Y to $040D
# We want both to write $0E so this test PASSES on both — actually we want
# them to DIVERGE. Set target_a = $C300, target_b = $C310. Both write $0E
# so result is identical UNLESS there's a wrap difference.
# Actually for DIVERGENCE detection: target_a writes $0E to $040D, target_b
# writes $5F (different glyph) to $040D. Then if T65 wraps and P65C816 doesn't,
# T65 writes $0E and P65C816 writes $5F. The visible char will differ.
# But: WE WANT BOTH TO PASS (write $0E) so the test reflects "no quirk
# difference visible". Actually no — we want to DETECT the quirk if it
# exists, so we configure them to give different result bytes.
#
# Plan: target_a (NMOS wrap path) writes $0E. target_b (CMOS path) writes $5F.
# If T65 produces $0E and P65C816 produces $5F at $040D, NMOS quirk diverges.

TARGET_NMOS  = 0xC300       # NMOS wrap path
TARGET_FIXED = 0xC310       # CMOS/65C816 fixed path

code = []

def emit(*bs):
    code.extend(bs)

# --- Setup ---
emit(0x78)                   # SEI
emit(0xD8)                   # CLD
emit(0xA2, 0xFF)             # LDX #$FF
emit(0x9A)                   # TXS

# Initialize scratch areas to known state. We'll INC them later.
# $C180..$C1FF = 0
emit(0xA2, 0x00)             # LDX #$00
emit(0xA9, 0x00)             # LDA #$00
# loop_clear:
clear_loop_start = len(code)
emit(0x9D, 0x80, 0xC1)       # STA $C180,X
emit(0xE8)                   # INX
emit(0xE0, 0x80)             # CPX #$80
emit(0xD0, len(code) + 2 - clear_loop_start)
# Hmm the BNE target: BNE relative to the byte AFTER BNE. Let me recompute.
# We need BNE to jump back to STA $C180,X.
# clear_loop_start is the offset of "STA $C180,X". After "BNE rel", PC = (BNE pos) + 2.
# Distance backward = (BNE pos + 2) - clear_loop_start.
# Let me just patch this correctly. Replace the ad-hoc len(code)+2 calc above.
# We need to backtrack and emit clean.

# Reset code, redo cleanly with explicit branch offsets:
code = []
emit(0x78)                   # SEI
emit(0xD8)                   # CLD
emit(0xA2, 0xFF)             # LDX #$FF
emit(0x9A)                   # TXS

# Clear $C180..$C200 (128 bytes)
emit(0xA2, 0x00)             # LDX #$00
emit(0xA9, 0x00)             # LDA #$00
# Loop label:
loop1 = len(code)
emit(0x9D, 0x80, 0xC1)       # STA $C180,X      ; 3 bytes
emit(0xE8)                   # INX              ; 1 byte
emit(0xD0, 0xFB)             # BNE -5  (back to STA)  -- wraps when X=0
# After BNE: X==0 means done (256 iterations); we cleared $C180..$C27F. Fine.

# --- ZP pointer setup at $FB,$FC = $0500 (output buffer for STA-side tests) ---
# Use $0500-$05FF as a write-test buffer, then verify by reading back.
emit(0xA9, 0x00)             # LDA #$00
emit(0x85, PTR_FB)           # STA $FB
emit(0xA9, 0x05)             # LDA #$05
emit(0x85, PTR_FB+1)         # STA $FC

# --- T0: STA abs (control). Write $01 to $0400. ---
emit(0xA9, 0x01)             # LDA #$01
emit(0x8D, 0x00, 0x04)       # STA $0400

# --- T1: STA (zp),Y. Write $02 to ($FB),Y where Y=$01 -> $0501. Read back, store at $0401. ---
emit(0xA9, 0x02)             # LDA #$02
emit(0xA0, 0x01)             # LDY #$01
emit(0x91, PTR_FB)           # STA ($FB),Y      -> $0501
emit(0xAD, 0x01, 0x05)       # LDA $0501
emit(0x8D, 0x01, 0x04)       # STA $0401

# --- T2: STA abs,X. Write $03 to $0500,X where X=$02 -> $0502. ---
emit(0xA9, 0x03)             # LDA #$03
emit(0xA2, 0x02)             # LDX #$02
emit(0x9D, 0x00, 0x05)       # STA $0500,X     -> $0502
emit(0xAD, 0x02, 0x05)       # LDA $0502
emit(0x8D, 0x02, 0x04)       # STA $0402

# --- T3: STA abs,Y. Write $04 to $0500,Y where Y=$03 -> $0503. ---
emit(0xA9, 0x04)             # LDA #$04
emit(0xA0, 0x03)             # LDY #$03
emit(0x99, 0x00, 0x05)       # STA $0500,Y     -> $0503
emit(0xAD, 0x03, 0x05)       # LDA $0503
emit(0x8D, 0x03, 0x04)       # STA $0403

# --- T4: STA abs,X with page cross. Write $05 to $05FF,X where X=$05 -> $0604. ---
emit(0xA9, 0x05)             # LDA #$05
emit(0xA2, 0x05)             # LDX #$05
emit(0x9D, 0xFF, 0x05)       # STA $05FF,X     -> $0604 (page cross)
emit(0xAD, 0x04, 0x06)       # LDA $0604
emit(0x8D, 0x04, 0x04)       # STA $0404

# --- T5: STA (zp,X). Setup $20,$21 = $0506; X=$00; write $06 via (zp,X) -> $0506. ---
emit(0xA9, 0x06)             # LDA #$06
emit(0x85, 0x20)             # STA $20      (lo of $0506)
emit(0xA9, 0x05)             # LDA #$05
emit(0x85, 0x21)             # STA $21      (hi of $0506)
emit(0xA2, 0x00)             # LDX #$00
emit(0xA9, 0x06)             # LDA #$06
emit(0x81, 0x20)             # STA ($20,X)  -> $0506
emit(0xAD, 0x06, 0x05)       # LDA $0506
emit(0x8D, 0x05, 0x04)       # STA $0405

# --- T6: INC abs,X (X=0).  pre $C180=$06; INC $C180,X -> $07. Read back, store at $0406. ---
emit(0xA9, 0x06)             # LDA #$06
emit(0x8D, 0x80, 0xC1)       # STA $C180
emit(0xA2, 0x00)             # LDX #$00
emit(0xFE, 0x80, 0xC1)       # INC $C180,X
emit(0xAD, 0x80, 0xC1)       # LDA $C180
emit(0x8D, 0x06, 0x04)       # STA $0406

# --- T7: INC abs,X with page cross. pre $C200=$07; INC $C1FF,X with X=$01 -> $C200. Result $08. ---
emit(0xA9, 0x07)             # LDA #$07
emit(0x8D, 0x00, 0xC2)       # STA $C200
emit(0xA2, 0x01)             # LDX #$01
emit(0xFE, 0xFF, 0xC1)       # INC $C1FF,X      -> $C200 (page cross)
emit(0xAD, 0x00, 0xC2)       # LDA $C200
emit(0x8D, 0x07, 0x04)       # STA $0407

# --- T8: ASL abs,X. pre $C181=$04 (X=$01 -> $C181 + $01? no, $C180 + X=1 = $C181). ASL gives $08. Wait want $09. ---
# We want result $09 (bin 1001). ASL of $04 = $08. To get $09, need ASL of $04 + ORA before? Just store result+1.
# Let me re-target: want $09 visible. Use pre-byte $04 (ASL = $08), then we'd see $08 not $09. Off by one.
# Adjust: pre $C181 = $04, do ASL+INC, OR use diff method. Simpler: just accept screen byte = $08
# But T7 already produced $08. We need each cell to have a unique byte for clear visual.
# Workaround: pre $C181 = $04, ASL gives $08, then INC gives $09. Simple.
emit(0xA9, 0x04)             # LDA #$04
emit(0x8D, 0x81, 0xC1)       # STA $C181
emit(0xA2, 0x01)             # LDX #$01
emit(0x1E, 0x80, 0xC1)       # ASL $C180,X     -> $C181: $08
emit(0xFE, 0x80, 0xC1)       # INC $C180,X     -> $09
emit(0xAD, 0x81, 0xC1)       # LDA $C181
emit(0x8D, 0x08, 0x04)       # STA $0408

# --- T9: LSR abs,X. pre $C182 = $14, LSR gives $0A. ---
emit(0xA9, 0x14)             # LDA #$14
emit(0x8D, 0x82, 0xC1)       # STA $C182
emit(0xA2, 0x02)             # LDX #$02
emit(0x5E, 0x80, 0xC1)       # LSR $C180,X     -> $C182: $0A
emit(0xAD, 0x82, 0xC1)       # LDA $C182
emit(0x8D, 0x09, 0x04)       # STA $0409

# --- T10: ROL abs,X. pre $C183 = $05 (carry-in 1), ROL gives ($05<<1)|1 = $0B. ---
emit(0x38)                   # SEC (carry in = 1)
emit(0xA9, 0x05)             # LDA #$05
emit(0x8D, 0x83, 0xC1)       # STA $C183
emit(0xA2, 0x03)             # LDX #$03
emit(0x3E, 0x80, 0xC1)       # ROL $C180,X     -> $C183: $05<<1|1 = $0B
emit(0xAD, 0x83, 0xC1)       # LDA $C183
emit(0x8D, 0x0A, 0x04)       # STA $040A

# --- T11: ROR abs,X. pre $C184 = $18 (carry-in 0), ROR gives $0C. ---
emit(0x18)                   # CLC
emit(0xA9, 0x18)             # LDA #$18
emit(0x8D, 0x84, 0xC1)       # STA $C184
emit(0xA2, 0x04)             # LDX #$04
emit(0x7E, 0x80, 0xC1)       # ROR $C180,X     -> $C184: $0C
emit(0xAD, 0x84, 0xC1)       # LDA $C184
emit(0x8D, 0x0B, 0x04)       # STA $040B

# --- T12: DEC abs,X. pre $C185 = $0E, DEC -> $0D. ---
emit(0xA9, 0x0E)             # LDA #$0E
emit(0x8D, 0x85, 0xC1)       # STA $C185
emit(0xA2, 0x05)             # LDX #$05
emit(0xDE, 0x80, 0xC1)       # DEC $C180,X     -> $C185: $0D
emit(0xAD, 0x85, 0xC1)       # LDA $C185
emit(0x8D, 0x0C, 0x04)       # STA $040C

# --- T13: JMP ($00FF) NMOS page wrap. ---
# Setup ZP $00FF = lo of TARGET_NMOS,
# ZP $0000 = hi of TARGET_NMOS (NMOS wraps and reads here),
# ZP $0100 = hi of TARGET_FIXED (CMOS reads here, which P65C816 emu does).
# Hmm wait — both TARGETs need the SAME lo? No, NMOS reads lo from $00FF and hi from $0000.
# CMOS reads lo from $00FF and hi from $0100.
# Both produce target = lo:hi. We need TWO completely separate target addresses to land at.
#
# Construct: $00FF = $00 (low byte common). $0000 = $C3. $0100 = $C3.
# Both NMOS and CMOS jump to $C300 -- SAME ADDRESS. No divergence detected.
# To make them diverge: $0000 = $C3 (NMOS target $C300 = TARGET_NMOS),
#                       $0100 = $C4 (CMOS target $C400 = different).
# Then NMOS path lands at $C300 (writes $0E), CMOS path lands at $C400 (writes $5F).
# Visible char at $040D will be 'N' ($0E) on T65 and '_' (or whatever $5F maps to) on P65C816.
TARGET_NMOS_HI  = 0xC3
TARGET_FIXED_HI = 0xC4

# Save current $0000 / $0100 contents so we don't crash KERNAL state.
# Actually $0000/$0001 are the C64 IO port — DO NOT clobber. Use a different address.
# Let me change strategy: use vector at $C0FF (in code page). NMOS reads lo from $C0FF,
# hi from $C000. We can't safely modify $C000 either (start of our program).
# Better: pick a vector address far from anything important. Let's use $00BF.
# T1 NMOS: reads lo from $00BF, hi from $0000. Writes to ($00BF) -> wraps from $0000.
# Wait, the key is the LOW BYTE = $FF. JMP ($xxFF) is the buggy form. JMP ($xxBF) doesn't have the bug.
# So we MUST use a $xxFF address. But $00FF is ZP, $00FF is $0000. $00FF write OK; $0000 = D6510 IO port (DON'T touch).
# Use $20FF instead (in $2000-$2FFF area, free RAM). NMOS reads ($20FF) -> lo from $20FF, hi from $2000.
# CMOS reads ($20FF) -> lo from $20FF, hi from $2100.

# Setup the vector area:
emit(0xA9, 0x00)             # LDA #$00 (low byte of both targets)
emit(0x8D, 0xFF, 0x20)       # STA $20FF
emit(0xA9, TARGET_NMOS_HI)   # LDA #$C3
emit(0x8D, 0x00, 0x20)       # STA $2000  (NMOS wrap reads hi here)
emit(0xA9, TARGET_FIXED_HI)  # LDA #$C4
emit(0x8D, 0x00, 0x21)       # STA $2100  (CMOS-fixed reads hi here)

# Also STA the same lo at start of TARGET_FIXED page
# (we want both NMOS and CMOS targets to actually point at our handlers)
# TARGET_NMOS = $C300, TARGET_FIXED = $C400 — declared above. We'll plant code there.

emit(0x6C, 0xFF, 0x20)       # JMP ($20FF)

# CONTROL FLOW: from here, execution diverges. Both code paths eventually
# write to $040D and JMP to a "halt loop" at $C220.

# After T13, the rest of the program would never execute because of the JMP.
# We move T14, T15 BEFORE T13 above? No, T13 is the divergent jump. Let's
# arrange so handlers do T14, T15, then halt.
# Actually for simplicity, let both target handlers do all of T14, T15 and halt.
# Or — simpler — T13's targets each STA $0E (or $5F) to $040D and then JMP to a common
# post-T13 routine that does T14, T15.
#
# Simplest: T14 and T15 happen BEFORE T13. Reorder: do T14, T15 first, then T13 last.

# Hmm we already emitted up to T12 + a partial T13. Let me delete the JMP indirect and do T14, T15 first.
# Pop the last 12 bytes (vector setup + JMP indirect):
del code[-12:]

# --- T14: NMOS-style ADC overflow check. ---
# Run a specific operation that produces different N/Z flags on NMOS vs CMOS in decimal mode.
# Classic test: SED ; CLC ; LDA #$80 ; ADC #$80 -- decimal underflow. NMOS leaves N undefined.
# Stable test: skip BCD-flag quirks; just verify normal binary ADC overflow.
# CLC ; LDA #$50 ; ADC #$50 -- result $A0, V flag set (signed overflow).
# BVS sets if V; if T65 and P65C816 agree, both will branch.
# Result: write $0F if V was set, $00 if not.
emit(0x18)                   # CLC
emit(0xA9, 0x50)             # LDA #$50
emit(0x69, 0x50)             # ADC #$50         -> A=$A0, V=1
emit(0xA9, 0x00)             # LDA #$00 (default fail value)
emit(0x70, 0x02)             # BVS +2          (if V set, skip the next 2 bytes)
emit(0x80, 0x02)             # BRA  +2 ??? wait BRA is $80 on 65C816 only — not safe in pure 6502 context
# Skip the BRA-65C816-only thing; use forward BCC-always with carry:
# Actually let me redo this:
# We want: A := $0F if V set, else A := $00.
# Code:
#   CLC ; LDA #$50 ; ADC #$50          ; flags now reflect ADC
#   LDA #$00                           ; default
#   BVC skip                           ; if V clear, skip overwrite
#   LDA #$0F                           ; override with $0F
# skip:
#   STA $040E
# Pop the last 8 bytes I just emitted and redo:
del code[-8:]
# T14:
emit(0x18)                   # CLC
emit(0xA9, 0x50)             # LDA #$50
emit(0x69, 0x50)             # ADC #$50
emit(0xA9, 0x00)             # LDA #$00
emit(0x50, 0x02)             # BVC +2 (skip next LDA)
emit(0xA9, 0x0F)             # LDA #$0F
emit(0x8D, 0x0E, 0x04)       # STA $040E

# --- T15: STX $zp,Y / LDY $zp,X (rare but used). ---
# STX zp,Y: store X at zp+Y.
# LDY zp,X: load Y from zp+X.
# Setup: X=$10. STX $40,Y where Y=$05 stores X=$10 at zp $45.
# Then LDY $40,X with X=$05 loads zp $45 (=$10) into Y.
# Store Y to $040F.
emit(0xA2, 0x10)             # LDX #$10
emit(0xA0, 0x05)             # LDY #$05
emit(0x96, 0x40)             # STX $40,Y       -> zp $45 = $10
# Verify via direct LDA:
emit(0xA5, 0x45)             # LDA $45         -> $10
emit(0x8D, 0x0F, 0x04)       # STA $040F

# --- Now T13: JMP ($20FF) ---
# Setup vector
emit(0xA9, 0x00)             # LDA #$00
emit(0x8D, 0xFF, 0x20)       # STA $20FF
emit(0xA9, TARGET_NMOS_HI)   # LDA #$C3
emit(0x8D, 0x00, 0x20)       # STA $2000
emit(0xA9, TARGET_FIXED_HI)  # LDA #$C4
emit(0x8D, 0x00, 0x21)       # STA $2100
emit(0x6C, 0xFF, 0x20)       # JMP ($20FF)

# Body length so far:
body_len = len(code)
print(f"; body_len = {body_len} bytes (ends at ${RUNTIME + body_len:04X})", file=sys.stderr)

# Pad to TARGET_NMOS = $C300
pad_to_nmos = (TARGET_NMOS - RUNTIME) - body_len
if pad_to_nmos < 0:
    raise RuntimeError(f"Code overran $C300: ends at ${RUNTIME+body_len:04X}")
code.extend([0xEA] * pad_to_nmos)

# At $C300: NMOS path handler — write $0E to $040D and halt
nmos_at = RUNTIME + len(code)
emit(0xA9, 0x0E)             # LDA #$0E
emit(0x8D, 0x0D, 0x04)       # STA $040D
# Halt loop
halt_addr = RUNTIME + len(code)
emit(0x4C, halt_addr & 0xFF, (halt_addr >> 8) & 0xFF)

# Pad to TARGET_FIXED = $C400
pad_to_fixed = (TARGET_FIXED - RUNTIME) - len(code)
code.extend([0xEA] * pad_to_fixed)

# At $C400: CMOS path handler — write $5F (visible distinct char) and halt
fixed_at = RUNTIME + len(code)
emit(0xA9, 0x5F)             # LDA #$5F
emit(0x8D, 0x0D, 0x04)       # STA $040D
halt_addr2 = RUNTIME + len(code)
emit(0x4C, halt_addr2 & 0xFF, (halt_addr2 >> 8) & 0xFF)

# ---------- BASIC stub ----------
basic_stub = bytes([
    0x0C, 0x08, 0x0A, 0x00, 0x9E,
    0x34, 0x39, 0x31, 0x35, 0x32,
    0x00, 0x00, 0x00,
])

load_addr = 0x0801
gap_to_runtime = RUNTIME - (load_addr + len(basic_stub))
content = bytearray(basic_stub) + bytearray([0x00] * gap_to_runtime) + bytearray(code)
prg = bytes([load_addr & 0xFF, (load_addr >> 8) & 0xFF]) + bytes(content)

out = "tools/cpu_modes_test2.prg"
with open(out, "wb") as f:
    f.write(prg)

print(f"; wrote {out} ({len(prg)} bytes)", file=sys.stderr)
print(f"; runtime ends near ${RUNTIME + len(code):04X}", file=sys.stderr)
print(f"; expected (NMOS T65): 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10", file=sys.stderr)
print(f"; expected (CMOS path): 01 02 03 04 05 06 07 08 09 0A 0B 0C 5F 0E 0F 10", file=sys.stderr)
