# Session Passover - 2026-04-05d

## Session Summary
Focused on getting doom.reu loaded into SDRAM and verifying SuperRAM reads. Discovered
that MiSTer's `load_core` command via `/dev/MiSTer_cmd` does NOT process MGL file entries
(only loads the RBF core). Successfully loaded doom.reu via OSD navigation (user manually),
confirmed 16MB transfer. Game init runs in bank $20 native mode but crashes at $20:20FC
where SDRAM returns $00 instead of $85 (STA dp).

## Key Findings

### 1. MGL load_core Does NOT Load Files
`echo load_core /path/to/file.mgl > /dev/MiSTer_cmd` only loads the RBF core specified
in `<rbf>`. The `<file>` entries are IGNORED. File loading only happens through OSD
file browser selection. This is a MiSTer framework limitation, not a core issue.

### 2. REU Size Limits ioctl Transfer
MiSTer's main process reads `status[54:53]` (REU size OSD setting) to determine how
much .reu file data to transfer via ioctl:
- Disabled (default): transfers ~256KB
- 512KB: transfers 512KB
- 16MB: transfers full file

Config is stored in `/media/fat/config/C64.cfg` (or `doom.cfg` when loaded via MGL).
Format: 16 bytes, little-endian status words. REU bits at byte 6 bits 5-6.

Our FPGA code overrides `reu_cfg = 2'b11` (16MB) when SuperCPU is enabled, but
MiSTer main doesn't see this override — it reads the OSD status directly.

### 3. C64.cfg Format for REU=16MB
Working config bytes (with SuperCPU, UART, overlay ON):
```
00 00 00 00 00 80 62 02 00 00 CC 00 00 00 00 00
```
- Byte 5: 0x80 → Turbo mode = Smart
- Byte 6: 0x62 → REU=16MB (bits 5,6) + Turbo speed (bit 1)
- Byte 10: 0xCC → SuperCPU ON, Overlay ON, Kickstart ON, UART ON

### 4. OSD File Browser Path
The F2 file browser starting directory is stored in `/media/fat/config/C64.f2`.
Format: null-terminated path string (relative to `/media/fat/`), padded to 64+ bytes.
Old value pointed to USB (`../usb0/games/C64/scpu/doom/doom.reu`).
Updated to SD card: `games/C64/doom.reu`.

### 5. 16MB REU Load Confirmed
After user manually loaded doom.reu via OSD (F12 → Load REU → doom.reu):
```
reu_ioctl_cnt = 0x000000 (wrapped from 16MB = 2^24)
reu_ioctl_idx = 2 (F2 slot)
last_addr = $1FFFFFF (full 16MB range)
byte0_data = $00 (matches doom.reu first byte)
```

### 6. Game Init Runs But Crashes
After launching with BRK launcher (SEI, CLC, XCE, BRK, $00 → JML $20:0000):
- K:20, B:20, E:0 — PBR=$20, DBR=$20, native mode ✓
- T:21 — turbo ON, overlay ON ✓
- Game init executes: SEI, CLD, CLC, XCE, REP, LDA, TCD... ✓
- Crashes at $20:20FC — CPU reads $00 (BRK) instead of $85 (STA dp)
- BRK handler → JML $20:0000 → init restarts → infinite loop

UART loop pattern (sampled once per frame):
```
A:000A K:20 I:5B  ← TCD at init
A:FFE7 K:00 I:00  ← BRK vector
A:20FC K:20 I:00  ← BRK at $20:20FC (should be $85)
A:20F8 K:20 I:68  ← PLA
A:0012 K:20 I:82  ← at $20:0012
A:0080 K:20 I:64  ← STZ at $20:0080
```

### 7. SuperRAM Read Path Issue
doom.reu data at offset $2020FC = $85 (verified in file), but CPU reads $00.
The ioctl wrote 16MB to SDRAM correctly (confirmed by diagnostic registers).
The SuperRAM read path (`scpu_superram_addr = {1'b1, bank, addr}`) uses the
same SDRAM address as the ioctl write path, so the physical location matches.

Early init code ($20:0000-$20:000F) reads correctly — the SuperRAM pipeline
works for SOME addresses. The failure at $20:20FC may indicate:
- A timing issue in the 3-stage SuperRAM pipeline at certain addresses
- A conflict between instruction fetch and data writes during the decompression loop
- An address aliasing problem in the SDRAM controller

### 8. REU DMA Fetch Is Broken
REU DMA round-trip test (stash/fetch) returns zeros. Fetching data loaded via
ioctl also returns zeros. The REU DMA path (reu_ram_active, sdram_data_reu latch)
is separate from the SuperRAM CPU path and appears non-functional.

Not blocking for Doom (game uses SuperRAM LDA long, not REU DMA).

### 9. mtype.py Device Exhaustion
Creating too many uinput devices via mtype.py causes MiSTer to stop accepting
keyboard input. Each mtype.py call creates/destroys a device with 6-second setup.
After many calls, the input system breaks. Fix: reboot MiSTer.

Created `tools/osd_load_reu.py` as a single-device OSD navigation script, but
blind navigation is unreliable since we can't see the OSD (OBS capture broken).

## Current State of Code

### cpu_65c816.vhd
- BRK handler at $FF04: JML $20:0000
- vec_reg: WRITABLE with signal initialization attribute
- ROM stub: $FF00-$FF3F + $FFE4-$FFEF

### P65C816.vhd  
- PBR: NO fix (PBR=$F8 in emu mode is required for ROM routing)
- Comment explains why

### c64.sv
- REU auto-enable: `reu_cfg = supercpu_enable ? 2'b11 : status[54:53]`
- doom.reu on SD card: `/media/fat/games/C64/doom.reu` (16MB, copied from USB)
- doom.mgl exists but `load_core` doesn't process file entries

### Config files on MiSTer
- `/media/fat/config/C64.cfg` — REU=16MB, SuperCPU/UART/overlay ON
- `/media/fat/config/doom.cfg` — same settings  
- `/media/fat/config/C64.f2` — points to `games/C64/doom.reu` (SD card)

## Next Steps (Priority Order)

### 1. Debug SuperRAM Read at $20:20FC
The root cause of the game crash. Options:
- Write a minimal test PRG that reads specific SuperRAM addresses via LDA long
  and stores results in zero page (not screen RAM — scrolling overwrites $0400)
- Check if the issue is specific to address $20FC or affects a range
- Compare the SDRAM read timing between early init (works) and $20FC (fails)
- Check if the decompression loop's writes to banks $10-$1F interfere with
  instruction fetches from bank $20

### 2. Fix REU DMA Fetch (Lower Priority)
The REU DMA stash/fetch returns zeros. The `sdram_data_reu` latch might not be
capturing correctly for the REU DMA path. Not needed for Doom but needed for
other REU software.

### 3. Display System
Even after fixing the crash, the display needs:
- NMI timer setup for VBlank
- IRQ handler installation ($1D00 dispatch pointer, $00FC indirect)
- SCPUMIPS function pointers at $1CB4-$1CBB

## Tools Created
- `tools/osd_load_reu.py` — single-device OSD navigation for REU loading
- `tools/superram_read_test.prg` — machine code PRG at $C000 for SuperRAM testing
- `tools/superram_basic_test.prg` — BASIC-wrapped test (DATA tokenization broken)

## Debugging Notes
- doom.reu must be loaded via OSD (F12 → Load REU → navigate to SD card → doom.reu)
- OSD REU setting must be 16MB (Hardware page → REU → 16MB)
- deploy wipes SDRAM — always deploy BEFORE loading REU via OSD
- Launcher: `POKE256,83:POKE257,67:POKE258,80:POKE259,85` (SCPUMIPS sig)
  then `POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,0:POKE49156,0:SYS49152`

## UART Debug Format
`A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx V:xxxx.`
- K=PBR, B=DBR, I=instruction register (opcode of current/last instruction)
- T:21 = turbo=1, overlay=1 (normal game running state)
