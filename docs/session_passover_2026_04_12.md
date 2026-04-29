# Session Passover 2026-04-12: REU Register Fix + File Loading Investigation

## Headline

**Fixed REU register mapping** — command register is at $DF01 (not $DF00). REU DMA confirmed working on both stock and SuperCPU cores via ML test program. **File loading via MiSTer_cmd/mbc does NOT transfer data** — doom.reu data never reaches SDRAM.

## 1. REU Register Map — FIXED

The MiSTer C64 REU implementation (reu.v) has the command register at **$DF01**, not $DF00:
- $DF00 (57088) = Status register (**READ ONLY** — writes ignored, no case in write block)
- $DF01 (57089) = Command register (write triggers DMA)
- $DF02-$DF08 = C64 addr, REU addr, length (shifted by 1 from many tutorials)
- $DF09 (57097) = Interrupt mask (on stock core; diagnostic override on SuperCPU core)
- $DF0A (57098) = Address control

For immediate DMA: bit 7 (execute) AND bit 4 must be set → **$90 = STASH, $91 = FETCH**.
$80/$81 require $FF00 write trigger (deferred mode).

All previous REU tests in earlier sessions were writing to the wrong register ($DF00 instead of $DF01), which is why they appeared to fail.

Full reference: `docs/reu_register_map.md`

## 2. ML REU Test Program — reu_test_c64.prg

Built a proper machine language REU test at $C000 that:
1. STASH/FETCH roundtrip with ABCD pattern → **WORKS** (status $50, data 41 42 43 44)
2. FETCH from REU bank $20 (doom.reu code area) → status $50 but **all zeros**
3. FETCH from REU bank $80 (SCPU marker) → status $50 but **all zeros**

This proves:
- REU DMA is fully functional on both cores
- doom.reu data was never loaded into SDRAM by any of our file loading methods

## 3. File Loading — ALL Methods Fail

Tested on BOTH stock and SuperCPU cores:

| Method | Result |
|--------|--------|
| `echo load_core foo.mgl > /dev/MiSTer_cmd` | Core loads, **file data NOT transferred** |
| `mbc load_rom C64 /path/doom.reu` | Core reboots, **file data NOT transferred** |
| `mbc load_rom C64.REU /path/doom.reu` | Core reboots, **file data NOT transferred** |
| OSD F12 → Load REU (attempted) | Couldn't complete navigation reliably |

### Diagnostics (SuperCPU core only):
- **ioctl_index = 8** (expected 2 for F2 REU slot) — wrong index!
- **ioctl byte count (CNT) = 0** — zero bytes received for REU
- **SDRAM write count (WRC) = 65535** — from other ioctl activity, not REU
- **REU readback byte = $EE** — sentinel value from reset, confirming no data written

### Root cause hypothesis:
`load_core` via MiSTer_cmd pipe loads the RBF but does NOT process `<file>` tags in MGL files. The file transfer ioctl mechanism only works when launched from MiSTer's menu system (file browser / MGL browser). There is no command-line equivalent.

## 4. MiSTer Filesystem Layout

- `/media/fat/` = SD card (`/dev/mmcblk0p1` exfat)
- `/media/usb0/` = USB drive (`/dev/sda1` exfat)
- Both have doom.reu with identical md5: `b5b3f7f7988b754017f4dcdc9418b21d`
- MGL `path="games/C64/doom.reu"` resolves to SD card, not USB
- doom.reu first 2MB is all zeros; code starts at offset $200000 (bank $20)

## 5. BASIC 80-char Line Limit

C64 BASIC truncates input lines at ~80 characters. POKE sequences longer than 80 chars get silently truncated. This caused intermittent test failures when chaining many POKEs on one line. Always split POKEs across multiple `\r`-separated lines, each under 80 chars.

## 6. reu_load.py — Started, Not Finished

Started writing `tools/reu_load.py` to bypass MGL by directly using the HPS-to-FPGA bridge via `/dev/mem` and the FIO SPI protocol. Not yet functional — needs the correct SPI bit-banging implementation based on MiSTer Main's fpga_io.cpp.

## Files Created/Modified

- `docs/reu_register_map.md` — NEW: Complete REU register reference
- `docs/session_passover_2026_04_12.md` — this file
- `tools/reu_load.py` — NEW: Direct HPS REU loader (incomplete)
- `/tmp/reu_test.s` → `reu_test_c64.prg` — ML REU test program (built, tested)

## Next Steps

### Priority 1: Get doom.reu data into SDRAM
Options:
1. **Complete reu_load.py** — direct HPS bridge file transfer via `/dev/mem`
2. **Fix MiSTer_cmd MGL processing** — investigate why `<file>` tags aren't processed
3. **Ask user** how they normally load REU files (their workflow may differ from MiSTer_cmd)
4. **OSD automation** — improve mtype.py key sequences for reliable OSD navigation

### Priority 2: Fix ioctl_index mismatch on SuperCPU core
Our core receives ioctl_index=8 instead of 2 for F2 REU. This needs investigation:
- Check how hps_io computes ioctl_index from CONF_STR entry positions
- May need to update `load_reu` to also check for index 8

### Priority 3: Debug K:F8 crash (from session 2026-04-11d)
Once doom.reu loads successfully, continue debugging the crash during K:2D game init.
