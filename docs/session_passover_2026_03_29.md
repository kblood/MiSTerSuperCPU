# Session Passover — 2026-03-29

## Key Discovery: REU ioctl Loading Bug

### The Bug
Loading .reu files via OSD sends **byte counter values** (0,1,2,3...$FF,0,1...) instead of actual file data to the FPGA — but ONLY when the file is on the SD card (`/media/fat/`). Loading from USB (`/media/usb0/`) sends correct data.

### Evidence Chain
1. **Diagnostic registers** added to capture `ioctl_data` at specific byte offsets during REU load
2. **Fixed-value test** proved the diagnostic mux works: assigned `8'hAB` and `8'hCD` to byte 0/1 registers, read back correctly via PEEK
3. **Real ioctl_data** at byte 0 showed 0 (counter) instead of $42 (file data) for test.reu from SD card
4. **Stock C64 core** (C64_20250828.rbf) has the SAME bug — REU FETCH from SDRAM returned 0,1,2,3 (counter)
5. **MiSTer Main updated** from Sep 2024 to Mar 2026 — same bug
6. **F2 separate entry** (`F2,REU;` with ioctl_index=0x02) — same bug
7. **Size tests**: 16B (tiny.reu), 1KB, 4KB, 16KB, 64KB, 128KB, 256KB all from USB → **ALL CORRECT**
8. **test.reu from USB** → byte 0 = $42 (CORRECT), byte 2 = $00 (CORRECT)
9. **test.reu from SD** → byte 0 = 0 (COUNTER), byte 2 = 2 (COUNTER)
10. **MD5 identical** on both SD and USB copies

### Root Cause
MiSTer Main binary SD card file reading path sends byte position counter instead of file content for ioctl transfers. USB path works correctly. Affects both old (Sep 2024) and new (Mar 2026) Main binaries.

### Workaround
Load REU files from USB drive, not SD card. CONF_STR changed to `F2,REU;` (separate entry).

## Current Code State (working tree, NOT committed)

### CONF_STR Change
```verilog
// OLD:
"F1,PRGCRTREUTAP;",
// NEW:
"F1,PRGCRTTAP;",
"F2,REU;",
```

### ioctl_index Change
```verilog
// OLD:
wire load_reu = ioctl_index == 'h81;
wire load_tap = ioctl_index == 'hC1;
// NEW:
wire load_reu = ioctl_index == 'h02;
wire load_tap = ioctl_index == 'h81;
```

### Diagnostic Registers (STILL IN CODE — should be cleaned up)
Lines ~1144-1191 in c64.sv: reu_ioctl_cnt, reu_ioctl_last_data, reu_ioctl_byte0-3_data, etc.
Mux entries in reu_reg_mux cases 9-28. These overlap with real REU registers $DF09+ and should be REMOVED before final commit.

## Remaining Issue: io_cycle SDRAM Writes

Even with correct ioctl_data (from USB), LDA long from bank $02:$0000 returns stale SDRAM data ($4D), not the REU file content ($DE). This means the io_cycle write path doesn't persist data to SDRAM on our SuperCPU build.

**On the stock core**, io_cycle writes DID work (counter values were readable via REU FETCH). So something in our SuperCPU modifications affects the io_cycle SDRAM write path.

### Possible causes:
1. **io_cycle timing**: Our SDRAM mux modifications may affect the io_cycle write window
2. **SDRAM address bit[24]**: The sdram.v uses addr[24] as byte select (high/low byte of 16-bit word). REU_ADDR = 25'h1000000 has bit[24]=1. io_cycle writes might not handle the byte select correctly
3. **cart_ce gating**: During io_cycle, ce = io_cycle_ce (explicitly set). But during CPU reads via LDA long, ce = cart_ce — check if this fires for SuperRAM addresses
4. **Cache interference**: Unlikely since cache only covers bank $00, but worth checking

### Test Programs on MiSTer
- STA/LDA round-trip: writes $AB/$CD to bank $02, reads back (works within same SYS call)
- LDA-only readback: reads bank $02:$0000-$0001 (returns stale $4D, $00)
- Diagnostic PEEKs: `PRINT PEEK(57111);PEEK(57112);PEEK(57113);PEEK(57114)`

### Test Files on MiSTer
- `/media/usb0/C64/test.reu` — 256KB, $42 at byte 0, $DEADBEEF at offset $020000
- `/media/usb0/C64/test_256k.reu` — 256KB, pattern (i*7+$42)&$FF
- `/media/usb0/C64/test_*.reu` — various sizes (1k, 4k, 16k, 64k, 128k)
- `/media/usb0/C64/tiny.reu` — 16 bytes ($42,$AA,$BB,$CC,$DD,$EE,$FF,$11,$22,$33,$44,$55,$66,$77,$88,$99)
- `/media/fat/games/C64/test.reu` — same as USB copy (DO NOT USE — SD card bug)

### MiSTer State
- MiSTer Main: updated to Mar 2026 (1,014,152 bytes), backup at /media/fat/MiSTer_20240902_backup
- mtype.py: needs re-upload after reboot (`scp tools/mtype.py root@192.168.50.130:/tmp/mtype.py`)
- Current core: SuperCPU build with F2 REU + diagnostic registers
- OSD has two "Load File" entries: first for PRG/CRT/TAP, second for REU

## Next Steps
1. **Debug io_cycle SDRAM write path** on our SuperCPU build — why don't ioctl writes persist to SDRAM? Compare with stock core's working io_cycle path.
2. **Clean up diagnostic registers** once REU loading is fully working
3. **Test doom.reu loading** from USB once SDRAM writes work
4. **Consider filing MiSTer Main bug report** for SD card ioctl data corruption
