# sim/verilator_c64

Desktop/Verilator harness for the MiSTer C64 SuperCPU fork.

This is the first MVP implementation of `docs/verilator_desktop_harness_plan.md`.
It reuses the real `fpga64_sid_iec` core through a reduced wrapper and builds a
native host executable via:

`VHDL -> GHDL synth -> Verilog -> Verilator -> C++`

The original plan targeted `ghdl-yosys-plugin -> Yosys -> Verilog`, but the
Ubuntu-packaged plugin currently trips over this design's cache/memory
structures. The working path in this repo now uses `ghdl --synth --out=verilog`
for the RTL-to-Verilog step instead.

## Current scope

Implemented here:
- `verilator_c64_top.vhd` wrapper around the real `fpga64_sid_iec`
- host-driven C64 ROM streaming (`rom_wr/rom_addr/rom_data`)
- host-driven PRG loading via the existing reduced-harness ioctl model
- behavioral SDRAM model reuse (`sim/common/memory_models/simple_sdram_model.vhd`)
- raw video/audio export from the real core
- headless memory/screen dump in the host app
- optional SDL2 video frontend if SDL2 is available at build time

Still intentionally deferred / simplified:
- real SID audio pipeline (the current flow still uses the existing SID stub)
- real CIA/mos6526 behavior (still stubbed like Phase 4b)
- REU, cartridge, disk/tape, MiSTer `sys/` integration
- native keyboard mapping beyond placeholder host plumbing

## Why this wrapper exists

The GHDL Phase 4b harness (`sim/c64_reduced_harness/`) already proved that the
real `fpga64_sid_iec` can boot in a reduced simulation environment. This
Verilator harness keeps that same reduced environment but changes two things:

1. ROM loading is moved to the host instead of VHDL TextIO, which is friendlier
   to Yosys/ghdl-plugin translation.
2. Video/audio/debug signals are exposed directly for a desktop executable.

## Layout

```text
sim/verilator_c64/
├── Makefile
├── README.md
├── verilator_c64_top.vhd
├── flow/
│   ├── prepare_staging.sh
│   └── vhdl_to_verilog.ys
└── host/
    └── main.cpp
```

## Toolchain requirements

Recommended environment: **WSL2 / Linux**.

Required tools:
- `ghdl` (GCC backend recommended; this repo uses `GHDL_BACKEND=gcc`)
- `verilator`
- `g++` or `clang++`
- optional: `SDL2` development package for windowed video
- optional: `yosys` + `yosys-plugin-ghdl` for experimentation/debugging

## WSL-friendly install checklist

These steps assume Ubuntu under WSL2.

### 1. Base packages

```bash
sudo apt update
sudo apt install -y build-essential git python3 pkg-config libsdl2-dev verilator yosys ghdl
```

### 2. Verify the tools are actually on PATH

```bash
ghdl --version
yosys -V
verilator --version
pkg-config --modversion sdl2
```

If `pkg-config --modversion sdl2` fails, the harness still builds headless, but
SDL windowed video will not be enabled.

### 3. Make sure the GCC backend is installed/selected for GHDL

```bash
GHDL_BACKEND=gcc ghdl --dispconfig | sed -n '1,12p'
```

Expected result: library paths under `/usr/lib/ghdl/gcc/vhdl/...`.

### 4. Optional Yosys plugin check

```bash
yosys -m ghdl -p 'plugin -i ghdl'
```

This is no longer required for the main build flow, but it is useful if you
want to compare the alternate plugin-based approach.

### 5. Enter the harness directory

```bash
cd /mnt/c/LLM/C64/MiSTerSuperCPU/sim/verilator_c64
```

### 6. Optional quick preflight

```bash
bash flow/prepare_staging.sh
ls flow/build_staging/fpga64_sid_iec.vhd
```

### 7. Build

```bash
make
```

This has been validated in WSL2 Ubuntu on this machine using the GCC-backed
GHDL synthesis flow.

### 8. First headless run

```bash
make run-headless RUN_CYCLES=1000001
```

or directly:

```bash
./obj_dir/Vverilator_c64_top --headless --cycles 1000001 \
  --rom ../../C64_MiSTer/rtl/roms/std_C64.mif
```

### 9. First SDL run (WSLg / Linux desktop)

```bash
make run-sdl RUN_CYCLES=1000001
```

or directly:

```bash
./obj_dir/Vverilator_c64_top --cycles 1000001 \
  --rom ../../C64_MiSTer/rtl/roms/std_C64.mif
```

### 10. PRG injection run

```bash
make run-headless RUN_CYCLES=200000 RUN_PRG=../../tools/test_addr0801.prg
```

or directly:

```bash
./obj_dir/Vverilator_c64_top --headless --cycles 200000 \
  --rom ../../C64_MiSTer/rtl/roms/std_C64.mif \
  --prg ../../tools/test_addr0801.prg
```

### 11. Trace capture run

```bash
./obj_dir/Vverilator_c64_top --headless --cycles 1000000 \
  --rom ../../C64_MiSTer/rtl/roms/std_C64.mif \
  --trace boot.fst
```

## Expected `make` flow

From `sim/verilator_c64/`:

```bash
make
```

This performs:
1. stage-copy + patch `C64_MiSTer/rtl/fpga64_sid_iec.vhd`
2. run `ghdl --synth --out=verilog` against the reduced-wrapper source set
3. emit `flow/generated/verilator_c64_top.v`
4. run Verilator against that generated Verilog and `host/main.cpp`
5. build a Verilated executable in `obj_dir/`

Useful intermediate targets:

```bash
make stage     # only prepare the staged fpga64_sid_iec.vhd
make synth     # stop after generating flow/generated/verilator_c64_top.v
make yosys     # alias for 'make synth'
make verilate  # full native build
make clean
```

Expected artifacts after a successful build:

```text
flow/build_staging/fpga64_sid_iec.vhd
flow/generated/verilator_c64_top.v
obj_dir/Vverilator_c64_top
```

## Run

```bash
make run
```

or directly:

```bash
./obj_dir/Vverilator_c64_top --rom ../../C64_MiSTer/rtl/roms/std_C64.mif
```

Useful options:

```text
--rom <path>       ROM image (.mif or 16KB raw .bin), default std_C64.mif
--prg <path>       PRG to inject through the ioctl-style loader
--cycles <n>       Number of half-cycles to run after setup
--trace <path>     Write an FST waveform
--headless         Disable SDL even if compiled in
```

At shutdown the host now dumps a 40x25 view taken from the real bank-$00 BRAM
screen area (`$0400..$07E7`) via a dedicated BRAM probe path added to the
wrapper/core. This is a true screen-RAM view, not the earlier SDRAM-only
approximation.

## Notes / expected first blockers

Known current limitations:

1. The first desktop MVP currently uses a reduced SDRAM backing store default
   (`256 KiB`) so GHDL synthesis remains tractable. This is enough for boot and
   small PRG experiments, but not a full SuperRAM/REU-scale configuration.
2. The reduced harness still keeps the CIA and SID as VHDL stubs, which is fine
   for first boot/video work but not a full-featured desktop C64 yet.
3. The original Yosys plugin path currently fails on this design; the GHDL
   synth path is the working route.

If the SDRAM model still proves too heavy, the next step is to replace it with
an explicit Verilator/host memory backend while keeping the wrapper interface
unchanged.
