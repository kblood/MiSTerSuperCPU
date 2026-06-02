# iter-14 brief: realize the same-line 2× alt-fire enable (falsification target)

## What is proven (off-device, GHDL, committed `ade5aac`)
The SuperRAM read-path cache (`cpu_cache.vhd`, instance `read_path_cache` in
`fpga64_sid_iec.vhd`, gated by `CACHE_READ_PATH`) can feed the CPU at **2-apart
(8 MHz) on same-line hits** instead of the fixed 4-apart (4 MHz), with ZERO stale
reads, IF the shortened ("fast") CPU step is gated on the cache's `same_line`
output **sampled one clk32 before the consume** (registered = `rp_same_line_d1`).

Bench `sim/cache_coherency_tb/cpu_cache_altfire_race_tb.vhd`, modes:
- mode 0 (iter-7g shipped-bug gate, decision at E-2): **7 stale** reads → the HW wedge.
- mode 1 (decision moved 1 clk but only the alt slot gated): **2 stale** (post-fast main slot).
- mode 2 (oracle policy: latch iff csl≥4 OR same-line-as-prev-consumed): **0 stale**, 2.93 clk32/access.
- mode 5 (REALIZABLE: same as 2 but the same-line decision = the cache's LIVE
  `same_line` registered to E-1 = exactly a 1-clk enable): **0 stale, byte-identical
  schedule to mode 2.** This is the realizability proof.

Consume phasing (RTL-traced, why E-1 is the magic sample point):
- `cpu_cache.same_line` is combinational: `line(cpuAddr)==prev_line AND tag==prev_tag`,
  where `prev_line/prev_tag` are registered EVERY clk32 from the live address.
- `cache_di` = byteselect(line_word, offset); `line_word` is registered 1 clk32 after
  the address. The fpga64 override `rp_cache_di_d1` registers `cache_di` once more.
  ⇒ `cpuDi(E)` reflects `cpuAddr(E-2)`.
- The 816 advances cpuAddr 1 clk32 AFTER each enable (consume). So for a 2-apart fast
  consume at cycle E (previous consume at E-2): cpuAddr became access(E) at the E-2
  edge, so at **E-1** cpuAddr=access(E) while prev_line still holds access(E-1) ⇒
  `same_line(E-1)` == "access(E) same line as previously-consumed" == the safe condition.
  `rp_same_line_d1` (same_line registered once) is high during E and equals same_line(E-1).

## Enable path (clk32, today)
`cpu_cyc` (comb, fires at CYCLE_CPU0/4/8/C gated on cs_ram/turbo/throttle, plus the
disabled alt_fire_r/r2 terms) → `cpu_cyc_s <= cpu_cyc_s(0)&cpu_cyc` → `enableCpu <=
cpu_cyc_s(1)` (2-stage shift; main consume lands 3 clk32 after cpu_cyc, i.e. at
CPU3/7/B/F) → `enableCpu_816 <= enableCpu and not dma_active and supercpu_en` →
`scpu_async_bridge` with `SAME_CLOCK_PASSTHROUGH='1'` → passes through unchanged →
816 `enable`. The MCP bridge is transparent at clk_cpu=clk32. So this is purely an
`enableCpu`-generation change.

sysCycle order (32 clk32/1MHz): EXT0-3, DMA0-3, EXT4-7, VIC0-3, **CPU0..CPUF**.
Only CPU slots may step the CPU (VIC/DMA/EXT own the bus otherwise).
`CACHE_READ_PATH=true` is HW-PROVEN clean at 4-apart (iter-7e probe `e9c36c3e`: boots
SCPU64 V0.07/READY, Lorenz scpu+t65 PASS) — correctness only, no speedup yet.
`scpu_fast_path` = '1' only when the 816 executes from a SuperRAM bank (≠$00), i.e.
exactly where the cache + fast cadence applies. Bank $00 / I/O stays on baseline.

## Proposed RTL (the thing to falsify)
Gate everything behind `constant ALT_FIRE_SAMELINE : boolean` (requires
CACHE_READ_PATH). When false, `enableCpu <= cpu_cyc_s(1)` exactly as today
(RBF bit-identical). When true AND `supercpu_en='1' AND scpu_fast_path='1'`,
replace enableCpu generation with a UNIFORM gap-gated pulse:

```
-- candidates = the 7 in-phase consume slots CPU3,5,7,9,B,D,F (2-apart within the CPU phase)
-- csl = clk32 since the last enableCpu pulse (reset to 1 on fire, else +1; runs across
--       the EXT/DMA/VIC gap so it is always >=4 by the next CPU3 = first consume safe)
fast_slot <= sysCycle in {CPU3,CPU5,CPU7,CPU9,CPUB,CPUD,CPUF}
fire      <= fast_slot AND ( (csl>=4)                       -- full pipeline margin, always safe
                          OR (csl>=2 AND rp_same_line_d1) ) -- 2-apart same-line, safe per mode 5
enableCpu <= fire        -- bypasses cpu_cyc_s entirely in fast-path mode
```
When `scpu_fast_path='0'` (bank $00 / I/O), fall back to `cpu_cyc_s(1)` (baseline).
`rp_same_line_d1` comes from wiring `read_path_cache.same_line => rp_same_line` (today
`open`) and registering it one clk32 inside `gen_read_path`.

## Stress these failure modes (be adversarial — this lever has been HW-falsified ~5×)
1. **fast↔baseline transition glitch.** When `scpu_fast_path` toggles mid-stream
   (816 crosses between SuperRAM and bank $00 / hits I/O), enableCpu switches between
   the gap-gated generator and `cpu_cyc_s(1)`. Can this drop a step, double-fire, or
   land an enable in a non-CPU slot? cpu_cyc_s keeps shifting underneath. Is an OR
   (`cpu_cyc_s(1) OR fire`) safer than a mux, or does OR double-step at the boundary?
2. **csl seeding / bus-gap.** csl free-runs across EXT/DMA/VIC. Is there any path where
   csl<4 at the first CPU3 of a phase (e.g. a fire at CPUF then CPU3 next phase = how many
   clk32 apart? CPUF→next CPU3 spans the 16-cycle non-CPU gap, so >=4 — confirm)?
3. **I/O & CIA timing.** Baseline fires cpu_cyc at CPUC for `io_enable` (1MHz CIA/SID
   window) and there's a `scpu_force_1mhz` throttle (KERNAL IEC). Does bypassing
   cpu_cyc_s in fast-path mode break the throttle or the CPUC I/O slot? (Note throttle
   only matters in bank $00 serial routines where scpu_fast_path=0, so baseline path runs.)
4. **Address-advance vs the next decision.** rp_same_line_d1 at slot E reflects
   same_line(E-1). After a fire at E the 816 advances cpuAddr at the E edge; at E+1
   same_line recomputes. For the NEXT candidate E+2, rp_same_line_d1 must reflect
   same_line(E+1) = access(E+2) vs access(E). Confirm the single registration delivers
   that and there's no 1-slot skew that re-introduces mode-1's post-fast staleness.
5. **STA / 1-clk enable hold.** The fast pulse is effectively a 1-clk enable. Any new
   hold/0-margin risk vs the 2-clk cpu_cyc_s path? (iter-12 showed rp_cache_hit_d1→ALU
   closes setup-1 +7.8ns; this is about the enable FF, not the data path.)
6. **VIC/badline RDY.** 816 rdy = `baLoc AND cpu816_rdy_to_cpu AND data_ready`. Does the
   uniform generator interact badly with baLoc badline stalls (enable high while rdy low)?

Question for Codex: is the proposed uniform gap-gated enable the right realization, or
is there a less-invasive form that still gates EVERY 2-apart consume (mode 5 proved the
post-fast main slot MUST be gated, so a pure additive alt-pulse is insufficient)? Find
the boot-wedge before we spend a 30-40 min build + a contended-MiSTer HW gate.

---

# CORRECTED DESIGN (post-Codex-falsification, iter-14)

Codex verdict on the draft above: **do-not-build**. Two findings changed the design;
both are now resolved off-device (bench commit `88e0aa3`, GATE_MODE=6 + PREFILL=false).

## Finding 4 (the subtle one) — FIXED + proven off-device
`same_line` (cpu_cache.vhd:180) is **line/tag equality only**, NOT a valid-byte hit
(:269-276). Fills are per-byte on accepted misses (fpga64:4925). So a cold line can be
`same_line=1` while the requested byte is invalid (`cache_hit=0`); a fast 2-apart fire
there consumes stale `cpuDi_nocache` (SDRAM not ready at 2-apart). Bench mode 5 with
PREFILL=false reproduces this (7 FAST-MISS stale, csl=2). **Fix:** the fast 2-apart
fire requires `rp_same_line_d1 AND rp_cache_hit_d1` (mode 6 → 0 fails cold AND warm;
warm rate unchanged at 2.93 clk32/access; cold 3.86 = fills 4-apart then hits 2-apart).

## Finding 1 + the post-fast-main collision — drives the architecture
A "fixed 4-apart mains (cpu_cyc_s) + inserted fast pulses" structure is unsafe: a fast
fire at a between-slot advances the address, making the NEXT fixed main a 2-apart consume
that is stale if cross-line (mode 1 = 2 residual fails). Muxing `enableCpu` between
`cpu_cyc_s(1)` and the fast generator also leaks a pending `cpu_cyc_s(1)` pulse across a
`scpu_fast_path` toggle, and OR-ing defeats the gap gate. ⇒ **single registered
scheduler owns enableCpu in SuperCPU mode; cpu_cyc_s is NOT tapped for the 816 enable
when the scheduler is active.**

## The scheduler (the thing to build, behind ALT_FIRE_SAMELINE; baseline-identical when off)
Confine candidates to CPU consume slots, gap-gate uniformly, mask with the existing
baseline permissions (so I/O/throttle/badline keep working):
```
fire = cpu_consume_slot                         -- slot-aware (NOT a free counter; keeps CPUC I/O + turbo alignment)
       AND base_permit                          -- the existing cs_ram / io_enable@CPUC / not scpu_force_1mhz / not dma gating
       AND ( csl >= 4                            -- full margin: the proven 4-apart cadence (also the bank-$00 / I/O / miss path)
           OR ( csl >= 2                         -- fast 2-apart, ONLY when ALL hold:
                AND scpu_fast_path                --   SuperRAM bank (≠$00), cs_io=0  [fpga64:3314-3317]
                AND rp_same_line_d1               --   E-1 same-line as prev-consumed  [mode 5]
                AND rp_cache_hit_d1 ) )           --   byte actually valid in cache    [mode 6 / finding 4]
enableCpu <= fire    -- registered; the fast path is effectively a 1-clk enable
```
Rules from the other findings:
- **(2) csl** resets to 1 ONLY on an accepted `fire`; +1 otherwise; reset value on
  `reset`. Free-runs across the EXT/DMA/VIC gap (CPUF→next CPU3 ≫ 4 clk32, so the first
  in-phase consume is always full-margin). `base_permit` already blocks non-CPU slots.
- **(5) STA / 1-clk hold:** `fire` is registered (no comb enable). Fast path requires
  `rp_cache_hit_d1` so the cpuDi mux (:1987) is on the cache value. MEASURE the new FF's
  setup/hold on the fitted netlist (cache_path_probe.tcl); iter-12 showed
  rp_cache_hit_d1→ALU closes setup-1 +7.884 so the data side fits.
- **(6) RDY/badline:** 816 `EN = RDY_IN and CE` (P65C816.vhd:102) swallows CE-while-RDY-low,
  but csl must reset on ACCEPTED advancement, not on a generated pulse that RDY squashes —
  else same-line phasing desyncs from "previously consumed". So either reset csl on the
  CPU's actual step-ack, or AND `baLoc` into the fire/csl-reset (no fire while baLoc low).
- Wire `read_path_cache.same_line => rp_same_line` (today `open`) and register once in
  `gen_read_path` → `rp_same_line_d1`. Set `CACHE_READ_PATH=true` (HW-proven clean at
  4-apart, iter-7e `e9c36c3e`).

## Remaining gates before this is real
1. **Off-device boot validation** of the scheduler via `sim/c64_reduced_harness` (the
   scheduler subsumes baseline gating; the warm/cold cache bench does NOT cover I/O /
   throttle / badline — the reduced harness boot is the right vehicle). This is the next
   local probe.
2. Build (local, ~30-40 min) → **STA** (finding 5: the new enable FF + the 1-clk fast path).
3. **HW gate** (needs a free MiSTer): boot clean + Lorenz scpu/t65 100% + Doom + Wolf3D
   no-regress + `superram_bench` COUNT > control (proves speedup) + measure effective MHz.
