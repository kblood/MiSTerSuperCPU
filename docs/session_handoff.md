# Session handoff — 2026-05-24 end-of-session (REVISED 6)

## TL;DR — F.3' implementation landed; F.3' enable wedged on CPU enable CDC

This session implemented F.3' (two-stage source FSM, commit `03bf677`)
and then attempted F.3' enable (clk_cpu=clk64 + BRIDGE_ACTIVE='1' +
SAME_CLOCK_PASSTHROUGH='0' + SDC false-path). The bridge synthesis
closed timing cleanly (+0.383 ns setup) but KERNAL wedged with PC=
$00:0000 + SP=$0100 + CY=0000 all **stable**.

**Root cause** (analysis in
`memory/project_f3_enable_cpu_enable_cdc_2026_05_24.md`): the
`cpu_65c816` instance at `fpga64_sid_iec.vhd:2649` is clocked by
`clk_cpu` but its `enable` pin is `enableCpu_816` — a 1-clk_sys-wide
pulse. At clk_cpu=clk64 the pulse spans 2 clk_cpu edges, so the CPU
advances 2 internal states per slot → instruction sequencing
desynchronizes before the reset vector even completes. The bridge's
MCP CDC is correct and necessary; what's still missing is **enable
CDC**. None of the original Phase F plan / revised plan / F.3'
sketch caught this.

Rolled back HEAD: `c64.sv` clk_cpu=clk_sys, bridge in passthrough.
SDC false-path for `strobe_sync1_reg` kept (harmless in passthrough).
Bridge FSM + bench upgrades preserved at commit `03bf677` — fully
re-usable once enable CDC is solved. Sanity RBF md5 `c61bfa77` is
restored to `/media/fat/_Test/C64.rbf`.

Previous session (2026-05-23) closed Milestone A and pushed Milestone B
through F.0/F.1'/F.2/F.3'-sketch.

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

## Milestone B — F.3' implementation done, enable wedged

Branch: `milestone-b-cdc-rewrite` (off `milestone-a-build-c-revival`).
Commits this session (2026-05-24):

| commit  | what                                                     |
|---------|----------------------------------------------------------|
| 03bf677 | bridge(F.3'): two-stage source FSM with synced strobe   |
| 6bf90dd | docs(handoff): F.3' two-stage FSM landed                 |
| (next)  | bridge(F.3' enable rollback): document CPU enable CDC gap |

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
- [x] **F.3' enable attempted, wedged on CPU enable CDC**
      (RBF bcde5e56). Rolled back. Full analysis in
      `memory/project_f3_enable_cpu_enable_cdc_2026_05_24.md`.
- [ ] **CPU enable CDC fix** — pick from three options listed in the
      memory entry:
      (a) Tie `cpu_65c816 enable='1'` constant at clk_cpu=clk64.
          Bridge `cpu_rdy_out` is the only forward-progress gate.
      (b) Pulse-stretch `enableCpu_816` to 1 clk_cpu via posedge
          detect inside the bridge.
      (c) Derive enable from bridge ack arrival (re-use ack toggle).
- [ ] **F.3' clk_cpu retarget + enable (retry)** — after CPU enable
      CDC fix lands, re-flip `c64.sv:329` to `clk64`,
      `fpga64_sid_iec.vhd:2703-2709` BRIDGE_ACTIVE='1' +
      SAME_CLOCK_PASSTHROUGH='0'. Build, deploy, KERNAL boot test.
- [ ] F.4: Doom/Wolf3D/Lorenz regression at clk_cpu=64MHz.
- [ ] F.5: optional cache re-enable.

## Suggested next-session entry point

1. **Pick a CPU enable CDC option.** Read
   `memory/project_f3_enable_cpu_enable_cdc_2026_05_24.md` for the
   three options + tradeoffs. Default recommendation: **(a) tie
   enable='1' constant** — simplest, lets the bridge's rdy be the
   sole gate. Risk: the 65C816 IP may have internal assumptions
   about enable cadence; verify in sim before committing to silicon.
2. **Sim the chosen fix.** Extend `sim/scpu_async_bridge_tb` or
   write a small wrapper that exercises a P65C816 instance with
   the proposed enable wiring at clk_cpu=clk64.
3. **Apply the fix + re-enable F.3'.** Same edits as today's
   attempt: c64.sv clk_cpu=clk64, fpga64 BRIDGE_ACTIVE='1' +
   SAME_CLOCK_PASSTHROUGH='0'. Plus the enable fix.
4. **Build, deploy, KERNAL boot test.** If KERNAL clean, regression
   suite. If wedged, compare to **stable**-CPU signatures (this
   session's wedge) vs **bouncing**-CPU signatures (Phase E.1 wedges
   at `memory/project_phaseE1_64mhz_wedge.md`).

## State on disk

- Branch: `milestone-b-cdc-rewrite` HEAD `6bf90dd` (+ pending rollback commit)
- RBF on MiSTer: `/media/fat/_Test/C64.rbf` md5 `c61bfa77` (sanity build)
- Wedged build preserved: `C64_MiSTer/builds/C64_milestone-b-cdc-rewrite_6bf90dd72f_20260523T222551Z_bcde5e56-dirty.rbf`
- Bench artifacts: `sim/scpu_async_bridge_tb/work/`
- Sanity boot screenshot: `tools/test_cart/out/_f3_sanity_boot.png`
- F.3' wedge screenshot: `tools/test_cart/out/_f3_enable_boot.png`
- F.3' rollback boot screenshot: `tools/test_cart/out/_f3_rollback_boot.png`
- Prior F.1' boot screenshot: `tools/test_cart/out/_bridge_restore_boot.png`

## Memory entries

- `project_f3_enable_cpu_enable_cdc_2026_05_24.md` (NEW)
- `project_f3_two_stage_protocol_2026_05_24.md`
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
