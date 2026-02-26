# SuperCPU (65C816) Mode – User Guide

This guide covers using the SuperCPU (CMD SuperCPU / 65C816) emulation in the MiSTer C64 core.

---

## What Is Implemented

| Feature | Status | Notes |
|---|---|---|
| 65C816 CPU core | ✅ Working | Emulation mode and native mode both functional |
| SuperCPU kickstart ROM | ✅ Working | 64KB scpu64.mif embedded in bitstream |
| SuperCPU ID registers ($D0BC/$D0B0) | ✅ Working | Returns $C9 / $40 |
| $D07E ROM visibility register | ✅ Working | Kickstart hides itself after init |
| $D07A speed register | ✅ Working | Bit 5 = 1 forces 1MHz compat mode |
| 16MB SuperRAM (banks $01–$EF) | ✅ Working | Wired to SDRAM with bank byte in address |
| SuperCPU SYSRAM ($D200–$D3FF) | ✅ Working | 512-byte block RAM, cleared on reset |
| I/O bank gating | ✅ Working | VIC/SID/CIA only decoded in bank $00 |
| Speed control via Turbo option | ✅ Working | Turbo Off = 1MHz; On = 2×/3×/4× |
| Debug overlay | ✅ Working | Shows A/B/K/R/S/P/I/E on screen |
| 20MHz hardware mode | ❌ Not implemented | Limited by C64 bus architecture |
| Full $D0xx register set | ⚠️ Partial | Only key registers implemented |
| REU compatibility | ❌ Not tested | REU uses separate SDRAM path |

---

## OSD Settings

Access the OSD with **F12** (keyboard) or the **Menu** button on the MiSTer.

### SuperCPU Options

| OSD Option | Status bit | Description |
|---|---|---|
| `SuperCPU (65C816): On` | status[82] = 1 | Enables the 65C816 CPU. Disables the 6510. |
| `SCPU Kickstart ROM: On` | status[86] = 1 | Loads the CMD SuperCPU kickstart firmware. Required for SuperCPU software. |
| `Debug Overlay: On` | status[83] = 1 | Shows CPU state in top-left corner of screen. |
| `LED Debug` | status[85:84] | Controls DE10-Nano LED behaviour for debugging. |

### Speed Settings (affects SuperCPU and 6510)

| OSD Option | Effect |
|---|---|
| `Turbo mode: Off` | CPU runs at 1MHz (normal C64 speed). Recommended for most software. |
| `Turbo mode: C128` | CPU runs at higher speed during VIC-safe periods. |
| `Turbo mode: Smart` | CPU accelerates when not accessing I/O; auto-reverts during DMA. |
| `Turbo speed: 2x` | ~2MHz |
| `Turbo speed: 3x` | ~3MHz |
| `Turbo speed: 4x` | ~4MHz |

> **Note:** The real CMD SuperCPU runs at 20MHz. The MiSTer core is currently limited to
> ~4× because the 32-cycle bus period only provides a limited number of extra CPU slots.
> For maximum compatibility, use **Turbo Off** (1MHz) with the SuperCPU enabled.

---

## Quick Start: Booting SuperCPU Software

1. Enable **SuperCPU (65C816): On** in OSD
2. Enable **SCPU Kickstart ROM: On** in OSD
3. Press **Reset** (or toggle the core reset from OSD)
4. Wait for the kickstart to initialise — you should see:
   ```
   **** COMMODORE 64 BASIC V2 ****
   64K RAM SYSTEM  38911 BASIC BYTES FREE
   READY.
   ```
5. Load SuperCPU software from disk as normal

### Verifying SuperCPU Is Active

In BASIC, type:
```basic
PRINT PEEK(53436)
```
This reads address $D0BC. It should print **201** ($C9) if the SuperCPU is detected.

```basic
PRINT PEEK(53424)
```
This reads $D0B0. Should print **64** ($40) — SuperCPU v2 in C64 mode.

---

## SuperRAM (16MB)

The core implements 16MB of SuperRAM using the MiSTer SDRAM module.

- **Bank $00**: Standard C64 64KB — VIC-II, SID, CIA, BASIC, KERNAL, etc.
- **Banks $01–$EF**: SuperRAM (plain RAM, no I/O decode, no ROM overlay)
- **Banks $F0–$FF**: SuperCPU kickstart ROM (read-only from CPU; writes go to SDRAM shadow)

The SDRAM address is composed as:
```
{1'b0, supercpu_bank[7:0], cpu_addr[15:0]}  →  25-bit address (32MB space)
```

### Checking Available SuperRAM

With SuperCPU enabled, run:
```basic
SYS 3072
```
(Assumes a SuperCPU RAM test utility is loaded.)

Or check manually: the kickstart reports memory configuration during boot via
the SIMM detect routine. With the current FPGA implementation all banks alias
the same SDRAM region since bank-aliasing detection exits early on the first pass.
The effective SuperRAM is 16MB but all banks are backed by SDRAM.

---

## The Kickstart ROM Boot Sequence

When **SCPU Kickstart ROM** is enabled:

1. CPU reset vector ($FFFC) → $FC90 in the ROM (bank $FF)
2. JML $F8:00FC → JML $F8:80C1 (main kickstart entry)
3. Kickstart enters 65C816 native mode, sets SP=$01FF, DP=$0000
4. Three MVN block copies: bank $F8 → bank $01 ($A000–$BFFF, $E000–$FFFF, $6000–$7FFF)
5. STA $D07E with $00 → hides kickstart ROM from $E000–$FFFF (KERNAL re-appears)
6. JSL $F8:8148 — SIMM detect (exits on first iteration in FPGA)
7. LDA $FFFC — reads C64 KERNAL reset vector ($FCE2)
8. SEC + XCE → switches back to emulation mode
9. RTL → jumps to KERNAL at $FCE2 — normal C64 BASIC boot

---

## Known Issues

### Scrolling Character Lines on Screen

When SuperCPU mode is enabled with turbo speed, rows of identical characters
(`@`, `E`, or other symbols) may scroll across the screen.

**Observed behaviour:**
- Lines appear at 1MHz (slowly) and speed up with turbo setting
- Lines temporarily pause/disappear during disk load (JiffyDOS)
- Lines are from KERNAL/BASIC initialisation writes that are replayed

**Current status:** Under investigation. Likely related to the interaction
between the 65C816 emulation-mode execution path and C64 KERNAL startup
routines (specifically routines near $F6AF containing opcode $1A = INA,
which is a NOP on NMOS 6502 but INC A on 65C816).

**Workaround:** Disable turbo (Turbo mode: Off) to slow the artifacts. They
do not affect program execution.

### Disk Insertion Detection

Multi-disk software installers (e.g. SuperCPU Kicks! installer) may not
reliably detect disk changes because the virtual disk system notifies the
KERNAL in the normal way — SuperCPU mode does not change this.

### SIMM Size Detection

The kickstart SIMM detect routine exits early because all SDRAM banks alias
the same memory. Reported memory size may not match 16MB.

---

## Debug Overlay

Enable **Debug Overlay: On** in OSD to see a live CPU state display
in the top-left corner of the screen (rows 0–1 in the border area).

### Display Format

```
A:xxxx B:xx K:xx R:xx
S:xxxx P:xx I:xx E:x
```

| Field | Meaning |
|---|---|
| `A:xxxx` | Current 16-bit CPU address |
| `B:xx` | Current bank byte (A23–A16 of 65C816 address) |
| `K:xx` | Sticky max bank seen since last reset |
| `R:xx` | Low byte of address when max bank was first entered |
| `S:xxxx` | Stack pointer |
| `P:xx` | Processor status byte |
| `I:xx` | Current instruction register (opcode) |
| `E:x` | Emulation flag (1 = emulation/6502 mode, 0 = native/65C816 mode) |

### Reading the Overlay

After a successful kickstart boot:
- `B:00` — in bank $00 (normal C64 address space)
- `K:F8` — kickstart was active in bank $F8
- `E:1` — emulation mode (65C816 behaving as NMOS 6502)

---

## Turbo Mode and Speed Register ($D07A)

The 65C816 reads/writes $D07A to control speed:
- **Write bit 5 = 1** → `scpu_speed_slow = 1` → forces 1MHz even if Turbo is On
- **Write bit 5 = 0** → releases speed control to the OSD Turbo setting

This mirrors real SuperCPU behaviour where software can lock to 1MHz for
timing-sensitive routines (IEC serial, raster effects, etc.).

---

## Technical Reference

### Implemented SuperCPU Registers

| Address | R/W | Value | Description |
|---|---|---|---|
| $D07A | R/W | bit5 = slow flag | Speed control |
| $D07E | W | — | ROM visibility (bit7: 1=kickstart, 0=KERNAL) |
| $D07E | R | $00 | Always reads $00 |
| $D0B0 | R | $40 | Mode detect: SuperCPU v2 in C64 mode |
| $D0B2 | R | $00 | ROM visibility mirror (critical for SIMM detect) |
| $D0BC | R | $C9 | SuperCPU ID ($C9 = 201 = "SuperCPU present") |
| $D200–$D3FF | R/W | RAM | 512-byte SYSRAM (kickstart working variables) |

### Memory Map (SuperCPU Mode)

| Bank | Range | Contents |
|---|---|---|
| $00 | $0000–$CFFF | C64 RAM (64KB) |
| $00 | $D000–$D3FF | VIC-II / SID / CIA / SYSRAM |
| $00 | $D400–$DFFF | SID, CIA2, I/O expansion |
| $00 | $E000–$FFFF | C64 KERNAL/BASIC ROM (or kickstart if visible) |
| $01–$EF | $0000–$FFFF | SuperRAM (SDRAM, 16MB total) |
| $F0–$FF | $0000–$FFFF | Kickstart ROM (read) + SDRAM shadow (write) |
