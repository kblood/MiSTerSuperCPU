# Track C — SuperRAM posted-write buffer (design, gated on A1)

Status: DESIGN READY, build-gated on the A1 write-fraction measurement
(`tools/writefrac_probe.py`). Do NOT cut the HW build until A1 shows Doom's
SuperRAM write fraction justifies the surgery (≥~25% → proceed; <~10% →
reconsider). Sources: VICE differential (4 Sonnet subagents, 2026-06-13),
harness map (Sonnet Explore), Codex spec review
(`tools/codex-out/writebuffer-spec-review.txt`).

## Why this lever is NOT in the 6-dead-lever death class
The 6 dead levers all fired a *memory access* (with `dout_r` read latency) earlier
than the SDRAM could return data → setup/phase race. A posted **write** has no
`dout_r` return path: the store completes to the CPU immediately and the actual
SDRAM write is drained later in a guaranteed-idle slot. VICE confirms the real
SuperCPU's 20 MHz comes entirely from this memory-timing model (no CPU pipeline);
its write buffer (`scpu64cpu.c` `buffer_finish`/`wait_buffer`) posts writes free
while reads cannot be. Our gain is bounded by the SuperRAM write fraction (A1).

## The core surgery (Codex's "dangerous split") — handle FIRST
- `ramCE <= cs_ram when sysCycle=CYCLE_VIC0 or cpu_cyc='1'` (fpga64_sid_iec.vhd
  ~:3586/3609). CPU advance = `enableCpu <= cpu_cyc_s(1)` (~:3900), i.e. `cpu_cyc`
  delayed 2 clk32.
- To post a write we must **advance the CPU without asserting `cpu_cyc`** (asserting
  it would launch a real SDRAM transaction + load `sdram_busy_cnt`). So a posted
  store needs a **separate enable pulse** that bypasses the `cpu_cyc → ramCE`
  path but still drives the CPU's `enable` and the `cpu_cyc_s` consume contract.
- Design: a `wb_post` strobe asserted at a CPU slot when the CPU's current op is a
  SuperRAM store (`scpu_fast_path='1' and cs_ram='1' and cpuWe='1'`) AND the
  buffer is free. `wb_post`:
  1. captures `{supercpu_bank, c64_addr(=ramAddr), cpuDo}` into the 1-entry buffer,
  2. drives an enable to the CPU **without** setting `cpu_cyc` (so `ramCE` stays
     low and `sdram_busy_cnt` is NOT loaded), via a dedicated OR into the
     `enableCpu`/consume path — phased to match the existing `cpu_cyc_s(1)` timing
     so the CPU sees the same handshake shape it does for a normal access.
- This is the riskiest edit. Prototype it in GHDL (below) and STA-check the new
  enable path before any HW build. Register every strobe (`wb_post_r`,
  `wb_drain_r`) — never combinational `ramCE`.

## Buffer + correctness rules
- **1 entry**, dedicated in the arbiter (NOT cpu_cache's 16-entry FIFO — that has
  no `wb_bank` port and `wb_enable` is tied off; lighter to build fresh).
  Fields: `wb_valid`, `wb_bank(7:0)`, `wb_addr(15:0)`, `wb_data(7:0)`.
- **Scope: SuperRAM only** (`scpu_fast_path` = bank $02+, excludes bank $00/$01,
  cs_io, color RAM, DMA). This makes `{bank,addr}` a 1:1 physical SDRAM map →
  Codex's "RAW must use physical address" is satisfied; mirrors/aliases excluded.
- **RAW-forward:** a CPU read with `scpu_fast_path='1'` whose `{bank,addr}` ==
  `{wb_bank,wb_addr}` and `wb_valid='1'` returns `wb_data` (combinational compare
  into the cpuDi mux), NOT an SDRAM read. Bank differs ⇒ no false hit for bank-$00.
- **WAW-stall:** a 2nd SuperRAM store while `wb_valid='1'` does NOT post — it falls
  back to the normal busy-gated `cpu_cyc` path (stalls one slot until drain clears
  `wb_valid`). Simplest correct policy for 1 entry.
- **Drain-before-conflict:** before any I/O access and before the buffer would be
  overwritten, drain. Drain target = idle EXT4–EXT7 / DMA0–DMA3 (harness-confirmed
  free with no cart/REU). Drain via `wb_drain_r` (registered) overriding the SDRAM
  controller inputs in **c64.sv** with `{1'b1, wb_bank, wb_addr}` + `wb_data` + we
  (the 25-bit addr can't ride the 16-bit `ramAddr`; bank is assembled in c64.sv at
  `scpu_sdram_addr`, c64.sv:1143). Clear `wb_valid` on drain completion.
- **Drain vs CPU read contention:** the drain is a real SDRAM transaction; it must
  finish (auto-precharge) before the next `cpu_cyc` SDRAM slot. Confine drain to
  the idle EXT/DMA window and, if needed, make a pending drain also block the next
  `cpu_cyc` via `sdram_busy` so a CPU read never collides with an in-flight drain.

## Mandatory GHDL test (Codex's single most important case)
In `sim/c64_reduced_harness` with `clk64_sdram_model.vhd` (latency-faithful,
models writes at :106-108, 5-clk64 read latency at :95):
1. Launch a real SDRAM read **miss**.
2. Accept a posted SuperRAM write while `sdram_busy_cnt /= 0`.
3. Immediately issue a read to a **different row/bank**.
4. Assert: **no `enableCpu` fires until the clk64 model `data_valid`** for that
   read — i.e. the posted write did NOT let the following read consume early.
Plus: a RAW-forward MATCH case (read same {bank,addr} → gets `wb_data`) and a
NON-match case (different addr → gets SDRAM). Run with `WRITE_BUFFER` ON and OFF;
both must be byte-correct. Toggle via a constant patched by the run script (same
`sed`-on-staging-copy pattern as `CACHE_READ_PATH`/`CLK64_SDRAM` in
`run_superram_coherency.sh`). If the bench cannot exercise the post (writes turn
out to have a hidden return dependency) → STOP, do not build.

## Files to touch (when A1 says GO)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — `WRITE_BUFFER` constant; 1-entry buffer
  regs; `wb_post`/`wb_drain_r` strobes; the separate enable path; RAW-forward into
  cpuDi mux; expose `wb_*` on new entity ports.
- `C64_MiSTer/c64.sv` — drain mux on `scpu_sdram_addr`/`cart_wrdata`/we (~:1105,
  :1143); route new `wb_*` ports.
- `sim/c64_reduced_harness/` — new tb (model on `c64_superram_coherency_tb.vhd` +
  `c64_reduced_top_v2`), run script patching `WRITE_BUFFER`.
- STA: confirm the new enable path closes at 32 MHz before HW.

## HW gate (one build only, after GHDL green)
A/B vs shipped `3698680a`: boot READY + SCPU64 V0.07; idle PC range $E5CD–$E5D6
(not pinned); `sweep_sst.ps1 -All` = 0/5.12M; Lorenz scpu+t65 clean ~8min; Doom
autoloads to title/menu; effective-MHz delta positive. Commit on green (push gated).

## Track-D note resurfaced by VICE B3
VICE models a 2–8 KB DRAM row; ours is 256 bytes (only `c64_addr[7:0]` sequential).
iter-29's 54% locality was against that tiny row. A column remap to a wider row
(`c64_addr[8:0]`+ → ≥512 B) could push locality well above the ~50% break-even and
revive page-mode — but only pays *with* a page-mode controller and risks REU/VIC
layout. Defer; re-measure with `pagehit_probe.py` if Track C succeeds and we want
to stack cadence levers on an open-row controller.
