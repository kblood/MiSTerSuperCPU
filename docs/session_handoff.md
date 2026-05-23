# Session handoff — 2026-05-23 end-of-session (REVISED 3)

## TL;DR — Milestone A is at its ceiling; only Milestone B remains

Three things landed this session in `milestone-a-build-c-revival`:

1. **Single root cause for bank-$20 wedge AND "LDA al → STA hazard"**:
   Step 7b's `alt_fire_r2`. Hard-gating it OFF (commit `c254063`)
   made every previously-wedging probe pass, including
   `superram_bench` showing live PASS/COUNT for the first time.

2. **Bench metric corrected**: PASS/sec is capped at ~61/sec by Timer
   A latch ($4000 phi2 in 1 MHz domain) and is **independent of CPU
   speed**. The real CPU-speed signal is **COUNT-per-PASS** —
   inner-loop iterations per fixed-time window. Baseline on the
   alt_fire_r-ON build: ~2575 iter/window.

3. **Step 5 `alt_fire_r` is dead on Build B**: controlled-variable
   build (RBF `453a3380`, BOTH alt-fires off) shows COUNT-per-PASS
   bit-identical to the alt_fire_r-ON build (RBF `a993d7b7`).
   ~0% contribution. Build B's SDRAM cycle is fundamentally too
   long for any alt-slot CPU fire to be safe. **Path C alt-slot
   is dead.** Only Milestone B remains as a forward path.

## Path forward — go to Milestone B

Per `docs/path_to_20mhz_plan.md` and
`docs/async_bridge_phase_f_revised.md`:

- F.0: read-only verification of `enableCpu_816` as capture strobe.
  Most of this is already documented; needs a 2-3 paragraph
  "decision-point #1" note answering the CPU-write payload question.
- F.1': re-engage bridge port-signature, lock `BRIDGE_ACTIVE='0'`,
  add `SAME_CLOCK_PASSTHROUGH` generic.
- F.2: upgrade GHDL bench `sim/p65c816_tb/` to two clock domains.
- F.3': arbiter pre-fetch redesign at `clk_cpu = clk64`. Highest
  wedge risk. Cannot start until F.1' baseline is bit-identical
  to current HEAD on hardware.
- F.4: Doom/Wolf3D/Lorenz regression.
- F.5: cache re-enable (optional).

Suggested Milestone B starting tasks (cold-start checklist):

- [x] Re-read `docs/async_bridge_phase_f_revised.md` (revised plan
      after the F.1 four-rung wedge ladder)
- [x] Re-read `docs/async_bridge_mcp_handshake_plan.md` for F.0/F.1
      detail (still authoritative for those phases)
- [x] Spawn F.0 note: see Appendix A (2026-05-21) and Appendix B
      (2026-05-23 freshness check) in the plan doc. Line numbers
      drifted; claims still hold. Decision point #1 resolved.
- [x] Branch off `milestone-a-build-c-revival` HEAD into
      `milestone-b-cdc-rewrite`
- [x] Restore F.1 MCP FSM as `tools/scpu_async_bridge_F1_backup.vhd`
      (out-of-tree, 363 lines from commit 7f9dced)
- [x] F.3' arbiter prefetch design sketch landed at
      `docs/async_bridge_f3_prefetch_sketch.md` (2026-05-23):
      latency budget at 2:1 clock ratio, `cpu_cyc` (combinational,
      2 clk_sys ahead of `enableCpu`) chosen as strobe source over
      `cpu_cyc_s(0)`, cancel path via existing `dma_active` /
      `baLoc` gating, port-shape with new
      `bus_request_strobe_in` + `SAME_CLOCK_PASSTHROUGH` generic.
      Three open questions for the user at §5.
- [x] User answered §5 questions: (q1) sink waits, no rollback;
      (q2) parametric RATIO; (q3) F.3' first, Build C after.
- [x] F.2 bench upgrade landed (commit `ac7caf1`):
      `sim/scpu_async_bridge_tb/bridge_tb.vhd` now takes RATIO and
      PASSTHROUGH_MODE generics. Validated all four configs:
      RATIO={1,2,3} PASSTHROUGH=1 pass, RATIO=2 PASSTHROUGH=0
      hard-fails on scenario E (correctly catches missing MCP FSM).
      run_bridge_tb.ps1 takes -Ratio and -Passthrough params.
- [ ] **NEXT:** restore the F.1 MCP FSM bridge from
      `tools/scpu_async_bridge_F1_backup.vhd` as the active
      `C64_MiSTer/rtl/scpu_async_bridge.vhd`. Add
      `SAME_CLOCK_PASSTHROUGH` generic defaulting to '1' so HEAD
      baseline is preserved; add `bus_request_strobe_in` port and
      wire to `cpu_cyc` per `docs/async_bridge_f3_prefetch_sketch.md`.
      Then validate against bench scenarios with PASSTHROUGH=0.

## State on disk (REVISED 3)

- Branch: `milestone-a-build-c-revival`
- Source has BOTH alt-fire blocks commented out (alt_fire_r at
  `fpga64_sid_iec.vhd:2831-2843`, alt_fire_r2 at `:2854-2862`).
- RBF on MiSTer: `/media/fat/_Test/C64.rbf` md5 `453a3380` (both off).
- Bench probes saved at `tools/test_cart/out/_bothoff_t{1,2}.png` and
  `_baseline_t{1,2}.png`.
- Memory:
  - `project_step7b_alt_fire_r2_confirmed_2026_05_23.md`
  - `project_lda_al_sta_hazard_2026_05_23.md` (resolved)
  - `project_superram_bench_metric_2026_05_23.md`
  - **NEW**: `project_alt_fire_r_dead_on_buildB_2026_05_23.md`

## What's the actual baseline now?

Build B at HEAD with both alt-fires OFF gives:
- KERNAL boots clean to READY prompt.
- `superram_bench`: ~2575 inner-loop iter/16.4ms = ~157 K bank-$20
  RMW-style iter/sec. Equivalent to ~3 MHz effective on the SuperRAM
  bank with multi-cycle RMW + bank-0 long-LDA mixed.

This is the Build-B physical ceiling. To exceed it, either Build C
page-mode (locked-deferred until Milestone B integration) or
Milestone B's clk_cpu doubling must land.

## Commits this session

- `2407264` test_cart: bisect pins LDA-al → STA hazard (1 NOP fixes)
- `8fbe7cf` test_cart: bank-$20 wedge is NOT the LDA-al hazard
- `44d9de9` docs: session_handoff — LDA-al → STA hazard pinpointed
- `ed8b72a` docs: handoff — bank-$20 wedge → alt_fire_r2-OFF RBF
- `c254063` fpga64_sid_iec: hard-gate alt_fire_r2 OFF (Step 7b cause)
- `442176f` docs: session_handoff FINAL (hazard collapse)
- `312943b` docs: session_handoff (hazard collapse 2)
- `0903443` docs: end-of-session handoff full rewrite (early)
- `6e90292` docs: Step 7b deferred to Build C
- *(pending)* fpga64_sid_iec: gate alt_fire_r OFF + characterize
  Step 5 dead on Build B + memory entries

## Pointers

- `docs/path_to_20mhz_plan.md` — Milestones A/B/C.
- `docs/async_bridge_phase_f_revised.md` — revised Phase F plan.
- `docs/async_bridge_mcp_handshake_plan.md` — F.0/F.1 detail.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2827-2862` — both alt-fire
  blocks currently commented.

MiSTer IP `192.168.50.130`, root/1. RBF md5 `453a3380` at
`/media/fat/_Test/C64.rbf`. Don't touch `/media/fat/_Computer/`.
