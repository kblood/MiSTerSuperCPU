# Session Handoff — current (rebased 2026-06-13, post iter-30)

## North star
Make the SuperCPU as **compatible and fast** as possible. Drive; don't ask.

## ✅ iter-30 DONE: SPEED FRONTIER DECLARED CLOSED → pivot to COMPAT frontier
The operator asked to dig deeper into each remaining speed lever with Sonnet
subagents and mine VICE `xscpu64` for clues. Done. The investigation closed the
speed half of the project (short of a multi-month CPU-architecture rewrite that
needs an explicit operator decision to fund).

**What iter-30 did, in order:**
1. **VICE differential (4 Sonnet subagents)** → VICE gets 20 MHz with ZERO CPU
   pipelining; ALL its speed is the memory-timing accumulator, keystone = a posted
   WRITE BUFFER. `project_vice_differential_write_buffer.md`.
2. **A1 `WRITEFRAC_OBSERVER` HW gate** → Doom SuperRAM write fraction ~0.7-0.9%
   (read-dominated; heavy writes go to bus-visible bank $00 = un-postable anyway)
   ⇒ **posted-write buffer DROPPED.** `project_writefrac_gate_dropped.md`.
3. **Wider-row page-hit D-gate** → 512B locality 54.2% == 256B 54% (misses are
   scattered-access, not row-width-bound) ⇒ **page-mode DROPPED in ALL forms**
   (standalone / per-bank / 256B / 512B-remap). `project_pagehit_gate_measured_dropped.md`.
4. **Lever 2 (65C816-internal pipeline) datapath analysis (Sonnet) + Codex** →
   all 3 pipeline insertion points FATAL to SST cycle-exactness (the CPU does
   D_IN-read+ALU+writeback on ONE edge, even internal cycles; SST compares every
   cycle exactly). **Speed and compat are in direct architectural tension.**
   Codex independently agrees the frontier is closed short of a CPU rewrite.
   `project_speed_frontier_closed_compat_pivot.md`.

## Speed-lever ledger (COMPLETE — all exhausted)
| Lever | Verdict |
|---|---|
| cache read-path ×5 | HW-wedged (zero-delay-bench-blind death class) |
| raised-clock | HW-wedged |
| alt-fire (2-clk32) | HW-wedged |
| internal-fast-fire | HW-wedged |
| demand-arbiter | INERT (4-apart floor; byte-identical A/B) |
| posted write buffer | DROPPED — Doom SuperRAM ~0.7% writes, no ROI |
| page-mode SDRAM (all forms) | DROPPED — 54% locality → ~1.1× |
| 65C816-internal pipeline | FORBIDDEN by SST cycle-exactness |

**Two remaining speed options, both multi-month CPU-architecture projects needing
an explicit operator funding decision (NOT autonomous-loop work):**
- **Cycle-preserving datapath surgery** — faster BCD adder / carry-select decimal
  / precomputed PC+addr candidates / mux-depth split with NO added architectural
  latency. Preserves SST. Lower risk, lower ceiling (~1.x×). Start with P65C816
  critical-path STA.
- **Dual-mode CPU** — a second non-cycle-exact fast SuperRAM engine with precise
  traps/flushes into the exact core. Higher ceiling (20 MHz fast path) but trades
  away the SST guarantee; killer obstacle = precise mode-boundary semantics
  (drain before IRQ/NMI/ABORT/I-O/bank-0/VIC/mode-crossing branches/DMA).

## Status in one breath
- **Instruction-level compat is SOLVED.** SST 100% clean (0/5.12M). Lorenz 100%
  both modes. Doom + Wolf3D run; SCPU Kicks renders. SST vein exhausted.
- **Speed is closed for the autonomous loop.** Shipped build runs ~4 MHz (clk32
  SDRAM passthrough, `busy_cnt="011"` = 4-apart `enableCpu`, 6-clk64 auto-precharge
  floor). ~5× below real SuperCPU 20 MHz — and every cheap lever to close that gap
  is dead (table above).
- **HARD RULE persists:** do NOT build another speed RBF off a zero-delay bench
  (failed 6×). The only safe RBF class proven this session = read-only
  counter/observer (changes no cadence) — reuse for any HW characterization.

## Shipped build / MiSTer state
- `_Test` C64.rbf = iter-26 `3698680a` (known-good): boots READY, SCPU64 V0.07,
  idle PC cycles **$E5CD–$E5D6**. A/B control for any future speed RBF.
- Working tree: gated read-only observers committed in `fpga64_sid_iec.vhd`
  (`PAGEHIT_OBSERVER`/`WRITEFRAC_OBSERVER`, debug-only, prune from shipped RBF;
  `PAGEHIT_COL_EXTRA` parametrizes row width). Gated dead-lever constants
  (`DEMAND_ARBITER`/`INTERNAL_FAST_FIRE`=false) left as record; RBF-bit-identical
  to shipped (Quartus folds them away).

## NEXT — COMPAT frontier (the active autonomous-loop track)

### ✅ Recommended A — real SuperCPU software compat sweep (no risky build)
With the speed frontier closed, the highest-leverage *steady* progress is the
compat frontier. SST is exhausted ⇒ the live frontier is *non-instruction*
incompat. Curate real SCPU software (GEOS, SCPU-library titles, timing-sensitive
demos, WriteSmart users), run on shipped `3698680a` on HW, triage failures. No
speed build, no zero-delay-bench wall. The `pagehit_probe.py`/`writefrac_probe.py`
autoload+UART harness + the observers are reusable to characterize any title.

### Backlog F — WriteSmart register decode ($D074–D077 / $D0B3)
Specific real-HW feature; reportedly already partly software-visible, full decode
is the remaining piece. VICE B4 (`scpu64mem.c scpu64_hardware_store` ~684-817)
documents the optimization-mode → `mem_set_mirroring` semantics to match.

### ⏸ Speed (operator-funded only) — see ledger above
Datapath surgery or dual-mode CPU. Surface to operator; do not start in the loop.

## Tooling notes
- SST regression oracle: `sweep_sst.ps1 -All` must stay 0/5.12M after ANY
  CPU/ALU/AddrGen change. Garbage variant: `-GarbageInternal`.
- HW A/B method: deploy suspect RBF, sample UART `PC:` distribution
  (`mister_debug.py uart N`). Healthy idle = a RANGE around $E5CD–$E5D6; wedge =
  one pinned address. Always run shipped `3698680a` as the control.
- Read-only observer pattern (iter-29/30): gated constant in `fpga64_sid_iec.vhd`,
  reuse dead cpu_cache HR/HW UART slot via `debug_uart_pool_fmt.sv`, probe with a
  `pagehit_probe.py`-style autoload+UART script. Wedge-proof, prunes from shipped.
- `lorenz_run.py [scpu|t65]`'s MGL core-reload can transiently wedge the daemon
  pipe; `reboot` clears it (pre-authorized). Confirm core via `cat /tmp/CORENAME`.
- Full death records: `session_handoff_2026-06-13_iter28-speed-levers-exhausted.md`
  + the iter-30 memory files listed above.
