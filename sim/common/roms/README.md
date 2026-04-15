# sim/common/roms — local ROM images for the simulation harness

This directory is for ROM images consumed by the Phase 4b harness at
`sim/c64_reduced_harness/`. **Do not commit ROM binaries** — they are
copyrighted by Commodore / CMD and the `.gitignore` in this directory
excludes `*.bin`, `*.rom`, `*.raw`.

## What the harness looks for

The ROM loader in `sim/c64_reduced_harness/rom_loader_pkg.vhd` tries
these paths in order (first match wins) and falls back to an internal
"idle KERNAL stub" if none are found:

1. `sim/common/roms/kernal_basic_16k.bin`
   - 16 384 bytes (exactly 16 KB)
   - Layout: **BASIC at offset 0 (0x0000..0x1FFF)**, **KERNAL at offset
     0x2000..0x3FFF**. This matches the C64 memory map once the dprom
     is mapped to `$A000` (BASIC) and `$E000` (KERNAL).
2. `C64_MiSTer/rtl/roms/std_C64.mif` *(in-repo, parsed from Intel MIF)*
3. `C64_MiSTer/rtl/roms/dol_C64.mif` *(DolphinDOS 2.0 kernel/basic)*
4. Fallback: synthesized idle stub — BRK-at-$E000 spin loop, enough to
   keep the CPU in a known state but the BASIC boot path is absent.

## How to supply real ROMs

You need legally-owned Commodore C64 ROM dumps. The most common sources
are:

- **VICE** — `~/.vice/C64/` or `C:\ProgramData\VICE\C64\` contains
  `basic.bin` (8 KB) and `kernal.bin` (8 KB). Concatenate them:
  ```bash
  cat basic.bin kernal.bin > sim/common/roms/kernal_basic_16k.bin
  ```
  or on PowerShell:
  ```powershell
  Get-Content basic.bin, kernal.bin -AsByteStream -Raw |
    Set-Content sim/common/roms/kernal_basic_16k.bin -AsByteStream
  ```
- **Your real C64** — dump via `C64 EasyFlash` / `1541 Ultimate` to
  get stock 901226-01 BASIC + 901227-03 KERNAL.
- **Option 2 is already ready**: the in-repo `std_C64.mif` file is the
  stock C64 KERNAL+BASIC in Intel MIF format. The harness parses it
  automatically. You do NOT need to place any files here for the
  default Phase 4b run.

## What is NOT loaded

- **Chargen** (`$D000-$DFFF`). The real `fpga64_buslogic.vhd` uses a
  separate `dprom` for the character generator with no runtime write
  port, so we cannot fill it from the harness without modifying the
  RTL. The CPU reset path does not need chargen data, but any test
  that reads from `$D000-$DFFF` with CHAREN off will see 'U'.
- **SuperCPU kickstart ROM** (`scpu64.mif`). Not loaded. The Phase 4b
  bench drives `supercpu_rom='0'` so the SCPU ROM path is bypassed.

## Known limitation

The `rom_loader_pkg.load_mif_16k` parser is narrow: it accepts the
Altera MIF dialect actually used in `C64_MiSTer/rtl/roms/*.mif`
(uppercase hex, `: ;` separators, `CONTENT BEGIN / END`) and will
reject other dialects. For a custom MIF, convert to a raw `.bin` file.
