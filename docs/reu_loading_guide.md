# REU File Loading Guide for MiSTer C64 SuperCPU Core

## Overview

This document covers all known methods for loading `.reu` files into the MiSTer C64
core (both stock and SuperCPU-modified), which methods work, which do not, and why.

The `.reu` file format is a raw binary image of REU (RAM Expansion Unit) memory.
Files like `doom.reu` (Doom for SuperCPU) contain game data that gets loaded into
the REU SDRAM region at address `REU_ADDR = 25'h1000000` (bit 24 set, 16MB space).

---

## CONF_STR and ioctl_index Mapping

The current CONF_STR entry is:

```verilog
"F1,PRGCRTREUTAP;",
```

This is a single F1 file browser that accepts PRG, CRT, REU, and TAP files.
The `ioctl_index` sent by MiSTer Main to the FPGA is computed as:

```
ioctl_index[5:0] = F-directive number (1 in this case)
ioctl_index[7:6] = extension position in the concatenated list (0-based)
```

| Extension | Position | ioctl_index | Hex   |
|-----------|----------|-------------|-------|
| PRG       | 0        | (0 << 6) \| 1 | 0x01 |
| CRT       | 1        | (1 << 6) \| 1 | 0x41 |
| REU       | 2        | (2 << 6) \| 1 | 0x81 |
| TAP       | 3        | (3 << 6) \| 1 | 0xC1 |

The core decodes these in c64.sv:

```verilog
wire load_prg   = ioctl_index == 'h01;
wire load_crt   = ioctl_index == 'h41 || ioctl_index == 5;
wire load_reu   = ioctl_index == 'h81;
wire load_tap   = ioctl_index == 'hC1;
```

This is identical to the stock MiSTer C64 core.

---

## Method 1: OSD File Browser (Physical Keyboard)

**Status: WORKS (from USB only)**

### How It Works

Press F12 on a physical keyboard to open the MiSTer OSD menu. Select "Load File",
navigate to a `.reu` file, and select it. MiSTer Main reads the file and sends it
to the FPGA via the ioctl mechanism (FIO_FILE_INDEX + FIO_FILE_TX).

### Steps

1. Place the `.reu` file on a USB drive (e.g., `/media/usb0/C64/doom.reu`)
2. Press F12 on a physical keyboard connected to the MiSTer
3. Select "Load File" from the OSD menu
4. Navigate to the USB drive and select the `.reu` file
5. The file loads into SDRAM at REU_ADDR via io_cycle writes

### Critical Bug: SD Card Data Corruption

**Loading `.reu` files from the SD card (`/media/fat/`) sends byte counter values
(0, 1, 2, 3, ..., 255, 0, 1, ...) instead of actual file data.** This is a bug in
the MiSTer Main binary, confirmed on both Sep 2024 and Mar 2026 builds.

Loading from USB (`/media/usb0/`) sends correct file data.

Evidence:
- test.reu has `$42` at byte 0; SD card load sends `$00` (counter), USB sends `$42`
- test.reu has `$00` at byte 2; SD card load sends `$02` (counter), USB sends `$00`
- MD5 checksums match between SD and USB copies
- Stock C64 core (C64_20250828.rbf) has the same bug
- All tested sizes (16B to 256KB) from USB load correctly

### Limitations

- Cannot be triggered remotely via SSH (F12 via mtype.py/uinput goes to the C64
  core, not to MiSTer Main which handles the OSD)
- Requires physical keyboard access

---

## Method 2: MGL File (Game Launcher)

**Status: WORKS on SuperCPU — canonical scriptable REU loader (2026-04-15)**

### How It Works

MGL (MiSTer Game Launcher) files are small XML documents that tell MiSTer Main
to load a specific core RBF and then load a file into it. MiSTer Main processes
the MGL, loads the core, waits for the specified delay, then sends the file via
ioctl with the specified type and index.

### MGL File Format

```xml
<mistergamedescription>
  <rbf>CORE_PATH</rbf>
  <file delay="SECONDS" type="TYPE" index="INDEX" path="FILE_PATH"/>
</mistergamedescription>
```

Attributes:
- `rbf`: Path to core RBF, relative to SD root, no extension or timestamp
- `delay`: Seconds to wait before loading the file (increase if loading fails)
- `type`: `f` = load to memory, `s` = mount (use `f` for REU)
- `index`: The F-directive number from CONF_STR (use `1` for our F1 entry)
- `path`: Path to the game file, relative to the core's games folder

### MGL for REU Loading

```xml
<mistergamedescription>
  <rbf>_Test/C64</rbf>
  <file delay="10" type="f" index="1" path="/media/usb0/Games/C64/SCPU/Doom/doom.reu"/>
</mistergamedescription>
```

**Important**: Use `index="1"` (the F-directive number), NOT `index="129"` (0x81).
MiSTer Main computes the full ioctl_index internally by matching the file extension
against the F1 extension list and shifting the extension position into bits [7:6].

### How to Use

Save the MGL file on the MiSTer SD card (e.g., `/media/fat/_doom.mgl`), then:

```bash
ssh root@192.168.50.130 'echo "load_core /media/fat/_doom.mgl" > /dev/MiSTer_cmd'
```

### Important: Use the `_Test/C64` rbf path

On the SuperCPU-modified core, the MGL **must** reference `<rbf>_Test/C64</rbf>`
(our modified build lives only in `/media/fat/_Test/`). An MGL that references
`<rbf>_Computer/C64</rbf>` will load the vanilla release rbf and appear to
"break SuperCPU native mode" — but that's just the vanilla core running, not
a real regression. Dragon's Lair MGLs (and other stock MiSTer MGLs) confirm
the pipe handler processes both `<rbf>` and `<file>` tags end-to-end.

---

## Method 3: mbc (MiSTer Batch Control)

### 3a: mbc load_rom

**Status: DOES NOT WORK for REU (no C64.REU alias)**

`mbc load_rom` has no C64.REU alias and routes `.reu` files as PRG. In addition,
its generated MGL hardcodes `<rbf>_Computer/C64_20250828</rbf>` — the vanilla
release rbf — so even when it appears to "work" it is running vanilla, not
our SuperCPU build. Use a custom MGL via the pipe (Method 2) instead.

### 3b: mbc raw_seq (OSD Navigation)

**Status: DOES NOT WORK (F12 not intercepted by MiSTer Main)**

`mbc raw_seq` emulates keyboard input via Linux uinput. However, the F12 key
sent via uinput is delivered to the running core (the C64), not to MiSTer Main
(which handles the OSD). Therefore, you cannot open the OSD menu remotely
via `mbc raw_seq "M"` (M = F12).

Key codes for raw_seq:
- `M` = F12 (Menu/OSD) -- does not reach MiSTer Main
- `U/D/L/R` = arrow keys
- `O` = Enter
- `E` = Escape

### 3c: mbc with MBC_CUSTOM_MODE

**Status: UNTESTED, may work for MGL generation**

The `MBC_CUSTOM_MODE` environment variable controls the `type` and `index` in
the generated MGL. Setting `MBC_CUSTOM_MODE=f1` would generate an MGL with
`type="f" index="1"`. This could potentially fix the ioctl_index issue, but
still suffers from the MGL core-reload problem.

```bash
export MBC_CUSTOM_MODE=f1
mbc load_all_as /media/fat/_Test/C64.rbf /media/usb0/C64/doom.reu
```

---

## Method 4: /dev/MiSTer_cmd Direct Commands

**Status: PARTIALLY WORKS (core reload only)**

### load_core

Loads a core RBF or MGL file:

```bash
echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd
echo "load_core /media/fat/_doom.mgl" > /dev/MiSTer_cmd
```

This reloads the core. For MGL, it also loads the specified file.

### force_file (deprecated) / scan_mask_add

The `force_file` command was an older mechanism to override the file path used
by `user_io_file_tx`. It has been replaced by `scan_mask_add`:

```bash
echo "scan_mask_add /path/to/file.reu" > /dev/MiSTer_cmd
echo "select_a_rom" > /dev/MiSTer_cmd
echo "scan_clear" > /dev/MiSTer_cmd
```

The `select_a_rom` command synthesizes user input to navigate the OSD menu and
select the file. This is the closest thing to "load a file into a running core
without reloading" from the command line.

**Status: TESTED 2026-03-30 — DOES NOT WORK.** The `scan_mask_add` +
`select_a_rom` sequence appears to reload the core or leave MiSTer Main in
an inconsistent state. After testing, the FPGA was left uninitialized
(GPI[31]==1), MiSTer Main crashed and could not restart, requiring a full
reboot. Do NOT use `load_core` with a `.reu` file either — it tries to load
the REU data as an FPGA bitstream, which corrupts the FPGA state.

**WARNING**: `echo "load_core /path/to/file.reu" > /dev/MiSTer_cmd` will
crash the FPGA and require a power cycle or SSH reboot to recover.

---

## Method 5: mrext Remote API

**Status: POTENTIALLY WORKS (requires mrext installation)**

The [mrext Remote](https://github.com/wizzomafizzo/mrext) utility provides an
HTTP API on port 8182 that can send keyboard input and launch files:

```bash
# Send F12 to open OSD
curl -X POST http://192.168.50.130:8182/api/controls/keyboard/f12

# Launch a file
curl -X POST http://192.168.50.130:8182/api/launchers/launch \
  -d '{"path":"/media/usb0/C64/doom.reu"}'
```

The keyboard endpoint may be able to trigger F12 for MiSTer Main (unlike uinput),
but this has not been verified. The launch endpoint may generate an MGL internally.

### Installation

```bash
ssh root@192.168.50.130
curl -L https://github.com/wizzomafizzo/mrext/releases/latest/download/remote \
  -o /media/fat/Scripts/remote
chmod +x /media/fat/Scripts/remote
/media/fat/Scripts/remote  # starts on port 8182
```

---

## Method 6: Manual MGL File + /dev/MiSTer_cmd

**Status: WORKS for stock core; breaks SuperCPU native mode (same as Method 2)**

Generate an MGL file on the MiSTer and load it:

```bash
# Create MGL on MiSTer
ssh root@192.168.50.130 'cat > /tmp/reu_load.mgl << "MGLEOF"
<mistergamedescription>
<rbf>_Test/C64</rbf>
<file delay="10" type="f" index="1" path="/media/usb0/C64/doom.reu"/>
</mistergamedescription>
MGLEOF'

# Load it
ssh root@192.168.50.130 'echo "load_core /tmp/reu_load.mgl" > /dev/MiSTer_cmd'
```

This is equivalent to Method 2 but generated programmatically.

---

## Method 7: io_cycle SDRAM Write Test (POKE $DF1D/$DF1E)

**Status: WORKS (single bytes only, diagnostic/debug use)**

The SuperCPU core has diagnostic registers that allow writing individual bytes
to the REU SDRAM region via BASIC POKEs:

```basic
POKE 57117, value  : REM $DF1D - writes 'value' to SDRAM bank $02:$0000
POKE 57118, value  : REM $DF1E - writes 'value' to SDRAM bank $02:$0001
```

After writing, the core auto-triggers an io_cycle readback. The result appears
at `PEEK(57115)` ($DF1B), with status at `PEEK(57116)` ($DF1C, bit 2 = done).

This is not practical for loading full REU images but useful for verifying the
SDRAM write path works.

---

## Summary Table

| # | Method | Works? | Remote? | Reloads Core? | Notes |
|---|--------|--------|---------|---------------|-------|
| 1 | OSD (physical F12) | YES (USB only) | No | No | SD card has data corruption bug |
| 2 | MGL file (`_Test/C64` rbf) | **YES** | **Yes** | Yes | Canonical scriptable path |
| 3a | mbc load_rom | No | Yes | Yes | No C64.REU alias |
| 3b | mbc raw_seq | No | Yes | No | F12 not intercepted by Main |
| 3c | mbc CUSTOM_MODE | Untested | Yes | Yes | Superseded by Method 2 |
| 4 | /dev/MiSTer_cmd | **NO** | Yes | Crashes | scan_mask_add crashes FPGA |
| 5 | mrext Remote | Untested | Yes | Maybe | F12 delivery unverified |
| 6 | Manual MGL | **YES** | Yes | Yes | Same as Method 2 |
| 7 | POKE $DF1D/1E | Yes (1 byte) | Yes | No | Debug only, not practical |

---

## Recommended Approach (Current Best Path)

### Canonical scriptable REU loader (2026-04-15)

Use a custom MGL referencing our `_Test/C64` rbf, loaded via the MiSTer_cmd
pipe. Dragon's Lair MGLs (and other stock MiSTer MGLs) confirm the pipe
handler processes both `<rbf>` and `<file>` tags end-to-end.

```bash
# 1. Deploy the core.
scp C64_MiSTer/output_files/C64.rbf root@192.168.50.130:/media/fat/_Test/

# 2. Write a one-shot MGL on the MiSTer.
ssh root@192.168.50.130 'cat > /tmp/reu_load.mgl << "EOF"
<mistergamedescription>
  <rbf>_Test/C64</rbf>
  <file delay="2" type="f" index="1" path="/media/usb0/Games/C64/SCPU/Doom/doom.reu"/>
</mistergamedescription>
EOF'

# 3. Trigger load via pipe. Loads both the rbf and the .reu.
ssh root@192.168.50.130 'echo "load_core /tmp/reu_load.mgl" > /dev/MiSTer_cmd'

# 4. Wait ~15s for 16 MB transfer + KERNAL ready. SDRAM survives subsequent
#    deploys on the same power-on cycle, so iterative test cycles can reuse
#    the loaded REU content without re-running the MGL.
```

The `<file index="1">` + `.reu` extension lands on `load_reu` in c64.sv
via the `reu_by_ext` check. Use the SuperCPU launcher in BASIC:

```basic
POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92
POKE49156,0:POKE49157,0:POKE49158,32
SYS49152
```

---

## Known Bugs

### 1. SD Card REU Data Corruption (MiSTer Main Bug)

**Affects**: All MiSTer C64 cores (stock and modified)
**Symptom**: `.reu` files loaded from SD card contain byte counter values instead
of file data
**Workaround**: Load from USB drive
**Status**: Not reported upstream yet

### 2. MGL rbf path must be `_Test/C64`, not `_Computer/C64`

**Affects**: SuperCPU-modified core only
**Symptom**: An MGL with `<rbf>_Computer/C64</rbf>` loads the vanilla release
rbf (which lives in `/media/fat/_Computer/`), not our modified build. Vanilla
does not implement 65816 native mode, so CLC/XCE fails, overlay disappears,
and LDA long returns wrong data — the core looks "broken" but it's just the
wrong rbf running.
**Workaround**: Always use `<rbf>_Test/C64</rbf>` in MGLs for SuperCPU tests.
Verify the running build via `PEEK($DFF0)` (vanilla returns $FF, our build
returns real counter values).
**Status**: Resolved — document and follow the folder-layout rule (see
`feedback_mister_folder_layout.md`).

### 3. REU DMA (STASH/FETCH) Data Does Not Survive SDRAM Round-Trip

**Affects**: SuperCPU-modified core
**Symptom**: REU DMA state machine completes correctly but written data is not
readable from SDRAM
**Workaround**: Use SuperRAM CPU path (LDA long / STA long) instead of REU DMA
**Status**: Separate from ioctl loading; the DMA SDRAM write path has timing issues

### 4. mbc load_rom Sends Wrong ioctl_index

**Affects**: REU loading via mbc
**Symptom**: File loaded as PRG instead of REU
**Workaround**: Use MGL with explicit `index="1"` and correct file extension
**Status**: May be fixable with MBC_CUSTOM_MODE environment variable

---

## Architecture Reference

### ioctl Data Flow

```
User selects file in OSD
  -> MiSTer Main reads file from filesystem
  -> Main sends FIO_FILE_INDEX (0x55) with computed ioctl_index
  -> Main sends FIO_FILE_TX (0x53) to start transfer
  -> Main sends FIO_FILE_TX_DAT (0x54) with file bytes
  -> hps_io.sv receives data, asserts ioctl_download + ioctl_wr
  -> c64.sv: load_reu triggers when ioctl_index == 0x81
  -> c64.sv: ioctl_load_addr starts at REU_ADDR (25'h1000000)
  -> c64.sv: ioctl_req_wr triggers io_cycle SDRAM writes
  -> io_cycle writes each byte to SDRAM at ioctl_load_addr++
```

### SDRAM Address Space

```
0x0000000 - 0x00FFFFF : C64 RAM + I/O (bank $00)
0x0100000 - 0x01FFFFF : Cartridge ROM (CRT_ADDR)
0x0200000 - 0x03FFFFF : Tape data (TAP_ADDR)
0x1000000 - 0x1FFFFFF : REU / SuperRAM (REU_ADDR, bit 24 = 1)
  0x1000000 = bank $00 (REU offset 0)
  0x1010000 = bank $01 (SuperRAM bank $01)
  0x1020000 = bank $02 (SuperRAM bank $02)
  ...
  0x1FF0000 = bank $FF
```

### Key Files

- `C64_MiSTer/c64.sv` -- Top-level module, ioctl handling, SDRAM mux, diagnostic registers
- `C64_MiSTer/sys/hps_io.sv` -- HPS I/O interface, ioctl_index/download/wr signals
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` -- Bus arbitration, io_cycle, SuperRAM data path

---

## References

- [MiSTer CONF_STR Documentation](https://mister-devel.github.io/MkDocs_MiSTer/developer/conf_str/)
- [MiSTer hps_io Documentation](https://mister-devel.github.io/MkDocs_MiSTer/developer/hps_io/)
- [MiSTer MGL File Documentation](https://mister-devel.github.io/MkDocs_MiSTer/advanced/mgl/)
- [MiSTer Batch Control (mbc)](https://github.com/pocomane/MiSTer_Batch_Control)
- [mrext Remote API](https://github.com/wizzomafizzo/mrext)
- [Main_MiSTer /dev/MiSTer_cmd discussion](https://github.com/MiSTer-devel/Main_MiSTer/issues/190)
- [Main_MiSTer user_io.cpp](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/user_io.cpp)
- [Main_MiSTer file_io.cpp](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/file_io.cpp)
