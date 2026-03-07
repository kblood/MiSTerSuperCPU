# MiSTer Debug Skill

Remote debugging and automated testing for MiSTer FPGA core development.

## Scope

Use this skill for:
- Deploying cores to MiSTer and loading them remotely
- Taking and analyzing screenshots of running cores
- Reading debug UART output for CPU state inspection
- Sending keyboard input for OSD navigation
- Running the full build-deploy-test loop
- AI-assisted visual analysis of debug overlay

For generic MiSTer access, see [Skill_MiSTer.md](Skill_MiSTer.md).
For C64-specific paths and ROMs, see [Skill_MiSTer_C64.md](Skill_MiSTer_C64.md).
For full research on available approaches, see [docs/mister_remote_debug_research.md](docs/mister_remote_debug_research.md).

## Quick Reference

| Task | Command |
|------|---------|
| Deploy + load core | `python tools/mister_debug.py deploy` |
| Take screenshot | `python tools/mister_debug.py screen` |
| Read debug UART | `python tools/mister_debug.py uart 3` |
| Send keys | `python tools/mister_debug.py keys "MDDDO"` |
| Check status | `python tools/mister_debug.py status` |
| Reboot MiSTer | `python tools/mister_debug.py reboot` |

## Prerequisites

- SSH key auth to MiSTer configured (root@192.168.50.130)
- Python 3 available
- For debug UART: enable "Debug UART" in OSD (status[87])
- For debug overlay: enable "Debug Overlay" in OSD (status[83])
- Optional: [mrext Remote](https://github.com/wizzomafizzo/mrext) for HTTP API

## Tool: mister_debug.py

Location: `tools/mister_debug.py`

Environment variables:
- `MISTER_HOST` - MiSTer IP (default: `192.168.50.130`)
- `MISTER_USER` - SSH user (default: `root`)
- `MISTER_DEST` - Core deploy path (default: `/media/fat/_Test/C64.rbf`)

### deploy

Copies the .rbf to MiSTer and loads it via `/dev/MiSTer_cmd`.

```bash
# Deploy default build output
python tools/mister_debug.py deploy

# Deploy specific .rbf
python tools/mister_debug.py deploy path/to/custom.rbf
```

Default .rbf path: `C64_MiSTer/output_files/C64.rbf`

The core loads immediately. Allow ~5 seconds for boot to READY prompt.

### screen

Triggers a screenshot and retrieves the PNG file.

```bash
# Save to default (mister_screen.png)
python tools/mister_debug.py screen

# Save to specific path
python tools/mister_debug.py screen captures/test1.png
```

Screenshots are saved by MiSTer to `/media/fat/screenshots/{corename}/`.

### uart

Reads debug UART output from `/dev/ttyS1`.

```bash
# Read for 3 seconds (default)
python tools/mister_debug.py uart

# Read for 10 seconds
python tools/mister_debug.py uart 10
```

Requires "Debug UART" enabled in OSD. Output format (one line per frame):
```
A:E544 D:AD B:00 S:01FF P:34 I:AD E:1 F:003A
```

Fields:
| Field | Description |
|-------|-------------|
| A:xxxx | CPU address bus (16-bit) |
| D:xx | CPU data bus (8-bit) |
| B:xx | Bank register (A23-A16) |
| S:xxxx | Stack pointer (16-bit) |
| P:xx | Processor status register |
| I:xx | Current opcode (instruction register) |
| E:x | Emulation mode (1=6502 emu, 0=native) |
| F:xxxx | Frame counter (for freeze detection) |

### keys

Sends keyboard sequences via `mbc raw_seq`.

```bash
# Open OSD (F12)
python tools/mister_debug.py keys "M"

# Navigate OSD: F12, down 5x, enter
python tools/mister_debug.py keys "MDDDDDO"
```

Key codes for `mbc raw_seq`:
| Code | Key |
|------|-----|
| M | F12 (OSD toggle) |
| U | Up |
| D | Down |
| L | Left |
| R | Right |
| O | Enter |
| E | Escape |

Note: `mbc` (MiSTer Batch Control) must be installed on MiSTer. Get it from
[pocomane/MiSTer_Batch_Control](https://github.com/pocomane/MiSTer_Batch_Control).

### status

Checks MiSTer reachability, uptime, active core, and debug UART output.

```bash
python tools/mister_debug.py status
```

## Tool: kick-mister-deploy

Location: `tools/kick-mister-deploy`

Quick bash one-liner for deploy+load only (no Python needed):

```bash
./tools/kick-mister-deploy
./tools/kick-mister-deploy path/to/other.rbf
```

## Debug UART (FPGA Side)

### Architecture

Two SystemVerilog modules in `C64_MiSTer/rtl/`:

| Module | File | Function | Resource Cost |
|--------|------|----------|---------------|
| `debug_uart_tx` | `debug_uart_tx.sv` | 115200 baud 8N1 UART transmitter | ~50 LUTs |
| `debug_uart_fmt` | `debug_uart_fmt.sv` | Formats CPU state to ASCII hex | ~100 LUTs |

### How It Works

1. At each vblank (50/60Hz), `debug_uart_fmt` latches current CPU state
2. It serializes a 45-character ASCII line through `debug_uart_tx`
3. The UART output drives `UART_TXD` (overriding C64 RS232 when enabled)
4. MiSTer Linux sees the output on `/dev/ttyS1` at 115200 baud

### OSD Control

`status[87]` = Debug UART toggle. When ON:
- UART_TXD carries debug data instead of C64 RS232
- One line per frame at 115200 baud (~4ms per line)
- C64 RS232 user port functionality is disabled

When OFF:
- UART_TXD carries normal C64 RS232 output
- No debug data is transmitted

### Adding More Debug Data

To add new fields to the UART output, edit `debug_uart_fmt.sv`:
1. Add the new signal as an input port
2. Add latching in the vblank block
3. Extend the `LINE_LEN` parameter
4. Add character entries in the `case (char_idx)` block
5. Wire the new input in `c64.sv` where the module is instantiated

## Debug Overlay (FPGA Side)

### Architecture

Module: `debug_overlay.sv` in `C64_MiSTer/rtl/`

Renders 4 rows of hex debug data in the VIC-II top border area using a
self-contained 4x6 pixel font. White text on solid black background for
maximum readability (both human and AI/OCR).

### Display Layout

```
Row 1: A:xxxx B:xx K:xx R:xx   (addr, bank, max bank seen, addr at max bank)
Row 2: S:xxxx P:xx I:xx E:x    (stack pointer, status, opcode, emulation mode)
Row 3: W:xxxx D:xx P:xxxx oo   (screen RAM write tracking)
  -or- C:vvvv M:x D:DD P:PPPP  (VIC c-access anomaly, if detected)
Row 4: M:x F:xx P:xx C:xx Fxx  (test mode, counters, frame counter)
```

The **frame counter** (`Fxx` in row 4) is an 8-bit rolling counter that
increments each frame. If this value stops changing across screenshots,
the system is frozen.

### OSD Control

`status[83]` = Debug Overlay toggle. Appears in OSD under SuperCPU section.

## AI-Assisted Debug Workflow

### Full Build-Deploy-Test Loop

```bash
# 1. Build (syntax check or full)
powershell.exe -ExecutionPolicy Bypass -File build_c64.ps1 -SyntaxOnly
# or for full build:
powershell.exe -ExecutionPolicy Bypass -File build_c64.ps1

# 2. Deploy to MiSTer
python tools/mister_debug.py deploy

# 3. Wait for boot
sleep 5

# 4. Capture screenshot (with debug overlay enabled)
python tools/mister_debug.py screen captures/test.png

# 5. Read debug UART
python tools/mister_debug.py uart 2

# 6. Analyze results, make changes, repeat
```

### What the AI Agent Can Read

**From screenshots** (using Claude's vision capability):
- Debug overlay hex values (white on black, top border)
- Whether C64 booted to READY prompt
- Screen corruption, artifacts, wrong colors
- Error messages or test results

**From debug UART** (structured text):
- Exact CPU register state each frame
- Frame counter for freeze detection
- Bank register to verify extended addressing
- Emulation mode flag

### Interpreting Common States

| UART Output | Meaning |
|-------------|---------|
| `A:E544 ... E:1 F:xxxx` | Normal boot, emulation mode, frames advancing |
| `A:xxxx ... E:1 F:0000` | Frame counter stuck = system frozen |
| `A:xxxx ... E:0` | Native 65C816 mode active |
| `B:01` or higher | Accessing extended bank (SuperCPU memory) |
| `I:00 ... F:xxxx` (unchanging A) | CPU executing BRK or stuck in loop |

### Common Debug Scenarios

**Core doesn't boot (black screen)**:
1. `python tools/mister_debug.py uart 5` - check if UART produces output
2. If no output: CPU is completely stuck (reset issue, clock issue)
3. If output shows: check A/I fields for where CPU is stuck

**Core boots but has visual artifacts**:
1. `python tools/mister_debug.py screen` - capture the artifacts
2. Enable debug overlay in OSD: `python tools/mister_debug.py keys "MDDDDDDO"`
3. Take another screenshot with overlay visible
4. AI reads overlay values to correlate CPU state with artifacts

**SuperCPU mode doesn't work**:
1. Enable SuperCPU in OSD
2. `python tools/mister_debug.py uart 3` - verify E:0 appears (native mode)
3. Check B:xx for bank access
4. Run dead test cartridge for systematic verification

## Direct SSH Commands (No Python)

For when you need raw access without the Python wrapper:

```bash
# Deploy
scp C64_MiSTer/output_files/C64.rbf root@192.168.50.130:/media/fat/_Test/

# Load core
ssh root@192.168.50.130 'echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd'

# Screenshot
ssh root@192.168.50.130 'echo "screenshot" > /dev/MiSTer_cmd'
sleep 1
scp root@192.168.50.130:/media/fat/screenshots/C64/*.png .

# Read UART (2 second capture)
ssh root@192.168.50.130 'timeout 2 cat /dev/ttyS1'

# Send keys (requires mbc installed)
ssh root@192.168.50.130 'mbc raw_seq "MDDDO"'
```

## /dev/MiSTer_cmd Reference

Commands accepted by the MiSTer main binary via the command pipe:

| Command | Description |
|---------|-------------|
| `load_core <path>` | Load a core (.rbf) or MGL file |
| `screenshot` | Take a screenshot of current output |

## mrext Remote API (Optional)

If [mrext Remote](https://github.com/wizzomafizzo/mrext) is installed, a REST
API is available on port 8182:

```bash
# Install on MiSTer
ssh root@192.168.50.130 \
  'curl -L https://github.com/wizzomafizzo/mrext/releases/latest/download/remote \
   -o /media/fat/Scripts/remote && chmod +x /media/fat/Scripts/remote'

# Start it
ssh root@192.168.50.130 '/media/fat/Scripts/remote &'
```

Then use HTTP:
```bash
# Take screenshot
curl -X POST http://192.168.50.130:8182/api/screenshots

# List screenshots
curl http://192.168.50.130:8182/api/screenshots

# Send keyboard key
curl -X POST http://192.168.50.130:8182/api/controls/keyboard/f12

# Launch core
curl -X POST http://192.168.50.130:8182/api/launchers/launch \
  -d '{"path":"/media/fat/_Test/C64.rbf"}'

# Get system info
curl http://192.168.50.130:8182/api/sysinfo
```

Full API docs: https://github.com/wizzomafizzo/mrext/blob/main/docs/remote-api.md

## HPS-FPGA Communication Architecture

MiSTer does NOT use the Cyclone V lightweight bridge (0xFF200000). Instead it
uses a software SPI protocol over the MPU General Purpose Interface:

- GPO (ARM to FPGA): `0xFF706010` — 16-bit data + strobe + select lines
- GPI (FPGA to ARM): `0xFF706014` — 16-bit response + ack

The `hps_io.sv` module decodes commands from the ARM binary. Status register
(128-bit) is the primary control channel. Our debug signals use:
- `status[83]` — Debug Overlay enable
- `status[85:84]` — LED debug mode
- `status[87]` — Debug UART enable

For deeper technical details, see [docs/mister_remote_debug_research.md](docs/mister_remote_debug_research.md).
