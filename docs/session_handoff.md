# Session Handoff — current (rebased 2026-06-13, post iter-29)

## North star
Make the SuperCPU as **compatible and fast** as possible. Drive; don't ask.

## ✅ iter-29 DONE: page-hit GATE MEASURED on HW → page-mode SDRAM DROPPED
Ran the cheap characterization gate (counter-only, wedge-safe) before committing
to the multi-session page-mode rewrite. Added a read-only gated
(`PAGEHIT_OBSERVER`) page-hit-rate observer in `fpga64_sid_iec.vhd` (repurposes
the dead cpu_cache `HR/HW` UART slot → **`PH:## PW:##`**); probe =
`tools/pagehit_probe.py`. Observer geometry verified EXACT vs `sdram_pm.v:185`.
- **Two HW builds, A/B at the Doom title (engine rendering from SuperRAM, boot
  clean, PW advancing):** #1 `42b6da7c` single-global open row = **~50%**; #2
  `2d5c79f9` per-bank open row (the realistic 4-bank SDRAM model) = **~54%**.
- **Per-bank recovered only +4 pts** ⇒ bank-$00 zeropage/stack interleaving is
  NOT the dominant miss source; misses are **intra-bank "01" row competition**
  (256-byte effective rows — addr[23] is wasted as a column bit — plus scattered
  code/texture reads). Fundamental to Doom's access stream.
- **VERDICT: DROP page-mode (Lever 1) as the next step.** At ~54% (break-even
  ~45%): ~1.08× raw SDRAM, ~1.1–1.15× CPU even counting the cadence-margin prize
  = poor ROI for a high-risk multi-session rewrite that already wedged (PC=$0D62).
- Sub-option (NOT pursued): address remap (column=`c64_addr[8:0]` → 512-byte
  rows) could lengthen runs but only pays WITH page-mode + risks REU/VIC layout.
- Observer committed gated `true` (debug-only; prunes from the shipped non-debug
  RBF). `_Test` restored to shipped `3698680a`. Full detail: memory
  `project_pagehit_gate_measured_dropped.md`.

## Status in one breath
- **Instruction-level compat is SOLVED.** SST 100% clean (0/5.12M). Lorenz 100%
  both modes. Doom + Wolf3D run; SCPU Kicks renders. The SST vein is exhausted.
- **Speed is the open half, and all *cheap* speed levers are dead.** Shipped build
  runs pure **~4 MHz** in clk32 SDRAM passthrough — a genuine SDRAM-throughput
  floor (6 clk64 = 3 clk32 min ce-spacing, auto-precharge; `busy_cnt="011"` =
  4-apart `enableCpu`). We're ~5× below real SuperCPU 20 MHz.
- **6 speed attempts have died the same way: zero-delay bench passes, silicon
  wedges.** (cache read-path ×5, raised-clock, alt-fire, internal-fast-fire,
  demand arbiter.) Full death record + cadence analysis archived in
  `session_handoff_2026-06-13_iter28-speed-levers-exhausted.md`.
- **HARD RULE: do NOT build another speed RBF off a zero-delay bench.** It has
  failed 6×. Any speed RBF needs a latency-faithful repro harness (Option C) OR a
  fundamentally different approach (Lever 2, the CPU pipeline) — page-mode (Lever
  1) is now dropped per the iter-29 gate.
- **iter-29 added the only safe RBF class proven this session: a read-only
  counter/observer** (changes no cadence) — that is how the page-hit gate was
  measured without risking a wedge. Re-use that pattern for any future on-HW
  characterization.

## Shipped build / MiSTer state
- `_Test` C64.rbf = iter-26 `3698680a` (known-good): boots READY, SCPU64 V0.07,
  idle PC cycles **$E5CD–$E5D6**. Use this as the A/B control for any speed RBF.
- Working tree: page-hit observer committed (gated `PAGEHIT_OBSERVER=true`,
  debug-only, prunes in shipped RBF). Gated dead-lever constants
  (`DEMAND_ARBITER`/`INTERNAL_FAST_FIRE` = false) left in `fpga64_sid_iec.vhd` as
  the record; both are RBF-bit-identical to shipped (Quartus folds them away).

## NEXT — pick a frontier (page-mode now de-prioritized by the iter-29 gate)

### ✅ Recommended A — real SuperCPU software compat sweep (no risky build)
With page-mode dropped (iter-29) AND all arbiter-tweak speed levers dead, the
highest-leverage *steady* progress is the compat frontier. SST is exhausted ⇒ the
live frontier is *non-instruction* incompatibility. Curate real SCPU software
(GEOS, SCPU-library titles, timing-sensitive demos, WriteSmart users), run on the
shipped RBF on HW, triage failures. No speed build, no zero-delay-bench wall risk.
The `pagehit_probe.py` autoload/UART harness + the page-hit observer are reusable
to characterize *other* titles' access patterns if a speed question resurfaces.

### Lever 2 (highest ceiling, deepest) — pipeline the 65C816 internals
Now the ONLY remaining speed lever with real headroom. Per iter-19 STA the real
per-read floor is the CPU-internal di→ALU→BCD→PC path (~15 ns), NOT the SDRAM/mux.
Pipelining it is the biggest win but the deepest, multi-session effort. Unlike the
6 dead arbiter/cache/clock levers, this attacks the actual critical path rather
than the cadence quantization, so it is not in the zero-delay-bench-blind class.

### ⛔ Lever 1 (page-mode SDRAM) — DROPPED by the iter-29 gate
Doom SuperRAM row-locality measured ~50% global / **~54% per-bank** = near the
~45% break-even ⇒ ~1.1× best case for a high-risk multi-session rewrite that
already wedged (PC=$0D62). Not worth it. The drafts (`rtl/sdram_pm.v.buildC*`,
`sim/sdram_pm_tb/`, `docs/plan_sdram_page_mode.md`) and the Layer-2 backpressure
fix remain on file if a future workload shows much higher locality — re-measure
with `pagehit_probe.py` first. A column-remap (`c64_addr[8:0]`→512-byte rows)
could raise locality but only pays *with* page-mode and risks REU/VIC layout.

### Option C (enabler, uncertain) — latency-faithful KERNAL-boot bench
Integrate `clk64_sdram_model` (faithful q5 latency) into `c64_reduced_harness`
running the real KERNAL boot in scpu mode; reproduce the iter-27 $EE97 wedge with a
fast-fire change. If it reproduces, *any* future clk32 speed fix becomes
validatable instead of dying on HW — would revive the cheap-arbiter levers. But
prior attempts (iter-23/24) found the model wedges even the baseline CPU; may only
confirm "unfixable in RTL."

### Lever 2 / Option D (highest ceiling, deepest) — pipeline 65C816 internals
Per iter-19 STA the real per-read floor is the CPU-internal di→ALU→BCD→PC path
(~15 ns), not the cpuDi mux (~3–5 ns). Biggest win, deepest multi-session effort.

### Backlog (documented, not current plan)
- **F — WriteSmart register decode** ($D074–D077 / $D0B3): specific real-HW feature;
  reportedly already software-visible, full decode is the remaining piece.
- bank-$01 ROM-shadow reads — deferred, no known consumer.

## Tooling notes
- SST regression oracle: `sweep_sst.ps1 -All` must stay 0/5.12M after ANY
  CPU/ALU/AddrGen change. Garbage variant: `-GarbageInternal`.
- HW A/B method: deploy suspect RBF, sample UART `PC:` distribution
  (`mister_debug.py uart N`). Healthy idle = a RANGE around $E5CD–$E5D6; wedge =
  one pinned address. Always run shipped `3698680a` as the control.
- `lorenz_run.py [scpu|t65]`'s MGL core-reload can transiently wedge the daemon
  pipe; `reboot` clears it (pre-authorized). Confirm core via `cat /tmp/CORENAME`.
- Full speed-lever death record + cadence math:
  `session_handoff_2026-06-13_iter28-speed-levers-exhausted.md`.
