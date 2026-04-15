# C64-Specific Simulation Harness Architecture

This note proposes a simulation harness architecture for the MiSTer SuperCPU C64 project, inspired by MiSTer-oriented desktop simulation projects such as JimmyStones/Verilator_Template, but tailored to this repository's constraints:

- primary RTL is VHDL
- existing CPU-focused GHDL benches already work
- full MiSTer top-level behavior is complex
- immediate goal is debugging PRG loading / native-mode execution without hardware

## Goals

The harness should let us test "load a PRG and run it" without MiSTer hardware or Quartus, while giving much better observability than the FPGA.

Primary goals:

1. Simulate PRG injection in a way that matches MiSTer's HPS/ioctl path closely enough to reproduce software-visible behavior.
2. Run enough of the C64/SuperCPU execution path to exercise:
   - BASIC pointer init after PRG load
   - execution from bank $00 RAM
   - transition from emulation mode to native mode
   - 65C816 post-XCE/REP execution
3. Observe internal state with deterministic, scriptable outputs.
4. Keep the first implementation much smaller than a full MiSTer desktop simulator.

Non-goals for phase 1:

- cycle-perfect video/audio output
- complete IEC drive emulation
- full MiSTer OSD/HPS framework emulation
- perfect SDRAM controller timing equivalence

## Recommended Architecture

Use a layered approach rather than jumping straight to a monolithic top-level simulation.

### Layer 1: CPU-Sequence Benches (already exists, extend further)

Keep and extend the existing GHDL benches under:

- `sim/p65c816_tb/`

Purpose:
- isolate CPU-core and wrapper bugs
- verify `CLC/XCE`, `REP/SEP`, immediate width behavior, long jumps, bank transitions
- inject CE stalls/dropped enables similar to real scheduler gating

This remains the fastest and most important layer for current PRG/native-mode debug.

### Layer 2: PRG Loader Integration Bench

Add a new VHDL/SystemVerilog integration bench that simulates only the minimum parts needed to reproduce PRG-load execution:

Suggested DUT boundary:
- `cpu_65c816.vhd`
- bank-$00 RAM model
- minimal ROM model
- minimal PRG injection state machine matching `c64.sv` behavior
- optional simplified buslogic for ROM/RAM visibility

This bench should not include full VIC/CIA/IEC unless needed.

Purpose:
- validate that PRG bytes end up in memory correctly
- validate BASIC pointer meminit logic
- start execution at the same address a loaded PRG would use
- verify whether failure occurs before full-system effects matter

### Layer 3: Reduced-System C64 Harness

Build a reduced-system harness around `fpga64_sid_iec.vhd` with simplified substitutes for the pieces that make full MiSTer simulation hard.

This harness would provide:
- clock/reset generation
- simplified SDRAM backing store
- ROM images
- PRG injection API
- scripted keyboard or direct SYS/start trigger
- internal debug capture

This is the layer most analogous to a JimmyStones-style desktop harness.

### Layer 4: Optional Desktop UI Front-End

Only after Layer 3 exists and is useful, consider a desktop runner with:
- step/run controls
- log console
- optional framebuffer view
- scripted regression scenarios

This can be implemented with C++ or Python around the simulator, but should be deferred until the headless harness is proven useful.

## Recommended Phase Breakdown

## Phase A — Immediate: Extend Existing CPU Benches

Add new focused benches under `sim/p65c816_tb/` for:

1. `SEI / CLC / XCE / REP #$30 / LDA #imm16 / BRA`
2. `SEI / CLC / XCE / JML banked-target`
3. same sequences with dropped CE pulses:
   - on XCE
   - after XCE
   - on REP operand fetch
   - on first post-REP instruction

Outputs to check:
- E flag
- M/X flags
- PC progression
- fetched operand bytes
- PBR/DBR
- wrapper vs bare-core differences

This phase is likely to identify whether the bug is:
- in `P65C816`
- in `cpu_65c816.vhd`
- or only in larger integration

## Phase B — Add a PRG Loader Integration Bench

Create a bench specifically for PRG-load semantics.

Suggested new directory:
- `sim/prg_loader_tb/`

Suggested components:
- simplified RAM image for bank $00
- ROM image with reset vectors / minimal KERNAL stubs
- PRG injector that emulates:
  - first 2 bytes = load address
  - subsequent bytes copied to RAM
  - BASIC pointer init (`TXT`, `VAR`, `ARY`, `STR`, `LOAD_END`, etc.)
- CPU start control to mimic `RUN` or `SYS`

Useful test cases:
1. tiny emulation-mode PRG
2. tiny native-switch PRG
3. native-switch + REP + immediate-width PRG
4. minimal Doom launcher sequence

Outputs:
- RAM dump around `$0801`
- CPU trace for first few hundred instructions
- pass/fail assertions on expected PC/border/debug writes

## Phase C — Reduced-System Harness Around `fpga64_sid_iec`

If Phase B is still inconclusive, move up to a larger harness.

Suggested new directory:
- `sim/c64_reduced_harness/`

### DUT

Primary DUT:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`

Potentially wrapped with a custom simulation top that replaces or abstracts:
- MiSTer HPS I/O
- physical SDRAM controller
- optional cartridge/drive subsystems

### Simulated peripherals / models

#### 1. Simplified SDRAM Model
Provide a behavioral memory model for:
- bank $00 backing store if needed
- SuperRAM banks
- REU region if needed later

Requirements:
- deterministic reads/writes
- scriptable initialization
- trace logging for suspicious addresses

It does **not** need to be a cycle-accurate SDRAM chip model at first.

#### 2. Minimal ROM Providers
Models for:
- KERNAL ROM
- BASIC ROM
- CHARGEN only if needed
- SuperCPU vector/overlay stub if required

Should allow deterministic startup and controllable reset vectors.

#### 3. PRG Injection Driver
A bench-side driver that mimics the software-visible effect of MiSTer's ioctl PRG load.

Two possible modes:

- **Behavioral mode**: directly perform the same memory writes + meminit side effects as `c64.sv`
- **Signal-accurate mode**: drive an internal pseudo-ioctl interface that mirrors the download protocol more closely

Recommendation:
- start with behavioral mode
- add signal-accurate mode only if a loader-path bug remains plausible

#### 4. Scripted Trigger Source
Instead of simulating full keyboard/BASIC input at first, provide direct triggers:
- start CPU at reset
- inject PRG
- optionally force `SYS <addr>`-like entry
- optionally patch memory to simulate `RUN`

This reduces complexity a lot.

## Observability Requirements

The biggest value of the harness is observability. It should expose more than hardware does.

### Required logs/signals

1. CPU trace:
- PC
- IR
- PBR
- DBR
- P
- SP
- VPA/VDA
- enable/CE

2. Memory access trace:
- reads/writes around `$0800-$0820`
- stack page `$0100-$01FF`
- vectors `$FFE0-$FFFF`
- SuperRAM accesses for banked tests

3. Loader trace:
- final PRG load address
- final `inj_end`
- pointer init writes
- first instruction bytes after load

4. Optional watchpoints:
- write to `$D020`
- write to `$0801`
- BRK vector fetch
- JML target fetch

### Output formats

Use simple machine-readable outputs first:
- text logs
- CSV/TSV traces
- memory dumps
- assertion pass/fail messages

Waveforms (`.ghw`/`.vcd`) remain useful but should not be the only output.

## Harness Control Interface

A good harness should be scriptable from CI or command line.

Suggested interface:

```text
run_harness --scenario test_xce_run
run_harness --prg tools/test_cart/test_xce.prg --mode run
run_harness --prg tools/test_cart/test_xce_fixed.prg --mode sys --entry 0x080d
run_harness --scenario rep_width_check --trace 500
```

The scenario layer should define:
- memory preload files
- ROM configuration
- PRG injection mode
- execution start method
- stop condition
- pass/fail checks

## Suggested Scenario Set

### Scenario 1: Emulation-only PRG smoke test
Purpose:
- prove PRG injection path works in reduced harness

Expected:
- correct execution from bank $00
- no crash

### Scenario 2: Native switch minimal
Purpose:
- reproduce `CLC/XCE` path after PRG load

Expected:
- E clears
- execution continues correctly

### Scenario 3: Native switch + REP width test
Purpose:
- target current strongest hypothesis

Expected:
- 16-bit immediate instruction consumes 2-byte operand
- PC lands on expected next instruction

### Scenario 4: JML after native switch
Purpose:
- verify bank transition logic post-native entry

Expected:
- correct PBR/PC target

### Scenario 5: Doom launcher minimal
Purpose:
- partial reproduction of real workload without full Doom

Expected:
- `JML $20:0000` or equivalent path reaches expected bank

## Language / Tool Recommendations

### For near-term work
Use:
- **GHDL** for VHDL benches
- existing PowerShell runner style like `sim/p65c816_tb/run_tb.ps1`

This fits the repo today.

### For larger harness work
Possible options:

#### Option A: GHDL-only headless harness
Pros:
- easiest fit with current VHDL codebase
- minimal new toolchain burden

Cons:
- less friendly for interactive UI

#### Option B: GHDL + Python runner
Pros:
- easy scripting
- easy log parsing, memory dump analysis, regression orchestration
- quick to iterate

Cons:
- not as fast/fancy as full C++ UI harness

#### Option C: Mixed translated/Verilator desktop harness
Pros:
- could eventually provide richer UI
- conceptually closer to JimmyStones template

Cons:
- highest effort
- weakest immediate fit for this VHDL-heavy project

Recommendation:
- **Phase A/B: GHDL + PowerShell/Python**
- only consider a Verilator-style front-end after the reduced harness proves valuable

## Suggested Repository Layout

```text
sim/
  p65c816_tb/
  prg_loader_tb/
  c64_reduced_harness/
  common/
    rom_images/
    memory_models/
    trace_utils/
```

Possible contents:

- `sim/common/memory_models/simple_sdram_model.vhd`
- `sim/common/memory_models/ram64k_model.vhd`
- `sim/common/trace_utils/cpu_trace_pkg.vhd`
- `sim/prg_loader_tb/run_tb.ps1`
- `sim/c64_reduced_harness/run_harness.ps1`

## Key Design Principle

Do **not** start by trying to simulate the whole MiSTer C64 core with all peripherals faithfully.

Instead:
- reproduce the smallest layer that still contains the suspected bug
- add realism only when a lower layer cannot explain the failure

For the current PRG-loading problem, the likely minimum useful reproducer is:
- PRG injected into bank $00 RAM
- 65C816 wrapper active
- native-mode entry sequence executed
- instruction width/PC progression checked

## Final Recommendation

Immediate next step:

1. extend `sim/p65c816_tb/` with a native-switch + REP-width bench
2. add a new `sim/prg_loader_tb/` integration bench
3. only then decide whether a larger reduced-system harness is needed

This approach gives the best chance of isolating the current PRG/native-mode failure quickly, while still building toward a reusable desktop simulation framework for future SuperCPU regressions.
