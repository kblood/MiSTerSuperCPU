# MiSTer FPGA Core Debugging Guide

## Overview

This document covers all available debugging methods for MiSTer FPGA cores,
specifically in the context of the C64 SuperCPU project. Methods are ordered
from simplest/quickest to most powerful/complex.

---

## 1. LED Probes (Immediate, No Build Cost)

The DE10-Nano has 8 LEDs plus the MiSTer framework exposes `LED_USER`,
`LED_POWER`, and `LED_DISK` signals.

### How It Works

In `c64.sv`, override the LED assignment to probe a signal:

```systemverilog
// Normal: assign LED_USER = |drive_led | ioctl_download | ...;
// Debug:  assign LED_USER = supercpu_emul;  // lit = emulation mode
```

### Useful Probes

| Signal | What It Tells You |
|--------|-------------------|
| `supercpu_emul` | 65C816 is in 6502 emulation mode (should be lit on boot) |
| `enableCpu_816` | 65C816 is receiving clock enable pulses (should blink/glow) |
| `cpuWe_816` | 65C816 is writing to the bus |
| `supercpu_enable` | OSD toggle state |

### Pros/Cons
- **Pro:** Zero FPGA resource cost, 1-line code change
- **Con:** Only 1 bit of information per LED

---

## 2. OSD Info Notifications

The MiSTer framework provides an 8-bit `info_req`/`info` mechanism in
`hps_io.sv` (lines 119-120) that displays a brief notification on the OSD.

### How It Works

```systemverilog
// In c64.sv, connect to hps_io:
.info_req(info_req),
.info(info),

// Pulse info_req to display 8-bit value:
reg info_req;
reg [7:0] info;
always @(posedge clk_sys) begin
    info_req <= some_trigger;
    info <= debug_byte;
end
```

### Pros/Cons
- **Pro:** Visible on-screen without external hardware
- **Con:** Only 8 bits per notification, low update rate

---

## 3. UART Debug Output

The MiSTer framework wires a full UART path from the FPGA to the HPS Linux
side via the Cyclone V hard UART peripheral.

### Framework Wiring

In `sys_top.v` (lines 548-559):
```verilog
cyclonev_hps_interface_peripheral_uart uart (
    .rxd(uart_txd),  // FPGA TX -> HPS RX
    .txd(uart_rxd),  // HPS TX -> FPGA RX
    ...
);
```

In `c64.sv` (lines 165-170, 1625-1660), the UART is currently used for
C64 user port RS-232 emulation (controlled by `status[43]`). When RS-232
mode is disabled, the UART lines are idle and available for debug use.

### Implementation Approach

1. Add a simple UART TX module (~50 lines VHDL/Verilog)
2. Connect to `UART_TXD` when `status[43]=0`
3. Output fixed-format packets: `addr(2B) + data(1B) + flags(1B)`
4. Use triggered logging (e.g., only on writes to VIC-II range $D000-$D3FF)

### Accessing UART on MiSTer

```bash
# SSH into MiSTer, then:
cat /dev/ttyS1                    # raw output
screen /dev/ttyS1 115200          # interactive terminal
stty -F /dev/ttyS1 115200 raw     # configure baud rate
```

### Bandwidth Limitations

| Baud Rate | Bytes/sec | Notes |
|-----------|-----------|-------|
| 9600 | ~960 | Default C64 CONF_STR setting, too slow for tracing |
| 115200 | ~11,520 | Usable for triggered/filtered logging |
| 921600 | ~92,160 | May work depending on HPS UART config |

Change baud rate in CONF_STR: `"C64;UART115200;"` (line 208 of c64.sv).

### Pros/Cons
- **Pro:** Rich data, persistent logging, no external hardware
- **Con:** Bandwidth-limited, must multiplex with RS-232 feature

---

## 4. On-Screen Hex Debug Overlay

Render CPU state as hex digits directly onto the video output, overlaid on
the VIC-II picture in the border area.

### How It Works

1. Create a `debug_overlay` module that takes CPU signals and raster position
2. Use a small character ROM (0-9, A-F) for hex digit rendering
3. Overlay during VBlank or in the border area (outside C64's 320x200 active area)
4. MUX the overlay pixels with VIC-II RGB output in `c64.sv`

### Available Raster Position Signals

The VIC-II already exposes debug outputs (`video_vicII_656x.vhd` lines 70-74):
```vhdl
debugX  : out unsigned(9 downto 0);  -- raster X position
debugY  : out unsigned(8 downto 0);  -- raster Y position
```

These are connected in `fpga64_sid_iec.vhd` but currently unused for display.

### Suggested Display Layout

```
+------------------------------------------+
| ADDR:C000 DO:4C WE:0 EM:1 CYC:CPU3      |  <- top border
|                                          |
|          Normal C64 display              |
|                                          |
| BANK:00 IO:37 BA:1 EN:1                 |  <- bottom border
+------------------------------------------+
```

### Resource Cost
- ~200-400 ALMs for character ROM + mux logic
- ~1 M9K block for the 4x6 or 8x8 font bitmap
- Negligible impact on timing

### Pros/Cons
- **Pro:** Real-time visibility, shows bus activity alongside artifacts
- **Pro:** No external hardware needed
- **Con:** ~1-2 hours to implement, small resource cost

---

## 5. Freeze-and-Examine via OSD

Add an OSD option to halt the CPU and display its internal state.

### How It Works

1. Add a status bit (e.g., `status[83]`) for "Freeze CPU"
2. When asserted, hold `enableCpu = '0'` to stop CPU execution
3. Latch last CPU address, data, opcode, and flags
4. Display latched values through the OSD info mechanism or overlay

### Existing Infrastructure

The C64 core already has a `pause` mechanism in `fpga64_sid_iec.vhd`:
```vhdl
pause     : in std_logic := '0';
pause_out : out std_logic;
```

The `video_freezer.sv` module freezes video sync when the OSD is open
(`status[42]`). This could be extended to also capture CPU state.

### Pros/Cons
- **Pro:** Allows examining exact CPU state at a point in time
- **Con:** Limited display bandwidth through OSD, stops execution

---

## 6. HPS Register Read-Back via EXT_BUS

The MiSTer framework provides a 36-bit bidirectional `EXT_BUS` for custom
HPS-to-FPGA communication (`hps_io.sv` lines 168-173).

### How It Works

```systemverilog
// When EXT_BUS[32] is asserted, EXT_BUS[15:0] overrides io_dout
assign HPS_BUS[15:0] = EXT_BUS[32] ? EXT_BUS[15:0] : ... ;
```

1. Create a debug register file in the FPGA that latches CPU state
2. Respond to HPS read requests via EXT_BUS
3. On the Linux side, read registers via `devmem` or a custom script

### Linux-Side Access

```bash
# Read FPGA registers via memory-mapped I/O
devmem 0xFF200000 32    # read from lightweight HPS-to-FPGA bridge
```

### Pros/Cons
- **Pro:** Rich data, scriptable from Linux
- **Con:** Undocumented protocol, requires matching Linux-side code

---

## 7. SignalTap II Logic Analyzer (Most Powerful)

Intel's built-in logic analyzer captures any internal FPGA signal at full
clock speed with configurable triggers.

### Prerequisites

- **USB Blaster II** cable (or clone, ~$15-30)
- Connect to DE10-Nano's USB Blaster port (next to HDMI)
- Quartus Prime with SignalTap II (included in Lite Edition)

### Setup

1. In Quartus: File > New > SignalTap II Logic Analyzer File (`.stp`)
2. Set capture clock: `clk_sys` (32 MHz)
3. Add signals via Node Finder (use post-fit netlist filter)
4. Set trigger conditions
5. Recompile (adds ~2-5 min to build time)
6. Tools > SignalTap II Logic Analyzer > capture and analyze

### Suggested Signal Set for CPU Debug

```
Clock:   emu|fpga64|clk32
Signals: emu|fpga64|sysCycle[4:0]
         emu|fpga64|cpuAddr_pre[15:0]
         emu|fpga64|cpuDo_pre[7:0]
         emu|fpga64|cpuWe_pre
         emu|fpga64|enableCpu
         emu|fpga64|enableCpu_816
         emu|fpga64|enableCpu_6510
         emu|fpga64|supercpu_en
         emu|fpga64|cpuHasBus
         emu|fpga64|aec
         emu|fpga64|baLoc
Trigger: supercpu_en = '1' AND enableCpu_816 = '1'
Depth:   4096 samples (uses ~4 M9K blocks)
```

### JTAG Direct Upload

For faster iteration, upload `.sof` files directly via JTAG instead of
creating `.rbf` files and copying to SD card:

```
quartus_pgm -m jtag -o "p;output_files/C64.sof"
```

This is volatile (lost on power cycle) but much faster for development.

### Resource Cost

| Sample Depth | M9K Blocks | Notes |
|-------------|------------|-------|
| 1024 | ~2 | Minimal, short captures |
| 4096 | ~4 | Good for most debugging |
| 16384 | ~16 | Detailed long captures |
| 65536 | ~64 | May strain resource budget |

Current C64 core uses 391/553 RAM blocks (71%). A 4096-depth SignalTap
with 50 signals would use ~8 additional blocks — well within budget.

### Enabling MISTER_DEBUG_NOHDMI

For resource-constrained debug builds, define `MISTER_DEBUG_NOHDMI` in the
QSF to disable the HDMI scaler, freeing substantial ALM and RAM resources:

```tcl
set_global_assignment -name VERILOG_MACRO "MISTER_DEBUG_NOHDMI=1"
```

### Pros/Cons
- **Pro:** Most powerful — full visibility into any signal at full speed
- **Pro:** Configurable triggers, waveform viewer
- **Con:** Requires USB Blaster hardware
- **Con:** Each signal set change requires recompilation
- **Con:** Can affect timing/routing (observer effect)

---

## 8. GHDL / ModelSim Simulation

RTL simulation allows verification without hardware.

### GHDL (Free, Open Source)

```bash
# Analyze all VHDL files
ghdl -a --std=08 rtl/t65/*.vhd rtl/65C816/*.vhd rtl/cpu_65c816.vhd

# Elaborate top entity
ghdl -e --std=08 cpu_65c816

# Run with VCD waveform output
ghdl -r cpu_65c816 --vcd=cpu_debug.vcd --stop-time=100us
```

### ModelSim-Intel (Free with Quartus)

```tcl
# In ModelSim:
vlib work
vcom rtl/65C816/P65816_pkg.vhd
vcom rtl/65C816/P65C816.vhd
vcom rtl/cpu_65c816.vhd
vsim cpu_65c816
add wave *
run 100us
```

### Pros/Cons
- **Pro:** Full visibility, repeatable, no hardware needed
- **Con:** Very slow for full-system simulation
- **Con:** Requires testbench with ROM/RAM models and stimulus

---

## 9. Existing Debug Signals in the C64 Core

### T65 CPU Debug Record

The T65 core exposes a full debug record (`T65_Pack.vhd` lines 143-150):
```vhdl
type T_t65_dbg is record
    I : std_logic_vector(7 downto 0);  -- current instruction opcode
    A : std_logic_vector(7 downto 0);  -- accumulator
    X : std_logic_vector(7 downto 0);  -- X register
    Y : std_logic_vector(7 downto 0);  -- Y register
    S : std_logic_vector(7 downto 0);  -- stack pointer
    P : std_logic_vector(7 downto 0);  -- processor flags
end record;
```

Connected in `T65.vhd` (lines 267-273) but **not wired through**
`cpu_6510.vhd` to the system level. Could be exposed for comparison testing.

### P65C816 Internal Debug Signals

In `P65C816.vhd` (lines 69-76):
```vhdl
signal DBG_BRK_ADDR : std_logic_vector(23 downto 0);
signal DBG_NEXT_PC  : std_logic_vector(15 downto 0);
signal DBG_CTRL     : std_logic_vector(7 downto 0);
```

These are internal-only signals. To use them, either:
- Add output ports to P65C816.vhd (simple, ~5 lines)
- Access via SignalTap (no code changes needed)

### VIC-II Raster Debug

In `video_vicII_656x.vhd` (lines 70-74):
```vhdl
debugX : out unsigned(9 downto 0);  -- current raster X
debugY : out unsigned(8 downto 0);  -- current raster Y
```

Already connected in `fpga64_sid_iec.vhd`, available for overlay rendering.

---

## 10. Save State Support

### Framework Support

MiSTer supports save states via DDR3 memory with 4 slots. Declared in
CONF_STR: `"SS{base_addr}:{size};"`. The framework handles slot management,
disk persistence, and UI.

### C64 Core Status

The C64 core has **no save state support**. Implementing it requires:

1. Enumerating ALL stateful elements (CPU regs, VIC-II state, CIA timers,
   SID state, all RAM contents, bus arbitration state machine, PLA state)
2. Adding serialization/deserialization logic for each
3. Implementing the pause-serialize-resume protocol
4. Testing that restored state is cycle-accurate

This is a **major undertaking** (estimated weeks of work) and is not
practical as a debugging tool. However, it would be a valuable feature
for the finished SuperCPU core.

---

## Recommended Debug Strategy for SuperCPU

### Phase 1: Quick Validation (LED probes)
Add LED probes to confirm basic 65C816 operation:
- Is it getting clock enables?
- Is it in emulation mode?
- Is it producing writes?

### Phase 2: Visual Debug (On-screen overlay)
Build a hex overlay showing CPU address/data/flags in the border area.
This directly correlates bus activity with visible screen artifacts.

### Phase 3: Deep Analysis (SignalTap or simulation)
If the overlay doesn't reveal the issue, use SignalTap to capture exact
cycle-by-cycle bus timing, or build a simulation testbench for the
cpu_65c816 wrapper.
