# Plan — Step 6: RDY-Handshake SDRAM Bus Interface

**Status:** Active. Created 2026-05-20 after the v1-v4 CONFLICT-gate attempts wedged in spite of correct paper traces.
**Branch:** `step6-rdy-handshake` (off `step5-altslot-registered`)
**Working baseline:** Step 5a (RBF md5 `3ba225b0…`) — registered alt_fire_r on Build B, 1.5× Doom, Lorenz PASS.

## Motivation

External research doc (`docs/external_supercpu_architecture_research.md`) crystallized
the architectural distinction we'd been glossing over: our current arbiter uses
**fire-and-pray timing** — it predicts SDRAM completion with a hardcoded
busy-counter, then schedules the CPU sample edge a fixed number of clk32 later.

That works for Build B because Build B's SDRAM cycle is uniform (8 clk64 = 4 clk32),
so the prediction is always right. It fails for Build C because Build C's cycle is
variable (3/5/8 clk64 for HIT/COLD/CONFLICT). v1–v4 tried to bolt conditional
stalls on top of the predictor; static traces said v4 was correct, but HW disagreed
across all four variants. Suspect synthesis or undocumented SDRAM/chip-internal
timing diverging from paper math.

The proper fix is to replace the predictor with **a handshake**: the SDRAM signals
"data is now valid in dout_r" and the arbiter waits for that signal before firing
`enableCpu`. No prediction, no race.

## Architecture

### Current (fire-and-pray)

```
cpu_cyc fires at clk32 K → ramCE rises → sdram_pm starts cycle
cpu_cyc_s shift register adds fixed 2-clk32 delay
enableCpu rises at clk32 K+2 → CPU samples cpuDi at K+3 rising edge
                                    ^
                              MUST hope dout_r is fresh by here
```

### Proposed (handshake)

```
cpu_cyc fires at clk32 K → ramCE rises → sdram_pm starts cycle
sdram_pm asserts `data_valid` post-edge of the path's sample q
data_valid_sync(0) captures it at next clk32 rising edge
enableCpu rises after data_valid_sync(0) sees '1'
CPU samples cpuDi at the next clk32 rising edge → dout_r guaranteed fresh
```

The handshake is naturally elastic: HIT cycles (q=3 sample, dout_r fresh at clk64
#2K+4 post) free the CPU earlier than COLD (q=5 sample) which is earlier than
CONFLICT (q=7 sample). No conditional stall logic needed — the same gate fires at
the right edge for each path.

## Phased Implementation

### Phase 6a — `data_valid` plumbing (small, safe)

Goal: route a "dout_r is fresh" pulse from sdram_pm to the clk32-domain arbiter.

1. **`sdram_pm.v`** — add `output reg data_valid` set high on the dout_r update
   edge (q=5 for COLD, q=3 for HIT, q=7 for CONFLICT). Clear at next ce-edge so
   it's a level-stable handshake (high from sample-edge through next cycle start).
2. **`c64.sv`** — add a wire `sdram_data_valid`, pipe it from the sdram_pm
   instantiation through to `fpga64_sid_iec` as a new port.
3. **`fpga64_sid_iec.vhd`** — declare new input port `sdram_data_valid : in std_logic`
   and a single-flop sync `sdram_data_valid_sync` in the clk32 process.

Don't change the gating yet. Mark the sync signal `preserve` so Quartus doesn't
optimize it away. Build and confirm Lorenz/Doom unchanged.

**Exit criteria**: build succeeds, Lorenz t65 PASS, Lorenz scpu PASS, Doom hashes
match Step 5a baseline.

### Phase 6b — gate `enableCpu` on `data_valid_sync` (Build B only)

Goal: prove the handshake gating works on the known-good Build B SDRAM controller.

1. Replace `enableCpu <= cpu_cyc_s(1);` with logic that holds enableCpu low until
   `data_valid_sync(0) = '1'` after a cpu_cyc fire.
2. Keep the cpu_cyc_s shift register as a one-shot "edge detector" tracking
   in-flight CPU cycles, but use `data_valid` (not a fixed delay) to release.
3. Add a guard so non-SDRAM cycles (e.g., I/O at $D000-$DFFF that bypass SDRAM)
   still fire enableCpu without waiting (use `cs_ram` and `cart_mem_req` to
   decide which path is in flight).

**Risk**: Build B's `data_valid` fires at clk64 #2K+5 post, sync sees it at
clk32 K+3 rising — same edge as the existing cpu_cyc_s(1) pipeline drives
enableCpu. So this should be functionally equivalent on Build B. Any difference
is a bug.

**Exit criteria**: same as Phase 6a.

### Phase 6c — re-introduce Build C (page-mode sdram_pm)

Goal: bring back the page-mode controller now that the arbiter no longer assumes
a fixed cycle length.

1. Cherry-pick `sdram_pm.v` from commit `92d5be2` (the v4 branch) **without** the
   `is_conflict` output port — Phase 6b's `data_valid` handshake replaces the
   need for the gate.
2. Verify the C64.sdc filter still matches the renamed entity (`sdram_pm:sdram`
   pattern — see `feedback_renaming_sdram_entity_breaks_sdc.md`).
3. Smoke test: KERNAL boots clean, Lorenz PASS, Doom progresses.

**Expected outcome**: HIT path (3 clk64) frees `enableCpu` earlier, so subsequent
CPU accesses cluster faster. Even without alt-slot firing, single-CPU-slot HIT
cycles should give a noticeable speedup on Doom's tight inner loops.

### Phase 6d — HIT early termination

Goal: allow sdram_pm to accept a new ce-edge before the full 8-clk64 envelope
completes, so HIT cycles can back-to-back at ~3 clk64 instead of 8.

1. In sdram_pm.v, after a HIT path completes (q=3 sample), wrap q to 0 instead
   of continuing 4→5→6→7→0. Equivalent: `if (path==P_HIT && q==3) q <= 0;`
2. ce-edge handling already supports re-entry (the `if (ce && !last_ce)` block
   forces q=1 unconditionally).
3. Re-enable the alt-slot fire path (CPU2/6/A/E) — since HIT clears `data_valid`
   ~1.5 clk32 after cpu_cyc, the alt-slot at CPU1 boundary sees data_valid_sync='1'
   → alt_fire_r latches '1' → CPU2 fires.

**Expected outcome**: True 2× speedup on HIT-pattern code (Doom's renderer
working with adjacent rows in the same bank).

### Phase 6e — instrumentation & validation

1. Doom smoke test with hash comparison vs Step 5a baseline at t=30/60/90/120/150/180s.
2. Wolf3D smoke (use v356 baseline path — `python tools/wolf3d_v356_PLAY.py`).
3. Lorenz full run (t65 + scpu modes, 30 min each).
4. Document the achieved speedup in a memory file.

## Implementation order constraint

Phases must land in 6a→6b→6c→6d order. Skipping ahead risks the same
"correct on paper, wedged on HW" failure mode as v1-v4: each phase introduces ONE
testable change, so any regression localizes to one commit.

## What we explicitly drop

- The CONFLICT-gate conditional stall (v1-v4) — superseded by handshake.
- The busy_counter as a CPU-sample timing source — superseded by data_valid.
  (We may keep `sdram_busy_cnt` as a back-pressure signal for the alt-slot fire
  decision in Phase 6d if needed, but it no longer drives enableCpu.)
- The `is_conflict` output from sdram_pm — Phase 6c drops the page-mode
  conflict path optimization. CONFLICT cycles fall back to COLD (PRECHARGE +
  ACTIVE + READ at q=2 — slower than the v4 PRECHARGE+ACTIVE+READ-at-q=4 pipe,
  but correct.

## Rollback plan

If any phase introduces a regression that can't be diagnosed in 1-2 build iterations:
- Revert that phase's commit
- Step 5a remains as the safe deployable baseline
- File a memory note documenting the symptom
- Move on; don't repeat the v1-v4 spin pattern

## Files we'll touch

- `C64_MiSTer/rtl/sdram_pm.v` — add `data_valid`, later re-introduce page-mode
- `C64_MiSTer/c64.sv` — wire `data_valid` from sdram_pm to fpga64_sid_iec
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — add port, sync, gate enableCpu
- `C64_MiSTer/C64.sdc` — sanity-check entity name match (Phase 6c)
- `tools/option_c/step2_smoke.py` — reuse for regression
- `tools/lorenz_run/scpu_run.py`, `tools/lorenz_run/t65_run.py` — Lorenz regression

## Open questions

1. **Single-flop vs two-flop sync on data_valid**: data_valid is a level signal
   that stays high for many clk64. Single-flop is sufficient for metastability;
   two-flop adds 1 clk32 latency. Start with single-flop + `preserve` attribute.
2. **Non-SDRAM cycle handling in Phase 6b**: cycles to $D000-$DFFF (I/O) don't
   touch SDRAM. They currently fire enableCpu via the cpu_cyc_s pipeline. The
   handshake gate must let them through without waiting for `data_valid`. Easiest
   solution: skip the wait if `cs_ram = '0'` at cpu_cyc-fire time.
3. **DMA cycles**: REU DMA bypasses the CPU entirely (`dma_active='1'`). Confirm
   the gate doesn't interfere with DMA path.
