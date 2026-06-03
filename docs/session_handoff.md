# Session Handoff

## 🎯🔬⚙️ iter-18 (2026-06-03): fill-data-phase fix CORROBORATED on silicon (WD FFFF→2); a SECOND residual hole found; override consume still HW-unvalidated (REU env block)

**STATE: source restored to Doom-safe baseline (`CACHE_READ_PATH := false`, RBF
bit-identical to shipped). Fill-fix RTL + GHDL bench committed as inert infrastructure.
MiSTer lock released. Nothing pushed.**

### What iter-18 established

1. **Root cause (fill DATA capture phase) is real and the fix works in isolation.**
   GHDL bench `sim/cache_coherency_tb/cpu_cache_filldata_phase_tb.vhd` (run
   `run_filldata_phase.ps1`): models `dout_r` fresh at +3 clk32 while the fill fires
   at +2 (buggy) / +3 (fixed). Result **BUGGY=64, FIXED=0** — each buggy line returns
   the PREVIOUS access's byte (off-by-one stale) = exact HW signature. Re-verified
   this session.

2. **Silicon corroboration via the HW divergence detector.** Override-ON ground-truth
   build `595008b1` (CACHE_READ_PATH=true, CACHE_DATA_OVERRIDE=true,
   **FILL_DATAVALID_GATE=true**, detector retained). Plain boot = **clean to READY**
   (SCPU64 V0.07 / 38911 BYTES FREE) ⇒ the fill-fix RTL does NOT break execution.
   Doom UART run: divergence **WD collapsed from FFFF (saturated, unfixed iter-16/17)
   to 0002** ⇒ the fill-data-phase fix removed essentially all the content corruption.

3. **A SECOND, distinct residual hole.** The 2 surviving mismatches are at
   **bank $20, addr $00AE, cache=$00 vs SDRAM=$4A**. `cache=$00` is a pre-write/empty
   value ⇒ this is a **loader-WRITE → fill-READ ordering race** (Codex candidate a:
   the fill reads SDRAM before the loader's long-store to that line has committed),
   NOT the fill-phase bug just fixed. This is the next target.

4. **Override consume path is still HW-UNVALIDATED.** The Doom run never reached
   bank $20 — PC/instruction banks were 100% bank $00, oscillating between KERNAL idle
   ($E5CF/$E5D4/$E5CD) and the loader ML ($0700-$078E), with **WP:00FD83** (REU
   fetch-wait) + WP:00370F dominating. The loader is alive but never completes the
   REU→SuperRAM transfer ⇒ never XCE+JMLs into bank $20. This is the **recurring REU
   environmental block**, not a build regression. So the `_d1` override serving
   bank-$20 reads was not actually exercised.

### Key correction to the prior handoff

The divergence detector is **phase-ambiguous as an oracle**: it samples
`cpuDi_nocache` at the consume edge (+2), before `dout_r` is fresh (+3), so even a
correct cache can mismatch the stale reference. WD=0 was therefore never an
achievable clean target. The FFFF→2 *collapse* is still a strong signal (a no-op fix
would leave WD saturated), and the residual 2 at cache=$00 is independently meaningful
(empty-line, not a phase artifact). But do not treat WD as a precise correctness oracle.

### NEXT (GHDL-first — do this before any further override-on HW build)

1. **Extend `sim/cache_coherency_tb` to model the loader-WRITE → fill-READ ordering
   race** (the cache=$00 residual): a CPU long-store to a bank-$20 line, then a read
   miss to the same line whose fill reads `dout_r` *before* the store's data has
   propagated through `sdram_pm` (write latency + the read launch/q=5 latency).
   Reproduce cache=$00-while-SDRAM-has-data, then prove a fix (candidates: gate the
   fill on the same `sdram_data_valid` *and* ensure no in-flight write to the line, or
   invalidate-on-write must beat the fill — check `invalidate_wr` vs `fill_we` priority
   in `cpu_cache.vhd:380-503` under realistic write-commit timing).
2. Only after the bench reproduces+fixes the ordering race, do ONE HW build with
   override ON + both fixes, and get a **clean REU load** (verify the loader completes
   to bank $20 — watch for sustained bank-$20 PCs, not WP:00FD83) before judging it.
3. Then `ALT_FIRE_SAMELINE := true` for the 3× SuperRAM speedup; gate Doom + Lorenz +
   superram_bench.

### DECISIVE A/B (end of iter-18): override-on stalls the LOADER, build-specific

Two override-on Doom runs (build `595008b1`: CACHE_READ_PATH=true, CACHE_DATA_OVERRIDE
=true, FILL_DATAVALID_GATE=true, detector) **both stalled at the loader** — 100% bank
$00, WP:00FD83 (REU fetch-wait) + WP:00370F dominant, **0 bank-$20 lines**, reproducible.
The cache-OFF control (build `b6612ef2`: CACHE_READ_PATH=false, freshly compiled from the
restored baseline, STA-clean) on the **same MiSTer / same REU image / same harness today**
**completed the loader and ran SuperRAM Doom** — 4199 bank-$20..$2C lines, engine code
executing, ending in a loop at $2BDE55 (black screen this run = env/REU data quality, not
a cache effect; cache is off). ⇒ **the override-on loader stall is BUILD-SPECIFIC, not
environmental** — the REU harness works; enabling the read-path cache + override breaks the
loader even though the override is logically inert in the bank-$00 loader phase. Caveat:
the A/B disables the WHOLE gen_read_path generate, so the culprit is one of {override mux
masked-timing, my new FILL_DATAVALID_GATE logic interacting with the loader's bank-$20
write traffic, the detector} — not isolated. But the decision is the same regardless: after
iter-15..18, the cache-read-path/override HW lever does NOT converge and fails in
inconsistent masked-timing/integration ways. The fill-data-phase fix is proven OFF-DEVICE
(bench BUGGY=64/FIXED=0 + WD FFFF→2) but yields no working override-on HW build.

**VERDICT: park the cache-read-path speed lever.** Fill-fix banked as inert infrastructure
(commit 54eccfb). Pivot to a compat lever (next section). If ever revived: first isolate
which gen_read_path element stalls the loader (build Build-D + FILL_DATAVALID_GATE, override
OFF — if it completes the loader like plain Build-D did, the override mux is the masked-timing
culprit; if it stalls, my fill-gate logic is buggy). The deployed `b6612ef2` is the
Doom-safe baseline (RBF == shipped when CACHE_READ_PATH=false).

### Alternative if the override path stays a tar pit (NOW THE ACTIVE PATH)

The cache speed lever has now consumed iter-15..18. If the write-ordering bench does
not converge quickly, pivot to a compat lever where progress is not gated on the flaky
REU loader + an imperfect oracle: WriteSmart register decode ($D074-$D077/$D0B3), or a
SCPU library compatibility sweep. The shipped baseline (cache-off) is unaffected.

### Files (this session)

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — FILL_DATAVALID_GATE fix (delayed fill, latched
  addr/bank, fired on `sdram_data_valid_sync`); `CACHE_READ_PATH := false` restored
  (Doom-safe). Divergence detector + repurposed UART fields retained (inert when
  CACHE_READ_PATH=false).
- `sim/cache_coherency_tb/cpu_cache_filldata_phase_tb.vhd` + `run_filldata_phase.ps1`
  — NEW, the fill-data-phase reproduction+fix proof (BUGGY=64/FIXED=0).

Memory: `project_bug2_fill_latches_stale_dout.md` (update with the WD FFFF→2
corroboration + the cache=$00 write-ordering residual). LESSON: a content bug that
survives every golden-data sim can be a capture-phase bug the consumer dodges via a
multicycle exception its secondary capture FF doesn't share — model real dout latency.
And a HW detector run in a non-crashing config beats chasing a crash, but check its
sampling phase before trusting its zero.
