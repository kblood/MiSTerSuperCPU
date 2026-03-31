# MiSTer C64 Debug Agent Reference

## Purpose
Provides instructions for debugging the MiSTer C64 SuperCPU core on live hardware.
Use this context when launching an Agent to diagnose hardware issues.

## Connection Details
- MiSTer IP: 192.168.50.130
- SSH: `ssh root@192.168.50.130` (password: 1)
- Core location: `/media/fat/_Test/C64.rbf`
- WSL SSH is broken to MiSTer — use Windows native ssh/scp
- **SSH auth**: mister_debug.py uses paramiko with password auth (key-based auth
  may break after MiSTer updates). Requires `pip install paramiko`.

## Deploy

### Core (RBF)
```bash
scp C:/LLM/C64/MiSTerSuperCPU/C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf
```
Reload remotely (no OSD needed):
```bash
ssh root@192.168.50.130 "echo 'load_core /media/fat/_Test/C64.rbf' > /dev/MiSTer_cmd"
```

### Test CRTs and PRGs
Games/programs folder (usb0 is the primary storage):
```
/media/usb0/games/C64/
```
Deploy a CRT:
```bash
scp C:/LLM/C64/MiSTerSuperCPU/tools/test_cart/out/scpu_speedtest.crt root@192.168.50.130:/media/usb0/games/C64/scpu_speedtest.crt
```
User loads CRT from MiSTer OSD file browser (F12 → Load *.crt).

### Available Test CRTs
All generated from Python scripts in `tools/test_cart/`:

| CRT | Generator | Purpose |
|-----|-----------|---------|
| scpu_speedtest.crt | gen_scpu_speedtest.py | CIA Timer A MHz measurement (SLOW vs FAST mode) |
| turbo_test.crt | gen_turbo_test.py | Raster-line based cache/turbo speed measurement |
| scpu_diag_counters.crt | gen_scpu_diag_counters.py | SDRAM data corruption diagnostic counters |
| scpu_vic_test.crt | gen_scpu_test.py | VIC-II read-side corruption test |
| scpu_kernal_mimic_m0-m12.crt | gen_scpu_kernal_mimic.py | Progressive '@' artifact isolation |
| scpu_dead_test.crt | gen_dead_test.py | Dead test wrapper for 65C816 |

Rebuild all CRTs:
```powershell
.\tools\test_cart\build_and_deploy_carts.ps1
```

## UART Debug (115200 8N1 on /dev/ttyS1)
```bash
ssh root@192.168.50.130 "cat /dev/ttyS1" 2>&1 | head -10
```

### UART Line Format
```
A:xxxx D:xx B:xx R:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx
```

| Field | Description |
|-------|-------------|
| A     | CPU address (16-bit) |
| D     | CPU data bus (8-bit) |
| B     | Bank byte (A23-A16) |
| R     | Raw cpu_cyc count per frame |
| P     | Processor status (8-bit) |
| I     | Instruction register / opcode |
| E     | Emulation mode (1=emu, 0=native) |
| F     | Frame counter (16-bit) |
| T     | Diagnostic byte (see below) |
| C     | Cache hit count per frame (16-bit) |
| N     | T65 enableCpu count per frame (always 0 in SCPU mode) |

### T: Diagnostic Byte Bits
| Bit | Value | Signal | Meaning when set |
|-----|-------|--------|------------------|
| 0   | 0x01  | turbo_en | Turbo enabled |
| 1   | 0x02  | scpu_rom_vis | SCPU ROM visible (should be 0 after kickstart) |
| 2   | 0x04  | scpu_speed_1mhz | Software forced 1MHz ($D07A) |
| 3   | 0x08  | iec_slow_mode | IEC serial bus slowdown active |
| 4   | 0x10  | scpu_rom_overlay | ROM overlay blocking cache |
| 5   | 0x20  | cache_hit | Instantaneous cache hit signal |
| 6   | 0x40  | enableCpu | Instantaneous SDRAM enable |

### Healthy State Examples
- `T:21 C:0B59` — turbo ON, cache hitting (~2905/frame), cache_hit instantaneous = good
- `T:01 C:0000` — turbo ON, no cache hits = cache suppressed or empty
- `T:13 C:0000` — turbo + rom_vis + overlay = ROM blocking cache (bad after boot)

## Debug Overlay (on-screen)
Row 1: `A:xxxx B:xx K:xx R:xx` (K=sticky max bank, R=addr at max bank entry)
Row 2: `S:xxxx P:xx I:xx E:x`
Row 3: `C:xxxx M:x D:xx P:xxxx` (screen write capture)
Row 4: `T:x C:xxxx E:xxxx N:xx` (turbo/cache/enable/frame — overlay still 1-digit T)

## OSD Configuration
Config file: `/media/fat/config/C64.cfg` (16 bytes)
- byte 5 bits 7:6 = turbo_mode
- byte 6 bits 1:0 = turbo_speed
- byte 10: bit2=SuperCPU, bit3=overlay, bit6=SCPU ROM

## Remote OSD Control & Screenshots

### Opening/Closing OSD Remotely
There is NO `/dev/MiSTer_cmd` command for OSD. Use F12 keypress via `mtype.py`:
```bash
# Via mtype.py (ONLY working method — mbc raw_seq does NOT work)
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"
# Upload mtype.py first: scp tools/mtype.py root@192.168.50.130:/tmp/mtype.py

# Via mister_debug.py:
python tools/mister_debug.py keys "M"

# Via mrext API (if installed)
curl -X POST http://192.168.50.130:8182/api/controls/keyboard/f12
```

**Why not mbc?** `mbc raw_seq "M"` creates a virtual input device that MiSTer's
main binary **filters out**. `mtype.py` works because it spoofs USB identifiers
(`Phys=usb-ffb40000.usb-1.9/input0`, vendor=0x04d9). Each call takes ~7s.

### Screenshot with OSD Visible
MiSTer's built-in `screenshot` and `screenshot scaled` commands capture the FPGA
video output **before** the OSD overlay is composited in hardware. They will
**never** include the OSD. To capture the OSD, use an HDMI capture device:

```bash
# Best method: OBS + HDMI capture (e.g., Genki Shadowcast)
# 1. Open OSD
python tools/mister_debug.py keys "M"
# 2. Capture OBS preview window (Python on local Windows machine)
python -c "from PIL import ImageGrab; ImageGrab.grab(all_screens=True).save('osd.png')"
# 3. Close OSD
python tools/mister_debug.py keys "M"

# All-in-one tool command:
python tools/mister_debug.py osd_screen captures/osd.png
```

### Screenshot Methods Compared
| Method | Captures OSD? | What it captures |
|--------|--------------|------------------|
| `echo "screenshot" > /dev/MiSTer_cmd` | **No** | Core video, native resolution |
| `echo "screenshot scaled" > /dev/MiSTer_cmd` | **No** | Core video, ASCAL-scaled |
| `fbgrab /tmp/fb.png` | **No** | Linux framebuffer (console) |
| OBS + HDMI capture device | **Yes** | Full HDMI output with OSD |

### Navigating OSD Remotely
Use `mtype.py` key names or mbc-style shorthand via mister_debug.py:
```bash
# Open OSD, go down 4 items, press Enter
python tools/mister_debug.py keys "MDDDDDO"

# Or with mtype.py native names:
python tools/mister_debug.py keys f12 down down down down enter

# Direct SSH:
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12 down down down down enter"
```

### Key Shorthand Codes (mister_debug.py keys command)
| Code | Key | mtype.py equivalent |
|------|-----|---------------------|
| M | F12 | `f12` |
| U | Up | `up` |
| D | Down | `down` |
| L | Left | `left` |
| R | Right | `right` |
| O | Enter | `enter` |
| E | Escape | `esc` |
| H | Home | `home` |
| F | End | `end` |

Note: `mbc raw_seq` shorthand (a-z, 0-9, :XX hex, !s wait) is only available
as a fallback. The primary method is `mtype.py` which accepts Linux key names
(f1-f12, up, down, left, right, enter, esc, space, tab, etc.).

## Key Diagnostic Patterns

### Brown Screen (VIC shows garbage)
- CPU running correctly (A:E5CF = KERNAL idle loop)
- BRAM has stale data — VIC reads wrong values from Port B
- Check: are writes going through SDRAM (enableCpu) or lost via cache_hit_d1?
- cache_hit_d1 must be gated by `not cpuWe_pre` to prevent lost writes

### No Cache Hits (C:0000)
- Check T diagnostic byte for blocking signals
- scpu_rom_overlay (bit 4): ROM visibility not cleared by kickstart
- scpu_speed_1mhz (bit 2): software forced 1MHz
- iec_slow_mode (bit 3): CIA2 write triggered slowdown

### No Turbo (T bit 0 = 0)
- Check iec_slow_mode, scpu_speed_1mhz, dma_req
- turbo_en set at EXT1/EXT5 cycles in fpga64_sid_iec.vhd

## Build Commands
```powershell
.\build_c64.ps1                # Full synthesis
.\build_c64.ps1 -SyntaxOnly   # Quick syntax check
.\build_c64.ps1 -Clean         # Clean build
```
Build in Windows: `powershell.exe -File C:/LLM/C64/MiSTerSuperCPU/build_c64.ps1`

## Deploy + Test Workflow
```bash
# 1. Build core
powershell.exe -File C:/LLM/C64/MiSTerSuperCPU/build_c64.ps1

# 2. Deploy RBF
scp C:/LLM/C64/MiSTerSuperCPU/C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf

# 3. Reload core remotely
ssh root@192.168.50.130 "echo 'load_core /media/fat/_Test/C64.rbf' > /dev/MiSTer_cmd"

# 4. Wait for boot (~8 seconds)
sleep 8

# 5. Read UART diagnostics
ssh root@192.168.50.130 "cat /dev/ttyS1" 2>&1 | head -10
```
