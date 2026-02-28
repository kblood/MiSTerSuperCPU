# P65C816 Emulation Mode IRQ Corruption - Root Cause Analysis

## Problem
When the P65C816 core runs in emulation mode (6502 compatibility) on the
MiSTer C64 core, screen RAM ($0400-$07E7) gets corrupted with scrolling
lines of repeated characters. This happens with the standard C64 KERNAL
and with our custom diagnostic ROM.

## Resolution Update (2026-02-28)

Final hardware diagnostics identified and confirmed the primary fault:

1. **RTI microcode regression (root cause)**
   - An extra RTI stack-read stage was introduced during debugging in
     `rtl/65C816/MCode.vhd` (`-- 40 RTI` path).
   - That extra stage broke BRK/IRQ handler return flow in emulation mode.
   - Reverting RTI to the original microcode sequence restored correct return
     behavior.

2. **BRK/COP stack push handling**
   - BRK/COP emulation-mode sequence now uses explicit duplicated PCL write
     (`PCL->[00:SP]` then `PCL->[00:SP--]`) before pushing `P`.
   - This aligns with observed stack behavior and passes the final diagnostics.

3. **Diagnostic ROM harness bug fixed**
   - Test subroutine at `$FF20` overlapped IRQ handler bytes and corrupted
     debug readouts.
   - Subroutine moved to `$FF30`, making BRK/RTI markers reliable.

4. **Verification outcome**
   - V19 diagnostics (BRK handler direct jump bypassing RTI) reached full pass
     (`8 Ps`, white border), proving BRK pushed bytes were correct.
   - V20 diagnostics (real RTI path restored) also reached full pass.
   - Standard C64 ROM boot in the previously failing mode now works again.

## Diagnostic Results

### Phase 1 - Instruction Tests: ALL PASS
Six instruction types tested with no IRQs active:
1. LDA #imm / STA abs / LDA abs / CMP - PASS
2. STA abs,X / LDA abs,X - PASS
3. STA (zp),Y / LDA (zp),Y - PASS
4. PHA / PLA - PASS
5. JSR / RTS - PASS
6. LDA (zp,X) - PASS

### Phase 1H - Hold Loop (no IRQs): PASS
Tight loop checking 3 sentinels (screen RAM and data RAM) over ~65K
iterations with SEI active. No corruption detected. Border stays green.

**Conclusion: Basic instruction execution is correct. No corruption
occurs without interrupts.**

### Phase 2B - BRK/RTI Test: HANGS
Attempted 256 BRK/RTI cycles (software interrupt, same CPU microcode as
hardware IRQ). The CPU appears to hang - border stays at P1H's light green
and never progresses to P2B PASS (light blue) or Phase 2 (CIA IRQ).

**Conclusion: BRK instruction does not return correctly in emulation mode.**

### Phase 2 - CIA Timer A IRQ (earlier build): CORRUPTION
When CIA interrupts are enabled, screen RAM gets corrupted with scrolling
lines. IRQ handler does execute (counter increments), but screen integrity
check fails (red border).

**Conclusion: Interrupt handling mechanism is broken, not CIA-specific.**

## CPU Core Analysis (P65C816.vhd)

### Stack Address Generation - CORRECT
File: rtl/65C816/P65C816.vhd, lines 565-570

Stack addresses are correctly forced to $01xx in emulation mode.

### PBR Push Skip - CORRECT
File: rtl/65C816/P65C816.vhd, lines 148-155

STATE_CTRL="111" at BRK STATE 0: in emulation mode, NextState = STATE + 2,
which skips STATE 1 (PBR push). Only 3 bytes pushed (PCH, PCL, P).

### PC Increment Suppression for Hardware IRQ - CORRECT
File: rtl/65C816/AddrGen.vhd, lines 62-67

GotInterrupt='1' suppresses PC increment at BRK STATE 0.

### Vector Address Generation - CORRECT
File: rtl/65C816/P65C816.vhd, lines 573-587

IRQ vector address is $00FFFE/$00FFFF in emulation mode (EF=1).

## Remaining Suspects

### 1. BRK Return Address Bug
BRK in emulation mode should push PC+2 (past signature byte). If the
P65C816 pushes the wrong return address, RTI goes to the wrong location.
The diagnostic Phase 2B hang strongly suggests this.

### 2. RTI State Machine Bug
RTI in emulation mode (STATE_CTRL="111", IR=$40) transitions to STATE 0
immediately from STATE 6. If this skips PC restoration, RTI would go wrong.

### 3. B-Flag / P Register Corruption
The D_OUT line (P65C816.vhd:454) has complex B-flag logic for BRK vs IRQ.
If P is pushed with wrong flags, RTI could restore wrong processor state.

### 4. Bus Logic Write Timing
During interrupt vector fetch, if WE momentarily goes active, stray writes
could corrupt memory.

## Next Steps
1. Add test that does single BRK then halts (to see what happens)
2. Test RTI independently (push known values to stack, execute RTI)
3. If BRK is confirmed broken, deep-dive BRK/RTI microcode in MCode.vhd
4. Consider tracing BRK execution with SignalTap
