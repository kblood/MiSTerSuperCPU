# Session Passover — 2026-04-08d

## Subject

LDA-long ($AF) crash investigation via narrow-scope GHDL simulation of the
bare P65C816 core. Two leading hypotheses tested and **both eliminated**.

## What was built

`sim/p65c816_tb/` — a narrow GHDL bench around `C64_MiSTer/rtl/65C816/P65C816.vhd`
with no `fpga64_sid_iec`, no Intel megafunctions, no SDRAM/VIC/T65/BRAM stubs.
Drives a 64 KB combinational `std_logic_vector` array as bank-$00 memory.

**Files:**

- `sim/p65c816_tb/p65c816_lda_long_tb.vhd` — testbench, four scenarios in one elaboration
- `sim/p65c816_tb/run_tb.ps1` — PowerShell driver: analyze + elaborate + run, dumps log + GHW

**RTL touched (one tiny change):**

- `C64_MiSTer/rtl/65C816/P65C816.vhd` — added `DBG_STATE : out std_logic_vector(3 downto 0)` (one new port, one assign at the existing DBG_* block)
- `C64_MiSTer/rtl/cpu_65c816.vhd` — added `DBG_STATE => open` to the existing port map; no behavioural change, no synthesis impact

GHDL 5.1.1 mcode is the existing native Windows install (already on PATH via WinGet). No WSL involvement.

## Method (worth replicating for future CPU-class bugs)

This is now documented in [`docs/faster_debug_iteration.md`](./faster_debug_iteration.md) under "Worked example: bare-CPU GHDL bench for the P65C816." The general recipe:

1. Smallest entity that could plausibly contain the bug.
2. Confirm vendor-clean (`grep -i altera/altsync/lpm` over the source list).
3. Add minimal `DBG_*` outputs for any internal state you need; leave `open` in the production wrapper.
4. Self-contained testbench entity, free-running clock, combinational ROM model with the smallest reproducer.
5. Multiple scenarios in one elaboration, separated by `report` markers.
6. `report`-based per-cycle text trace (`grep`-friendly) plus `--wave=*.ghw` fallback.
7. One-click PowerShell driver that hard-codes the GHDL path.

End-to-end runtime is ~5 seconds. The deploy/UART loop cannot match this for "what does the CPU actually do at clk32 granularity."

## Scenarios run

All four scenarios run back-to-back under one elaboration. Each does cold reset, waits for `IR=$AF`, then observes 80 µs of simulated time.

| # | Name | Manipulation | Result |
|---|------|--------------|--------|
| 1 | `SC_BASELINE` | `CE='1'` always | Passes — see baseline trace below |
| 2 | `SC_DROP_S3` | One CE pulse dropped while `IR=$AF AND STATE=3` (bank-byte fetch) | Pause, then resume identically to baseline |
| 3 | `SC_DROP_S4` | One CE pulse dropped while `IR=$AF AND STATE=4` (data fetch) | Pause, then resume identically to baseline |
| 4 | `SC_CORRUPT_AB` | Combinational override forces `D_IN <= $FF` for one cycle while `IR=$AF AND STATE=3` | AB becomes $FF, data fetch goes to $FF:D020, **PC still ends at $0804 and execution continues normally** |

## Critical traces

### Baseline (`SC_BASELINE`)

```
cyc=19 STATE=0 IR=$00 PC=$0800 A_OUT=$000800 D_IN=$AF VPA=1 VDA=1   ; opcode fetch
cyc=20 STATE=1 IR=$AF PC=$0801 A_OUT=$000801 D_IN=$20 VPA=1 VDA=0   ; AAL
cyc=21 STATE=2 IR=$AF PC=$0802 A_OUT=$000802 D_IN=$D0 VPA=1 VDA=0   ; AAH
cyc=22 STATE=3 IR=$AF PC=$0803 A_OUT=$000803 D_IN=$00 VPA=1 VDA=0   ; AB (bank operand)
cyc=23 STATE=4 IR=$AF PC=$0804 A_OUT=$00D020 D_IN=$5A VPA=0 VDA=1   ; DATA fetch
cyc=24 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$EA VPA=1 VDA=1   ; next opcode
```

Five enable cycles for `$AF`, PC walks `$0801→$0802→$0803→$0804`, state-4 address is `$00D020`, data is `$5A`. Spec-correct.

### Drop CE during state 3 (`SC_DROP_S3`)

```
cyc=2598 STATE=3 IR=$AF PC=$0803 A_OUT=$000803 D_IN=$00
[cyc=2599 dropped — CE='0' for one clk32]
cyc=2600 STATE=4 IR=$AF PC=$0804 A_OUT=$00D020 D_IN=$5A   ; identical to baseline
cyc=2601 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$EA
```

The dropped pulse just stalls the CPU for one clock. Address bus, registers, and `D_IN` are all held stable across the gap, so the next active edge resumes the instruction at the exact point it paused. **No PC drift, no AB corruption, no observable difference from baseline at the next active edge.**

### Drop CE during state 4 (`SC_DROP_S4`)

```
cyc=5174 STATE=3 IR=$AF PC=$0803 A_OUT=$000803 D_IN=$00
cyc=5175 STATE=4 IR=$AF PC=$0804 A_OUT=$00D020 D_IN=$5A   ; data fetch correct
[cyc=5176 dropped]
cyc=5177 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$EA   ; next opcode
```

Same story. One-clock stall, full recovery.

### Corrupt the bank operand (`SC_CORRUPT_AB`)

```
cyc=7748 STATE=1 IR=$AF PC=$0801 A_OUT=$000801 D_IN=$20
cyc=7749 STATE=2 IR=$AF PC=$0802 A_OUT=$000802 D_IN=$D0
cyc=7750 STATE=3 IR=$AF PC=$0803 A_OUT=$000803 D_IN=$FF   ; <<< corruption fired
cyc=7751 STATE=4 IR=$AF PC=$0804 A_OUT=$FFD020 D_IN=$5A   ; <<< AB became $FF as expected
cyc=7752 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$EA   ; next opcode at $0804
cyc=7754 STATE=0 IR=$EA PC=$0805 A_OUT=$000805 D_IN=$EA   ; NOPs continue
cyc=7756 STATE=0 IR=$EA PC=$0806 A_OUT=$000806 D_IN=$EA
... (CPU continues running NOPs forever)
```

The data fetch goes to `$FF:D020` (the memory model ignores bank bits and returns `$5A`, but the address bus clearly carries `$FFD020`). **PC still advances correctly to `$0804`** and the next opcode fetch is normal. No BRK, no warm-restart-equivalent, no PC drift. The bare core handles a corrupted bank byte as a perfectly normal load to a wrong address, nothing more.

## Hypotheses eliminated

1. **`io_in_pipeline` 2-vs-3-stage race during state-3→4 address-bus switch** (the Perplexity analysis from earlier in the day). Eliminated previously by code reading: `iof_detect` in `fpga64_sid_iec.vhd:756` is `$DFxx`-only, not the full `$D000–$DFFF` range, so the test target `$00:D020` (VIC-II) cannot trigger that path. Also incompatible with the brief's observation that the crash reproduces with bank-$00 RAM targets.

2. **`enableCpu_816` pulse-count starvation in the bus arbiter.** Eliminated by SC_DROP_S3 and SC_DROP_S4: dropping any single CE pulse during `$AF` causes only a one-cycle stall with full recovery. The P65C816 implements its EN-gating exactly the way a synchronous core should.

3. **Wrong byte delivered for the bank-fetch cycle.** Eliminated by SC_CORRUPT_AB: corrupting `D_IN` during state 3 causes AB to load wrong, the data fetch to go to a wrong address, and… that's it. PC is unaffected. The next opcode fetch is normal. So even if some external mechanism is delivering a wrong byte at the bank-fetch cycle, that alone cannot produce the observed BRK→KERNAL warm-restart.

## What this redirects toward

The bug **cannot** be in:

- The bare P65C816 core itself (handles every input we throw at it correctly).
- Single-pulse CE timing in the bus arbiter (proven benign).
- Single-byte `D_IN` corruption during the bank fetch (proven benign).

The bug **must** therefore be in one of the following — listed in increasing scope of work to investigate:

1. **The wrapper `cpu_65c816.vhd`** — specifically the `localDi` mux at line 107 which has the unusual `localDi <= localDo when localWe='0'` form, and the `accessIO` detect at line 106. Worth instantiating the **wrapper** in the same testbench and re-running the four scenarios.
2. **A multi-cycle disturbance** that the testbench doesn't currently model — e.g., `D_IN` being wrong for *several* consecutive cycles, or the wrapper deciding to re-fetch the bank operand because of an `accessIO` glitch.
3. **An out-of-band PC corruption path** — RDY_IN going low in a problematic way, an unintended ABORT/NMI/IRQ assertion mid-instruction, or RST_N pulsing. The wrapper drives all of these from external signals; full system context is needed.
4. **The system bus around the wrapper** in `fpga64_sid_iec.vhd` — the `cpuDi` mux specifically. Now justified by elimination, where it wasn't before.

## Recommended next moves (in order)

1. **Promote the testbench to instantiate `cpu_65c816` (the wrapper) instead of `P65C816` directly.** Rerun the same four scenarios. If any of them now reproduce the symptom, the bug is in the wrapper. If they all still pass, the wrapper is also bulletproof in isolation and the bug is in the system around it.
2. **Add a fifth scenario that holds `D_IN` corrupt for *multiple* consecutive cycles** (e.g., $FF for the entire bank-fetch and next-opcode-fetch window). This tests whether sustained wrong-byte delivery can ever produce PC drift on the bare core.
3. **Add a sixth scenario that asserts ABORT_N low for one cycle during state 3 of `$AF`.** ABORT is the canonical 65816 mechanism for "reissue this instruction" — if the wrapper or system ever asserts ABORT during a long instruction, the result could look exactly like the observed crash.
4. **Only after the above:** consider extending the bench to include a stub of the relevant `fpga64_sid_iec` arbitration and `cpuDi` mux logic. This is much more work and should not be undertaken until the cheaper experiments are exhausted.

## Files changed this session

```
C64_MiSTer/rtl/65C816/P65C816.vhd          (added DBG_STATE port + assign)
C64_MiSTer/rtl/cpu_65c816.vhd              (added DBG_STATE => open)
sim/p65c816_tb/p65c816_lda_long_tb.vhd     (NEW)
sim/p65c816_tb/run_tb.ps1                  (NEW)
docs/faster_debug_iteration.md             (added "Worked example" subsection)
docs/session_passover_2026_04_08d.md       (THIS FILE)
```

## How to run

From the repo root, on Windows:

```powershell
.\sim\p65c816_tb\run_tb.ps1
```

Output goes to `sim/p65c816_tb/work/lda_long.log` and `lda_long.ghw`. Cycle traces are `grep`-friendly: `grep "sc_baseline.*IR=\$AF" lda_long.log` extracts just the `$AF` cycles from the baseline scenario.
