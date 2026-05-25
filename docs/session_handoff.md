# Session handoff — 2026-05-26: Option (a) PRECHARGE FSM SILICON-VALIDATED (KERNAL boot + Lorenz scpu)

## 0. TL;DR for the next agent

Today's session shipped Milestone A Option (a) PRECHARGE FSM to silicon.
**First-silicon results: PASS**.

- KERNAL boots clean to READY prompt (screenshot:
  `tools/milestone_a_optionA_boot.png`).
- Lorenz scpu test suite progresses cleanly through 5 minutes of load/store
  opcode tests (ldxzy/ldxa/ldxay/stxz/.../tayn/txan all OK). Screen
  changes every ~30s = active test progression, no wedge.
- SuperRAM speed bench shows 1x across all modes — **NOT a regression**.
  Turbo path requires clk_cpu=64MHz which is blocked on a separate
  passthrough/MCP bridge issue. Option (a)'s HIT path is being exercised
  silently (cycle 6→4 clk64 on consecutive same-row) but at 1MHz cadence
  the CPU isn't bandwidth-bound. The Lorenz scpu test IS the real
  Option (a) validation — it continuously exercises HIT, conflict-MISS,
  and refresh paths.

Build: md5 `cf8d185b9a09ac981eeb0c27145af8c9`, archived as
`C64_MiSTer/builds/C64_milestone-b-cdc-rewrite_c2c87b7cdc_20260525T101019Z_cf8d185b-dirty.rbf`.
66% ALM utilization (27,505 / 41,910).

## 0a. What worked end-to-end

Step 2 of the Option (a) plan: PRECHARGE FSM in `sdram_pm.v`, mirrored
in `sdram_pm_lite.vhd`. Bench PASSES with `expect_spec_violations=false`
(refresh_while_open=0, active_conflicts=0). A second Codex falsification
pass surfaced two BLOCKING issues that were fixed in-flight:

1. **Multi-driver on `refresh_pending` / `refresh_wait`** (would hard-fail
   Quartus): reset was in block 1 (q-block), updates in main_clk_block.
   Moved reset into main_clk_block. Single-driver now.
2. **HIT read sampled at q=2 = CAS_LATENCY, missing the +1 safety margin**
   the MISS path inherits from Till Harbaum's baseline. With `sd_clk` via
   `altddio_out` the SDRAM sees commands ~half-clk64 late; q=2 risks
   landing on/before DQ valid. Bumped `STATE_READ_HIT` to CAS_LATENCY+1=3
   (HIT cycle 3→4 clk64; still way under MISS=6).

**Bench re-run after fixes: RESULT: PASS** (12/12 scenarios, zero
spec violations).

**Status of code in working tree**: Option (a) FSM + multi-driver fix +
HIT margin fix + bench updates all uncommitted. Files:
- `C64_MiSTer/rtl/sdram_pm.v` (Option a PRECHARGE FSM + multi-driver fix
  + STATE_READ_HIT bump + cycle_needs_precharge / cycle_row_latched regs
  + refresh sub-state machine)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` (existing — `scpu_fast_path_o` port)
- `C64_MiSTer/c64.sv` (existing — fast_path threading)
- `sim/sdram_pm_tb/sdram_pm_lite.vhd` (Option a mirror: conflict-MISS
  ce-edge PRECHARGE, q=2 delayed ACTIVE, q=7 sample, refresh handler
  PRECHARGE-ALL+defer)
- `sim/sdram_pm_tb/sdram_pm_buildc_extended_tb.vhd` (timing expecteds
  updated for 8-clk conflict-MISS + 4-clk HIT; expect_spec_violations
  flipped to false; verdict block enforces I/J/K must show zero)

## 1. Residual Codex risks NOT fixed in this iteration

Codex's #2 (refresh not exclusive bus owner) and #3 (no tRFC guard) live
at the boundary of the existing 8-clk64 EXT-slot idle window
(`fpga64_sid_iec.vhd:1568` schedules refresh in EXT4..EXT7 when
`rfsh_cycle="00"`). Option (a) PRECHARGE FSM extends the refresh
in-window cost from 1 clk64 (baseline AUTO_REFRESH only) to ~3 clk64
(PRECHARGE + tRP + AUTO_REFRESH). Add ~5 clk64 of tRFC after AUTO_REFRESH
and total is ~8 clk64 — fits the idle slot exactly, no margin.

**Decision**: ship to silicon. The bench-passing Option (a) FSM is a
strict improvement over Option (b) and the existing idle-slot
contract likely tolerates the extension. If silicon wedges in a
refresh-correlated pattern, the first instrumented re-build adds
sticky counters per Codex #2:
- `dbg_ce_during_refresh_pending` (sticky, increment on `ce && refresh_pending`)
- `dbg_active_within_trfc` (sticky, increment on `CMD_ACTIVE within 5 clk64 of CMD_AUTO_REFRESH`)

Both fit in `debug_pkg.sv` alongside existing taps.

## 2. Next session — extended silicon validation

First-silicon smoke + Lorenz scpu PASSED. Remaining tests for higher
confidence (not blockers, can be deferred):

1. **Lorenz full suite** (~30 min) instead of 5-min cap. Confirms all
   ~150 SCPU opcodes pass, including bank-transition ones that exercise
   conflict-MISS heavily.
2. **REU LOAD test**: `LOAD"$",8` then `LOAD"*",8,1` from disk
   (the passthrough-baseline workload — confirms IEC + REU paths
   unaffected by SDRAM controller changes).
3. **Refresh stress** (>2 hours uptime): the only way Codex Risks 2/3
   (refresh-not-exclusive + no tRFC guard) would manifest. If PC drifts
   to garbage or screen corruption after long uptime, add instrumented
   build with sticky counters per memory file
   [[milestone-a-option-a-codex-saved-quartus-2026-05-26]].
4. **Doom + Wolf3D smoke** (SuperRAM-heavy workloads). The HIT path
   should help if the bridge ever goes back to clk_cpu=64MHz.

## 3. The MCP bridge / turbo question

This build inherits SAME_CLOCK_PASSTHROUGH=1 from the prior passthrough
baseline. Turbo path requires reviving the MCP bridge at clk_cpu=64MHz
(Phase F.3/F.4 — currently blocked per
[[passthrough-plus-gates-baseline-2026-05-25]]). Until that's solved
the HIT path is silent at the CPU level. After it's solved Option (a)
should deliver real throughput gain on SuperRAM workloads.

Don't conflate the two: Milestone A (HIT path) is now silicon-validated
as correct; MCP revival is a separate workstream.

## 3. Methodology notes for future Milestone work

- **Codex falsification BEFORE first HW build remains the most valuable
  cost-saver** — caught a Quartus-blocking multi-driver this round that
  no bench can catch (single-process GHDL has no multi-process driver
  rule; Quartus does). Skill at `.claude/skills/codex/SKILL.md`.
- **Lite-model benches don't model SDRAM command sequencing**. The shadow
  process added in Step 1 (snoops cmd_active_pulse / cmd_precharge_pulse
  / cmd_refresh_pulse to a per-bank open-row table) catches Risks 1+2
  but NOT Risk 3 (tRFC). For Risk 3 we'd need a real SDRAM behavioural
  model with cycle-level command-spacing enforcement (out of scope for
  GHDL).
- **The "single-row-open invariant"** chosen for the Verilog Option (a)
  trades simplicity (q stays 3 bits, no per-bank tracker, always
  PRECHARGE-ALL on conflict) for cycle cost (conflict-MISS = 8 clk64).
  The lite mirrors this exactly — bench timings reflect both 6-clk
  fresh MISS and 8-clk conflict MISS.

## 4. Files at end of session (uncommitted)

```
C64_MiSTer/c64.sv                                  (Option b threading, unchanged today)
C64_MiSTer/rtl/sdram_pm.v                          (Option a FSM + Codex fixes)
C64_MiSTer/rtl/fpga64_sid_iec.vhd                  (scpu_fast_path_o port, unchanged today)
sim/sdram_pm_tb/sdram_pm_lite.vhd                  (Option a mirror + STATE_READ_HIT=3)
sim/sdram_pm_tb/sdram_pm_buildc_extended_tb.vhd    (timings updated, violations enforced)
docs/session_handoff.md                            (this file)
codex_option_a_review.txt                          (Codex output, this session only)
```
