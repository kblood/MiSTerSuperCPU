# Session Passover 2026-04-02e: SuperRAM Read Regression Fixed, VICE Architecture Researched

## Goal
Fix Doom C64 crash, implement SuperCPU ROM properly.

## Summary
Found and fixed a SuperRAM LDA long regression that had been broken since commits ccb5ab3/96e9262. Researched VICE's SuperCPU implementation to understand correct ROM mapping. Identified that our ROM decode approach was wrong — VICE uses bootmap + kernal shadow, not rom_vis for $E000-$FFFF.

## Commits
- `9833fce`: Fix SuperRAM LDA long regression: restore superram_data_r in cpuDi mux

## Key Findings

### 1. SuperRAM LDA Long Regression (ROOT CAUSE + FIX)
**Symptom**: `STA $020100 ($42) → LDA $020100` returned 0 (expected 66).
Broken on HEAD (96e9262), NOT by the pipeline fix or ROM decode fix attempted this session.

**Two regressions stacked**:
1. **ccb5ab3** changed `superram_data_r` capture from `sdram_raw` to `sdram_lo`
   - SuperRAM addr = `{1'b1, bank, addr16}`, so addr[24]=1 → bt=1 → data in HIGH byte
   - `sdram_lo = dout_r[7:0]` = LOW byte = WRONG byte
   - `sdram_raw = bt ? hi : lo` = HIGH byte = CORRECT (when bt=1)
2. **96e9262** changed cpuDi mux from `superram_data_r` to `sdram_raw`
   - At enableCpu time (EXT0), io_cycle CE fires and flips bt → sdram_raw returns wrong byte
   - The `superram_data_r` latch captures at CPUE (before bt flip) specifically to avoid this

**Fix** (2 lines in fpga64_sid_iec.vhd):
- Line 798: `sdram_raw` → `superram_data_r` in cpuDi mux
- Line ~2055: `sdram_lo` → `sdram_raw` in superram_data_r capture latch
- Restores the d3b403d behavior that was verified working on 2026-03-29

**Hardware verified**: PEEK(2) = 66 after STA/LDA round-trip to bank $02

### 2. VICE SuperCPU Architecture (NEW UNDERSTANDING)
Read VICE source code (scpu64mem.c, scpu64meminit.c, scpu64rom.c):

**Memory model**: 64KB internal RAM + 128KB SRAM (bank 0+1) + 16MB SIMM
**Config byte** (256 combos): bootmap(7), dosext(6), hwenable(5), !game(4), !exrom(3), loram/hiram/charen(0-2)

**Key registers**:
- `$D07E`: ANY write → hwenable=1 (strobe, data irrelevant) — we incorrectly use bit 7
- `$D07F/$D07D`: ANY write → hwenable=0
- `$D0B6`: write → bootmap=0 (requires hwenable=1) — NOT IMPLEMENTED
- `$D0B7`: write → bootmap=1 (requires hwenable=1) — NOT IMPLEMENTED

**Boot sequence**:
1. Reset: bootmap=1, hwenable=0 → $8000-$FFFF maps to EPROM
2. Kickstart runs from bank $F8 (always EPROM)
3. Copies KERNAL from EPROM offset $4100 to SRAM $8000 ("kernal shadow")
4. Writes $D07E (hwenable=1), $D0B6 (bootmap=0)
5. $E000-$FFFF now served from kernal shadow at 20MHz

**$E000-$FFFF mapping** (NOT via rom_vis):
- bootmap=1: EPROM (during boot only)
- bootmap=0, hwenable=1: kernal shadow (SRAM $8000+)
- bootmap=0, hwenable=0, hiram=1: kernal trap/shadow
- bootmap=0, hwenable=0, hiram=0: SRAM bank 0

### 3. ROM Decode Fix Was Wrong (REVERTED)
- Adding `cpuAddr(15 downto 13) = "111"` to scpu_rom_en was incorrect
- VICE uses bootmap for $E000-$FFFF, not rom_vis
- Reverted; only added a comment explaining the correct approach

### 4. Pipeline Fix for Doom (NOT YET APPLIED)
The `superram_in_pipeline` drain guard was coded and syntax-checked but reverted during debugging. Now that the baseline LDA long works, it can be re-applied and tested. The interleaved bank $00/$02 STA/LDA pattern (Doom's crash trigger) needs this fix.

## Build State
- Current build: 9833fce (cpuDi fix), deployed and tested on MiSTer
- Build tool: `powershell.exe -File build_c64.ps1` (don't pipe output — breaks build)
- Background builds with `2>&1 | tail` cause incomplete builds (analysis only, no fitter)

## Next Steps (Priority Order)
1. **Pipeline drain guard**: Re-apply the `superram_in_pipeline` fix for interleaved bank access
   - Test with: `STA $020100 → STA $000500 → LDA $020100` (should return 66)
   - Code was written and syntax-checked; reverted during debugging
2. **Implement bootmap register** ($D0B6/$D0B7): proper $E000-$FFFF boot mapping
3. **Fix $D07E strobe behavior**: any write = hwenable, not bit-7 dependent
4. **Implement kernal shadow**: SRAM region for $E000-$FFFF native mode vectors
5. **Re-test Doom** with pipeline fix + ROM improvements

## Remote Testing State
- MiSTer IP: 192.168.50.130, SSH root/1
- mtype.py at /tmp/mtype.py (working, use paramiko SSH with timeout=30)
- doom.reu at /media/usb0/games/C64/doom.reu
- Test pattern: BASIC DATA+POKE+SYS via mtype.py (single invocation, 5 lines per batch)
- SYS address for ca65 PRGs with c64-816.cfg: 2061

## Key Lessons Learned
- `sdram_lo` is WRONG for SuperRAM: addr[24]=1 means data is in HIGH byte of SDRAM word
- `sdram_raw` is correct at CPUE (before io_cycle bt flip) but wrong at EXT0 (after flip)
- `superram_data_r` latch exists specifically to bridge this timing gap
- PowerShell build script breaks when output is piped (`2>&1 | tail`) — only does analysis
- BASIC DATA lines entered without line numbers are NOT accessible by READ in direct mode
