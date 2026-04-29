# Session Passover: REU I/O Read Pipeline Fix (2026-03-26)

## Context
Working on getting REU register reads ($DF00-$DFFF) to work from assembly code on the MiSTer C64 SuperCPU core. This is needed for REU DMA and ultimately for running Doom.

## Root Cause Found
The P65C816 CPU updates its address bus at the same clock edge as `enableCpu`, creating a timing race in the combinational `cpuDi` data mux. The bus logic's IOF→io_ext→dataToCpu path has -10ns timing violations on clk32. VIC reads ($D020) work because they don't need io_ext. REU reads ($DF00) fail because they go through the full io_ext path.

## Current Architecture (COMMITTED, boots cleanly)
All changes are in `C64_MiSTer/rtl/fpga64_sid_iec.vhd` and `C64_MiSTer/c64.sv`.

### IOF-only 3-stage I/O Pipeline
- `io_in_pipeline` flag: set for $DFxx reads ONLY (NOT all $Dxxx — that broke VIC raster timing)
- Uses SuperRAM's 3-stage pipeline path (extra cycle for data settling)
- `io_data_r`: captures data from c64.sv io_data port (registered, bypasses bus logic)
- `io_read_deliver = registered(enableCpu AND io_in_pipeline)`: 1-cycle pulse for cpuDi mux
- cpuDi mux: `io_data_r when io_read_deliver='1'` at TOP priority (above bram_do)
- `io_in_pipeline` cleared at BRAM cancel AND at enableCpu delivery
- `iof_detect` / `iof_detect_d1`: IOF detect from cpuAddr_pre (registered, no bus logic)

### BRAM Suppression
- `at_cpucd`: suppresses BRAM hits in `enableCpu_816` at CPUA through CPUD
- Prevents BRAM from racing cpu_cyc at CPUC (the I/O slot)
- `IOF_raw` = simple detect from cpuAddr_pre (bypasses bus logic timing path)

### c64.sv Changes
- `reu_oe` = c64_addr-based (bypasses IOF bus logic path)
- `io_ext_r` / `io_data_r_sv` = registered io_ext/io_data (stable, breaks timing path)
- These registered versions go to fpga64_sid_iec ports

## Current Reliability
- **3/5 to 3/8 boots** show ALL 3 REU reads delivering $FF (reu_dout default)
- Remaining boots show $00 (pipeline doesn't fire due to boot-dependent BRAM timing)
- When pipeline fires: ALL reads consistently deliver (no per-read variation)
- The $FF is from REU cpu_din reset default (REU register read logic doesn't fire)

## Key Remaining Issues

### 1. Boot-dependent BRAM timing alignment (~60% success rate)
The BRAM hit from the previous instruction's fetch can fire at a cycle that prevents the IOF detection at CPUC. The 4-cycle suppression window (CPUA-CPUD) helps but doesn't guarantee alignment.

**Current approach being tested**: Combined primary (cpu_cyc at CPUC) + fallback (iof_detect rising edge at any cycle) detection. BUILD IN PROGRESS at time of passover.

### 2. REU cpu_din stays at $FF
The REU module's register read logic (`~old_cs & cpu_cs` rising edge in reu.v) never fires despite IOF_raw (simple detect from cpuAddr_pre) being connected. Even unconditional `cpu_din <= 8'h42` showed $FF — synthesis optimized it away when the downstream path was the broken reu_di port. Now that io_data path is used (existing port), this needs retesting.

### 3. REU DMA STASH still doesn't write to SDRAM
This is the ORIGINAL issue from session 1. The IOF read pipeline work was a prerequisite but DMA SDRAM writes are a separate issue with the cart_ce/SDRAM mux during DMA.

## Critical Design Constraints Discovered
1. **$DFxx ONLY** for 3-stage pipeline — ALL $Dxxx breaks VIC raster timing
2. **io_in_pipeline MUST have `else '0'`** at cpu_cyc — persistence garbles display
3. **io_read_deliver must use SDRAM enableCpu** not BRAM enableCpu_816
4. **Quartus 17.0 new VHDL port bug** — can't add new ports from SV→VHDL
5. **Must use EXISTING ports** for cross-language data (io_ext, io_data work)
6. **Register io_ext/io_data in c64.sv** to break timing-violated bus logic path
7. **IOF_raw = simple detect** from cpuAddr_pre for REU chip select
8. **Capture at enableCpu with io_ext guard** — only update when REU visible
9. **BRAM suppression CPUA-CPUD** via registered sysCycle check in enableCpu_816
10. **turbo_en defaults to '1'** despite OSD config (MGL reload doesn't apply C64.cfg)

## Commits This Session
```
3d82df6 Use iof_detect edge + enableCpu capture for IOF pipeline
5a28c1f Widen BRAM suppression to CPUA-CPUD for IOF pipeline reliability
295db8e Improve IOF pipeline: registered io_ext/io_data, CPUE fallback, direct capture
f726ec0 Fix IOF pipeline reliability: suppress BRAM at CPUC+CPUD
e8dd173 Add IOF-only 3-stage I/O pipeline for REU register reads
5229190 Revert broken I/O pipeline commits (garbled display)
```

## Files Modified
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — Primary: io_in_pipeline, io_data_r, io_read_deliver, iof_detect, at_cpucd, enableCpu_816 suppression
- `C64_MiSTer/c64.sv` — reu_oe, io_ext_r, io_data_r_sv registration
- `C64_MiSTer/rtl/reu.v` — cleaned up test code only (no functional changes)

## Uncommitted Changes (build in progress)
`fpga64_sid_iec.vhd` has a combined primary + fallback IOF detection approach:
- Primary: cpu_cyc at CPUC with iof_detect check
- Fallback: iof_detect_d1 rising edge at any cycle
This needs testing after the build completes.

## Test Programs
- `tools/test_cart/reu_read_test.prg` — reads BD ($D020), R0 ($DF00), R1 ($DF01), R4 ($DF04 write/readback)
- `tools/test_cart/reu_asm_test.prg` — REU DMA STASH/FETCH round-trip test
