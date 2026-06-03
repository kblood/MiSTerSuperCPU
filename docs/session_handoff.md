# Session Handoff

## ✅🔬 iter-17 (2026-06-03): BUILD D RUNS DOOM (title screen) → cache FOOTPRINT INNOCENT → the cache-on crashes are TWO FUNCTIONAL bugs (fixable), NOT masked-timing. Cache read-path lever SALVAGEABLE. Next = GHDL-fix the `_d1` data-override staleness.

**DECISIVE POSITIVE RESULT (clean uninterrupted re-run, build `b6612ef2`):** Build D
(CACHE_READ_PATH=true, **data override OFF + hit_pred OFF** = both CPU-facing effects
off, cache still compiled-in + filling/snooping) **reaches the DOOM TITLE SCREEN** and
runs clean for the full 240s (UART grew steadily t020→t240, NO freeze; 1395 SuperRAM
lines sustained across banks $20-$2C; screenshot `tools/doom_autoload/buildD_rerun_C64.png`
= rendered DOOM logo + id Software + shareware menu). Even further than the cache-OFF
baseline's "Init Playloop." (The `doom_uart_test` "CRASH" verdict is a false positive
from its $80 heuristic — 93 $80 lines ~2%, recovered; Doom visibly renders.)

**THEREFORE (the strategic redirection):**
- The cache's **fitter footprint / mere presence is INNOCENT** — it does NOT corrupt
  Doom. The earlier "masked-timing footprint → pivot to Milestone C" hypothesis is
  FALSIFIED. (Build D's first run looked confounded by a CD32 takeover at t220; the
  clean re-run confirms it RUNS.)
- The cache-on crashes are **FUNCTIONAL, fixable bugs**, each independently sufficient:
  1. **`48730a04`** (data OFF, hit_pred **ON**) crashed = the **hit_pred grant**
     shortening corrupts (consumes SDRAM early per the `sdram_busy`→`cpu_cyc` mechanism).
     → MOOTED for shipping: just leave `HITPRED_SHORTGRANT=false` (the alt-fire FAST
     path is hit_pred-independent, so the 3× speedup survives without it).
  2. **ISOLATION C `4160e2ef`** (data **ON**, hit_pred OFF) crashed = the **`_d1`
     data override** serves a wrong byte on a bank-$20 read. → THE bug to fix (the
     cache feeds the CPU through it, AND the alt-fire FAST path consumes the registered
     `_d1`, so the speedup needs it correct).
- **Cache read-path lever is SALVAGEABLE** — fix bug #2 and the Doom-safe 3× speedup is
  back on the table (data override fixed + hit_pred off + alt on).

**THE PUZZLE for the GHDL attack:** `cpu_cache_sched_phasing_tb` (mains-only, 4-apart)
says the `_d1` override is COHERENT, and iter-16 `cpu_cache_bank20_replay_tb` Scenario
A (aligned/settled fills) is also coherent — yet ISOLATION C crashes at 4-apart with
the override on. So the benches are MISSING the real staleness source. Build D proves
it's FUNCTIONAL (reproducible in sim with a faithful-enough model), not timing.
Prime suspect: the loader-write→Doom-read coherency under REAL fill timing (the fill
source is `cpuDi_nocache` = SDRAM-delayed, not the bench's instant correct byte) ×
the override delivering it. iter-16 fill-skew fix was HW-falsified (passthrough holds
cpuAddr stable), so the skew model was wrong — but the staleness is real and lands via
the override. **NEXT (GHDL-FIRST):** build a bench that models loader long-stores to
bank $20 with realistic SDRAM write-commit-vs-fill-read timing + the `_d1` override
consumption at 4-apart, reproduce the ISOLATION C wrong-byte, prove a fix, THEN one HW
build (data ON + hit_pred OFF + fix; gate on Doom title + Lorenz + then add alt for 3×).

**SHARED-MISTER NOTE:** the CD32/ao486 agent overrode my fresh (<30min) lock and
core-swapped Minimig over the first Build D run at ~t220. Operator manually freed the
MiSTer for the clean re-run. For future decisive HW runs under contention, coordinate a
window (aicc/agent-db) rather than relying on the lockfile alone.

---

## 🗄️ (SUPERSEDED) iter-17 building-Build-D framing — kept for the partition logic

**NEW THIS SESSION (the decisive datum):** rebuilt + HW-ran ISOLATION C (build
`4160e2ef`, CACHE_READ_PATH=true, **data override ON, alt OFF, hit_pred OFF**).
Boots clean (KERNAL editor idle loop, healthy). **Doom CRASHED** — `doom_uart_test`
verdict CRASH: reached bank $20 (~36 lines), bounced through bank $00 (`PC:000A64`,
`I:000D68`, instr window `8D 7A D0 A9`), then wild `PC:2BAF57`/`8003CD`/`291117` →
$4D-heavy runaway (last SuperRAM `PC:2B8D00`). The Bug-2 family.

**What this proves (corrects the prior "data path INNOCENT" conclusion):**
- `48730a04` (data OFF, hit_pred **ON**) crashed ⇒ with the override off, the only
  CPU-facing cache feature was hit_pred ⇒ hit_pred IS a corruptor.
- ISOLATION C (data **ON**, hit_pred OFF) crashed ⇒ with hit_pred off, the only
  CPU-facing feature was the `_d1` data override ⇒ **the data override IS ALSO
  implicated.** Turning EITHER feature off alone did not save Doom. So "hit_pred was
  the sole 4-apart corruptor" is FALSE. Memory `project_bug2_is_hitpred_grant.md`
  title is now wrong (hit_pred is *a* corruptor, not *the* one).

**KEY TENSION (drives the strategy):** functional sim says the cache is COHERENT at
4-apart — both `cpu_cache_sched_phasing_tb` (mains-only control, 0 stale) and the
iter-16 `cpu_cache_bank20_replay_tb` Scenario A (aligned fills, settled timing).
Yet HW crashes in ALL THREE cache-on configs regardless of which CPU-facing feature
is on. Sim-coherent + HW-corrupt-regardless = the signature of a real timing
violation STA does NOT catch (the masked-timing / fitter-footprint class the memory
warns about for clk48/SLOT3), NOT a logic bug the functional benches can reach.

**DECISIVE CORNER NOW BUILDING — Build D** (CACHE_DATA_OVERRIDE=false +
HITPRED_SHORTGRANT=false, CACHE_READ_PATH=true): both CPU-facing effects OFF, cache
still compiled-in + filling/snooping. CPU runs pure baseline passthrough.
- **D RUNS** → footprint innocent; 48730a04 crash = hit_pred, ISOLATION C crash =
  `_d1` data override → TWO functional bugs (each in principle fixable, but the
  cache lever now needs two fixes + the speedup on top).
- **D CRASHES** → the cache's mere presence corrupts → masked-timing/fitter footprint
  → cache read-path lever is DEAD for Doom → bank the safe baseline, PIVOT to
  Milestone C (demand arbiter @ clk32, recover speed via bus slots, no cache).
- Build log `build_iter17_buildD.log`. MiSTer restored to safe baseline `95db2dda`
  + lock released (off-device until D finishes). On D done: claim lock, deploy, run
  `tools/doom_uart_test.py 240`.

**BUILD D RESULT (2026-06-03, CONFOUNDED by CD32 takeover — RE-RUN NEEDED):** built
`b6612ef2` (CACHE_DATA_OVERRIDE=false + HITPRED_SHORTGRANT=false + CACHE_READ_PATH
=true), STA-clean, boots clean. `doom_uart_test` classified CRASH, BUT the trace tells
a very different story from ISOLATION C: **Build D ran Doom DEEP** — 1981 SuperRAM
lines across banks $20,$21,$27,$28,$29,$2B,$2C (structured multi-bank engine
execution), ending in a tight legit loop in bank $28 (`$283CD5–$283D16`). NOT the
ISOLATION C garbage runaway (39 lines, random-bank spray → $00 wedge). The lone wild
bank $80 (119 lines) was EARLY (~t030, loader region `I:0007B2`) and execution
RECOVERED into deep Doom after. **CONFOUND:** the CD32/ao486 agent loaded Minimig over
my C64 at ~t220 (overrode my fresh 15:44 lock) — the UART freeze t220→t240 and the
CD32-logo `t240.png` are that core-swap, not a wedge. Screenshot `t180.png` (15:47) =
genuine C64 SuperCPU debug overlay (black bg, no visible Doom frame yet). **READING:**
leans STRONGLY toward FOOTPRINT INNOCENT → the cache-on crashes (ISOLATION C = `_d1`
data override, 48730a04 = hit_pred grant) are FUNCTIONAL & fixable, NOT masked-timing.
This is the hopeful branch. **BUT NOT CONCLUSIVE** (early $80, no visible frame,
takeover). **NEXT = clean Build D re-run** (uninterrupted MiSTer; verify screenshot
reads `/media/fat/screenshots/C64/` not MinimigCD; want a visible Doom title/menu frame
to confirm "runs"). If D confirmed-runs → GHDL-reproduce the data-override staleness
that crashes ISOLATION C at 4-apart (the sched_phasing bench currently says coherent →
it's MISSING something real), fix, re-enable data+alt, keep hit_pred off, HW-gate. If
re-run D actually crashes (the early $80 was real) → footprint after all → pivot to
Milestone C. COOPERATION NOTE: CD32 agent overrode a <30min lock; may clobber the
re-run — consider aicc/agent-db coordination for a 5-min window.

**Prior iter-17 builds (context):**

**Method that broke the logjam:** added a constant `CACHE_DATA_OVERRIDE` gating ONLY
the `cpuDi <= rp_cache_di_d1` override, plus `HITPRED_SHORTGRANT` gating
`sdram_hit_pred`, so I can turn the cache's CPU-facing effects on/off independently
and partition Bug 2 on hardware (it resists functional sim — iter-15b/16 proved the
functional cache is coherent, so the bug is system-level: arbiter/timing).

**Builds run this iter (all CACHE_READ_PATH=true; cache-OFF baseline runs Doom fine):**
- `48730a04` DIAGNOSTIC = data-override OFF, alt OFF, hit_pred ON. CPU gets
  byte-identical baseline SDRAM data. **Doom STILL CRASHED** (bank-$20 `2000C0`→`20038F`
  → wild `$80`/`$2B`/`$29`). ⇒ **the cache DATA path is INNOCENT**; corruptor is
  `sdram_hit_pred` OR the cache's fitter footprint. Mechanism for hit_pred:
  `sdram_busy_cnt<="001"` on a hit → `sdram_busy` clears early (:3376) → `cpu_cyc`
  fires sooner (:3489, gated on `sdram_busy='0'`) → `cpu_cyc_s(1)`/`enableCpu`
  consume sooner → CPU latches SDRAM before the ~79ns read settles = stale. This is
  the dual-tracker desync force-disabled at :3387-3396. (Refutes Codex's "hit_pred
  inert at 4-apart" — he missed that `sdram_busy` gates `cpu_cyc`.)
- `a42ec7d7` FIX-attempt = data ON, alt ON, hit_pred OFF (`HITPRED_SHORTGRANT=false`).
  **Still crashed** but the crash MOVED (reached bank `$2C` `PC:2CB717` then wild
  `$80`/`$FF`) ⇒ hit_pred=0 changed behaviour + let it run deeper, but a SECOND
  corruptor remains. This build changed 3 vars vs the diagnostic (data, alt, hit_pred)
  so it doesn't cleanly isolate. Suspect: alt-fire's 2-apart `_d1` consume.
- `bf2hbser1` (BUILDING) ISOLATION C = data ON, **alt OFF**, hit_pred OFF. SINGLE
  variable vs known-crash `38118b68` (data ON, alt OFF, hit_pred ON). DECIDES:
  - **C WORKS** → hit_pred WAS the 4-apart corruptor + the data path is HW-coherent
    at 4-apart. Since the fix-attempt (alt ON) crashed, alt-fire is a 2nd corruptor.
    Shippable now: correct cache @ 4-apart (no speedup = correctness milestone);
    then fix alt-fire's `_d1`-consume coherency for the 3×.
  - **C CRASHES** → hit_pred NOT the sole cause; data-path-at-4-apart or the cache's
    fitter footprint (placement pushes a relaxed-multicycle path marginal; STA-clean
    but real-violating, the clk48/SLOT3 masking class) corrupts. Cache lever likely
    DEAD for Doom → bank the safe baseline, PIVOT (Milestone C demand arbiter / compat).

**Test tool:** `tools/doom_uart_test.py [secs]` — reloads core, fires Doom MGL,
captures `/dev/ttyS1` continuously (reliable; the daemon screenshot pipe wedged mid-run),
auto-classifies SUCCESS / CRASH / STALL. Doom legit banks = `$00` + `$20-$3F`; wild =
`$80`/`$FF`/etc. SUCCESS needs a screenshot too (Init-Playloop text isn't on the CPU UART).

**State:** source currently = ISOLATION C config. RBFs archived under `C64_MiSTer/builds/`.
Memory: `project_bug2_is_hitpred_grant.md` (note: title is provisional — hit_pred
confirmed as A corruptor by the diagnostic, but the fix-attempt shows it's not the
ONLY one; update after Build C). MiSTer free (`CORENAME=MENU`).

---

## ✅ iter-16 (2026-06-03): BUG 2 ROOT CAUSE FOUND — fill-tuple skew (address-ahead-of-data). [SUPERSEDED by iter-17: fill-skew HW-falsified; data path proven innocent]

**Bottom line:** Bug 2 (SuperRAM bank-$20 read staleness that blocks the iter-15 3× speedup)
is a **fill-tuple skew**, not a write-race / tag-alias / missed-invalidate. The cache fill is
tagged with the LIVE `cpuAddr` while the fill DATA (`cpuDi_nocache` = pipeline-delayed `dout`)
belongs to the PREVIOUS access — so the just-read byte is stored under the NEXT address's line.
A later read of that line HITs and returns the stale "previous byte" → garbage operand → wild
JML → bank-$00 runaway. Cadence-independent because the address-ahead-of-data asymmetry exists
at any CPU cadence.

**Three converging proofs (no HW needed — done off-device while MiSTer held by ao486):**
1. **GHDL** `sim/cache_coherency_tb/cpu_cache_bank20_replay_tb.vhd` (+ `run_bank20_replay.ps1`):
   - Scenario A — Doom-like bank-$20 pattern (colliding direct-mapped lines, invalidating
     writes, same/cross-line reads) at faithful 4-apart SETTLED timing with ALIGNED fills →
     **0 stale**. The cache LOGIC is coherent; Bug 2 is NOT in cpu_cache.vhd.
   - Scenario B — inject a 1-cycle `fill_data`-vs-`fill_addr` skew → **every re-read HIT
     returns the PREVIOUS address's byte** (consumed=$37 vs golden=$5F, …) = exact Doom signature.
2. **Codex** (independent oracle) `tools/codex-out/bug2-superram-read-staleness.txt`: same
   fill-tuple-skew pick. Supplied the fact I'd assumed away — `RDY_HANDSHAKE=false`
   (fpga64_sid_iec.vhd:1637) + `data_ready` forced '1' (:3382) ⇒ neither the CPU consume nor
   `rp_fill_we` (:5000) is gated on real SDRAM-data-return; the fill tags delayed `dout` with
   LIVE `cpuAddr`/`addr_hi_816` (:5028-5031), not a transaction-matched token.
3. **`sdram_pm.v`** confirms the lag direction: read launches at the `ce`-edge (q→1), `dout_r`
   latches at q=5 (`STATE_READ`, :159-160) ≈ 5 clk64 later. `dout` LAGS while `cpuAddr`
   ADVANCES at the consume edge ⇒ fill_addr is ahead of fill_data.

**FIX DESIGN (chosen = option a, transaction-matched fill):** tag the fill with the address
whose data is actually in `dout` — capture `{addr_hi_816,cpuAddr}` at SDRAM read-ISSUE
(`cpu_cyc` slot, where `enableCpu_816` is low so `cpuAddr` has NOT yet advanced) and hold it to
the `rp_fill_we` edge. Emergent bench `cpu_cache_superram_pipe_tb.vhd` (LAT=3, nothing injected):
**MODE BUGGY (live cpuAddr) = 63/64 stale; MODE FIXED (tx-matched) = 0 stale.**

**✅ RTL IMPLEMENTED 2026-06-03 (uncommitted)** in `fpga64_sid_iec.vhd` behind `constant
FILL_TXMATCH := true` (+ `CACHE_READ_PATH := true`, `ALT_FIRE_SAMELINE := false` to isolate the
read-coherency fix from the speedup): new `rp_fill_addr_r`/`rp_fill_bank_r` capture process gated
on `supercpu_en and cpu_cyc and rp_cacheable and cpuWe='0'`, fed to `cpu_cache.fill_addr/fill_bank`
via `rp_fill_addr_sel`/`rp_fill_bank_sel`. Residual risk: single capture register assumes ≤1 read
in flight at the fill edge (true with alt-fire OFF, one CPU grant/arbiter period); if Doom still
shows staleness, upgrade to a depth-N delay line.

**HARNESS VALIDATED 2026-06-03** (the previous "Doom harness broken" claim was a MISDIAGNOSIS):
re-ran the autoload probe on cache-OFF `95db2dda` → reaches **"Init Playloop state."** REU/MGL
environment is HEALTHY. The garbage `$2C`/`V:AB` runaway that triggered the "broken harness"
worry was from `04b980a2`, which INDEX.md shows is **commit `0deb09327d` = iter-15 same-line 2×
alt-fire (speedup ON)** — i.e. the cache+alt build that crashes Doom BY DESIGN, NOT a cache-OFF
baseline. Lesson reaffirmed: identify the deployed build's commit before blaming environment.

**❌ HW RESULT 2026-06-03 — FILL_TXMATCH FALSIFIED (build `af834bf9`, STA-clean):** deployed +
ran the probe AND a continuous launch→crash UART (`tools/doom_autoload/fix_trace.txt`, 3240 lines).
Doom boots clean, launches, prints a full init-text screen (~t060), then crashes at the
**byte-identical** point as the unfixed cache-on build `38118b68`: 145 lines of real bank-$20 code
(last good `PC:2003AB` fetching correct `8D 7A D0 A9`), then a stale operand → wild `PC:80007F` →
bank `$4D`/`$2B` runaway (550 lines) → bank-$00 wedge (`PC:000047`, SP draining). **FILL_TXMATCH had
ZERO observable effect** ⇒ the fill-tuple skew is NOT Bug 2's HW cause: in deployed
`SAME_CLOCK_PASSTHROUGH` the bridge holds `cpuAddr` stable through the access, so capture-at-issue
== live `cpuAddr` at the fill edge = a no-op. The emergent pipe-bench "cpuAddr advances ahead of
LAT-delayed dout" model does not match real passthrough timing.

**Reverted `CACHE_READ_PATH := false`** (Doom-safe), restored MiSTer to `95db2dda`, released lock.
FILL_TXMATCH capture RTL kept in source (inert, correct-in-principle).

**REFINED SUSPECT (next iter, GHDL-FIRST — do NOT build until proven):** with alt OFF and the fill
addr provably un-skewed, the remaining read-path mechanism is the **iter-7d registered `_d1` hit/di
override** (`rp_cache_hit_d1`/`rp_cache_di_d1`, fpga64:5035-5041): on a cross-line cache HIT it may
serve a one-clk32-stale byte (the registered di lags `line_word` settling) → wrong operand → the
`$2003AB`→`$80007F` wild jump. The corrupting `$2003A3` read is likely a HIT (no fresh fill), which
is exactly why fixing the FILL path did nothing. Build a faithful GHDL bench modeling the `_d1`
override consumption at the real 4-apart cadence (extend `cpu_cache_sched_phasing_tb`), reproduce
the cross-line stale-hit, prove a fix, THEN one HW build. Detail in memory
`project_cache_invalidate_cpuen_hole.md`.

**HARNESS VALIDATED 2026-06-03** (was a misdiagnosis): cache-OFF `95db2dda` re-reached "Init
Playloop" — REU/MGL env is HEALTHY. The garbage `$2C`/`V:AB` run that triggered the "broken harness"
worry was `04b980a2` = INDEX.md commit `0deb09327d` = iter-15 speedup-ON (crashes Doom by design),
NOT a cache-OFF baseline. Identify the deployed build's commit before blaming environment.

**Also this session:** removed a stale, self-contradicting iter-12 "does-not-revive-the-lever"
claim from MEMORY.md (iter-15 already shipped the lever HW-proven 3.0×). The compaction summary
was anchored at iter-11; the project is actually at iter-15b/iter-16 — no RTL damage, only the
memory note was corrected.

---

## 🏁 PRIOR STATE (2026-06-02, end): TWO cache bugs found; speedup REVERTED to OFF to restore Doom.

**Bottom line:** the iter-15 cache-read-path 3× SuperRAM speedup regresses Doom via TWO
independent bugs. Bug 1 (invalidate-miss) is fixed + GHDL-proven. Bug 2 (SuperRAM bank-$20
read staleness) is HW-confirmed but NOT yet fixed. Per "compatible is the floor", I reverted
`CACHE_READ_PATH := false` (+ ALT_FIRE_SAMELINE false) on HEAD — Doom-safe, bit-identical to
the shipped baseline. The invalidate fix + DMA snoop + SuperRAM-only narrowing stay in source
(correct + inert when the path is off; ready for re-enable once bug 2 is fixed).

**Bug 2 evidence (the new, decisive data):** continuous full UART trace
`tools/doom_autoload/doomtrace_38118b68.txt` (3993 lines, captured from MGL fire — the stock
`doom_autoload_probe.py` only grabs 5 s at the end, which is why earlier sessions only saw the
post-crash runaway). On build `38118b68` (cache ON, SuperRAM-only, **alt-fire OFF**): the loader
populates bank $20 and the CPU REACHES bank $20 (145× `PC:20xxxx`), but with `V:AB AB AB AB`
(uninitialized regs), spins a tight `$2000AE-F1` loop, bounces to bank $00 (`$0009xx`→`$000D68`),
then JMPs wild ($2B/$80/$2C) → bank-$00 runaway (SP draining). cache-OFF baseline reaches Init
Playloop on the same SDRAM image ⇒ bank $20 has real data ⇒ the cache read path serves stale
bytes on bank-$20 reads. **Cadence-INDEPENDENT** (alt was OFF) ⇒ disabling alt-fire can't save
it; the speedup intrinsically needs CACHE_READ_PATH=true. (Caveat: the `W5` instr-window debug
field is frozen at loader bytes in the trace — unreliable for "is the fetch real code".)

**Build status:** iter-15b revert build (CACHE_READ_PATH=false) in flight. When done: deploy,
re-run the continuous doomtrace to confirm Doom runs on the SAME source with only the constant
flipped (the clean A/B), spot-check Lorenz scpu+t65 no-wedge, then commit the revert.

**NEXT ITER (GHDL-FIRST — do NOT burn HW builds speculating):** reproduce the bank-$20
loader-write→Doom-read staleness in `sim/cache_coherency_tb`. The loader copy loop is
`LDA $0500,Y (bank $00) / STA [$FB],Y (bank $20)` — no bank-$20 reads during transfer, so a
naive functional bench (fill pulls fresh SDRAM on Doom's first read) will NOT reproduce it →
the bug is a timing race or a hidden read. Suspects: (a) fill caching a stale/early SDRAM read
(write-through→read ordering at a late-written line); (b) tag-aliasing within bank $20
(line_index=addr(11:3), tag=bank&addr(15:12) — stale valid bit from addr A served for addr B);
(c) a long-store invalidate phase the `cpu_we`-window fix still misses. Resolve in sim, prove,
THEN re-enable. See memory `project_cache_invalidate_cpuen_hole.md` (updated).

---

## ⚠️ CORRECTION (2026-06-02, later): iter-15 REGRESSES DOOM — confirmed by clean A/B. The "Doom = environmental" claim below is FALSE.

The operator pushed back ("But Doom does not seem to be working on this core?") and was
right. Decisive A/B on the SAME harness/REU image, run back-to-back today:
- **Baseline `95db2dda`** ("restore Doom MGL autoload", CACHE_READ_PATH=**false**, cache OFF):
  Doom reaches **engine init** — W_Init WADfiles ./doom1.wad, Shareware!, R_Init DOOM
  refresh daemon, InitTextures/Flats/Sprites/Colormaps, **"Init Playloop state."** ⇒ the
  REU harness is HEALTHY today (doom.reu loaded fresh, transferred to SuperRAM, launched).
- **iter-15 `0deb093` (cache ON, alt ON)** and **iter-15b snoop-fix `cb53ed8c` (cache ON +
  DMA snoop + alt ON)**: Doom CRASHES. Snoop changed the failure from an early "eeee"
  loader wedge → a **late runaway** (PBR=$00, PC sweeping $8000-$CFFF at constant ~$C45
  stride, SP draining 4/sample, never enters bank-$20 Doom). The snoop was *progress*
  (fixed the bank-$00/REU staleness so the loader completes) but a residual coherency hole
  remains AFTER Doom launches — most likely SuperRAM coherency × the alt-fire FAST path's
  registered `_d1` data (a write-invalidate then immediate 2-apart read consuming the
  1-cycle-stale registered hit).

**Conclusion: the cache read path (required for the speedup) breaks Doom.** iter-15 as
committed is a real Doom regression. The speedup (3.0× SuperRAM, Lorenz-clean) is genuine
but NOT shippable until Doom coherency is fixed.

**ROOT CAUSE FOUND + FIXED (GHDL-proven).** The residual hole is the CPU-write
invalidation `invalidate_wr` in `cpu_cache.vhd`: it was gated on `cpu_en='1'`, so it
**missed** any write whose `cpu_we` strobe didn't coincide with the enable pulse the cache
samples on the clk32 edge — exactly the Doom-loader's turbo/alt-fire long-stores. The miss
left stale (pre-transfer garbage) bytes cached → CPU later fetched garbage code → the
runaway. Reproduced in the new bench `sim/cache_coherency_tb/cpu_cache_doom_coherency_tb.vhd`
(S2: `cpu_en=0` write returns STALE $AA; S1 aligned control passes). **Fix:** drop the
`cpu_en` gate; fire on the entire `cpu_we` window and exclude DMA writes via `snoop_we='0'`
(`snoop_we = dma_active and cpuWe`, so `not snoop_we` = "a CPU write, not DMA"; DMA is
handled by the snoop with the correct bank-$00 tag). Post-fix: doom bench S2 invalidates
(`hit=0`), original coherency bench still `TEST PASSED`. The hole is alt-fire-INDEPENDENT
(a pure invalidate miss), which is why cache-on crashed Doom even at 4-apart.

**In flight:** candidate build `b3yl243b4` = invalidate fix + DMA snoop + **ALT_FIRE=true**
(full speedup + Doom fix together). HW gate when done: (1) Doom autoload probe MUST reach
the menu/playloop (the fix's decisive test); (2) superram_bench COUNT ~2225 (3× speedup must
survive); (3) Lorenz scpu + t65 no-wedge. If all green: commit iter-15b, then it's a
Doom-safe speedup. (The earlier alt-off partition build was killed — the hole is
alt-independent so it was moot.)

**Push status:** `0deb093` is UNPUSHED and MUST NOT be pushed as a Doom-safe speedup until
this is resolved. MiSTer currently has baseline `95db2dda` deployed (Doom-works).

---

## (SUPERSEDED by the correction above) HEADLINE (2026-06-02): iter-15 same-line 2× alt-fire — HW-PROVEN 3.0× SuperRAM speedup. COMMITTED.

The fork's **first** >4MHz-class speed lever to survive the silicon gate. Commit
`0deb093` on `milestone-b-cdc-rewrite` (unpushed). Build `6fe98f79` (DEBUG flavor).

### What shipped
A single registered gap-gated enable scheduler in `fpga64_sid_iec.vhd` (~3604-3621)
that owns `enableCpu`, behind `ALT_FIRE_SAMELINE := true` && `CACHE_READ_PATH := true`
(both now true). It fires the CPU **2-apart on same-line SuperRAM cache hits** (8MHz)
while keeping the proven **4-apart** cadence for misses/writes/bank-$00/throttle.
- Collapses to `enableCpu <= cpu_cyc_s(1)` (RBF bit-identical) when off or in 6510 mode.
- MAIN = `cpu_cyc_s(1)='1' and en_gap>=3` (ties every miss-main to the real SDRAM
  prefetch slot CPU0/4/8/C → cpu_cyc_s(1) @ CPU2/6/A/E).
- FAST = `scpu_fast_path and not scpu_force_1mhz and not dma_active and en_gap>=1 and
  rp_same_line and rp_cache_hit and baLoc and cpu816_rdy_to_cpu and sysCycle∈even`.
  **LIVE gate, registered (`_d1`) data** — asymmetric, see below.

### Two corrections to the iter-14 brief that produced the final RTL
1. **LIVE gate, not `_d1`.** With registered `enableCpu<=fire`, the fast gate is
   evaluated at the even fire-eval slot where LIVE `rp_same_line`/`rp_cache_hit` is
   correct; only the DATA side keeps `rp_cache_di_d1`/`rp_cache_hit_d1` (latched at
   consume). Proven by `sim/cache_coherency_tb/cpu_cache_sched_phasing_tb.vhd`
   (LIVE PASS warm+cold, D1 FAIL 6/3 stale) and confirmed independently by Codex.
2. **Codex BLOCKING fix.** Tie ALL mains to `cpu_cyc_s(1)` (the delayed prefetch
   slot); the FAST cache-hit clause is the only off-cadence path. An off-prefetch
   miss-main would consume stale (the cache bench can't catch this — it models cache,
   not SDRAM). `tools/codex-out/iter15-rtl-review.txt`.

### HW gate (MiSTer 192.168.50.130, DEBUG rbf at /media/fat/_Test/C64.rbf — currently loaded, boots clean)
- **Boot**: clean SCPU64 ROM V0.07 / 38911 BASIC BYTES FREE / READY.
- **Lorenz scpu**: NO WEDGE, 16 distinct progress checkpoints over 8 min, all `- ok`.
  THE decisive test — clk64/clk48/SLOT3/page-mode/iter-7g all hard-halted here ~30-62s.
- **Lorenz t65**: NO WEDGE, all `- ok` (slow-path collapse = no 6510 regression).
- **STA**: TNS=0 all domains (CPU domain `emu|pll counter[0]` setup +2.410 / hold +0.255).
- **superram_bench A/B** (identical tree, only `ALT_FIRE_SAMELINE` flipped; control
  RBF md5-deduped to known-good baseline `f74736f6`): alt-fire **OFF COUNT=736**
  ($02E0), **ON COUNT=2225** ($08AE) → **3.0×**. >2× because the SuperRAM baseline
  runs below 4MHz (the ~1MHz throttle) and same-line hits bypass it.
- **Doom**: ENVIRONMENTAL-BLOCKED, not a regression. UART = the documented WP:00FD83
  REU-FETCH-wait stall; doom.reu was clobbered from SDRAM by the shared-MiSTer CD32/
  ao486 agent's all-day core cycling. CPU is alive (F-counter advancing). Wolf3D
  untested (same REU-harness dependency).

### Why it won where the raised-clock/cadence levers all died
Stays in the proven clk32 passthrough domain — NO raised clock, NO active CDC bridge
(those failed on a functional/CDC hazard, not pure timing). It only re-spaces the
`enable` pulse to 2-apart on cache HITS, where data comes from the registered `_d1`
latch (reg→reg, closes honestly at clk32) — NOT the deep ~20.5ns cpuDi/SDRAM mux that
bounds miss cadence. Sidesteps BOTH the masked-timing class AND the CDC class.

### State
- Source: `ALT_FIRE_SAMELINE=true`, `CACHE_READ_PATH=true` (winning config). Committed `0deb093`.
- MiSTer: iter-15 build deployed at `_Test/C64.rbf`, boots clean. The control build
  (`output_files/C64.rbf`, alt-fire off) was the temporary A/B and has been overwritten
  by the iter-15 redeploy.
- Push: GATED (user go-ahead required) — `0deb093` is unpushed.

### NEXT levers (the lever is banked; build on it)
1. Widen FAST eligibility to write-hits (currently `rp_cache_hit` excludes writes →
   they fall to 4-apart). GHDL-prove the write-hit coherency first.
2. Doom/Wolf3D no-regress once the REU image is reloadable (pure no-regress; did NOT
   block the commit — needs a fresh doom.reu load, SDRAM was clobbered by the shared agent).
3. Push cache line size / associativity so more of a real workload is same-line
   (raises the fraction running at 8MHz).
4. Miss cadence (still 4-apart, cpuDi-mux + SDRAM-79ns bound) — the next ceiling;
   only a deeper SDRAM-term attack (page mode on MISS, or prefetch) goes beyond this.

### Memory updated
`memory/project_alt_fire_2x_timing_viable.md` (iter-15 section + frontmatter),
MEMORY.md line 7 (HW-PROVEN) + line 9 (EXHAUSTED header annotated OVERTURNED).
