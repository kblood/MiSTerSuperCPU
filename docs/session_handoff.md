# Session Handoff — iter-26 (2026-06-08)

## North star
Make the SuperCPU as compatible and fast as possible.

## TL;DR of where we are
- **COMPAT vein remains the productive lever** (GHDL-first SST sweep). iter-26
  closed the last known SST failure: **$e1 (SBC dp,X) case 8668**. A full SST
  re-baseline now confirms the 65C816 core is **100% SST-clean: 0 fail across
  all 256 opcodes × emu/native = 5,120,000 cases** (5,672 skips = expected
  prelude-region overlaps, not failures). The SST suite is now a definitive
  clean regression oracle — run `sweep_sst.ps1 -All` (~3.4h) before/after any
  CPU change to guard it. Results: `sweep_results_iter26_full/summary.csv`.
- **SPEED lever still exhausted at RTL** (cache "Bug 2" = setup-time class,
  HW-unreproducible; raised-clock B HW-dead). Cache RTL stays gated/inert
  (CACHE_READ_PATH=false shipped). Remaining speed = a CPU-internal pipeline
  (deep, multi-session) — not a quick win.

## iter-26: DP-indirect pointer +1 always 16-bit — SHIPPED (commit `fa6dc55`)
The $e1/8668 "carry" failure was a downstream symptom. Real bug: the **(dp,X)
indirect pointer HIGH byte was read from the wrong address**. D=$F400 (DL=$00),
dp+X = $FF → base pointer $00:$F4FF; our core wrapped +1 within the page → read
hi at $F400 instead of $F500, cascading to wrong pointer/operand/result/carry.

The W65C816 does NOT replicate the NMOS-6502 zero-page pointer wrap — the
DP-indirect pointer fetch is always full 16-bit arithmetic (a documented
emu-mode incompatibility). `P65C816.vhd` ADDR_BUS `"0011"/"0111"` had an
`EF=1 ∧ DL=0 → wrap` branch; the `DL≠0 → full-16-bit` part was the real prior
"262-fail" fix, the leftover `DL=0 → wrap` was wrong. Fix: always full 16-bit.

**SST oracle proof:** scanned ALL DP-indirect opcodes emu mode — EVERY DL=0
case whose ptr+1 crosses a page carries, never wraps (e1/8668 $F4FF→$F500,
[dp] 27/3340 $2FFF→$3000, [dp],Y 17/1411 $B6FF→$B700, 77/1177, 77/5959,
97/8726, 57/6431). Zero wrap cases anywhere ⇒ removing the wrap is strictly
correct. Safe because the wrap only ever changed behavior when DX(7:0)=$FF.

### Validation (complete)
- **GHDL SST (authoritative oracle):** e1.e 1→**0 fail**; full 80-run
  regression (40 DP-indirect opcodes × emu/native) = **0 fail everywhere**.
  Results in `sim/p65c816_singlesteptest/sweep_results_dpind_iter26/`.
- **Build:** md5 `3698680a`, fitter 75% ALM, TimeQuest TNS=0 all clocks
  (worst setup +0.499, hold +0.206).
- **HW system-regression guard:** deployed `/media/fat/_Test/C64.rbf`, boots
  READY clean (KERNAL idle PC ~$00E5CF), Lorenz scpu 8 min all-`ok`, no wedge
  (screen progressed at every checkpoint to t=487s). SST is the real oracle
  for this addressing fix; Lorenz confirms system health.

## Next levers (resume here, in priority order)
1. **SST sweep is DONE (100% clean, 0/5.12M).** Nothing left to chase in the
   SST micro-detail vein. Keep it green: re-run `sweep_sst.ps1 -All` after any
   future CPU/ALU/AddrGen change as the regression guard.
2. **Real SuperCPU software compat sweep** — now the live compat frontier
   (genuine programs, beyond SST
   micro-details). Needs HW + curated program set; open-ended.
3. **Speed (long horizon):** a pipeline INSIDE the P65C816 to raise miss
   cadence in clk32 passthrough — the only speed path left after cache and
   raised-clock are HW-dead. Deep, multi-session; GHDL-prove first.

## Tooling notes
- SST single op: `run_sst.ps1 -InputFile ../../external/65816/v1.bin/<op>.<e|n>.txt
  -StopTime 60000ms` (NOT "5s"). Sweep: `sweep_sst.ps1 -Opcodes @(...)` or `-All`.
- Single-case isolation: build a file with header `H <OP> <e|n> 1` + the case
  block renumbered to `C 0` (the tb asserts case-index == loop counter), run
  with `-VerboseEach` to dump the full cycle trace + register CAP.
- DP-indirect pointer address logic: `P65C816.vhd` ADDR_BUS `"0011"/"0111"`
  (~line 759). "0011" = ptr lo (ADDR_INC=0), "0111" = ptr hi (ADDR_INC=1);
  long [dp] adds bank at +2. All now full 16-bit `unsigned(DX)+ADDR_INC`.
- Lorenz: `tools/lorenz_run.py [t65|scpu] --mins N` (screenshot daemon flakes on
  long runs; CPU health better confirmed via UART when screenshots go NONE).
