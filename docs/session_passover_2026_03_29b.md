# Session Passover — 2026-03-29 (afternoon)

## What Was Done This Session

### 1. Committed previous session's changes (c89ad27)
- F2 REU split in CONF_STR (SD card ioctl bug workaround)
- SuperRAM SDRAM address timing fix (`dbg_cpu_addr` + concatenation)
- REU ioctl diagnostic registers

### 2. Diagnosed io_cycle SDRAM write path
- **Extensive static analysis** of the io_cycle write path: address mapping, byte select (bt/DQM), SDRAM controller state machine, clock domain crossing (clk32→clk64), io_cycle timing, pipeline cancel logic
- **Conclusion**: io_cycle write path is identical to stock core when io_cycle=1 — no SuperCPU modification affects it

### 3. Added POKE-triggered SDRAM write test ($DF1D/$DF1E)
- POKE $DF1D,val → writes val to SDRAM at bank $02:$0000 via io_cycle
- POKE $DF1E,val → writes val to SDRAM at bank $02:$0001 via io_cycle
- Auto-triggers io_cycle readback from same address → result in $DF1B
- Status byte at $DF1C: bit2=done, bit1=active, bit0=pending

### 4. Found and fixed SuperRAM read byte-select bug (d3b403d)

**Root cause**: `sdram.v`'s `bt` (byte toggle = addr[24]) register gets updated when io_cycle CE fires at EXT0. Since `dout = bt ? high_byte : low_byte`, this flips the output to the wrong byte. `superram_data_r` was captured at `enableCpu` time (CPUF→EXT0), AFTER `bt` changed — so it returned the LOW byte (stale cart/ROM data) instead of the HIGH byte (SuperRAM data).

**Why STA/LDA round-trip worked but LDA-only didn't**: In the round-trip, the STA immediately before LDA keeps the pipeline "warm" — the data is captured before io_cycle interferes. LDA-only (e.g., reading back io_cycle-written data) hits the race condition.

**Fix in fpga64_sid_iec.vhd**: Changed `superram_data_r` capture from:
```vhdl
if enableCpu = '1' and superram_in_pipeline = '1' then
    superram_data_r <= sdram_raw;
```
to:
```vhdl
if superram_enable_delay = '1' and superram_in_pipeline = '1' then
    superram_data_r <= sdram_raw;
```
This captures at CPUE (one cycle earlier), before io_cycle goes HIGH at EXT0.

**Hardware verified**:
- io_cycle write $AB → LDA long $020000 returns **$AB** (was $4D before fix)
- STA/LDA round-trip at $020100 returns **$5A** (still works)

## Current State of Working Tree

### Committed changes (on master branch):
```
d3b403d Fix SuperRAM read: capture data before io_cycle corrupts byte select
c89ad27 Fix REU ioctl loading: F2 split, SDRAM addr timing, diagnostics
544f317 Fix REU register reads: bypass mux + direct cpuDi IOF path
```

### Diagnostic registers still in c64.sv (temporary):
- $DF09-$DF0B: ioctl byte count (24-bit)
- $DF0C: ioctl_index at download start
- $DF0D-$DF10: last ioctl write address (25-bit)
- $DF11: last ioctl data byte
- $DF12: first byte data
- $DF13-$DF15: SDRAM write presentation count (24-bit)
- $DF16-$DF19: first SDRAM write addr (25-bit)
- $DF1A: first SDRAM write data
- $DF1B: io_cycle readback data (from bank $02:$0000)
- $DF1C: readback status {5'b0, done, active, pending}
- $DF1D: POKE triggers write to bank $02:$0000 via io_cycle (reads as dbg_wr_pending)
- $DF1E: POKE triggers write to bank $02:$0001 via io_cycle

## What Needs Testing Next

### 1. REU .reu file loading from USB via OSD
The bt fix should now allow REU file data to be visible via LDA long. Need to:
- Open OSD (F12 on physical keyboard — remote F12 via mtype.py doesn't work for MiSTer Main)
- Select REU file from USB
- Verify via PEEK $DF09-$DF0B that ioctl transfer happened
- Verify via LDA long that data is readable

**Note**: Remote OSD not working — F12 via mtype.py sends to core but NOT to MiSTer Main (which handles OSD). Must use physical keyboard or find alternative.

### 2. Retest MVN/MVP tests 3 & 5
These failed with "reads bank $00 data" — exactly the bt byte-select symptom. Likely fixed now.
Test files: `tools/test_cart/scpu_mvn_mvp_test.s`

### 3. Doom loading
- doom.reu needs to reach SDRAM via ioctl (REU DMA FETCH is still broken)
- MGL reload still has issues (overlay disappears, native mode broken)
- Direct deploy + USB OSD load is the viable path

### 4. REU DMA (still broken)
- STASH/FETCH DMA state machine completes but data doesn't survive SDRAM round-trip
- This is a SEPARATE issue from the bt fix (DMA uses different SDRAM path)
- May also have a bt-related issue in the DMA read path — worth investigating

## Key Technical Notes

### SDRAM byte select architecture
- addr[24] = `bt` in sdram.v = byte toggle (HIGH/LOW byte of 16-bit SDRAM word)
- REU space: all addresses have bit[24]=1 → HIGH byte
- Cart ROM space: bit[24]=0 → LOW byte
- Both coexist in the same 16-bit SDRAM words (different byte lanes)
- io_cycle writes use HIGH byte (correct)
- CPU SuperRAM reads use HIGH byte (correct after fix)

### Pipeline timing (3-stage SuperRAM)
```
CPUC: cpu_cyc fires, SDRAM CE → superram_in_pipeline='1'
CPUD: cpu_cyc_s shift
CPUE: superram_enable_delay='1' → superram_data_r captures sdram_raw ← FIX POINT
CPUF: enableCpu='1' (takes effect at EXT0) → CPU advances
EXT0: io_cycle goes HIGH → sdram.v bt changes ← DANGER ZONE (old capture point)
```

### Remote testing limitations
- mtype.py: sends keystrokes to C64 core via uinput (works for BASIC commands)
- F12 for OSD: NOT intercepted by MiSTer Main from uinput devices
- mbc load_rom: reloads the core (can't load REU into running core)
- MGL: always reloads core + file together
- No way found to load REU file into running core remotely

### Test programs available
- `tools/test_cart/lda_bank2.prg` — reads bank $02:$0000-$0001 via LDA long, prints result
- `tools/test_cart/reu_sdram_diag.prg` — reads all diagnostic registers (didn't work via mbc due to BRAM coherency)
- Machine code via POKE: `POKE49152,24:POKE49153,251:...` for CLC/XCE/LDA long/STA/SEC/XCE/RTS

## Build Info
- Last build: 2026-03-29 ~15:45
- ALMs: ~72%, RAM blocks: ~90%
- Timing: still has negative slack (clk64 ~-15ns, clk32 ~-7ns) but functional
