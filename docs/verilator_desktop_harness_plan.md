# Verilator Desktop Harness Plan

Status: PLAN — not yet implemented.
Goal: Run the MiSTer C64 SuperCPU core on the developer PC as a
near-real-time software emulator, compiled from the real RTL via a
Yosys + GHDL-plugin toolchain that translates VHDL → Yosys IR →
Verilog → Verilator → C++ → native binary. Target: 30–60% real-time
on a modern laptop, i.e. a playable C64 running the real FPGA core
with SDL video + keyboard + audio.

## Why this would be valuable

The three GHDL benches we already have (`sim/p65c816_tb/`,
`sim/prg_loader_tb/`, `sim/c64_reduced_harness/`) run logical
simulation at ~0.1–1% of real-time. That is fine for targeted
unit-level scoreboards (PRG loader, REP/XCE semantics, 1-instruction
CPU behavior) but too slow for scenarios that need tens of millions
of clock cycles to reproduce — e.g. a game that crashes 30 seconds
after boot, BASIC auto-RUN interactions, REU DMA streams, keyboard
timing races.

A Verilator-compiled version of the same RTL runs thousands of times
faster. It gives us:

- **Playable desktop C64 running our fork** — watch a game actually
  run on the PC, keyboard input via SDL, video out via SDL, audio
  out via PortAudio/SDL audio
- **Logically identical to the FPGA build** — same `fpga64_sid_iec.vhd`,
  same CPU, same cache, same REU
- **Much longer reproducer windows** — instead of 20-second sim runs,
  we can run for minutes of simulated C64 time and still finish in
  wallclock seconds
- **Differential testing** — run vanilla MiSTer vs. our SuperCPU fork
  side-by-side on the same PRG, diff screen RAM / CPU registers
- **CI-friendly** — a compiled binary runs anywhere, no FPGA needed,
  suitable for regression testing on every commit

What Verilator does NOT give us:
- Timing closure verification (still logical sim, no gate delays)
- Signal-integrity / marginal slack detection
- SDRAM controller timing (tRFC, refresh) unless the model is ported
- Analog audio quality (depends on the SID model)

## Existing art / prior work

The MiSTer ecosystem already has Verilator ports of several cores
(not C64 specifically — notably `Arcade-MCR3` and `NES` have had
Verilator harnesses). The idea is well-trodden; the C64 case is
harder because the core is VHDL-heavy while most Verilator-friendly
MiSTer cores are Verilog-native.

Relevant upstream:
- **Yosys** — open-source RTL synthesis, includes a Verilog frontend
  and can emit Verilog from its internal IR
- **ghdl-yosys-plugin** — bridges GHDL (VHDL) into Yosys's IR, so
  Yosys can ingest VHDL alongside Verilog
- **Verilator** — translates Verilog to high-speed C++ simulation

The chain: `VHDL -> GHDL -> ghdl-yosys-plugin -> Yosys IR -> write_verilog -> Verilator -> C++`.

## Scope

**In scope (MVP):**
- `fpga64_sid_iec.vhd` + all its Verilog/SV children compiled to a
  single Verilated binary
- Behavioral SDRAM backing store (reuse `sim/common/memory_models/simple_sdram_model.vhd` ported to C++ if needed, or model inline)
- ioctl-style PRG loader fed from command-line arg
- Real KERNAL/BASIC/CHARGEN ROMs loaded at startup from `sim/common/roms/`
- SDL2 video window mapping the VIC-II 504×312 frame buffer with
  the standard C64 palette
- SDL2 keyboard mapping to the CIA1 matrix
- SDL2 audio out from SID (or silent stub if SID port is painful)

**Out of scope for MVP (add later if the core works):**
- Disk drive (1541) emulation
- Cassette emulation
- Analog joystick / paddle
- REU (defer — only matters once MVP boots)
- Cartridge port
- Net / HPS interface
- Debug overlay / UART stream (reuse the RTL debug infra by flipping
  `DEBUG_ENABLE=1` at compile time)

## Toolchain setup

### Required packages

- **GHDL** ≥ 3.0 (already installed, used by `sim/p65c816_tb/`)
- **Yosys** ≥ 0.30 with VHDL support
- **ghdl-yosys-plugin** (built against the matching GHDL)
- **Verilator** ≥ 5.0 (supports SystemVerilog well)
- **SDL2** dev headers
- **C++17** compiler (clang or gcc)
- **pkg-config**, **make**, **cmake** (for the host glue code)

### Install notes (Windows)

The pain point is that GHDL + Yosys + Verilator together on Windows
is nontrivial. Two paths:

1. **WSL2** — all the toolchain lives in Linux, you run the binary
   inside WSL, X forwarding or WSLg shows the SDL window. Easiest
   to set up, same environment the project's existing Quartus build
   already uses.
2. **MSYS2 UCRT64** — native Windows binaries, works but requires
   more effort to package GHDL + Yosys + the plugin in compatible
   versions.

Recommend WSL2 for MVP. Migrate to native Windows later if needed.

## Architecture

```
sim/verilator_c64/
├── Makefile                     -- orchestrates yosys, verilator, g++
├── flow/
│   ├── vhdl_to_verilog.ys       -- Yosys script: ghdl -> write_verilog
│   └── patches/                 -- any staging patches mirroring
│                                   sim/c64_reduced_harness/build_staging/
├── host/
│   ├── main.cpp                 -- SDL event loop, binds to Verilated top
│   ├── vic_display.cpp          -- VIC-II frame buffer -> SDL texture
│   ├── keyboard_matrix.cpp      -- SDL keys -> CIA1 matrix columns
│   ├── audio_sid.cpp            -- SID sample ring -> SDL_AudioSpec
│   ├── ioctl_prg_loader.cpp     -- Command-line PRG -> ioctl driver
│   ├── rom_loader.cpp           -- Load KERNAL/BASIC/CHARGEN .bin
│   ├── sdram_behav.cpp          -- Byte-addressable backing store
│   └── cli.cpp                  -- Argument parsing
├── obj_dir/                     -- Verilator output (gitignored)
├── README.md
└── .gitignore
```

The top-level hierarchy in Verilator becomes a single C++ class
(e.g. `Vc64_top`) generated from the real `fpga64_sid_iec` + a
thin wrapper module. The `main.cpp` runs the SDL event loop and on
each iteration:

1. Drives `clk_sys` / `clk_c64` / `clk_vid` at the correct ratio
2. Lets Verilator evaluate for N ticks
3. Samples the VIC-II output pixels into the SDL framebuffer
4. Forwards SDL keyboard events to the CIA1 matrix model
5. Drains SID sample outputs to the audio ring
6. Feeds ioctl ROM/PRG bytes when requested

## Step-by-step implementation

### Step 1 — Toolchain proof (1–2 hours)

Install GHDL, Yosys + plugin, Verilator. Verify with a trivial test:
take `sim/p65c816_tb/p65c816_tb.vhd` or similar, compile to Verilog
via Yosys, then Verilate and run. This proves the toolchain is
functional before we invest in the C64 top.

### Step 2 — Verilator-analyze the real DUT (2–4 hours)

Write the `flow/vhdl_to_verilog.ys` Yosys script:

```
plugin -i ghdl
ghdl --std=08 --ieee=synopsys -frelaxed \
  C64_MiSTer/rtl/... ... fpga64_sid_iec.vhd -e fpga64_sid_iec
write_verilog sim/verilator_c64/flow/fpga64_sid_iec.v
```

Expected issues:
- Same GHDL `--std=08` gotchas as the existing harness:
  `fpga64_rgbcolor.vhd`, `cpu_6510.vhd`, `turbo_speed` case,
  `preCycle` bounds. Reuse the same `build_staging/` patches.
- Mixed-language instantiation: when `fpga64_sid_iec.vhd`
  instantiates Verilog children (`mos6526.v`, `sid_top.sv`,
  `reu.v`, `sdram.v`, `cartridge.v`), Yosys + ghdl plugin need
  those sources added to the same session so elaboration binds.
- `sys/*` dependencies: Yosys does not need the MiSTer framework,
  we stub it at the harness level.

### Step 3 — Verilate + link (4–8 hours)

Run Verilator on the emitted `fpga64_sid_iec.v` with the DPI
flag off, `-Wno-fatal`, `--trace` optional for debugging:

```
verilator --cc --build -j 0 \
  -Ifpga64_sid_iec.v \
  --top-module fpga64_sid_iec \
  host/main.cpp host/vic_display.cpp ...
```

Expected issues:
- `initial` blocks in Verilog children may not match Verilator's
  expectations — fix with explicit resets
- `logic` / `var` style differences between the ghdl-emitted Verilog
  and the existing `mos6526.v` — resolve by normalizing to one
  dialect
- Unused clock / reset signals: stub in the host wrapper

### Step 4 — Minimal boot (2–4 hours)

Goal: start the Verilated binary, load real ROMs, let the CPU come
out of reset and boot to the READY prompt. Success criterion:
capture the VIC-II frame buffer after ~500k cycles and check the
expected KERNAL welcome text at $0400.

This milestone is equivalent to Phase 4b's Scenario A but running
thousands of times faster.

### Step 5 — SDL frontend (4–8 hours)

Add video, keyboard, audio. Success criterion: type characters in
the SDL window, see them echoed in the C64 text screen, hear a tone
from `POKE 54276,33`.

### Step 6 — PRG loader + first game (2–4 hours)

Wire a command-line flag `--prg path/to/game.prg` that feeds bytes
through the same ioctl path the real hardware uses. Success
criterion: load and run asterix.prg (our current hardware
reproducer) and observe whether the same "loads-then-resets" bug
manifests in Verilator.

**This is the moment of truth for the debugging question.** If the
bug reproduces in Verilator but not in the GHDL benches, we have a
full waveform to trace. If it does not reproduce in Verilator either,
then the bug really is FPGA-physical (timing closure, signal
integrity, or something outside the logical model) and the
modularization + `-Release` build is the only path.

### Step 7 — Nice-to-haves (ongoing)

- Save states (`Verilated::save()` / `restore()`)
- Trace export to FST for post-mortem analysis of rare bugs
- REU support (extend ioctl loader to handle `.reu` files)
- 1541 disk drive support
- Cycle-accurate audio (depends on SID port fidelity)

## Risks

1. **Yosys + ghdl-plugin instability** — the plugin is maintained
   but not bulletproof. VHDL-2008 features that GHDL accepts may
   not round-trip through Yosys. Mitigation: if a feature fails,
   stub it out (we already have stubs for `cpu_6510` and
   `fpga64_rgbcolor`).

2. **Clock domain crossing** — Verilator handles one clock well;
   multi-clock designs need explicit step interleaving. The C64
   core has `clk_sys`, `clk_c64`, `clk_vid`, and PLL-derived clocks.
   Mitigation: use `V*::eval()` at the highest rate and derive the
   others by counting.

3. **Performance** — 30–60% real-time is optimistic; first runs
   often hit 10–20% because of unoptimized loops. Mitigation:
   profile with `verilator --prof`, enable `--x-assign fast`,
   consider `--threads 4`.

4. **Build-time coupling to MiSTer RTL changes** — every commit that
   touches RTL risks breaking the Verilator flow. Mitigation: run
   the Verilator build in CI on every PR that touches `C64_MiSTer/`.

5. **SDL / audio latency tuning** — 30 ms audio buffer is a common
   starting point but may cause crackling. Tune once video and
   keyboard work.

## When to build this

**Not now.** The pragmatic path (modularization → `-Release` →
redeploy asterix → see if it works) is cheaper and will very likely
resolve the current bug without any of this work. Verilator is the
right move if:

- The `-Release` build does NOT fix the asterix reproducer, AND
- We need to iterate on logical bug hypotheses that the GHDL harness
  is too slow to reach, OR
- We want a "desktop C64" to demo the SuperCPU fork without hardware

If both of those come true, the investment is ~2–4 developer-days
for a working MVP. Smaller than it sounds because the Phase 4b
harness already proved the ghdl-side instantiation of the real
`fpga64_sid_iec.vhd` works — the Yosys step is largely a translation
problem, not a semantic one.

## Validation checklist

MVP complete when:

- [ ] `make` in `sim/verilator_c64/` produces a native binary
- [ ] Binary boots to the C64 READY prompt within 10 seconds
  wallclock
- [ ] Keyboard input echoes to the text screen
- [ ] Audio output is audible (even if imperfect)
- [ ] `--prg asterix.prg` loads and runs the game
- [ ] `--prg test_addr0801.prg` round-trips cleanly (catches the
  meminit regression class)
- [ ] A differential run against a vanilla MiSTer C64 Verilator
  build (if ever produced) diffs only on expected SuperCPU
  registers
- [ ] Wallclock performance ≥ 30% real-time on a modern laptop
