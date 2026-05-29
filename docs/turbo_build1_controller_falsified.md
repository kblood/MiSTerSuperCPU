# Turbo Build-1 (controller-only bisect) — HW-FALSIFIED 2026-05-30

## What was tested
Build-1 of the "more turbo" plan (memory `project_goal_more_turbo`): restore the
`aafa4a4` Build-C page-mode SDRAM controller (`sdram_pm.v` — HIT/MISS +
PRECHARGE FSM + internal `last_bank`/`last_row`/`last_row_valid` tracker) and
wire its `fast_path` input from `scpu_fast_path & ~io_cycle & ~ext_cycle`, while
leaving the **arbiter completely unchanged** (`sdram_hit_pred<='0'`, alt-slots
gated off). Build md5 `fc4e8176`, 66% ALMs, clean compile.

The bisect's purpose: isolate the Build-C *controller* from the historical
*arbiter* dual-tracker bug. The standing assumption (handoff + memory) was that
the aafa4a4 controller is "silicon-validated" and the Doom failure of the
aafa4a4 RBFs was caused **only** by the arbiter's private predictor diverging
from the controller's tracker. Build-1 forces the arbiter predictor off, so if
the controller is truly sound, Doom should boot.

## Result: the controller ALONE regresses Doom
Decisive A/B on the same `doom_autoload_probe.py`, same MiSTer, back-to-back:

| Build | controller | arbiter | Doom result | PC signature |
|-------|-----------|---------|-------------|--------------|
| `97392a1f` (control) | Build B | unchanged | **reaches main loop** | `2C:0CA6/0D02/0C90`, native P:00 |
| `fc4e8176` (Build-1) run 1 | Build C | unchanged | fail — stuck at BASIC | `00:E5CD` KERNAL idle, emu P:32 |
| `fc4e8176` (Build-1) run 2 | Build C | unchanged | fail — **BRK $00:000A** | `PC:00000A`, J:`0738` (loader ML), SP runaway |

Run 2 is the smoking gun: the loader's inner ML (`J:$0738` = REU→SuperRAM
transfer chain) **ran** and then crashed with the classic stale-read BRK
`$00:000A` — the same corruption signature as the historical dual-tracker bug,
but here **the arbiter predictor is OFF**. Therefore the stale read is produced
by the **controller itself**, not the arbiter.

## Root cause (mechanism)
The Build-C controller keeps the SuperRAM row OPEN on a `fast_path` access
(A10=0, no auto-precharge) so the next access can HIT. When the *next* access is
NOT a HIT (different row, or a bank-$00 access — `last_row_valid && !row_hit`),
the controller takes the **conflict-MISS path**: PRECHARGE-ALL (q=0) → tRP (q=1)
→ ACTIVE (q=2) → tRCD → READ/WRITE (q=4) → CAS → **sample at q=7** = 8 clk64 =
4 clk32. Build B's MISS samples at **q=5** = 6 clk64 = 3 clk32. The conflict-MISS
delivers `dout_r` **one clk32 later** than Build B.

The arbiter in Build-1 is byte-for-byte Build B timing (`busy_cnt="011"`,
hit_pred=0), so the CPU samples `dout_r` at the Build-B time — i.e. **before** the
conflict-MISS has updated it → it latches the *previous* cycle's data = a stale
read. Doom's loader interleaves SuperRAM long-stores (open the row) with bank-$00
ZP/pointer accesses (force conflict-MISS on the return to SuperRAM), so the
conflict-MISS path fires constantly during the transfer → corrupted bytes →
corrupted pointer/opcode → BRK $00:000A.

## Consequences for the speed plan
1. **Build-2 is blocked.** Build-2 (single-tracker arbiter + alt-slots) layers a
   *speedup* on top of this controller. The controller's correctness floor is
   already broken under interleaved access, so Build-2 cannot help — do NOT build
   it. (`docs/turbo_build2_ready_patch.md` is shelved.)
2. **The sim has a fidelity gap.** `sim/turbo_throughput_tb` uses `sdram_pm_lite`,
   which models HIT/MISS latency but NOT the conflict-MISS sample-timing hazard
   under interleaved (SuperRAM + bank-$00) access. It reported mode-2 = 0 stale;
   real HW says otherwise. The sim must model: (a) the 8-clk64 conflict-MISS, (b)
   the CPU sample edge relative to the controller's q-state, (c) a realistic
   interleaved access stream (not pure-sequential SuperRAM). Until it reproduces
   the BRK, its speed numbers for page-mode are not trustworthy.
3. **Page-mode payoff on real workloads is low anyway.** The 7.99 MHz sim figure
   was for *sequential* SuperRAM. Real 6502/65C816 code is ZP-heavy and
   interleaves bank-$00 constantly → mostly conflict-MISS → little HIT benefit
   even if made correct. This corroborates iter-4's conclusion that the real
   >4 MHz path is **Milestone B** (clk_cpu=64 MHz), not page-mode SDRAM.

## State after this iteration
- RTL reverted to pristine HEAD behavior: `sdram_pm.v` = Build B (git-clean);
  `c64.sv` `sdram_fast_path` = `1'b0` stub, `.fast_path` removed (functional code
  identical to HEAD; only a finding-note comment added; pre-existing local UART
  instrumentation untouched).
- Good build `97392a1f` restored to `/media/fat/_Test/C64.rbf`; MiSTer lock
  released.
- Archived Build-1 RBF: `builds/..._fc4e8176-dirty.rbf` (kept for re-confirmation
  only; it is a known-bad turbo build).
