# Session Handoff — iter-28 (2026-06-13)

## North star
Make the SuperCPU as compatible and fast as possible.

## ⛔ iter-28 GOAL B DONE (GHDL, no build): demand arbiter FALSIFIED — INERT. GOAL-A "GO" was WRONG.
Prototyped the Milestone C demand arbiter (`DEMAND_ARBITER` constant; busy-gated
extra `cpu_cyc` terms at CPU1/2/3/5/6/7/9/A/B, all inside the `sdram_busy='0'`
gate) and A/B-tested it in `sim/c64_reduced_harness`
(`run_internal_fastfire.sh`, `DEMAND=0|1`).
- **Genuine A/B (real constant false vs true, staged-verified): BYTE-IDENTICAL** —
  cpu_cyc_fires=7640, min_cyc_gap=3, ticks_to_op2000=68776, witnesses
  $AA/$4A/$4A/$EE in both. The demand arbiter adds **ZERO fires → no speed gain**.
  (NO HW build — correctly avoided the 7th zero-delay-blind speed RBF.)
- **GOAL-A premise was WRONG.** "busy_cnt='011' already permits a 3-clk32 cadence;
  only slot positions stop it" is FALSE. "011" STATIC-decrements 011→010→001→000
  and clears `sdram_busy` only at **N+4** (`:3786-3791`), so it is a **4-apart
  FLOOR**. Every demand slot requires `cs_ram='1'` and is therefore busy-blocked
  through N+1..N+3 → never fires. The `sdram_ready` early-clear is REDUNDANT:
  `NOEARLYCLEAR=1` (patch#10) is byte-identical; a-fortiori on HW the 6-clk64 MISS
  + 2-FF sync makes ready visible only at ~N+5, later than the static N+4, so the
  4-apart floor governs HW too.
- **Instrumentation correction**: `min_cyc_gap` counts IDLE holes between fires
  (`since_cyc` increments only when cpu_cyc=0, tb:344) → gap=3 = a **4-apart**
  cadence = the documented 4 MHz floor, NOT 3-apart over-firing. (A 2026-06-09 note
  misread this.)
- **Reaching 3-apart needs reservation "010"** (clears at N+3) → SDRAM ce-edge
  spacing = exactly 6 clk64 = the V6 throughput floor with ZERO slack. The ±1 clk64
  uncertainty of the `cpu_cyc`→ce strobe sync (`C64.sdc:82-90`, a real 3-FF
  synchronizer) can land the 2nd ce-edge at q=5 (mid-`dout_r` sample) → `sdram_pm`
  FSM restart → corruption = the SAME dead class as the 6 prior levers. "010" is
  NOT safe and is zero-delay-blind. **The only sound throughput lever is a
  page-mode SDRAM controller** (open-row back-to-back column reads, no 6-clk64
  spacing) — the deferred Build-A rewrite (wedged PC=$0D62).
- `DEMAND_ARBITER := false` committed as a gated dead-lever record (RBF
  bit-identical to shipped `3698680a`; Quartus constant-folds the term away).
- Full detail: memory `project_demand_arbiter_inert_zerodelay.md`.

## Where we are
- **COMPAT is solved at the instruction level.** SST suite 100% clean (0/5.12M,
  iter-26). Lorenz 100% both modes. Doom + Wolf3D run; SCPU Kicks renders. No
  signal points at a specific broken instruction. The SST vein is exhausted.
- **SPEED is the open half — and ALL known speed levers are now HW-dead.** The
  shipped build runs **pure ~4 MHz** in clk32 passthrough. The 4 MHz floor is
  SDRAM-bound: `enableCpu` fires only at sysCycle CPU0/4/8/C (every 4 clk32),
  matched to the ~4-clk32 SDRAM read latency (`busy_cnt="011"` MISS floor). We are
  ~5× below real SuperCPU 20 MHz. Dead levers: cache read-path, raised-clock B
  (clk64/clk48), alt-fire, and now internal-fast-fire (iter-27). Each died the
  same way: **zero-delay bench passes, silicon wedges** (the SDRAM-latency /
  setup-time / phase class). **Anti-pattern that has failed 6×: do NOT build
  another speed RBF off a zero-delay bench.**

## ⛔ iter-27 OUTCOME (record): internal-cycle fast-fire HW-FALSIFIED
HW build `0675f71e` (`INTERNAL_FAST_FIRE=true`) **WEDGED** — black screen, CPU
hard-pinned at **PC:$EE97** (KERNAL IEC region), never reached READY. Control
(same MiSTer, same session): iter-26 shipped RBF `3698680a` booted **clean**
(SCPU64 V0.07 / READY, PC cycling the real keyboard-idle loop **$E5CD–$E5D6**) ⇒
the wedge is the lever, not the environment. Falsifies the "different class / no
SDRAM-staleness risk" hope: fast-firing internal cycles 2-apart still advances the
CPU's phase ahead of the ~4-clk32 SDRAM cadence → the *following* memory fetch
races SDRAM latency = the same class that killed every cache lever. Everything
zero-delay PASSED (system bench bit-identical 178→0 + ~8% faster; SST garbage
0/5.12M; Codex v2 logic-clean) yet HW wedges. Reverted `INTERNAL_FAST_FIRE :=
false` (RBF bit-identical), kept gated RTL + bench as the record, restored MiSTer,
committed `51c3d6c`. Full detail: memory `project_internal_cycle_fast_fire.md`.
Diagnostic lesson: a boot wedge masquerades as a healthy idle (frames advance,
WD:FFFF) — the tell is PC pinned at ONE address vs the idle loop's $E5CD–$E5D6
RANGE. ALWAYS A/B a suspect speed RBF against the shipped RBF on the same MiSTer.

## NEXT — arbiter-tweak speed levers are EXHAUSTED; pick a frontier below

iter-28 closed the last cheap speed idea. The 4 MHz floor is a genuine
SDRAM-throughput floor (6 clk64 = 3 clk32 min ce-spacing, auto-precharge), and the
arbiter already runs the CPU as fast as that floor + the di-FF multicycle safely
allow (4-apart). You cannot beat it by adding arbiter slots — every faster cadence
either is busy-blocked (demand, inert) or eats the ce-sync jitter margin (the "010"
reservation, dead class). The two real levers left are both large:

### Speed lever 1 (real, big) — page-mode SDRAM controller
Replace the auto-precharge `sdram_pm` read path with open-row back-to-back column
reads so a same-row read costs ~4 clk64 instead of the cold 6–8. This is the ONLY way
to legitimately drop below the 6-clk64 ce-spacing floor. Already deeply explored: 8
draft FSMs (`rtl/sdram_pm.v.buildC*/.V5/.V6/.V7/.V8*.draft`, one
`V8_addrlatch_FAILED`), a dedicated bench `sim/sdram_pm_tb/`
(`sdram_pm_buildc_extended_tb.vhd`), and a full design in `docs/plan_sdram_page_mode.md`
(Layer 1 page-mode FSM + Layer 2 `ready` backpressure + Layer 3 extra CPU slots). The
Build-A page-mode wedged the C64 at PC=$00:$0D62 — the 2nd slot's `ce` edge restarted
the FSM mid-access (`plan_sdram_page_mode.md:7-10`); Layer 2 backpressure (gate
`cpu_cyc` on `sdram_ready`) is the fix for that and is the part still not wired in.

**DO THIS FIRST (cheap characterization gate, no risky build — the GOAL-A discipline
that just paid off):** measure Doom's SuperRAM **page-hit rate** during gameplay.
`plan_sdram_page_mode.md:87-103` — if hit-rate >90%, page-mode wins little and the
whole multi-session rewrite is NOT worth it; if <60%, it's a big win. Unknown today.
Cheapest: add a hit/miss counter to the `sdram_pm` open-row predictor (the
`sdram_pred_row/bank/valid` logic already exists in `fpga64_sid_iec.vhd:3767-3801`),
expose via UART/`T:`/`WD:`, run `tools/doom_autoload_probe.py` for ~60 s, read the
ratio. That number decides whether Lever 1 is pursued at all.

### Speed lever 2 (highest ceiling, deepest) — pipeline the 65C816 internals
Per iter-19 STA the real per-read floor is the CPU-internal di→ALU→BCD→PC path
(~15 ns), not the cpuDi mux. Pipelining it is the biggest win but the deepest,
multi-session effort.

### Compat frontier (productive, NO risky build) — real SuperCPU software on HW
SST is 100% clean and Lorenz passes both modes, so instruction-level compat is
solved; the live frontier is *non-instruction* incompatibility. Curate real SCPU
software (GEOS, SCPU-library titles, timing-sensitive demos, WriteSmart users), run
on HW, and triage failures. This is the natural north-star step that does NOT require
a speed build and cannot hit the dead zero-delay-bench wall. **Recommended next** if
the goal is steady progress without committing to a multi-session controller rewrite.

## Other options (documented, not the current plan)
- **C — Latency-faithful KERNAL-boot bench.** Integrate `clk64_sdram_model`
  (faithful q5 latency) into `c64_reduced_harness` running the *real* KERNAL boot
  in scpu mode, and reproduce the iter-27 $EE97 wedge with a fast-fire-style
  change. If it reproduces, *any* future clk32 speed fix becomes validatable
  instead of dying on HW. High leverage but **uncertain** — prior attempts
  (iter-23/24) found `clk64_sdram_model` wedges even the baseline CPU in
  zero-delay, and it may only confirm "unfixable in RTL." Worth building if B
  needs a validation harness it doesn't currently have.
- **D — Pipeline the 65C816 internals.** Per iter-19 STA the real floor is the
  CPU-internal di→ALU→PC path (~15 ns), not the cpuDi mux (~3–5 ns). Pipelining it
  is the highest ceiling but the deepest, multi-session effort.
- **E — Real SuperCPU software compat sweep.** Curate new titles (demos, GEOS,
  SCPU library) and run on HW; this is where *non-instruction* incompatibilities
  (timing-sensitive demos, WriteSmart usage) surface. Open-ended, lower per-unit
  signal since the current pool passes. This is the natural compat frontier now
  that SST is exhausted.
- **F — WriteSmart register decode** ($D074–D077 / $D0B3). A specific real-HW
  feature from the backlog that may unlock specific software. Reportedly already
  software-visible; full decode is the remaining piece.
- **(low) bank-$01 ROM-shadow reads** — deferred, no known consumer.

## State of the working tree (clean — committed `ccbdf2a`)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — `DEMAND_ARBITER := false` (iter-28 INERT,
  gated dead record; RBF bit-identical to shipped) + `INTERNAL_FAST_FIRE := false`
  (iter-27 HW-dead) + `cpu_cyc_va_ok` VDA/VPA gate. Both kept as the record.
- `sim/c64_reduced_harness/c64_internal_fastfire_tb.vhd` + `run_internal_fastfire.sh`
  — system bench. iter-28 added `turbo_m`/`sdram_busy`/cpu_cyc fire-rate observers
  (`DEMAND_FIRERATE` report) + runner `DEMAND=0|1` (patch#9) and `NOEARLYCLEAR=1`
  (patch#10). A/B verdict: false≡true≡NOEARLYCLEAR, all 7640 fires / gap=3 (4-apart).
  Zero-delay — confirms inertness but (as always) cannot predict an HW wedge.
- iter-28 A/B logs: `tools/codex-out/demand2_true_baseline.log` (DEMAND=0) vs
  `demand2_demand_on.log` (DEMAND=1) — byte-identical fire-rate.
- Garbage-sweep proof harness committed `2c34007`
  (`p65c816_sst_tb.vhd` `garbage_internal` + `run_sst.ps1`/`sweep_sst.ps1
  -GarbageInternal`).
- Codex v2 review: `tools/codex-out/iter27-fastfire-v2-review.txt`.
- MiSTer `_Test` = iter-26 `3698680a` (known-good), lock released, healthy
  (PC cycling $E5CD–$E5D6).

## Tooling notes
- SST regression oracle: `sweep_sst.ps1 -All` must stay 0/5.12M after ANY
  CPU/ALU/AddrGen change. Garbage variant: add `-GarbageInternal`.
- HW A/B method: deploy suspect RBF, sample UART `PC:` distribution
  (`mister_debug.py uart N`). Healthy idle = a RANGE around $E5CD–$E5D6; wedge =
  one pinned address. Always run the shipped `3698680a` as the control.
- `lorenz_run.py [scpu|t65]`'s MGL core-reload can transiently wedge the daemon
  screenshot/command pipe (stale frames / empty `/media/fat/screenshots/C64/`);
  `reboot` clears it (pre-authorized). Confirm core via `cat /tmp/CORENAME`.
- Cadence facts: `enableCpu <= cpu_cyc_s(1)` shipped; `cpu_cyc` @CPU0/4/8/C gated
  on `sdram_busy` + `cs_ram`; `busy_cnt="011"` MISS reservation STATIC-decrements to
  0 at N+4 = a hard 4-apart FLOOR = the 4 MHz ceiling (iter-28: NOT a 3-apart permit;
  demand slots are busy-blocked, so adding arbiter slots cannot beat it).
- A fire's data pipeline: `cpu_cyc`@N → `cpu_cyc_s(1)`@N+2 → `enableCpu`@N+3 consume;
  `sdram_pm` (V6) samples `dout_r` at q=5 = 5 clk64 = 2.5 clk32 after the ce-edge;
  min ce-spacing = 6 clk64 = 3 clk32 (auto-precharge). Sub-3-clk32 reads need a
  page-mode controller, not an arbiter change.
