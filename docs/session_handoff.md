# Session handoff — 2026-05-23 end-of-session (REVISED 4)

## TL;DR — Milestone A closed; Milestone B at F.1' done, F.3' implementation pending

This session closed out Milestone A (alt-fire characterization confirmed
both Step 5 + Step 7b dead on Build B) and pushed Milestone B through
F.0/F.1'/F.2/F.3'-sketch. The bridge with its full F.1 MCP FSM is
back in tree at `C64_MiSTer/rtl/scpu_async_bridge.vhd`, safety-gated
to passthrough behavior, and the synthesized RBF is bit-identical to
the post-both-off-alt-fires baseline.

## Milestone A — closed at ceiling

1. **alt_fire_r2 (Step 7b)** was the single root cause for both the
   bank-$20 wedge and the "LDA al → STA hazard." Gated OFF, both
   symptoms vanish.
2. **alt_fire_r (Step 5)** measured at 0% contribution on Build B.
   Bench COUNT-per-PASS bit-identical between alt_fire_r-ON
   (RBF `a993d7b7`) and both-off (RBF `453a3380`). Build B's
   ~4-clk32 SDRAM cycle is too long for any alt-slot CPU fire.
3. **Bench metric corrected**: COUNT-per-PASS is the speedup signal;
   PASS/sec is capped at ~61/sec by Timer A (1 MHz phi2 domain) and
   is independent of CPU speed.
4. Both alt-fire blocks commented out in source; restore on Build C
   revival in Milestone B integration.

## Milestone B — F.1' checkpoint

Branch: `milestone-b-cdc-rewrite` (off `milestone-a-build-c-revival`).
Five commits this session:

| commit  | what                                                     |
|---------|----------------------------------------------------------|
| 8f1e3a2 | F.0/F.1' kickoff — line freshness + MCP FSM backup       |
| b27e914 | F.3' arbiter prefetch design sketch                      |
| ac7caf1 | F.2 bench upgrade — RATIO + PASSTHROUGH_MODE generics    |
| bc5f90f | handoff update                                            |
| da1a684 | F.1' bridge restoration with SAME_CLOCK_PASSTHROUGH gate |

### Active state on disk

- Bridge at `C64_MiSTer/rtl/scpu_async_bridge.vhd` is the **full F.1
  MCP FSM** (363 lines), gated to passthrough via
  `SAME_CLOCK_PASSTHROUGH='1'` (default). New port
  `bus_request_strobe_in` wired to `cpu_cyc`.
- `EFF_BRIDGE_ACTIVE = BRIDGE_ACTIVE AND NOT SAME_CLOCK_PASSTHROUGH`.
  Both must be set deliberately to engage the MCP path. Quartus
  constant-folds today's config so the MCP FSM has zero netlist
  cost — RBF md5 `453a3380` matches the both-off-alt-fires build.
- Bench at `sim/scpu_async_bridge_tb/bridge_tb.vhd` validates:
  - `RATIO={1,2,3} PASSTHROUGH=1` → all 5 scenarios pass (regression
    net against the diag baseline)
  - `RATIO={1,2} PASSTHROUGH=0` → MCP FSM passes (sim-proves the
    handshake will work when F.3' enables it on hardware)
- Reference MCP source preserved at
  `tools/scpu_async_bridge_F1_backup.vhd` (out-of-tree).

## Milestone B — what remains

- [x] F.0: verification + Appendix A/B in plan doc.
- [x] F.1': bridge restored, SAME_CLOCK_PASSTHROUGH gate, RBF
      bit-identical to baseline.
- [x] F.2: bench parametric across RATIO + PASSTHROUGH_MODE.
- [x] F.3' design sketch.
- [ ] **F.3' implementation** — open work. The current MCP FSM uses
      `cpu_vpa_in | cpu_vda_in` as the request trigger (source-side).
      To engage the arbiter prefetch, the source-side FSM must be
      reworked to fire on a synced version of `bus_request_strobe_in`
      (the strobe is in clk_sys; needs 2-FF sync into clk_cpu).
      Open design question: should the strobe REPLACE vpa/vda as
      the trigger, or COMPLEMENT it (e.g., latch payload on vpa/vda,
      fire toggle on synced strobe)?
- [ ] F.3' clk_cpu retarget — flip `c64.sv:328 clk_cpu = clk_sys`
      to `clk_cpu = clk64`. Add SDC clock-groups + max/min-delay
      across toggles per `hdl-coding-guidelines/24-cdc-multi-bit.md §6`.
- [ ] F.4: Doom/Wolf3D/Lorenz regression at clk_cpu=64MHz.
- [ ] F.5: optional cache re-enable.

## Suggested next-session entry point

1. **Decide the F.3' source-side trigger protocol.** Read
   `docs/async_bridge_f3_prefetch_sketch.md §1` (latency budget) and
   the F.1 source FSM at `C64_MiSTer/rtl/scpu_async_bridge.vhd:248-310`.
   Choose between (a) strobe replaces vpa/vda, (b) strobe is an
   additional gate on the FSM transition, (c) two-stage protocol.
2. **Implement the chosen protocol** in the bridge. Add a 2-FF sync
   of `bus_request_strobe_in` into clk_cpu. Update the bench's
   model arbiter to emit the strobe 3 clk_sys before the ack pulse.
3. **Validate in sim first** (RATIO=2 PASSTHROUGH=0 with strobe
   timing). Iterate the FSM if needed.
4. **Then flip `c64.sv:328` and add SDC constraints.** Build, deploy,
   KERNAL boot test, then Doom/Wolf3D/Lorenz regression.

## State on disk

- Branch: `milestone-b-cdc-rewrite` HEAD `da1a684`
- RBF on MiSTer: `/media/fat/_Test/C64.rbf` md5 `453a3380`
- Bench artifacts: `sim/scpu_async_bridge_tb/work/`
- Boot screenshot: `tools/test_cart/out/_bridge_restore_boot.png`

## Memory entries

- `project_step7b_alt_fire_r2_confirmed_2026_05_23.md`
- `project_lda_al_sta_hazard_2026_05_23.md` (resolved)
- `project_superram_bench_metric_2026_05_23.md`
- `project_alt_fire_r_dead_on_buildB_2026_05_23.md`

## Commits this session (all branches)

`milestone-a-build-c-revival`:
- `2407264`–`6e90292` (earlier session work)
- `1395997` fpga64_sid_iec: gate alt_fire_r OFF — Step 5 confirmed 0%

`milestone-b-cdc-rewrite` (NEW branch off above):
- `8f1e3a2` docs(milestone-b): F.0/F.1' kickoff
- `b27e914` docs(milestone-b): F.3' arbiter prefetch design sketch
- `ac7caf1` sim(bridge_tb): F.2 upgrade — RATIO + PASSTHROUGH_MODE generics
- `bc5f90f` docs(handoff): F.2 done; next is bridge restoration
- `da1a684` bridge(F.1'): restore MCP FSM with SAME_CLOCK_PASSTHROUGH safety gate

## Pointers

- `docs/path_to_20mhz_plan.md` — Milestones A/B/C.
- `docs/async_bridge_phase_f_revised.md` — revised Phase F plan.
- `docs/async_bridge_mcp_handshake_plan.md` — F.0/F.1 detail + Appendix B (freshness).
- `docs/async_bridge_f3_prefetch_sketch.md` — F.3' design sketch.
- `C64_MiSTer/rtl/scpu_async_bridge.vhd:108-109` — `EFF_BRIDGE_ACTIVE`
  derivation (the safety gate).
- `tools/scpu_async_bridge_F1_backup.vhd` — out-of-tree reference of
  the same MCP FSM.

MiSTer IP `192.168.50.130`, root/1. RBF md5 `453a3380` at
`/media/fat/_Test/C64.rbf`. Don't touch `/media/fat/_Computer/`.
