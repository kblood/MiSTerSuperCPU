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

## STA CLOSED — 64MHz is FEASIBLE on this FPGA (committed ca4c4a3)
Engaged Milestone B behind a reversible switch in `c64.sv`:
- `localparam MILESTONE_B = 1; wire clk_cpu = MILESTONE_B ? clk64 : clk_sys;`
- `fpga64_sid_iec #(.SCPU_MCP_ACTIVE(MILESTONE_B ? 1'b1 : 1'b0)) fpga64`
- `C64.sdc` was ALREADY prepared (clk64↔clk32 multicycles + all bridge CDC
  false-paths keyed to `scpu_async_bridge_inst`) — no SDC edits needed.
- Syntax check 0 errors; mixed-language std_logic generic override OK.

**Full build result (RBF `00452c21`, archived in `C64_MiSTer/builds/`):**
- clk64 (PLL counter[1]): **setup slack +2.410ns, hold +0.245ns, TNS=0.000.**
- ALL clock domains positive, TNS=0 everywhere, 0 errors.
- 569 synchronizer chains, worst-case MTBF 1e9 years.
- 66% ALMs (27,587/41,910) / 73% M10K (403/553) / 55% block-mem — in budget.
⇒ **64MHz closes timing with 2.4ns to spare.** Milestone B is feasible here.
Committed the switch (`ca4c4a3`) with HW-verification flagged as the last gate.

### THE ONE REMAINING GATE — hardware verification (operator must lift no-MiSTer)
Everything checkable without hardware is now green (sim-functional + STA). The
deferred HW checks, to run when the operator re-enables MiSTer:
1. Boot to READY (clk_cpu=clk64 historically wedged pre-F.3'-fix; sim says fixed).
2. Lorenz 100% in BOTH t65 and scpu modes (must not regress).
3. Doom autoload (REU→SuperRAM transfer + in-engine playloop) — the integration
   stressor most likely to expose a sim-invisible CDC/latency hazard.
4. Measure effective MHz vs the 4MHz baseline (the whole point — expect ~up to 20).
If any regress: `MILESTONE_B=0` reverts in one line; then bisect against the
sim benches (they're the oracle for what *should* work at 2:1).
- Do NOT deploy `00452c21` until the operator lifts the constraint.

## Parallel/lower-priority backlog
- VICE 3-speed triage matrix (default/4MHz/1MHz) to classify more 3rd-party SCPU
  titles speed-bound vs separable-compat (pure desktop VICE, no MiSTer).
- Milestone C (demand arbiter) sim prep — GATED on B being HW-stable first.

## Pushes still gated. Commits are pre-authorized when green.
