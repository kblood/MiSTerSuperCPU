# SuperCPU on MiSTer C64 Core — User Guide

This guide explains how to use the CMD SuperCPU 65C816 emulation
built into this modified version of the MiSTer C64 core.

---

## What Has Been Implemented

| Feature | Status | Notes |
|---------|--------|-------|
| 65C816 CPU core (emulation mode, E=1) | ✅ Working | Full T65 replacement |
| 65C816 native mode (E=0) | ✅ Working | Used by kickstart internally |
| Kickstart ROM ($F8:0000-$FFFF) | ✅ Working | Boots, detects SIMM, exits to KERNAL |
| SuperCPU ID registers ($D0BC=$C9, $D0B0=$40) | ✅ Working | Software detects SCPU present |
| 16 MB SuperRAM (banks $01-$EF → SDRAM) | ✅ Working | Addressed via SDRAM upper bits |
| SuperCPU speed register $D07A | ✅ Working | Bit 5 = 1MHz compat mode |
| Turbo speed (2x/3x/4x via OSD) | ✅ Working | Follows existing turbo setting |
| 1 MHz default (turbo OFF) | ✅ Working | Turbo off = 1MHz even with SCPU |
| $D07E ROM visibility toggle | ✅ Working | Kickstart hides itself after boot |
| $D27B/$D27D/$D27E/$D27F SYSRAM regs | ✅ Partial | Basic register handling |
| Full 20 MHz CPU speed | ❌ Not yet | Needs deeper bus arbitration changes |
| REU compatibility | ❌ Not tested | May conflict with SuperRAM |

---

## Quick Start

### Enabling SuperCPU

1. Load the core `.rbf` from `output_files/C64.rbf` onto your SD card
2. In the MiSTer OSD (F12 or OSD button):
   - **Hardware → SuperCPU** → `Enabled`
   - **Hardware → SuperCPU ROM** → `Enabled` (to boot kickstart)
3. Reset the core (long-press OSD button, or OSD → Reset)
4. The C64 will boot normally to `COMMODORE 64 BASIC V2` / `READY.`

### Verifying SuperCPU is Active

At the BASIC prompt:
```basic
PRINT PEEK(53436)
```
Should print `201` ($C9) — the SuperCPU ID byte.

```basic
PRINT PEEK(53424)
```
Should print `64` ($40) — SuperCPU status byte (SCPU present, not JiffyDOS).

### Free Memory Test
```basic
PRINT FRE(0)
```
Normal C64 free memory is 38655. With SuperCPU it should be similar
(SuperRAM is not directly used by C64 BASIC without software support).

---

## SuperRAM (16 MB)

The 16 MB SuperRAM is mapped as follows:

| Bank | Address | Use |
|------|---------|-----|
| $00 | $0000-$FFFF | C64 base RAM (normal) |
| $01-$EF | $0000-$FFFF | SuperRAM (240 × 64K = ~15 MB usable) |
| $F0-$FF | $0000-$FFFF | Kickstart ROM (read-only) |

SuperRAM is accessed using 65C816 long addressing (bank byte ≠ $00).
Standard C64 software is unaware of SuperRAM; it requires software
compiled for the 65C816 or CMD SuperCPU utilities.

**To test SuperRAM with ML code:**
```asm
; In native mode (after CLC + XCE):
LDA #$01       ; bank $01
PHA
PLB            ; data bank = $01
LDA $0000      ; read from bank $01 address $0000
```

---

## Speed Modes

| OSD Turbo Setting | CPU Speed | Notes |
|-------------------|-----------|-------|
| Off (default) | 1 MHz | Normal C64 speed |
| 2x | ~2 MHz | Extra CPU cycles from EXT slots |
| 3x | ~3 MHz | |
| 4x | ~4 MHz | Maximum currently supported |

SuperCPU software can also control speed via register $D07A:
- Bit 5 = `1`: Force 1 MHz compatibility mode (ignores OSD turbo)
- Bit 5 = `0`: Use speed set in OSD turbo

**Note**: Real CMD SuperCPU runs at 20 MHz. This implementation is
currently limited to ~4× the C64 bus speed due to bus arbitration.
Full 20 MHz support requires a deeper redesign.

---

## Debug Overlay

Enable the debug overlay in OSD → Debug → Overlay to see live CPU state:

```
A:xxxx B:xx K:xx R:xx
S:xxxx P:xx I:xx E:x
W:xxxx D:xx O:xx
```

| Field | Meaning |
|-------|---------|
| A | 16-bit CPU address (current PC low 16 bits) |
| B | Bank byte (A23:A16 — together A+B = full 24-bit PC) |
| K | Highest bank reached since reset (sticky) |
| R | Low byte of address when highest bank was first entered |
| S | Stack pointer |
| P | Processor status register |
| I | Current opcode (instruction register) |
| E | Emulation mode flag (1=emulation/C64 compat, 0=native 816) |
| W | Address of last CPU write to screen RAM ($0400-$07FF) |
| D | Data written (00 = screen code for `@`) |
| O | Opcode that performed the write |

**Kickstart boot states:**

| K | B | A | Meaning |
|---|---|---|---------|
| $00 | $00 | $FC** | SuperCPU ROM not enabled or not booting |
| $F8 | $F8 | $8*** | Stuck in kickstart (check I for opcode) |
| $F8 | $00 | $FC**-$FF** | Kickstart done, KERNAL running |
| $F8 | $00 | $00**-$9*** | KERNAL crashed |

---

## Known Issues

### Scrolling `@` Lines on Screen

When SuperCPU is active, some screen memory locations are occasionally
written with $00 (screen code for `@`), causing lines of `@` symbols
that scroll down the screen.

**Workaround**: None confirmed yet. Investigation is ongoing.

**Diagnosis**: Enable the debug overlay and look at Row 3 (`W:xxxx D:xx O:xx`).
If `D:00` and `O:9C`, this is the STZ absolute opcode ($9C) difference
between the 65C816 (stores zero) and the 6502 (undocumented SHY — stores Y
ANDed with address high byte +1). The KERNAL ROM was written for 6502 so
these bytes are data, not instructions; but the 65C816 executes them as
STZ when they appear at instruction boundaries.

### Disk Drive Detection

If you see `DEVICE NOT PRESENT` errors:
- This is a regression from a previous build. Current build should not have this.
- Try resetting the core after enabling SuperCPU.
- JiffyDOS and standard KERNAL both supported.

### DolphinDOS vs Standard KERNAL

DolphinDOS may show extra characters (`ε`) at boot due to screen codes
left by the kickstart RAMTAS not being fully cleared. Switch to
**Std. C64 KERNAL** in OSD if this is a problem.

---

## Loading SuperCPU Software

### Requirements
- Software must be compiled for CMD SuperCPU (65C816, bank-switched RAM)
- Disk images: `.d64` format, mounted via OSD → Drive A

### Steps
1. Mount disk image in OSD
2. Type `LOAD"*",8,1` + RETURN
3. Type `RUN` + RETURN

### Known-Working Software
- SuperCPU BASIC extension (tests registers and memory)
- Any 65C816 native mode demo that checks for `PEEK(53436)=201`

---

## Building the Core

```powershell
# Full synthesis (WSL + Quartus 22.1std Lite)
.\build_c64.ps1

# Syntax check only (fast)
.\build_c64.ps1 -SyntaxOnly

# Clean build
.\build_c64.ps1 -Clean
```

Output: `C64_MiSTer/output_files/C64.rbf` (copy to SD card).

See `BUILD_GUIDE.md` for detailed build instructions.

---

## Architecture Notes

The SuperCPU implementation is layered on the existing C64 core:

1. **CPU**: `cpu_65c816.vhd` instantiates `P65C816.vhd` (65C816 core from
   pcornier/iigs_simulation, fixed for C64 compatibility).
2. **Bus arbitration**: `fpga64_sid_iec.vhd` switches between 6510 and 65C816
   based on OSD `supercpu_en` signal.
3. **ROM**: `scpu_rom.vhd` holds the SuperCPU kickstart ROM image.
   Enabled for banks $F0-$FF always; bank $00 $8000-$9FFF only when
   `scpu_rom_vis='1'` (set at reset, cleared by kickstart).
4. **SuperRAM**: Banks $01-$EF are mapped to SDRAM upper address bits
   (A24:A16 = bank byte, A15:A0 = 65C816 address bus).
5. **I/O registers**: $D0B0/$D0BC/$D07A/$D07E/$D27x handled in
   `fpga64_sid_iec.vhd` as read overrides on the `dataToCpu` mux.

For full technical details, see `ARCHITECTURE.md` and `TECHNICAL_ANALYSIS.md`.
