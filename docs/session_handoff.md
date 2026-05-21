# Session handoff — 2026-05-21 (async-cpu-bridge Phases A/B/C done)

## Status: Phases A/B/C complete. Branch `async-cpu-bridge` carries the inert scaffolding. Phase D is the next perturbation step.

**Current branch:** `async-cpu-bridge` (tip `f7ba6d7`)
**RBF md5 (B + C):** `88963b9e` — bit-identical to vanilla-cpu-swap baseline
**Saved on remote:** step6-rdy-handshake / vanilla-cpu-swap / master / async-cpu-bridge all pushed

### Phase A — Save point. DONE
Merged step6-rdy-handshake (post-Phase-6b-revert) into vanilla-cpu-swap (`e7a9afb`),
then into master (`bb7f3e9`). Branch `async-cpu-bridge` forked from
vanilla-cpu-swap. All four branches pushed.

### Phase B — clk_cpu wire alias. DONE (commit `708a56f`)
One-line addition in c64.sv: `wire clk_cpu = clk_sys;`. Names the future CPU
clock domain without any electrical change. Quartus collapses the alias →
RBF md5 88963b9e (= baseline). Phase B PASS confirms the synthesis pipeline
treats the named hook as a no-op.

### Phase C — P65C816 retargeted onto clk_cpu. DONE (commit `f7ba6d7`)
Added `clk_cpu` input port to `fpga64_sid_iec.vhd` entity, wired from c64.sv
`fpga64` instantiation, and switched `cpu_65c816_inst.clk` from `clk32` to
`clk_cpu`. Still 88963b9e — the synthesizer recognises both nets are
electrically the same. The T65 6510 and the rest of the bus arbiter stay
on `clk32`; only the 65C816 has moved. This is the clean separation point
the future CDC bridge will hang off.

### Phase D — CDC bridge. NOT STARTED
Real perturbation. When `clk_cpu = clk_sys` the bridge becomes pipeline
latency rather than true CDC, but it WILL slow per-access throughput (output
register + req CDC + bus access + ack CDC + input latch ≈ 5-7 clk_sys per
access on a same-clock build). Doom hashes will change. Open design
questions before starting:

1. **Handshake protocol.** Pulse-based req/ack (one-shot per access) vs
   level-based valid/ready (held until acknowledged). Pulse is simpler;
   level is closer to AXI-stream pattern Gemini hinted at.
2. **Where the synchronizer FFs sit.** Adding them at the entity boundary
   (just outside cpu_65c816_inst) is the cleanest hookpoint. The bus mux
   downstream stays unchanged.
3. **RDY-stall vs enable-gate.** Current CPU is `enable`-gated, not RDY
   stalled. The Gemini model uses RDY. Switching costs an extra mode
   bit per slot; staying with enable is faster to validate.
4. **Same-clock CDC FF count.** When `clk_cpu = clk_sys`, the 2-FF sync
   chain is technically unnecessary (no metastability between same-edge
   FFs). Building it anyway preserves the timing closure margin that
   Phase E (different clk_cpu) will need.

### Phase E — Bump clk_cpu. NOT STARTED
Requires regenerating the PLL with a 4th output. Frequency options:
40 MHz (2× clk_sys, no SDRAM constraint conflict), 64 MHz (= clk64,
already in PLL), 100 MHz native target.

### Phase F — Full regression. NOT STARTED
KERNAL, Lorenz t65+scpu, Doom hashes vs Step 5a, Wolf3D Level 1, REU DMA.

---

(historical context below — superseded by the Phase A/B/C section above)

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
