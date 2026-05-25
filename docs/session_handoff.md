# Session handoff — 2026-05-26 (evening): mb-probe-003 confirms irq_n-stuck mechanism

## 0. TL;DR

Built `mb-probe-003` (RBF md5 `ef01bea6`, 12:14, 0 errors). Added 3
CIA1 internal taps to mos6526.v: `TA:####` (timer_a), `TL:####`
({ta_hi,ta_lo}), `IC:##` (raw 5-bit icr). LINE_LEN 380→402.

3 LOAD"*",8,1 runs, **1/3 wedged**. Adding probes shifted Quartus P&R
enough to reduce reproducibility from 100% (v2) to ~33% (v3) —
Heisenberg effect, expected risk. The one wedged run captured
**definitive evidence for Codex hypothesis #1**:

| Field | Run 2 SECOND_HALF | Interpretation |
|---|---|---|
| TA (Timer A counter) | 391 unique values $001A..$4016 | **Timer A IS counting** |
| TL (reload latch) | $4025 (1 unique value) | reload latch intact |
| **IC bit 0** | **set in 432/438 frames** | **Timer A pending STUCK SET** |
| IF/C1 | $06A1 → $06AE (only 13 incs) | irq_n falling edges frozen |
| PC | 66 unique, last $EAC6 | KERNAL IRQ tail spin |
| Bridge | WD 28-40, FL=0x07 | still healthy |

**Mechanism (Codex hypothesis #1, confirmed):**
1. Timer A keeps overflowing every ~16ms (TA varies wildly).
2. Each overflow sets `icr[0]` to 1 (mos6526.v line 248).
3. CPU stops reading $DC0D (DR frozen in legacy probe).
4. Without $DC0D read, `int_reset` never fires (line 550).
5. `icr[0]` stays high.
6. mos6526.v line 554: `irq_n <= irq_n ? ~|(imr & icr_adj) : irq_n`.
   Once `irq_n` goes LOW, it can only go HIGH via int_reset. So
   irq_n is stuck low forever.
7. IF/C1 (falling-edge counters) freeze because there are no new
   falling edges to count.

**The CIA is functioning correctly.** Yesterday's interpretation of
"Timer A stops firing" was wrong — Timer A keeps firing; what stops
is `irq_n` toggling, because the IRQ acknowledgement path (CPU read
of $DC0D) breaks first.

## 1. State at end of session

- **Source:** committed at `b6a0207` (mb-probe-003 RTL + test +
  Codex insight). Working tree includes a regex fix in
  `tools/mb_probe_003_test.py` (the `IF:\s+C1:` constraint was too
  strict for the real UART line layout; changed to `IF:.*?C1:`).
  Still uncommitted — pair it with this handoff commit.
- **MiSTer (`192.168.50.130`):** running mb-probe-003 RBF
  (md5 `ef01bea6`). Lockfile claimed for C64.
- **Build archive:** `C64_MiSTer/builds/C64_milestone-b-cdc-rewrite_b6a02076e9_20260525T163655Z_ef01bea6-dirty.rbf`.
- **Test artifacts:** `tools/mb_probe_003_run{1,2,3}/`. Run 2 is the
  wedge capture; runs 1 and 3 are no-wedge controls.
- **Memory:** `project_mb_probe_003_irq_n_stuck_confirmed.md` +
  `irq_n_stuck_low_hypothesis.md` (Codex's prediction, now
  retrospectively the "before-confirmation" record).

## 2. Recommended next probe (mb-probe-004)

The remaining unknown: **why does the CPU stop reading $DC0D?**

The PC pattern ($EAB1..$EAC6) matches the KERNAL IRQ-handler tail.
Real C64 KERNAL has a `CMP $D012 / BNE` raster-wait loop at the end
of the IRQ handler that waits for a specific raster line before
RTI'ing. If $D012 returns wrong values to SCPU through the bus mux
during MCP, this loop never exits — CPU is stuck CMP-ing $D012
forever, never reaching the rest of the IRQ tail (which is where
$DC0D would be read).

### 2.1 Minimum useful taps for mb-probe-004:
- Last `cpuDi` value observed when `cpuAddr[15:0] == $D012`
  (8-bit) plus a 16-bit increment counter of $D012 reads.
- VIC's current `rasterY[8:0]` value (already in design somewhere,
  just needs to route to dbg_pool).

That's about 25-30 UART bytes. LINE_LEN 402→~432.

### 2.2 Risk note
mb-probe-003 reduced wedge reproducibility 100%→33%. mb-probe-004 may
reduce it further. If a build comes back with 0/3 runs wedging,
revert to mb-probe-003 and use the 1-in-3 captures as the truth set.

### 2.3 Alternative strategic pivots

- **Pivot to Milestone C**: accept `SAME_CLOCK_PASSTHROUGH=1` as
  ship-baseline. Clk_cpu stays at 32MHz instead of 64MHz; turbo
  speed regression but no LOAD wedge. User-level decision.
- **Read the actual KERNAL disassembly** for $EAB1+ to confirm
  the raster-wait-loop hypothesis BEFORE building. C64 KERNAL is
  public, well-documented; should be 15 min of grepping.

## 3. Confirmed orthogonalities (now an even longer list)

The wedge is NOT caused by:
- Bridge FSM, dwell, or handshake ([[mb-probe-002-bridge-falsified-2026-05-26]])
- Bridge transaction count (43k+ delivered during wedge)
- CIA1 Timer A counter (TA varies 391 unique values in wedge)
- CIA1 Timer A reload latch (TL stable $4025 in wedge)
- CIA1 ICR latch hardware (toggles correctly when CPU reads $DC0D)
- CIA1 IRQ mask (IM:01 stable)
- CIA2 IEC port phantom-writes (Option G falsified that earlier)

## 4. Methodology notes

- **Codex hypothesis-rank → tap design → diff review → build** is
  proving valuable. This round: Codex review caught nothing
  blocking (clean diff), Codex brainstorm correctly predicted the
  mechanism, classifier auto-confirmed on first wedged run.
- **Stochastic reproduction is fine** when you have a good
  classifier — 1 wedge in 3 with a classifier that auto-identifies
  the mechanism is better than 3 wedges with no classifier.
- **Parse regex needed `.*?` not `\s+` between PC/IF/C1/IM/CR**
  because real UART line interleaves many other fields. Run 1
  initially parsed 0 samples; fix applied + committed alongside.
- **Don't trust pre-wedge halves.** Both runs 1 and 3 looked
  "Timer A overflow not registering" in the classifier — that's
  the *healthy* state when the CPU is actively reading $DC0D and
  acking IRQs. Only the wedged half shows the smoking gun. Future
  classifiers should weight on PC location + IF freeze before
  declaring anything.
