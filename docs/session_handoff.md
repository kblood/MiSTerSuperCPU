# Session Handoff — iter-24 (2026-06-05)

## North star
Make the SuperCPU as compatible and fast as possible. The live speed lever is the
HW-proven 3.0x "same-line alt-fire" cache speedup (commit `0deb093`), **blocked**
by cache "Bug 2": with `CACHE_READ_PATH=true` the SuperRAM cache serves a stale
byte on a bank-$20 read, crashing Doom.

## THE DECISIVE FINDING (iter-24): Bug 2 is a SETUP-TIME class, not a functional bug
Four prior fixes (FILL_TXMATCH iter-16, FILL_DATAVALID_GATE iter-18,
FILL_CANCEL_ON_WRITE iter-22) were HW no-ops. iter-22 demanded a SYSTEM repro;
iter-23 built it (clk32 SDRAM) and found everything COHERENT. iter-24 closed the
last fidelity gap — a **dual-clock** SDRAM — and that is what cracked it:

- I built `clk64_sdram_model.vhd`: a clk64-clocked behavioral SDRAM that faithfully
  mirrors `sdram_pm.v`'s q-FSM (RASCAS=2, CAS=2 → STATE_READ=5, V6 early-exit),
  **sticky `data_valid`** (set at q==5, cleared at the clk64 ce-edge), consumed by
  the DUT's existing 1-flop clk32 sync. clk64 is PLL-aligned to clk32 in the tb.
- Result (CLK64_SDRAM=1): the **CPU itself reads stale SDRAM** and BRK-loops — the
  copied program body IS in SDRAM ($0800=$A9 verified, so writes land), but the
  CPU's instruction fetch from $0800 returns the not-yet-fresh `dout_r` ⇒ executes
  BRK ⇒ loops to $E000 (boot marker written 4×, done marker never).
- WHY this is the proof: in **zero-delay RTL sim** the P65C816 di-capture FF and the
  `cpu_cache` fill FF latch on the SAME clk32 edge and read the SAME zero-delay
  `cpuDi_nocache` expression. There is **no way** to make the CPU read fresh while
  the fill reads stale. Either the data is aligned to the latch edge (both correct
  — the clk32 baseline) or it isn't (both stale — the dual-clock CPU crash). The
  CPU-vs-fill DIFFERENTIAL that *is* Bug 2 exists ONLY on silicon, created by
  `C64.sdc`: the CPU's capture path has `set_multicycle_path -setup 2/4 -to
  *P65C816*` (lets it sample the late-arriving deep `cpuDi_nocache` mux), while the
  cache fill FF has **no equivalent relief** (lines 44-45 vs nothing for the fill).
  So on silicon the fill FF samples the still-propagating mux ~1 clk32 early = stale.
- ⇒ **No zero-delay RTL bench (unit, system, single- OR dual-clock) can reproduce
  Bug 2 as a functional divergence.** This explains all four prior no-ops AND
  retires the iter-22 "must build a system repro" mandate — the system repro is
  built and it PROVES the bug is unreproducible in sim. Validation of a fix must be
  **STA + HW**, not GHDL. Codex independently confirmed (two adversarial passes).

## The fix to build (Codex-vetted): matched-tuple STAGED FILL (option b)
Make the cache `fill_data` path **reg→reg** so it no longer samples the deep
`cpuDi_nocache` mux under a single-cycle constraint:
- At `rp_fill_fire`, register the WHOLE tuple together: `{data=cpuDi_nocache,
  addr=rp_fill_addr_dly, bank=rp_fill_bank_dly}` into staged regs (this capture is
  covered by the EXISTING clk64→clk32 setup-2 multicycle, C64.sdc:31-33).
- Assert cache `fill_we` ONE clk32 later, driving `fill_data/addr/bank` from ONLY
  the staged regs (reg→reg into the M10K — closes single-cycle naturally).
- Off-by-one care (Codex caveat d): data+addr+bank+we MUST be delayed together;
  the write/cancel invalidation must apply to the same staged tuple. Sticky
  `data_valid` must be transaction-matched (fire on the valid edge belonging to
  THIS read, not merely level-high) — else the staged fill can still capture the
  previous read's byte.
- Gate behind a constant (e.g. `FILL_STAGED_TUPLE`, default false = bit-identical
  shipped). Build → **read the STA report for the fill path** (confirm it closes
  where the direct path didn't) → ONE HW test: Doom + Lorenz with
  CACHE_READ_PATH=true + staged fill, alt-fire OFF first (isolate Bug 2); if Doom
  runs, add alt-fire for the 3x. Defer the SDC-multicycle option (c) — Codex: a
  multicycle alone can silence STA while HW still samples too early.

## What landed this session (iter-24)
- `sim/c64_reduced_harness/clk64_sdram_model.vhd` (NEW) — faithful clk64 SDRAM.
- `c64_reduced_top_v2.vhd` — `CLK64_SDRAM` generic (if-generate: clk32 simple model
  default / clk64 model opt-in); `clk64` port; ce strobe.
- `c64_superram_coherency_tb.vhd` — clk64 gen (PLL-aligned); `DUALCLK` mode; cross-
  line stale-dout test ROM witnesses; diag-divergence observers; dual-clock verdict.
- `rom_loader_pkg.vhd` `make_bug2_test_rom` — CROSS-LINE pattern: seed $20:0140=$AA
  & $20:00AE=$4A, read A then B then re-read B (the iter-18 stale-dout shape).
- `run_superram_coherency.sh` — `CLK64_SDRAM=0|1` env (default 0); stages+patches tb.

## iter-24b: ROBUST STAGED FILL implemented + TEST BUILD running
- `fpga64_sid_iec.vhd` gen_read_path: added `FILL_STAGED_TUPLE` (constant, default
  false = bit-identical shipped) + `stage_fill_proc` (3-stage) + rp_fill_*_sel/sel2
  muxes feeding the cpu_cache fill ports.
- CODEX REVIEW (tools/codex-out/iter24-staged-fill-review.txt) caught that a capture
  AT rp_fill_fire samples the deep mux on the SAME edge the direct M10K did => no
  settling gain, only endpoint shortening (marginal, my theory predicts it fails).
  Switched to the ROBUST 3-stage: stage1 @fire latches addr/bank + provisional data
  + arms; stage2 @fire+1 RE-captures the now-settled cpuDi_nocache (deep mux had the
  full 2 clk32 the C64.sdc:31-33 multicycle promises) when cpuAddr still matches
  (passthrough holds it stable, iter-16), emits fill_we; M10K writes reg->reg @fire+2.
  Fire-edge cancel (Codex bug #4: FILL_CANCEL_ON_WRITE clears rp_fill_req but fire
  is already high) + gap-cycle cancel; fire+2 write caught by cpu_cache cpu_wr_pending
  >fill priority. Assumes >=4-apart cadence (alt OFF); faster cadence needs review.
- Sim regression: clk32 baseline PASS with FILL_STAGED=1 (robust 3-stage, no break).
  Runner gained `FILL_STAGED=0|1` env (patch#6).
- TEST BUILD (UNCOMMITTED constant flips): CACHE_READ_PATH=true + FILL_STAGED_TUPLE
  =true, CACHE_DATA_OVERRIDE=true, HITPRED_SHORTGRANT=false, ALT_FIRE_SAMELINE=false
  (alt OFF to isolate Bug 2). Build log: build_iter24_staged.log. (A first marginal
  capture-at-fire build was killed ~8min in after the Codex review.)
- NEXT: when build green -> read STA fill-path slack -> check shared-MiSTer ownership
  -> ONE HW test (Doom + Lorenz). If Doom runs: flip ALT_FIRE_SAMELINE=true for the
  3x. If still stale (no-op): the deep mux itself is the wall even with 2 clk32 ->
  fill from the shallow `ramDin` node instead of the full cpuDi_nocache mux.
  Either way REVERT CACHE_READ_PATH + FILL_STAGED_TUPLE to false before committing
  source (keep the staged-fill RTL in tree, inert).

## Status / housekeeping (iter-24a)
- Bench GREEN both modes: clk32 (coherent baseline, PASS) and clk64 (dual-clock
  proof: CPU reads stale = EXPECTED finding, PASS). Re-run the proof:
  `CACHE_READ_PATH=1 CLK64_SDRAM=1 bash run_superram_coherency.sh`.
- iter-24a harness + docs committed `def0174`. Memory: project_bug2_setup_time_class.
