# sim/verilator_c64_vanilla

Desktop/Verilator harness for a **6510 baseline / vanilla-style** C64 run of this repo.

The build flow is automated: `make` stages and patches the required RTL, runs the
VHDL→Verilog conversion, applies the generated-Verilog fixups needed for the
T65 path via `flow/postprocess_generated_verilog.py`, and then compiles the
final Verilated executable.

This harness reuses the same reduced desktop environment as `sim/verilator_c64/`,
but drives the real `fpga64_sid_iec` with:
- `supercpu_en = '0'`
- the real `cpu_6510` + T65 path
- the same host-driven ROM/PRG loading and BRAM/SDRAM probing

## Scope

This is intended as a **comparison harness** against the SuperCPU desktop harness,
not yet a historically perfect upstream snapshot. It uses the current forked RTL
with SuperCPU disabled, so it is best thought of as a **6510 baseline build of the
current core**.

Implemented here:
- separate wrapper `verilator_c64_vanilla_top.vhd`
- separate build flow / binary
- real T65-based 6510 CPU path (staged `cpu_6510.vhd` patch for GHDL compatibility)
- real `mos6526.v` CIA RTL swapped into the generated Verilog after GHDL synth
- same host diagnostics as the SuperCPU harness
- same BRAM/SDRAM memory inspection and screen dump flow
- simulation-only power-up RAM init modes (`off`, `zero`, `vice`)

Current simplifications remain:
- SID still stubbed
- reduced SDRAM model
- no keyboard injection yet

## Build

From WSL/Linux:

```bash
cd /mnt/c/LLM/C64/MiSTerSuperCPU/sim/verilator_c64_vanilla
make
```

Notes:
- the conversion/build is fully scripted; no manual staging or post-conversion edits are required
- because the vanilla/6510 build pulls in the real T65 path, the first full build can be much slower than the SuperCPU harness
- use generous timeouts for now; once we have stable timings we can tune them back down
- the inner Verilator C++ build now runs with `make -j` for automatic parallel compile jobs

## Run

```bash
./obj_dir/Vverilator_c64_vanilla_top --headless \
  --cycles 100000 \
  --rom ../../C64_MiSTer/rtl/roms/std_C64.mif
```

With PRG injection:

```bash
./obj_dir/Vverilator_c64_vanilla_top --headless \
  --cycles 100000 \
  --prg-delay 50000 \
  --rom ../../C64_MiSTer/rtl/roms/std_C64.mif \
  --prg ../../tools/test_addr0801.prg
```

Useful options are the same as `sim/verilator_c64/`, plus:
- `--prg-delay`
- `--log-every`
- `--snapshot-every`
- `--stop-on-ready`
- `--trace`
- `--powerup-init off|zero|vice`

`--powerup-init vice` is the new default. It writes a deterministic VICE-inspired
power-up stripe pattern into bank-$00 BRAM/SDRAM before the wrapper releases the
internal reset to the core, so boot runs against non-zero RAM without changing
any synthesizable core RTL.

## Current boot-state caveat

Short runs like `100000` or `300000` cycles are **far too short** to judge cold boot.
The C64 KERNAL is still in its cold-start RAM test for those runs; the host status log
shows this via zero-page `$C2`, which acts as the RAM-test page counter. Any transient
changes in screen RAM during that phase are usually just the RAM test touching page `$04`.

Also note that in the vanilla harness the exported `dbg_cpu_addr` is a CPU **bus address**,
not a true architectural 6510 PC. The host log labels it as `cpu_addr` accordingly.

## Notes

The purpose of this harness is to let us answer questions like:
- does a PRG survive and run in the 6510 baseline harness?
- does the same PRG fail only in the SuperCPU harness?
- are boot/screen/BASIC pointer behaviors materially different between the two?

That gives a much tighter A/B platform for desktop debugging before going back to FPGA hardware.
