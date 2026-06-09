# Session Handoff — iter-27 (2026-06-09)

## North star
Make the SuperCPU as compatible and fast as possible.

## ⛔ iter-27 OUTCOME: INTERNAL-FAST-FIRE HW-FALSIFIED — lever joins the HW-dead set
The HW gate ran (build `0675f71e`, `INTERNAL_FAST_FIRE=true`) and the lever **WEDGED
on silicon**: black screen, CPU hard-pinned at **PC:$EE97** (KERNAL IEC region),
never reached READY. **Control (same MiSTer, same session):** the iter-26 shipped
RBF `3698680a` booted **clean** — SCPU64 V0.07 / "38911 BASIC BYTES FREE / READY.",
PC cycling the real keyboard-idle loop **$E5CD–$E5D6**. So the wedge is the lever,
not the environment. This **falsifies the "different class / no SDRAM-staleness
risk" hope**: fast-firing internal cycles 2-apart still advances the CPU's phase
ahead of the ~4-clk32 SDRAM read cadence, so the *following* memory fetch races
SDRAM latency = the same setup-time/phase class that killed every cache lever
(Bug 2). Everything zero-delay PASSED (system bench bit-identical 178→0 + ~8%
faster; SST garbage 0/5.12M; Codex logic-clean) yet HW wedges — exactly the class
a zero-delay bench cannot reproduce. **Action taken (per the documented plan):**
reverted `INTERNAL_FAST_FIRE := false` (RBF bit-identical to shipped), kept the
gated RTL + system bench + garbage-sweep harness as the record, restored MiSTer
`_Test` to iter-26 `3698680a`, committed. **Net speed status: ALL known speed
levers are now HW-dead** (cache read-path, raised-clock B clk64/clk48, alt-fire,
internal-fast-fire). The shipped build remains pure ~4 MHz. The next real speed
lever requires either (a) a latency-faithful KERNAL-boot bench (c64_reduced_harness
+ clk64_sdram_model) that can finally REPRODUCE this wedge class so a fix is
validatable, or (b) a pipeline inside the 65C816 (deep, multi-session), or
(c) Milestone C demand-arbiter @ clk32. Do NOT build another speed RBF off a
zero-delay bench — that anti-pattern has now failed 6×.

## TL;DR of where we are
- **COMPAT is essentially solved at the instruction level.** SST suite is 100%
  clean (0/5.12M, iter-26). Lorenz 100% both modes. Doom + Wolf3D run; SCPU Kicks
  renders. No strong signal points at a specific broken instruction → the open
  half of the north star is now **SPEED**.
- **SPEED status:** shipped build runs **pure ~4 MHz** in clk32 passthrough —
  every prior speed enhancement (cache read-path, raised-clock B clk64/clk48,
  alt-fire) is HW-dead and inert behind `CACHE_READ_PATH=false`. The 4 MHz floor
  is SDRAM-bound: `enableCpu` fires only at sysCycle CPU0/4/8/C (every 4 clk32),
  matched to the ~4-clk32 SDRAM read latency. We are ~5× below real SuperCPU
  20 MHz.

## iter-27: INTERNAL-CYCLE FAST-FIRE — new speed lever, PROVEN-SAFE semantics, v1 scheduler FLAWED (do not build)
A genuinely **different, safer class** than the dead cache/alt-fire levers. Every
dead lever raced *SDRAM data delivery* (and the cache added an unconstrained fill
FF = the Bug-2 setup-time corruptor). This lever touches neither.

**Idea:** ~22.6% of CPU cycles are INTERNAL operations (VDA=0 ∧ VPA=0: RMW modify,
decimal correct, taken-branch IO, transfers, NOP, REP/SEP, XBA, stack/ctrl IO —
measured across all 256 opcodes from the SST traces). On an internal cycle the
W65C816 makes **no valid memory access**, so the data bus is don't-care. Those
cycles currently still wait for the 4 MHz SDRAM cadence even though they need no
bus. Firing them 2-apart (2 clk32, next even CPU slot) gives ~**+12-15%**
throughput with no SDRAM-staleness risk. It would be the **first shippable** speed
gain (everything else is inert).

### What is DONE and SOLID this iteration
1. **Semantic-safety PROOF (GHDL-first, the foundational result).** Modified the
   SST harness to drive D_IN with garbage (`x"5A"`) on every internal cycle
   (VDA=0 ∧ VPA=0) — new `-GarbageInternal` switch on `run_sst.ps1` /
   `sweep_sst.ps1` (generic `garbage_internal`, gated, default false = baseline).
   - Diverse subset (RMW, decimal ADC/SBC, abs,X page-cross, branches,
     RTI/RTS/RTL, MVN/MVP, JSR/JSL/JML, XBA, SBC(dp,X)) = **44,000 cases, 0 fail**.
     Results: `sim/p65c816_singlesteptest/sweep_results_garb_subset/`.
   - **Full 5.12M sweep COMPLETE (definitive):** `pass=5,114,328 fail=0
     skip=5,672` (`-All -GarbageInternal`, `sweep_results_garb_full/`) —
     identical pass/skip split to the clean iter-26 baseline ⇒ the CPU never
     consumes D_IN on internal cycles. Harness COMMITTED `2c34007` (reusable
     oracle; baseline bit-identical when the generic is false).
2. **Payoff quantified:** 22.6% internal cycles (median per-opcode 22.8%;
   NOP/XBA/transfers/REP/SEP run 50-75% internal). Model ⇒ ~+12-15%.
3. **SDC analysis (favorable):** `set_multicycle_path -setup 2 -to *P65C816*`
   (C64.sdc:44) already assumes enableCpu fires ≥2 clk32 apart — the fast-fire
   (even slots, en_gap≥2) respects it exactly; CPU-internal reg→ALU→reg closes at
   setup-2 (+23.6ns, iter-19 STA). Adds NO new data-capturing register; reads NO
   SDRAM on the fast cycle. dout_r→CPU budget (clk64→clk32 -setup 2) is unchanged.
4. **RTL implemented, gated, syntax-clean.** New constant `INTERNAL_FAST_FIRE`
   (`fpga64_sid_iec.vhd` ~:1690, default **false** ⇒ RBF bit-identical) + a new
   highest-priority scheduler branch (~:3775). Quartus Analysis & Elaboration
   **0 errors** (`syntax_iter27.log`).

### The v1 FLAW — FIXED + SYSTEM-BENCH VALIDATED (iter-27 v2)
**v1 flaw (Codex):** `cpu_cyc` was gated on `cs_ram` (address decode), NOT on
VDA/VPA. An INTERNAL cycle presenting a RAM-region address still issued a
`cpu_cyc` prefetch + a pending `cpu_cyc_s(1)` MAIN pulse → dangling MAIN consumes
stale data on the following cycle ⇒ wedge.

**FIX (applied):** new combinational `cpu_cyc_va_ok` (`fpga64_sid_iec.vhd`, near
the `cpu_cyc` assignment) = `'1' when (not INTERNAL_FAST_FIRE) or (vda_816='1' or
vpa_816='1')`, AND-ed into the `cpu_cyc` main-slot block. When `INTERNAL_FAST_FIRE`,
an internal cycle issues NO prefetch and NO MAIN pulse — it is advanced ONLY by
the fast-internal scheduler branch; memory cycles keep the full prefetch+consume
window. When false, `cpu_cyc_va_ok` folds to `'1'` ⇒ `cpu_cyc` bit-identical to
the shipped arbiter. Quartus A&E **0 errors** (`syntax_iter27.log` re-run).

**SYSTEM-BENCH VALIDATION (decisive):** new
`sim/c64_reduced_harness/c64_internal_fastfire_tb.vhd` + `run_internal_fastfire.sh`
drive the REAL `fpga64_sid_iec` arbiter + real P65C816 with `make_bug2_test_rom`,
observe `cpu_cyc/cpu_cyc_s(1)/vda_816/vpa_816/enableCpu` via external names, and
assert the invariant "cpu_cyc never '1' while vda=vpa=0". A/B (`FASTFIRE=0` vs `1`):
| metric | baseline | fast-fire |
|---|---|---|
| viol_count (prefetch-on-internal) | **178** | **0** |
| witnesses (w0/w1/w2/done) | $AA/$4A/$4A/$EE | $AA/$4A/$4A/$EE (identical) |
| fastfire_cnt (lever engaged) | 178 | 178 |
| ticks_to_op2000 | 68776 | 63364 (~7.9% fewer) |
The fix drives prefetch-on-internal 178→0 (a model-INDEPENDENT structural
property: the stale-data desync can only arise FROM a prefetch-on-internal, so
zeroing them removes the mechanism the zero-delay bench otherwise can't see),
keeps output bit-identical, and runs measurably faster. `DUALCLK=true` is NOT
used for this A/B (it wedges even the baseline CPU in zero-delay — the
setup-time-class finding). RESIDUAL (HW-only): the Codex #2 PHASE question
(vda/vpa at the decision edge = pending cycle's) and the setup-time margin — a
zero-delay bench can't confirm timing; that's the single HW-build gate.

## Next levers (resume here, priority order)
1. **Finish the internal-fast-fire lever (the active speed thread).**
   a. ✅ Garbage sweep 0/5.12M (proof complete, committed `2c34007`).
   b. ✅ Scheduler redesigned (`cpu_cyc_va_ok` VDA/VPA gate) — A&E 0 err.
   c. ✅ System bench built + A/B validated (178→0, bit-identical, ~8% faster):
      `sim/c64_reduced_harness/c64_internal_fastfire_tb.vhd` +
      `run_internal_fastfire.sh`. `FASTFIRE=0|1 bash run_internal_fastfire.sh`.
   d. ✅ Re-Codex'd the v2 fix (`tools/codex-out/iter27-fastfire-v2-review.txt`).
      Verdict POSITIVE: (#2) no prior-memory `cpu_cyc_s(1)` vs fast-internal
      collision — MAIN resets en_gap first; (#3 PHASE) vda/vpa at the decision
      edge ARE the pending cycle's flags in passthrough (the handoff's "HW-only"
      residual — now structurally confirmed); (#4) no `<2 clk32` spacing
      violation. ONE actionable but INERT finding (#1): `cpu_cyc_va_ok` qualifies
      only the main term, NOT the trailing `alt_fire_r`/`alt_fire_r2` terms
      (fpga64_sid_iec.vhd:3662-3663) — both are hard-`'0'` every clk32 in this
      build (the `'1'` assigns at 3757/3780 are commented out), so it is inert
      HERE; it would only re-open the dangling-MAIN hazard if alt-fire is ever
      revived alongside INTERNAL_FAST_FIRE. Defensive fix (AND `cpu_cyc_va_ok`
      into those terms too) deferred — alt-fire is HW-dead; revisit only if revived.
   e. ✅ DONE = HW build `0675f71e` (`INTERNAL_FAST_FIRE := true`) deployed + tested.
      **RESULT: WEDGED** (black screen, PC pinned $EE97). Control iter-26 `3698680a`
      booted clean on the same MiSTer. ⇒ phase/setup-time class CONFIRMED, lever is
      HW-DEAD. Reverted constant to false, restored MiSTer, committed gated RTL +
      bench as the record. See the "⛔ iter-27 OUTCOME" block at the top.
      Diagnostic note for next time: the wedge looks like a healthy idle at a glance
      (frames advance, WD:FFFF) — the tell is PC pinned at a SINGLE address vs the
      real keyboard-idle loop's $E5CD–$E5D6 RANGE. Always A/B against the shipped RBF.
2. **SST stays the compat regression oracle** — re-run `sweep_sst.ps1 -All` after
   any CPU/ALU/AddrGen change (must stay 0/5.12M).
3. **Real SuperCPU software compat** — secondary; current pool (Doom/Wolf3D/SCPU
   Kicks) all run. Open-ended, needs new curated titles.

## State of the working tree (COMMITTED this iteration — lever recorded as HW-dead)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — `INTERNAL_FAST_FIRE := false` (HW-dead, gated;
  RBF bit-identical to shipped) + `cpu_cyc_va_ok` VDA/VPA gate + fast-internal
  scheduler branch + the HW-dead annotation. Kept as the record.
- `sim/c64_reduced_harness/c64_internal_fastfire_tb.vhd` + `run_internal_fastfire.sh`
  — the system bench (A/B `FASTFIRE=0|1`, 178→0 prefetch-on-internal, bit-identical,
  ~8% fewer ticks). NOTE: zero-delay ⇒ it could NOT predict the HW wedge (the whole
  point — same blind spot as the Bug-2 benches).
- Garbage-sweep proof harness already committed `2c34007` (`p65c816_sst_tb.vhd`
  `garbage_internal` generic + `run_sst.ps1`/`sweep_sst.ps1 -GarbageInternal`).
- Codex v2 review: `tools/codex-out/iter27-fastfire-v2-review.txt` (logic-clean,
  flagged only the inert alt-fire-term gap #1).
- MiSTer `_Test` restored to iter-26 `3698680a` (known-good); lock released.

## Tooling notes
- Garbage-internal proof: `run_sst.ps1 -InputFile <op>.<e|n>.txt -GarbageInternal
  -StopTime 60000ms`; sweep `sweep_sst.ps1 -All -GarbageInternal -ResultDir X`.
- Internal-cycle fraction measured by parsing CY-block flag tokens (positions
  1-2 = VDA 'd' / VPA 'p'; '--' = internal) in `external/65816/v1.bin/*.txt`.
- Deployed HW = iter-26 `3698680a` (md5 confirmed on `/media/fat/_Test/C64.rbf`).
  MiSTer free at handoff (CORENAME=MENU).
- Cadence facts: `enableCpu <= cpu_cyc_s(1)` shipped; cpu_cyc @CPU0/4/8/C gated on
  sdram_busy + cs_ram; busy_cnt="011" MISS floor = ~4 clk32 = the 4 MHz ceiling.
