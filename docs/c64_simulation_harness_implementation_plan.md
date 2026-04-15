# C64 Simulation Harness Implementation Plan

This plan turns `docs/c64_simulation_harness_architecture.md` into a concrete phased implementation roadmap.

The priority is to debug PRG loading / native-mode execution **without MiSTer hardware and without Quartus builds**, using the smallest useful simulation layers first.

**Update:** a likely root cause for the immediate PRG-load failure symptom has now been identified in the production RTL:
- `cache_fill_we` in `fpga64_sid_iec.vhd` was allowing fills while `bram_invalidate='1'`
- this could preserve stale pre-load bytes in the 8KB cache during PRG load / `inj_meminit`
- manual `$D078` flush after PRG load reportedly makes affected PRGs run

That means the harness effort should now explicitly support two tracks:
1. verify and regression-test the **stale-cache-during-load** failure class
2. continue investigating the possible **post-REP/native-mode CPU** issue seen in focused simulation

## Objectives

1. Reproduce the PRG/native-mode failure in simulation.
2. Separate cache/load invalidation bugs from CPU/wrapper/integration bugs.
3. Build reusable simulation infrastructure for future SuperCPU regressions.
4. Avoid jumping directly into a full-system simulation unless lower layers fail to explain the bug.

## Phase 0 — Baseline and Triage

### Goal
Document what already exists and lock in a baseline before adding more simulation.

### Existing assets

Already present:
- `sim/p65c816_tb/run_tb.ps1`
- `sim/p65c816_tb/p65c816_lda_long_tb.vhd`
- `sim/p65c816_tb/cpu_65c816_lda_long_tb.vhd`
- `sim/p65c816_tb/p65c816_rep_tb.vhd`

Already known:
- `p65c816_rep_tb.vhd` reports a post-REP width failure
- prior docs indicate PRG-loaded native-mode paths fail while POKE/SYS works
- a likely PRG-load root cause has been found: stale cache fills during `bram_invalidate`
- manual `$D078` flush after load reportedly makes affected PRGs run

### Deliverables

- preserve current bench outputs under source control or docs
- document current failures in one place

### Suggested doc updates

Add references from:
- `docs/prg_loading_debug_without_hardware.md`
- `docs/c64_simulation_harness_architecture.md`

to this plan.

### Success criteria

- current bench commands are reproducible
- current failing behavior is documented clearly enough to compare later changes
- cache-related PRG-load hypothesis is recorded as a first-class investigation target

## Phase 1 — Extend CPU-Level Benches

### Goal
Confirm whether the remaining native-mode failure is fundamentally a CPU/wrapper bug, independent of the stale-cache PRG-load issue.

### New directory/files

Under `sim/p65c816_tb/`, add:

- `p65c816_native_switch_tb.vhd`
- `cpu_65c816_native_switch_tb.vhd`
- optional runner update in `run_tb.ps1`

### Scenario set

#### Scenario A: XCE minimal
Program shape:
- `SEI`
- `CLC`
- `XCE`
- `BRA *`

Checks:
- E flag clears
- no illegal PC progression

#### Scenario B: XCE + REP + LDA #imm16
Program shape:
- `SEI`
- `CLC`
- `XCE`
- `REP #$30`
- `LDA #$1234`
- `BRA *`

Checks:
- M/X clear
- immediate consumes 2 bytes
- PC lands at correct next instruction
- A receives expected value if exposed or inferred

#### Scenario C: XCE + JML
Program shape:
- `SEI`
- `CLC`
- `XCE`
- `JML target`

Checks:
- PBR changes correctly
- target PC reached

#### Scenario D: CE perturbation
Repeat B/C with one dropped CE pulse:
- on XCE
- just after XCE
- on REP operand fetch
- on first post-REP instruction

Checks:
- determine whether scheduler-style CE gaps trigger failure

### Files to touch

- `sim/p65c816_tb/run_tb.ps1`
- new benches only

### Outputs

- text trace log
- pass/fail assertions
- waveform output (`.ghw`) where useful

### Success criteria

At end of Phase 1, we should know which of these is true:

1. **Bare core fails** -> root cause likely in `P65C816` behavior or adaptation assumptions
2. **Bare core passes, wrapper fails** -> root cause likely in `cpu_65c816.vhd`
3. **Both pass** -> bug likely requires larger integration context

## Phase 2 — Build PRG Loader / Cache-Invalidation Integration Bench

Status (2026-04-15): **IMPLEMENTED** at `sim/prg_loader_tb/`. Runs in
0.53s, 54/54 checks PASS across 3 scenarios (S1: $0801, S2: $1000,
S3: cold reads during invalidate window). Result: the narrow model of
`inj_meminit` + `bram_invalidate` + `cache_flush` + cache fill-gating is
internally consistent. The bench does **not** reproduce the hardware
"loads then memory resets" bug, which rules out this bug class and
points the next investigation at Phase 4 (SDRAM pipeline latency, real
1024×8 M10K cache, turbo/scheduler interactions, BASIC auto-RUN). See
`sim/prg_loader_tb/README.md`.

### Goal
Test PRG injection semantics and cache-invalidation hazards without full `fpga64_sid_iec` complexity.

### New directory

- `sim/prg_loader_tb/`

### New files

Suggested initial file set:

- `sim/prg_loader_tb/prg_loader_tb.vhd`
- `sim/prg_loader_tb/prg_loader_pkg.vhd`
- `sim/prg_loader_tb/run_tb.ps1`
- optional sample scenario data files under `sim/prg_loader_tb/data/`

### DUT boundary

Phase 2 should **not** use full `fpga64_sid_iec.vhd` yet.

Instead, include:
- `C64_MiSTer/rtl/cpu_65c816.vhd`
- simple RAM model for bank $00
- simple ROM model or ROM stubs
- simulation-side PRG injector
- minimal reset/start control

Optional later:
- small subset of buslogic behavior for ROM/RAM visibility

### Behavior to model

The bench should emulate the software-visible effect of the PRG load path in `c64.sv` and, where possible, the relevant cache invalidation/fill hazard:

1. first two PRG bytes define load address
2. remaining bytes copied to RAM
3. BASIC pointers initialized the same way `inj_meminit` does
4. execution started in a chosen mode:
   - `RUN`-like
   - `SYS`-like
   - direct PC jump for controlled experiments

### Test scenarios

#### Scenario 0: stale-cache-during-load reproducer
Build a focused scenario that models:
- stale memory contents at the target address range
- PRG write/update sequence
- invalidation window during which speculative/cold-start reads are possible
- optional cache fill suppression vs non-suppression

Expected:
- without `not bram_invalidate`-style gating, stale bytes can survive in the simulated cache layer
- with the gate, post-load execution sees the correct PRG bytes


#### Scenario 1: Emulation-only PRG
Use something like `test_noswitch.prg` semantics.

Expected:
- program executes normally

#### Scenario 2: Native switch PRG
Equivalent to `test_xce.prg` style semantics.

Expected:
- reproduce failure if loader path is relevant

#### Scenario 3: Native switch + fixed known bytes
Manually inject a tiny synthetic PRG with:
- `SEI`
- `CLC`
- `XCE`
- `REP #$30`
- `LDA #$1234`

Expected:
- deterministic reproduction independent of BASIC tokenized PRG complexities

#### Scenario 4: Compare RUN-like vs SYS-like startup
Expected:
- determine if failure is tied to BASIC execution context or simply loaded code bytes

### Outputs

- RAM dump around load address and zero-page pointer area
- trace of injection writes
- CPU execution trace
- optional watchpoints on `$0801`, stack, vectors

### Success criteria

At end of Phase 2, we should know whether:

1. the failure reproduces in a small PRG integration bench
2. loader semantics matter
3. BASIC-context differences matter

## Phase 3 — Common Simulation Utilities

### Goal
Avoid duplicated models and trace logic across benches.

### New directory

- `sim/common/`

### Suggested files

#### Memory models
- `sim/common/memory_models/ram64k_model.vhd`
- `sim/common/memory_models/simple_bankmem_model.vhd`
- later: `sim/common/memory_models/simple_sdram_model.vhd`

#### Trace support
- `sim/common/trace_utils/cpu_trace_pkg.vhd`
- `sim/common/trace_utils/watchpoint_pkg.vhd`

#### Data helpers
- `sim/common/data/prg_loader_pkg.vhd`
- or plain text/binary loader utilities if bench format supports it

### Purpose
Shared helpers for:
- RAM/ROM behavior
- CPU trace formatting
- watchpoints/assertions
- deterministic scenario setup

### Success criteria

- Phase 1 and Phase 2 benches can share models or helper packages
- no duplicated ad-hoc trace code where reusable utilities make sense

## Phase 4 — Reduced-System Harness Around `fpga64_sid_iec`

Status (2026-04-16): **SKELETON IMPLEMENTED** at `sim/c64_reduced_harness/`.
Runs end-to-end in under 1s, 40/40 scoreboard checks PASS, exit 0.
Instantiates the **real** `P65C816` CPU core + behavioral SDRAM
(`sim/common/memory_models/simple_sdram_model.vhd`, 2-stage bank $00 /
3-stage SuperRAM) + faithful `inj_meminit` + `bram_invalidate` /
`cache_flush` glue + 1-cycle-latency cache stub with the
`not bram_invalidate` fill gate. Scenarios: (A) reset + 500-cycle
warm-up, (B) scripted PRG load at $0801, (C) immediate readback,
(D) +2000 CPU cycles then re-verify ("loaded-then-wiped" catch).

Result: **does not reproduce the hardware bug** — yet another ruling-out.
The skeleton does **not** instantiate the real `fpga64_sid_iec.vhd` — that
requires VHDL stubs for multiple Verilog children (`mos6526.v`, `sid_top`,
`reu.v`, `sdram.v`, `cartridge.v`) that GHDL cannot analyze. Phase 4b
(below) is the unified "full reduced `fpga64_sid_iec` on real ROMs" target.

### Phase 4b (next) — Full real-DUT harness

Author VHDL behavioral stubs with matching entity interfaces but empty
or minimal-correct architectures for: `mos6526`, `sid_top`, `reu`,
`sdram` (wrap the existing simple_sdram_model), `cartridge`. Then
instantiate the **real** `C64_MiSTer/rtl/fpga64_sid_iec.vhd` on top.
Pre-populate KERNAL/BASIC/CHARGEN regions from real .rom binary files
at elaboration time. With the real DUT, the bench automatically gets:
- sysCycle 32-phase bus arbitration (EXT/DMA/VIC/CPU slots)
- Turbo mode scheduling + write buffer drain
- Real BRAM + real cache + real SDRAM mux
- Real BASIC boot + auto-RUN path

This is the closest we can get to hardware without building a bitstream,
and should reproduce any bug that lives in the scheduler or the BASIC
auto-RUN NEW-wipe path.

### Goal
Only if needed, move up to a larger integration target that includes the real bus arbitration and more of the real memory path.

### New directory

- `sim/c64_reduced_harness/`

### New files

Suggested starting set:

- `sim/c64_reduced_harness/c64_reduced_harness_tb.vhd`
- `sim/c64_reduced_harness/c64_reduced_top.vhd`
- `sim/c64_reduced_harness/run_harness.ps1`
- `sim/c64_reduced_harness/scenarios/`

### DUT choice

Primary DUT:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`

### Simulated substitutes

#### Replace or stub
- HPS/ioctl framework
- full MiSTer top-level glue
- physical SDRAM controller
- optional cartridge/drive pieces unless required

#### Provide simplified models for
- SDRAM backing store
- ROM contents
- PRG injection mechanism
- start trigger / keyboard surrogate

### Key focus

This harness should answer questions that smaller benches cannot, especially:
- does `enableCpu` scheduling affect the failure?
- do BRAM/cache/buslogic interactions matter?
- do ROM/RAM visibility transitions matter in the failing path?

### Observability

Must include logging for:
- `enableCpu`, `cpu_cyc`, `superram_enable_delay`
- BRAM/cache hit indicators where relevant
- CPU PC/PBR/P/IR
- reads/writes around failure points

### Success criteria

- can run a scripted PRG-load scenario headlessly
- can produce enough trace to classify bug as loader/cpu/cache/scheduler/integration

## Phase 5 — Scenario Runner and Regression Layer

### Goal
Turn benches into reusable regression tools.

### Suggested files

- `sim/run_regress.ps1`
- optional `sim/run_regress.py`
- `sim/scenarios/manifest.json` or similar

### Functionality

Support commands like:

```text
run_regress native_switch
run_regress prg_loader_smoke
run_regress rep_width
run_regress jml_bank_transition
```

Each scenario should define:
- bench to run
- optional PRG input
- stop condition
- expected outputs/assertions
- artifacts to retain on failure

### Regression targets

Initial set:
- `rep_width`
- `xce_minimal`
- `jml_minimal`
- `prg_emulation_smoke`
- `prg_native_switch`

### Success criteria

- one command runs all high-value simulations
- failures are easy to compare before/after RTL changes

## Phase 6 — Optional Desktop Front-End

### Goal
Only after headless simulation is valuable, consider a richer front-end inspired by MiSTer/Verilator desktop harnesses.

### Potential features

- single-step / multi-step control
- live log window
- optional framebuffer viewer
- register/watchpoint pane
- scripted PRG upload button

### Recommended approach

Build around an already-working headless harness, not the other way around.

Possible technologies:
- Python UI around subprocess-driven simulation
- C++ UI only if clearly justified

### Success criteria

- improves developer speed beyond headless scripts
- does not become the critical path for correctness work

## Concrete Task List

## Immediate tasks (do now)

1. **Add Phase 1 native-switch benches**
   - create `p65c816_native_switch_tb.vhd`
   - create `cpu_65c816_native_switch_tb.vhd`
   - add to `run_tb.ps1`

2. **Codify current REP failure**
   - capture the existing failure in a doc note or comments
   - ensure the new runner clearly reports it

3. **Define common trace format**
   - standardize log fields across benches:
     - cycle
     - scenario
     - PC
     - IR
     - P
     - PBR
     - DBR
     - state
     - CE/enable

## Near-term tasks (after Phase 1)

4. **Create `sim/prg_loader_tb/` skeleton**
   - runner script
   - memory model
   - simple injector package

5. **Implement synthetic native-switch PRG scenario**
   - no dependency on external tokenized BASIC files at first

6. **Compare RUN-like vs SYS-like start conditions**

## Later tasks (only if still needed)

7. **Create `sim/common/` shared packages**
8. **Build `sim/c64_reduced_harness/` around `fpga64_sid_iec`**
9. **Add regression manifest/runner**
10. **Consider optional desktop UI**

## Priority Order

Recommended execution order:

1. Phase 1 — CPU/native-switch benches
2. Phase 2 — PRG loader integration bench
3. Phase 3 — shared utilities as needed
4. Phase 5 — regression runner for completed benches
5. Phase 4 — reduced-system harness only if lower layers are inconclusive
6. Phase 6 — optional UI last

This ordering minimizes effort while maximizing diagnostic value.

## Key Decision Gates

### Gate A — After Phase 1
If bare or wrapper bench reproduces the bug:
- do **not** move immediately to full-system harness
- fix/analyze CPU or wrapper behavior first

### Gate B — After Phase 2
If PRG loader bench reproduces the bug:
- loader-context simulation is sufficient for this class of issues
- reduced-system harness may be unnecessary for now

### Gate C — Before Phase 4
Only build the `fpga64_sid_iec` reduced harness if:
- CPU/wrapper benches pass
- PRG loader bench is inconclusive
- bug still appears likely to involve scheduler/cache/buslogic interactions

## Recommended File Ownership / Edit Scope

### Safe initial edit scope
- `sim/p65c816_tb/*`
- new `sim/prg_loader_tb/*`
- new `sim/common/*`
- docs only

### Avoid early edits to
- `C64_MiSTer/sys/*`
- large top-level simulation plumbing
- production RTL unless a bench already proves the bug location

## Definition of Success

This harness effort is successful if it gives us a simulation-driven answer to:

> Is PRG loading actually broken, or is the loaded PRG exposing a 65C816 native-mode execution bug?

And, ideally:

> At which layer does the failure first become reproducible: bare core, wrapper, loader integration, or full reduced system?

## Recommended Next Actions

Best immediate coding tasks now are:

1. verify the production RTL cache-fill fix against real build results
2. keep **Phase 1** active with focused native-switch benches under `sim/p65c816_tb/`
3. shape **Phase 2** so it can explicitly model the stale-cache-during-load failure class

That gives coverage for both the practical PRG-load bug and the possible deeper CPU/native-mode bug.
