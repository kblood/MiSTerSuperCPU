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

## Latest runtime test-suite result (March 2, 2026)
- Runtime mode control via `$D07B` (modes 0..3) is active and visible in overlay row 4 (`M`).
- Across artifact-reproducing workloads, switching modes did not materially change artifacts.
- New counters:
  - `F` (CPUF live-zero count) increases quickly.
  - `P` (CPUE live-zero count) increases quickly.
  - `C` (CPUE live-vs-held mismatch) remains `00`.
- Interpretation:
  - CPUE and held samples are not diverging at compare point.
  - CPUE/VIC2 hold-mux experiment is not the dominant cause in current workloads.
  - Evidence remains consistent with upstream read-side/workload-sensitive behavior.

### Additional user observations from same run
- SCPU OFF: no artifact.
- SCPU ON + Standard ROM: artifact present, repeated row-3 `C:... D:00 ...` captures.
- SCPU ON + SCPU kick ROM: artifact present with similar counter behavior.
- SCPU ON + SCPU kick + Diag ROM: no artifact.
- Cursor movement increases artifact speed/irregularity.
- Tight screen-write loop amplifies artifacts significantly.
- `F` varies run-to-run after reset (timing-sensitive event-rate variation).

## Latest status update (v6 + diag MVP)
- v6 instrumentation changes were implemented:
  - Row-3 label fixed to `C`.
  - VIC-owned buslogic path forced to `currentAddr <= vicAddr` when `cpuHasBus=0`.
  - Full `systemAddr[15:0]` captured/exported with VIC hit.
- Hardware capture after v6:
  - `C:0590 01 D:00 S:0590`
  - Confirms address match at hit time (`vicAddr == systemAddr`) while VIC still consumes `$00`.
- New diagnostic KERNAL MVP (menu-driven) was created and loaded as `debug_system.rom`.
  - MVP also reproduces scrolling-line behavior.
  - Earlier standalone V22 diagnostic ROM reportedly does not.
  - Therefore behavior is sensitive to exact ROM workload/timing, not simply "diagnostic ROM" category.

## New evidence (v5 c-access capture)
- v5 captured: `I:0617 01 00 17`.
- The `I:` prefix is a display glyph bug in the overlay VIC-hit row and should be `C:`.
- Decode:
  - `0617` = vicAddr latched at CPUC (c-access screen RAM address)
  - `0` = cpuHasBus@CPUC (real badline steal)
  - `1` = aec@VIC2
  - `00` = vicDi@VIC2 (VIC consumed `$00`)
  - `17` = systemAddr[7:0]@CPUC (address low byte match)
- This confirms the corrected CPUC->VIC2 c-access pipeline is triggering as intended.

## v6 implementation set (completed)
1. Row-3 VIC-hit label fixed to `C`.
2. In buslogic VIC-owned path (`cpuHasBus=0`), `currentAddr` now uses `vicAddr`.
3. Full `systemAddr[15:0]` capture/export added for VIC-hit diagnostics.

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

## Current best root-cause statement

The VIC-II receives `$00` during real badline c-access fetches.
Address routing at capture point matches (`vicAddr == systemAddr`), so the remaining
fault is data-side: either true RAM content is `$00` at that location, or returned data
is stale/clobbered before VIC consumes it.

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

## Active instrumentation (current tree, v6)
- Capture latches vicAddr + full systemAddr at **CPUC** (c-access address phase)
- Checks `vicDi` at **next VIC2** with badline gate (`cpuHasBus_lat='0'`)
- Row 3 format: `C:vvvv HA D:DD S:SSSS`
  - `vvvv` = vicAddr@CPUC
  - `H` = cpuHasBus@CPUC
  - `A` = aec@VIC2
  - `DD` = vicDi@VIC2
  - `SSSS` = full systemAddr@CPUC

## Next diagnostic steps
1. Add sticky provenance capture of first VIC-zero event:
   - VIC hit addr/data
   - last CPU write to same addr (data/PC/bank)
   - age since that write.
2. Use this to determine whether VIC is consuming true RAM `$00` or corrupted read-return data.
3. If provenance shows recent nonzero writes before VIC-zero hits, focus on upstream SDRAM/CE/read-return integrity.
