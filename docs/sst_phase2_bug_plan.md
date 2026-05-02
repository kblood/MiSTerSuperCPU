# SST Phase 2 — Bug Catalog and Fix Plan

Branch: `vanilla-cpu-swap`. Source of truth: SingleStepTests/65816 v1
real-hardware traces, run through `sim/p65c816_singlesteptest/p65c816_sst_tb.vhd`
via GHDL.

Phase 0 (single opcode) and Phase 1 (28 RMW opcodes) are landed in `fd477c9`.
Phase 2 is the full 256-opcode × 2-mode sweep. While the sweep was at ~60%
complete (309/512 logs), `triage.py` already revealed the families below;
the catalog will be re-validated against the final results before commit.

## Findings (full Phase 2 sweep, all 512 logs)

**Grand totals**: 4 589 284 pass / 186 583 fail / 304 129 skip / 5 080 000
total → **90.34 % pass on first sweep.**

| Family | Opcodes | Fails | Suspect |
|---|---|---|---|
| **F1 — dp,S / (dp,S),Y carry** | $03 $13 $23 $33 $43 $53 $63 $73 $83 $93 $a3 $b3 $c3 $d3 $e3 $f3 (16 ops, e mode mostly) | ~80 K | RTL — pinpointed |
| **F2 — JMP (abs,X) cycle-4 VDA** | $7C e+n | 20 K | RTL probe semantics |
| **F3 — RTI PC++** | $40 e+n | 20 K | RTL or bench |
| **F4 — WDM cycle-1 VPA** | $42 e+n | 20 K | RTL probe semantics |
| **F5 — X-flag 0→1 high-byte clear** | $28 (PLP), $e2.n (SEP) | ~5 K | RTL — same shared bug |
| **F6 — PLD** | $2B | 181 | RTL |
| **F7 — RTL** | $6B | 219 | RTL |
| **F8 — PLY** | $7A | small | TBD |
| **F9 — WAI / STP halt-cycle RWB** | $cb $db both modes | 40 K | bench (suspected) — RWB compared on null cycles |
| **F10 — JSR (abs,X) prelude collision** | $fc both modes | 20 K (all *skip*) | bench — skip predicate too eager |
| **F11 — RTS scattered fail subset** | $60 (92), various small | <500 total | RTL — page-cross / specific patterns |
| **F12 — single-case strays** | many ops 1-100 fails each | <500 total | mix |

Grand failure-kind distribution:
`P 49 K · CY_VDA 30 K · CY_VPA 20 K · A 17 K · RAM 10 K · CY_addr 4.6 K · D 81 · DBR 8`.

> **About the post-Phase-1 surface area.** Phase 1 only exercised RMW
> opcodes with `LOAD_T="10"` modify cycles, so it never read addresses
> through dp,S, never crossed page-1 in the AddrGen, never pulled
> registers, and never executed RTI/RTL/JMP-(abs,X)/WDM. Every family
> here is a previously-untested code path.

## F1 — dp,S addressing carry (highest impact)

### Smoking gun

03.e (ORA dp,S) case 15: `CY[3] addr exp=000205 got=000105`. Exact diff
$0100 — RTL wraps the address inside page 1 instead of carrying out of
the low byte. The AAH stays at `$01` (initial DH from S=01FF) when the
real chip increments to `$02`.

### Mechanism

`AddrGen.vhd:202-207` has

```vhdl
DL <= NewDL(7 downto 0);
if e6502 = '1' and ABSCtrl = "11" then
    SavedCarry <= '0';                  -- defeat carry into DH
else
    SavedCarry <= NewDL(8);
end if;
```

The intent (per the comment) was VICE-style "stack-relative wraps inside
page 1 in emu mode." SingleStepTests is generated from actual WDC silicon
traces and disagrees: the carry **does** propagate, address goes
`$00:(S + dp)` with full 16-bit add and **bank stays $00** (not $01).

Two things are wrong simultaneously in our RTL:

1. **Carry suppression** — should let `NewDL(8)` propagate via the
   `AAHCtrl="110"` cycle into DH.
2. **Bank** — for dp,S the effective bank is always `$00`, not the stack
   bank `$01`. Our got=$00:0105 happens to land on bank 0 only because
   the AddrGen path uses `unsigned("0"&DH)` for the high byte and DH was
   already $01 from a prior cycle. The bank field (top 8 of the 24-bit
   bus) is set elsewhere; smoking-gun shows bank already correct ($00),
   so this side is OK — the fix is purely the carry path.

### Proposed fix

Drop the `e6502 = '1' and ABSCtrl = "11"` special case in
`AddrGen.vhd:203` so SavedCarry always = `NewDL(8)`. Verify against the
regression that originally motivated the suppression (commit log says
"2026-04-21 Emulation-mode stack-relative wrap"). If a single workload
broke without it, prefer fixing the SST-aligned way and re-validating
the original failure.

Risk: medium. Need to reproduce the original failure (probably a Lorenz
or Asterix test) on the freshly-fixed CPU before declaring done.

### Expected impact

Wipes F1 entirely (~50 K cases / 8 opcodes RAM/A/P/CY_addr fails).

## F2 — JMP (abs,X) cycle-4 VDA

### Smoking gun

7c.e all 10 000 cases fail with `CY[4] VDA exp=1 got=0`. JMP (abs,X) is a
6-cycle instruction (op, lo, hi, internal, ind-lo, ind-hi). Cycle 4 is
the indirect read of the low byte of the destination — by spec a real
data read with VDA=1.

### Mechanism (suspected)

P65C816's microcode for JMP (abs,X) drives VDA=0 on the read at cycle 4.
Sister opcode JMP (abs) ($6C) needs to be checked too — if same MCode
row, fix lifts both.

### Proposed fix

Inspect `MCode.vhd` rows for $7C (and $6C). Set OUT_BUS / VDA gate so
the indirect-read cycle reports VDA=1 like a normal data read.

Risk: low.

### Expected impact

20 K cases ($7C both modes). Possibly extends to $6C if MCode is shared.

## F3 — RTI PC++

### Smoking gun

40.e all 10 000 fail `PBR:PC exp=1A:ED07 got=1A:ED08`. Got is exactly
exp+1.

### Mechanism (two hypotheses)

**A. Bench timing.** Phase 2 smoke test moved `cap_pc` to one clock
*after* the SST cycle loop — that fixed off-by-one for ops where the
last SST cycle is followed by an internal cycle before the next
opcode-fetch. RTI's last cycle is the PCH pull; the very next clock is
the first byte of the next instruction's opcode fetch, which has
already advanced PC.

**B. RTL.** P65C816's RTI microcode does an extra ADDR_INC after the
PCH pull, treating PC like a return-address fetch.

### Proposed fix

Capture cycle-by-cycle from the simulator: dump the PC bus across all
RTI cycles for a single case and compare against the SST cycle list.
If PC takes the right value at the end of cycle N (last SST cycle) and
only goes wrong at cycle N+1 → bench bug. Else → RTL bug.

If bench: the post-loop capture rule needs a per-opcode "is-flow-
control" predicate so cap_pc reads dbg_pc *during* the last SST cycle
rather than one clock after.

If RTL: clear ADDR_INC on the final RTI microcode row.

Risk: low for diagnosis, low for either fix.

### Expected impact

20 K cases ($40 both modes). Same diagnosis applies to RTS ($60 — 1
fail in smoke), RTL ($6B — 220 fails), BRK ($00), COP ($02) and any
other op with no trailing internal cycle.

## F4 — WDM cycle-1 VPA

### Smoking gun

42.e/n all 10 000 fail `CY[1] VPA exp=0 got=1`. WDM is a 2-byte reserved
no-op. The second byte fetch should be tagged VPA=0 (per the WDC
errata: WDM's signature byte is not a program byte).

### Proposed fix

MCode row for $42 cycle 1: clear the VPA flag (or set OUT_BUS so VPA
gate evaluates 0).

Risk: trivial — WDM is reserved, no real-world software depends on it,
fix has zero functional effect.

### Expected impact

20 K cases. Pure reporting cleanup.

## F5 — X-flag 0→1 high-byte clear (PLP, SEP, also RTI)

### Smoking guns

- 28.n PLP case 10: `X16 exp=00B7 got=A0B7` — high byte $A0 retained.
- e2.n SEP case 3: `X16 exp=0020 got=8120` — high byte $81 retained.

Both opcodes drop the same bug: when the loaded/forced P has X=1 but
the previous X was 0, the high bytes of X **and** Y must be zeroed.

### Mechanism

P65C816's high-byte zeroing for X-flag flips is presumably gated on
**explicit** P writes (REP/SEP via the P load path) but PLP and SEP
arrive via different paths in the microcode that bypass the clear.

### Proposed fix

Locate the X-flag-edge detector (or the P-write commit path) and route
PLP/SEP/RTI/RTL through the same high-byte clear logic. A single
combinational signal `clear_xy_hi <= newP(4) and not P(4);` that all
four opcodes assert at P-update is the cleanest shape.

Risk: low; the SEP path likely already has the right wiring,
just needs to be shared.

### Expected impact

2495 cases ($28.n) + 2564 cases ($e2.n) = ~5 K. Will also fix any RTI
case ($40.n) where the cause is X-flag transition rather than just PC.

## F9 — WAI / STP halted-cycle RWB

### Smoking gun

cb.e (WAI) case 0: `CY[3] RWB exp=0 got_we=1`. SST's null cycles have
addr=null in JSON; converter writes `FFFFFF XX 0 ........` and the
bench skips addr/data when valid=0. But it still compares the cycle
flags including RWB.

### Mechanism

When CPU is halted, RWB is meaningless on real silicon — SST records
RWB=0 (read default) in those cycle slots regardless of what the
silicon drives. Our RTL drives WE=1 (write asserted) on the entry
cycle, then ought to settle. Bench compares anyway → universal fail.

### Proposed fix

Bench-side: when `valid=0` (null cycle), skip RWB / VDA / VPA / VPB /
MLB comparisons too — only compare the bus-level flags on real bus
cycles.

Risk: trivial.

### Expected impact

~40 K cases ($cb + $db both modes). Pure cosmetic — no real-world
software depends on WAI/STP cycle-flag semantics.

## F10 — JSR (abs,X) prelude collision

### Smoking gun

fc.e and fc.n: 0 pass / 0 fail / **10 000 skip** each. Prelude's
case_skipped predicate fires for every case.

### Mechanism

JSR (abs,X) reads its indirect pointer from `$00:(operand + X)` after
pushing the return address to stack. SST cases place the indirect
pointer somewhere benign, but the prelude's PHA scratch byte at
`$01:(S_low)` apparently overlaps with what the bench checks. More
likely: the converter is emitting a prelude byte at an address that
happens to be the JSR (abs,X) target, and the skip predicate triggers.

Worth verifying: the converter unconditionally adds 35-byte prelude;
case .ram entries in init that overlap the prelude region cause skip.
JSR (abs,X) likely places its operand high byte exactly there for many
cases.

### Proposed fix

Investigate: dump one fc.e case's prelude span vs case.ram. If the
overlap is benign (prelude byte and case byte happen to match), tighten
the skip predicate to skip only on **content mismatch**, not
unconditional overlap.

Risk: low; the predicate is local to the bench.

### Expected impact

20 K cases (will move from skip to pass column once predicate is
tighter; some may turn into real fails that need separate triage).

## F6, F7, F8, F11, F12 — small / individual

These are smaller in count; characterize during a single follow-up
commit after the big families are gone.

- **F6 PLD ($2B)** — 181 fails: D=81, P=100. PLD pulls D from stack;
  small subset of cases differ. Likely flag-derivation issue
  (D≠0 → Z=0 / D[15] → N).
- **F7 RTL ($6B)** — 219 fails: PBR mismatch on subset. Probably PBR
  pulled from wrong stack offset, or RTL in emu mode.
- **F8 PLY ($7A.e 36, $7A.n 1)** — small subset: pulled byte wrong.
  Could be prelude scratch-byte collision the bench's `case_skipped`
  predicate doesn't cover.
- **F11 RTS scattered ($60.e 92)** — most cases pass; failures are
  scattered. Not the simple +1 PC bug from RTI; cases like
  `exp=A950 got=4050` differ in PCH by tens of bytes — pulled wrong
  bytes from stack in some specific patterns.
- **F12 single-case strays** — many opcodes show 1-100 fails each
  ($57, $65, $77, $87, $91, $93.n, $97, $a4, $b2, $b7, $c1, $c6, $d2,
  $d5, $d6, $e5, $f2, $f6, $f7, etc.). Mostly P-flag or RAM mismatches
  on edge-case data. Investigate after big families to see if any
  share a common root cause.

## Fix order (impact-weighted)

| Step | Family | Effort | Wipes |
|---|---|---|---|
| 1 | F1 dp,S carry | 1 line revert + HW regression | ~80 K |
| 2 | F9 bench RWB on null cycles | bench 1 line | ~40 K |
| 3 | F3 RTI PC | diag first; either side small | ~20 K |
| 4 | F2 JMP (abs,X) VDA | MCode row tweak | 20 K |
| 5 | F4 WDM VPA | MCode row tweak | 20 K (cosmetic) |
| 6 | F10 JSR (abs,X) skip predicate | bench predicate | 20 K skip→pass |
| 7 | F5 X-flag clear (PLP+SEP+RTI) | RegFile branch share | ~5 K |
| 8 | F6/F7/F8/F11/F12 | per-op investigation | <1 K |

## Iteration loop

Each family follows the same loop. Single-opcode loops are fast (~25 s
for 10 000 cases via `run_sst.ps1 <op> <mode>`); a focused regression
across the family stays well under 10 minutes.

```text
┌──────────────────────────────────────────────────────────────┐
│  1. Pick next family from the order table                    │
│  2. Read SST text cases that fail; pick the simplest         │
│     (smallest cycle count, no mid-page-cross)                │
│  3. Confirm hypothesis with a single-case GHDL run, dumping  │
│     bus/internal signals across each cycle                   │
│  4. Implement minimal RTL or bench fix                       │
│  5. Re-run the family's opcodes both modes                   │
│       — every previously-failing op now 10 000 / 10 000      │
│       — every previously-passing op unchanged                │
│  6. Run the F1..F_current cumulative regression (all already-│
│     fixed opcodes both modes) — no green→red flips           │
│  7. Commit "P65C816: SST F<n> <name> fix"                    │
│  8. Loop                                                     │
└──────────────────────────────────────────────────────────────┘
```

Exit when all 256 × 2 opcodes are at fail=0 *or* every remaining family
has been characterized and explicitly deferred (with rationale: e.g.
known-controversial spec divergence, real-HW errata we don't model, or
out-of-scope for the current branch goal).

## Cumulative regression workflow

After each fix lands, re-run the **full Phase 2 sweep** in the
background (~3 h) — not blocking the next family's diag work.
`triage.py` on the resulting log set is the canonical scoreboard. Each
commit message records the before/after pass counts and the families
involved. The final "Phase 2 done" commit cites the full 256-opcode
sweep summary.

## Hardware-side regression gate

Phase 2 RTL changes that affect real silicon (F1 carry, F5 PLP) must
also pass the existing hardware regression set on `vanilla-cpu-swap`
before Phase 2 closes:

- **Cold boot** to BASIC READY both T65 and SCPU (`tools/v272_regress.py`)
- **decomp_stress.prg** screen-RAM identity T65 = SCPU
- **Asterix / scputest / synthmark64 / autorun_test / DragonsLair**
  (`tools/v272_sweep2.py`)

Cosmetic-only fixes (F4 WDM VPA) don't need this — verify with sweep
only and call out the limited scope in the commit message.

## Status

- **Phase 2 first sweep complete** — 4 589 284 / 5 080 000 pass (90.34 %).
- Doc updated with final triage and fix order.
- **Next**: enter Step 1 of the loop with F1 (dp,S carry). Suspect line:
  `AddrGen.vhd:202-207` — drop the `e6502 = '1' and ABSCtrl = "11"`
  carry suppression; HW-regress on T65=SCPU `decomp_stress.prg` + DL +
  Asterix to confirm the original 2026-04-21 motivating regression
  doesn't reappear.
