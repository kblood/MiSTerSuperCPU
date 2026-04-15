# PRG Loading Debug Without Hardware

I dug through the RTL and existing simulation assets and found a pretty strong non-hardware explanation for why PRG loading breaks in the SuperCPU core while it worked in the plain C64 core.

## Short version

**Update after further investigation:** there is now a much stronger candidate for the immediate PRG-loading failure symptom.

The most likely root cause of the visible "PRG loads on vanilla but fails on SuperCPU" behavior is now:

- **stale 8KB cache fills during the PRG-load invalidation window**
- specifically, `cache_fill_we` was allowing cache fills while `bram_invalidate='1'`
- during ioctl PRG download + `inj_meminit`, CPU cold-start reads could fill the cache with **pre-write / stale bytes**
- those stale bytes then survived after the load completed and were executed/read back later

This theory is strongly supported by empirical testing:

- the PRG loads fine on vanilla
- it fails on the SuperCPU build
- a manual **`$D078` cache flush after load makes the PRG run**

A fix has been proposed/applied in `fpga64_sid_iec.vhd`:

- gate `cache_fill_we` with `and not bram_invalidate`

So the current working view is:

> The immediate PRG-loading failure is most likely a stale-cache-during-load bug. Separately, there may still be a deeper 65C816 native-mode / post-`REP` execution issue seen in simulation.

## What I checked

### 1. PRG injection path in `c64.sv`
Relevant code:
- `C64_MiSTer/c64.sv`
- PRG load logic around:
  - `wire load_prg = ioctl_index == 'h01 && !reu_by_ext;`
  - `if (ioctl_wr) begin if (load_prg) ...`
  - `inj_meminit` on falling edge of `ioctl_download`
  - `bram_inval_hold <= ioctl_download | inj_meminit;`
  - `io_bram_we_pulse` write-through into bank-$00 BRAM

### 2. BRAM/cache coherency path
Relevant code:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`
- `C64_MiSTer/rtl/cpu_cache.vhd`

This path has already had a lot of PRG-load fixes:
- io-cycle PRG writes also write through to bank-$00 BRAM
- BRAM valid/page-valid gets invalidated during download + meminit
- cache invalidation exists on writes
- bank-$00 PRG bytes should now land in both SDRAM and BRAM

So the raw “PRG bytes never actually got loaded” theory is much weaker than before.

## Strong evidence from prior docs

`docs/session_passover_2026_04_10.md` is especially important.

That session already established:

- `CLC/XCE` works when entered manually via `POKE` + `SYS`
- emulation-only PRGs loaded via mbc run fine
- **only** the `BASIC RUN -> mbc-injected code -> native switch` path crashes

That already narrowed it to:
- not generic PRG load failure
- not generic XCE failure
- something about the execution path after PRG load

## Updated simulation result: no reproduced wrapper/native-switch bug

I extended and ran the focused native-switch benches:

- `sim/p65c816_tb/p65c816_native_switch_tb.vhd`
- `sim/p65c816_tb/cpu_65c816_native_switch_tb.vhd`
- `sim/p65c816_tb/run_native_switch_only.ps1`

These benches were refined to:

- use small sparse memories instead of huge 16MB arrays
- stop quickly
- emit only a compact baseline trace plus per-scenario end-state summaries
- exercise the baseline path and CE-drop perturbation scenarios

The key baseline sequence is:

- `SEI`
- `CLC`
- `XCE`
- `REP #$30`
- `LDA #$1234`
- `JML $20:2000`

### Baseline result for bare `P65C816`

Observed in trace:

- `XCE` changes `EF` from `1` to `0`
- `REP #$30` changes `P` from `$35` to `$05`
- `LDA #$1234` consumes the expected 16-bit immediate width
- `JML` reaches `PBR=$20`, `PC=$2000`

Compact end-state summary:

- `final_P = $05`
- `final_EF = 0`
- `final_PBR = $20`
- `final_PC = $2001`

### Baseline result for wrapped `cpu_65c816`

Observed behavior matches the bare core.

Compact end-state summary:

- `final_P = $05`
- `final_E = 0`
- `final_PBR = $20`
- `final_PC = $2001`

### CE-drop scenarios

The benches also exercised these scenarios:

- drop on `XCE`
- drop immediately after `XCE`
- drop on `REP` operand fetch
- drop on first `LDA` operand fetch

For both bare core and wrapper, all encoded scenarios still converged to:

- native mode active
- `P = $05`
- `PBR = $20`
- `PC = $2000/$2001`

## What this means

This simulation work does **not** reproduce a second independent CPU/native-mode bug in the post-`XCE` / post-`REP` / `JML` path.

In particular:

- no wrapper-vs-bare divergence was observed
- no failure was reproduced in the focused native-switch path
- the CE-drop scenarios currently encoded in the benches also did not fail

So the earlier REP-bench concern should currently be treated as superseded by the more focused native-switch benches.

At this point, the simulation evidence does **not** support the idea that the immediate PRG-load symptom is being caused by a separate reproduced native-transition bug in `P65C816` or `cpu_65c816`.

## Specific likely bug classes

### A. 65C816 width/state bug after `REP/XCE`
Not currently reproduced by the focused native-switch benches.

The current simulation evidence says the tested sequence works correctly in both:

- bare `P65C816`
- wrapped `cpu_65c816`

So this is no longer the leading explanation for the immediate PRG-load symptom.

### B. Wrapper-level enable / fetch interaction
Also not reproduced by the focused native-switch benches.

The wrapper still deserves scrutiny in general, but the current benches do **not** show a wrapper-only failure in:

- native entry
- `REP #$30`
- 16-bit immediate handling
- `JML`
- encoded CE-drop perturbations

### C. BASIC RUN path still exposing stale/fetched bytes
This remains the strongest explanation for the immediate symptom.

Given:

- vanilla loads fine
- SuperCPU fails
- manual `$D078` flush after load makes the PRG run
- cache-fill gating during `bram_invalidate` directly addresses the stale-byte path
- focused CPU/native-switch benches do not reproduce an independent core/wrapper failure

the stale-cache explanation is now stronger than the CPU-mode theory for the immediate PRG-load failure.

## Less likely: raw ioctl PRG loader bug

I don’t think the first thing to blame is:
- `ioctl_index`
- load address parsing
- BASIC pointer meminit
- io-cycle write scheduling

Those all deserve validation, but they don’t explain why:
- emulation-mode PRGs work
- POKE/SYS works
- native-mode PRGs fail
- simulation shows REP-width inconsistency

## Best debugging plan without MiSTer or Quartus

The focused native-switch simulation work has now been done, and it did **not** reproduce a second independent CPU/wrapper bug.

So the highest-value next work without hardware is no longer more native-switch benching; it is keeping the cache-coherency diagnosis clearly separated from any future CPU work.

### 1. Preserve the focused native-switch benches as regression assets
Keep these benches available:

- `sim/p65c816_tb/p65c816_native_switch_tb.vhd`
- `sim/p65c816_tb/cpu_65c816_native_switch_tb.vhd`
- `sim/p65c816_tb/run_native_switch_only.ps1`

They now document that the tested post-`XCE` / post-`REP` / `JML` path works in both bare core and wrapper.

### 2. Treat the immediate PRG-load problem as a cache/invalidation issue first
Given current evidence, any remaining non-hardware reasoning should prioritize:

- cache fill behavior during `bram_invalidate`
- PRG load + `inj_meminit` interaction
- whether stale instruction bytes can survive into first execution after load

### 3. Only reopen CPU-native-mode investigation if a tighter reproducer appears
Future CPU-focused simulation should be reopened only if there is a new reproducer that:

- fails in simulation
- differs between bare core and wrapper
- or exercises a path not covered by the current focused native-switch benches

## Concrete files to focus on

### CPU wrapper
- `C64_MiSTer/rtl/cpu_65c816.vhd`

### Existing benches
- `sim/p65c816_tb/p65c816_lda_long_tb.vhd`
- `sim/p65c816_tb/cpu_65c816_lda_long_tb.vhd`
- `sim/p65c816_tb/p65c816_rep_tb.vhd`
- `sim/p65c816_tb/run_tb.ps1`

### Execution/cache integration
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`
- `C64_MiSTer/rtl/cpu_cache.vhd`

### Prior reasoning
- `docs/session_passover_2026_04_10.md`
- `docs/cache_crash_fix_report_2026-03-08.md`

## Current conclusion

Most likely diagnosis now splits into two parts:

### 1. Immediate PRG-loading failure symptom

Most likely root cause:

> The SuperCPU core was filling the 8KB cache during the `bram_invalidate` window of PRG load / `inj_meminit`, allowing stale pre-load bytes to survive and be executed after load.

Strong evidence:
- vanilla loads fine
- SuperCPU fails
- manual `$D078` flush after load makes the PRG run
- fix is to gate `cache_fill_we` with `not bram_invalidate`

### 2. Possible remaining deeper CPU/native-mode issue

Not currently reproduced by the focused native-switch benches.

Current status:

> A second independent post-`REP` / native-mode CPU bug was considered, but the newer focused bare-vs-wrapper native-switch benches did not reproduce it.

So for now, the practical PRG-load bug and the CPU-mode question should **not** be treated as equally likely explanations of the same symptom.

## Recommended next steps

1. **Verify the cache-fill fix on hardware/build results**
   - confirm PRGs like asterix now run without manual `$D078`
   - confirm no regressions in normal startup / cache behavior

2. **Keep the new native-switch benches as regression tests**
   - baseline and CE-drop scenarios now complete quickly
   - current result: no reproduced difference between bare `P65C816` and wrapped `cpu_65c816`

3. **Treat the stale-cache PRG failure as the primary explanation unless new contrary evidence appears**
   - PRG-load issue: likely cache coherency during invalidation window
   - current simulation: no reproduced second native-switch bug in the tested path
