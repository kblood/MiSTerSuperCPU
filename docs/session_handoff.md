# Session handoff — 2026-05-30: Milestone B validated in GHDL sim; STA build in flight

## NORTH STAR & THIS SESSION'S CONSTRAINT
Goal: fully-compatible SuperCPU at 20MHz+ turbo. Operator sequencing: **compat
first, then more turbo** — but the remaining big compat wins are SPEED-BOUND
("SuperCPU Kicks!" etc. assume the real ~20MHz default; VICE-confirmed our
1/4MHz reproduces the breakage). So both halves funnel into **Milestone B**
(clk_cpu=64MHz + MCP async bridge). Operator constraint THIS session:
**make Milestone B progress WITHOUT the MiSTer** — GHDL sim only, no deploy.
A Quartus *build* (STA report, no hardware) is in-bounds; deploying is not.

## DONE THIS SESSION (all GHDL, no MiSTer)

### 1. Reduced harness now actually clocks the real 65C816 — both configs PASS
`sim/c64_reduced_harness/run_harness_mb.sh` (NEW). Real `fpga64_sid_iec` arbiter
+ real `cpu_65c816` + SDRAM latency model. Two configs, both 17/0:
- `RATIO=1 MCP=0` passthrough (HW baseline): max_pc=$FD5F, en_count 53→365.
- `RATIO=2 MCP=1` Milestone B, clk_cpu=64MHz: max_pc=$FF7F, en_count 27→236.
CPU boots into KERNAL ROM correctly across the 64MHz CDC bridge with the real
sysCycle wheel + SDRAM model.
- **Root-caused the "CPU frozen" blocker:** `rfsh_cycle`/`sysEnable` had no init
  → `rfsh_cycle = "00"` never true → `sysEnable` never armed → arbiter never
  advanced (sim 'U' deadlock; FPGA powers these FFs to 0). Added explicit inits
  to `fpga64_sid_iec.vhd` (HW no-op, sim-correct). v2 harness still 84/0.
- Committed `c1233a5`.

### 2. SuperRAM long store/load across the bridge at 64MHz — PASS
`sim/scpu_async_bridge_tb/cpu_in_bridge_superram_tb.vhd` (NEW). Real CPU + active
bridge, native-mode `STA $02:0000` / `LDA $02:0000` into SuperRAM (bank $02) with
the mock arbiter giving SuperRAM a longer 4-cycle ack vs bank $00's 2-cycle
(models the real 3-stage vs 2-stage SDRAM split). RATIO=2 PASS + RATIO=1 control
PASS — round-trips $AB, went_native. Closes the "LDA long bank transition"
wedge-locus coverage gap. Committed `38c1d36`.

### Strategic upshot
The historical "64MHz wedge" is now sim-proven to be an **integration/STA**
issue, NOT an RTL functional bug — corroborated at the SYSTEM level (real
arbiter + SDRAM), not just the isolated bridge bench. The F.3' enable-skew fix
inside `scpu_async_bridge` is sound at 2:1.

## IN FLIGHT — STA closure build at clk_cpu=64MHz (the one fact sim can't give)
Wired Milestone B behind a reversible build switch in `c64.sv`:
- `localparam MILESTONE_B = 1; wire clk_cpu = MILESTONE_B ? clk64 : clk_sys;`
- `fpga64_sid_iec #(.SCPU_MCP_ACTIVE(MILESTONE_B ? 1'b1 : 1'b0)) fpga64`
- `C64.sdc` was ALREADY prepared (clk64↔clk32 multicycles + all bridge CDC
  false-paths keyed to `scpu_async_bridge_inst`) — no SDC edits needed.
- Syntax-only build PASSED (0 errors) — mixed-language std_logic generic OK.
- Full build running in background → `build_milestone_b.log`. **NOT committed**
  (experimental; flip `MILESTONE_B=0` to revert).

### NEXT STEP (when build finishes)
Read `C64_MiSTer/output_files/C64.sta.rpt` (and `.fit.summary`):
- Grep for worst-case slack on the **clk64** domain (counter[1]). Setup slack
  ≥ 0 ⇒ 64MHz closes ⇒ Milestone B is FEASIBLE on this FPGA (huge — de-risks the
  eventual HW test the operator has deferred). Negative slack ⇒ which paths fail;
  whether more SDC multicycles or an RTL pipeline stage can recover them.
- If clean: commit the c64.sv switch as "Milestone B engaged, STA-closed,
  HW-verification pending"; the archived RBF lands in `C64_MiSTer/builds/`.
- If it fails timing: revert `MILESTONE_B=0`, document the failing paths, and the
  next lever is either targeted SDC relaxation or a registered bridge boundary.
- HW deploy/Doom/Lorenz re-verification remains GATED on operator lifting the
  no-MiSTer constraint. Do NOT deploy this build.

## Parallel/lower-priority backlog
- VICE 3-speed triage matrix (default/4MHz/1MHz) to classify more 3rd-party SCPU
  titles speed-bound vs separable-compat (pure desktop VICE, no MiSTer).
- Milestone C (demand arbiter) sim prep — GATED on B being HW-stable first.

## Pushes still gated. Commits are pre-authorized when green.
