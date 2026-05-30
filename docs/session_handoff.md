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

## ⛔ HW VERDICT (2026-05-30): MILESTONE B HW-FALSIFIED — clk64 wedges; reverted to MILESTONE_B=0
The operator lifted the no-MiSTer constraint and I HW-tested build `00452c21`
(MILESTONE_B=1, clk_cpu=clk64 + MCP). Results:
- **Boot to READY at 64MHz: PASS** ✅ (first-ever clean clk64 boot — `SCPU64 ROM
  V0.07`, 38911 BASIC BYTES FREE, READY). The handshake/boot path works on silicon.
- **Lorenz scpu at 64MHz: FAILS (intermittent wedge).** 1 pre-reboot run showed
  ~15 instruction-group tests "ok" then the daemon wedged; 3 post-reboot runs ALL
  failed (1 autostart-miss, 2 hard CPU wedges at ~30s/~62s — overlay frozen =
  CPU halted). The 32MHz control build `97392a1f` runs Lorenz scpu CLEAN
  (continuous progress, all "ok") under the identical harness → fair A/B.
- **ROOT CAUSE (airtight, RTL+SDC+empirical):** `scpu_async_bridge` SUSTAINS
  `cpu_enable_reg<='1'` across consecutive clk_cpu edges in CPU_IDLE (F.3' v2,
  scpu_async_bridge.vhd:552-557,665 — intentional, so multi-cycle 65816 ops get
  enough EN=1 cycles). At clk_cpu=64MHz that makes the P65C816 advance on
  consecutive 64MHz edges, which **INVALIDATES** `set_multicycle_path -setup 2 -to
  *P65C816:cpu|*` in C64.sdc (valid ONLY when enable is the sparse arbiter pulse,
  i.e. in passthrough — which is why the control is clean). STA therefore MASKED
  real setup violations on the CPU's deep internal combinational paths (ALU/BCD/
  AddrGen/MCode) which do NOT close at 64MHz single-cycle (15.6ns). The "+2.41ns
  clk64 slack" was measured against the wrong (2×-relaxed) budget. Boot survives
  because KERNAL exercises fewer/shorter internal paths; Lorenz's intensive
  ALU/addressing coverage hits the failing paths → data-dependent wedge.
- **This OVERTURNS the earlier "STA-clean ⇒ feasible" conclusion.** clk64 is NOT
  viable with this CPU core under the sustain-enable scheme.
- **ACTION TAKEN:** reverted `c64.sv` to `MILESTONE_B=0` (safe passthrough default,
  bit-identical to shipped). MiSTer restored to `97392a1f` + released.

### Doom autoload this session: environmental, NOT a B regression
Both `00452c21` (MB) and `97392a1f` (control) wedge IDENTICALLY at `$EABE` with a
garbage screen → the REU/MGL Doom harness is broken for all builds today (REU
content/timing). Separate pre-existing issue; B exonerated. The Lorenz autoload
(disk MGL) works, so start_strk is fine.

### PATH FORWARD (the >4MHz question, now better understood)
The sustain-enable scheme requires the CPU's internal paths to close single-cycle
at clk_cpu. They close at 32MHz, not 64MHz. Options, in rough order of leverage:
1. **Quantify true 64MHz CPU slack** — rebuild MILESTONE_B=1 with the
   `-to *P65C816:cpu|*` multicycle REMOVED → STA shows the real (negative) clk64
   slack on CPU-internal paths. Cheap, no MiSTer, confirms+sizes the gap. (Teed up.)
2. **Try clk_cpu=clk48** (PLL already emits clk48). 20.8ns may close where 15.6ns
   doesn't → 1.5× internal cycle rate with sustain-enable, modest but real, and
   HW-safe to A/B against Lorenz.
3. **Demand arbiter (Milestone C) at clk32** — keep CPU at 32MHz (where it closes)
   and grant more bus slots. This is a DIFFERENT speed mechanism that does NOT need
   clk_cpu=64MHz at all; the earlier "C is gated on B" framing is weakened — C may
   be pursuable directly on the stable 32MHz CPU.
4. Pipeline/retime the P65C816 core to close at 64MHz (largest effort).

## STA CLOSED — 64MHz is FEASIBLE on this FPGA (committed ca4c4a3) [SUPERSEDED — see HW verdict above]
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

## ⛔ clk48 HW-FALSIFIED (2026-05-30) — timing CLOSES honestly, but FUNCTIONAL/CDC crash
HW-tested the STA-clean clk48 build `abf8ff88` against the control `97392a1f`
under TODAY's identical Lorenz harness (control proven healthy — it runs+passes
the suite: "basic commands ok / ldab ok / ... / staz ok"). Two independent clk48
failures, both absent on control (only clk_cpu differs):
1. **Lorenz scpu autoload STALLS** — stuck at BASIC READY, suite never starts.
   UART: PC idling $EACC/$EAB6 (KERNAL editor loop), bridge RQ/AK cycling = CPU
   alive but the RUN->LOAD chain never dispatched. (Via the robust start_strk
   path, NOT mtype — so not a tooling race.)
2. **Keyboard interaction HARD-WEDGES the CPU** — after a typed `PRINT 2+2` the
   screen garbled and UART froze: **PC stuck at $0000F5** (executing in zero page
   = crashed off the rails), SP/regs static, bridge idle (RQ==AK). A genuine CPU
   crash.
**THE KEY INSIGHT (stronger than the clk64 result):** clk48's STA was HONEST and
POSITIVE (CPU-internal +3.730ns, worst ANY->CPU +0.281ns, ALL domains TNS=0 after
the cross-domain SDC completion). A passing-STA path does NOT fail from setup
timing — so this crash is **NOT a timing-closure problem**. I genuinely fixed
timing (disproving "clk64 wedged purely on timing"). The remaining hazard is
**functional / CDC in the sustain-enable MCP bridge at raised clk_cpu** — it
appears at BOTH clk64 and clk48 but never in clk32 passthrough. Another timing
constraint cannot fix a functional/CDC bug. The CPU core itself is sound (sim-
correct; at clk48 timing-clean; boots clean to READY) — the failure is the
raised-clk_cpu + active-MCP-bridge INTEGRATION.

### DECISION: pivot to Milestone C (demand arbiter @ clk32)
Two raised-clock attempts (clk64, clk48) now both HW-falsified at the system
level despite a sound CPU core. The pattern says: raising clk_cpu + activating
the CDC bridge has a non-timing integration hazard that's expensive to chase
(the bench is sim-correct, so the hazard is something the bench doesn't model —
clock-ratio-dependent metastability or a scenario gap). **Milestone C keeps the
CPU on clk32 (proven-compatible, control passes Lorenz) with NO active CDC
bridge, and recovers speed by granting more SDRAM bus slots via a demand
arbiter.** That sidesteps the entire failing class. This is the higher-leverage
next step toward compat+speed. (Milestone B is not dead-dead — a future revival
would need to functionally debug the bridge CDC at raised clk, lower priority.)
- Actions taken: working tree reverted to committed `84ddf8f` (MILESTONE_B=0 +
  original SDC); MiSTer restored to `97392a1f` + lock released; clk48 RBF
  `abf8ff88` kept archived for the record.

## (SUPERSEDED by the falsification above) clk48 CPU-INTERNAL CLOSES (honest STA) — clk64 was truly -1.56ns
Build `0d284387` (MILESTONE_B=2, clk_cpu=clk48=21.146ns) with the blanket
`-to *P65C816:cpu|*` multicycle REMOVED (honest single-cycle). Focused STA
(quartus_sta -t, WSL 17.0):
- **CPU-internal (P65C816->P65C816): worst +3.730ns, 0 violated.** Worst paths
  are real ALU/addr-gen (AddrGen|DH->Mux, ADDR_INC->PCr, ->X[11]); ~17.2ns data.
- **ANY->P65C816 (incl bus/IRQ/BA): worst +0.281ns, 0 violated** (binding path
  use_tape@clk_sys -> ADDR_INC@clk48). Every path INTO the CPU closes.
- Back-computes the HONEST clk64 number: 3.730 - (21.146-15.859) = **~-1.56ns**
  CPU-internal — the real violation the blanket multicycle had MASKED (STA had
  falsely shown +2.41ns). This is the airtight quantification of the clk64 wedge.
- The only STA failures were clk48-CROSSING constraint gaps, NOT the CPU:
  counter[1] -6.796 = bridge cpu_req_addr*/ioDir -> sdram sd_addr (ce-gated,
  multicycle); counter[2] -1.164 = shared $01 port ioDir -> SCPU-disabled T65
  (quasi-static). Both fixed in C64.sdc (counter[0]->counter[1] setup-2 +
  sd_* setup-4 for bridge/ioDir sources; counter[0]->counter[2] setup-2). These
  add NO counter[0]->counter[0] relaxation, so CPU-internal stays honest.
- **Why this is a much stronger GO than clk64's STA-clean ever was:** the clk64
  +2.41 was an ARTIFACT of a multicycle masking the ALU paths; this clk48 +3.730
  is the genuine single-cycle slack on those exact ALU paths with NO masking. The
  failure mode that bit clk64 cannot recur. clk48 ~= 1.5x clk32 = a real speed
  candidate where clk64 (2x) is dead.

### ✅ REBUILD STA-CLEAN — HW Lorenz A/B is the only gate, BLOCKED on shared MiSTer
Rebuild with completed cross-domain SDC: **build `abf8ff88`** (staged at repo-root
`C64.rbf`, archived `C64_MiSTer/builds/C64_..._abf8ff88-dirty.rbf`). ALL domains
TNS=0, 0 timing-not-met: counter[0]/clk48 +0.228, counter[1]/clk64 +3.704,
counter[2]/clk_sys +8.688. Clean, deployable.

**BLOCKED (2026-05-30 ~t12:00):** shared MiSTer at 192.168.50.130 has
`CORENAME=DotC-CD32MVP` (the CD32 agent's core, loaded ~09:41 today). Per the
cooperation protocol I backed off — did NOT deploy. HW test deferred until the
C64 slot frees (re-poll scheduled).

**WHEN THE MISTER FREES (CORENAME empty or C64):** write the session lock, then:
1. `python tools/mister_debug.py deploy C64.rbf` (the staged abf8ff88 clk48 build).
2. `python tools/lorenz_run.py scpu --mins 7` then `python tools/lorenz_run.py t65 --mins 7`.
3. Compare against the clean control `97392a1f` (scpu ran CLEAN there; clk64 build
   `00452c21` WEDGED scpu — that's the A/B contrast to beat).
4. PASS both modes -> clk48 ships ~1.5x; COMMIT MILESTONE_B=2 (c64.sv) + C64.sdc
   (the honest CPU multicycle removal + counter[0] cross-domain block). Pushes
   still gated.
   WEDGE like clk64 -> sustain-enable scheme itself is implicated (not just 64MHz
   timing) -> REVERT working tree (git checkout c64.sv C64.sdc) and pivot to
   Milestone C (demand arbiter @ clk32, CPU stays where it closes).
5. Re-verify Doom once REU/MGL harness is healthy (today's wedge was environmental).
Working tree (uncommitted): c64.sv MILESTONE_B=2, C64.sdc honest+clk48 crossings.

## SUPERSEDED NEXT-EXPERIMENT NOTE (kept for trail): honest clk48 CPU-internal slack
Building `MILESTONE_B=2` (clk_cpu=clk48, counter[0]=**21.146ns** vs clk64's
15.859ns = +5.287ns budget). SDC made honest: removed the blanket
`-to *P65C816:cpu|*` setup-2 multicycle (it masked clk64's failure), so
CPU-internal reg→reg paths are now timed single-cycle at clk48 — the decisive
read. **Gate:** when the build lands, run
`report_timing -setup -from [get_registers {*P65C816:cpu|*}] -to [get_registers {*P65C816:cpu|*}]`
against `output_files/C64.sta.rpt` (or quartus_sta). If worst CPU-internal
slack ≥ ~0 → clk48 viable, proceed to a real deploy build + Lorenz A/B. If
deeply negative → clk48 dead too; pivot to Milestone C (demand arbiter, CPU
stays at clk32 where it closes).

### Codex caveats for the DEPLOY build (NOT this diagnostic — noise here)
Independent review (tools/codex-out/clk48-strategy.txt) flagged two things that
only matter IF clk48 closes and I build a deployable bitstream:
1. **The narrow `-from bus_di_capture_reg -to P65C816` setup-2 may itself be
   dishonest.** Codex reads the bridge FSM as: bus_di_capture_reg updates in
   CPU_WAIT_ACK, CPU gets en/rdy on the NEXT clk_cpu edge → a 1-cycle path, not
   a held round-trip. Before deploy, verify the actual capture→sample cycle
   count in scpu_async_bridge.vhd; if it's 1-cycle, drop the multicycle (don't
   repeat the clk64 masking error on the data path).
2. **clk48's 1.5× ratio leaves IRQ/NMI, baLoc, diIO/cass_sense unconstrained.**
   These enter cpu_65c816 OUTSIDE the bridge (clk_sys→clk48 crossings). clk64
   (2×) covered them via the clk32→clk64 multicycle; clk48 (counter[0]) has no
   clk32→clk48 equivalent. A deploy build needs a counter[2]→counter[0]
   multicycle (mirror SDC lines 13-19) or those paths false-fail / mis-time.
Both are `-from <other> -to CPU` paths → they do NOT affect the CPU-internal
slack read from this build.

## Parallel/lower-priority backlog
- VICE 3-speed triage matrix (default/4MHz/1MHz) to classify more 3rd-party SCPU
  titles speed-bound vs separable-compat (pure desktop VICE, no MiSTer).
- Milestone C (demand arbiter) sim prep — GATED on B being HW-stable first.

## Pushes still gated. Commits are pre-authorized when green.
