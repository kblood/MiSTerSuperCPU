# Session Passover 2026-04-01: Doom SuperRAM Execution Investigation

## Goal
Get Doom C64 (doom.reu) running on the MiSTer SuperCPU core by loading it into SuperRAM and executing from bank $20.

## What Works
1. **doom.reu loading via mbc**: `/media/fat/linux/mbc load_rom C64 /media/usb0/games/C64/doom.reu` loads 16MB REU data into SDRAM SuperRAM
2. **Individual LDA long reads**: SYS verify code reads bytes from bank $20:$0000-$0007, ALL return correct values (78 D8 18 FB C2 30 A9 00 = SEI CLD CLC XCE REP#30 LDA#$0000)
3. **1KB copier**: Code at bank $00 that reads bank $20 bytes via LDA [$FB],Y and copies to $4000 — data is correct, copied code executes (green screen)
4. **mtype2.py daemon**: Persistent virtual keyboard for remote BASIC input

## What Fails
- **JML $200000 (execute from bank $20)**: CPU enters native mode, executes some Doom init (green screen = VIC registers written), then crashes to BRK loop at bank $00 native mode vector ($FFE6/$FFE7)
- Crash happens with turbo enabled (T:20/28 in UART, not T:00)
- Doom's STA $DD0E/$DD0F (CIA2 timer ctrl) does NOT trigger iec_slow_mode (addr bits [3:2]="11", detection checks "00")

## Key Investigation Results

### iec_slow_mode is NOT the cause
- Detection only triggers on writes to $DD00-$DD03 (cpuAddr[3:2]="00") and reads of $DD00
- Doom writes to $DD0E/$DD0F which are Timer A/B Control, NOT the IEC port registers
- The T:08 seen in UART crash data is from BRK loop accidentally hitting CIA2 addresses

### SDRAM timing violations
- clk64: -15.4ns to -18.5ns slack (depending on build)
- clk32: -5.1ns to -6.9ns slack
- Registered SuperRAM address (`scpu_superram_addr_r`) improved timing from -18.5ns to -15.4ns
- But individual reads still work, suggesting timing violations alone aren't the cause

### 4-stage pipeline experiment
- Added `superram_enable_delay2` to give SDRAM one more clk32 cycle
- Worsened timing significantly (-21.8ns clk64, -12.4ns clk32)
- Still crashed — but test was invalid (POKEs lost after deploy, not re-entered)

### NOP debug experiment  
- Forced cpuDi = $EA for all cache_cpu_bank > $00 reads
- UART still showed BRK at bank $00 — but test was INVALID (same POKE issue)
- Needs proper retest with fresh POKEs after deploy

## The Mystery
- Individual data reads from bank $20 via LDA long = CORRECT
- Continuous opcode fetches from bank $20 after JML = CRASH (BRK)
- The cpuDi mux should select superram_data_r for enableCpu+superram_in_pipeline
- SDRAM data capture comment says: "q=5 may be mid-CPUE edge" — capture at CPUE might get stale data
- But individual reads also capture at CPUE and work... unless the pipeline state is different

## Current Build State
- BRAM 1MHz fix: 3 changes applied (enableCpu_816 turbo_en gate, bram_hit_d1 speed gates, pipeline cancel)
- Registered SuperRAM address: `scpu_superram_addr_r` in c64.sv
- Building with these 2 changes only (no 4-stage, no NOP debug)

## Files Modified
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`: BRAM 1MHz fix (3 locations)
- `C64_MiSTer/c64.sv`: registered SuperRAM address + various previous changes

## Next Steps
1. Deploy clean build (BRAM fix + registered address)
2. Load doom.reu via mbc
3. POKE skip loader, verify with PEEK, then SYS49152
4. If still crashes: add NOP debug properly (POKE after deploy, then launch)
5. If NOP debug shows CPU at bank $20 with NOPs: issue is SDRAM data capture timing
6. If NOP debug still crashes to BRK: issue is pipeline/mux selection (CPU never reaches bank $20)

## Test Scripts on MiSTer
- `/tmp/mtype2.py`: daemon mode, persistent virtual keyboard
- `/tmp/doom_skip_poke.py`: POKEs skip loader + verify
- `/tmp/doom_poke.py`: POKEs copier (1KB) + verify

## Doom Data
- doom.reu on USB: `/media/usb0/games/C64/doom.reu` (16MB)
- Code starts at file offset 0x200000 (bank $20:$0000 in SuperRAM)
- First bytes: 78 D8 18 FB C2 30 A9 00 00 5B A9 FF 01 1B 64 80
- Entry point: JML $200000 → SEI/CLD/CLC/XCE/REP#30/LDA#0/TCD/LDA#$01FF/TCS/...
