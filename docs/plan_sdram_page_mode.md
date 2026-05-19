# Plan: SDRAM page-mode controller + backpressure for SCPU speedup

Status: **DRAFT in progress, not wired into build.**

## Why
Option C (iter 1 / iter 1.5) tried to give the SCPU more CPU slots per 32-cycle
frame but wedged Doom in both cases. Root cause: the SDRAM controller takes
8 clk64 per access and the second slot's `ce` edge restarts the FSM
mid-flight, corrupting the in-progress access. The 4-MHz cap on SuperRAM
reads is the binding constraint for Doom's frame rate.

The master/upstream branch has already exploited the in-FPGA cache heavily,
so the next lever is the SDRAM controller itself.

## Three layers required to actually move the needle

### Layer 1 — SDRAM page-mode (DRAFTED)
File: `C64_MiSTer/rtl/sdram_pm.v`

Changes vs baseline `sdram.v`:
- Track open row per bank (4 × 13-bit row + valid bit).
- Skip `CMD_ACTIVE` when next access hits the open row → access drops from
  8 clk64 to 4 clk64.
- Drop the auto-precharge bit (sd_addr[10]) from `CMD_READ`/`CMD_WRITE`.
- On row-conflict (same bank, different row): issue per-bank
  `CMD_PRECHARGE`, wait tRP, then proceed through cold ACTIVE+READ
  sequence (9 clk64 total, 1 cycle worse than baseline cold).
- On refresh: precharge all banks (A10=1) before `CMD_AUTO_REFRESH` if
  any row is valid.

**Status**: file written. Not yet syntax-checked under Quartus. Not yet
swapped into c64.sv (still references `sdram.v`).

### Layer 2 — backpressure interface (NOT STARTED)
Even with page-mode, a row-conflict (9 clk64) still exceeds the iter-1.5
slot cadence (8 clk64 between CPU slots). Without a "controller busy"
signal, the FSM still aborts mid-flight on the next `ce` edge.

Plan:
- Add `output sdram_ready` (= `q == ST_IDLE`) to sdram_pm.v.
- Modify `fpga64_sid_iec.vhd` to gate `cart_ce` generation when
  `sdram_ready=0` AND the CPU is requesting a SuperRAM access.
- Effect: CPU slot stalls (CPU enable held low) until SDRAM finishes
  previous op. CPU "lost" cycles are bounded by the worst-case 9-clk64
  conflict path.

Risk: stalling the CPU enable might desync VIC / CIA timing. Need to
verify CPU enable can be held without bus-arbiter corruption.

### Layer 3 — extra CPU slots (DEFERRED, depends on Layer 2)
Re-attempt iter 1.5 (8 CPU slots per frame) with the backpressure-aware
controller. Or go further: more slots reclaimed from EXT cycles.

## Pre-build measurements needed
Before betting any more synthesis hours on this path, **measure where
Doom's frame time is actually going**. Currently we assume "SDRAM is the
bottleneck" because turbo speedup is ~3×, but we haven't decomposed:
- SuperRAM read latency (SDRAM page-hit vs miss rate during gameplay)
- BRAM access vs SDRAM access ratio
- VIC slot stalls
- IRQ handler overhead

If page-hit rate is high (>90%), the SDRAM cold path is already rare and
page-mode wins little. If page-hit rate is low (<60%), page-mode is a
big win. We don't know which regime Doom is in.

**Cheap measurement**: instrument cart_ce / sdram bank/row history in
UART for 60 seconds of Doom gameplay. Hash row sequences to compute
hit rate. Decide whether layers 1–3 are worth the engineering before
synthesizing.

## Open questions
- Real CMD SuperCPU runs at 20 MHz with 128 KB SRAM (zero-wait fast
  memory). Our equivalent would be all of SuperRAM in BRAM, which we
  can't afford (DE10-Nano has ~5 MB BRAM total, SuperRAM ROM/RAM
  budget is much smaller). So SDRAM access **will always be slower
  than CMD SuperCPU's SRAM**. Page-mode + backpressure narrows the
  gap but doesn't close it.
- DDR3 via HPS f2sdram bridge could host bulk REU memory (frees SDRAM
  bandwidth for SuperRAM) but DDR3 latency is too high for per-instruction
  fetches. SuperRAM on DDR3 would lose more than it gains.

## Files in this plan
- `C64_MiSTer/rtl/sdram_pm.v` — draft, page-mode controller (Layer 1)
- `C64_MiSTer/rtl/sdram.v` — baseline, still wired in
- `C64_MiSTer/c64.sv:1013` — current `sdram sdram (...)` instantiation
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1335-1366` — refresh + sysCycle
  state machine (Layer 2 will touch this)
