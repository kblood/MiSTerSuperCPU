# Session handoff — 2026-06-02 (iter-13)

## HEADLINE
The iter-7g 2× alt-fire functional consume-race is now **REPRODUCED OFF-DEVICE**
(GHDL) and a **correct + faster gating policy is proven**. The new bench
`sim/cache_coherency_tb/cpu_cache_altfire_race_tb.vhd` (committed `01ec2ad`) is a
faithful cycle-exact model of the fpga64 consume phasing. It answers the iter-12
open question and goes one step further: it shows the obvious "fix the same_line
timing" idea is INSUFFICIENT, and identifies the correct gap-based invariant.
RTL realization (with its own decision-before-address timing hazard) + STA + HW
gate remain. MiSTer was CONTENDED (ao486 lock) → all work off-device by design.

## iter-13 — the bench and its four modes (commit 01ec2ad)
Faithful phasing (RTL-traced): `cpu_cache.cache_di` reflects addr(E-1) (registered
`line_word`), the iter-7d override `rp_cache_di_d1` adds 1 more clk32 ⇒ cpuDi(E)
reflects **addr(E-2)** ⇒ a latch consuming the access on cpuAddr(E) is SAFE iff
addr(E-2) is the same cache line as addr(E). cpuAddr advances 1 clk32 after each
latch (the 816 steps). Latch cadence: main @ sysCycle 2/6/10/14 (4-apart = 4MHz),
alt @ 4/8/12/0 (2 after a main = 8MHz).

| mode | gate policy | failures | clk32/access | meaning |
|------|-------------|----------|--------------|---------|
| 3 CONTROL | no alt (pure 4-apart) | **0** | 4.00 | validates the bench phasing |
| 0 iter-7g BUG | same_line @ main-latch cycle | **7** | 2.00 | gate is a NO-OP → reproduces wedge |
| 1 TIMING-FIXED | same_line sampled 1 clk32 later | **2** | 2.66 | necessary but INSUFFICIENT |
| 2 UNIFIED FIX | csl≥4 OR same-line-as-prev-consumed, else STALL | **0** | 2.93 | correct AND ~37% faster |

Run: `powershell sim/cache_coherency_tb/run_altfire_race.ps1` (sweeps all 4 modes;
logs in `work_altfire/`).

### Findings
1. **Open question answered.** In mode 0, `same_line` sampled at the main-latch
   cycle is ALWAYS '1' (the address is stable for the whole slot, so current line
   == previous line). So the iter-7g same_line gate never suppresses anything →
   alt fires unconditionally → every cross-line consume returns the PREVIOUS
   line's byte (idx=2: $1008 expected B0, got A0). That IS the wedge.
2. **Timing-of-decision fix alone is insufficient (NEW, beyond iter-12's plan).**
   Sampling same_line 1 clk32 later (after cpuAddr advances to the alt access)
   correctly suppresses alt on genuine cross-line — BUT a fired alt slot advances
   the address one step early, compressing the FOLLOWING **main** slot to 2-apart
   margin (cycles_since_latch=2); if that access is cross-line it is STILL stale
   (mode 1: idx=2, idx=15). The handoff's "consume combinational rp_cache_di on
   the alt slot" idea does not cover this post-alt main slot.
3. **The correct invariant is GAP-BASED and uniform.** Treat every even cycle as a
   latch candidate; latch iff (cycles_since_last_latch ≥ 4 = full pipeline margin)
   OR (current access same-line as the **previously CONSUMED** access); otherwise
   STALL one slot to rebuild 4-apart margin. This covers alt slots AND post-alt
   main slots. Proven 0-fail and faster than 4-apart control (2.93 vs 4.00
   clk32/access ≈ +37% on a mixed stream; → 2.0 = 8MHz on pure same-line runs).

## NEXT STEP (off-device first, then HW gate) — RTL realization of mode 2
The bench decides AT the latch cycle (combinationally on the live addr). Real RTL
can't: `cpu_cyc → enableCpu` is 2 clk32 (`enableCpu <= cpu_cyc_s(1)`), so a latch
at cycle E is decided at E-2 when the to-be-consumed access's address is NOT yet on
cpuAddr (it appears at E-1, after the E-2 latch advances the 816) — the SAME root
timing that makes the same_line gate leak. **Sharp conclusion (airtight):** a
shortened (2-apart) latch CANNOT be safely decided at E-2 with the existing 2-clk
enable, because the safe condition needs access(E) same-line as the prev-consumed
access, and access(E)'s line is unknown at E-2. iter-7g failed precisely because it
kept the 2-clk enable and only changed the gate.

**The realizable fix = move the fast-path decision to E-1 via a 1-clk enable.** At
E-1 the live `same_line` signal EXACTLY equals the mode-2 condition (live addr =
access(E) just appeared; cpu_cache's registered `prev_line` = access(E-1) =
prev-consumed) ⇒ `same_line(E-1)` = "access(E) same-line as prev-consumed". So:
1. **Design:** generate the shortened-slot enable from a decision registered at E-1
   (i.e. use `cpu_cyc_s(0)` / a 1-clk enable on the same-line fast path) gated on
   live `same_line OR full-margin`; otherwise fall to the normal 4-apart `cpu_cyc_s(1)`
   path (= STALL one slot, rebuilding margin). This applies the gate to EVERY 2-apart
   latch (alt AND post-alt main), which mode 2 proved is required. On the fast path
   consume the COMBINATIONAL `rp_cache_di` (valid immediately within a line), not the
   `_d1` register (which is built for the 4-apart latch).
2. **Extend this bench** to model the cpu_cyc→enable pipeline and the E-1 registered
   decision explicitly (a "mode 5"), confirming the 1-clk-enable fast path implements
   mode 2's policy with 0 fails. The current mode 2 proves the POLICY; mode 5 must
   prove the REALIZABLE decision phase implements it. Watch the new hold/0-margin
   risk of the 1-clk enable.
3. **STA-check** the chosen consume path closes at setup-2 (combinational
   `rp_cache_di → cpuDi → ALU` adds ~10ns cache-internal mux — iter-12 showed it
   closes at setup-1 +7.884 / setup-2 +39.6, so it fits; MEASURE on the fitted
   netlist with `cache_path_probe.tcl`).
4. **HW gate** (needs MiSTer): boot clean + Lorenz scpu/t65 100% + Doom + Wolf3D
   no-regress + `superram_bench` COUNT > control $0335 (proves speedup) + measure
   effective MHz. Also wire the DMA snoop for the Doom REU coherency gap (iter-7f).

## Device / cooperation
- Control build `97392a1f` is the healthy reference (Lorenz scpu/t65 PASS, Doom +
  Wolf3D PASS). NOT deployed.
- **Shared MiSTer CONTENDED:** `ao486` agent lock at last check. All HW gating of
  any future alt-fire build waits for the device to free up.

## Artifacts
- `sim/cache_coherency_tb/cpu_cache_altfire_race_tb.vhd` + `run_altfire_race.ps1`
  (committed `01ec2ad`) — the iter-13 reproduction + fix-policy bench.
- iter-12 STA probes still in `C64_MiSTer/` (untracked): `cache_path_probe.tcl`,
  `internal_path_probe.tcl`, `cadence_sweep.tcl`, `alu_sta_probe.tcl` + their
  `*_path.txt` evidence.

## RTL state: CLEAN. No shipped RTL change this session (the bench is a new sim
artifact; cpu_cache.vhd and fpga64_sid_iec.vhd untouched). Speed lever is the
live thread: the 2× alt-fire is NO LONGER timing-dead AND no longer just a
"reproduce it" TODO — the fix policy is proven; only a realizable RTL decision
path + STA + HW gate remain.
