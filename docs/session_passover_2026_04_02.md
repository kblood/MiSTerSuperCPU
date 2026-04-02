# Session Passover 2026-04-02: Cache Fill Fix + SDRAM Data Path Investigation

## Goal
Get Doom C64 (doom.reu) running on the MiSTer SuperCPU core by executing from SuperRAM bank $20.

## Key Accomplishments

### 1. Cache Fill Bug Fixed
**Root cause found and fixed**: The cache `fill_data` port was connected to `cpuDi_raw`
(buslogic output), which returns bank $00 data for SuperRAM addresses. When the CPU
read from bank $20 via SDRAM, the cache filled with WRONG bank $00 data. Subsequent
cache hits served this wrong data, causing crashes.

**Fix**: Added `and not superram_in_pipeline` to `cache_fill_we` in fpga64_sid_iec.vhd:
```vhdl
cache_fill_we <= enableCpu and not wb_drain_active and not cpuWe_pre
                 and bram_valid_cycle
                 and not scpu_rom_overlay
                 and not superram_in_pipeline  -- NEW: prevent cache poisoning
                 and baLoc;
```

### 2. NOP Debug Proves Pipeline Correct
Forced `cpuDi = x"EA"` (NOP) for all SuperRAM reads. CPU ran at bank $20 indefinitely
without crashing. UART confirmed: B:20, I:EA, E:0 (native mode), stable.
**Conclusion**: Pipeline/bank handling, 3-stage timing, and bank switching all work correctly.

### 3. SDRAM Byte-Select Investigation
Discovered that the SDRAM data byte position differs between read paths:
- `sdram_raw` (combinational, bt-dependent): Returns LOW byte when bt=0 at EXT0. **Works** — Doom gets yellow screen.
- `superram_data_r` (registered at CPUF with bt=1): Returns HIGH byte = $80 (wrong). CPU stuck.
- `sdram_hi` (dout_r[15:8], bt-independent): Returns HIGH byte = $80 (wrong). CPU stuck.

The correct data ($78) is in the **LOW byte** of the SDRAM word. `sdram_raw` picks it up
because bt changes from 1→0 at EXT0 (io_cycle CE fires with bank $00 addr[24]=0).

### 4. Added sdram_hi Port to sdram.v
New `dout_hi` output provides registered high byte (dout_r[15:8]) independent of bt.
Currently unused in cpuDi (sdram_raw is used), but available for future investigation.

## Current Build State
- **Cache fill fix**: Applied (and not superram_in_pipeline)
- **cpuDi SuperRAM path**: sdram_raw (combinational)
- **sdram_hi port**: Added to sdram.v, connected in c64.sv/fpga64_sid_iec.vhd
- **Build result**: 30,111 ALMs (72%), BUILD SUCCESSFUL
- **Test result**: Yellow screen (Doom partially executes), then crash to BRK

## Files Modified
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`:
  - Cache fill fix (line ~1296): `and not superram_in_pipeline`
  - sdram_hi port added
  - cpuDi uses sdram_raw for SuperRAM (line ~795)
- `C64_MiSTer/rtl/sdram.v`:
  - Added `dout_hi` output (dout_r[15:8], bt-independent)
- `C64_MiSTer/c64.sv`:
  - Connected sdram_data_hi from SDRAM to fpga64_sid_iec

## The Mystery: Why is Data in LOW Byte?
When mbc load_rom loads doom.reu, it writes through the FPGA's SDRAM controller.
For REU addresses (addr[24]=1), bt=1, DQM = {~bt&wr, bt&wr} = {0, 1}.
- sd_dqm[1] = 0 → HIGH byte NOT masked (written)
- sd_dqm[0] = 1 → LOW byte MASKED

So WRITES go to HIGH byte. But READS show data in LOW byte. This contradicts
the DQM analysis. Possible explanations:
1. The DQM bit assignment (sd_addr[12:11]) maps differently to physical DQM pins
2. The SDRAM chip on DE10-Nano has inverted DQM polarity
3. mbc load_rom doesn't use the FPGA SDRAM controller (uses HPS SDRAM instead)

## Next Steps
1. **Determine byte position definitively**: Write a known pattern via io_cycle
   (POKE $DF1D), then read both bytes (dout_r[7:0] and dout_r[15:8])
2. **Fix the data path**: Once byte position is known, use the correct byte source
   (either sdram_raw with guaranteed bt=0, or explicit low byte output from sdram.v)
3. **Enable cache fills from correct data**: Use the correct byte as cache fill_data
   during SuperRAM reads. This would give cache-speed hits after first SDRAM read.
4. **Timing violations**: Still -15ns on clk64. The sdram_raw path relies on bt
   changing at EXT0 — this is fragile. A more robust path is needed.

## Remote Testing State
- mtype2.py daemon: started, PID running
- doom.reu: on USB at /media/usb0/games/C64/doom.reu
- doom_skip_poke.py: POKEs verified working
- MiSTer IP: 192.168.50.130, SSH root/1 (use paramiko with look_for_keys=False)

## UART Debug Fields
```
A:xxxx D:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx
A=addr D=cpuDo B=bank S=SP P=flags I=IR E=emul F=frame T=turbo C=hitcnt N=encnt
```
T bits: b0=turbo, b1=rom_vis, b2=1mhz, b3=iec, b4=overlay, b5=cache, b6=enCpu
