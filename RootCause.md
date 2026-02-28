# P65C816 SuperCPU Runtime Artifact - Root Cause Status

## Scope
Two distinct issues were investigated:
1. BRK/RTI failure in emulation mode (resolved)
2. Standard-ROM runtime `@` scrolling with SCPU enabled (still open)

## Resolved issue: BRK/RTI failure
- A temporary debug edit added an extra RTI microcode stage in `rtl/65C816/MCode.vhd`.
- That stage broke BRK/IRQ return flow in emulation mode.
- Reverting RTI to the original sequence fixed the crash/hang behavior.
- Diagnostic ROM overlap bug at `$FF20-$FF22` was fixed by moving the helper routine.
- Validation:
  - V19 (BRK push-byte bypass test): pass
  - V20 (real RTI path): pass
  - V22 (extended IRQ stress): pass — all 10 tests show P (pass)
  - Standard C64 ROM boot restored with SCPU enabled

## Current unresolved issue: standard-ROM `@` artifact
- With standard ROM + SCPU enabled, visible scrolling `@` artifacts still occur at READY.
- The diagnostic ROM (V22) does NOT show the scrolling `@` lines. All 10 tests pass cleanly.
  Earlier diagnostic ROM versions DID show the scrolling lines, but V22 does not.
- This means the artifact is specific to the standard KERNAL ROM execution environment,
  not a general CPU correctness issue.

## Hardware evidence — write-side ruled out

1. **Baseline overlay capture (before cursor filtering)**
   - `W:04F0 D:20/A0 P:EA20 91`
   - Normal KERNAL cursor blink writes (space/reverse-space).

2. **After filtering cursor-blink writes (PC $EA20 at any address)**
   - `W:0400 D:20 P:EA0E 91`
   - KERNAL space-fill loop (`STA ($D1),Y` at $EA0E). Normal screen maintenance.
   - Also saw `W:04CD D:2E P:EA20 91` before broadening the cursor filter.

3. **Sticky $00 capture: NO $00 writes detected**
   - A one-shot sticky capture was added that freezes on the first CPU write of
     data=$00 to screen RAM ($0400-$07FF). After running with `@` artifacts
     visibly scrolling, the sticky capture never triggered (row 3 still shows `W:`
     label, not `0:` frozen label).
   - **This definitively rules out the CPU writing $00 to screen RAM.**

4. **Address gating hardening trial**
   - `supercpu_cycle` tightened to `cpu_cyc and cs_ram and cpuHasBus`.
   - No change in artifact behavior.

## Hardware evidence — read-side CONFIRMED

5. **VIC read capture v1 (CYCLE_VIC3 check) — false positive**
   - Checked `vicDi` at CYCLE_VIC3 (g-access timing). Did NOT trigger.
   - This was checking bitmap data, not screen code data.

6. **VIC read capture v2 (CYCLE_CPUE, no cpuHasBus gate) — false positive**
   - Checked `vicDiAec` at CYCLE_CPUE. Triggered immediately.
   - `R:0400 01 3F 00` → aec=0, cpuHasBus=1, vicDi=$3F, vicBus=$00
   - cpuHasBus=1 means NOT a badline steal. VIC ignores `di` (uses charStore).
   - False positive: vicBus happened to be $00 during a non-badline cycle.

7. **VIC read capture v3 (CYCLE_CPUE + cpuHasBus=0 gate) — CONFIRMED**
   - Added `cpuHasBus = '0'` requirement to only trigger during real badline steals.
   - `R:0401 01 00 FF` → baLoc=0, aec=1, vicDi=$00, vicBus=$FF
   - **SDRAM returned $00 during a real badline c-access.**
   - aec=1 confirms vicDiAec=vicDi (mux is correct). vicBus=$FF (not involved).
   - The VIC latches vicDi=$00 (screen code `@`) instead of $20 (space).

## Confirmed root cause: SDRAM returns wrong data during badline c-access

The VIC-II receives $00 from the SDRAM data path during real badline character
pointer fetches (c-access). The aec mux is correct, the address routing is plausible.
The SDRAM data itself is wrong.

## SDRAM pipeline timing analysis

The SDRAM controller (sdram.v) has CAS latency=2, RASCAS_DELAY=2:
- STATE_READ = 0 + 2 + 2 + 1 = 5 → data captured at q=5
- From CE rising edge to dout_r valid: **5 clk64 = 2.5 clk32 cycles**

SDRAM CE fires at:
- **VIC0**: ramCE for VIC g-access → data in dout_r at VIC0+2.5 = between VIC2-VIC3
- **CPUC**: cpu_cyc for c-access/CPU → data in dout_r at CPUC+2.5 = between CPUE-CPUF

VIC latches:
- **VIC2** (enaData=1, phi=0): g-access → gets **previous CPUC** read result
- **CPUE** (enaData=1, phi=1): c-access → gets **current VIC0** read result

**The c-access screen code data the VIC latches at CPUE comes from the VIC0 SDRAM read.**
This is a deliberate pipeline: VIC outputs c-access address at VIC0, data arrives at CPUE.

## Active instrumentation (current tree, v4)
- Capture latches vicAddr AND systemAddr at **VIC0** (pipeline-correct for c-access)
- Checks `vicDiAec` at **CPUE** with `cpuHasBus='0'` gate (real badline only)
- Row 3 format: `R:vvvv BA DD SS`
  - vvvv = vicAddr at VIC0 (address VIC requested)
  - B = baLoc, A = aec (at CPUE)
  - DD = vicDi[5:0] at CPUE (SDRAM data)
  - SS = systemAddr[7:0] at VIC0 (actual address sent to SDRAM)
- If vvvv[7:0] ≠ SS → buslogic routed wrong address to SDRAM at VIC0

## Next diagnostic steps
1. **Build and test v4 capture**: Check if vicAddr matches systemAddr at VIC0.
   If they differ, the buslogic address mux is corrupted at VIC0 time.
   If they match, SDRAM is reading from the correct address but returning wrong data.
2. **Investigate SDRAM read collision**: Check whether a SuperCPU-related SDRAM access
   between VIC0 and CPUE could restart the SDRAM controller's state machine (q counter),
   clobbering the VIC0 read before data is captured.
3. **Check refresh timing**: Verify auto-refresh doesn't collide with VIC0 CE.
