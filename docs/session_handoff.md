# Session handoff — 2026-05-22 (Milestone A scaffolding in flight)

## TL;DR
After the Phase F.1c–F.1f wedge ladder (rolled back per `80dc8d7`), we
pivoted to a multi-milestone plan in `docs/path_to_20mhz_plan.md`. This
session executes **Milestone A scaffolding-first**:

1. **Step 6 (busy_counter + sdram_ready_sync edge feedback)** — committed
   to working tree on top of `80dc8d7`. **Verified no-op on Build B** via
   32-min SCPU Lorenz pass (final md5 `2ade55b0a1cc`, 60 shots, time-cap
   1923s with CHANGE on every frame). Snapshot baseline at
   `tools/lorenz_run/scpu_2026-05-22_step6_baseline/`.
2. **Build C `sdram_pm.v` (HIT early-exit)** — drafted in working tree.
   Syntax check PASS (0 errors). Full build in flight (background task
   `b5t0ke9qa`). Once it completes, deploy + Lorenz + Doom regression.

The plan is `path_to_20mhz_plan.md`; the per-phase risk register lives
inside that doc. Phase F revision is at `async_bridge_phase_f_revised.md`.

## Architectural note on Milestone A
Detailed analysis of the sync-chain latency: with the existing 2-FF
`sdram_ready_sync` chain (line 735), the early-clear path in Step 6 fires
at clk_sys T+4 for both Build B (static decrement reaches 0 at T+4) and
Build C HIT (sync edge at T+4). **So at the arbiter level Build C HIT
delivers no measurable speedup yet** — the 2-FF sync eats the HIT path's
4-clk64 advantage. Milestone A is therefore correctly characterized as
*scaffolding without perf gain* — the actual speedup needs single-FF sync
(metastability-safe because `data_valid` is a level signal) or Milestone B's
clk_cpu=clk64 + F.3' prefetch.

**Decision**: Build C compile + HW regression is the value being delivered
this milestone — proves the new controller doesn't wedge. The HIT early-
exit primitive becomes useful as soon as Milestone B's CDC rework lands.

## Tree state
- Branch: `milestone-a-build-c-revival`
- HEAD: `80dc8d7` (`fix(bridge): restore baLoc stall path`)
- Uncommitted:
  - `C64_MiSTer/rtl/sdram_pm.v` (Build C with HIT early-exit, new)
  - `C64_MiSTer/rtl/sdram_pm.v.buildB.bak` (Build B preserved for rollback)
  - `C64_MiSTer/rtl/fpga64_sid_iec.vhd` (Step 6 + busy_counter feedback)
  - Plan docs: `docs/path_to_20mhz_plan.md`,
    `docs/async_bridge_phase_f_revised.md`
  - UI changes in `c64.sv` (turbo override when SCPU enabled)
  - This handoff
- Per CLAUDE.md "Commit when a fix lands": these stay uncommitted until
  Build C HW Lorenz + Doom prove the scaffolding is regression-free as a
  logical unit.

## Pending step-by-step
- [ ] Build C compile (in flight, background `b5t0ke9qa`)
- [ ] Deploy Build C to MiSTer
- [ ] Lorenz SCPU regression on Build C — must reach `andix - ok` at
      time-cap, matching v356 + Step 6 baselines.
- [ ] Doom regression — confirm no new regression (perf change not expected
      yet given sync-latency analysis above).
- [ ] If all green: commit the Step 6 + Build C scaffolding as one unit.
- [ ] Then either:
  - Continue Milestone A with single-FF sync experiment (risk: meta),
    OR
  - Jump to Milestone B (clk_cpu=clk64 + F.3' prefetch — bigger work but
    actual perf delivery)

## Strategic paths (kept for reference from earlier in session)
**A. SAME_CLOCK generic in bridge** — bypass MCP at matched clocks.
**B. Pre-emptive bus_di capture** — sample at `cpu_cyc_s(0)` one clk32
   before `enableCpu_816`.
**C. Abandon bridge for clk_cpu=clk64**, pursue arbiter-side slot
   reclamation. This is the active branch (Step 5a `alt_fire_r` already
   merged at HEAD via `e7a9afb` lineage).

The Milestone A scaffolding is path C's foundation. Milestone B will
revisit path A or B.

## MiSTer state
- Active core: Build B + Step 6 (current uncommitted RBF on `/media/fat/_Test/`).
- Daemon health: OK. User has ownership of the MiSTer this session.
- Lorenz screenshots: `tools/lorenz_run/scpu/` (latest, Step 6 baseline)
  and `tools/lorenz_run/scpu_2026-05-22_step6_baseline/` (snapshot).

## Reference
- `docs/path_to_20mhz_plan.md` — three-milestone plan with risk registers.
- `docs/async_bridge_phase_f_revised.md` — F-plan revision after the F.1
  wedge ladder.
- Memory `project_phaseF1c_BRIDGE_ACTIVE_1_wedge.md` — full F.1 diagnosis.
- Memory `project_step2_alt_slot_wedges_doom.md` — prior alt-slot attempts.
- Memory `feedback_renaming_sdram_entity_breaks_sdc.md` — SDC filter trap
  to re-verify if Build C HW wedges.
