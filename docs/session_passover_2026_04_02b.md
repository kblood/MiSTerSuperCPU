# Session Passover 2026-04-02b: Two SuperRAM Regressions Found and Fixed

## Goal
Get Doom C64 (doom.reu) running on the MiSTer SuperCPU core by executing from SuperRAM bank $20.

## Key Findings

### Regression 1: Registered SuperRAM Address (c2ddf69)
The `scpu_superram_addr_r` register added in c2ddf69 introduced a 1 clk32 cycle
latency in the SDRAM address path. This broke STA long/LDA long round-trips:
- 8f580b8 (combinational): writes $42, reads back $42 (correct)
- c2ddf69 (registered): writes $42, reads back $00 (broken)

**Fix**: Reverted to combinational `scpu_superram_addr` in scpu_sdram_addr mux.

### Regression 2: BRAM 1MHz Fix (c2ddf69)  
Removing `turbo_en` gating from `bram_hit_d1` in `enableCpu_816` disrupted the
SDRAM pipeline during SuperRAM reads. Even after fixing the registered address,
SuperRAM reads returned 0. Reverting all three BRAM 1MHz changes restored correct
behavior.

The BRAM 1MHz fix needs to be redesigned with a `not superram_in_pipeline` guard.

### Bug 3: Crash Latch Overriding dbg_cpu_addr (a2307b5)
The crash latch process overrode `dbg_cpu_addr` with latched values. Since
`dbg_cpu_addr` feeds `scpu_superram_addr = {1'b1, supercpu_bank, dbg_cpu_addr}`,
this broke all SuperRAM SDRAM addresses when the latch triggered.

**Fix**: Removed crash latch override. `dbg_cpu_addr <= cpuAddr_pre` always.

## SDRAM Byte Position: HIGH Byte
All SuperRAM writes use bt=1 (addr[24]=1). DQM={0,1} masks LOW byte.
Data is in HIGH byte (dout_r[15:8]). At CPUE capture time, bt=1, so
sdram_raw = dout_r[15:8] = correct. sdram_lo = LOW byte = WRONG.

## Verified Test Results
- STA long $42 → LDA long = **66** ($42) ✓  
- POKE $DF1D,170 → LDA long = **170** ($AA) ✓
- C64 boots normally, KERNAL idle, T:21 ✓

## Current Build State
- cpuDi: direct `sdram_raw` at enableCpu (matching 8f580b8)
- SDRAM addr: combinational (no register)
- BRAM: turbo_en gating restored (1MHz fix needs redesign)
- Cache fill: `and not superram_in_pipeline` guard  
- Crash latch: removed
- sdram_hi/lo/superram_dout ports: present (unused)

## Files Modified (relative to HEAD = a2307b5)
- `c64.sv`: Reverted scpu_superram_addr_r to combinational
- `fpga64_sid_iec.vhd`:
  - Removed crash latch process
  - Reverted enableCpu_816 bram_hit_d1 turbo_en gate
  - Restored 1MHz speed checks in bram_hit_d1 generation
  - Reverted pipeline cancel to require turbo_en for all
  - Changed cpuDi from superram_data_r to sdram_raw

## Next Steps
1. **Load doom.reu** via OSD and test Doom execution
2. **Redesign BRAM 1MHz fix**: gate bram_hit_d1 on `not superram_in_pipeline`
   instead of removing turbo_en entirely
3. **Commit** the working fixes
4. **SuperRAM hold register**: test for timing improvement (data valid at CPUF)

## Remote Testing
- MiSTer IP: 192.168.50.130, SSH root/1
- doom.reu: /media/usb0/games/C64/doom.reu (USB) and /media/fat/games/C64/doom.reu (SD)
- mtype.py: keyboard via uinput (upload to /tmp/mtype.py)
- OSD: F12 via mtype.py, OBS capture for OSD screenshots
