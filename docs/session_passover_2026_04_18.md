# Session Passover 2026-04-18: Modular Debug Split + PRG Auto-RUN Fix Queued; Build-Time Regression Investigation Needed

## Headline

Two things landed on `master`:

1. **Modular debug-gate refactor** — single `DEBUG_ENABLE` split into
   `DBG_TRACE`, `DBG_UART`, `DBG_OVERLAY`, `DBG_BUS_CAPTURE`. Master toggle
   preserved for backwards-compat. `build_c64.ps1` has new `-Release` /
   `-Debug` / `-Dbg<Category>` / `-NoDbg<Category>` flags.
2. **PRG-vs-REU classification fix** (agent's proposed solution to
   PRG auto-RUN regression) cherry-picked onto master as commit `0bcfabe`.
   **UNVALIDATED** — no successful build yet.

**Open blocker:** fit time has ballooned from Apr 16's **10:02** to
**80+ min (killed, unfinished)** in the current attempt. Cause unknown.
Next session must get a `-Clean -Release` baseline before anything else.

## Commit / branch state

### master
Current HEAD: `0bcfabe WIP: latch PRG vs REU classification at first ioctl_wr`

Commits since Apr 16's working build (`C64.rbf` dated Apr 16 01:19):
- `edfb1d6` Shelve Verilator SuperCPU-fork harness; retain vanilla reference
- `9e9f14d` Point shelving notes at shelved/verilator-superfork branch
- `892b985` Add X-flag bank-transition GHDL bench; rules out CPU-level Doom bug
- `417845d` Add Doom launch harness v2-v5 + REU diagnostic peek
- `737b514` Split DEBUG_ENABLE into per-category gates
- `e29b64c` Extend build_c64.ps1 with per-category debug flags
- `4120224` Document modular debug gate split
- `0bcfabe` WIP: latch PRG vs REU classification at first ioctl_wr ← **tip**

### Branches
- `feature/modular-debug-gates` — source branch for the three debug-split
  commits (already merged, can be deleted after validation).
- `wip/prg-autorun-fix-partial` (`302707d`) — original commit of agent's
  classification fix; same content as `0bcfabe` on master. Safe to delete
  after the master version is validated.
- `shelved/verilator-superfork` — preserves the deleted Verilator harness
  (do not delete; revival criteria in `docs/verilator_desktop_harness_plan.md`).

## What the agent's PRG classification fix does

Agent `ad382d50` diagnosed the PRG auto-RUN regression as an HPS-protocol
race rather than timing. The hypothesis:

> `ioctl_file_ext` is not guaranteed settled at the rising edge of
> `ioctl_download`. The HPS sends `FIO_FILE_INFO` (extension) →
> `FIO_FILE_INDEX` → `FIO_FILE_TX_DAT` in sequence; if the comparator
> reads `ioctl_file_ext` one cycle too early, a PRG can get classified
> as `.REU` and get dropped (because `load_prg` would be 0 and `load_reu`
> also 0 because `ioctl_index` hasn't caught up either).

Fix (c64.sv, around line 530-575):
- New `reu_by_ext_latched` register.
- Captured at the **first `ioctl_wr` pulse** of a download — by then both
  INFO and INDEX have settled in the HPS protocol.
- Reset on the falling edge of `ioctl_download`.
- `wire reu_by_ext = reu_by_ext_latched;`
- Adds diagnostic counters (`dbg_any_dl_cnt`, `dbg_idx_at_dl`, etc.)
  which the agent intended to expose at `$DFC0-$DFC7` but whose mux
  reads I did not confirm were wired (registers exist; reads may not —
  synthesis will optimize unused ones out regardless).

**Rationale cross-check:** this matches the 2026-04-14 memory
`project_mgl_prg_loading_fixed.md` which said PRG bytes reach SDRAM but
auto-RUN's trigger logic was fragile. The agent's fix specifically
targets the classification gate; it does not touch auto-RUN trigger logic
itself. Possible the fix is necessary but not sufficient.

## The modular debug split (three commits)

### Macros (c64.sv header)

```verilog
// File-scope: define any subset from the QSF. Master toggle implies all.
`ifndef DEBUG_ENABLE
`ifndef DEBUG_RELEASE
`define DEBUG_ENABLE 1
`endif
`endif

`ifdef DEBUG_ENABLE
`ifndef DBG_TRACE       `define DBG_TRACE       1 `endif
`ifndef DBG_UART        `define DBG_UART        1 `endif
`ifndef DBG_OVERLAY     `define DBG_OVERLAY     1 `endif
`ifndef DBG_BUS_CAPTURE `define DBG_BUS_CAPTURE 1 `endif
`endif
```

### What each category gates

| Macro | Scope |
|---|---|
| `DBG_TRACE` | 128-entry crash trace ring buffer (`fpga64_sid_iec.vhd` `gen_trace_debug`), `bug_page` paged view mux, `$DF20-$DFA0` and `$DFC9-$DFE8` mux reads, BRK / `$0801` wipe trigger |
| `DBG_UART` | `debug_uart_fmt` formatter + UART_TXD override block |
| `DBG_OVERLAY` | `debug_overlay` video module |
| `DBG_BUS_CAPTURE` | `gen_srr_debug`, `gen_cia1_dbg_debug`, `gen_scr_debug`, `gen_0801_trap_debug`, `gen_vic_debug` (VHDL) + their mux reads in c64.sv (SRR, REU FETCH, PRG load, phase-align counters) |

### Passing macros into VHDL

Verilog-to-VHDL uses integer parameter shadowing (mixed-language Quartus
can't pass `boolean` generics from a `define`):

```verilog
`ifdef DBG_TRACE
localparam DBG_TRACE_PARAM = 1;
`else
localparam DBG_TRACE_PARAM = 0;
`endif
// ... same for DBG_BUS_CAPTURE

fpga64_sid_iec #(
    .DBG_TRACE       (DBG_TRACE_PARAM),
    .DBG_BUS_CAPTURE (DBG_BUS_CAPTURE_PARAM)
) fpga64 ( ... );
```

VHDL entity exposes `DBG_TRACE : integer := 1; DBG_BUS_CAPTURE : integer := 1;`
and all generate blocks use `if DBG_TRACE = 1 generate` / `if DBG_TRACE = 0 generate`.

The old single `DEBUG_ENABLE : boolean` generic on fpga64_sid_iec was
**removed** — the Verilog macro is now the single source of truth.

### build_c64.ps1 flags

```
.\build_c64.ps1 -Release                       # all gates off
.\build_c64.ps1 -Debug                         # all gates on (= today's default)
.\build_c64.ps1 -Release -DbgBusCapture        # only PRG/REU/SRR diagnostics
.\build_c64.ps1 -Release -DbgTrace -DbgUart    # X-flag hunt toolkit only
.\build_c64.ps1 -SyntaxOnly -Release           # quick 1:42 sanity
```

The script edits the QSF `VERILOG_MACRO` line in-place and restores it
on exit (success or failure). No longer patches the VHDL generic
default — that's no longer authoritative.

### Validation status
- `.\build_c64.ps1 -SyntaxOnly` (default `DEBUG_ENABLE=1`): PASSED 4m13s (per agent)
- `.\build_c64.ps1 -SyntaxOnly -Release`: PASSED **1m42s** ← proves all gates
  can turn off cleanly (no dangling signal references)
- Full build with gates off: NOT YET (this session killed at 80min fit)

## The build-time anomaly — needs root-cause investigation

| Build | Elapsed (fit only) | Status |
|---|---|---|
| Apr 16 (last known good, `DEBUG_ENABLE=1`, smart incremental) | **10:02** | ✓ produced rbf |
| Today agent's full-debug | 62 min | killed mid-fit by usage limit |
| Today `-Release -DbgBusCapture` (this session) | 80+ min | killed mid-fit, errored |

The map phase was also slow: 51 min vs Apr 16's typical ~2-3 min.
`map.summary` reported **559k total registers pre-optimization** (vs
Apr 16's post-fit 38,229). That suggests the fitter was fighting either:

- corrupted incremental state in `C64_MiSTer/db/` (likely — my refactor
  renamed most debug signal hierarchies, smart compile couldn't reuse),
- genuine timing closure difficulty from my refactor or the agent's
  PRG fix (less likely — `-Release` should have LOWER fit difficulty
  since debug is stripped),
- or SCC warnings in `fpga64|buslogic` forcing extra STA retry (these
  warnings exist in the Apr 16 fit.rpt too, so not new).

The SCC warnings pre-existed the refactor — a grep of the Apr 16
`C64.fit.rpt` shows `WSTA_SCC_NODE` entries. They are warnings, not
errors, and were not limiting Apr 16's 10-min fit.

## Immediate next step (DO THIS FIRST)

Run the from-scratch baseline. If THIS takes 50+ min, the issue isn't
debug bloat — it's something structural we need to investigate before
any further work:

```powershell
cd C:\LLM\C64\MiSTerSuperCPU
.\build_c64.ps1 -Clean -Release
```

Expected: **20–25 min total** if my theory (corrupted incremental state)
is right. Worst-case 60+ min if there's a genuine design issue.

After that completes:
- `scp output_files/C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf`
- Deploy and run a simple PRG auto-RUN test
- If auto-RUN works in `-Release` (no diagnostic regs), rebuild with
  `-Release -DbgBusCapture` and use the $DFxx counters to verify
- If auto-RUN doesn't work, fall back to `-Debug` build and use full
  trace to diagnose

## Secondary next steps (after validation)

1. **Doom via clean path.** Once PRG auto-RUN works, the MGL absolute-path
   Doom loader path should work: `doom.mgl` loads `doom.reu`, then
   `loader.prg` auto-RUNs, does REU→SuperRAM copy, jumps to bank $20.
   No more mtype or POKE/SYS gymnastics.

2. **Delete stale working-tree files.** 200+ PNG screenshots, many
   .prg test artifacts, many .log files from the past week's Doom
   hunt are cluttering `git status`. Worth a `.gitignore` sweep and
   an `rm -rf` of the obsolete ones. Not a priority.

3. **Measure the actual ALM/slack delta from the split.** With a
   clean `-Release` baseline and a clean `-Debug` rebuild, compare:
   - Total ALMs
   - clk32 worst-corner setup slack
   - clk64 worst-corner setup slack
   - Fit elapsed time
   
   Update `docs/debug_infrastructure_modular_plan.md` "Validation
   checklist" with actual numbers.

4. **Audit agent's new diagnostic counters.** The agent added
   `dbg_any_dl_cnt`, `dbg_idx_at_dl`, `dbg_ext_at_dl_hi/lo`,
   `dbg_classify_cnt`, `dbg_reu_by_ext_cap`, `dbg_idx_at_capture` in
   c64.sv but I haven't confirmed they got wired into `reu_reg_mux`
   for readback. If they're write-only registers (driven but not read),
   synthesis removes them — fine. If they're needed for validation,
   they should be wrapped in `\`ifdef DBG_BUS_CAPTURE` and have
   mux cases added.

## Do NOT re-investigate (resolved)

- **Verilator SuperCPU-fork harness.** Shelved on `shelved/verilator-superfork`.
  Do not rebuild without the revival criteria in `docs/verilator_desktop_harness_plan.md`.
- **X-flag flip as a CPU bug.** GHDL bench
  `sim/p65c816_tb/p65c816_xflag_bank_transition_tb.vhd` PASSES on bare CPU.
  Remaining X-flip candidates are system-side (cache, SuperRAM pipeline, bus
  arbiter, IRQ injection). See `project_xflag_bench_rules_out_cpu.md`.
- **SDRAM read path.** Not broken. See `project_sdram_read_path_not_broken.md`.
- **SCC warnings in `fpga64|buslogic`.** Pre-existing in Apr 16 fit.rpt.

## Files / artifacts to be aware of

- `C:\LLM\C64\MiSTerSuperCPU-debug-split` — the git worktree used for the
  modular-debug refactor. Branch `feature/modular-debug-gates` is already
  merged to master; the worktree can be removed with
  `git worktree remove ../MiSTerSuperCPU-debug-split`.
- `C64_MiSTer/db/` — stale incremental Quartus state from Apr 16. A
  `-Clean` build will wipe it.
- `C64_MiSTer/output_files/C64.rbf` — still the Apr 16 rbf. It's what
  `/media/fat/_Test/C64.rbf` on MiSTer currently corresponds to (modulo
  whatever got deployed manually during the Doom hunt).
