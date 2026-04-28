# VICE PC-trace Diff Harness

Differential debugging tool: capture PC traces from VICE's `xscpu64` (the
SuperCPU emulator) and from our sim or hardware, compare line-by-line,
report the first divergent PC.

VICE is the oracle — its `xscpu64` runs Asterix (and more) to title screen
correctly, so any PC where our trace diverges from VICE's identifies
either a CPU-core bug, a system-integration bug, or a memory-hierarchy bug.

This is the highest-leverage debug technique we have once it's wired up:
turns 30-min Quartus iteration loops into 2-min sim diff loops with a
deterministic ground truth.

## Components

| File | Purpose | Status |
|---|---|---|
| `trace_format.md` | Wire format specification both sides must emit | DONE |
| `vice_diff.py` | Diff harness — reads two trace files, finds first divergence | DONE (validated end-to-end 2026-04-28) |
| `vice_capture_chis.py` | VICE side capture via -remotemonitor (text mode + `trace exec`) | DONE (200K-entry trace captured) |
| `vice_trace_asterix.cmd` | VICE monitor commands: break at $CB00, dump chis | LEGACY (replaced by `vice_capture_chis.py`) |
| `run_vice_trace.ps1` | PowerShell wrapper that runs `xscpu64 -moncommands ...` | LEGACY (replaced by Python capture) |
| `uart_to_trace.py` | Convert MiSTer UART log (TR: ring entries) to trace format | DONE |
| Bare-CPU GHDL bench | `sim/p65c816_tb/p65c816_asterix_full_tb.vhd` writes `ours_trace.txt` | DONE (500K entries captured) |
| System-level GHDL bench | `sim/c64_reduced_harness/c64_reduced_harness_tb_v2.vhd` writes `ours_system_trace.txt` | DONE (boot phase captured; needs asterix payload to reach $0852) |

## Validation (2026-04-28)

`vice_diff.py --pc-only --align tools/vice_diff/vice_trace.txt sim/p65c816_tb/work_asterix_full/ours_trace.txt`
matches all 200,000 lines of the VICE trace against our bare-CPU bench.
PC alignment requires `--align` (skip ours[1] for entry-point cycle skew),
which means our bare P65C816 implements Asterix's phase-2 decompressor
identically to VICE for the first 200K instructions. Any future
divergence will reflect either a CPU-microarchitecture bug or a
test-vector difference — not a wiring bug in the harness.

## Sources of "ours" trace

Three valid sources, in increasing system-integration coverage:

1. **Bare-CPU GHDL bench** (`sim/p65c816_tb/p65c816_asterix_full_tb.vhd`).
   Loads the Asterix PRG from a `.mem` file into a flat 64KB RAM and runs
   the bare P65C816 against a stubbed memory model (KERNAL = RTS, IRQ
   vector = RTI). Useful as a pure CPU correctness check vs VICE's CPU,
   but diverges quickly past PC=$E5A0 / $A659 because the KERNAL stubs
   don't do real work.
2. **Reduced harness** (`sim/c64_reduced_harness/`). Adds VIC, CIA, BRAM,
   cache. Closer to system-level. PC dumper not yet wired (would need to
   expose `dbg_pc_816`, `vpa_816`, `vda_816` from `fpga64_sid_iec`).
3. **Hardware UART** via `uart_to_trace.py`. Captures the 128-entry ring
   buffer when `bug_frozen=1`, formats as trace lines. Bandwidth-limited:
   ring is the only practical option (full-trace UART is infeasible at
   115200 baud).

## VICE-side capture (not yet end-to-end)

The trickiest part. VICE 3.9 monitor output (`chis`, `print`, etc.) goes
to the GUI window by default; with `+nativemonitor` -silent, the monitor
window appears separately and our `-logfile` only captures system errors.

Options to wire:
- `-nativemonitor` and capture stdout via PowerShell pipe (untested).
- `-binarymonitor` over TCP, drive from Python, step instructions and
  read PC/IR/P/SP each step. Slower but reliable.
- `-remotemonitor` (text monitor over TCP) and parse `chis` output.

The bare-CPU GHDL trace is independently useful (validates our CPU core
against an oracle representation we can construct manually for short
sequences), so VICE wiring isn't a hard blocker for the harness.

## Plan reference

See `docs/roadmap.md` Phase 0.2 for the full plan and exit criteria.
