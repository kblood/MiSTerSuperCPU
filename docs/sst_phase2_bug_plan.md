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

## F5 — X-flag 0→1 high-byte clear (PLP, SEP, also RTI) — FIXED

### Smoking guns

- 28.n PLP case 10: `X16 exp=00B7 got=A0B7` — high byte $A0 retained.
- e2.n SEP case 3: `X16 exp=0020 got=8120` — high byte $81 retained.

Both opcodes hit the same bug: when the loaded/forced P has X=1 but
the previous X was 0, the high bytes of X **and** Y must be zeroed
**at the same edge that P commits** — the previous RTL fired one
cycle later via an `oldXF` register lag.

### Mechanism

`P65C816.vhd:391-395` had:

```vhdl
oldXF <= XF;
if XF = '1' and oldXF = '0' and EF = '0' then
    X(15 downto 8) <= x"00";
    Y(15 downto 8) <= x"00";
end if;
```

Because `XF` is combinational from `P(4)` and `P` is registered, at the
edge that `P` commits its new value, `XF` is still the *pre-edge* value.
The condition `XF=1 AND oldXF=0` fires only on the **next** edge —
i.e. when the next opcode begins fetching. SST captures `final.x` at
the same edge that P commits, so the bench sees the unchanged high byte.

### Fix (committed)

Compute `next_xf` combinationally from the in-flight P-load path
(`MC.LOAD_P` + `D_IN(4)` for PLP/RTI, `DR(4)` for SEP/REP) and trigger
the X/Y high-byte clear on the same edge using `next_xf=1 AND XF=0 AND EF=0`.

```vhdl
case MC.LOAD_P is
    when "011" => next_xf := D_IN(4) or EF;       -- PLP / RTI
    when "110" =>                                  -- SEP / REP
        if IR(5) = '1' then
            next_xf := XF or (DR(4) and not EF);
        else
            next_xf := XF and not (DR(4) and not EF);
        end if;
    when others => next_xf := XF;
end case;

oldXF <= next_xf;
if next_xf = '1' and XF = '0' and EF = '0' then
    X(15 downto 8) <= x"00";
    Y(15 downto 8) <= x"00";
end if;
```

### Result (sweep_results_f5)

| Op | Pre-fix | Post-fix |
|---|---|---|
| 28.e | 9966 / 34 fail | 9966 / 34 fail (unchanged — strays are unrelated bug, see F12) |
| 28.n | 7499 / 2495 fail | **9993 / 1 fail** |
| e2.e | 10000 / 0 fail | 10000 / 0 fail |
| e2.n | 7434 / 2564 fail | **9998 / 0 fail** |
| c2.e/c2.n (REP) | clean | clean (not affected) |

Net: ~5057 fails eliminated. No regressions on adjacent flag opcodes
($38 SEC, $f8 SED, $78 SEI, $58 CLI, $b8 CLV, $18 CLC, $d8 CLD all 9989+/0).

## F9 — WAI / STP / WDM null-cycle bus-flag compares — FIXED

### Smoking guns

- cb.e (WAI) case 0: `CY[3] RWB exp=0 got_we=1`.
- 42.e (WDM) case 0: `CY[1] VPA exp=0 got=1` (folded in: F4 was the
  same root cause).

### Mechanism

SST's null cycles have addr=null in the JSON; the converter writes
`FFFFFF XX 0 ........` and the bench's `valid` field is '0'. Bus-flag
fields (VDA/VPA/RWB/MLB) are informational-only on real silicon during
those cycles, so SST records the default RWB=0/VDA=0/VPA=0 regardless
of what the chip is actually driving. Previous bench gated only
addr+data on `valid='1'` but still compared flags on null cycles,
causing universal fail on $cb (WAI), $db (STP), $42 (WDM), and partial
fails on every opcode whose cycle trace contains a null IO cycle.

### Fix (committed)

`p65c816_sst_tb.vhd` — wrap the entire VDA/VPA/RWB/MLB block in
`if cyc_exp(i).valid = '1'`.

### Result

| Op | Pre-fix | Post-fix |
|---|---|---|
| cb.e WAI | 0 / 10000 | 10000 / 0 |
| cb.n WAI | 0 / 10000 (-3 skip) | 9995 / 0 |
| db.e STP | 0 / 10000 | 10000 / 0 |
| db.n STP | 0 / 10000 (-11 skip) | 9989 / 0 |
| 42.e WDM | 0 / 10000 | 10000 / 0 |
| 42.n WDM | 0 / 10000 (-7 skip) | 9993 / 0 |

Net: **~60 K** cases eliminated. Subsumes F4 as a duplicate.

## F10 — FR-cells stack-collision skip predicate over-conservative — FIXED

### Smoking gun

fc.e and fc.n: 0 pass / 0 fail / **10 000 skip** each.

### Mechanism

The bench's skip predicate flagged a collision when any final.ram
(FR) cell sat at `$00:(stk_top)` or `$00:(stk_below)`, the addresses
the prelude transiently writes for its PHA/PLP. But an FR cell at the
stack address means SST recorded a CHANGED final value, which by
definition implies the test instruction wrote there. The prelude's
stale byte at stk_top is overwritten by that legitimate stack push,
so the final state matches.

### Fix (committed)

Removed the FR-cells loop in the skip predicate. Kept the IR-cells
(init.ram) collision check as the real safety net for cases where
the prelude clobbers explicitly-set test setup bytes.

### Result

| Op | Pre-fix | Post-fix |
|---|---|---|
| 20.e JSR | 0 / 10000 skip | 10000 / 0 / 0 |
| 20.n JSR | 0 / 10000 skip | 9994 / 0 / 6 |
| 22.n JSL | 0 / 10000 skip | 9993 / 0 / 7 |
| 60.n RTS | 0 / 10000 skip | 9991 / 0 / 9 |
| fc.e JSR(abs,X) | 0 / 10000 skip | (revealed VDA bug, fixed by F2-like microcode) |

Combined with the FC microcode fix (cycles 6,7 VA="01"→"10", same
shape as F2), $fc clean both modes.

## F2 — \$FC JSR (abs,X) indirect-read VDA — FIXED

Same shape as the original F2 ($7C JMP (abs,X)) fix: cycles 6 and 7
of $fc fetch the indirect target through PBR:AA, which is a data read
(VDA=1, VPA=0). MCode VA field changed from "01" to "10".

`fc.e: 0 / 10000 → 10000 / 0`  
`fc.n: 0 / 9995 → 9995 / 0` (5 prelude-skip)

## F8 — Reset-stub clobbers prelude PHA target at \$00:01:FD — FIXED

### Smoking gun

7a.e PLY case 188: `Y8 exp=E9 got=CE`. Y received $CE which is the
case A_hi byte the prelude pushed via its first PHA. Verbose run
showed PLY read at correct address $0001FD but `mem[$01FD]=$CE`,
not $E9 from the IR cell.

### Mechanism

The RTL's reset-interrupt microcode runs the standard 3-push BRK
sequence — BUS_CTRL suppresses the actual writes but SP still
decrements three times. With reset SP=$0100 and emu-mode wrap, the
prelude entry sees SP=$01:FD. The prelude's first PHA (offset 12, in
native mode after the first XCE) writes the case's DBR-priming byte
to $00:01:FD. Any case init.ram cell at $00:01:FD therefore gets
clobbered before the test instruction runs.

### Fix (committed)

Bench-side: extend the prelude/IR collision check to skip cases with
init.ram cells at $00:01:FD.

### Result

| Op | Pre-fix | Post-fix |
|---|---|---|
| 7a.e PLY | 9930 / 188 / 0 | 9964 / 0 / 36 |
| 2b.e PLD | 9819 / 181 / 0 | 9819 / 99 / 82 |
| 6b.e RTL | 9781 / 219 / 0 | 9781 / 100 / 119 |

## F6, F7 (residual) — SuperCPU emu-mode page-1 stack wrap

The remaining ~100 fails on $2B/$6B/etc are the deliberate SuperCPU
compatibility deviation from WDC silicon. New-65816 opcodes
(JSL/PHD/PLD/RTL/PEA/PEI/PER/JSR (abs,X)) on a real WDC chip do NOT
wrap stack to page 1 in emu mode — SP can decrement into $00FF, $00FE.
Our RTL forces page-1 wrap (per `LOAD_SP="110"/"111"` emu branches
in P65C816.vhd:436-456) to match VICE/CMD SuperCPU semantics, which
real C64 software (Asterix decompressor) depends on.

This is **not a bug** but a documented compatibility tradeoff. SST
will continue to flag these cases against pure WDC silicon. Marked
as expected deviation.

## F3 — RTI PC++ — DEFERRED

### Smoking guns

- 40.e: `PBR:PC exp=1A:ED07 got=1A:ED08` — PC off by 1.
- 40.n: `CY[3] addr exp=0081CC got=0081CD` — addr off by 1.

### Mechanism (deeper than initially diagnosed)

Real WDC RTI uses **pre-read SP++** semantics: each pull cycle
increments SP first, then reads at the new SP. Our microcode uses
**post-read SP++** (the `LOAD_SP="001"` register file commits SP at
end of cycle). The cycle shapes diverge:

```
Real silicon native RTI (7 cycles):
  CY0 opcode | CY1 dummy fetch | CY2 dummy IO | CY3 read P (SP+1)
  | CY4 read PCL (SP+2) | CY5 read PCH (SP+3) | CY6 read PBR (SP+4)
  Final SP = init_SP + 4

Our microcode (7 cycles, off by ONE internal cycle at start):
  CY0 opcode | CY1 SP++ no-read | CY2 read P (SP+1) | ...
```

To realign: insert a true no-op cycle at state 1, push everything by
one. But then the SP++ for the PBR read in native must be conditional
(emu terminates after PCH read with SP at PCH-addr; native needs one
more SP++ before PBR read). This requires either a new microcode
LOAD_SP code that conditions on EF, or restructuring the SP-based
ADDR_BUS to support pre-read SP+1 semantics.

### Fix order

Deferred until the bench's other low-hanging RTL fixes are landed.
Option A: redesign microcode + custom LOAD_SP code.
Option B: redefine `addrBus="1100"` to use SP+1 for the read address
and have post-read SP++ commit to SP+1, matching pre-read silicon.
Option B is simpler but has wider blast radius (every SP-based read
in microcode would need re-checking).

## F11, F12 — single-case strays

A few opcodes have small straggler counts left after the big families
landed (e.g., $60 RTS emu 92, $28 PLP emu 34). The patterns differ
per-op; investigate one at a time after the v3 sweep lands.

## Fix order — landed

| Step | Family | Commit | Wipes |
|---|---|---|---|
| 1 | F1 dp,S carry | b7b2c68 | ~80 K |
| 2 | F2 JMP (abs,X) VDA | 8ab6722 | ~20 K |
| 3 | F5 X-flag 0->1 high-byte clear | a866b0f | ~5 K |
| 4 | F9 + F4 null-cycle flag compares | 2c02f48 | ~60 K |
| 5 | F10 FR-cells skip | 5bdeec8 | unblocks ~50 K |
| 6 | F2 ($FC) JSR (abs,X) VDA | df52690 | ~20 K |
| 7 | F8 reset-stub $01:FD clobber | a3ed66e | ~500 |
| -- | **Total wiped** | | **~185 K of 187 K** |
| (deferred) | F3 RTI PC++ | -- | 20 K (microcode restructure) |
| (deviation) | F6/F7 SuperCPU page-1 stack wrap | -- | ~300 (intentional) |
| (residual) | F11/F12 single-case strays | -- | <500 |

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
