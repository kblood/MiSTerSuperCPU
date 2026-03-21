# REU DMA Solutions Analysis

## Problem
REU DMA STASH/FETCH data doesn't survive SDRAM write/read via ext_cycle path.
65816 long addressing to the same SDRAM region works perfectly.

## Simulation Results
- Simplified model: ALL TESTS PASS (both CPU and REU paths work)
- Full bus rotation model: WRITE ADDRESS MISMATCH (addr=0 instead of expected)
- The `io_cycle_ce` at EXT0 is always IGNORED (q=6, SDRAM busy from CPUC)
- The `reu_ram_ce` at DMA0 IS accepted (q=0)

## Root Cause Candidates

### 1. Clock Domain Crossing (clk_sys 32MHz ↔ clk64 64MHz)
The reu_ram_ce is generated at clk_sys but the SDRAM runs at clk64.
The 1-cycle pulse at 32MHz spans 2 cycles at 64MHz. The rising-edge
detector should catch it, but subtle metastability could cause misses.
**Likelihood: LOW** (cart_ce has the same crossing and works)

### 2. io_cycle_ce Collision at EXT0
Every rotation, io_cycle_ce fires at EXT0 (falling edge of io_cycle).
This is always IGNORED because q=6 from the CPUC access. But on real
hardware, the ignored CE might corrupt the SDRAM's state or address latch.
**Likelihood: MEDIUM** (the simulation shows it's ignored, but real SDRAM
might handle it differently)

### 3. REU Module Timing
The REU module sets ram_addr/ram_we/ram_dout BEFORE entering STATE_PROC_RAM.
But these are registered at clk_sys. The SDRAM latches them at the clk64
edge when reu_ram_ce fires. If the REU signals haven't propagated through
the clk_sys→clk64 domain, the SDRAM latches stale values.
**Likelihood: MEDIUM** (the signals are stable for multiple clk_sys cycles
before DMA0, so they should be propagated)

### 4. SDRAM Mux Glitch on ext_cycle Transition
When ext_cycle transitions from 0→1 at DMA0, the mux output switches
from cart_addr to reu_ram_addr. This is combinational. At the clk64
edge that catches the CE, the addr mux might still be settling from the
cart_addr to reu_ram_addr, causing the SDRAM to latch the wrong address.
**Likelihood: HIGH** (simulation showed addr=0 at DMA0, matching this theory)

### 5. Quartus Optimization Removing the Path
The synthesizer might optimize away the ext_cycle SDRAM path because
it determines that reu_ram_ce can never fire (if it analyzes the
logic and concludes dma_req is always '0' in the static analysis).
**Likelihood: LOW** (the REU status shows DMA executed)

## Proposed Solutions (in priority order)

### Solution A: Register the SDRAM mux outputs at clk64
Add pipeline registers at clk64 for addr/ce/we/din BEFORE the SDRAM
module. This eliminates combinational glitches on mux transitions.
```verilog
reg [24:0] sd_addr_r;
reg        sd_ce_r, sd_we_r;
reg [7:0]  sd_din_r;
always @(posedge clk64) begin
    sd_addr_r <= addr_mux;
    sd_ce_r   <= ce_mux;
    sd_we_r   <= we_mux;
    sd_din_r  <= din_mux;
end
// Feed registered signals to SDRAM
sdram sdram(.addr(sd_addr_r), .ce(sd_ce_r), .we(sd_we_r), .din(sd_din_r), ...);
```
This adds 1 clk64 cycle of latency but ensures clean signals.
**Complexity: LOW, Risk: LOW**

### Solution B: Generate reu_ram_ce at clk64 instead of clk_sys
Register ext_cycle and dma_req into the clk64 domain, then generate
reu_ram_ce at clk64. This ensures the CE pulse is synchronous with
the SDRAM module.
```verilog
reg ext_cycle_64, ext_cycle_64_d, dma_req_64;
always @(posedge clk64) begin
    ext_cycle_64   <= ext_cycle;
    ext_cycle_64_d <= ext_cycle_64;
    dma_req_64     <= dma_req;
end
wire reu_ram_ce = ~ext_cycle_64_d & ext_cycle_64 & dma_req_64;
```
**Complexity: LOW, Risk: LOW**

### Solution C: Steal CPU SDRAM slot for REU DMA
When dma_req is active, hijack the CPUC SDRAM slot for REU SDRAM
access. Use cart_ce (which works) but route reu_ram_addr through it.
This was partially implemented but needs the REU module's ram_cycle
to also be changed to fire during the CPU phase.
**Complexity: MEDIUM, Risk: MEDIUM** (changes DMA timing)

### Solution D: Bypass REU DMA entirely for Doom
Write a custom loader using 65816 MVN block moves to copy doom.reu
data from SuperRAM to C64 RAM. This avoids REU DMA completely.
**Complexity: MEDIUM, Risk: LOW** (but only fixes Doom, not general REU)

### Solution E: Implement custom REU DMA in VHDL
Replace reu.v's SDRAM path with a custom VHDL implementation that
uses the CPU's working SDRAM mechanism. The REU module's C64 bus
side stays the same, but SDRAM access goes through cart_ce.
**Complexity: HIGH, Risk: MEDIUM**

## Recommendation
**Try Solution A first** (register mux outputs at clk64). It's the
simplest change, addresses the likely root cause (mux glitch on
ext_cycle transition), and has the lowest risk of breaking other things.

If A doesn't work, try **Solution B** (generate CE at clk64).
If neither works, fall back to **Solution C** (steal CPU slots).
