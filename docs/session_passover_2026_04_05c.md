# Session Passover - 2026-04-05c

## Session Summary
Deep investigation into why Doom crashes to bank $9B. Discovered the root cause: P65C816 PBR
register corruption in emulation mode, and that the C64 runs entirely from the SuperCPU ROM
(via PBR=$F8 → bank $F8 routing). Multiple fix iterations with key architectural discoveries.

## Key Findings

### 1. P65C816 PBR Emulation Mode Behavior (CRITICAL)
The P65C816 core has PBR=$F8 during emulation mode (observed in UART). This is "corruption"
from the 65816's RTL ($6B) instruction being executed in 6502 code (opcode $6B is undocumented
on 6502 but valid on 65816). The RTL microcode has NO emulation mode skip (unlike RTI which
properly skips PBR pull via STATE_CTRL "111").

**But PBR=$F8 is REQUIRED:** The bus logic routes bank $F8 through `scpu_rom_en`, serving ALL
instruction fetches from the SuperCPU ROM. The ROM contains a copy of the C64 KERNAL at
$E000-$FFFF and handler code at $8000-$80FF. Changing PBR to $00 breaks the KERNAL!

### 2. SuperCPU Kickstart Boot
The SuperCPU ROM at $80C1-$80C3 contains: SEI, CLC, XCE — the kickstart boot sequence.
After reset, the CPU reads the reset vector from the ROM ($FFFC=$FC90), JMLs to $F8:00FC,
and eventually reaches the kickstart at $80C1. The kickstart:
- Enters native mode (XCE)
- Sets up S=$01FF, D=$0000
- Copies handler code from ROM to bank $00 SRAM (MVN)
- Sets up native vectors
- Runs the C64 in emulation mode with ROM overlay

Our FPGA doesn't prevent the kickstart from running — it runs by default!

### 3. ROM Visibility Architecture
- `scpu_rom_en` activates for: bank $F8 (ANY address) OR bank $00 $8000-$9FFF (rom_vis=1)
- In emulation mode with PBR=$F8: ALL fetches come from SuperCPU ROM
- In native mode: only $8000-$9FFF in bank $00 comes from ROM (rest is BRAM/SDRAM)
- The game's init writes $E3 to $D07E (bit7=1) → rom_vis stays 1

### 4. BRK as PBR Fix Mechanism
BRK on 65816 forces PBR=$00 (hardcoded in microcode LOAD_DKB="10" with IR=$00 check).
The launcher uses BRK after XCE to get PBR=$00, then the BRK handler at $FF04 does
JML $20:0000 to start the game with correct PBR=$20.

Launcher code: SEI ($78), CLC ($18), XCE ($FB), BRK ($00 $00).
DATA: 120, 24, 251, 0, 0

### 5. SCPUMIPS Signature Architecture
- Game checks "SCPU" (4 chars, not 8) at $00:0100-$0103
- With signature: dispatches through function pointers at $00:1CB4-$1CBB
  - These pointers are ZERO in doom.reu (kickstart supposed to set them)
  - JML [$0090] → $00:0000 → crash to ROM handler at $80xx
- Without signature: calls $0968 (timing calibration) → enters VBlank wait at $0EE8
  - VBlank wait hangs (no NMI timer set up)

### 6. $0200/$0300 = FixedMul, NOT BRK Dispatcher
The 256-byte blocks at $00:0200 and $00:0300 are fixed-point multiplication routines
using log/antilog tables in SuperRAM banks $10-$18. Game uses JSL (not BRK) to call them.
195 JSL calls across banks $20-$22.

### 7. Writable Native Vectors
Made vec_reg writable (was read-only). Game's "with signature" init at $00:0854
writes NMI vector ($FFEA=$0800). Write path: `rom_stub_wr` detects native mode
writes to $00:FFE4-$FFEF, updates vec_reg on rising_edge(clk).

## Fix Attempts (Chronological)

### Fix 1: Continuous PBR=$00 forcing (FAILED)
Force PBR=$00 when EF=1, force bank $00 on address bus in emu mode.
Result: BLACK SCREEN — broke KERNAL (normally served by SuperCPU ROM via bank $F8).

### Fix 2: Targeted PBR=$00 on XCE (FAILED)
Clear PBR only when XCE transitions from emu→native mode.
Result: Broke kickstart boot (kickstart also uses XCE at $80C3).

### Fix 3: BRK launcher (IN PROGRESS)
No PBR fix in CPU. Change launcher from JML to BRK (BRK forces PBR=$00 in microcode).
BRK handler at $FF04: JML $20:0000 instead of zero-regs RTI.
Launcher: SEI, CLC, XCE, BRK $00 → PBR=$00 → $FF04 → JML $20:0000 → game starts.

## Current State of Code

### cpu_65c816.vhd
- BRK handler ($FF04): JML $20:0000 (was PHK/PLB/REP/LDA/TAX/TAY/RTI)
- vec_reg: WRITABLE (was read-only). Write process with reset defaults.
- ROM stub read range: $FF00-$FF3F + $FFE4-$FFEF (unchanged)
- ROM stub write: $FFE4-$FFEF in native mode, bank $00

### P65C816.vhd
- PBR: NO fix applied (PBR=$F8 in emu mode is required for KERNAL via ROM)
- Address bus: ORIGINAL (no EF check, uses PBR directly)
- Comment added explaining why PBR is not fixed

### fpga64_sid_iec.vhd
- No changes this session

## Build in Progress
BRK launcher build running. Expected ~7 min.

## Next Steps

### 1. Test BRK Launcher
Deploy and test. Launcher: `DATA120,24,251,0,0` (SEI,CLC,XCE,BRK,$00).
If game starts: K should show $20 (game bank) with N > $1D00 (turbo).

### 2. Fix Display System
Even if game starts, display won't update without NMI setup:
- Without SCPUMIPS: game enters VBlank wait at $0EE8, hangs (no NMI)
- With SCPUMIPS: crashes from NULL function pointers at $1CB4
- Need to either: populate $1CB4 pointers, or call $0E84 directly, or set up NMI timer

### 3. Investigate Kickstart Boot
The kickstart IS running on our system (from the ROM reset vector). It sets up:
- Handler code in bank $00 SRAM
- Native vectors
- ROM overlay (rom_vis)
Need to understand what state the kickstart leaves the system in, and whether it
conflicts with our ROM stub vectors.

### 4. Potential Kickstart Conflict
The kickstart writes native vectors to $FFEA/$FFEB (NMI) and $FFEE/$FFEF (IRQ).
But our ROM stub ALSO serves these addresses. If the kickstart writes to BRAM but
the ROM stub intercepts reads, the written values are ignored. Need to check if
the kickstart's vectors are compatible with our ROM stub defaults.

## UART Debug Format
`A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx V:xxxx.`
- K=PBR, B=DBR (K:F8 in emu mode = NORMAL, via SuperCPU ROM routing)
- V=native IRQ vector from vec_reg ($FFEE/$FFEF)
- T:13 = turbo=1, rom_vis=1, overlay=1 (normal boot state)
