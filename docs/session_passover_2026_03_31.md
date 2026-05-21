# Session Passover — 2026-03-31 (Doom Loading Attempt)

## What Was Done This Session

### 1. Downloaded doom.reu from CSDb
- `doom.zip` from csdb.dk contains: doom.reu (16MB), loader.prg, readme.txt, 4x D2M disk images
- doom.reu and loader.prg already existed on USB at `/media/usb0/games/C64/SCPU/Doom/`
- Copied doom.reu to `/media/usb0/games/C64/doom.reu` for easier access
- Also copied to SD as `/media/fat/games/C64/aaa.reu` (sorted first alphabetically)

### 2. Analyzed doom.reu format and loader.prg
- **loader.prg** (254 bytes): copies 187-byte loader to $0700, runs it
- **Loader at $0700**: REU DMA FETCH allocation table from $FF0000, copies pages to SuperRAM via STA [$FB],Y
- **Allocation table**: Bank $FF pages 0-255 describe which 256-byte pages to copy per bank
- **JML vector**: At $FFFFFE = $20 → game entry point is `$20:0000`
- **Game code at $20:0000**: SEI, CLD, CLC, XCE (native mode), sets up DP/SP, disables CIAs/VIC IRQs
- **Key insight**: Since doom.reu data is already in SDRAM after ioctl load, the DMA copy is redundant. A "skip loader" that just JMLs to $200000 should work.

### 3. Added F2 "Load REU" to OSD + ioctl_file_ext detection
**Code changes in c64.sv:**
```verilog
// CONF_STR: added F2 for REU-specific loading
"F2,REU,Load REU;",

// load_reu now detects .reu files even when MGL sends index=0x01
wire reu_by_ext = (ioctl_file_ext == ".REU" || ioctl_file_ext == ".reu");
wire load_prg   = ioctl_index == 'h01 && !reu_by_ext;
wire load_reu   = ioctl_index == 'h81 || ioctl_index == 'h02
               || (ioctl_index == 'h01 && reu_by_ext);
```

### 4. MGL loading approach (partially works)
- **SD path**: `path="../games/C64/aaa.reu"` — loads 16MB counted ✓
- **USB path**: `path="../../usb0/games/C64/doom.reu"` — loads 16MB counted ✓
- **Problem**: MGL breaks native mode (REU DMA returns zeros, turbo disabled)
- **Skip loader JML $200000**: game code starts executing (debug overlay clears) but crashes
- After 30 minutes at 1MHz, no rendering visible → game is stuck/crashed

### 5. OSD navigation (could not complete)
- **F12 via mtype.py**: CONFIRMED opens OSD (keyboard input intercepted)
- **Menu structure**: DOWN×3 = Load * (F1), DOWN×4 = Load REU (F2)
- **File browser cursor**: remembers position from PREVIOUS sessions → unpredictable
- **Tried**: HOME (no effect), UP×20 (wraps around), letter jump ('d')
- **Result**: Loaded wrong files (test.reu, tiny.reu, etc.) — never doom.reu
- **Root cause**: Browser is on USB, cursor position cached at old position

### 6. SD card data bug confirmed
- SD card ioctl sends counter values (0,1,2,...) instead of file data for REU files
- Verified: REU FETCH from offset $200004 returns 0 (counter value) not $C2 (doom data)
- USB does NOT have this bug — but MGL from USB breaks native mode
- **Only OSD + USB loading works correctly** (preserves native mode + sends real data)

## Current State

### Committed changes: None (all changes are uncommitted)

### Uncommitted changes:
- `c64.sv`: F2 "Load REU" entry, ioctl_file_ext REU detection, DMA diagnostics
- `tools/mister_debug.py`: load_prg uses mbc
- `tools/mtype.py`: 6s device detection delay

### Build info:
- Last build: 2026-03-31 ~23:42
- ALMs: similar to previous (~72%)

### Files on MiSTer:
- `/media/usb0/games/C64/doom.reu` — 16MB doom REU image (from CSDb)
- `/media/fat/games/C64/aaa.reu` — same file, renamed for alphabetical sorting
- `/media/fat/_Test/doom_usb.mgl` — MGL for USB loading
- `/media/fat/_Test/doom_sd.mgl` — MGL for SD loading
- USB games/C64/.bak/ — backed up PRG/CRT/TAP files (moved to simplify browser)

## What Needs Work Next

### Priority 1: Load doom.reu via OSD (preserving native mode)
The ONLY remaining blocker. Options:
1. **Physical keyboard**: Press F12 on a USB keyboard connected to MiSTer, navigate OSD visually
2. **Fix OSD cursor**: Delete ALL files from USB except doom.reu, use F2 "Load REU" browser
3. **mrext/remote OSD**: Use MiSTer Remote extension for OSD control
4. **Fix MGL native mode bug**: ARM-side investigation (complex, in MiSTer Main source)

### Priority 2: After successful REU load, run skip loader
```basic
POKE49152,120:POKE49153,141:POKE49154,123
POKE49155,208:POKE49156,24:POKE49157,251
POKE49158,92:POKE49159,0:POKE49160,0
POKE49161,32:SYS49152
```
This POKEs: SEI, STA $D07B, CLC, XCE, JML $200000 at $C000 and executes it.

### What we know works:
- doom.reu data at $20:0000 = $78 $D8 $18 $FB (valid game code)
- Game entry point: bank $20, offset $0000
- Skip loader JML $200000 starts game execution (debug overlay clears)
- The original loader.prg is redundant (data already in SDRAM after ioctl)
- SuperRAM reads via LDA long verified working in previous sessions
- REU DMA STASH/FETCH verified working (when NOT after MGL)

### Key constraints:
- **SD card REU bug**: sends counter values, must use USB
- **MGL native mode bug**: breaks REU DMA, turbo, UART
- **OSD is the only correct loading path** for REU files from USB
- **mtype.py F12 works** for opening/closing OSD
- **OSD navigation works** (DOWN/ENTER) but cursor position is unpredictable
