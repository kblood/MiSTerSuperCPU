# Debug Infrastructure Modularization Plan

Status: MODULAR SPLIT IMPLEMENTED (2026-04-18) on branch
`feature/modular-debug-gates`. The single `DEBUG_ENABLE` gate from the
2026-04-15 pass has been split into four independent per-category gates so
specific debug toolkits can be enabled in isolation and the rest compile
out. The master toggle is retained for backwards compatibility.

## Macros (Verilog) / generics (VHDL)

Set any of the per-category macros in `C64.qsf` (via
`set_global_assignment -name VERILOG_MACRO "DBG_XXX=1"`) or via the
`build_c64.ps1` flags below. Any subset may be defined.

- `DBG_TRACE`       -- 128-entry crash trace ring buffer + bug_page view +
                       $DF20-$DFA0 / $DFC9-$DFE8 read mux + BRK/$0801 wipe
                       triggers. VHDL side: `DBG_TRACE` generic on
                       `fpga64_sid_iec` (`gen_trace_debug`).
- `DBG_UART`        -- `debug_uart_fmt` formatter + UART_TXD override.
- `DBG_OVERLAY`     -- Video debug overlay module.
- `DBG_BUS_CAPTURE` -- CIA1 / VIC / $0801 / screen-write / SuperRAM-read
                       capture processes + their diagnostic mux reads.
                       VHDL side: `DBG_BUS_CAPTURE` generic
                       (`gen_srr_debug`, `gen_cia1_dbg_debug`,
                       `gen_scr_debug`, `gen_0801_trap_debug`,
                       `gen_vic_debug`).

Master toggle `DEBUG_ENABLE` (set in the committed QSF by default): if
defined, implies ALL four sub-gates are defined. Release builds set
`DEBUG_RELEASE=1` (which suppresses the `ifndef`-default for
`DEBUG_ENABLE` in `c64.sv`) and leave every sub-gate undefined, so all
debug RTL compiles out.

`DBG_TRACE` and `DBG_BUS_CAPTURE` are also passed to `fpga64_sid_iec` as
integer generics via shadow localparams (`DBG_TRACE_PARAM` /
`DBG_BUS_CAPTURE_PARAM`) on the instance. Half-gated (SV macro on, VHDL
generic off, or vice versa) will dangle signal references -- keep the
two sides in sync.

## build_c64.ps1 flags

- `-Debug`            : full debug (all four categories on). Default.
- `-Release`          : emit `DEBUG_RELEASE=1`, all four off.
- `-DbgTrace` / `-NoDbgTrace`         : include / exclude DBG_TRACE.
- `-DbgUart`  / `-NoDbgUart`          : include / exclude DBG_UART.
- `-DbgOverlay` / `-NoDbgOverlay`     : include / exclude DBG_OVERLAY.
- `-DbgBusCapture` / `-NoDbgBusCapture` : include / exclude DBG_BUS_CAPTURE.

Narrow build: if any `-Dbg*` / `-NoDbg*` flag is given without `-Debug`
or `-Release`, the build starts from "nothing defined" and adds only the
requested categories. With `-Debug`, starts from all-on and
`-NoDbg*` subtracts.

Original `DEBUG_ENABLE` 2026-04-15 context (preserved below for
reference): expected payoff ~1,500-2,500 ALMs recovered, clk32 setup
slack returns from -0.865 ns back to comfortably positive (+0.5 to
+1 ns), same functional behavior for gameplay. The modular split lets
us validate each category's cost/benefit independently.

---

# Original single-toggle plan (2026-04-15, superseded by modular split)

Status: IMPLEMENTED (2026-04-15) -- pending merge from worktree
`.claude/worktrees/agent-aa69502c` (branch `worktree-agent-aa69502c`) and
Quartus `-Release` build validation. See "Implementation notes" at the
bottom of this file for what was actually wrapped and what wasn't.
Owner: subagent run 2026-04-15 (aa69502c).
Goal: Wrap all debug-only RTL behind a single `DEBUG_ENABLE` toggle so a
release build synthesizes it away. Expected payoff: ~1,500-2,500 ALMs
recovered, clk32 setup slack returns from -0.865 ns back to comfortably
positive (+0.5 to +1 ns), same functional behavior for gameplay.

## Motivation

As of 2026-04-15, the SuperCPU fitter reports 83% ALMs (34,780 / 41,910)
and clk32 setup slack -0.865 ns worst-corner. Analysis (see this session's
git log and the two subagent reports) attributes roughly half of the
~4,400-ALM growth since the 30,388-ALM baseline (2026-04-04) to debug
instrumentation accumulated during the Doom investigation — particularly
the 128-entry crash trace ring buffer (commit `2730f39`) whose wide read
mux sits on the critical path.

None of this instrumentation is needed for a release build. A compile-time
toggle lets us keep it for debugging sessions and compile it out for
timing-critical stress tests or a shipping core.

## What counts as "debug" (subject to gating)

All of the following are debug-only and should be wrapped:

### 1. Crash trace ring buffer (fpga64_sid_iec.vhd)

Signals (around lines 500–520):
- `bug_frozen`, `bug_armed`, `bug_timeout`, `bug_wp`
- `brk_detect_r`, `bram_inval_d`
- `trace_prev_pc`, `trace_prev_pbr`, `trace_prev_ir`, `trace_prev_p`
- `trace_entry_view` / `trace_p_view` arrays (128 entries × 32 bits)
- `trace_idx`, `trace_page_sel` (if present)

Process: the `bug_frozen` / ring-write process around lines ~1870–1970,
including the BRK-in-game-bank detect, the `$0801` wipe trigger, and the
PRG-load reset block added this session.

Read mux: the `$DF20-$DFA0` readout case statement in `c64.sv` (inside
`reu_reg_mux`) that selects the 128 trace entries — this is the single
widest mux in the design and the biggest critical-path contributor.

### 2. REU / SuperRAM diagnostic counters

In `c64.sv` `reu_reg_mux` (~lines 1040–1090):
- `$DFA1-$DFBF`: REU FETCH diagnostics (prod/cons counts, cmd fires,
  IOF edges, internal cs-we counters) from commit `fc61428` follow-ups
- `$DFE9-$DFEF`: SuperRAM round-trip diagnostic registers
- `$DFFC-$DFFD`: first-write address latches
- `$DFFE-$DFFF`: `dbg_inj_fall_cnt`, `dbg_strk_cnt`

Backing signals in fpga64_sid_iec.vhd / reu.v: the counter registers
themselves, plus their increment paths.

### 3. UART debug stream formatter

Module: `debug_uart_fmt.sv` (entire file). Instance + wiring in `c64.sv`.
Outputs the `A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx
N:xxxx W:xxxx L:xx[!/.]\n` line-per-frame diagnostic stream.

### 4. BRK-in-game-bank trigger

`brk_detect_r` register + transition path to `bug_frozen`. Fed from
`dbg_pbr_816` / `dbg_ir_816` which themselves come from the P65C816
debug ports — those may need defaults when gated out.

### 5. `$0801` wipe freeze trigger

Registered `dbg_0801_cnt_r` and its use in the `bug_frozen` set path.

### 6. `dbg_*` signal forwarding

`c64.sv` → `fpga64_sid_iec.vhd` → P65C816 / REU / cache. Dozens of
one-shot debug wires. Each needs a non-debug default (tie to `'0'` or
`(others => '0')`) when `DEBUG_ENABLE=0`.

## What is NOT debug (must keep)

Functional registers that happen to live in the `$DFxx` space:
- `$D078` cache flush (software-triggered, actual SuperCPU register
  repurposed from real-HW SIMM config)
- `$D079` / `$D07B` software turbo
- `$D07A` software 1 MHz
- `$D07D-$D07F` hwenable / register-enable gates

The overlay display (`overlay_en` and its character data) is user-facing
and should probably stay enabled independently, but the `dbg_*` values it
displays will need fallback defaults in release mode.

## Design approach

**Single shared toggle:** a boolean that propagates to both the VHDL and
Verilog/SystemVerilog halves.

**Mechanism:**
- VHDL: a top-level generic on `fpga64_sid_iec` — `DEBUG_ENABLE : boolean
  := true`. Used inside `if DEBUG_ENABLE generate` blocks around the
  trace-buffer signal declarations, process, and read mux. Signals
  declared outside the generate scope get default assignments via a
  second `if not DEBUG_ENABLE generate` block.
- Verilog/SV: a `` `define DEBUG_ENABLE`` set via Quartus QSF
  `set_global_assignment -name VERILOG_MACRO "DEBUG_ENABLE=1"`. The c64.sv
  mux cases, `debug_uart_fmt` instance, and `dbg_*` wire connections sit
  inside `` `ifdef DEBUG_ENABLE`` blocks.
- The VHDL generic default and the Verilog macro must match. The build
  script is the single source of truth.

**Why not just generics for everything:** `debug_uart_fmt.sv` is
SystemVerilog, and mixing VHDL generic passing across language boundaries
through Quartus hierarchy is brittle. A global QSF macro is simpler.

## Build script changes

`build_c64.ps1` gains two mutually exclusive flags:

```powershell
.\build_c64.ps1 -Release   # DEBUG_ENABLE=0
.\build_c64.ps1 -Debug     # DEBUG_ENABLE=1 (current behavior)
```

Default when neither is specified: `-Debug` (preserves current behavior
for existing workflows).

Implementation: before invoking Quartus, the script patches the QSF to
set the macro and the VHDL entity default. Two options:

1. Patch-in-place: regex-replace the `set_global_assignment -name
   VERILOG_MACRO "DEBUG_ENABLE=..."` line and a `DEBUG_ENABLE : boolean
   := ...` line in `fpga64_sid_iec.vhd`. Simple, but modifies tracked
   files during build.
2. Generate a sidecar `build_flags.qsf` that the main QSF `source`s, plus
   a `build_flags_pkg.vhd` that defines a constant. Cleaner, more files.

Preferred: option 1 for simplicity, with the patch atomically restored on
build exit (trap / try-finally).

## Step-by-step implementation (for the future subagent)

1. **Audit existing `dbg_*` signals** in `c64.sv`, `fpga64_sid_iec.vhd`,
   and any sub-module that exposes debug ports. Produce a list of every
   debug-only wire/port; classify each as "gate out" vs "functional
   register in DFxx that happens to be dbg-named".

2. **Add the top-level toggle:**
   - Add `DEBUG_ENABLE : boolean := true` generic to `fpga64_sid_iec` entity
   - Add ``\`define DEBUG_ENABLE`` wrapped via ``\`ifndef`` so QSF macro wins
   - Add QSF line: `set_global_assignment -name VERILOG_MACRO "DEBUG_ENABLE=1"`

3. **Wrap the trace ring buffer** (biggest ALM/slack win):
   - Move signal declarations for `bug_*`, `trace_*`, `brk_detect_r`,
     `bram_inval_d`, `trace_prev_*` inside `if DEBUG_ENABLE generate`
   - Move the `bug_frozen` process inside the same generate block
   - In `c64.sv`, wrap the `$DF20-$DFA0` mux cases in `` `ifdef
     DEBUG_ENABLE`` and return `$FF` in the `` `else`` branch

4. **Wrap REU diagnostic counters** ($DFA1-$DFBF, $DFE9-$DFEF, $DFFC-$DFFF):
   - Move counter declarations and increment paths inside the VHDL
     generate block (or keep declarations and just don't drive them —
     optimizer will remove unread registers)
   - Wrap mux case entries in the Verilog `` `ifdef``

5. **Wrap `debug_uart_fmt` instance** in `c64.sv`:
   - `` `ifdef DEBUG_ENABLE`` the instantiation
   - In `` `else``, tie the UART TX to whatever the non-debug path wants
     (likely: pass through the existing UART from the SuperCPU if any,
     otherwise tie high)

6. **Wrap BRK-in-game-bank trigger** and `$0801` wipe trigger inside
   the generate block.

7. **Audit overlay display** (`c64.sv` and overlay RTL) for references to
   `dbg_*` signals. Provide defaults for release mode so the overlay
   compiles (even if the values shown are meaningless — overlay itself
   may also be debug-only and could be gated).

8. **Extend `build_c64.ps1`:**
   - Add `-Release` / `-Debug` switch parameters (mutually exclusive)
   - Before Quartus invocation: patch QSF `DEBUG_ENABLE` macro value and
     VHDL generic default in `fpga64_sid_iec.vhd`
   - Use try/finally to restore the original content on exit (even on
     build failure or Ctrl-C)
   - Print which flavor is being built at the top of the build log

9. **Validate both builds:**
   - `.\build_c64.ps1 -Release` → should report ~30,500 ALMs, clk32
     slack > 0 ns, 0 errors. Deploy to MiSTer and verify C64 KERNAL
     boots, asterix MGL loads, a canonical SCPU game runs.
   - `.\build_c64.ps1 -Debug` → should be bit-identical to today's
     build. Deploy and verify UART trace stream still emits, crash
     freeze still captures on forced BRK.

10. **Document:** update `CLAUDE.md` "Build Commands" section with the
    new flags. Update `docs/supercpu_architecture_reference.md` with the
    debug gating design. Add a memory entry for future sessions.

## Risks and gotchas

- **Generate-scope signal leakage:** signals declared inside an
  `if generate` block are not visible outside it. Any signal referenced
  by non-gated code (e.g., a `dbg_*` routed to a UART mux that lives
  outside the generate) needs either a default assignment in the
  opposite branch or to be declared at the architecture level with
  conditional drivers. This is the main mechanical risk.

- **Trace buffer register files:** the 128-entry trace array may be
  implemented as distributed RAM or registers; when gated out the
  synthesizer will remove it, but any non-gated code that reads from
  it (e.g., an overlay debug display) will need a fallback.

- **`$D078` is functional, not debug:** the cache-flush register lives
  in the same address space as the debug registers. Be careful not to
  gate out the functional flush path when stripping the debug read mux.

- **Build-script patching is scary:** if the script crashes between
  patching and restoring, the user ends up with a modified tracked file.
  Use a try/finally with a hash check on exit, or prefer the sidecar
  file approach if the in-place patch feels risky.

- **QSF macro must match VHDL generic:** if they drift (e.g., user
  manually flips one in the QSF but not the other), you get half a
  gated build and cryptic errors. The build script should treat QSF
  as authoritative and derive the VHDL default from the same source.

## Validation checklist

Release build (`DEBUG_ENABLE=0`):
- [ ] 0 synthesis errors, 0 new warnings beyond baseline
- [ ] Total ALMs < 32,000 (aim: 30,500)
- [ ] clk32 setup slack > 0 ns worst corner
- [ ] C64 KERNAL boots to READY prompt
- [ ] Asterix MGL loads and runs
- [ ] `$D078` cache flush still works (test with a PRG that relies on it)
- [ ] `$D079/$D07B` turbo toggles still work

Debug build (`DEBUG_ENABLE=1`):
- [ ] Bit-identical or near-identical to current build
- [ ] UART debug stream emits the A/K/B/S/P/I/F/T/C/N/W/L line
- [ ] Crash trace ring buffer captures on forced BRK
- [ ] `$DF20-$DFA0` reads return trace entries
- [ ] REU diagnostic counters at `$DFA1-$DFBF` still increment
