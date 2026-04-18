# Verilator Desktop Harness Plan

Status: **SHELVED 2026-04-18.** The SuperCPU-fork harness
(`sim/verilator_c64/`) was deleted in this revision. The vanilla
comparison harness (`sim/verilator_c64_vanilla/`) is retained as a
reference — it boots to READY at ~4M half-cycles and can be revived
if long-horizon differential testing becomes the critical path.

Why shelved (retrospective after ~3 days of work):
- The SuperCPU-fork harness never produced a linked binary and
  therefore never caught a single fork bug. All post-plan fixes
  (REU falling-edge, trace ring buffer 128, MGL PRG loading,
  meminit pulse) came from hardware + UART + GHDL benches.
- The current critical-path bugs (Doom X-flag, bank-$2D, REU +
  SuperRAM interactions) require REU, 16 MB SDRAM, and real CIA
  timing — none of which are in the harness. Adding them was
  another days-to-weeks of work with no guarantee of payback.
- Build cost (heavy, CPU-bound, regenerates on wrapper/RTL edits)
  undercut the "fast iteration" premise the plan was built on.
  A MiSTer deploy + UART round-trip is ~2 min, comparable to an
  incremental Verilator rebuild once the wrapper changes.

Previous goal (kept for historical reference): run the MiSTer C64
SuperCPU core on the developer PC as a desktop software emulator,
compiled from the real RTL via a VHDL → Verilog → Verilator → C++
flow. The original plan targeted Yosys + GHDL-plugin; the working
MVP path used `ghdl --synth --out=verilog` with `GHDL_BACKEND=gcc`,
followed by Verilator.

What survived: `sim/verilator_c64_vanilla/` with simulation-only
power-up RAM init modes (`off`, `zero`, `vice`), reset-hold until
prefill completes, and screenshot/text-screen PPM export. It is
not a polished or real-time-playable desktop C64.

Build policy note (still applies to the vanilla harness): full
Verilator builds are heavy, CPU-bound jobs. Rebuild only when the
harness is actually being used, and prefer incremental over clean
rebuilds.

Revival criteria (if this ever comes back): a SuperCPU-fork bug
survives >1 week of hardware + GHDL-bench debugging, OR
differential vanilla-vs-fork diffing becomes the cheapest path.
At that point, budget it explicitly as a fixed-duration spike
("one week, then kill or commit") rather than open-ended work.

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
- **GHDL** — used here both for simulation and for the current working
  RTL-to-Verilog synthesis step (`--synth --out=verilog`)
- **Yosys** — still useful for experimentation, but not the current
  working path for this harness
- **ghdl-yosys-plugin** — attempted first; presently fails on this
  design in the Ubuntu-packaged toolchain
- **Verilator** — translates synthesized Verilog to high-speed C++ simulation

Current working chain: `VHDL -> GHDL synth -> Verilog -> Verilator -> C++`.

## Scope

**In scope (MVP):**
- `fpga64_sid_iec.vhd` compiled through a reduced wrapper into a
  single Verilated binary
- Behavioral SDRAM backing store (currently reusing
  `sim/common/memory_models/simple_sdram_model.vhd` with a reduced
  default size of 256 KiB for tractable synthesis)
- ioctl-style PRG loader fed from command-line arg
- Real KERNAL/BASIC ROM loaded at startup from host-side `.mif` or
  raw 16KB ROM input
- SDL2 video window support in the host executable
- Headless execution plus FST tracing
- Accurate bank-$00 BRAM probing for screen RAM inspection

**Implemented now:**
- `sim/verilator_c64/Makefile`
- `sim/verilator_c64/verilator_c64_top.vhd`
- `sim/verilator_c64/host/main.cpp`
- `sim/verilator_c64_vanilla/` comparison harness with real T65 path
- WSL2 Ubuntu toolchain install and working build
- `make`, `make synth`, `make verilate`, `make run-headless`, `make run-sdl`
- ROM streaming under reset
- PRG injection (`--prg`)
- BRAM screen dump from `$0400..$07E7`
- vanilla-harness power-up RAM init modes (`--powerup-init off|zero|vice`)
- wrapper-level reset-vs-powerup split: internal reset stays asserted until RAM prefill completes

**Not implemented yet:**
- real CIA/mos6526 integration in the SuperCPU harness (the vanilla harness now swaps in real CIA RTL post-synth)
- real SID/audio pipeline (still stubbed/silent)
- keyboard matrix injection from SDL
- REU/cartridge/disk/tape integration
- full-size SuperRAM/REU-scale SDRAM backing store
- proof of BASIC `READY.` boot text on the desktop harness

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

Current working environment (verified in WSL2 Ubuntu on 2026-04-15):
- **ghdl** + **ghdl-gcc**
- **verilator**
- **SDL2** dev headers
- **C++17** compiler (g++)
- **pkg-config**, **make**
- optional: **yosys** + **yosys-plugin-ghdl** for experimentation

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

### Step 1 — Toolchain proof (completed)

WSL2 Ubuntu toolchain was installed and verified. The Yosys plugin loads,
but the actual C64 design hits a plugin-side failure later in import.
The harness therefore uses the GHDL synthesis path instead.

### Step 2 — Synthesize the reduced wrapper to Verilog (completed, revised)

Instead of the original Yosys script path, the working flow now runs:

```bash
GHDL_BACKEND=gcc ghdl --synth --out=verilog --std=08 --ieee=synopsys -frelaxed ... -e verilator_c64_top
```

Key implementation notes:
- The staging patches from `sim/c64_reduced_harness/run_harness_v2.sh`
  are still required and are applied by `sim/verilator_c64/flow/prepare_staging.sh`
- CIA and SID remain stubbed in the current desktop MVP
- Generated block comments are stripped before invoking Verilator,
  because Verilator mistakes some GHDL-emitted comments for meta-comments

### Step 3 — Verilate + link (completed, revised)

The current Makefile runs Verilator against the synthesized
`flow/generated/verilator_c64_top.v` and `host/main.cpp`.

Additional compatibility fixes that were required:
- force Verilog-2001 parsing with `--language 1364-2001`
  because GHDL emits identifiers such as `do`
- strip GHDL source-location block comments before Verilator parsing
- keep the current host as a single-file MVP (`host/main.cpp`)
  rather than the more modular host layout proposed originally

### Step 4 — Minimal boot (in progress)

Current state:
- the binaries build and run in WSL2
- ROM bytes are streamed while reset is held active
- the vanilla harness now performs an optional simulation-only bank-$00 RAM prefill before releasing internal reset
- CPU debug output advances into KERNAL code (`pc=$fd74`, `pc=$fd78` seen)
- the harness can dump true bank-$00 BRAM screen RAM via a dedicated
  BRAM probe path

Latest result on the vanilla harness after adding VICE-style deterministic RAM init:
- bank-$00 screen RAM is no longer forced to all-zero when `--powerup-init vice` is used
- longer inspection showed the machine is still in the KERNAL cold-start RAM test during the previously-reported 180k/300k runs; zero-page `$C2` advances page-by-page exactly as expected for the ROM RAM-test loop at `$FD50-$FD8D`
- therefore, those short runs were **not long enough** to judge whether BASIC boot succeeds; lack of `READY.` there was primarily a run-length / performance issue, not yet proof of a new logic blocker
- transient screen changes during these runs are from the RAM test touching `$0400` page contents, not from real screen editor initialization

Still missing for this milestone:
- a confirmed BASIC `READY.` screen in the desktop harness
- enough simulated run length / execution speed to get through cold-start RAM test in practical wallclock time
- stronger 6510 observability (the current vanilla debug address is a CPU bus address, not a true PC)

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

Current validation status (2026-04-15):

- [x] `make` in `sim/verilator_c64/` produces a native binary in WSL2
- [ ] Binary boots to the C64 READY prompt within 10 seconds wallclock
- [ ] Keyboard input echoes to the text screen
- [ ] Audio output is audible (even if imperfect)
- [ ] `--prg asterix.prg` loads and runs the game
- [x] `--prg test_addr0801.prg` path is wired and runs through the harness
- [ ] `test_addr0801.prg` round-trips with a dedicated semantic check
- [ ] A differential run against a vanilla MiSTer C64 Verilator build diffs only on expected SuperCPU registers
- [ ] Wallclock performance ≥ 30% real-time on a modern laptop

Practical MVP features currently available:
- working WSL2 build flow
- host-side ROM streaming from `.mif` or raw 16KB ROM blob
- host-side PRG injection via ioctl-style path
- headless execution
- optional SDL2 video window
- FST tracing
- CPU debug logging
- accurate bank-$00 BRAM screen probing
