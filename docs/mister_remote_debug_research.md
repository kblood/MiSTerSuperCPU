# MiSTer Remote Control & AI-Assisted Debug Research

## Executive Summary

This document surveys all known approaches for remotely controlling, debugging, and
automating MiSTer FPGA core development — with a focus on enabling an AI agent (Claude)
to participate in the debug loop. Approaches are ranked by **feasibility** and
**value for our SuperCPU project**.

---

## Table of Contents

1. [Approach 1: hps_io UART Debug Channel (BEST)](#approach-1)
2. [Approach 2: mrext Remote API + Screenshots](#approach-2)
3. [Approach 3: MiSTer_Batch_Control + /dev/MiSTer_cmd](#approach-3)
4. [Approach 4: Enhanced On-Screen Debug Overlay + Vision](#approach-4)
5. [Approach 5: HPS-FPGA Debug via SPI Protocol Extension](#approach-5)
6. [Approach 6: Screenshot_MiSTer Direct Framebuffer Capture](#approach-6)
7. [Approach 7: HDMI Capture + AI Vision](#approach-7)
8. [Approach 8: JTAG UART (Tom Verbeure)](#approach-8)
9. [Approach 9: In-System Memory Content Editor](#approach-9)
10. [Approach 10: SignalTap via Command Line](#approach-10)
11. [Approach 11: Virtual JTAG Custom Debug](#approach-11)
12. [Approach 12: Open-Source Embedded Logic Analyzers](#approach-12)
13. [Approach 13: Remote JTAG via jtagd/USB-IP](#approach-13)
14. [Critical Architecture Note: How MiSTer HPS-FPGA Actually Works](#hps-architecture)
15. [Recommended Architecture](#recommended-architecture)

---

<a name="hps-architecture"></a>
## Critical Architecture Note: How MiSTer HPS-FPGA Actually Works

**IMPORTANT CORRECTION**: The MiSTer framework does **NOT** use the Cyclone V's
AXI bridges (lightweight `0xFF200000` or full `0xC0000000`) for core communication.

While `fpga_core_read()`/`fpga_core_write()` exist in `fpga_io.cpp` and reference
`0xFF200000`, the **lightweight bridge is NOT instantiated** in `sys_top.v`. Those
functions would read undefined values. The `cyclonev_hps_interface_hps2fpga_light_weight`
primitive is simply not present in the MiSTer design.

### What MiSTer Actually Uses: GPO/GPI Software SPI

MiSTer uses the **MPU General Purpose Interface** — a pair of 32-bit registers in
the Cyclone V HPS hard block:

```verilog
// sys_top.v line 281
cyclonev_hps_interface_mpu_general_purpose h2f_gp (
    .gp_in({~gp_out[31] ? core_magic : gp_in}),
    .gp_out(gp_out)
);
```

- **GPO** (ARM→FPGA): `SOCFPGA_MGR_ADDRESS + 0x10` = `0xFF706010`
- **GPI** (FPGA→ARM): `SOCFPGA_MGR_ADDRESS + 0x14` = `0xFF706014`

The framework implements a **software SPI-like protocol** over these GPIO registers:

**GPO bit assignments** (ARM→FPGA):
| Bits | Signal | Description |
|------|--------|-------------|
| [15:0] | io_din | 16-bit data word |
| [17] | io_clk | Clock strobe (SSPI_STROBE) |
| [18] | io_ss0 | Slave select 0 |
| [19] | io_ss1 | Slave select 1 |
| [20] | io_ss2 | Slave select 2 |

**GPI bit assignments** (FPGA→ARM):
| Bits | Signal | Description |
|------|--------|-------------|
| [15:0] | io_dout | 16-bit data response |
| [17] | io_ack | Acknowledgment (SSPI_ACK) |
| [31] | ready | FPGA ready flag (0=ready) |

**Select line decoding**:
- `io_fpga` = `~io_ss1 & io_ss0` — target is the core (hps_io)
- `io_uio` = `~io_ss1 & io_ss2` — target is sys_top (system-level)
- `io_osd_hdmi` = `io_ss1 & ~io_ss0` — OSD overlay

The `fpga_spi()` function in `fpga_io.cpp` implements this protocol:
```c
uint16_t fpga_spi(uint16_t word) {
    uint32_t gpo = (fpga_gpo_read() & ~(0xFFFF | SSPI_STROBE)) | word;
    fpga_gpo_write(gpo | SSPI_STROBE);  // Assert strobe + data
    // ... wait for ACK ...
    return (uint16_t)(fpga_gpi_read());  // Read response
}
```

### DE10-Nano Bridge Status in MiSTer

| Bridge | Address | MiSTer Status |
|--------|---------|---------------|
| Lightweight HPS-to-FPGA | `0xFF200000` | **NOT instantiated** |
| Full HPS-to-FPGA | `0xC0000000` | **NOT used** |
| FPGA-to-HPS | N/A | **NOT used** (f2sdram used for DDR) |
| MPU GPO/GPI | `0xFF706010/14` | **Primary communication channel** |

### Status Register (128-bit)

The `status[127:0]` register is the main OSD→FPGA control path. Updated via
command `0x1E` (8 sequential 16-bit writes). Available unused bits:
- `status[127:87]` — 41 bits available
- `status[63:47]` — 17 bits available

### Extension Points for Debug Data

| Mechanism | Direction | Modifies sys/? | ARM Changes? | Notes |
|-----------|-----------|---------------|-------------|-------|
| Status bits | HPS→FPGA | No | No | Only 58 unused bits, OSD-controlled |
| `info` port | FPGA→HPS | No | No | Only 8 bits, shown in OSD |
| `EXT_BUS[35:0]` | Bidirectional | No | **Yes** | Core can override io_dout |
| hps_io UART | FPGA→HPS | No | No | **Existing UART_TX/RX signals!** |
| Lightweight bridge | Bidirectional | **Yes** | No | Must add primitive + devmem |

---

<a name="approach-1"></a>
## Approach 1: hps_io UART Debug Channel

### Rating: HIGHEST VALUE — Existing infrastructure, tiny FPGA cost, no ARM changes

### How It Works

**MiSTer's `hps_io.sv` already exposes UART_TX and UART_RX signals to cores!**
The `uart_mode` parameter controls routing to `/dev/ttyS1` on the MiSTer Linux side.

The core instantiates a simple UART TX module (~50 LUTs, ~0.1% of design) and
connects it to the `UART_TX` signal from hps_io. On the Linux side, debug output
appears on `/dev/ttyS1` — readable via `cat` over SSH.

### Implementation

**FPGA side** (add to c64.sv):
```systemverilog
// In hps_io instantiation, set uart_mode
.uart_mode(16'b000_11111_000_11111),
.UART_TX(uart_debug_tx),  // Connect to our debug UART

// Instantiate a simple UART TX module
uart_tx #(.CLK_FREQ(32000000), .BAUD(115200)) debug_uart (
    .clk(clk_sys),
    .tx(uart_debug_tx),
    .data(debug_byte),
    .send(debug_send),
    .busy(debug_busy)
);
```

**Debug state machine** (formats and sends CPU state):
```
A:D000 D:42 B:00 P:34 SP:01FF IR:AD WE:0 EM:1\n
```

At 115200 baud: ~11,520 chars/sec = ~200 state dumps/second.
At 230400 baud: ~400 dumps/second. Sufficient for sampled/triggered capture.

**Reading from AI agent**:
```bash
ssh root@192.168.50.130 'cat /dev/ttyS1' | head -100
# Or with timeout:
ssh root@192.168.50.130 'timeout 2 cat /dev/ttyS1'
```

### Advantages

- **Uses existing hps_io infrastructure** — no sys/ changes, no ARM binary changes
- **Tiny FPGA cost**: ~50 LUTs for UART TX
- **Always-on**: Streams data continuously without polling
- **SSH-accessible**: AI agent reads via `cat /dev/ttyS1`
- **Human-readable**: ASCII hex format viewable in any terminal
- **No extra hardware**: Uses existing USB connection

### Disadvantages

- Limited bandwidth (~11-23KB/s at 115200/230400 baud)
- Can't capture every CPU cycle at 20MHz
- Needs triggering/sampling for useful captures

### Effort: Low-Medium (1-2 days — UART TX module + formatter state machine)
### Value: Very High

---

<a name="approach-2"></a>
## Approach 2: mrext Remote API + Screenshots

### Rating: HIGH VALUE — Already exists, rich API, easy setup

### What It Is

[wizzomafizzo/mrext](https://github.com/wizzomafizzo/mrext) is a Go-based extension
suite for MiSTer. The **Remote** app provides a full REST + WebSocket API on port 8182.

### Key API Endpoints for Debug

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/screenshots` | POST | Take screenshot via /dev/MiSTer_cmd |
| `/api/screenshots/{core}/{file}` | GET | Download screenshot as PNG |
| `/api/systems/{id}` | POST | Launch a specific core |
| `/api/controls/keyboard/{name}` | POST | Send named keyboard key/combo |
| `/api/controls/keyboard-raw/{code}` | POST | Send raw uinput keycode |
| `/api/launchers/launch` | POST | Launch any file (core, ROM, MGL) |
| `/api/launchers/menu` | POST | Return to menu core |
| `/api/games/playing` | GET | Get current running game/system/core |
| `/api/games/search` | POST | Search indexed games by name |
| `/api/settings/inis/{id}` | GET/PUT | Read/write MiSTer.ini settings |
| `/api/settings/system/reboot` | POST | Reboot MiSTer |
| `/api/sysinfo` | GET | Network, disk, version info |

### WebSocket (ws://mister:8182/ws)

Real-time events + keyboard control:
- `kbd:{name}` — send named key
- `kbdRaw:{code}` — send raw keycode
- `kbdRawDown:{code}` / `kbdRawUp:{code}` — hold/release for combos
- Core status change events
- Game status change events

### AI Agent Workflow

```bash
# 1. Deploy new core
scp C64.rbf root@192.168.50.130:/media/fat/_Test/

# 2. Load core via REST API
curl -X POST http://192.168.50.130:8182/api/launchers/launch \
  -d '{"path":"/media/fat/_Test/C64.rbf"}'

# 3. Wait for boot, take screenshot
sleep 5
curl -X POST http://192.168.50.130:8182/api/screenshots

# 4. Download latest screenshot
curl http://192.168.50.130:8182/api/screenshots/C64/latest.png > screen.png

# 5. Send keyboard input (e.g., F12 to open OSD)
curl -X POST http://192.168.50.130:8182/api/controls/keyboard/f12

# 6. Claude analyzes screen.png with vision capability
```

### Setup

```bash
ssh root@192.168.50.130
curl -L https://github.com/wizzomafizzo/mrext/releases/latest/download/remote \
  -o /media/fat/Scripts/remote
chmod +x /media/fat/Scripts/remote
/media/fat/Scripts/remote  # starts on port 8182
```

### Effort: Low (1 hour setup)
### Value: High — screenshots + input + core loading, all via HTTP

---

<a name="approach-3"></a>
## Approach 3: MiSTer_Batch_Control + /dev/MiSTer_cmd

### Rating: HIGH — Already built into MiSTer, zero setup for basic use

### /dev/MiSTer_cmd

The MiSTer main binary creates a command pipe. Send commands via echo:

```bash
echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd
echo "screenshot" > /dev/MiSTer_cmd
```

### MiSTer_Batch_Control (mbc)

[pocomane/MiSTer_Batch_Control](https://github.com/pocomane/MiSTer_Batch_Control):

- `mbc load_rom <path>` — Load ROM into current core
- `mbc raw_seq <sequence>` — Emulate key sequences
  - Key codes: U(up), D(down), L(left), R(right), O(enter), E(escape), M(F12/OSD)
  - Configurable delay via `MBC_SEQUENCE_WAIT` (default 1000ms)
- `mbc load_all_as <core> <rom>` — Load specific core with ROM
- `mbc stream` — Read commands from stdin (for scripting)
- `mbc mgl_gen` — Generate MGL files programmatically

### AI Agent Workflow (SSH only, no mrext needed)

```bash
# Deploy and load
scp C64.rbf root@192.168.50.130:/media/fat/_Test/
ssh root@192.168.50.130 'echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd'

# Wait for boot, navigate OSD to enable SuperCPU
sleep 5
ssh root@192.168.50.130 'mbc raw_seq "MDDDDDO"'  # F12, down 5x, enter

# Take screenshot
ssh root@192.168.50.130 'echo "screenshot" > /dev/MiSTer_cmd'
sleep 1

# Retrieve screenshot
scp root@192.168.50.130:/media/fat/screenshots/C64/*.png ./
```

### Effort: Very Low (already available)
### Value: High for basic automation

---

<a name="approach-4"></a>
## Approach 4: Enhanced On-Screen Debug Overlay + Vision

### Rating: HIGH — Already partially implemented, leverages Claude's vision

### Current State

We already have `debug_overlay.sv` displaying hex debug values in the VIC-II
top border. Currently shows: CPU Address, Bank, Max Bank, SP, P, IR, Emulation,
screen RAM write tracking, VIC-II anomaly counters.

### How Claude Reads It

```
Screenshot (mrext or /dev/MiSTer_cmd) → PNG → Claude Vision → Parse hex values
```

Claude can reliably read fixed-position hex text from screenshots when the text
is clear and consistently positioned. The debug overlay is a "printf to screen"
that Claude can read.

### Enhancements for AI Readability

1. **Structured layout**: Fixed character positions for each value with labels
2. **High contrast**: White text on solid black background band (no transparency)
3. **Frame counter**: Incrementing value to detect freezes (stale screenshots)
4. **Health checksum**: Single value encoding "system healthy" vs "stuck"
5. **Mode indicator**: Large visible text showing current CPU mode

### Effort: Low (enhance existing overlay)
### Value: High — zero additional infrastructure needed

---

<a name="approach-5"></a>
## Approach 5: HPS-FPGA Debug via SPI Protocol Extension

### Rating: MEDIUM-HIGH — Powerful but requires ARM-side tooling

### How It Works

Extend the existing `hps_io` SPI-like protocol with custom debug read commands.
The FPGA side adds a handler for a new command code (e.g., `0x50`) in the io_fpga
channel. A small ARM-side C program uses `fpga_spi()` to send the command and
read back debug data.

### FPGA Side (in c64.sv or fpga64_sid_iec.vhd)

The `hps_io` module already passes through `EXT_BUS[35:0]`. When `EXT_BUS[32]=1`,
the core can override `io_dout` (the data returned to the ARM). We add logic that:

1. Detects command `0x50` on `io_fpga` channel
2. Returns sequential 16-bit words of debug data:
   - Word 0: `cpu_addr[15:0]`
   - Word 1: `{cpu_bank, cpu_data}`
   - Word 2: `cpu_sp[15:0]`
   - Word 3: `{cpu_p, cpu_ir}`
   - Word 4: `{flags, counters...}`

### ARM Side

A small C program (cross-compiled with MiSTer Toolchain) that:
1. Opens `/dev/mem`, mmaps `0xFF706000` (FPGA Manager GPO/GPI)
2. Sends `fpga_spi()` sequence: select io_fpga, send cmd 0x50, read N words
3. Prints formatted debug state to stdout

**Problem**: This conflicts with the Main_MiSTer binary which owns the GPO/GPI
interface. You'd need to either:
- Stop Main_MiSTer temporarily while reading debug data
- Modify Main_MiSTer to add the debug read command
- Use a shared memory / IPC mechanism

### Effort: Medium-High (ARM toolchain + conflict with Main_MiSTer)
### Value: High — sub-millisecond reads, but complex integration

---

<a name="approach-6"></a>
## Approach 6: Screenshot_MiSTer Direct Framebuffer Capture

### Rating: MEDIUM-HIGH — Direct memory access, no API dependency

### How It Works

[alanswx/Screenshot_MiSTer](https://github.com/alanswx/Screenshot_MiSTer) reads
the **ASCAL scaler's framebuffer** directly from memory via `/dev/mem`:

- ASCAL triple-buffers frames starting at `0x20000000` (512MB mark in DDR3)
- Linux uses first 512MB; ASCAL buffers are in the second 512MB (no conflict)
- Buffer addresses: `0x20000000`, `0x20800000`, `0x21000000`
- Header at `0x20000005` contains frame counter (bits 7-5) for sync
- Outputs PNG via lodepng library

### Usage

```bash
# On MiSTer
./screenshot_mister /tmp/capture.png

# From dev machine
ssh root@192.168.50.130 './screenshot_mister /tmp/capture.png'
scp root@192.168.50.130:/tmp/capture.png ./
```

### Advantages Over mrext Screenshots

- Works even if Main_MiSTer is not running
- Captures at native resolution before any scaling
- Can poll frame counter for precise timing
- No REST API overhead

### Effort: Low (compile and deploy existing tool)
### Value: Medium-High

---

<a name="approach-7"></a>
## Approach 7: HDMI Capture + AI Vision

### Rating: MEDIUM — Best for real-time video, requires hardware

### Hardware Options

| Device | Price | Notes |
|--------|-------|-------|
| MS2130-based USB3 dongle (marked "U3") | $10-15 | Best cheap option, good Linux support |
| MS2109-based USB2 dongle | $5-10 | MJPEG only at high res |
| Elgato Cam Link 4K | $100 | Appears as UVC webcam |
| Magewell USB Capture HDMI | $300+ | Professional, excellent Linux support |

### Software

```bash
# Single frame capture with ffmpeg
ffmpeg -f v4l2 -video_size 1920x1080 -input_format mjpeg \
  -i /dev/video0 -frames:v 1 capture.png

# Python with OpenCV
import cv2
cap = cv2.VideoCapture(0)
ret, frame = cap.read()
cv2.imwrite('capture.png', frame)
```

### Notable: hsdaoh Project

[hsdaoh](https://github.com/steve-m/hsdaoh) repurposes MS2130 USB3 capture sticks
as general-purpose high-speed data interfaces for FPGAs, achieving up to 175 MB/s.
Could theoretically stream raw debug data over HDMI signal instead of video.

### Effort: Low-Medium ($10 + capture script)
### Value: Medium — best for visual regression testing, overkill for register reads

---

<a name="approach-8"></a>
## Approach 8: JTAG UART (Tom Verbeure)

### Rating: MEDIUM — Elegant, tiny, uses existing JTAG connection

### How It Works

Intel's JTAG UART core provides a **virtual serial port over the existing USB-Blaster
JTAG connection**. No additional pins or cables needed.

Resources by Tom Verbeure:
- [Blog: The Intel JTAG UART](https://tomverbeure.github.io/2021/05/02/Intel-JTAG-UART.html)
- [Example project](https://github.com/tomverbeure/jtag_uart_example)
- [Python client](https://github.com/tomverbeure/intel_jtag_uart)

### Resource Cost

| Component | ALMs | Notes |
|-----------|------|-------|
| JTAG UART core | ~57 | Plus small BRAM for FIFOs |
| SLD hub overhead | ~99 | Shared with SignalTap if present |

Total: **~57 ALMs** (0.14% of Cyclone V) — extremely lightweight.

### Reading Data

```bash
# Using Quartus nios2-terminal
nios2-terminal

# Using Tom Verbeure's Python client (libjtag_atlantic)
python3 jtag_uart_read.py
```

### Disadvantages

- Requires USB-Blaster JTAG connection (not available over network without jtagd)
- Lower bandwidth than dedicated UART
- Requires Quartus installation on reading machine
- May conflict with SignalTap

### Effort: Medium (instantiate via Qsys + write formatter)
### Value: Medium — good if you already have JTAG connected

---

<a name="approach-9"></a>
## Approach 9: In-System Memory Content Editor

### Rating: MEDIUM — Zero ALMs, fully scriptable, JTAG-based

### How It Works

Add a dual-port Block RAM to the design. One port is written by your debug logic
(CPU state captured each cycle). The other port is accessible via JTAG for reading.
Quartus's In-System Memory Content Editor reads it.

### Resource Cost

- **0 ALMs** — uses only 1 M10K block (you have 553 available)
- Must mark the RAM with `(* ramstyle = "MLAB,logic" *)` or use IP with JTAG access

### Scripted Reading (TCL via quartus_stp)

```tcl
package require ::quartus::insystem_memory_edit

begin_memory_edit \
    -hardware_name "DE-SoC [USB-1]" \
    -device_name "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"

# Read 256 words from debug RAM
set data [read_content_from_memory \
    -instance_index 0 \
    -content_in_hex \
    -start_address 0 \
    -word_count 256]

puts $data

# Save to file
save_content_from_memory_to_file \
    -instance_index 0 \
    -mem_file_path "debug_dump.mif" \
    -mem_file_type mif

end_memory_edit
```

### Python Wrapper

The [quartustcl](https://quartustcl.readthedocs.io/en/latest/example-memory/) Python
package wraps these TCL commands for scripted access.

### Practical Application

Add a 4K x 32-bit dual-port RAM as a "debug register file":
- Port A: Written by RTL (CPU addr, data, bank, flags on each cycle)
- Port B: Read via JTAG at any time without stopping the design
- Cost: 1 M10K block, 0 ALMs

### Effort: Medium
### Value: Medium — powerful for deep trace, but needs JTAG connection

---

<a name="approach-10"></a>
## Approach 10: SignalTap via Command Line

### Rating: MEDIUM — Powerful but requires recompilation per signal set

### Command-Line Usage

```bash
# Enable SignalTap
quartus_stp myproject --stp_file debug.stp --enable
quartus_sh --flow compile myproject

# Program FPGA
quartus_pgm -m jtag -o "p;output_files/C64.sof"

# Run capture via TCL
quartus_stp -t capture_script.tcl
```

### TCL Capture Script

```tcl
package require ::quartus::stp

open_session -name "debug.stp"
run -instance "auto_signaltap_0" \
    -signal_set "signal_set_1" \
    -trigger "trigger_1" \
    -data_log "log_1" \
    -timeout 5
close_session
```

### Resource Cost (configurable)

A minimal instance with 8 signals, 1K depth: ~200-400 ALMs + 1 M10K block.

### Key Limitation

Adding/removing signals requires **recompilation** (~10 min). Signal paths are
post-synthesis names that change across builds. Not practical for AI automation.

### Reference: bladeRF build.tcl

The [bladeRF project](https://github.com/Nuand/bladeRF/blob/master/hdl/quartus/build.tcl)
demonstrates scripted SignalTap integration in a Quartus build flow.

### Effort: High (setup + recompilation cycle)
### Value: Medium — powerful for specific investigations, poor for automation

---

<a name="approach-11"></a>
## Approach 11: Virtual JTAG Custom Debug

### Rating: MEDIUM-LOW — Elegant but JTAG-dependent

Intel's `sld_virtual_jtag` IP creates custom scan chains (up to 254 clients).
Pre-wire debug signals to data registers, read via TCL scripts.

```tcl
device_lock -timeout 10000
virtual_ir_shift -instance_index 0 -ir_value 0x01 -no_captured_ir_value
set data [virtual_dr_shift -instance_index 0 -length 16 -value_in_hex]
device_unlock
```

### Effort: Medium-High
### Value: Medium-Low — HPS UART is simpler and doesn't need JTAG

---

<a name="approach-12"></a>
## Approach 12: Open-Source Embedded Logic Analyzers

| Project | Notes |
|---------|-------|
| [SUMP2/SUMP3](https://github.com/blackmesalabs/sump2) | Verilog, UART comms, PulseView/sigrok compatible |
| [LiteScope](https://github.com/enjoy-digital/litescope) | Python/Migen, part of LiteX ecosystem |
| [Enxor](https://github.com/lekgolo167/enxor-logic-analyzer) | Pure Verilog, no vendor IP |

Essentially building what SignalTap already does. Only worth it if you need
non-Quartus-dependent analysis.

### Effort: High
### Value: Low-Medium

---

<a name="approach-13"></a>
## Approach 13: Remote JTAG via jtagd / USB-IP

### Intel jtagd

```bash
# Machine with USB-Blaster:
jtagconfig --enableremote mypassword

# Remote machine (~/.jtag.conf):
# Remote1 { Host = "192.168.50.130:1309"; Password = "mypassword"; }
```

All Quartus tools (SignalTap, programmer, System Console) work transparently
over remote jtagd on TCP port 1309.

### SSH Tunnel Alternative

Documented by [Molnar Peter](https://www.molnar-peter.hu/en/altera-quartusii-remote-jtag-programming-over-ssh-tunnel.html):
tunnel jtagd port 1309 over SSH for secure access without firewall changes.

### Intel libaji_client

[intel/libaji_client](https://github.com/intel/libaji_client) — open-source client
library for the JTAG server protocol.

### Effort: High (setup + USB-Blaster access)
### Value: Low for debug reads — better alternatives exist via HPS

---

<a name="recommended-architecture"></a>
## Recommended Architecture: Layered Debug System

### Layer 1: Quick & Free (DO NOW — hours)

**SSH automation + /dev/MiSTer_cmd + Screenshots + Debug Overlay**

What we have today:
- SSH to MiSTer at 192.168.50.130 (already working)
- SCP to deploy .rbf files (already working)
- `/dev/MiSTer_cmd` for core loading (built-in)
- Debug overlay on screen (already implemented, `status[83]`)

What to add:
- Install mrext Remote for HTTP API (screenshots, keyboard, core loading)
- OR use `echo "screenshot" > /dev/MiSTer_cmd` + SCP (no install needed)
- Claude analyzes downloaded PNGs with vision to read debug overlay values

**Automated test loop**:
```bash
# Build
./build_c64.ps1

# Deploy
scp C64_MiSTer/output_files/C64.rbf root@192.168.50.130:/media/fat/_Test/

# Load
ssh root@192.168.50.130 'echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd'

# Wait + Screenshot
sleep 5
ssh root@192.168.50.130 'echo "screenshot" > /dev/MiSTer_cmd'
sleep 1

# Retrieve
scp root@192.168.50.130:/media/fat/screenshots/C64/*.png ./debug_captures/

# Claude reads the PNG with vision → decides next action
```

### Layer 2: UART Debug Stream (DO NEXT — 1-2 days)

**Add UART TX module → stream debug data → read via SSH**

- Add ~50 LUT UART TX to the design, connected to hps_io UART_TX
- Stream CPU state (addr, data, bank, SP, P, IR, flags) in ASCII hex
- AI agent reads via `ssh root@mister 'timeout 2 cat /dev/ttyS1'`
- Gives structured register-level data without needing screenshots

### Layer 3: Deep Trace Buffer (FUTURE — 2-3 days)

**Circular buffer in Block RAM for cycle-level capture**

- 4K x 64-bit M10K-based circular buffer
- Captures CPU state on every cycle (or on trigger)
- Trigger conditions: specific address, I/O write, IRQ, etc.
- Dump via UART or In-System Memory Editor
- Like a custom SignalTap purpose-built for CPU debugging

### Layer 4: Visual Regression Testing (OPTIONAL)

**HDMI capture + automated comparison**

- $10 USB HDMI dongle on dev PC
- Capture frames, compare against known-good baselines
- Detect visual artifacts, boot failures, wrong colors
- Best for catching regressions across builds

---

## Summary Table

| # | Approach | Effort | Value | HW Needed | AI-Friendly |
|---|----------|--------|-------|-----------|-------------|
| 1 | **hps_io UART debug** | Low-Med | **Very High** | None | Yes (SSH) |
| 2 | **mrext Remote API** | Low | **High** | None | Yes (HTTP) |
| 3 | **MiSTer_Batch_Control** | Very Low | **High** | None | Yes (SSH) |
| 4 | **Debug overlay + vision** | Low | **High** | None | Yes (vision) |
| 5 | HPS SPI protocol ext | Med-High | High | None | Partially |
| 6 | Screenshot_MiSTer | Low | Med-High | None | Yes (SSH) |
| 7 | HDMI capture | Low-Med | Medium | $10 dongle | Yes (vision) |
| 8 | JTAG UART | Medium | Medium | JTAG cable | Partially |
| 9 | In-System Memory Editor | Medium | Medium | JTAG cable | Partially |
| 10 | SignalTap CLI | High | Medium | None | Partially |
| 11 | Virtual JTAG | Med-High | Med-Low | JTAG cable | No |
| 12 | Embedded logic analyzer | High | Low-Med | None | No |
| 13 | Remote JTAG | High | Low | Network | No |

---

## Related Projects

- [C64AIToolChain](https://github.com/dexmac221/C64AIToolChain) — AI-driven C64 dev
  pipeline using VICE + Google Gemini. Uses vision model to analyze C64 screenshots
  and VICE's text RAM for verification. Closest existing project to our goal.
- [VibeC64](https://github.com/bbence84/VibeC64) — Another AI-powered C64 dev tool.
- [MiSTer Super Attract Mode](https://github.com/mrchrisster/MiSTer_SAM) — Automated
  core/ROM cycling. Template for automated smoke testing.
- [Minimig-AGA Hybrid](https://github.com/scrameta/Minimig-AGA_MiSTer_Hybrid) — Only
  known MiSTer project adding real HPS-FPGA AXI bridge.

---

## Key Sources

### MiSTer Control & Automation
- [mrext Remote API docs](https://github.com/wizzomafizzo/mrext/blob/main/docs/remote-api.md)
- [MiSTer_Batch_Control](https://github.com/pocomane/MiSTer_Batch_Control)
- [Screenshot_MiSTer](https://github.com/alanswx/Screenshot_MiSTer)
- [/dev/MiSTer_cmd discussion](https://github.com/MiSTer-devel/Main_MiSTer/issues/190)
- [Main_MiSTer fpga_io.cpp](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/fpga_io.cpp)

### JTAG & On-Chip Debug
- [Tom Verbeure: Intel JTAG UART](https://tomverbeure.github.io/2021/05/02/Intel-JTAG-UART.html)
- [Tom Verbeure: Intel JTAG Primitive](https://tomverbeure.github.io/2021/10/30/Intel-JTAG-Primitive.html)
- [Intel SignalTap Scripting (Quartus 22.1)](https://www.intel.com/content/www/us/en/docs/programmable/683819/22-1/scripting-support-49740.html)
- [Intel Virtual JTAG IP](https://www.intel.com/content/www/us/en/docs/programmable/683552/18-1/virtual-jtag-interface.html/)
- [quartustcl Python package](https://quartustcl.readthedocs.io/en/latest/example-memory/)
- [intel/libaji_client](https://github.com/intel/libaji_client)

### HPS-FPGA Bridge
- [DE10-Nano HPS-FPGA Bridge (CodeProject)](https://www.codeproject.com/Articles/1197698/Exploring-the-HPS-and-FPGA-onboard-the-Terasic-DE)
- [ZipCPU: SoC-FPGA Register Access](https://zipcpu.com/blog/2018/11/03/soc-fpga.html)
- [Minimig Hybrid (real bridge example)](https://github.com/scrameta/Minimig-AGA_MiSTer_Hybrid)

### Open Source Logic Analyzers
- [SUMP2/SUMP3](https://github.com/blackmesalabs/sump2)
- [LiteScope](https://github.com/enjoy-digital/litescope)
- [ZipCPU wbscope](https://github.com/ZipCPU/wbscope)

### AI + FPGA
- [C64AIToolChain](https://github.com/dexmac221/C64AIToolChain)
- [HDLdebugger (ACM TODAES)](https://dl.acm.org/doi/10.1145/3735638)
- [FVDebug (arXiv 2510.15906)](https://arxiv.org/pdf/2510.15906)
- [MiSTer UART from/to Core](https://misterfpga.org/viewtopic.php?t=2724)
- [MiSTer hps_io docs](https://mister-devel.github.io/MkDocs_MiSTer/developer/hps_io/)
- [MiSTer debugging docs](https://mister-devel.github.io/MkDocs_MiSTer/developer/debugging/)
