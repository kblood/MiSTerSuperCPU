# SignalTap II Setup Guide for MiSTer C64 SuperCPU Core

## Overview

SignalTap II is Intel Quartus Prime's on-chip logic analyser.
It embeds capture logic into the FPGA bitstream so you can observe internal
signals in real time over USB-Blaster without modifying any I/O pins.

## Current Project Status (March 1, 2026)

- Active project SignalTap file is intended to be:
  - `C64_MiSTer/supercpu_debug.stp`
- Current focused trigger in that profile:
  - `dbg_vic_zero_hit_r == 1` (first VIC-side screen-code `$00` hit capture path)
- Verified cable visibility:
  - `jtagconfig` shows `DE-SoC [USB-1]` and device `5CSEBA6`
- Compile flow for this repo:
  - Preferred: Quartus 17 build/runtime on Windows
  - `build_c64.ps1` supports: `-UseWindowsQuartus`

Quick commands:

```powershell
# 1) Compile core with embedded SignalTap
.\build_c64.ps1 -UseWindowsQuartus

# 2) Program .sof over JTAG (USB-Blaster)
.\program_sof_jtag.ps1

# 3) Open SignalTap GUI (Quartus 17 path)
.\launch_signaltap.ps1
```

---

## Constraints

| Issue | Detail |
|---|---|
| **Quartus License** | The Windows version of Quartus Prime **Standard** (25.1) requires a paid/floating license to run the Fitter and the post-fitting Node Finder filter. The **Lite Edition** (22.1std.1 in WSL) is free and fully supports SignalTap for Cyclone V targets. |
| **Resource cost** | Each captured signal uses block RAM (sample buffer) and a small amount of ALMs. The core is already at ~61% ALMs and 63% RAM. Keep sample depths ≤ 1K and limit the number of channels to stay under the RAM limit. |
| **ROM loading** | When programming via JTAG the MiSTer framework bypasses SD card ROM loading. The SuperCPU kickstart ROM is embedded in block RAM inside the bitstream, so it is always available in a SignalTap session. |

---

## Method A – WSL Quartus Lite (Recommended Free Path)

### Prerequisites

```
~/intelFPGA_lite/22.1std.1/quartus/
```

Verify: `which quartus_sh` → should resolve inside the Lite installation.

### Step 1 – Create the .stp file in WSL

Open the Quartus Lite GUI from WSL:

```bash
# From WSL terminal
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
~/intelFPGA_lite/22.1std.1/quartus/bin/quartus &
```

1. Open the project: **File → Open Project** → `C64.qpf`
2. **File → New** → **Verification/Debugging Files → SignalTap II Logic Analyzer File** → OK
3. Give the instance a name (e.g. `scpu_debug`)

### Step 2 – Configure the capture clock

In the SignalTap II window:

- **Clock** field: type or browse for `emu:emu|fpga64:fpga64|fpga64_sid_iec:fpga64|clk32`
  (the 32 MHz system clock)
- **Sample depth**: 1024
- **Trigger**: Rising edge on any signal you want as trigger

### Step 3 – Add nodes (signals to capture)

Because we are using the **Lite** edition and have not yet run the Fitter for this session, use the **pre-synthesis** filter:

1. Double-click the signal list area → **Node Finder** opens
2. **Filter**: select `Design Entry (all names)` (NOT "SignalTap II: post-fitting" — that requires Fitter license)
3. Click **List** → all RTL signal names appear
4. Useful signals to add for SuperCPU debugging:

| Signal path | Purpose |
|---|---|
| `fpga64_sid_iec:fpga64\|cpuAddr[15:0]` | Active CPU address bus |
| `fpga64_sid_iec:fpga64\|addr_hi_816[7:0]` | Current 65C816 bank byte |
| `fpga64_sid_iec:fpga64\|cpuDo_816[7:0]` | CPU data output |
| `fpga64_sid_iec:fpga64\|cpuDi[7:0]` | Data read by CPU |
| `fpga64_sid_iec:fpga64\|cpuWe_816` | CPU write enable |
| `fpga64_sid_iec:fpga64\|enableCpu_816` | Clock enable for 65C816 |
| `fpga64_sid_iec:fpga64\|sysCycle[4:0]` | Bus arbitration cycle counter |
| `fpga64_sid_iec:fpga64\|turbo_m[2:0]` | Turbo multiplier |
| `fpga64_sid_iec:fpga64\|cpu_cyc` | CPU SDRAM slot active |
| `fpga64_sid_iec:fpga64\|scpu_speed_slow` | $D07A 1MHz flag |
| `fpga64_buslogic:buslogic\|scpu_rom_en` | Kickstart ROM active |
| `fpga64_buslogic:buslogic\|scpu_io_en` | I/O decode enabled |

5. Click **>>** to add selected signals → **Close**

### Step 4 – Set trigger condition

For catching the artifact writes, a good trigger is:

- Signal: `addr_hi_816[7:0]` = `0x00`  AND  `cpuAddr[15:0]` = `0x0400` (screen RAM start)
- Trigger condition: **Pattern** match
- Trigger position: **Pre** (capture before trigger) with 50% pre-fill

### Step 5 – Save the .stp file

**File → Save As** → name it `supercpu_debug.stp`  
Quartus will ask *"Enable SignalTap for this project?"* → **Yes**

### Step 6 – Recompile

```bash
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
~/intelFPGA_lite/22.1std.1/quartus/bin/quartus_sh --flow compile C64
```

Or use the PowerShell wrapper from Windows:

```powershell
.\build_c64.ps1
```

This will take ~10 minutes. The resulting `C64.rbf` will contain the embedded SignalTap logic.

### Step 7 – Copy RBF to MiSTer

```powershell
# From Windows PowerShell / WinSCP / scp
scp C64_MiSTer/output_files/C64.rbf root@<MISTER_IP>:/media/fat/_Test/C64.rbf
```

### Step 8 – Program via JTAG and capture

Connect the USB Blaster to the DE10-Nano JTAG header (J10).

```bat
REM From Windows CMD with Quartus bin on PATH
quartus_pgm.exe -c "DE-SoC [USB-1]" -m jtag -o "p;C64_MiSTer\output_files\C64.sof@2"
```

Then in Quartus Lite GUI (WSL):

1. **Tools → SignalTap II Logic Analyzer**
2. JTAG Chain Configuration panel → **Setup** → select `DE-SoC [USB-1]`
3. Device should appear as `5CSEBA6`
4. Click **Run Analysis** (or press F5)
5. Switch to the **Data** tab to see captured waveforms

---

## Method B – Windows Quartus Standard (Requires License)

If you have a valid Quartus Standard / Premier license:

1. Open the project in Windows Quartus
2. **File → New → SignalTap II Logic Analyzer File**
3. Node Finder filter: `SignalTap II: post-fitting` (available after full Fitter run)
4. Add signals, set trigger, save as `.stp`
5. Recompile → program → capture (same as Method A steps 7–8)

---

## Signals to Focus On for Artifact Debugging

The scrolling artifact lines are screen RAM writes that happen when they should not.
Useful capture scenario:

```
Trigger: cpuAddr == 0x0400 AND cpuWe_816 == 1 AND addr_hi_816 == 0x00
```

Check: What is `cpuDo_816`? (should be space/0x20 on BASIC boot, not 0x05 or 0x40)
Check: What is `sysCycle`? (should be in a CPU slot, not a VIC slot)
Check: What is `turbo_m`? (0 = 1MHz, > 0 = accelerated)

---

## Troubleshooting

| Problem | Solution |
|---|---|
| "Node Finder returns no results with pre-synthesis filter" | Run **Processing → Start → Start Analysis & Elaboration** first (this is free in Lite) |
| "JTAG chain empty" | Check USB-Blaster drivers; device manager should show Altera USB-Blaster; try `jtagconfig` in WSL |
| "Can't find DE-SoC" | Run `jtagconfig` from Quartus bin directory; should list `DE-SoC [USB-1]` with device `5CSEBA6(..)/SOCVHPS` |
| "SOF programs but no capture" | Make sure the `.stp` file was saved and project was recompiled with SignalTap enabled |
| Build fails after adding STP | Check resource usage; reduce sample depth or remove signals to stay under 63% RAM |

### Known failure pattern seen in this repo (March 1, 2026)

- Symptoms:
  - `Invalid JTAG configuration`
  - `Instance not found`
  - many red signal names in SignalTap
  - exported CSV contains `Flow Summary` instead of sampled signal data
- Likely cause:
  - STP/profile drift across edits (`supercpu_debug.stp` vs `supercpu_debug_1.stp`) and stale node mapping.
  - In one bad state, STP had signals but no active instance section; in another, it had `auto_signaltap_0` metadata not matching current programmed image.
- Recovery steps:
  1. Use **one canonical file only**: `C64_MiSTer/supercpu_debug.stp`.
  2. Remove stale red nodes and re-add from current Node Finder results.
  3. Save STP, run clean full compile, then reprogram `.sof`.
  4. Reopen SignalTap and rescan chain.
  5. Export from SignalTap **Data Log** (must contain signal columns/samples; reject files that start with `Flow Summary`).

---

## Getting Node Names Post-Fitting (Lite Edition Workaround)

The post-fitting node filter needs the Fitter. Workaround:

1. Run **Analysis & Elaboration** only (free)
2. Use the **Design Entry (all names)** filter — gives pre-synthesis signal paths
3. After building, run the Tcl script to dump node names:

```bash
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
~/intelFPGA_lite/22.1std.1/quartus/bin/quartus_sh -t ../find_stp_nodes.tcl
```

This dumps synthesis-visible signal names to `../found_nodes.txt`.
