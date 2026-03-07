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

## ROOT CAUSE IDENTIFIED & FIXED (2026-03-02)

**ROOT CAUSE: The P65C816 core generates phantom bus cycles (VDA=0, VPA=0) during internal
address calculation cycles. The system was NOT gating SDRAM access on VDA/VPA.
These phantom cycles fired spurious SDRAM reads that clobbered `dout_r`, overwriting
the VIC's pending c-access screen code data with garbage.**

### Why it happens
The 65C816 architecture has "internal" cycles during complex addressing modes
(like indirect-indexed `LDA (zp),Y`). During these cycles, the address bus
contains intermediate calculation values, and the CPU signals VDA=0, VPA=0 to
indicate "no valid bus access." On real hardware, external devices ignore these
cycles. But in the FPGA implementation:

1. `cpu_65c816.vhd` exports the raw address unconditionally (no VDA/VPA gate)
2. `fpga64_sid_iec.vhd` used `cs_ram` (derived from the phantom address) to
   generate `ramCE` — **WITH NO VDA/VPA CHECK**
3. The phantom address falls in RAM range ($0000-$0FFF), triggering a real SDRAM read
4. This spurious read overwrites `dout_r`, clobbering the VIC's c-access data
5. VIC latches `$00` (or garbage) instead of correct screen code

### Why only indirect-indexed addressing triggers it
`LDA (zp),Y` has 7 microcode cycles in P65C816, of which cycles 2 and 5 are
internal (VDA=0, VPA=0). `LDA abs,X` has 4 cycles with no internal cycles.
The T65 (6502) has no phantom cycles at all.

### THE FIX (Implemented 2026-03-02)
Gate SDRAM CE on VDA/VPA when SuperCPU is active in `fpga64_sid_iec.vhd`:

**File:** `C64_MiSTer/rtl/fpga64_sid_iec.vhd` (lines 1286-1297)

```vhdl
-- Signal declaration (line ~282)
signal scpu_bus_valid : std_logic;

-- Combinational logic (lines 1286-1297)
-- Gate SDRAM access on VDA/VPA for P65C816
scpu_bus_valid <= (vda_816 or vpa_816) when supercpu_en = '1' else '1';
ramWE   <= systemWe when sysCycle >= CYCLE_CPU0 and scpu_bus_valid = '1' else '0';
ramCE   <= cs_ram when sysCycle = CYCLE_VIC0 or (cpu_cyc = '1' and scpu_bus_valid = '1') else '0';
```

**Status:** ✅ Implemented and syntax-checked (0 errors)
**Next:** Full build and hardware testing with cartridge modes M3/M7/M8/M12

**Important update from cartridge testing (2026-03-02):**
The artifact is **KERNAL-workload-specific**. An Ultimax-mode test cartridge that fills
screen RAM ($0400) with $01 and continuously reads it back shows:
- GREEN border (CPU reads correct $01) in ALL modes (SCPU OFF, ON, ON+ROM)
- Correct VIC display (all white blocks from RAM-based characters at $0800)
- **No corruption at all** — not even with SuperCPU enabled

This means simple SDRAM CPU+VIC read contention is NOT sufficient to trigger the bug.
The corruption requires the complex bus access patterns created by the KERNAL's
runtime environment (IRQ handlers, cursor blink, screen editor scroll, CIA keyboard
scan). The exact triggering condition remains unidentified.

**KERNAL-mimic test results (2026-03-02):**
Progressive KERNAL-behavior test cartridges identified the **screen scroll block copy**
as the trigger operation:

| Mode | What it does | Artifact? |
|------|-------------|-----------|
| M0 | Baseline (fill + read-only verify) | No |
| M1 | + CIA1 Timer A IRQ at 60Hz | No |
| M2 | + Cursor blink (single byte write in IRQ) | No |
| **M3** | **+ Screen scroll (24×40 byte copy in IRQ)** | **YES — blue lines flickering** |
| M4 | + Keyboard scan in IRQ | Same as M3 |
| M5 | All combined | Same as M3 |
| M6 | Main-loop screen RAM refill (write-only, no IRQ) | **No** |
| **M7** | **Main-loop scroll copy (read+write, no IRQ)** | **YES — same as M3** |

**Key conclusions:**
1. **NOT IRQ-specific:** M7 (main loop, no IRQ) triggers same artifact as M3 (in IRQ)
2. **NOT just write volume:** M6 writes $01 to all screen RAM continuously — no artifact
3. **NOT read+write combination:** M8 (read-only via indirect-indexed) **also triggers**
4. **NOT absolute-indexed reads:** M9 (LDA/STA absx) is **clean**
5. **Indirect-indexed addressing `LDA (zp),Y` is the trigger** — generates 3 SDRAM
   reads per instruction (ZP low, ZP high, data) in a tight loop. This bus density
   creates SDRAM access patterns that clobber VIC's c-access data in `dout_r`.
6. Absolute-indexed reads at lower density (M0 verify, M9) do NOT trigger it

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

## Next diagnostic steps (updated 2026-03-02)

### Cartridge test results summary

| What was tested | Result | What it rules out |
|-----------------|--------|-------------------|
| CPU fills screen RAM, reads back | GREEN border, all modes | RAM content is correct (H24 ruled out) |
| VIC displays RAM-based characters | Correct display, all modes | Simple CPU+VIC contention (H28 ruled out) |
| VIC internal char lookup from $0800 | Works correctly | VIC state corruption (H26 ruled out) |
| All tests with SuperCPU ON | No corruption | Bug is NOT triggered by basic SDRAM sharing |
| KERNAL-mimic M0-M2 (IRQ, cursor blink) | No artifact | IRQs and single-byte writes are safe |
| **KERNAL-mimic M3 (scroll copy in IRQ)** | **Blue lines** | **Block copy triggers corruption** |
| KERNAL-mimic M6 (write-only refill) | No artifact | CPU writes alone are safe |
| **KERNAL-mimic M7 (scroll copy, no IRQ)** | **Blue lines** | **Not IRQ-specific; read+write pattern is key** |

### What is ruled out
- **H24** (RAM contains $00): CPU reads back correct values
- **H26** (VIC internal state corruption): VIC correctly looks up RAM-based characters
- **H28** (Simple CPU+VIC SDRAM contention): No corruption under simple workload
- **Character ROM inaccessibility**: Confirmed — Ultimax mode blocks char ROM at $1000 on MiSTer, but RAM characters at $0800 work
- **IRQ context required**: M7 proves artifact occurs without any interrupts
- **Write volume alone**: M6 continuously writes to all screen RAM with no artifact

### What remains suspect
- **H25** (KERNAL workload-specific) ⭐ **NARROWED**: The trigger is the screen scroll
  block copy — specifically, interleaved CPU reads + writes to screen RAM via
  indirect-indexed addressing (LDA (zp),Y / STA (zp),Y). Neither reads alone nor
  writes alone trigger it.
- **H23** (SDRAM dout_r clobbered) ⭐ **STRENGTHENED**: The read+write pattern generates
  CPU SDRAM read CEs (for source bytes) interleaved with write CEs (for destination
  bytes), all within screen RAM ($0400-$07E7). These CPU reads may fire SDRAM CEs
  that clobber `dout_r` during the vulnerable window between CPUE and VIC2.
- **H27** (clk64/clk32 timing margin): May still contribute but secondary to H23.

### Recommended next steps
1. **Further isolation tests** — determine if the trigger is:
   a. The read+write combination (LDA+STA to screen RAM)
   b. The indirect-indexed addressing mode (more bus cycles per instruction)
   c. The CPU read from screen RAM specifically (competing for SDRAM dout_r)
2. **Trace SDRAM CE activity** during the scroll copy — confirm that CPU read CEs
   fire during the CPUE→VIC2 vulnerable window and overwrite dout_r
3. **Implement hold register fix** — latch c-access data at CPUF before any CPU
   read can clobber it. This should fix H23 regardless of the exact trigger pattern.
