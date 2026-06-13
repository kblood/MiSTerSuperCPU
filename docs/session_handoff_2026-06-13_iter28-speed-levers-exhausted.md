# Historical Handoff Archive — iter-27 / iter-28 (2026-06-13)

> Archived from `session_handoff.md` on 2026-06-13. This captures the full
> falsification record for the last two speed-lever attempts (internal-cycle
> fast-fire, demand arbiter) and the SDRAM-cadence analysis behind the 4 MHz
> floor. The live handoff keeps only the forward-looking frontier; this file is
> the evidence trail.

## North star
Make the SuperCPU as compatible and fast as possible.

## ⛔ iter-28 GOAL B (GHDL, no build): demand arbiter FALSIFIED — INERT. GOAL-A "GO" was WRONG.
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

## ⛔ iter-27 OUTCOME: internal-cycle fast-fire HW-FALSIFIED
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

## Speed-lever death record (the zero-delay-bench wall)
The shipped build runs **pure ~4 MHz** in clk32 passthrough. The 4 MHz floor is
SDRAM-bound: `enableCpu` fires only at sysCycle CPU0/4/8/C (every 4 clk32),
matched to the ~4-clk32 SDRAM read latency (`busy_cnt="011"` MISS floor). We are
~5× below real SuperCPU 20 MHz. **Dead levers** (each: zero-delay bench passes,
silicon wedges — the SDRAM-latency / setup-time / phase class):
- cache read-path (iter-16/17/18/22/23/24 — 5 RTL fixes all HW-dead)
- raised-clock B (clk64/clk48)
- alt-fire 2×
- internal-cycle fast-fire (iter-27)
- demand arbiter (iter-28 — inert even in zero-delay)
**Anti-pattern that has failed 6×: do NOT build another speed RBF off a
zero-delay bench.**

## Cadence facts (reference)
- `enableCpu <= cpu_cyc_s(1)` shipped; `cpu_cyc` @CPU0/4/8/C gated on
  `sdram_busy` + `cs_ram`; `busy_cnt="011"` MISS reservation STATIC-decrements to
  0 at N+4 = a hard 4-apart FLOOR = the 4 MHz ceiling (iter-28: NOT a 3-apart
  permit; demand slots are busy-blocked, so adding arbiter slots cannot beat it).
- A fire's data pipeline: `cpu_cyc`@N → `cpu_cyc_s(1)`@N+2 → `enableCpu`@N+3
  consume; `sdram_pm` (V6) samples `dout_r` at q=5 = 5 clk64 = 2.5 clk32 after the
  ce-edge; min ce-spacing = 6 clk64 = 3 clk32 (auto-precharge). Sub-3-clk32 reads
  need a page-mode controller, not an arbiter change.

## Working-tree state at archive time (committed `ccbdf2a`)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — `DEMAND_ARBITER := false` (iter-28 INERT,
  gated dead record) + `INTERNAL_FAST_FIRE := false` (iter-27 HW-dead) +
  `cpu_cyc_va_ok` VDA/VPA gate. Both kept as the record.
- `sim/c64_reduced_harness/c64_internal_fastfire_tb.vhd` + `run_internal_fastfire.sh`
  — system bench. iter-28 added `turbo_m`/`sdram_busy`/cpu_cyc fire-rate observers
  (`DEMAND_FIRERATE` report) + runner `DEMAND=0|1` (patch#9) and `NOEARLYCLEAR=1`
  (patch#10). A/B verdict: false≡true≡NOEARLYCLEAR, all 7640 fires / gap=3.
- iter-28 A/B logs: `tools/codex-out/demand2_true_baseline.log` (DEMAND=0) vs
  `demand2_demand_on.log` (DEMAND=1) — byte-identical fire-rate.
- Garbage-sweep proof harness committed `2c34007`.
- Codex v2 review: `tools/codex-out/iter27-fastfire-v2-review.txt`.
