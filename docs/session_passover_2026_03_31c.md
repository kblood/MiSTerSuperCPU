# Session Passover — 2026-03-31c

## What Was Accomplished This Session

Researched, implemented, and documented **remote OSD control and screenshot capture** for MiSTer,
then used it to successfully mount **doom.reu** into the SuperCPU core via remote automation.

### Key Commits

- `6ee40c3` — Fix remote OSD: use mtype.py (not mbc), OBS PrintWindow for screenshots
- `0b7bcd6` — Document REU file browser path config and doom.reu OSD mount procedure

---

## Current State

- **Core on MiSTer:** `/media/fat/_Test/C64.rbf` — our SuperCPU build (4,100,908 bytes)
- **doom.reu:** Loaded into SuperRAM ✅ (16MB file, loading confirmed via OBS screenshot)
- **doom.reu locations:**
  - `/media/usb0/C64/doom.reu` ← default OSD browser dir, use this
  - `/media/usb0/games/C64/scpu/doom/doom.reu` ← original with loader.prg and readme
- **C64.f2 config:** `/media/fat/config/C64.f2` set to `../usb0/games/C64/scpu/doom/doom.reu`
  (takes effect on next core reload; current session uses copied file in `/media/usb0/C64/`)

---

## Remote OSD Control — Definitive Summary

### How to Open OSD

```bash
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"
# Password: 1
```

`mtype.py` is the **only working** remote keyboard method. It creates a uinput device
impersonating a real USB keyboard (vendor=0x04d9, product=0x0006, `UI_SET_PHYS` set to
`usb-ffb40000.usb-1.9/input0`). Each SSH call takes ~7 seconds (6s device settle + keypress).

**mbc raw_seq does NOT work** — MiSTer's main binary filters mbc's virtual input device.

`mtype.py` is at `tools/mtype.py` locally. Upload to MiSTer if missing:
```bash
scp tools/mtype.py root@192.168.50.130:/tmp/mtype.py
```

### How to Screenshot the OSD

MiSTer's built-in `screenshot` command captures the FPGA output **before** OSD is composited —
it will never show the OSD. The only working method is **OBS via Win32 PrintWindow API**:

```python
# In Python on the Windows host:
import sys; sys.path.insert(0, 'tools')
import mister_debug
mister_debug._capture_obs_window('output.png')
```

Or use the integrated command:
```bash
python tools/mister_debug.py osd_screen output.png
```

**Requires:** OBS running with HDMI capture source showing MiSTer output. OBS process
name is `obs64`. The `_capture_obs_window()` function uses `PrintWindow` with
`PW_RENDERFULLCONTENT=2`, which captures the window even when behind other windows.

### OSD Navigation Tips

- **Keep each mtype.py call minimal** — sending too many keypresses at once causes OSD
  state transitions mid-burst; remaining keypresses leak to C64 BASIC interpreter.
- Always capture a screenshot after each navigation step to verify state before continuing.
- mtype.py supports: `f12`, `up`, `down`, `left`, `right`, `enter`, `space`, letter keys, etc.

---

## doom.reu Mount Procedure (Remote)

```bash
# 1. Open OSD
ssh root@192.168.50.130 "python3 /tmp/mtype.py f12"

# 2. Navigate to "Load REU *.REU" (4 downs from top of menu, then Enter)
#    Menu order from top: Mount#8, Mount#9, Mount Write Protected, Load*.PRG, Load REU *.REU
ssh root@192.168.50.130 "python3 /tmp/mtype.py down down down down enter"

# 3. File browser opens at /media/usb0/C64/ showing doom.reu and test*.reu files
#    doom.reu is above test* (alphabetically). Cursor starts on test* so press Up then Enter.
ssh root@192.168.50.130 "python3 /tmp/mtype.py up enter"

# 4. Loading bar appears. Wait ~5-8 seconds for 16MB to transfer.
# 5. Done — doom.reu is in SuperRAM at SDRAM bank offset 0x1000000
```

---

## OSD Menu Item Layout (SuperCPU Core)

From top of main menu:
1. Mount #8
2. Mount #9
3. Mount Write Protected: Off
4. Load *.PRG,CRT,REU,TAP  (F1 slot)
5. **Load REU *.REU**  (F2 slot — opens to /media/usb0/C64/)
6. Audio & Video →
7. Hardware →
8. Drives →
9. Swap Joysticks
10. Turbo mode
11. Turbo speed
12. SuperCPU (65C816): On

---

## File Browser Config Files

The MiSTer C64 core stores the last-used path for each file slot in
`/media/fat/config/C64.f{n}` (64-byte fixed record, null-padded, path
relative to `/media/fat/` with `../` prefix).

| Slot | Config File | OSD Menu Item |
|------|-------------|---------------|
| F1 | `C64.f5` | Load *.PRG,CRT,REU,TAP |
| F2 | `C64.f2` | Load REU *.REU |
| F8 | `C64.f8` | Mount #8 |
| F9 | `C64.f9` | Mount #9 |

To pre-seed the browser to a directory, write a 64-byte record (takes effect on core reload):
```python
# On MiSTer via SSH
path = '../usb0/games/C64/scpu/doom/doom.reu'
data = path.encode('ascii') + b'\x00' * (64 - len(path))
open('/media/fat/config/C64.f2', 'wb').write(data)
```

---

## MiSTer Connection Details

- IP: `192.168.50.130`
- SSH: `root` / `1`
- Core: `/media/fat/_Test/C64.rbf`
- UART: `/dev/ttyS1` at 115200 baud
- Keyboard tool: `/tmp/mtype.py` (must be uploaded each reboot)

---

## Known Issues / Gotchas

1. **mtype.py becomes unreliable after MGL core reloads** — MGL causes the core to
   reload which can confuse MiSTer's input device enumeration. If F12 stops working
   after an MGL load, try physical keyboard or re-upload mtype.py.

2. **OSD leaks keypresses to BASIC** — if too many keys are sent in one mtype.py call
   and the OSD closes mid-burst, remaining keys go to C64. Solution: send fewer keys
   per call and check state via screenshot.

3. **File browser caches directory** — changing C64.f2 only affects the next core load.
   For immediate access, copy files into whatever directory the browser is showing.

4. **Don't `find` on /media/usb0** — it's a 4TB drive, find will run forever.

---

## Next Steps

With doom.reu now loaded into SuperRAM, the next step is to actually run the Doom
loader and verify it works:

1. Load `loader.prg` from `/media/usb0/games/C64/scpu/doom/loader.prg`
   (or use the copy on disk image)
2. The loader should use REU DMA to copy game data from SuperRAM into the 65C816
   address space and launch Doom
3. Verify Doom runs — if it hangs/crashes, use debug UART + overlay to diagnose

Longer-term SuperCPU work:
- Speed switching ($D07A/$D07B registers for 1MHz/20MHz)
- Full SuperCPU compatibility testing with real software
- Lorenz CPU test suite pass for both 6510 and 65C816 modes
