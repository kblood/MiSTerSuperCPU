# Session handoff — 2026-05-23 end-of-session (FINAL — REVISED 2)

## TL;DR — single root cause: Step 7b's alt_fire_r2

**One bug, two symptoms.** Both the "LDA al → STA pipeline hazard"
and the "bank-$20 payload wedge" trace to Step 7b's `alt_fire_r2`.
Re-running every probe on the alt_fire_r2-OFF build (RBF md5
`a993d7b7`, bit-identical to pre-Step-7b baseline at `83d7716`)
shows ALL previously-wedging variants pass.

1. **~~LDA al → STA pipeline hazard~~ COLLAPSED into alt_fire_r2**
   (commit `2407264` is now historical, not a workaround). drill3_c
   (LDA al + 0 NOPs + STA $02) renders all markers + ♦ readback on
   the OFF build. **NOP padding is NOT needed.** Bisect ladder
   retained as regression net.

2. **Bank-$20 wedge ROOT-CAUSED: Step 7b's `alt_fire_r2`** (commit
   `c254063` hard-gates it OFF). With alt_fire_r2 disabled, every
   bank-$20 payload test now works:
   - `gen_b20_border.crt`: border turns RED ($02).
   - `gen_alive_nopped.crt`: "ALIVE BANK20" renders at row 6.
   - `gen_superram_bench.crt`: COUNT/PASS counters update live;
     **PASS advanced $028F → $0958 in 10s ≈ 174 passes/sec**.
   The OFF-gated RBF (md5 `a993d7b7`) is **bit-identical** to the
   pre-Step-7b baseline at `83d7716`, validating the controlled-
   variable bisect.

3. **Step 7b is CURRENTLY BROKEN.** Its `alt_fire_r2` (fires CPU
   access at CPU3/7/B/F with predicate `sdram_busy_cnt <= 1` at
   CPU2/6/A/E) causes the wedge. The hazard mechanism: at CPU3, a
   new SDRAM transaction starts while the prior transaction's data
   has not yet propagated through `sdram_data → cartridge → ramDin
   → cpuDi`, causing either bus collision in the SDRAM controller
   or stale-byte latching by the CPU. Decision needed: REVERT
   the commit, or DESIGN a proper gate (task #5).

4. **Other earlier wins still valid**:
   - prg_to_crt ZP-indirect bootstrap (`b869136`)
   - Long-mode single ops via CRT-boot (`d693ca3`)
   - CRT wrapper toolchain (`4174d7c`, `4173954`)

## Hazard #1: ~~LDA al → STA pipeline drain~~ (was actually alt_fire_r2)

Re-ran the full drill3 ladder on the alt_fire_r2-OFF build:
- `drill3_c` (LDA al + 0 NOPs + STA $02): renders all markers
  AAAA BBBB CCCC DDDD EEEE FFFF + ♦ readback at col 24 + GGGG
- `drill3_a` (LDA al + JMP self): F marker + ♦ readback + halt
- `drill3_i` (LDA al + STA al): all markers + GGGG
- `drill3_k` (LDA al + LDA al): all markers + GGGG

**NOP padding is no longer needed.** The "1 NOP fixes" rule was an
unintended consequence of how the NOP changed the alt_fire_r2 timing
relative to the next memory op. With alt_fire_r2 fully off, the
hazard simply doesn't exist.

The bisect ladder (`gen_copyback_drill[2,3].py`, `gen_copyback_fresh.py`)
is retained as a regression net for future alt_fire_r2 reintroduction
attempts.

## Hazard #2: Step 7b alt_fire_r2 / bank-$20

### Pattern that wedges
Step 7b's alt_fire_r2 in `fpga64_sid_iec.vhd:2848-2856` fires CPU
access at CPU3/7/B/F when `scpu_fast_path AND cs_ram AND
sdram_busy_cnt <= 1` is true at CPU2/6/A/E. Symptom: JML to
bank-$20:$8000 succeeds but bank-$20 payload produces no
observable bank-$00 side effects.

Mechanism (hypothesis):
- Main CPU access fires at CPU0, sdram_busy_cnt resets to 3.
- Cnt decrements 3→2→1 by CPU2.
- alt_fire_r2 latches at CPU2 (cnt=1 → predicate true).
- CPU3 cpu_cyc='1' from alt_fire_r2 — new SDRAM transaction.
- Old transaction is still in flight (cnt=1 means 1 clk32 of
  decrement left, but SDRAM data hasn't propagated to ramDin →
  cpuDi yet).
- Either SDRAM controller mishandles back-to-back triggers, OR
  CPU latches stale cpuDi byte for the prior LDA's read result.

### Fix options (task #5)
- **A) Revert Step 7b commit `09655d8`.** Simplest. Loses the
  intended SuperRAM 5 MHz boost.
- **B) Strict predicate `sdram_busy_cnt = 0`.** Probably never
  fires after a main slot (cnt=1 at CPU2 from main slot CPU0 fire).
- **C) Gate on `sdram_ready_sync(1)='1' since last cpu_cyc`.**
  Requires an extra "fresh data available" latch. Most likely to
  preserve the perf intent without the hazard.
- **D) Move alt_fire_r2 to CPU4/8/C/0** = same as main slot —
  degenerate.

## State on disk

- Branch: `milestone-a-build-c-revival`
  - HEAD: `c254063` (alt_fire_r2 OFF gate)
  - RBF deployed: `/media/fat/_Test/C64.rbf` md5 `a993d7b7`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2854-2862` has the alt_fire_r2
  block commented out. **DO NOT COMMIT TO MASTER in this state** —
  this build is for analysis only. Either revert Step 7b cleanly
  or implement a proper fix before any master merge.
- Memory entries:
  - `project_lda_al_sta_hazard_2026_05_23.md` (hazard #1)
  - `project_superram_bench_wedge_2026_05_23.md` (prior — now
    largely superseded by the alt_fire_r2 finding)
- Test artifacts in `tools/test_cart/out/` (gitignored):
  - `copyback_fixed_nopped*` (hazard #1 workaround proof)
  - `b20_border_probe*` (alt_fire_r2 confirmation)
  - `superram_alive_probe_nopped*` (alive proof)
  - `superram_bench_step7b_off*` (bench live counters)

## Suggested order of business next session

0. **Step 7b decision LOCKED IN: deferred to Build C.** Build B's
   SDRAM cycle is ~4 clk32 (cnt=3 reset + 1 propagation), but
   alt_fire_r2's CPU3 fire is only 3 clk32 after main CPU0 fire —
   fundamentally too early. Strict cnt=0 predicate at CPU2 never
   fires (cnt=1 from main slot 2 clk32 prior). Step 7b needs Build
   C's faster ~3-clk32 page-mode SDRAM to fit. Restore + retry
   once Build C revival lands (deferred per `project_milestone_a_
   buildC_bisect_2026_05_23`). Active codebase stays with
   alt_fire_r2 commented-out.
2. **Apply NOP convention** to `gen_stalong_probe.py`'s multi-op
   probes that previously "corrupted screen" — they almost certainly
   wedge for the same reason as hazard #1.
3. **Measure baseline-vs-alt_fire_r ratio**: capture
   `superram_bench` PASS/sec with current OFF build (alt_fire_r ON,
   alt_fire_r2 OFF) vs a build with **both** alt-fires off. If
   ratio ~1.0, alt_fire_r never actually fires (Step 5 may also
   be dead). If ratio >1.0, alt_fire_r is contributing.
4. **Move to Milestone B** per `docs/path_to_20mhz_plan.md` once
   Step 7b decision is locked in.

## Commits this session

- `2407264` test_cart: bisect pins LDA-al → STA hazard (1 NOP fixes)
- `8fbe7cf` test_cart: bank-$20 wedge is NOT the LDA-al hazard
- `44d9de9` docs: session_handoff — LDA-al → STA hazard pinpointed
- `ed8b72a` docs: handoff — bank-$20 wedge → alt_fire_r2-OFF RBF
- `c254063` fpga64_sid_iec: hard-gate alt_fire_r2 OFF (proves cause)

## Pointers

- `docs/path_to_20mhz_plan.md` — CANONICAL Milestones A/B/C.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2841-2862` — alt_fire_r2 block.
- `tools/test_cart/gen_b20_border.py` — minimal alt_fire_r2 probe.
- `tools/test_cart/superram_bench_step7b_off.png` — first bench
  with live data.

MiSTer IP `192.168.50.130`, root/1. RBF md5 `a993d7b7` at
`/media/fat/_Test/C64.rbf`. Don't touch `/media/fat/_Computer/`.
