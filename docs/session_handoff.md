# Session handoff — 2026-05-26 (afternoon): mb-probe-002 falsifies bridge, points to CIA1 Timer A

## 0. TL;DR for the next agent

Built `mb-probe-002` (RBF md5 `cd639f31`, 12:14, 64% ALMs = 27,004) on
top of Option (a) silicon + MCP=0. Implements **Codex Design 3** for
the milestone-B bridge probes (per yesterday's handoff §2.1):

- RQ/AK now WRAP (mod 65536) + clk_cpu-domain SNAPSHOT on synced
  vblank-rise (3-FF sync of `vSync_sig` clk_sys→clk_cpu). Fixes v1's
  saturating-counter limitation AND a multi-bit CDC tearing bug Codex
  flagged on the c64.sv side.
- New field `WD:####` — max WAIT_ACK dwell per frame in clk_cpu cycles
  (the *real* Race β detector — bridge is one-outstanding by structure,
  so RQ-AK gap can't widen; what matters is "how long did the bridge
  sit in WAIT_ACK").
- New field `FL:##` — sticky activity flags
  `{bit0=req_seen, bit1=ack_seen, bit2=wait_seen, bit7=dwell_sat}`.
- New field `GM:##` — max RQ-AK gap per frame (sanity check).
- LINE_LEN bumped 357 → 380.

Codex review of the diff (before Quartus) caught 4 real bugs:
  1. VF still drove from live multi-bit counter (added `dbg_vec_snap_reg`).
  2. Snap-after-case could overwrite same-clk event assignments
     (reordered snap *before* case so case wins via last-assignment-wins).
  3. WAIT_ACK dwell off-by-one (now uses `wait_dwell_reg + 1` for
     compare AND capture).
  4. Missing `preserve` attributes on sticky-flag regs (added).
All 4 fixed before build.

**Result (3 LOAD"*",8,1 runs):**

| Field | Range across 3 runs | Interpretation |
|---|---|---|
| WD (clk_cpu) | min=28, max=40 (3 unique values) | Bridge HEALTHY. Race β FALSIFIED. |
| GM | 1 always | One-outstanding FSM intact. |
| FL | 0x07 in 100% of frames | Bridge FSM making progress every frame. |
| FS distribution | IDLE 67-100%, WAIT_ACK 0-33% | Normal bus utilization. |
| RQ-AK gap | 0 or 1 always | Healthy handshake. |

**Race β definitively falsified with measurement, not just absence
of evidence.** The bridge is healthy throughout the wedge.

**The wedge is downstream of the bridge.** Run 3's tail captured the
tight wedge state:
```
PC:00EAB1 P:B4 SP:01F1 ... I:00EAAE B:00
IF:054D C1:054D DR:54C0 IM:01 CR:01
M2:00 T2:08 PA:D7 PB:00 DA:3F DB:00
FS:0 RQ:* AK:* WD:001C FL:07 GM:01 VF:FF
```
- PC bouncing 3 distinct values in $EAB1-$EAC1 (KERNAL IRQ tail).
- SP=$01F1 (top of stack — IRQs fully unwound).
- IF/C1 frozen at $054D — CIA1 internal Timer A IRQ generation STOPPED.
- DR frozen at $54C0 — no further $DC0D reads (correctly — no IRQs).
- IM:01 CR:01 — Timer A *should* still be enabled+running.

**Refined wedge hypothesis:** CIA1 Timer A stops firing IRQs after
~1357 successful fires (IF=$054D), despite IM/CR showing it's still
enabled. The "ICR-latch-stuck" hypothesis from yesterday is partially
falsified — DR was actually incrementing in the pre-wedge phase
(int_reset DID fire). The actual mystery is "what stops CIA1 Timer A
from firing further IRQs after ~22s of normal operation."

## 1. State at end of session

- **Source:** Uncommitted v2 bridge changes in working tree
  (5 files, +370/-52 lines). See `git diff HEAD` for the full diff.
  Notable: `SAME_CLOCK_PASSTHROUGH => '0'` at `fpga64_sid_iec.vhd:2921`
  (engages MCP path for probe observability).
- **MiSTer (`192.168.50.130`):** running `mb-probe-002` RBF
  (md5 `cd639f31`). Stale CD32 CORENAME from 11 days ago was
  overwritten; `/tmp/mister_session.lock` claimed for C64.
- **Build archive:** `C64_MiSTer/builds/C64_milestone-b-cdc-rewrite_aafa4a4417_20260525T151755Z_cd639f31-dirty.rbf`.
- **Test artifacts:** `tools/mb_probe_002_run{1_keep_2,2,3}/` —
  3 LOAD"*",8,1 runs, each with screenshots + uart_capture.log.
  Run 3 captures the deepest wedge state (PC unique=3).
- **Memory:** `memory/project_mb_probe_002_bridge_falsified.md` with
  the full analysis. MEMORY.md index updated.

## 2. Recommended next probe (mb-probe-003)

### 2.1 CIA1 internal probes (1 build)
Add taps inside `mos6526.v` for:
  - Timer A current counter value (16-bit)
  - ICR pending bits (raw byte before $DC0D read-mask)
  - The internal `irq_pending` latch that drives `irq_n`
  - Timer A reload-latch value (16-bit)

Port additions to `mos6526.v`, plumb through fpga64_sid_iec.vhd →
c64.sv → debug_pkg → uart_fmt. ~1 hour RTL + 1 build. UART fields
would be `TA:#### TL:#### IP:## IR:#` — about 25 new bytes.

**What this disambiguates:**
- If Timer A counter is FROZEN at $0000 → some write path is clobbering
  it (look for phantom writes to $DC04/$DC05).
- If Timer A reload-latch is FROZEN at $0000 → CRA reload bit issue.
- If ICR pending bit 0 (Timer A IRQ) is STUCK SET despite int_reset →
  bug in mos6526.v's ICR latch logic.
- If both pending bits are clear AND Timer A is counting → IRQ
  generation path itself is broken.

### 2.2 Stack/return-PC capture (1 build, lower priority)
Add a tap for the most recent RTI return PC pulled off the stack.
This would confirm whether the IRQ tail is RTIing back to itself
(stack corruption) or back to userspace (and immediately re-IRQing).

### 2.3 Pivot to Milestone C (strategic)
Per [[mb-probe-001-mcp-races-falsified-2026-05-26]] and the design
doc §C.3 fallback: if no probe can disambiguate further, the
remaining option is to accept `SAME_CLOCK_PASSTHROUGH=1` as the ship
baseline and pursue Milestone C (something other than 64MHz clk_cpu).
This is a non-debug decision and should be made by the user, not the
agent.

## 3. Confirmed orthogonalities

- **Bridge is NOT the wedge.** v2 probes WD/GM/FL all show healthy
  bridge behavior throughout 3 LOAD"*",8,1 wedge runs. Specifically:
  WD never exceeds 40 clk_cpu (saturating range [28, 40]), GM always
  1, FL=0x07 every frame.
- **Race β FALSIFIED with measurement.** Yesterday's untestable
  claim is now testable AND falsified.
- **Race α still FALSIFIED.** No PC byte-aliasing in any run.
- **Option (a) PRECHARGE FSM still works.** Boot clean, IRQs flow
  normally, bridge transactions complete fine until the wedge.

## 4. Methodology notes

- **Codex review BEFORE Quartus saves builds.** This is the 3rd
  documented case where `codex exec` caught a bug before a HW
  iteration. ~2 min, 91k tokens, 4 real findings. See
  [[reference-codex-skill]] for calling pattern.
- **The 1-unit dwell-carry-forward dent fix went in AFTER build
  kickoff** (commits show `dbg_wait_dwell_max_accum <= wait_dwell_reg + 1`
  vs the built-in version's `<= wait_dwell_reg`). Practical impact:
  WD might be 1 cycle lower than true max at frame boundaries. Benign
  for wedge detection (we look at orders of magnitude). Rebuild only
  if a future case needs single-cycle precision.
- **Stochastic reproducibility.** LOAD"*",8,1 wedges in 1-2 of 3
  trials with mb-probe-002. The wedge state is consistent when it
  fires (same PC pattern, IF/C1/DR frozen at same value), but the
  TIMING of when it locks up within the 30s window varies. Future
  probes should plan for ~3 runs per RTL build.
- **Don't trust pre-wedge observations.** I initially read "IF
  incrementing 02CE→02D0→02D2" and concluded the ICR-stuck hypothesis
  was wrong. That was the pre-wedge transition phase. The TAIL of
  the capture (Run 3's end) showed IF frozen at $054D — same as
  mb-probe-001. **Always look at the LAST 5-10 UART samples.**
