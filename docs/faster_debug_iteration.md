# Faster Debug Iteration for MiSTer-Scale FPGA Cores

This note focuses on a practical question for this repo:

> How do we debug and test new FPGA behavior without paying for a full `RBF` rebuild every time?

The short answer is that the expensive step is usually not the final `RBF` file generation. The expensive step is map, fit, and timing closure. So the real goal is to avoid full recompilation when possible, and to make the builds you do need much more informative.

This repo already has useful pieces for that:

- [`build_c64.ps1`](../build_c64.ps1) supports syntax/elaboration-only runs.
- [`program_sof_jtag.ps1`](../program_sof_jtag.ps1) already programs `.sof` directly over JTAG.
- [`launch_signaltap.ps1`](../launch_signaltap.ps1) and [`docs/SIGNALTAP_GUIDE.md`](./SIGNALTAP_GUIDE.md) already support SignalTap.
- [`C64_MiSTer/rtl/debug_overlay.sv`](../C64_MiSTer/rtl/debug_overlay.sv), [`C64_MiSTer/rtl/debug_uart_fmt.sv`](../C64_MiSTer/rtl/debug_uart_fmt.sv), and [`C64_MiSTer/rtl/debug_uart_tx.sv`](../C64_MiSTer/rtl/debug_uart_tx.sv) already provide runtime observability.
- [`tools/test_cart/`](../tools/test_cart/README.md) and [`tools/rom_builder/`](../tools/rom_builder/README.md) already provide fast software-side test generation.
- [`tools/mister_debug.py`](../tools/mister_debug.py) already supports remote deploy, screenshots, UART reads, and basic automation.
- [`iigs_simulation/`](../iigs_simulation/readme.md) is already an in-repo example of a simulation-first debug loop.

## The Decision Ladder

Use the cheapest loop that can still answer the question.

| Method | Avoids map/fit? | Avoids SD/RBF deploy? | Needs hardware? | Best for |
|---|---:|---:|---:|---|
| `analysis_and_elaboration` only | Yes | Yes | No | Syntax, hierarchy, port mismatches |
| Narrow RTL simulation | Yes | Yes | No | CPU, bus, cache, decode, timing intent |
| Software-only testing on an existing debug build | Yes | Yes | Yes | Reproducers, ROM tests, carts, boot sequences |
| `update_mif` + re-assembly | Yes | Usually yes | Optional | Embedded ROM / MIF changes only |
| JTAG `.sof` programming | No | Yes | Yes | Faster on-board iteration after a compile |
| SignalTap / ISSP / Virtual JTAG on a pre-instrumented build | Yes, after instrumentation exists | Yes | Yes | Runtime inspection and poke paths |
| Incremental compilation / partitions | Partially | No | No | Reducing recompilation cost for localized RTL edits |
| Full compile + `RBF` deployment | No | No | Usually | Final validation and normal MiSTer distribution flow |

The key distinction is this:

- Programming a `.sof` instead of copying an `.rbf` is a useful speedup.
- But it does **not** avoid synthesis, fitting, or timing analysis.
- The biggest wins come from simulation, software-only test assets, `MIF` updates, and prebuilt debug hooks.

## 1. Zero-Build Checks First

For many edits, the fastest useful check is already in the repo:

```powershell
.\build_c64.ps1 -SyntaxOnly
```

That runs Quartus analysis and elaboration without fitting or generating programming files.

Use it for:

- broken generics/ports after RTL refactors
- missing files or bad hierarchy wiring
- type mismatches across VHDL/SystemVerilog boundaries
- quick validation of debug-only instrumentation edits

This should be the default first pass before any expensive build.

## 2. Put More Bugs into Simulation

The repo already proves this model can work: [`iigs_simulation/`](../iigs_simulation/readme.md) contains a separate simulation workflow and even single-step test integration. The C64 side should move closer to that model for new work.

### Good simulation targets in this repo

Do not start with full-system C64 simulation. Start with narrow harnesses around blocks where the bug actually lives:

- [`C64_MiSTer/rtl/cpu_65c816.vhd`](../C64_MiSTer/rtl/cpu_65c816.vhd)
- [`C64_MiSTer/rtl/fpga64_buslogic.vhd`](../C64_MiSTer/rtl/fpga64_buslogic.vhd)
- [`C64_MiSTer/rtl/cpu_cache.vhd`](../C64_MiSTer/rtl/cpu_cache.vhd)
- [`C64_MiSTer/rtl/debug_uart_fmt.sv`](../C64_MiSTer/rtl/debug_uart_fmt.sv)
- any new arbitration or debug register block added around `fpga64_sid_iec`

### What simulation should check

- CPU-visible reads/writes across `sysCycle`
- banked address generation
- bus ownership (`BA`, `AEC`, DMA, VIC slots)
- cache hit/miss and invalidation behavior
- register overlays at the `$D07x/$D0Bx` range
- debug event capture logic, including "last bad write" or "last zero read" latches

### Tooling direction

- Use GHDL for VHDL-heavy unit benches.
- Use cocotb if you want Python-driven regressions and golden traces.
- Keep the harnesses small enough that they run in seconds, not minutes.

This is the highest-value missing layer on the C64 side right now.

### Worked example: bare-CPU GHDL bench for the P65C816

[`sim/p65c816_tb/`](../sim/p65c816_tb/) is the canonical example of how cheap a narrow-scope sim can be on this codebase. It instantiates [`C64_MiSTer/rtl/65C816/P65C816.vhd`](../C64_MiSTer/rtl/65C816/P65C816.vhd) directly, with **no `fpga64_sid_iec` and no Intel megafunctions**, drives a 64 KB combinational `std_logic_vector` array as bank-$00 memory, and runs three back-to-back scenarios under one elaboration. From a clean checkout:

```powershell
.\sim\p65c816_tb\run_tb.ps1
```

…analyzes the seven RTL files plus the testbench, elaborates, runs to ~250 µs simulated time, and writes a per-cycle text trace plus a GHW waveform under `sim/p65c816_tb/work/`. End-to-end runtime is a few seconds. No build, no deploy, no UART scraping.

**Why this is the right shape for CPU-class bugs:**

1. **No vendor stubs.** The 65C816 core uses only `ieee.std_logic_1164`, `ieee.numeric_std`, and `work.P65816_pkg`. The full SDRAM/VIC/T65/BRAM ecosystem around it brings in altsyncram and friends — that path is dramatically more work to stub. Resist starting there.
2. **Direct RTL instantiation.** The testbench bypasses [`cpu_65c816.vhd`](../C64_MiSTer/rtl/cpu_65c816.vhd), the I/O-port wrapper. This is intentional: when a bug reproduces on bare `P65C816` it proves the core is at fault, and when it doesn't reproduce there but does in the wrapper or system, you have already partitioned the problem in one experiment.
3. **Scenario-controlled CE.** A single CE process can hold `CE` low for one clock to simulate the kind of pulse starvation a bus arbiter might cause. Detection uses live `DBG_IR` and a small `DBG_STATE` debug-output port that was added to `P65C816.vhd` (one new port, one assign — left `open` in the production wrapper so synthesis is unaffected).
4. **Per-cycle text trace via `report`.** Console output is `cyc=N STATE=s IR=$xx PC=$xxxx A_OUT=$xxxxxx D_IN=$xx VPA=v VDA=v` for every CE-active rising edge. Greppable, diff-able, survives in build logs. The `--wave=lda_long.ghw` dump exists for the rare case where the text isn't enough.

**What it actually proved.** This bench was built to investigate the `$AF/$5C/$8F/$CF` (4-byte long-instruction) crash described in [`docs/lda_long_crash_perplexity_brief.md`](./lda_long_crash_perplexity_brief.md). One leading hypothesis was `enableCpu_816` pulse starvation: that under some bus alignments the arbiter delivers fewer than 5 CE pulses per 5-state instruction, advancing `STATE` the wrong number of times relative to `PC`/`AB`. The bench tested this directly by deliberately dropping one CE pulse during state 3 (bank-byte fetch) and again during state 4 (data fetch) of `$AF`. **In both cases the dropped pulse caused only a one-cycle stall — `STATE`, `PC`, `AB`, `AA`, and `A_OUT` were all held stable, and the next active CE edge resumed the instruction identically to the no-drop baseline.** Pulse starvation is now eliminated as a root cause, which it could not have been from any amount of hardware deploy iteration. The bench took an afternoon to write and produced a definitive negative result the deploy/UART loop could not.

**The general method, abstracted from this example:**

| Step | What you do | Why |
|------|-------------|-----|
| 1 | Identify the smallest entity that could plausibly contain the bug. | The blast radius of your sim is the price you pay. Pick the smallest blast radius that still includes the suspect. |
| 2 | Confirm its dependencies are vendor-clean. `grep -i altera/altsync/lpm` over the source list. | Vendor stubs are the #1 reason narrow benches turn into multi-day projects. |
| 3 | Add minimal debug-output ports if internal signals you need are not exposed. Leave them `open` in the production wrapper. | One-line port additions are nearly free; brittle external shadowing of internal state is not. |
| 4 | Write a self-contained testbench entity (no ports). Initialize a memory model with the smallest reproducer. Drive a free-running clock. | Self-contained = `ghdl -r entity_name` with no plusargs or external files. |
| 5 | Run *multiple* scenarios in one elaboration, separated by `report` markers. | Three scenarios under one elaboration = one set of analyze/elaborate costs and trivially diff-able output. |
| 6 | Use `report` for the cycle log AND `--wave=*.ghw` for fallback waveform. | Text logs win for `grep`, regression diffs, and AI assistance. Waveforms win for "I don't even know what to look for yet." |
| 7 | Drive the whole thing from a tiny PowerShell script that hard-codes the GHDL path and source order. | Reproducible one-click runs are what stop a sim bench from bit-rotting. |

**Typical lifecycle of a finding from a bench like this:**

1. **Negative result on a hypothesis** → narrows the search space substantially. Worth the effort even when it doesn't find the bug. The pulse-starvation result above is exactly this.
2. **Positive reproduction in isolation** → the bug is in the entity under test or its immediate inputs. Iterate the same bench until characterized.
3. **Cannot reproduce in isolation** → the bug is in a larger context (wrapper, bus, system). Promote the bench: instantiate the wrapper instead of the core, or instantiate the next layer up. Only after you've climbed the hierarchy a layer at a time should you consider full-system simulation.

The 65C816 bench can be extended trivially: a fourth scenario that **forces `D_IN` to a wrong value for one cycle** during a specific `(IR, STATE)` would test the next hypothesis (wrong-byte delivery from the system) in the same elaboration. Adding a scenario costs maybe 15 lines of VHDL.

### When narrow-scope GHDL is *not* the right tool

- **Bugs that depend on real Intel block behavior.** M9K, M10K, MLAB, and PLLs have timing and initialization details that GHDL won't reproduce. Use ModelSim-Intel with the vendor libs, or fall back to SignalTap on real hardware.
- **Bugs tied to clock-domain crossings.** A bench at one `clk32` can simulate the CDC logic but cannot exercise the metastability the FPGA actually sees. Useful for protocol checks; not useful for racing-logic debugging.
- **Bugs that only appear with millions of cycles of state.** Bench runtime grows linearly. If you need to simulate a 30-second boot, GHDL won't help — you need on-board iteration.
- **Bugs in code paths driven by the MiSTer framework / `sys/`.** The framework is large and changing. Don't try to stub it; use software-side testing on a debug build instead (Section 3).

The decision is always: **what's the smallest blast radius that still contains the bug?** If GHDL of one entity covers it, that's where to start.

## 3. Use Software-Side Tests Against a Stable Debug Build

This repo is already unusually well set up for software-side isolation:

- [`tools/test_cart/`](../tools/test_cart/README.md) can generate focused CRTs.
- [`tools/rom_builder/`](../tools/rom_builder/README.md) can generate SuperCPU `MIF` images and loadable ROM bundles.
- [`docs/DIAGROM_DESIGN.md`](./DIAGROM_DESIGN.md) already points toward a reusable diagnostic ROM framework.

This matters because many questions are not "is the RTL syntactically correct?" but:

- does a specific boot sequence trigger the bug?
- does a different workload still fail?
- is the failure tied to KERNAL code, to a cart, or to bus timing?

For those cases, changing the software payload is often much cheaper than changing the core.

Recommended pattern:

1. Keep one known-good debug-capable FPGA image loaded.
2. Change only the test ROM, CRT, or embedded kick image.
3. Drive the board remotely with [`tools/mister_debug.py`](../tools/mister_debug.py).
4. Compare screenshots, UART output, and counters across runs.

That avoids the FPGA build entirely while still letting you narrow the bug class.

## 4. `MIF` Updates Are the Best Fast Path for Embedded ROM Work

This repo uses embedded ROM content, including [`C64_MiSTer/rtl/roms/scpu64.mif`](../C64_MiSTer/rtl/roms/scpu64.mif). If you are changing only the contents of a memory initialization file, you should not pay for a full refit.

Typical flow:

1. Rebuild the `MIF` using [`tools/rom_builder/`](../tools/rom_builder/README.md).
2. Update Quartus memory content.
3. Re-run the assembler stage.
4. Program the updated `.sof` or copy the regenerated `.rbf` if needed.

Example command pattern:

```powershell
wsl bash --noprofile --norc -lc '
  cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
  $HOME/intelFPGA_lite/17.0/quartus/bin/quartus_cdb --update_mif C64 -c C64
  $HOME/intelFPGA_lite/17.0/quartus/bin/quartus_asm --read_settings_files=on --write_settings_files=off C64 -c C64
'
```

Why this is valuable here:

- SuperCPU kick ROM changes are common during bring-up.
- diagnostic firmware experiments do not usually require RTL changes
- this is much cheaper than a full compile

For this repo specifically, a small wrapper script such as `update_scpu_mif.ps1` would be a good addition later. The capability matters more than the exact script name.

## 5. Program `.sof` Over JTAG for Hardware Iteration

When you do need a new FPGA build, prefer volatile JTAG programming during development:

```powershell
.\program_sof_jtag.ps1
```

This is already supported by the repo and is the right default for active bring-up because it:

- skips SD-card copy steps
- skips MiSTer menu/reload friction
- works naturally with SignalTap

Important nuance:

- `.sof` programming is a deployment optimization
- it is **not** a substitute for avoiding full compilation

So it helps, but it is not the main answer by itself.

## 6. Pre-Instrumented Runtime Debug Is Better Than Rebuilding for Every Probe

This repo already has three useful runtime debug surfaces:

- on-screen overlay
- UART text output
- SignalTap

The right strategy is to prebuild a small, stable debug fabric and then reuse it across many experiments.

### What to keep permanently available

- current CPU address/data/write-enable
- current bank byte
- `sysCycle`
- `BA` / `AEC`
- active CPU select
- cache hit/miss or bypass state
- last screen RAM write
- last suspicious VIC read
- a small event counter bank

### Why permanent hooks matter

SignalTap is powerful, but changing the captured signal set usually means recompiling. If you instead standardize a compact set of "always useful" debug registers and event latches, you can answer many questions without changing the FPGA image.

This repo is already close to that style in [`C64_MiSTer/rtl/fpga64_sid_iec.vhd`](../C64_MiSTer/rtl/fpga64_sid_iec.vhd), which exports a substantial set of debug signals and event captures.

## 7. Add JTAG-Controlled Read/Write Hooks, Not Just Waveform Capture

Waveforms are not the only useful runtime tool. For bugs that need controlled pokes, flags, or register reads, Intel's lighter-weight debug IP is often a better fit than growing SignalTap captures.

### In-System Sources and Probes

Good for:

- forcing a debug mode bit
- selecting one of several trace sources
- resetting counters
- reading a small debug status bank

This is a strong fit for MiSTer cores because it adds very little visible surface area to the final design and can be driven over JTAG after one instrumentation build.

### In-System Memory Content Editor

Good for:

- inspecting or patching on-chip RAM/ROM-style structures
- verifying whether a BRAM-backed table or debug buffer contains what you think it does

This is especially useful when the question is "what is actually stored in this memory right now?" rather than "what waveform produced it?"

### Virtual JTAG / System Console

Good for:

- custom debug register files
- host-driven reads/writes that are more structured than UART
- scripting repeatable board interactions

This is heavier than UART or overlay, but it is the cleanest way to build a custom on-chip debug control plane if the project grows beyond ad hoc bring-up.

For this repo, the most realistic next step is not "build a huge custom debug bus." It is:

1. keep UART and overlay for human-readable state
2. add a small JTAG-readable debug register bank
3. reserve SignalTap for timing questions that still need waveforms

## 8. Remote Automation Matters More Than It Looks

The less manual the test loop is, the fewer expensive hardware rebuilds you waste on weak hypotheses.

This repo already has the pieces:

- [`tools/mister_debug.py`](../tools/mister_debug.py)
- [`docs/mister_remote_debug_research.md`](./mister_remote_debug_research.md)

That should be treated as part of the debug system, not just convenience tooling.

Recommended uses:

- deploy or reload a known test image
- wait for boot
- grab a screenshot
- read debug UART for a fixed window
- compare results against a baseline

If you can automate ten software-side repros against one debug build, you often avoid several unnecessary FPGA rebuilds.

## 9. Incremental Compilation Is Worth It, but Only After the Debug Surface Stabilizes

Quartus design partitions and incremental compilation can reduce the cost of repeated builds, but they are not the first thing to do.

For this repo, the likely partitioning strategy would be:

- keep `sys/` static
- keep most video/audio plumbing static
- isolate the SuperCPU, cache, bus arbitration, and debug instrumentation region as the volatile partition

That can help once the debug hooks are mostly stable, but it has tradeoffs:

- partition boundaries can complicate timing
- early bring-up changes often cross boundaries anyway
- the payoff is much better once the design is structurally settled

So this is a medium-term improvement, not the first fast-iteration tool to reach for.

## 10. Formal Verification Is Useful, but Only for Small Local Properties

Formal is not a direct replacement for hardware debug here, and the mixed-language nature of the core limits where it fits cleanly. But it is still valuable for small invariants around new logic.

Good candidates:

- "a VIC-owned slot never commits a CPU write"
- "a debug event counter only increments on the intended condition"
- "cache invalidate always clears the matching line before reuse"
- "bank-zero overlays only trigger when bank byte is zero"

In practice, formal is most useful for new small helper blocks or simplified wrappers, not for the whole C64 core.

## Recommended Workflow for This Repo

If I were tightening the day-to-day loop for new SuperCPU or bus work here, I would use this order:

1. Run [`build_c64.ps1`](../build_c64.ps1) with `-SyntaxOnly` after every nontrivial RTL edit.
2. Push logic bugs into narrow simulation harnesses before touching hardware.
3. Use [`tools/test_cart/`](../tools/test_cart/README.md) and [`tools/rom_builder/`](../tools/rom_builder/README.md) to vary workloads without rebuilding the core.
4. When the change is only in embedded ROM content, use `update_mif` + `quartus_asm` instead of a full compile.
5. When hardware is needed, program `.sof` via [`program_sof_jtag.ps1`](../program_sof_jtag.ps1), not a copied `RBF`.
6. Use overlay and UART first, SignalTap second.
7. Add a small JTAG-readable debug register bank before adding ever-larger SignalTap profiles.
8. Only do full `RBF` builds when:
   - the RTL itself changed and must be compiled anyway
   - the debug fabric changed
   - you are validating the normal MiSTer distribution path

## Concrete Improvements That Would Pay Off Here

### High value, low risk

- Add a `MIF` refresh helper script around `quartus_cdb --update_mif` and `quartus_asm`.
- Create a `c64_simulation/` folder modeled after [`iigs_simulation/`](../iigs_simulation/readme.md) with narrow benches for CPU wrapper, buslogic, and cache.
- Standardize one compact always-on debug register set instead of growing ad hoc probes.
- Script a few repeatable remote test cases on top of [`tools/mister_debug.py`](../tools/mister_debug.py).

### High value, medium effort

- Add an In-System Sources and Probes endpoint for debug mode selects and counter reset.
- Add a small Virtual JTAG or JTAG-readable CSR block for structured host reads.
- Keep a dedicated "debug build" configuration with the overlay, UART, and minimal instrumentation permanently present.

### Medium value, later

- Partition the design for incremental compilation once the debug topology settles.
- Add formal checks around any new cache, arbitration, or event-latch helper blocks.

## Bottom Line

For a project like this one, the best way to avoid "full `RBF` rebuild" pain is not one trick. It is a layered workflow:

- simulation for logic
- carts/ROMs for workload changes
- `update_mif` for embedded firmware changes
- `.sof` for quick board programming
- persistent runtime debug hooks for visibility

The repo already contains most of the pieces. The biggest missing parts are:

1. a first-class `MIF` update path
2. narrow C64 simulation harnesses
3. a small reusable JTAG-readable debug register bank

Those three changes would reduce the number of full compile cycles more than almost anything else.

## References

### Repo-local

- [`DEBUG_GUIDE.md`](../DEBUG_GUIDE.md)
- [`docs/SIGNALTAP_GUIDE.md`](./SIGNALTAP_GUIDE.md)
- [`docs/mister_remote_debug_research.md`](./mister_remote_debug_research.md)
- [`tools/test_cart/README.md`](../tools/test_cart/README.md)
- [`tools/rom_builder/README.md`](../tools/rom_builder/README.md)
- [`iigs_simulation/readme.md`](../iigs_simulation/readme.md)
- [`sim/p65c816_tb/p65c816_lda_long_tb.vhd`](../sim/p65c816_tb/p65c816_lda_long_tb.vhd) and [`sim/p65c816_tb/run_tb.ps1`](../sim/p65c816_tb/run_tb.ps1)

### External

- Intel Quartus help, "Update Memory Initialization File"  
  https://www.intel.com/content/www/us/en/programmable/quartushelp/18.0/design/med/med_com_update_mif.htm
- Intel Quartus Tcl reference, `update_mif_files`  
  https://www.intel.com/content/www/us/en/docs/programmable/683432/21-4/tcl_pkg_eco_ver_1-0_cmd_update_mif_files.html
- Intel Quartus debug tools user guide PDF  
  https://cdrdv2-public.intel.com/721598/ug-qpp-debug-683819-721598.pdf
- GHDL quick start  
  https://ghdl.github.io/ghdl/quick_start/index.html
- cocotb quickstart  
  https://docs.cocotb.org/en/stable/quickstart.html
- SymbiYosys quickstart  
  https://symbiyosys.readthedocs.io/en/latest/quickstart.html
