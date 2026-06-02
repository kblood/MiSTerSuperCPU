# Session handoff — 2026-06-02 (iter-14)

## HEADLINE
The same-line 2× alt-fire speed lever advanced from "policy realizable" to a
**falsified-and-corrected, build-ready design**. Three off-device results, all
committed; the next step is the first RTL realization (a single gap-gated enable
scheduler), validated by the `c64_reduced_harness` boot test, then build → STA → HW.
MiSTer was contended/stale-locked (ao486, CORENAME=MENU) → all work off-device by design.

## What landed this session (commits)
1. `ade5aac` — **mode 5** (handoff step 2 closed): the realizable E-1 1-clk-enable
   decision (cache's LIVE `same_line` registered once = `sl_d1`) reproduces the mode-2
   ORACLE gating policy **byte-for-byte** (0 stale, 2.93 clk32/access, identical
   per-latch schedule). Proves the decision phase is realizable, not just the policy.
2. (Codex falsification, `tools/codex-out/iter14-altfire-falsify.txt`) — **verdict
   do-not-build.** Found the bug the bench masked: `same_line` is line/tag equality
   ONLY (cpu_cache.vhd:180), NOT a valid-byte hit (:269-276); fills are per-byte on
   accepted misses. A cold line can be `same_line=1` but `cache_hit=0` → a fast 2-apart
   fire consumes stale `cpuDi_nocache`.
3. `88e0aa3` — **mode 6 + PREFILL=false** reproduces Codex point 4 AND proves the fix:
   - PREFILL=false, mode 5 (same_line only): **FAIL 7** (FAST-MISS stale, csl=2).
   - PREFILL=false, mode 6 (`sl_d1 AND rp_cache_hit_d1`): **PASS 0**, 3.86 clk32/access.
   - PREFILL=true (warm): modes 2/5/6 all PASS at 2.93 (hit-gate is free when warm).
   Steady-state (warm loops, e.g. Doom) = 8MHz on same-line runs; cold first-touch stays
   4-apart and correct. **mode 6 is the corrected realizable design.**

Bench: `sim/cache_coherency_tb/cpu_cache_altfire_race_tb.vhd` (+ `run_altfire_race.ps1`,
sweeps modes 3/0/1/2/5/6 warm, then 5/6 cold). Generics: `GATE_MODE`, `PREFILL`.

## The corrected RTL design (full spec: docs/iter14_altfire_rtl_brief.md "CORRECTED DESIGN")
Architecture conclusion from Codex points 1+4: "fixed 4-apart mains + inserted fast
pulses" CANNOT work (post-fast main slot becomes an ungated 2-apart consume; mode 1
= 2 residual fails). The RTL must be a **single registered gap-gated scheduler** that
owns `enableCpu` in SuperCPU mode (does NOT tap `cpu_cyc_s` for the 816 enable when
active), behind `constant ALT_FIRE_SAMELINE` (baseline-identical when false):
```
fire = cpu_consume_slot AND base_permit       -- keep cs_ram / io@CPUC / not throttle / not dma / baLoc
       AND ( csl >= 4                          -- full margin = proven 4-apart cadence (also bank-$00/I/O/miss)
           OR ( csl >= 2 AND scpu_fast_path AND rp_same_line_d1 AND rp_cache_hit_d1 ) )  -- fast 2-apart
enableCpu <= fire   -- registered; fast path = 1-clk enable
```
- csl resets to 1 ONLY on accepted `fire`; +1 else; runs across the EXT/DMA/VIC gap.
- Wire `read_path_cache.same_line => rp_same_line` (today `open`), register once in
  `gen_read_path` → `rp_same_line_d1`. Set `CACHE_READ_PATH=true` (HW-proven clean at
  4-apart, iter-7e `e9c36c3e`).
- Names confirmed collision-free: rp_same_line, rp_same_line_d1, ALT_FIRE_SAMELINE, etc.

## NEXT STEP (off-device first — local probe available)
1. Implement the scheduler behind `ALT_FIRE_SAMELINE` + the same_line wiring.
2. **Off-device sanity via `sim/c64_reduced_harness`** (run_harness.ps1) — LIMITED:
   per iter-7e it stalls at `final_pc=$FD83` (RAMTAS loop; simple_sdram_model RAM-sizing)
   and never reaches BASIC. So it CAN catch a gross scheduler wedge (CPU stops advancing
   in the $FD83 loop) but CANNOT validate the I/O/throttle/badline subsumption — that
   (the riskiest part of the single-scheduler) is HW-only. Plan accordingly: build the
   scheduler maximally gated/baseline-identical-when-off, lean on the $FD83 sanity +
   STA, and treat the HW boot+Lorenz as the real subsumption gate.
3. Build (local, ~30-40 min) → **STA** (Codex point 5: the new enable FF + 1-clk fast
   path setup/hold; iter-12 showed rp_cache_hit_d1→ALU closes setup-1 +7.884 — data side
   fits; MEASURE the FF with cache_path_probe.tcl).
4. **HW gate** (needs a free MiSTer): boot clean + Lorenz scpu/t65 100% + Doom + Wolf3D
   no-regress + `superram_bench` COUNT > control $0335 (proves speedup) + effective MHz.

## Device / cooperation
- Control build `97392a1f` = healthy reference (Lorenz scpu/t65, Doom, Wolf3D PASS). NOT deployed.
- MiSTer at last check: CORENAME=MENU, ao486 lock from 07:41 (stale >30 min). Re-check
  ownership before any HW action.

## RTL state: CLEAN. No shipped RTL change this session — three sim/doc commits only
(`cpu_cache.vhd` and `fpga64_sid_iec.vhd` untouched). The speed lever is the live thread:
2× alt-fire is no longer just "policy proven" — it has a falsified-and-corrected,
spec-complete design (mode 6 hit-gate + single scheduler). Only the scheduler RTL +
reduced-harness boot + STA + HW gate remain.
