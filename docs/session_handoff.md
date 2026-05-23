# Session handoff — 2026-05-24 end-of-session (REVISED 5)

## TL;DR — Milestone B at F.0/F.1'/F.2/F.3' implementation done; F.3' enable pending

This session implemented F.3': a two-stage source FSM
(CPU_IDLE → CPU_REQ_PENDING → CPU_WAIT_ACK) that latches payload on
vpa/vda and defers the cross-domain toggle to a synced strobe edge.
Bench passes 6/6 (RATIO × PASSTHROUGH). Sanity build at
SAME_CLOCK_PASSTHROUGH=1 (default) synthesises clean and KERNAL boots
on hardware — RBF md5 `c61bfa77` (changed from prior `453a3380` by
the 3 added preserved sync FFs only). The FSM's outputs are still
gated to passthrough; F.3' enable (flip clk_cpu and the safety gate)
is the next concrete step.

Previous session (2026-05-23) closed Milestone A (Step 5 + Step 7b
alt-fires both dead on Build B) and pushed Milestone B through
F.0/F.1'/F.2/F.3'-sketch.

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

## Milestone B — F.3' checkpoint

Branch: `milestone-b-cdc-rewrite` (off `milestone-a-build-c-revival`).
Commits this session (2026-05-24):

| commit  | what                                                     |
|---------|----------------------------------------------------------|
| 03bf677 | bridge(F.3'): two-stage source FSM with synced strobe   |

Commits last session (2026-05-23):

| commit  | what                                                     |
|---------|----------------------------------------------------------|
| 8f1e3a2 | F.0/F.1' kickoff — line freshness + MCP FSM backup       |
| b27e914 | F.3' arbiter prefetch design sketch                      |
| ac7caf1 | F.2 bench upgrade — RATIO + PASSTHROUGH_MODE generics    |
| bc5f90f | handoff update                                            |
| da1a684 | F.1' bridge restoration with SAME_CLOCK_PASSTHROUGH gate |
| 159bf8e | docs(handoff): F.1' checkpoint                           |

### Active state on disk

- Bridge at `C64_MiSTer/rtl/scpu_async_bridge.vhd` is the **F.3'
  two-stage source FSM** (390+ lines), gated to passthrough via
  `SAME_CLOCK_PASSTHROUGH='1'` (default). New port
  `bus_request_strobe_in` wired to `cpu_cyc`. New `strobe_sync1/2/3_reg`
  chain with preserve + SYNCHRONIZER_IDENTIFICATION attributes
  derives a one-cycle `strobe_edge` for the CPU_REQ_PENDING → CPU_WAIT_ACK
  transition.
- `EFF_BRIDGE_ACTIVE = BRIDGE_ACTIVE AND NOT SAME_CLOCK_PASSTHROUGH`.
  Both must be set deliberately to engage the MCP path. Quartus
  retains the new strobe sync FFs (preserve) but masks all bridge
  outputs to combinational passthrough today — RBF md5 `c61bfa77`
  (vs prior `453a3380`; delta = 3 added FFs only). KERNAL boot
  verified on hardware 2026-05-24.
- Bench at `sim/scpu_async_bridge_tb/bridge_tb.vhd` validates:
  - `RATIO={1,2,3} PASSTHROUGH=1` → 5/5 scenarios pass (regression
    net against the diag baseline)
  - `RATIO={1,2,3} PASSTHROUGH=0` → MCP FSM with strobe-triggered
    toggle passes (sim-proves the handshake will work when F.3'
    enables it on hardware). Round-trip at RATIO=2 ≈ 258 ns / ~8.3
    clk_sys for scenario E.
- Reference MCP source preserved at
  `tools/scpu_async_bridge_F1_backup.vhd` (out-of-tree, pre-F.3'
  vpa/vda-only trigger variant).

## Milestone B — what remains

- [x] F.0: verification + Appendix A/B in plan doc.
- [x] F.1': bridge restored, SAME_CLOCK_PASSTHROUGH gate, RBF
      bit-identical to baseline.
- [x] F.2: bench parametric across RATIO + PASSTHROUGH_MODE.
- [x] F.3' design sketch.
- [x] **F.3' implementation** (commit 03bf677). Two-stage source
      FSM picked (option c) per
      `docs/async_bridge_f3_prefetch_sketch.md §1'`. Bench passes
      6/6 configs; KERNAL boots clean on sanity build.
- [ ] **F.3' clk_cpu retarget + enable** — flip
      `c64.sv:329 wire clk_cpu = clk_sys` to `wire clk_cpu = clk64`,
      and in `fpga64_sid_iec.vhd:2703-2709` flip
      `BRIDGE_ACTIVE => '0'` to `'1'` and
      `SAME_CLOCK_PASSTHROUGH => '1'` to `'0'`. Add SDC additions
      (see below).
- [ ] **F.3' SDC** — add false-path for the new strobe sync chain:
      `set_false_path -from {*scpu_async_bridge_inst|strobe_sync1_reg}`
      is not the right shape (source is combinational `cpu_cyc`).
      Either register `cpu_cyc` in clk_sys first (`cpu_cyc_r`) and
      false-path the registered source, or add
      `set_max_delay -from <clk_sys clock> -to {*scpu_async_bridge_inst|strobe_sync1_reg}`
      sized to ~1 clk_sys. Existing F.3 false-paths at
      `C64_MiSTer/C64.sdc:78-103` cover the toggle and payload
      paths already.
- [ ] F.4: Doom/Wolf3D/Lorenz regression at clk_cpu=64MHz.
- [ ] F.5: optional cache re-enable.

## Suggested next-session entry point

1. **Decide whether to land a strobe registration in `cpu_cyc_r` or
   add an SDC max-delay constraint.** Cleaner option: in
   `fpga64_sid_iec.vhd` register `cpu_cyc` into `cpu_cyc_r` on
   clk_sys and wire that as `bus_request_strobe_in`. Costs 1
   clk_sys of advance (now 1 clk_sys instead of 2), still 2
   clk_cpu = 1 clk_sys of margin at RATIO=2 — tight but workable.
   Alternative: keep combinational and add a max-delay SDC.
2. **Flip the three settings** (c64.sv clk_cpu, bridge BRIDGE_ACTIVE,
   bridge SAME_CLOCK_PASSTHROUGH). Add SDC additions.
3. **Build, deploy, KERNAL boot test.** If wedges (similar to
   Phase E.1), capture UART, compare to wedge signatures in
   `memory/project_phaseE1_64mhz_wedge.md`.
4. **If KERNAL clean: Doom + Wolf3D + Lorenz regression.**

## State on disk

- Branch: `milestone-b-cdc-rewrite` HEAD `03bf677`
- RBF on MiSTer: `/media/fat/_Test/C64.rbf` md5 `c61bfa77`
- Bench artifacts: `sim/scpu_async_bridge_tb/work/`
- Sanity boot screenshot: `tools/test_cart/out/_f3_sanity_boot.png`
- Prior F.1' boot screenshot: `tools/test_cart/out/_bridge_restore_boot.png`

## Memory entries

- `project_f3_two_stage_protocol_2026_05_24.md` (NEW)
- `project_step7b_alt_fire_r2_confirmed_2026_05_23.md`
- `project_lda_al_sta_hazard_2026_05_23.md` (resolved)
- `project_superram_bench_metric_2026_05_23.md`
- `project_alt_fire_r_dead_on_buildB_2026_05_23.md`

## Commits to date (this branch)

`milestone-a-build-c-revival`:
- `2407264`–`6e90292` (earlier session work)
- `1395997` fpga64_sid_iec: gate alt_fire_r OFF — Step 5 confirmed 0%

`milestone-b-cdc-rewrite` (off above):
- `8f1e3a2` docs(milestone-b): F.0/F.1' kickoff
- `b27e914` docs(milestone-b): F.3' arbiter prefetch design sketch
- `ac7caf1` sim(bridge_tb): F.2 upgrade — RATIO + PASSTHROUGH_MODE generics
- `bc5f90f` docs(handoff): F.2 done; next is bridge restoration
- `da1a684` bridge(F.1'): restore MCP FSM with SAME_CLOCK_PASSTHROUGH safety gate
- `159bf8e` docs(handoff): F.1' checkpoint
- `03bf677` bridge(F.3'): two-stage source FSM with synced strobe trigger

## Pointers

- `docs/path_to_20mhz_plan.md` — Milestones A/B/C.
- `docs/async_bridge_phase_f_revised.md` — revised Phase F plan.
- `docs/async_bridge_mcp_handshake_plan.md` — F.0/F.1 detail + Appendix B (freshness).
- `docs/async_bridge_f3_prefetch_sketch.md` — F.3' design sketch.
- `C64_MiSTer/rtl/scpu_async_bridge.vhd:108-109` — `EFF_BRIDGE_ACTIVE`
  derivation (the safety gate).
- `tools/scpu_async_bridge_F1_backup.vhd` — out-of-tree reference of
  the same MCP FSM.

MiSTer IP `192.168.50.130`, root/1. RBF md5 `c61bfa77` at
`/media/fat/_Test/C64.rbf`. Don't touch `/media/fat/_Computer/`.
