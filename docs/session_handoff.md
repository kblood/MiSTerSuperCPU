# Session Handoff — iter-25 (2026-06-05)

## North star
Make the SuperCPU as compatible and fast as possible.

## TL;DR of where we are
- **SPEED lever is exhausted at the RTL level.** The HW-proven 3.0x same-line
  alt-fire cache speedup (commit `0deb093`) is blocked by cache "Bug 2", which
  iter-24 proved is a **setup-time/timing-asymmetry class bug, unreproducible in
  any zero-delay RTL sim** (5 distinct RTL fixes all HW-falsified, the last two
  byte-identical no-ops). Raised-clock (clk48/clk64, Milestone B) also HW-dead.
  Remaining speed needs a CPU-internal pipeline (deep, multi-session) — NOT a
  quick win. The cache RTL stays gated/inert (CACHE_READ_PATH=false = shipped,
  Doom-safe).
- **COMPAT work is the live, productive vein** (the iter-20/21 SST sweep that has
  shipped HW-verified fixes this month). The 65C816 core is now ~functionally
  clean: the full SST re-baseline (5.12M cases) showed only RTI (40.e/40.n) and
  one $e1 flag edge failing. **iter-25 fixed RTI (this session).**

## iter-25: RTI ($40) made cycle-exact — SHIPPED (commit `edf5daf`)
RTI was functionally correct (returned to the right PC/P/PBR) but cycle-trace
WRONG in both modes (40.e 9906 fail, 40.n 9995 fail in SST). Two defects:
1. **Missing leading IO cycle.** Real WDC RTI has TWO internal cycles after the
   opcode fetch (PBR:PC+1 x2) before the stack pulls; the microcode had one.
   Fixed by adding a pure-IO leading cycle (mirrors the RTS/RTL template).
2. **Native PBR-pull setup in the wrong trace position.** Native RTI pulls a 4th
   byte (PBR) needing SP one higher than emu. The old microcode did this with a
   dedicated internal LOAD_SP="000" cycle between PCH-pull and PBR-pull —
   state-correct but a cycle real silicon doesn't emit (its pulls are
   combinationally pre-incremented). Replaced with a surgical
   `IR=$40 ∧ EF='0' ∧ STATE_CTRL="111"` special case in `P65C816.vhd` that
   increments SP on the PCH-pull cycle in NATIVE only, so the next cycle reads
   PBR at S+4 with no extra cycle. Gated on IR=$40 ⇒ cannot affect any other
   opcode; in emu the PCH-pull is the last cycle and must NOT increment (SP=S+3).

Why native couldn't be done without the special case: the leading-increment pull
model needs the PCH-pull to increment in native (4 pulls) but not in emu (3
pulls, PCH is last). That mode-conditional increment has no spare LOAD_SP
encoding, so a tightly-gated IR=$40 special case is the minimal correct fix.

Result (both byte-exact vs TomHarte SST vectors):
- emu  = fetch,IO,IO,pullP,pullPCL,pullPCH (6cy, SP=S+3)
- native = +pullPBR (7cy, SP=S+4)

### Validation (complete)
- **GHDL SST (authoritative oracle — checks full cycle-by-cycle bus trace + final
  state):** 40.e 9906→**0 fail**, 40.n 9995→**0 fail**.
- **Regression:** targeted sweep over 30 stack/control/ALU opcodes both modes
  (600k cases) = **0 fail**; change is IR=$40-confined and the MCode block stays
  8 slots/opcode so ROM indexing is unchanged.
- **Build:** md5 `d387a4d5`, fitter OK 75% ALM, TimeQuest clean (worst setup
  +0.346, hold +0.219, TNS=0).
- **HW system-regression guard:** deployed to `/media/fat/_Test/C64.rbf`, boots
  to READY (KERNAL idle loop PC:00E5CF), Lorenz scpu runs clean ~10 min (basic/
  lda/sta/ldx/stx all "ok", no wedge, CPU healthy). Lorenz only validates RTI
  *function* (already correct) not cycle traces, so SST is the real RTI oracle —
  the Lorenz run's job is system health, which passed. t65 mode uses the T65 core
  (untouched by this 65C816-only change).
- **MiSTer daemon wedged once** mid-session on back-to-back core reloads
  (screenshots dropped, `ttyS1: 31250` baud spam, core dropped to menu.rbf, zero
  UART — a crashed CPU still streams UART, so this was the daemon not the core).
  Reboot (pre-authorized) cleared it; the post-reboot run was clean to t=584s.

## Next levers (resume here, in priority order)
1. **Continue the SST compat sweep** (GHDL-first, the shipping vein). Remaining
   known failure: **$e1 (SBC dp,X) 1 case** (case 8668, P exp=30 got=31 = carry
   bit; likely a decimal-mode SBC carry corner — 1/10000, very marginal). After
   that the SST suite is ~100% (a clean regression oracle going forward).
   Re-baseline if desired: `sweep_sst.ps1 -All` (~3.6h).
2. **Real SuperCPU software compat sweep** (the genuine compat frontier, beyond
   SST micro-details). Needs HW + curated program set; open-ended.
3. **Speed (long horizon):** a pipeline INSIDE the P65C816 to raise miss cadence
   in clk32 passthrough — the only speed path left after cache/raised-clock are
   HW-dead. Deep, multi-session; GHDL-prove first.

## Tooling notes
- SST single op: `sim/p65c816_singlesteptest/run_sst.ps1 -InputFile
  ../../external/65816/v1.bin/<op>.<e|n>.txt -StopTime 60000ms` (NOT the default
  "5s" — GHDL rejects it). Sweep: `sweep_sst.ps1 -Opcodes @(...)` or `-All`.
- MCode field order (per `P65816_pkg.vhd` MicroInst_r): stateCtrl, addrBus,
  addrInc, loadP, loadT, muxCtrl, addrCtrl, loadPC, loadSP, regAXY, loadDKB,
  busCtrl, ALUCtrl, byteSel, outBus, va. Each opcode = 8 slots (IR*8 + STATE).
- LOAD_SP decode in `P65C816.vhd` ~418: 000 null, 001 inc(emu=page1+lo), 010
  cond-inc(w16), 011 dec, 100 SP<=A, 101 SP<=X, 110 newinc(16b both modes), 111
  newdec. STATE_CTRL="111" = RTI/BRK/COP last-cycle-or-continue (mode branch).
- Lorenz: `tools/lorenz_run.py [t65|scpu] --mins N` (screenshot daemon flakes on
  long runs; CPU health is better confirmed via UART when screenshots go NONE).
