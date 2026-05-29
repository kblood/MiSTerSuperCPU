# SuperCPU turbo — two-domain throughput sim findings (2026-05-30)

**Goal (operator, 2026-05-30):** get *more* turbo. Don't accept the prior
"4 MHz is a hard architectural ceiling / >4 MHz is Milestone-B-gated"
conclusion — build better sims and find a way.

**Result:** built a faithful two-clock-domain throughput **and correctness**
sim (`sim/turbo_throughput_tb/`) that measures effective MHz. It shows a
concrete, correct path to **2× (8 MHz) on the current architecture** — no
clock change, no Milestone B — and reproduces the historical Doom-BRK
corruption in sim to prove the safe design. This **refutes iter-4's
"alt-slots cannot help."**

## The sim

- `cpu_arb_model.vhd` — the clk32 CPU-slot arbiter, extracted near-verbatim
  from `fpga64_sid_iec.vhd` (cpu_cyc / sdram_busy / busy_cnt / alt_fire /
  2-FF ready sync). Experiment knobs are generics that **default to today's
  RTL behaviour** (so the baseline run reproduces silicon).
- `sdram_pm_lite.vhd` (reused from `sim/sdram_pm_tb/`) — the validated clk64
  Build-C SDRAM model: MISS = 6 clk64, HIT (open-row) = 3 clk64, with the
  `fast_path` SuperRAM gate and an SDRAM-command observation stream.
- `turbo_throughput_tb.vhd` — wires them across the real clk64↔clk32 CDC,
  drives a sequential CPU access stream (locality via `G_STRIDE`), and
  measures: (1) **effective MHz** = CPU accesses launched per µs, and
  (2) **STALE_READS** = new `ce` asserted while `sdram_ready=0` (the
  controller silently drops it = corruption — the exact dual-tracker hazard).

Run: `sim/turbo_throughput_tb/run.sh` (GHDL). Baseline MUST report 4.0 MHz /
0 stale — that validates the model before any experiment is trusted.

## Knobs

| generic | meaning |
|---|---|
| `G_ALT_SLOTS` | enable the Step-5 alt-slot fires at CPU2/6/A/E |
| `G_HIT_MODE` | 0 = forced MISS budget (today); 1 = arbiter PRIVATE row predictor (the dual-tracker); 2 = SINGLE tracker sourced from the controller's command stream |
| `G_BUSY_FROM_READY` | true = clear busy on the 2-FF-synced real `data_valid` (the "true handshake") |
| `G_STRIDE` | bytes between accesses → controls row-hit rate (1 = tight seq, 256 = all-miss) |
| `G_REFRESH_PERIOD` | async row-close stress the arbiter is unaware of (models REU/DMA-stolen cycle) |

## Measured results (G_US=2000 µs each)

### Clean sequential SuperRAM code
| config | eff. MHz | stale | note |
|---|---|---|---|
| baseline (alt OFF, mode 0) | **4.00** | 0 | = today's silicon ✓ |
| alt ON, mode 0 (no prediction) | 4.00 | 0 | alt can't fire without a HIT budget |
| alt ON, mode 1 (private predictor) | 6.98 | 0 | works clean-case, but self-invalidates at VIC0 |
| **alt ON, mode 2 (single tracker)** | **7.99** | **0** | **the fix — 2×** |

### Async row-close stress (faithful model of the Doom REU hazard)
| config | eff. MHz | stale | verdict |
|---|---|---|---|
| mode 1 (private predictor) | 6.98 | **718–1026** | **FAIL — reproduces Doom BRK in sim** |
| mode 2 (single tracker) | 5.85–6.12 | 0 | **PASS — 1.5×, correct under stress** |

### True-handshake (iter-4's approach)
| config | eff. MHz | stale |
|---|---|---|
| busy ← synced data_valid | 3.99 | 0 |

→ confirms iter-4: the 2-FF sync (~2 clk32) clears busy too late for any
alt-slot to fire. iter-4 was right about *this* mechanism but wrong to
generalize "alt-slots can't help."

### mode 2 hit-rate sensitivity (graceful fallback, no refresh)
| stride | acc/page | eff. MHz | stale |
|---|---|---|---|
| 1 | 256 | 7.99 | 0 |
| 64 | 4 | 6.66 | 0 |
| 128 | 2 | 5.99 | 0 |
| 256 | 1 | 4.00 | 0 |

Never below the 4 MHz baseline; scales up with locality.

## The finding

1. **Throughput arithmetic for >4 MHz works.** Alt-slots at CPU2/6/A/E give
   up to 8 MHz (8 CPU accesses / 32-clk32 rotation) when the SDRAM cycle is
   short enough (page-mode HIT = 3 clk64 = 1.5 clk32 < the 2-clk32 alt
   spacing).
2. **The blocker was never arithmetic — it was correctness.** The arbiter's
   *private* row predictor (`sdram_pred_*`, cleared at VIC0) can diverge from
   the SDRAM controller's actual open-row state when something closes the row
   mid-CPU-window (REU/DMA/refresh). Predict-HIT-but-actual-MISS → busy
   clears early → premature `ce` → dropped/stale read → Doom BRK. The sim
   reproduces this (718–1026 stale reads).
3. **The fix is a SINGLE row tracker.** Have the arbiter derive its HIT
   decision from the controller's actual state (watch its SDRAM command
   stream, or read its `last_bank/last_row/last_row_valid`) instead of
   maintaining its own predictor. Then prediction can never disagree with
   reality → 0 stale in every config, and it's also *faster* (7.99 vs 6.98)
   because it doesn't needlessly self-invalidate at VIC0.

## What to build (queued for HW when the core frees)

This sim de-risks the **arbiter** side. The remaining HW risk is the Verilog
**page-mode SDRAM controller** itself (Build C — historically wedge-prone;
the current LKG `sdram_pm.v` is Build B + V6, no page mode, A10=1
auto-precharge always). Required RTL changes, GHDL-prove each in the reduced
harness first:

1. `sdram_pm.v` — revive the Build-C page-mode HIT path (3 clk64 open-row
   read, no ACTIVE) with proper conflict-MISS precharge. Reference FSM:
   `sim/sdram_pm_tb/sdram_pm_lite.vhd`. **Expose the open-row tracker**
   (`last_bank`/`last_row`/`last_row_valid`) as outputs.
2. `fpga64_sid_iec.vhd` —
   - replace `sdram_hit_pred <= '0'` (and the private `sdram_pred_*`
     predictor + its VIC0 clear) with a HIT compare against the controller's
     exposed tracker (single source of truth);
   - re-enable the Step-5 `alt_fire_r` block, gated on
     `sdram_busy_cnt <= 1` AND `scpu_fast_path` (SuperRAM only);
   - keep the MISS budget (`busy_cnt=011`) as the safety floor.
3. Regression gates unchanged: Lorenz 100% (both modes), Doom autoload, Wolf3D.
   The stale-read monitor here is the off-device oracle for "did we break the
   row-tracking again."

Expected effective speed: **~8 MHz on SuperRAM-bank code with good locality,
~5–6 MHz under heavy DMA/refresh, 4 MHz worst-case (no regression).**

Bigger lever beyond this (separate, larger): the BRAM CPU cache (up to
32 MHz on hits, bypasses SDRAM) — the same sim harness can be extended to
model the cache + write-buffer before reviving the dead `cpu_cache.vhd`.
