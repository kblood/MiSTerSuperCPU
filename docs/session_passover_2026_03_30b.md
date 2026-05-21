# Session Passover — 2026-03-30b (evening)

## What Was Done This Session

### 1. Phase 9 Complete — All 6 MVN/MVP Tests PASS
All tests verified via BASIC POKE+SYS after direct deploy:

| Test | Description | Result |
|------|-------------|--------|
| 1 | MVN bank $00 forward | PASS |
| 2 | MVP bank $00 backward | PASS |
| 3 | MVN $00→$02 (write to SuperRAM) | PASS |
| 4 | MVN $02→$00 (read from SuperRAM) | PASS |
| 5 | REU cross-path (STASH→LDA long) | **PASS** (new this session) |
| 6 | STA from SuperRAM code | PASS |

### 2. Test 5 (REU cross-path) verified
- Wrote minimal 62-byte machine code test via BASIC DATA/READ/POKE
- STASH $55 from C64 $5500 to REU addr $020100 via DMA (cmd $90)
- LDA long $02:$0100 returns 85 ($55) — correct
- Proves REU DMA STASH + SuperRAM LDA long cross-path works

### 3. MGL Native Mode Bug — Confirmed ARM-side
Thorough investigation proved the bug is in the MiSTer framework, not FPGA:
- **Same bitstream** (MD5 verified identical on MiSTer and local)
- **Same /dev/ttyS1 settings** (stty -a output identical for MGL vs direct)
- **Timer-based UART diagnostic**: replaced vsync-derived dbg_vblank with 50Hz timer — still zero bytes after MGL
- **Zero bytes at ALL baud rates** (115200, 57600, 38400, 19200, 9600, 2400, 230400)
- **Direct load_core immediately fixes** — same RBF, UART works, turbo active
- **Conclusion**: ARM-side MiSTer framework handles MGL core loading differently from direct load_core, in a way that silences UART output and disables turbo

### 4. Reverted diagnostic changes
- `fpga64_sid_iec.vhd`: reverted `sysEnable <= '1'` back to `sysEnable <= not pause`
- `c64.sv`: restored vsync-based dbg_vblank (timer diagnostic removed)
- Clean build: 30,139 ALMs (72%), clk64 slack -16.6ns, clk32 slack -7.9ns

### 5. Updated mtype.py device detection delay
- Changed from `time.sleep(3)` to `time.sleep(6)` in `create_uinput()`
- After core reset (e.g., mbc load_rom), MiSTer needs >3s to detect new uinput devices
- 6s delay is reliable

### 6. Updated mister_debug.py load_prg
- Changed from MGL-based to mbc-based (avoids MGL entirely)
- However, mbc load_rom doesn't actually persist PRG data (core reset clears RAM)
- Best approach remains: direct deploy + BASIC POKE+SYS via mtype.py

### 7. Tested mbc load_rom behavior
- `mbc load_rom 1 /path/to/file.prg` completes without error
- But PRG data doesn't persist: PEEK(2049)=0 after load
- Core reset clears RAM regardless of "Clear RAM on Reset" config setting
- mbc load_rom is NOT viable for PRG injection after direct deploy

## Current State

### Committed (master branch):
```
8f580b8 Add phantom cycle bypass for 65C816 VDA=0/VPA=0 internal cycles
25a6712 Reunify F1 file browser for PRG/CRT/REU/TAP loading
d3b403d Fix SuperRAM read: capture data before io_cycle corrupts byte select
c89ad27 Fix REU ioctl loading: F2 split, SDRAM addr timing, diagnostics
544f317 Fix REU register reads: bypass mux + direct cpuDi IOF path
```

### Uncommitted changes:
- `c64.sv`: freeze reset on ~reset_n, dbg_vblank comment update, DMA diagnostics
- `rtl/fpga64_sid_iec.vhd`: sysEnable reverted (clean)
- `tools/mister_debug.py`: load_prg uses mbc instead of MGL
- `tools/mtype.py`: device detection delay 3s→6s

### Build info:
- Last build: 2026-03-30 ~20:54
- ALMs: 30,139 / 41,910 (72%)
- RAM blocks: 496 / 553 (90%)
- Timing: clk64 -16.6ns, clk32 -7.9ns

## What Needs Work Next

### Phase 10 candidates:
1. **Doom loading** — doom.reu needs to reach SDRAM; doom_loader.prg uses REU DMA FETCH
2. **Performance optimization** — same_line cache skip, write-through cache
3. **Compatibility testing** — run more SuperCPU software
4. **MGL bug** — ARM-side issue, may need MiSTer Main source investigation or upstream report

### Testing infrastructure:
- PRG loading without MGL remains unsolved
- Best workaround: BASIC POKE+SYS via mtype.py (single invocation, all lines)
- OSD file browser automation (F12 → navigate → select) could work but untested

### REU cross-path test (BASIC):
```basic
10 FORI=0TO61
20 READV:POKE49152+I,V:NEXT
30 POKE55416,0
40 SYS49152
50 PRINTPEEK(21761)
100 DATA169,85,141,0,85,169,0,141,2,223
110 DATA169,85,141,3,223,169,0,141,4,223
120 DATA169,1,141,5,223,169,2,141,6,223
130 DATA169,1,141,7,223,169,0,141,8,223
140 DATA169,144,141,1,223,162,64,202,208,253
150 DATA24,251,175,0,1,2,56,251,141,1
160 DATA85,96
```
Expected result: 85 ($55)
