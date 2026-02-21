# Building the MiSTer C64 Core

## Prerequisites

- **Windows 11** with WSL2 enabled
- **Ubuntu** installed in WSL (tested with 24.04)
- **Intel Quartus Prime Lite Edition** installed inside WSL
  - Tested with version 22.1std.1 (also works with 17.0.2)
  - Must include **Cyclone V** device support
  - Default install path: `~/intelFPGA_lite/22.1std.1/`

## Quartus Installation (one-time setup)

If Quartus is not yet installed in WSL:

```bash
wsl bash -c '
  # Download Quartus 17.0.2 Lite for Linux (~5GB)
  cd /tmp
  wget https://downloads.intel.com/akdlm/software/acdsinst/17.0std.2/602/ib_tar/Quartus-lite-17.0.2.602-linux.tar

  # Extract and install (headless, Cyclone V only, no ModelSim)
  mkdir -p /tmp/quartus_install
  tar -xf Quartus-lite-17.0.2.602-linux.tar -C /tmp/quartus_install
  /tmp/quartus_install/setup.sh --mode unattended \
      --unattendedmodeui none \
      --installdir $HOME/intelFPGA_lite/17.0 \
      --disable-components quartus_help,modelsim_ase,modelsim_ae \
      --accept_eula 1

  # Add to PATH
  echo "export PATH=\$HOME/intelFPGA_lite/17.0/quartus/bin:\$PATH" >> ~/.bashrc
'
```

For Ubuntu 24.04, you may also need `libpng12` and `libtinfo5` — see the install script comments for details.

## Repository Setup

Clone the official C64 MiSTer core:

```powershell
cd C:\LLM\C64\MiSTerSuperCPU
git clone --recursive https://github.com/MiSTer-devel/C64_MiSTer.git
```

## PLL Compatibility Fix (Quartus 22.x only)

The project targets Quartus 17.0.2. If using Quartus 22.x, the MiSTer sys framework
looks for `sys/pll_q22.qip` which doesn't exist in the repo. Create it as a copy of the
Quartus 17 version:

```powershell
Copy-Item C64_MiSTer\sys\pll_q17.qip C64_MiSTer\sys\pll_q22.qip
```

The file contents should be:

```tcl
set_global_assignment -name QIP_FILE           rtl/pll.qip
set_global_assignment -name QIP_FILE           [file join $::quartus(qip_path) pll_hdmi.qip ]
set_global_assignment -name QIP_FILE           [file join $::quartus(qip_path) pll_audio.qip ]
set_global_assignment -name QIP_FILE           [file join $::quartus(qip_path) pll_cfg.qip ]
```

This works because the Quartus 17 PLL IP for Cyclone V is forward-compatible with 22.x.

## Building

### From PowerShell (automated)

```powershell
.\build_c64.ps1
```

See `build_c64.ps1` in this directory for the full automated script.

### Manual build from WSL

```bash
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
~/intelFPGA_lite/22.1std.1/quartus/bin/quartus_sh --flow compile C64
```

### Syntax check only (faster, no bitstream)

```bash
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
~/intelFPGA_lite/22.1std.1/quartus/bin/quartus_sh --flow analysis_and_elaboration C64
```

## Build Output

On success, the following files are generated in `C64_MiSTer/output_files/`:

| File | Size | Description |
|------|------|-------------|
| `C64.rbf` | ~3.8 MB | Raw binary file — this is what MiSTer loads |
| `C64.sof` | ~6.7 MB | SRAM object file (for JTAG programming) |
| `C64.fit.rpt` | ~6.7 MB | Fitter report with resource usage details |
| `C64.sta.rpt` | — | Timing analysis report |

## Deploying to MiSTer

Copy `C64.rbf` to your MiSTer SD card:

```
SD://_Computer/C64.rbf
```

Rename it to `C64_YYYYMMDD.rbf` if you want to keep multiple versions.

## Build Times

| Environment | Time |
|-------------|------|
| WSL2 on /mnt/c/ (NTFS) | ~10 min |
| WSL2 native filesystem | ~5-7 min (estimated) |
| Native Linux | ~5 min |

Build uses 16 parallel threads by default (configurable in QSF).

## Resource Usage (vanilla C64 core)

- Logic cells: ~52,600 (of 41,910 ALMs available)
- RAM segments: 1,452
- DSP elements: 51
- PLLs: 1 (of 6 available)
- Routing: ~17% average, 30% peak

## Troubleshooting

### "Tcl Script File sys/pll_q22.qip not found"
Create the file as described in the PLL fix section above.

### "Node instance pll_hdmi instantiates undefined entity"
The PLL QIP file is missing or not being included. Check that `sys/pll_q{VER}.qip` exists
for your Quartus major version number.

### Timing failures (negative setup slack)
A small negative slack on the HDMI PLL clock (-0.2ns) is normal when building with
Quartus 22 instead of 17. This does not affect functionality. For critical timing closure,
use Quartus 17.0.2.

### WSL PATH errors with parentheses
Use `wsl bash --noprofile --norc -c '...'` to avoid Windows PATH entries containing
`Program Files (x86)` from breaking bash.
