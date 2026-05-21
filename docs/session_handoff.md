# Session handoff — 2026-05-21 (stabilisation + async pivot decision)

## Status: Phase 6b REVERTED. Branch stable at Phase 6a baseline. Pivoting to async CPU bridge.

**Current branch:** `step6-rdy-handshake`
**Stabilising commit:** `8377734` — `Revert "feat: Step 6 Phase 6b ..."`
**Resulting RBF md5:** 88963b9e (= Phase 6a baseline, byte-identical to proven-working build)
**Merge target:** `vanilla-cpu-swap` → `master` → fork `async-cpu-bridge`

### Why the revert

Seven consecutive attempts at a Phase 6b dv_sync consumer (iso2-v3 through
iso7) all wedge on cold boot with PC=$0005, regardless of whether `cpu_cyc`
is gated. iso8 (literal Phase-6a-equivalent reconstruction) built bit-identical
to 88963b9e — confirming the bug class is the dv_sync CONSUMER, not the bus
arbiter, not the cpu_cyc gate. Phase 6b is suspended and the broken commit
(e42ee1e) is reverted. Step 5a alt-slot work (3455df7) and Phase 6a signal
plumbing (8434077) are KEPT — both work and Step 5a gives ~1.5× Doom.

### Decision: pivot to full async CPU domain

After comparing the Gemini 3.5 Flash research roadmap (`docs/Gemini35FlashResearch.md`
+ `docs/gemini_roadmap_vs_current.md`) to current state, the next architectural
step is to move the P65C816 into its own clock domain (`clk_cpu`) with a
CDC bridge, matching the real CMD SuperCPU model. This is what the project's
top-level goal ("20MHz native mode") actually requires and likely sidesteps
the iso2-iso7 wedge class entirely by forcing explicit CDC synchronization
instead of hidden sequential paths inside a single clock domain.

Phased plan, each phase = one build + defined exit test:

- **A — Save point.** Current step6-rdy-handshake (post-revert) merged into
  vanilla-cpu-swap → master. Fork `async-cpu-bridge` branch from there.
- **B — Add `clk_cpu` PLL output unused.** Start at 32 MHz (= clk_sys),
  electrically inert. Verify Doom hashes unchanged.
- **C — P65C816 moved into clk_cpu domain.** clk_cpu still = clk_sys, no
  CDC yet. Should behave identically.
- **D — Insert CDC bridge.** Double-buffered sync on cpuAddr/cpuDo/cpuWe
  (CPU→sys) and cpuDi/ack (sys→CPU). RDY/enable pulled low until ack
  returns. Still 32 MHz — measuring overhead only.
- **E — Bump clk_cpu to 64 MHz, then 20 MHz native target.** Payoff visible.
- **F — Full regression.** KERNAL, Lorenz t65+scpu, Doom hashes vs Step 5a,
  Wolf3D Level 1, REU DMA.

### What's preserved on step6-rdy-handshake (and now master)

| Commit  | What                                                  | Status                    |
|---------|-------------------------------------------------------|---------------------------|
| 3455df7 | Step 5a — registered `alt_fire_r`                    | ~1.5× Doom speedup, keep  |
| 0cee649 | Step 2 — SDRAM-busy backpressure scaffolding         | used by Step 5a, keep     |
| a65b3f7 | Step 1 — sdram_ready 2-FF synchroniser plumbing      | foundation, keep          |
| 9f9e2c2 | Revert sdram_pm.v back to Build B                    | Build C abandonment, keep |
| 793fa12 | C64.sdc filter fix (sdram_pm not sdram)              | required for fitter, keep |
| 8434077 | Phase 6a — data_valid signal plumbing (no consumer)  | inert plumbing, keep      |
| 8377734 | Revert Phase 6b                                       | NEW — unblocks baseline   |

All vanilla-cpu-swap fixes (v341 through v356, Doom/Wolf3D PLAYABLE,
$F8+ carve-out, IRQ stub etc.) are intact.

### v356 milestones (still valid)

| Title       | Status   | Verified              | Reproducer                          |
|-------------|----------|-----------------------|-------------------------------------|
| Wolf3D      | PLAYABLE | E1L1 starting room    | menu break via SPACE at HS→demo     |
| Doom        | PLAYABLE | E1M1 3D corridor+HUD  | `tools/doom_v356_PLAY.py`           |
| Lorenz t65  | PASS     | 32m SCPU regtest      | `tools/lorenz_run.py t65 --mins 32` |
| Lorenz scpu | PASS     | `orazx - ok` at 32m   | `tools/lorenz_run.py scpu --mins 32`|

### Open architectural questions for the async-cpu-bridge branch

1. **VIC-II handling.** Real CMD SuperCPU keeps VIC at 1 MHz on the C64
   motherboard; SuperCPU runs free. Likely the same architecture — VIC
   stays in clk_sys, async CPU bridges only when slow-side data is needed.
   Subtleties: VIC's IRQ to CPU crosses domains; screen RAM in SDRAM
   means VIC reads compete with CPU reads; refresh.
2. **ZP+stack BRAM cache (Gemini Phase 3).** Optional but very attractive
   — would let hot-path reads bypass the CDC bridge entirely. Defer until
   Phase D works, then add in Phase E or later.
3. **REU DMA path.** Currently `iof_fall_pulse` is falling-edge in clk_sys.
   In async model, the CPU's STA $DFxx write needs to cross CDC before
   reu.v sees the cs pulse — adds latency that may or may not break
   existing REU timing tests.
4. **Resource budget.** Currently 64% ALMs. Async bridge adds CDC FFs and
   new arbiter logic. Should fit but worth monitoring.

### Files added this session

- `docs/gemini_roadmap_vs_current.md` — point-by-point evaluation of the
  Gemini roadmap vs current implementation, with three options analysis
  (cheap SDC fix / medium cache / real async bridge).

### Pre-existing dirty files left in working tree (intentional, per user)

`.gitignore`, `C64_MiSTer/C64.qpf`, `C64_MiSTer/C64.qsf`, `C64_MiSTer/c64.sv`,
`build_c64.ps1`, `tools/doom_v342_test.py`, lorenz_run screenshots. Mostly
line-ending / build-artifact noise; user will triage separately.
