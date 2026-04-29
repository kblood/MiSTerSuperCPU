# Session Passover — 2026-04-08e

## Subject

Wrapper-level GHDL bench for the LDA-long crash investigation. Promotes
the DUT from `P65C816` (bare core) to `cpu_65c816` (the C64 wrapper) and
re-runs the same four scenarios. **The wrapper is also bulletproof in
isolation** — same byte-level traces as the bare-core bench.

This is the next layer in the partition test described in
[`docs/session_passover_2026_04_08d.md`](./session_passover_2026_04_08d.md).

## What was built

`sim/p65c816_tb/cpu_65c816_lda_long_tb.vhd` — companion to the bare-core
bench. Same memory image, same four scenarios (`SC_BASELINE`, `SC_DROP_S3`,
`SC_DROP_S4`, `SC_CORRUPT_AB`), but the DUT is `cpu_65c816` instead of
`P65C816`. Trace lines are prefixed with `W:` to disambiguate from the
bare-core trace when both logs are inspected together.

`sim/p65c816_tb/run_tb.ps1` updated to analyze both benches, elaborate
both top-level entities, and run them sequentially. The wrapper bench
output goes to `work/lda_long_wrapper.log` and `work/lda_long_wrapper.ghw`.

### RTL touches required

- `C64_MiSTer/rtl/cpu_65c816.vhd` — added `dbg_state : out unsigned(3 downto 0)` to the entity port list, a `localSTATE` signal, and the corresponding port-map line + output assign. Mirrors the existing `dbg_pc`/`dbg_ir`/etc. ports exactly.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — added `dbg_state => open` to the existing named port map at `cpu_816_inst`. Zero behavioral impact.

Total production-RTL footprint of the entire investigation so far:
**4 lines added across 3 files**, all `DBG_STATE` plumbing, all `open` in
the production data path. No synthesis impact.

## How to run

```powershell
.\sim\p65c816_tb\run_tb.ps1
```

End-to-end runtime is about 10 seconds for both benches combined. The
script writes:

- `sim/p65c816_tb/work/lda_long.log`         — bare-core trace
- `sim/p65c816_tb/work/lda_long.ghw`         — bare-core waveform
- `sim/p65c816_tb/work/lda_long_wrapper.log` — wrapper trace
- `sim/p65c816_tb/work/lda_long_wrapper.ghw` — wrapper waveform

## Critical traces

### Wrapper baseline (`SC_BASELINE` on `cpu_65c816`)

```
cyc=20 STATE=1 IR=$AF PC=$0801 A_OUT=$000801 D_IN=$20 WE=0 VPA=1 VDA=0
cyc=21 STATE=2 IR=$AF PC=$0802 A_OUT=$000802 D_IN=$D0 WE=0 VPA=1 VDA=0
cyc=22 STATE=3 IR=$AF PC=$0803 A_OUT=$000803 D_IN=$00 WE=0 VPA=1 VDA=0
cyc=23 STATE=4 IR=$AF PC=$0804 A_OUT=$00D020 D_IN=$5A WE=0 VPA=0 VDA=1
cyc=24 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$EA WE=0 VPA=1 VDA=1
```

PC walk, state-4 address, data byte, next-opcode fetch — **byte-identical
to the bare-core baseline** at the same cycle offset. The only cosmetic
difference is `WE=0` (wrapper's active-high `we`) vs `WEn=1` (bare core's
active-low `WE`); both indicate "read."

### Wrapper bank-byte corruption (`SC_CORRUPT_AB` on `cpu_65c816`)

```
cyc=7748 STATE=1 IR=$AF PC=$0801 A_OUT=$000801 D_IN=$20 WE=0 VPA=1 VDA=0
cyc=7749 STATE=2 IR=$AF PC=$0802 A_OUT=$000802 D_IN=$D0 WE=0 VPA=1 VDA=0
cyc=7750 STATE=3 IR=$AF PC=$0803 A_OUT=$000803 D_IN=$FF WE=0 VPA=1 VDA=0   ; corruption fired
cyc=7751 STATE=4 IR=$AF PC=$0804 A_OUT=$FFD020 D_IN=$5A WE=0 VPA=0 VDA=1   ; AB became $FF
cyc=7752 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$EA WE=0 VPA=1 VDA=1   ; PC=$0804 — correct
```

Identical structure to the bare-core SC_CORRUPT_AB. PC ends correctly at
`$0804`, the next opcode fetch is normal, no BRK.

### Drop scenarios

`SC_DROP_S3` and `SC_DROP_S4` on the wrapper produce the same one-cycle
stall + clean resume as on the bare core. No need to reproduce the traces
in full — they match the bare-core ones at line-level precision.

## Why this rules out the wrapper

The wrapper's behavior under all four scenarios is identical to the bare
core's, byte for byte. Specifically:

1. **The `localDi <= localDo when localWe = '0'` write-loopback line** at `cpu_65c816.vhd:108` does not interfere with `$AF` execution because `$AF` is read-only — `localWe` is `'1'` throughout, so `localDi` always sources from the system `di`. SC_CORRUPT_AB drives `di` to `$FF` and the wrapper passes that straight through to the CPU's `D_IN`. Confirmed by the trace.
2. **The `accessIO` detect** at `cpu_65c816.vhd:107` only fires for `$0000-$0001` in bank `$00`. None of the addresses touched by the test program ($0800–$0807, $D020) match, so `accessIO='0'` throughout and the I/O port path is never engaged. Confirmed by the trace.
3. **The 6510 I/O port state machine** at `cpu_65c816.vhd:113-134` only updates `ioDir`/`ioData` when `accessIO='1'`. Idle for the entire test.
4. **The NMI ack edge detector** at `cpu_65c816.vhd:140-156` only fires on `localVPB='0'`. VPB is high throughout normal execution. Idle for the test.

So the wrapper, in isolation, is a transparent pipe for any test that doesn't touch `$0000`/`$0001`, doesn't write, and doesn't take an interrupt. **The LDA-long bug cannot live here either.**

## Cumulative eliminations after this session

| # | Hypothesis | Method | Status |
|---|-----------|--------|--------|
| 1 | Perplexity `io_in_pipeline` 2-vs-3 stage race | Code reading | ❌ Eliminated 2026-04-08d |
| 2 | `enableCpu_816` single-pulse starvation | `SC_DROP_S3/S4` on bare core | ❌ Eliminated 2026-04-08d |
| 3 | Single-byte wrong delivery on bank fetch | `SC_CORRUPT_AB` on bare core | ❌ Eliminated 2026-04-08d |
| 4 | Wrapper `localDi` mux interfering with $AF | `SC_BASELINE/DROP_S3/DROP_S4/CORRUPT_AB` on `cpu_65c816` | ❌ Eliminated 2026-04-08e |
| 5 | Wrapper `accessIO` glitch on $AF | Same — accessIO='0' throughout test | ❌ Eliminated 2026-04-08e |

## Where the bug must be (narrowed further)

The bug now MUST be in one of:

1. **A multi-cycle disturbance** — wrong `D_IN` for several consecutive fetches, or `RDY_IN` going low for many cycles in a way that causes the CPU to reissue a state, or a sustained ABORT/IRQ assertion.
2. **An out-of-band signal** that the bench doesn't currently exercise — `ABORT_N` (the 65C816's "reissue this instruction" pin), `IRQ_N` mid-instruction, `NMI_N` mid-instruction, or `RST_N` glitching.
3. **The `cpuDi` mux in `fpga64_sid_iec.vhd:854-875`** — this is where the BRAM/cache/SDRAM/IOF/scpu_rom_stub priority chain selects what byte the wrapper sees on `di`. The wrapper bench drives `di` from a clean combinational ROM model, which is NOT what the real system does.
4. **The system bus arbitration around the wrapper** — `cpu_cyc`, `cpu_cyc_s`, `enableCpu`, `bram_hit_d1`, `cache_hit_d1`, `phantom_enable`, and the cancel logic at `fpga64_sid_iec.vhd:2125-2131`. Even though single-pulse drops are benign on the bare CPU, the system might deliver an enable AND wrong data simultaneously in a way the bench hasn't replicated.

The cheapest next experiments, in order:

1. **Add `SC_CORRUPT_S3_MULTI`** — hold `D_IN <= $FF` not just for state 3 but for the entire window from end-of-state-2 through start-of-state-4. Tests whether sustained wrong data does anything different than a one-cycle blip.
2. **Add `SC_ABORT_S3`** — pulse `ABORT_N` low for one cycle while `IR=$AF AND STATE=3` on the bare core. The 65C816 reference says ABORT causes the current instruction to reissue from the start; that's exactly the kind of behavior that could land PC on the wrong byte if the reissue logic interacts badly with the bank fetch.
3. **Add `SC_IRQ_S3`** — assert `IRQ_N` low while `IR=$AF AND STATE=3`. IRQ should be queued until after the instruction completes, but if there's a microcode bug it might fire mid-instruction.
4. **Promote to a system-context bench**: instantiate `cpu_65c816` plus a *minimal stub* of the `cpuDi` mux (BRAM-hit path, SDRAM-pipeline path, scpu_rom_stub path) and the `enableCpu_816` generator. This is significantly more work but is the only way to test the BRAM/cache cancel interaction with `$AF`. Not justified yet — keep at it with the cheap experiments first.

## Files changed this session

```
C64_MiSTer/rtl/cpu_65c816.vhd                       (added dbg_state port + wiring)
C64_MiSTer/rtl/fpga64_sid_iec.vhd                   (added dbg_state => open)
sim/p65c816_tb/cpu_65c816_lda_long_tb.vhd           (NEW)
sim/p65c816_tb/run_tb.ps1                           (now runs both benches)
docs/session_passover_2026_04_08e.md                (THIS FILE)
```
