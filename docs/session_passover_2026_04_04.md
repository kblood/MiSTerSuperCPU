# Session Passover - 2026-04-04

## Goal
Continue investigating why Doom's display doesn't update (stuck on BASIC screen).

## Key Findings

### Doom Display Architecture
- Doom uses **raster IRQ** for display updates (NOT polling as initially suspected)
- The raster IRQ setup function is at `$80:0B80-0BB6`
  - Sets native IRQ vector ($FFEE/$FFEF) to `$0D3C` (trampoline in bank $00)
  - Sets raster compare from dp `$90/$91`
  - Enables raster IRQ ($D01A = $01)
  - CLI (enables interrupts)
- The actual IRQ handler is at `$80:0900+` (jumped to from trampoline at $00:0D3C)
  - Writes $D018, $D011, $D022 (VIC display setup)
  - Ends with PLA/$01 restore/REP#20/PLB/PLD/PLY/PLX/PLA/RTI
- ALL VIC register writes ($D011, $D018, $D016, $D020, $D021) are in bank `$80`
- Bank `$2C` (game loop) has 10 JML calls to bank `$80` entry points
- Bank `$2C` has 0 JSL calls to bank `$80` (all cross-bank calls use JML)

### Vsync Detection
- Doom polls `BIT $D011` (not $D012) for vsync
- Pattern at `$81:0774`: `BIT $D011 / BPL (loop) / BIT $D011 / BMI (loop)`
- Waits for bit 7 (raster > 255) then waits for wrap-around

### Why Display Doesn't Update
The display is unchanged because the raster IRQ handler never fires. This requires:
1. Bank `$80` setup code to run (sets vector, enables IRQ, CLI)
2. IRQ trampoline at `$00:0D3C` to exist (block-copied during init)
3. VIC raster IRQ to fire (requires $D01A bit 0 = 1)
4. CPU I flag = 0 (requires CLI)

UART shows `P:04` (I=1, interrupts disabled), confirming the IRQ setup never completed.

### Possible Root Causes
1. **Bank $80 code never executes** — the init flow from $20→$2C might skip $80 setup
2. **MVN/MVP block copy to bank $00 fails** — trampoline at $00:0D3C never written
3. **IRQ vector mechanism broken** — $FFEE/$FFEF readback incorrect
4. **BRAM interference** — BRAM serves stale data for $FFEE instead of scpu_native_vec

### VIC Write Counter Diagnostic (Attempted)
- Added saturating VIC write counter to B field of UART
- Build succeeded but fitter timing regressed (-16ns vs -15ns previous)
- New build crashed (BRK, I:00) — fitter placement caused SDRAM corruption
- Reverted diagnostic, rebuilding with original code

### Fitter Timing Sensitivity
- The SDRAM timing fix (pre-registered clk64 address) only reduces slack from -24ns to -15ns
- Different fitter placements can worsen timing beyond the -15ns baseline
- Any code change risks fitter regression
- Need a more robust fix for the clk32→clk64 timing path

## Build State
- Both diagnostic and reverted builds produce -16ns clk64 slack → BRK crashes
- Previous stable build (Apr 3 23:58) had -15ns (better fitter placement, nondeterministic)
- **FIX ATTEMPTED**: Added `set_multicycle_path -setup 2` for clk32→clk64 crossing
  - New file: `C64_MiSTer/C64.sdc` (added to C64.qsf)
  - clk32 data is stable for 2 clk64 periods (31.7ns), not 1 (15.8ns)
  - Should improve slack from -16ns to approximately -0.4ns or positive
  - **Result**: clk64 timing FIXED (+1.053ns positive slack!)
  - But clk32 self-domain still at -5.768ns → CPU data corruption
  - Doom crashes to bank $E0 (all zeros → BRK loop) — corrupted JML target
  - **Fitter Fmax for clk64**: 81.75 MHz (was <63 MHz without constraint)
  - Need to fix clk32 self-domain timing next

## Research Agent Findings
- Doom is a **MIPS-to-65816 static recompilation** (AmiDog's recompiler)
- Game loop busy-waits on `I_GetTime()` which reads a timing counter
- Counter is incremented by raster IRQ handler
- If IRQ never fires → counter never advances → infinite busy-wait
- Source: https://scpu.amidog.se/doku.php?id=scpu:doom

## Next Steps
1. **Verify rebuild matches previous behavior** — Doom should run stably at K:2C
2. **Investigate why bank $80 code doesn't execute** — trace init flow from $20
3. **Check IRQ delivery** — verify VIC IRQ reaches the CPU in native mode
4. **Consider alternative diagnostic** — use existing debug registers instead of adding new ones
5. **Fix SDRAM timing properly** — the -15ns slack is too marginal

## Test Commands
```bash
# Deploy + set baud
python tools/mister_debug.py deploy
# (then set baud via paramiko)

# Load doom.reu via MGL + redeploy
# (see MGL method in docs)

# Skip loader (type via mtype.py):
# 10 FORI=0TO6:READA:POKE49152+I,A:NEXT
# 20 DATA120,24,251,92,0,0,32
# RUN
# SYS49152

# Monitor
python tools/mister_debug.py uart 5
```
