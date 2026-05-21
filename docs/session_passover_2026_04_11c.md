# Session Passover 2026-04-11c: doom.reu never loaded — [RETRACTED HEADLINE]

> **RETRACTED 2026-04-15**: The headline claim below ("MGL file tags broken")
> is WRONG. MGL via `/dev/MiSTer_cmd` DOES process `<file>` tags for both
> PRG and REU. Dragon's Lair MGLs (and other stock MiSTer MGLs) prove it.
> The session below was a flawed investigation — the real fault was a
> test-setup issue (likely `<rbf>_Computer/C64</rbf>` path resolving to
> vanilla, wrong REU target region, or mtype.py one-shot fragility). See
> `project_mgl_pipe_loads_files.md` for the current answer.

## Headline (ORIGINAL — WRONG)

The doom.reu was **never loaded into SDRAM**. Every previous "Doom running" observation was the CPU executing BRK chains ($00) through empty SDRAM. MGL `<file>` tags are NOT processed by `/dev/MiSTer_cmd` — only `<rbf>` core loading works. OSD manual loading is the only confirmed method to load REU files.

## 1. Critical Discovery: doom.reu Not Loaded

### Evidence
- REU ioctl diagnostic registers ($DF09-$DF12) all read **zero**:
  - `reu_ioctl_cnt` = 0 (no bytes transferred)
  - `reu_ioctl_idx` = 0 (no ioctl_index captured)
  - `reu_ioctl_last_addr` = 0 (no writes)
- UART shows `I:00` on every sample (BRK opcode at bank $20)
- Pattern: BRK at $20:xxxx → vector $FFE6-$FFE7 ($FF00=RTI) → RTI returns PC+2 → next BRK
- Address advances by +2 each BRK cycle through entire bank $20
- `A:FFE7 K:00` appears every 3 UART lines (BRK vector high byte read)

### Root Cause
`cat /tmp/doom.mgl > /dev/MiSTer_cmd` processes only `<rbf>` tag (core loads). The `<file>` tag with doom.reu is silently ignored. Tested with:
- `index="2"` (F2 slot encoding) → zero ioctl
- `index="129"` (0x81 = F2 raw encoding) → zero ioctl
- File-only MGL (no `<rbf>`) → not processed at all
- MGL path via echo → not processed at all

### All "Doom running" observations were BRK chains
Previous sessions reported "K:20 E:0" as Doom executing. In reality:
- JML $200000 jumped to empty SDRAM (all zeros)
- $00 = BRK in native mode → vector → RTI → next BRK
- Address cycling through bank $20 looked like "varying addresses = code executing"
- Frame counter incrementing was normal system operation, not Doom

## 2. Doom Does NOT Use REU DMA

Full disassembly of doom.reu at offset $200000 (bank $20:0000) reveals:
- **Zero REU register accesses** ($DF00-$DF0A) in the entire 16MB file
- Doom uses **SuperRAM direct long addressing** exclusively:
  - `STA [$dp],Y` for lookup table writes to banks $10-$19
  - `JML $80:005C` for cross-bank jumps
  - `LDA long,X` / `STA long` for data access
- The "REU DMA broken" hypothesis was a red herring for Doom

### Doom Init Flow (from $20:0000)
1. CPU setup: SEI, CLD, CLC, XCE, REP #$30, stack/DP init
2. Disable CIAs, VIC sprites/IRQs, clear pending interrupts
3. Write $35 to $01 (RAM visible)
4. SuperCPU registers: $D07E(HW_EN), $D07B(SW_TURBO), $D076(OPT), $D07F(HW_DIS)
5. Build math lookup tables in banks $10-$19 via `STA [$dp],Y` loops (64K entries × 10)
6. Copy math routines to $00:0200-$03FF
7. `JML $80:005C` — copy display data to $00:0800+
8. Return via `JML ($00FC)` indirect
9. `JML $2D:06A0` — game init continuation
10. `$20:0412: JML $20:0412` — error/halt infinite loop (shouldn't reach)

### CPU Microcode Verified
STA [$dp],Y (opcode $97) correctly loads the bank byte from the 3rd byte of the DP pointer into the AB (address bank) register. The CPU microcode for indirect long addressing is correct.

## 3. I/O Slowdown: REMOVE IT

Proven unnecessary in this session (confirming previous session):
- `cpu_cache.vhd:187` excludes $D000-$DFFF from caching
- BRAM also excludes I/O range
- VIC write test confirmed: native mode turbo STA $D020 works correctly
- The io_slowdown signal adds no benefit and can be removed

## 4. mtype.py / Input Device Issues

- `{RETURN}` syntax in mister_debug.py `keys` command doesn't work — typed literally
- Correct syntax: separate mtype.py arguments: `'text' enter 'text' enter`
- Or via direct SSH: `python3 /tmp/mtype.py 'line1' enter 'line2' enter`
- mbc load_rom causes UART/overlay to stop (likely enters native mode → BRK chain)
- Input devices exhaust after ~10 mtype.py calls — reboot MiSTer to fix

## 5. Doom Launcher (verified correct)

### PRG launcher (recommended)
`tools/doom_launcher.prg` — BASIC program at $0801: `10 SYS2061`, then ML at $080D:
```
SEI, CLC, XCE, JML $200000
```
Use: `mbc load_rom C64 /tmp/doom_launcher.prg` (after REU is loaded)

### POKE launcher (alternative)
```
POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92
POKE49156,0:POKE49157,0:POKE49158,32
SYS49152
```
Via mtype.py: `python3 /tmp/mtype.py 'POKE49152,...' enter 'POKE49156,...' enter 'SYS49152' enter`

## 6. OSD Menu Layout (verified via OBS capture)

```
Mount #8 *.D64...        ← cursor starts here on F12
Mount Write Protected Off
---
Load *.PRG,CRT,REU,TAP   (F1, ioctl_index varies by ext)
Load REU *.REU            (F2, ioctl_index=0x81)
---
Audio & Video             (submenu)
Hardware                  (submenu)
Drives                    (submenu)
---
Swap Joysticks: No
---
Turbo mode: Smart
Turbo speed: Rc
SCPU Speed: 20MHz (Max)
```

Separators may or may not be skipped by cursor. From Mount #8:
- 3 Downs (if separators skipped) or 4 Downs (if not) → Load REU

After selecting Load REU, file browser opens. Navigate: games/ → C64/ → doom.reu.

## Files Modified This Session

- `tools/doom_launcher.prg` — NEW: BASIC+ML Doom launcher PRG (21 bytes)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — io_slowdown v3 still in place (no changes this session)
- `docs/session_passover_2026_04_11c.md` — this file

## Next Steps

### Priority 1: Load doom.reu via OSD (MANUAL)
The user needs to manually:
1. Deploy core: `python tools/mister_debug.py deploy`
2. Open OSD (F12 on physical keyboard or USB keyboard connected to MiSTer)
3. Navigate to "Load REU" 
4. Browse to games/C64/doom.reu and select it
5. Wait for 16MB transfer (~10-30 seconds)
6. Verify: `PRINT PEEK(57097);PEEK(57098);PEEK(57099)` should show non-zero values
7. Launch Doom: type the POKE launcher lines + SYS49152

### Priority 2: Fix MGL file loading
Investigate why `/dev/MiSTer_cmd` doesn't process `<file>` tags. This might be:
- A MiSTer framework version limitation
- Need a different MGL format
- Need to use a different loading mechanism (MiSTer API, UDS socket)
- Check MiSTer GitHub issues for known problems

### Priority 3: Once REU loads successfully
- Verify UART shows `K:20 I:78` (SEI at $20:0000) not `I:00` (BRK)
- Monitor init progress: K:20 (init) → K:80 (display copy) → K:2D (game init) → K:BD (game loop)
- Debug any issues that appear during actual execution

## Build Info
- RBF: `C64_MiSTer/output_files/C64.rbf` built 2026-04-11 13:57 (io_slowdown v3)
- Fitter: 73% ALMs, 95% RAM blocks
- doom.reu: `/media/fat/games/C64/doom.reu` (16,777,216 bytes)
