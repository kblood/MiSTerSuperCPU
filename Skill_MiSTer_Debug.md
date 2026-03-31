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
| Screenshot with OSD | `python tools/mister_debug.py osd_screen` |
| Read debug UART | `python tools/mister_debug.py uart 3` |
| Send keys | `python tools/mister_debug.py keys "MDDDO"` |
| Open OSD remotely | `python tools/mister_debug.py keys "M"` |
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

### osd_screen

Opens the OSD and takes a screenshot capturing the OSD overlay via an HDMI
capture device (OBS window capture). Falls back to MiSTer's built-in screenshot
if OBS is not available (but the built-in method cannot capture the OSD overlay).

```bash
# Save to default (mister_osd_screen.png)
python tools/mister_debug.py osd_screen

# Save to specific path
python tools/mister_debug.py osd_screen captures/osd_check.png
```

**How it works:**

MiSTer's built-in `screenshot` and `screenshot scaled` commands capture the FPGA
video output **before** the OSD overlay is composited in the video pipeline. The
OSD is mixed in hardware at the final HDMI output stage, so no MiSTer-side
screenshot method can capture it. The tool uses these methods in order:

1. **OBS Window Capture (preferred):** If OBS Studio is running on the local
   Windows machine with an HDMI capture source (e.g., Genki Shadowcast), the
   tool captures the OBS preview window using PIL `ImageGrab`. This captures
   exactly what the HDMI output shows, including the OSD overlay.
2. **MiSTer built-in screenshot (fallback):** Uses `echo "screenshot" > /dev/MiSTer_cmd`
   which captures the core video only (no OSD).

The workflow:
1. Sends F12 via `mtype.py` (uinput virtual keyboard) to open the OSD
2. Waits for OSD to render (~1s)
3. Captures the OBS window (or MiSTer screenshot as fallback)
4. Optionally sends F12 again to close the OSD
5. Saves the PNG locally

**Important:** `mbc raw_seq` does NOT work for sending F12 to open the OSD.
MiSTer's main binary filters out mbc's virtual input device. Only `mtype.py`
works because it creates a uinput device with USB-like identifiers that MiSTer
accepts. See the keys command below for details.

You can also do this manually:
```bash
# Open OSD (mtype.py — the ONLY working remote keyboard method)
python tools/mister_debug.py keys "M"    # or: ssh ... "python3 /tmp/mtype.py f12"
sleep 1
# Capture via OBS window (Python on local machine)
python -c "from PIL import ImageGrab; ImageGrab.grab(all_screens=True).save('full.png')"
# Close OSD
python tools/mister_debug.py keys "M"
```

### MiSTer Screenshot Methods Compared

| Method | Captures OSD? | What it captures |
|--------|--------------|------------------|
| `echo "screenshot" > /dev/MiSTer_cmd` | **No** | Core video at native resolution |
| `echo "screenshot scaled" > /dev/MiSTer_cmd` | **No** | Core video scaled by ASCAL |
| `fbgrab /tmp/fb.png` | **No** | Linux framebuffer (login console) |
| OBS + HDMI capture device | **Yes** | Full HDMI output including OSD |
| Physical camera / HDMI capture card | **Yes** | Full display output |

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

Sends keyboard input to MiSTer via `mtype.py` (uinput virtual keyboard).
Accepts both mbc-style shorthand and mtype.py native key names.

```bash
# Open OSD (F12) — shorthand
python tools/mister_debug.py keys "M"

# Navigate OSD: F12, down 5x, enter — shorthand
python tools/mister_debug.py keys "MDDDDDO"

# Using mtype.py native key names
python tools/mister_debug.py keys f12 down down down enter
```

Key codes (mbc-style shorthand):
| Code | Key |
|------|-----|
| M | F12 (OSD toggle) |
| U | Up |
| D | Down |
| L | Left |
| R | Right |
| O | Enter |
| E | Escape |

**Why mtype.py, not mbc:** `mbc raw_seq` creates a virtual input device that
MiSTer's main binary **filters out** — keypresses are silently ignored.
`mtype.py` works because it creates a uinput device with realistic USB
identifiers (`Phys=usb-ffb40000.usb-1.9/input0`, vendor=0x04d9, product=0x0006)
that MiSTer recognizes as a real keyboard. Each mtype.py call takes ~7 seconds
(6s device settle time + 1s for keypress). The tool falls back to mbc if
mtype.py fails.

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

Commands accepted by the MiSTer main binary via the command pipe
(source: `input.cpp` in [Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer)):

| Command | Description |
|---------|-------------|
| `load_core <path>` | Load a core (.rbf) or MGL file |
| `screenshot` | Take a raw screenshot of current output |
| `screenshot scaled` | Take a scaled screenshot of current output |
| `screenshot scaled <path>` | Take a scaled screenshot, save to specific path |
| `video_mode <mode>` | Change video output mode |
| `volume mute` | Mute audio |
| `volume unmute` | Unmute audio |
| `volume <0-7>` | Set volume level (0=lowest, 7=highest) |
| `fb_cmd <args>` | Framebuffer video command |

**Note:** There is NO `open_osd` command. To open/close the OSD remotely,
send an F12 keypress via `mtype.py` (uinput). **`mbc raw_seq` does NOT work**
for this — MiSTer filters out mbc's virtual input device.

### Remote OSD + Screenshot Workflow

**Critical:** MiSTer's `screenshot` command captures the FPGA video output
**before** the OSD overlay is composited. Neither `screenshot` nor
`screenshot scaled` will include the OSD. To capture the OSD, you need an
external HDMI capture method (OBS + capture device).

**Method 1: OBS Window Capture (recommended)**
```bash
# Open OSD via mtype.py (the only working remote keyboard method)
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"

# Capture OBS window from local Windows machine (requires PIL)
python -c "
from PIL import ImageGrab
img = ImageGrab.grab(all_screens=True)
# Crop to OBS window coordinates (adjust for your setup)
img.save('osd_screenshot.png')
"

# Close OSD
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"
```

**Method 2: MiSTer screenshot (no OSD, core video only)**
```bash
# Open OSD
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"
sleep 8

# Take screenshot (will NOT include OSD overlay)
ssh root@192.168.50.130 'echo "screenshot" > /dev/MiSTer_cmd'
sleep 1

# Close OSD
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"

# Retrieve screenshot
scp root@192.168.50.130:/media/fat/screenshots/C64/*.png .
```

Or use the integrated command:
```bash
python tools/mister_debug.py osd_screen captures/osd_check.png
```

## Loading REU Files via OSD

### File Browser Path Configuration

The MiSTer C64 core remembers the last directory used for each file slot in
`/media/fat/config/C64.f{n}` (64-byte fixed-length record, null-padded, path
relative to `/media/fat/` with `../` prefix).

| Slot | File | OSD Option |
|------|------|-----------|
| F1 | `C64.f1` (or `C64.f5`?) | Load *.PRG,CRT,REU,TAP |
| F2 | `C64.f2` | Load REU *.REU |
| F5 | `C64.f5` | ROM/Kernal selector |
| F8 | `C64.f8` | Mount #8 disk |
| F9 | `C64.f9` | Mount #9 disk |

To pre-seed the REU file browser to open in a specific directory:

```python
# Run on MiSTer via SSH
path = '../usb0/games/C64/scpu/doom/doom.reu'  # must be a file, not just dir
data = path.encode('ascii') + b'\x00' * (64 - len(path))
open('/media/fat/config/C64.f2', 'wb').write(data)
```

**Note:** This only takes effect when the core starts (it reads config on load).
To apply without restarting the core, copy your .reu file into whatever directory
the browser is currently showing — it refreshes when you navigate in/out.

### OSD Navigation to Load doom.reu

The file browser for "Load REU *.REU" defaults to `/media/usb0/C64/` on this
MiSTer setup. doom.reu lives at `/media/usb0/games/C64/scpu/doom/doom.reu`
but a copy also exists at `/media/usb0/C64/doom.reu` for quick OSD access.

**Step-by-step remote mount of doom.reu:**

```bash
# 1. Open OSD
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"

# 2. Navigate to "Load REU *.REU" (4 downs from top, then Enter)
#    Menu order: Mount#8, Mount#9, Mount Write Protected, Load*.PRG, Load REU
ssh root@192.168.50.130 "python3 /tmp/mtype.py down down down down enter"

# 3. Capture to confirm file browser is open and doom is visible
python tools/mister_debug.py osd_screen captures/browser.png

# 4. doom appears ABOVE test (alphabetically) — one Up from default cursor pos, then Enter
ssh root@192.168.50.130 "python3 /tmp/mtype.py up enter"

# 5. Capture to confirm load bar
python tools/mister_debug.py osd_screen captures/loading.png
```

**CRITICAL:** Keep each mtype.py call minimal. Sending too many keypresses in
one call causes OSD state transitions mid-burst, and remaining keypresses
leak through to the C64 BASIC interpreter.

### doom.reu Locations on MiSTer

| Path | Notes |
|------|-------|
| `/media/usb0/C64/doom.reu` | **Use this** — default OSD browser dir |
| `/media/usb0/games/C64/scpu/doom/doom.reu` | Original location (with loader.prg) |

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
