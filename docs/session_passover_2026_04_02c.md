# Session Passover 2026-04-02c: Two SuperRAM Regressions Found, Fixed, Verified

## Goal
Get Doom C64 (doom.reu) running on the MiSTer SuperCPU core by executing from SuperRAM bank $20.

## Summary
Found and fixed two regressions introduced in commit c2ddf69 that completely broke SuperRAM reads. Also found and removed a crash latch bug from a2307b5. SuperRAM STA/LDA round-trip now verified working on hardware.

## Root Causes Found

### Regression 1: Registered SuperRAM Address (c2ddf69)
**What**: `scpu_sdram_addr` was changed to use `scpu_superram_addr_r` (registered) instead of `scpu_superram_addr` (combinational). This added a 1 clk32 cycle latency.
**Effect**: All SuperRAM STA long / LDA long round-trips returned 0.
**Fix**: Reverted to combinational `scpu_superram_addr` in c64.sv line ~1308.
**Location**: `C64_MiSTer/c64.sv` around line 1296-1310

### Regression 2: BRAM 1MHz Fix (c2ddf69)
**What**: Three changes removed `turbo_en` gating from `bram_hit_d1`:
1. `enableCpu_816`: removed `and turbo_en` from bram_hit_d1 term
2. BRAM hit suppress: removed `scpu_speed_1mhz/scpu_sys_1mhz/iec_slow_mode` checks
3. Pipeline cancel: changed to `(bram_hit_d1) or ((cache_hit_d1 or phantom_enable) and turbo_en)` — bram_hit_d1 no longer gated by turbo_en

**Effect**: Even after fixing the registered address, SuperRAM reads still returned 0. The ungated bram_hit_d1 was disrupting the SDRAM pipeline during SuperRAM instruction cycles.
**Fix**: Reverted all three BRAM 1MHz changes.
**Location**: `C64_MiSTer/rtl/fpga64_sid_iec.vhd` lines ~1153, ~1514-1519, ~1980
**TODO**: The BRAM 1MHz fix needs to be redesigned. Suggested approach: gate bram_hit_d1 on `not superram_in_pipeline` instead of removing turbo_en entirely.

### Bug 3: Crash Latch Override (a2307b5)
**What**: The crash latch process overrode `dbg_cpu_addr` with latched values when a bank>$00→$00 transition was detected.
**Effect**: Since `dbg_cpu_addr` feeds `scpu_superram_addr = {1'b1, supercpu_bank, dbg_cpu_addr}`, ALL subsequent SuperRAM SDRAM reads went to the wrong (frozen) address.
**Fix**: Removed crash latch process entirely. Now:
```vhdl
dbg_cpu_addr <= cpuAddr_pre;
dbg_cpu_data <= cpuDo_pre;
```
**Location**: `C64_MiSTer/rtl/fpga64_sid_iec.vhd` around line 1580
**Rule**: NEVER override `dbg_cpu_addr` — it's a functional signal, not just debug.

## SDRAM Byte Position Discovery
All SuperRAM writes (io_cycle, STA long, ioctl) use bt=1 (addr[24]=1).
In sdram.v, DQM = {~bt & wr, bt & wr} = {0, 1} when bt=1, wr=1:
- sd_dqm[1]=0 → HIGH byte written
- sd_dqm[0]=1 → LOW byte masked

So data lives in the **HIGH byte** (dout_r[15:8]) for all SuperRAM writes.
At capture time (CPUE/CPUF), bt=1 → `sdram_raw = dout_r[15:8]` = correct.
`sdram_lo` (dout_r[7:0]) = WRONG for SuperRAM.

## Verified Test Results (current deployed build)
```
STA long $42 to $020100 → LDA long $020100 = 66 ($42)  ✓
POKE $DF1D,170 → LDA long $020000 = 170 ($AA)          ✓
C64 boots normally, KERNAL idle, E:1, T:21               ✓
```

## Current Working Directory State
Starting from HEAD (a2307b5), with these changes applied:

### c64.sv changes (vs a2307b5):
- Line ~1296-1310: Reverted `scpu_superram_addr_r` → combinational `scpu_superram_addr`
  ```systemverilog
  // SDRAM address mux MUST be combinational
  wire [24:0] scpu_superram_addr = {1'b1, supercpu_bank, dbg_cpu_addr};
  wire [24:0] scpu_sdram_addr = (supercpu_enable && cpu_has_bus && (supercpu_bank != 8'h00))
                                 ? scpu_superram_addr  // NOT _r
                                 : cart_addr;
  ```

### fpga64_sid_iec.vhd changes (vs a2307b5):
1. **Crash latch removed** (~line 1580): Replaced 35-line process with:
   ```vhdl
   dbg_cpu_addr <= cpuAddr_pre;
   dbg_cpu_data <= cpuDo_pre;
   ```

2. **enableCpu_816** (~line 1153): Restored turbo_en gate:
   ```vhdl
   enableCpu_816 <= ((bram_hit_d1 and turbo_en and not at_cpucd) or ...
   ```

3. **BRAM hit suppress** (~line 1514): Restored 1MHz speed checks:
   ```vhdl
   and scpu_speed_1mhz = '0'
   and scpu_sys_1mhz = '0'
   and iec_slow_mode = '0'
   ```

4. **Pipeline cancel** (~line 1980): Restored turbo_en gate for all:
   ```vhdl
   if (cache_hit_d1 = '1' or bram_hit_d1 = '1' or phantom_enable = '1') and turbo_en = '1' then
   ```

5. **cpuDi mux** (~line 798): Changed back to direct sdram_raw:
   ```vhdl
   sdram_raw when (enableCpu = '1' and superram_in_pipeline = '1' and cpuWe_pre = '0') else
   ```

### sdram.v changes (vs a2307b5): NONE (dout_hi/dout_lo/superram_hold kept)

## Unchanged from a2307b5 (KEPT)
- `and not superram_in_pipeline` guard on cache_fill_we
- `cache_fill_data` signal (muxed fill source)
- sdram_hi, sdram_lo, sdram_superram ports in entity/c64.sv
- superram_hold register in sdram.v (captures dout_r[7:0] at STATE_READ+1 when bt=1)
- superram_data_r signal exists but cpuDi mux uses sdram_raw directly instead

## Build Info
- Last successful build: 2026-04-02 11:36, Fitter Successful
- ALMs: ~30,100 (72%), RAM blocks: 496/553 (90%)
- Currently deployed and tested on MiSTer

## NOT YET COMMITTED
All changes are in the working directory only. Need to commit.

## Next Steps (Priority Order)
1. **Commit** the current working fixes
2. **Load doom.reu** via OSD and test Doom execution with the fixed SuperRAM path
3. **Redesign BRAM 1MHz fix**: The original fix (removing turbo_en from bram_hit_d1) broke SuperRAM. New approach: add `and not superram_in_pipeline` to bram_hit_d1 in enableCpu_816, keeping the turbo_en removal but guarding against SuperRAM interference
4. **SuperRAM hold register**: The hold register in sdram.v is built but untested (crash latch + BRAM bugs masked all results). May improve timing for sustained SuperRAM execution
5. **Doom testing**: After doom.reu loads, use skip-loader POKEs to JML $200000

## doom.reu Loading (for next session)
- doom.reu exists at: /media/usb0/games/C64/doom.reu (USB, 16MB) and /media/fat/games/C64/doom.reu (SD, 16MB)
- **OSD approach**: F12 → "Load REU *.REU" (2nd item, down+enter) → file browser → select doom.reu
- **mbc approach**: Does NOT work after direct deploy (verified)
- **SD card data bug**: Previous sessions noted SD sends counter values for .reu files; USB works
- OSD navigation via mtype.py: F12 opens OSD, down/enter navigates, 'd' jumps to doom.reu in file browser
- OBS capture needed for OSD screenshots (MiSTer screenshot doesn't capture OSD overlay)

## Remote Testing State
- MiSTer IP: 192.168.50.130, SSH root/1 (use paramiko with look_for_keys=False)
- mtype.py: uploaded at /tmp/mtype.py (6s device setup wait)
- mister_debug.py: deploy/screen/uart/keys/osd_screen
- UART baud: 115200 (set via stty)

## Key Architecture Rules (reinforced by today's findings)
1. **SDRAM address mux MUST be combinational** — registering breaks STA/LDA
2. **NEVER override dbg_cpu_addr** — it feeds the SDRAM address path
3. **SuperRAM data is in HIGH byte** (dout_r[15:8]) — use sdram_raw with bt=1, not sdram_lo
4. **bram_hit_d1 must be guarded** during SuperRAM pipeline — ungated hits disrupt SDRAM reads
