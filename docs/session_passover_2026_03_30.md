# Session Passover — 2026-03-30

## What Was Done This Session

### 1. Reunified F1 file browser (commit 25a6712)
- Combined `F1,PRGCRTTAP;` + `F2,REU;` back into `F1,PRGCRTREUTAP;`
- Restored original ioctl_index mapping: REU='h81, TAP='hC1
- Reason: F2 opened to a different folder than F1, breaking usability

### 2. Hardware-verified SuperRAM read paths (bt fix confirmed)
- **STA long → LDA long round-trip**: PASS ($42 written to $02:2000, read back $42)
- **io_cycle write → LDA long (no preceding STA)**: PASS ($AB via POKE $DF1D, read 171)
- **MVN bank $00 → bank $02**: FAIL (system hangs — NOT bt bug, separate write path issue)
- Both read paths work correctly after the d3b403d byte-select fix

### 3. Tested remote REU/PRG loading methods
- **scan_mask_add + select_a_rom**: CRASHES FPGA — leaves it uninitialized (GPI[31]==1)
- **load_core with .reu file**: CRASHES FPGA — tries to load as bitstream
- **mbc load_rom / raw_seq**: does NOT inject files into running core after direct deploy
- **MGL**: works but reloads core, breaking SuperCPU native mode
- **Only working method**: Physical F12 OSD + USB drive

### 4. Wrote comprehensive REU loading guide
- `docs/reu_loading_guide.md` — covers 7 methods, which work and why others fail
- Documents CONF_STR ioctl_index mapping, SDRAM address space, known bugs

### 5. Researched OSD screenshots
- **Not possible** — MiSTer screenshots capture video BEFORE OSD compositing
- Architectural limitation in sys_top.v (OSD is in real-time HDMI output only)
- Only external HDMI capture can include the OSD

### 6. Verified MiSTer environment
- MiSTer Main: version 260325 (updated 2026-03-28) — current, no update needed
- File browser opens to: /media/fat/games/C64/ (SD) and /media/usb0/games/C64/ (USB)
- Both locations have .reu and .prg files

### 7. Fixed SSH after MiSTer update
- MiSTer update wiped authorized_keys, broke key-based SSH
- Updated `mister_debug.py` to use paramiko with password auth as primary method
- Falls back to ssh command if paramiko not available
- `pip install paramiko` is now a dependency

### 8. F12 OSD simulation — UNTESTED (can't verify via screenshots)
- `mtype.py F12` sends F12 via uinput — previous sessions said it doesn't reach MiSTer Main
- Screenshots can't show OSD (architectural limitation), so can't verify remotely
- User reports having seen F12 simulation work before — needs physical verification

## Current State of Working Tree

### Committed changes (on master branch):
```
25a6712 Reunify F1 file browser for PRG/CRT/REU/TAP loading
d3b403d Fix SuperRAM read: capture data before io_cycle corrupts byte select
c89ad27 Fix REU ioctl loading: F2 split, SDRAM addr timing, diagnostics
544f317 Fix REU register reads: bypass mux + direct cpuDi IOF path
```

### Uncommitted changes:
- `tools/mister_debug.py` — paramiko SSH support (password auth)
- `docs/debug_agent.md` — updated SSH auth note
- `docs/reu_loading_guide.md` — new comprehensive guide

## What Needs Investigation Next

### 1. F12 OSD simulation for remote REU loading
- Need physical verification: does `mtype.py F12` actually open the OSD?
- If yes, can we navigate the OSD menu remotely to select a .reu file?
- mbc raw_seq may also work: `M` = F12, `U/D` = arrows, `O` = enter

### 2. MVN cross-bank write (bank $00 → bank $02)
- System hangs when MVN tries to WRITE to SuperRAM
- Not the bt byte-select bug (reads work fine)
- Likely a write path issue in the SuperRAM SDRAM pipeline

### 3. MGL native mode breakage
- Core works after direct deploy but not after MGL reload
- 65816 native mode (CLC/XCE) fails, overlay disappears
- Root cause unknown — may be initialization timing or status register state

### 4. REU DMA (STASH/FETCH)
- DMA state machine completes but data doesn't survive SDRAM round-trip
- Separate issue from ioctl loading and bt fix

## Key Technical Notes

### SSH Authentication
- Key-based auth broke after MiSTer update (authorized_keys wiped)
- Key was re-installed at `/media/fat/linux/authorized_keys` but still not working
  (may need correct permissions or sshd config update)
- `mister_debug.py` now uses paramiko with password `1` as primary SSH method
- Direct `ssh`/`scp` commands from bash still fail — use `python tools/mister_debug.py`
  or paramiko directly

### DANGER Commands (Never Use)
- `echo "load_core /path/to/file.reu" > /dev/MiSTer_cmd` — crashes FPGA
- `scan_mask_add` + `select_a_rom` — crashes FPGA
- `busybox devmem` — crashes MiSTer

### Test via POKE (no PRG loading needed)
STA long + LDA long round-trip at $C000:
```
POKE49152,24:POKE49153,251:POKE49154,226:POKE49155,32:POKE49156,169
POKE49157,66:POKE49158,143:POKE49159,0:POKE49160,32:POKE49161,2
POKE49162,169:POKE49163,0:POKE49164,175:POKE49165,0:POKE49166,32
POKE49167,2:POKE49168,133:POKE49169,242:POKE49170,56:POKE49171,251
POKE49172,165:POKE49173,242:POKE49174,141:POKE49175,0:POKE49176,4
POKE49177,96
SYS49152
PRINT PEEK(242)
```
Expected result: 66 ($42)

## Build Info
- Last build: 2026-03-30 ~21:09
- ALMs: 30,251 / 41,910 (72%)
- RAM blocks: 496 / 553 (90%)
- Timing: still has negative slack but functional
