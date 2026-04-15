# MiSTer FPGA VHDL Core — CLI Simulation & Debug Reference

> **Purpose:** A practical do's-and-don'ts guide for AI agents running GHDL, cocotb, GTKWave/Surfer, Verilator (via GHDL bridge), and the ghdl-yosys-plugin for MiSTer FPGA VHDL core development. Build Quartus only when simulation passes.

---

## Quick-Reference: The Debug Loop

```
1. ghdl -a  →  ghdl --elab-run  →  .ghw / .vcd / .fst
2. (waveform viewer or VCD parser reads output)
3. AI identifies bug, edits VHDL
4. Repeat — no Quartus involved
5. Build to hardware only when ALL testbenches pass
```

---

## Tool Stack Installation (one-liner via oss-cad-suite)

The fastest way to get GHDL + Yosys + ghdl-yosys-plugin + GTKWave + Verilator in one shot:

```bash
# Download oss-cad-suite (Linux x64 example — includes VHDL support bundled)
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-linux-x64-$(date +%Y%m%d).tgz
tar xf oss-cad-suite-linux-x64-*.tgz
source oss-cad-suite/environment
# Verify
ghdl --version
yosys --version
gtkwave --version
verilator --version
```

> ✅ **DO** source `environment` at the start of every shell session or agent subprocess.
> ❌ **DON'T** mix oss-cad-suite GHDL with a system-installed GHDL — PATH conflicts cause subtle linker errors.

---

## GHDL

### The Three-Step Flow

```bash
# 1. Analyse (compile) — must be done bottom-up (dependencies first)
ghdl -a --std=08 --ieee=standard pkg_foo.vhd
ghdl -a --std=08 --ieee=standard my_core.vhd
ghdl -a --std=08 --ieee=standard tb_my_core.vhd

# 2. Elaborate
ghdl -e --std=08 tb_my_core

# 3. Run (simulation flags go AFTER the unit name — see gotcha below)
./tb_my_core --wave=out.ghw --stop-time=10us
# OR use the one-shot elab-run command:
ghdl --elab-run --std=08 --ieee=standard tb_my_core --wave=out.ghw --stop-time=10us
```

### Common Flags

| Flag | Effect |
|------|--------|
| `--std=08` | VHDL-2008 (use this for all MiSTer work) |
| `--std=93` | VHDL-1993 (some older cores) |
| `--ieee=standard` | Clean IEEE libs — use this by default |
| `--ieee=synopsys` | Adds `std_logic_arith`, `std_logic_unsigned` — avoid if possible |
| `--work=mylib` | Set target library (default: `work`) |
| `-g` | Emit debug info (line numbers in error traces) |
| `--wave=out.ghw` | GHW waveform output (native VHDL, supports records/arrays) |
| `--vcd=out.vcd` | VCD output (Verilog-origin format — limited VHDL type support) |
| `--fst=out.fst` | FST output (smaller than VCD, supported by Surfer & GTKWave) |
| `--stop-time=10us` | Stop simulation after 10 µs sim time |
| `--stop-delta=1000` | Halt after 1000 delta cycles (catches infinite loops) |
| `--assert-level=warning` | Abort on any WARNING or above (tightens assertion checking) |
| `--ieee-asserts=disable-at-0` | Suppress noisy ieee package assertions at t=0 |
| `-gGENERIC=VALUE` | Set a top-level generic at runtime, e.g., `-gDATA_WIDTH=16` |
| `--disp-time` | Print simulation time at each step (verbose, useful for hangs) |
| `--no-run` | Elaborate only, do not simulate |

### ⚠️ Critical Gotchas

**1. Simulation flags must come AFTER the unit name with `--elab-run`**

```bash
# ❌ WRONG — --assert-level silently ignored or errors
ghdl --elab-run --std=08 --assert-level=warning tb_core

# ✅ CORRECT — simulation options after unit name
ghdl --elab-run --std=08 tb_core --assert-level=warning --stop-time=1ms
```

This is the single most common source of agent confusion. Elaboration options (e.g., `--std=08`, `--ieee=`) go **before** the unit name; runtime options (e.g., `--stop-time=`, `--wave=`, `--assert-level=`, `-gGENERIC=`) go **after**.

**2. VCD does not support VHDL records or arrays — use GHW or FST**

```bash
# ❌ Records and arrays silently missing from output
ghdl --elab-run --std=08 tb_core --vcd=out.vcd

# ✅ Use GHW (native) or FST for full VHDL type support
ghdl --elab-run --std=08 tb_core --wave=out.ghw
# OR convert ghw → vcd post-simulation if VCD is required:
ghw2fst out.ghw out.fst   # then read fst
```

**3. File order matters — analyze bottom-up**

```bash
# ❌ WRONG — top-level before its dependencies
ghdl -a --std=08 tb_my_core.vhd my_core.vhd

# ✅ CORRECT — packages and entities first, testbench last
ghdl -a --std=08 pkg_types.vhd my_core.vhd tb_my_core.vhd
```

**4. Simulation hangs with no `--stop-time`**

If a testbench has no `wait` or `assert false; report "done" severity failure;` terminator, GHDL will run forever. Always specify `--stop-time` or terminate with:

```vhdl
-- In testbench, after stimulus:
assert false report "Simulation complete" severity failure;
```

**5. Work library artifacts must exist before elaboration**

GHDL writes object files (`work-obj08.cf`) to the current directory by default. If running from a different directory or in a CI clean state, re-run all `-a` steps first.

```bash
# Force re-analyse everything (safe default for agent pipelines)
rm -f work-obj*.cf *.o
ghdl -a --std=08 --ieee=standard *.vhd
```

**6. `--ieee=synopsys` operator ambiguity**

Using `std_logic_arith` or `std_logic_unsigned` alongside `std_logic_1164` causes operator `"="` overload ambiguity. Always prefer `ieee.numeric_std`. If a legacy MiSTer core uses the synopsys libs:

```bash
ghdl -a --std=08 --ieee=synopsys --warn-no-std legacy_core.vhd
```
Expect warnings; do not promote to errors until legacy libs are cleaned up.

**7. Stack overflow on large designs**

```bash
# Fix: remove stack size limit before running simulation
ulimit -s unlimited
./tb_my_core --wave=out.ghw
```

---

## Waveform Analysis (CLI / Headless)

### GHW/VCD/FST Format Decision

| Format | Records | Arrays | File Size | Tool Support |
|--------|---------|--------|-----------|--------------|
| `.ghw` | ✅ | ✅ | Large | GTKWave, ghwdump |
| `.vcd` | ❌ | ❌ | Largest | Universal |
| `.fst` | ❌ | ❌ | Small | GTKWave, Surfer, wellen |

Use `.ghw` for debugging VHDL-rich designs. Use `.fst` when integrating with Surfer, wellen-based parsers, or any tool that doesn't speak GHW.

### ghwdump — inspect GHW headlessly

```bash
# List all signals in GHW
ghwdump --list-signals out.ghw

# Dump signal values at each timestep
ghwdump --dump out.ghw

# Show hierarchy only
ghwdump --info out.ghw
```

### GTKWave headless batch mode (extract signal values to file)

```bash
# Create a .tcl batch script:
cat > extract.tcl << 'EOF'
set dumpfile "out.vcd"
set savefile "signals.gtkw"
gtkwave::loadFile $dumpfile
set nfacs [gtkwave::getNumFacs]
set all_facs [list]
for {set i 0} {$i < $nfacs} {incr i} {
    lappend all_facs [gtkwave::getFacName $i]
}
puts $all_facs
gtkwave::quit
EOF

gtkwave --tcl_init extract.tcl --script extract.tcl out.vcd
```

### vcd_parser / wellen (Python, headless AI-friendly)

```bash
pip install vcd          # pyVCD — simple signal extraction

python3 - << 'EOF'
import vcd
with open("out.vcd") as f:
    reader = vcd.VCDReader(f)
    for timestamp, signal, value in reader:
        print(f"{timestamp}: {signal.reference} = {value}")
EOF
```

For `.fst` files, the `wellen` Rust library (used by surfer-mcp and the waveform MCPs) is the fastest option. It has Python bindings via `pywellen`:

```bash
pip install pywellen

python3 - << 'EOF'
import pywellen
wave = pywellen.Waveform("out.fst")
signals = wave.hierarchy()
# Get all transitions for a signal
data = wave.signal_data("tb_core/dut/state")
for (time, value) in data:
    print(f"{time}ps: {value}")
EOF
```

---

## cocotb + GHDL

### Minimal Makefile

```makefile
SIM          = ghdl
TOPLEVEL_LANG = vhdl
VHDL_SOURCES  = $(PWD)/../rtl/my_core.vhd $(PWD)/tb_my_core.vhd
TOPLEVEL      = tb_my_core
MODULE        = test_my_core          # Python testbench module name

# GHDL-specific compile args
COMPILE_ARGS  += --std=08 --ieee=standard

# GHDL-specific sim args (go AFTER unit name — cocotb handles this correctly)
SIM_ARGS      += --stop-time=1ms
WAVE_FORMAT   ?= ghw
ifeq ($(WAVE_FORMAT),ghw)
  SIM_ARGS += --wave=$(SIM_BUILD)/$(TOPLEVEL).ghw
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
```

Run: `make WAVES=1` or `make WAVE_FORMAT=fst`

### Python Runner (preferred over Makefile per cocotb docs)

```python
# runner.py
import os
from pathlib import Path
from cocotb.runner import get_runner

def test_my_core():
    hdl_toplevel = "tb_my_core"
    runner = get_runner("ghdl")
    runner.build(
        vhdl_sources=[
            Path("../rtl/my_core.vhd"),
            Path("tb_my_core.vhd"),
        ],
        hdl_toplevel=hdl_toplevel,
        always=True,
        build_args=["--std=08", "--ieee=standard"],
    )
    runner.test(
        hdl_toplevel=hdl_toplevel,
        test_module="test_my_core",
        test_args=["--stop-time=1ms", "--wave=sim_build/out.ghw"],
    )

if __name__ == "__main__":
    test_my_core()
```

### ⚠️ cocotb + GHDL Gotchas

**1. `TOPLEVEL_LANG` must be set to `vhdl`** — it defaults to `verilog`, silently skipping VHDL sources.

**2. `GHDL_ARGS` vs `COMPILE_ARGS` vs `SIM_ARGS`**

- `COMPILE_ARGS` → passed to `ghdl -a` (analysis)
- `SIM_ARGS` → passed after the unit name to the simulator — these are *runtime* options
- Never put `--std=08` in `SIM_ARGS`; it will be ignored or error

**3. cocotb requires Verilator ≥ 5.022 if using `SIM=verilator`**; older versions have incomplete VPI support that breaks cocotb's signal access.

**4. GENERATE statement children in GHDL are accessed with integer strings**

```python
# ❌ dut.gen_pe[1]  — Python syntax error
# ✅
child = getattr(dut, "gen_pe(1)")   # VHDL for-generate instances
```

**5. Signal access with GHDL uses VHPI, not VPI** — some cocotb VPI-only features will not work. Check the `cocotb` simulator support page for known GHDL VHPI limitations before writing complex testbench introspection.

---

## ghdl-yosys-plugin (VHDL → Yosys Bridge)

### Setup Check

```bash
# Verify plugin is available (oss-cad-suite includes it)
yosys -m ghdl -p "help ghdl"
# Should print the ghdl command help, not an error
```

### Synthesize VHDL for Lint/Analysis

```bash
# Analyse all VHDL first (required — plugin reads GHDL's internal IR)
ghdl -a --std=08 --ieee=standard my_core.vhd

# Launch Yosys with GHDL plugin and synthesize
yosys -m ghdl << 'EOF'
ghdl --std=08 --ieee=standard my_core -e rtl
# Now the design is loaded as a Yosys module
proc
opt
fsm
memory
opt
# Export to Verilog (unlocks Verilator MCP, Verible lint, etc.)
write_verilog my_core_synth.v
# Or write netlist JSON
write_json my_core_netlist.json
EOF
```

> ✅ The `ghdl` command inside Yosys takes the **top entity name** (and optionally architecture), not a filename. Files must be pre-analysed.

### Quick Synthesis Check (no Yosys session needed)

```bash
# Fast synthesizability check — much faster than Quartus
ghdl --synth --std=08 --ieee=standard my_core.vhd -e my_core 2>&1
```

### ⚠️ ghdl-yosys-plugin Gotchas

**1. All units must be analysed before invoking the plugin**
The plugin reads GHDL's compiled IR (`.cf` files), not VHDL source directly.

**2. VHDL-2008 features not all supported for synthesis**
Simulation-only constructs (file I/O, `wait for`, unconstrained ports in synthesis context) will error. Use `--synth` first as a pre-flight check.

**3. Mixed VHDL+Verilog**: Add Verilog files as normal Yosys `read_verilog` before calling `ghdl`:

```bash
yosys -m ghdl << 'EOF'
read_verilog verilog_module.v
ghdl --std=08 vhdl_top.vhd -e vhdl_top
hierarchy -check -top vhdl_top
synth -top vhdl_top
write_verilog mixed_out.v
EOF
```

---

## Verilator (Post-GHDL Conversion)

Verilator does not natively simulate VHDL. Workflow: GHDL synthesis → Verilog → Verilator.

```bash
# Step 1: Get synthesized Verilog from GHDL+Yosys (see above)
# Step 2: Lint with Verilator (fast, good for AI agent error loops)
verilator --lint-only -Wall my_core_synth.v 2>&1

# Step 3: Compile for simulation
verilator --cc --exe --build --trace-fst \
  -CFLAGS "-O2" \
  my_core_synth.v sim_main.cpp \
  -o sim_my_core

# Step 4: Run simulation
./obj_dir/sim_my_core +trace
# Produces: dump.fst (or dump.vcd with --trace instead of --trace-fst)
```

### Key Verilator CLI Flags

| Flag | Effect |
|------|--------|
| `--lint-only` | Check for errors/warnings without building |
| `--cc` | C++ output |
| `--trace-fst` | FST waveform output (preferred — smaller than VCD) |
| `--trace` | VCD output |
| `-Wall` | All warnings |
| `--Wno-fatal` | Don't treat warnings as fatal (for legacy code) |
| `--top-module <name>` | Specify top module if ambiguous |
| `--assert` | Enable SystemVerilog assertions |
| `-O3` | Maximum C++ optimization (fastest simulation) |
| `--coverage` | Enable code coverage instrumentation |
| `--threads <N>` | Parallel simulation (Verilator 5+) |

### ⚠️ Verilator Gotchas

**1. Verilator is a compiler, not a simulator** — it compiles RTL to C++. Always link and compile the output before running.

**2. Synthesis-only subset** — behavioral VHDL constructs (after conversion) that Yosys keeps as black boxes will fail Verilator lint. Inspect Yosys warnings before passing to Verilator.

**3. Delayed assignments require `--timing`** — if the synthesized Verilog uses non-zero delays, add `--timing` flag (Verilator 5+).

---

## GTKWave CLI Reference

```bash
# Open waveform (GUI)
gtkwave out.ghw
gtkwave out.vcd
gtkwave out.fst

# Open with a saved signal layout
gtkwave out.ghw signals.gtkw

# Headless batch processing (for AI pipelines)
gtkwave --tcl_init batch.tcl --script batch.tcl --dump out.vcd --exit

# Batch: export signal list to stdout
gtkwave --tcl_init /dev/null --dump out.fst \
  --script <(echo "puts [gtkwave::getSignalList]; gtkwave::quit")

# Convert VCD to FST (much smaller, faster to load)
vcd2fst out.vcd out.fst

# Convert GHW to VCD (loses records/arrays but improves tool compat)
# Note: use ghwdump or Surfer's pywellen instead for lossless access
```

### ⚠️ GTKWave Gotchas

**1. VCD arrays are not displayed** — GTKWave cannot show VHDL array signals from VCD. Use GHW or FST from GHDL.

**2. GHW hierarchy root crashes** — Do not try to drag `standard`, `textio`, or other root-level IEEE package names into the signal view; GTKWave will crash.

**3. `-o` optimise flag re-encodes VCD to FST on load** — useful for large files but creates a spill file on disk. Use `--fastload` for repeated access to the same VCD.

---

## Surfer (CLI / pywellen)

Surfer has no traditional CLI for headless analysis, but its underlying `wellen` library does via Python:

```bash
pip install pywellen surfer-mcp  # optional MCP layer
```

```python
# headless_waves.py — AI agent friendly VCD/FST interrogation
import pywellen as pw

w = pw.Waveform("out.fst")  # or out.vcd, out.ghw (if wellen supports)

# List all signals
for sig in w.hierarchy():
    print(sig)

# Get transitions for a specific signal
for (time_ps, value) in w.signal_data("tb/dut/cpu_state"):
    print(f"{time_ps} ps  → {value}")

# Find first transition to a specific value
transitions = w.signal_data("tb/dut/valid")
first_high = next((t for t in transitions if t[1] == "1"), None)
print(f"valid first went HIGH at {first_high[0]} ps")
```

> ✅ `pywellen` returns times in **picoseconds** as integers — always divide by your expected time unit for human-readable output.
> ❌ GHW format support in wellen/pywellen is limited — convert to FST first for agent pipelines:
> `ghdl --elab-run --std=08 tb --fst=out.fst` (not `--wave=`)

---

## Quartus (MiSTer Build — Minimal CLI)

Only invoke Quartus when simulation passes. MiSTer uses **Quartus Prime Lite 17.0.2** (free tier).

```bash
# Compile from CLI (non-interactive)
quartus_sh --flow compile <project_name>

# Synthesis only (faster iteration)
quartus_map <project_name> --source=my_core.vhd

# Check timing report
quartus_sta <project_name> --do_report_timing

# Program device
quartus_pgm -c USB-Blaster -m JTAG -o "p;<project_name>.sof"
```

### Speed Tuning (`.qsf` settings)

```tcl
# Set in <project>.qsf — use physical core count, not logical (no HT)
set_global_assignment -name NUM_PARALLEL_PROCESSORS 8   # Ryzen 7: 8 physical
set_global_assignment -name OPTIMIZATION_MODE "Aggressive Compile Time"
set_global_assignment -name PHYSICAL_SYNTHESIS_EFFORT FAST
```

### ⚠️ Quartus Gotchas (MiSTer specific)

**1. Incremental compilation is NOT available in Lite** — Quartus Lite does not support block-based incremental compilation. Every build recompiles everything.

**2. MiSTer uses Quartus 17.0.2** — some newer VHDL-2008 features may need workarounds or backport to VHDL-93 syntax.

**3. `NUM_PARALLEL_PROCESSORS ALL` is slower than physical core count** — hyperthreads contend on memory bandwidth during Fitter. Set to physical core count.

**4. SignalTap adds ~5% area and requires recompile** — use it only for in-hardware debug after simulation passes. Remove before final MiSTer build.

---

## AI Agent: Suggested Debug Workflow

```bash
#!/bin/bash
# agent_sim_loop.sh — drop this in your core repo root

set -e
STD="--std=08 --ieee=standard"
TOP="tb_my_core"
STOP="--stop-time=5ms"

# Clean
rm -f work-obj*.cf *.o sim_out.fst

# Analyse (order matters: deps first)
ghdl -a $STD rtl/pkg_types.vhd rtl/my_core.vhd tb/tb_my_core.vhd

# Simulate → FST (pywellen/Surfer compatible)
ghdl --elab-run $STD $TOP $STOP --fst=sim_out.fst --ieee-asserts=disable-at-0
EXIT=$?

if [ $EXIT -ne 0 ]; then
  echo "SIMULATION FAILED (exit $EXIT)" >&2
  exit 1
fi

echo "Simulation OK — waveform: sim_out.fst"
# Agent can now parse sim_out.fst with pywellen or surfer-mcp
```

### Exit Code Interpretation

| Exit Code | Meaning |
|-----------|---------|
| `0` | Simulation completed normally |
| `1` | Assertion failure, constraint error, or runtime error |
| `2` | GHDL analysis/elaboration error (syntax, unresolved) |

Always check exit code before reading waveform — a failed simulation may produce a truncated or empty waveform file.

---

## Reference: VHDL IEEE Library Choice

| Library flag | Packages available | Recommended use |
|---|---|---|
| `--ieee=standard` | `ieee.std_logic_1164`, `ieee.numeric_std`, `ieee.math_real` | **Default — always prefer** |
| `--ieee=synopsys` | Above + `std_logic_arith`, `std_logic_unsigned`, `std_logic_signed` | Legacy MiSTer cores only |
| `--ieee=mentor` | Above + Mentor variants | Avoid |
| `--ieee=none` | Nothing | Test harnesses only |

> **Rule:** Migrate `std_logic_arith` / `std_logic_unsigned` to `ieee.numeric_std` where possible. Synopsys libs cause operator overload ambiguity that breaks GHDL analysis.

