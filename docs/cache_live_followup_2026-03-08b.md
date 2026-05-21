# SuperCPU Cache Live-State Follow-Up

Date: 2026-03-08

Scope:
- Follow-up to `docs/cache_crash_fix_report_2026-03-08.md`
- No Quartus build
- No RTL edits
- Simulator-only checks with `ghdl 5.1.1` and `nvc 1.19.2`
- Source files were stable during this pass

Live-source hashes used for this note:
- `C64_MiSTer/rtl/cpu_cache.vhd`: `27440BB09570D5052265947B6ED932660E06B740378B7767146A864BDDC3391B`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`: `3D06C4B379463E3FCDF848156790A1BB3987F8B3106FA72B6E5EE18E00D5C371`

## Direction of the Live RTL

The code is moving in a more conservative direction:

1. `fpga64_sid_iec.vhd` now routes cache bank and `cpu_en` from the active CPU (`cache_cpu_bank`, `cache_cpu_en`).
2. Cache flush now includes C64 bank-register changes (`cache_flush_bank`).
3. Cache fills are suppressed during SCPU ROM overlay (`scpu_rom_overlay`).
4. The extra non-CPU-slot cache enable experiment is hard-disabled (`cache_hit_d1 <= '0'`).
5. Write-buffer drain is hard-disabled (`wb_drain_active <= '0'`).
6. `cpu_cache.vhd` now invalidates cached SuperRAM bytes on non-bank-`$00` writes.

That narrows the likely crash surface. If the core still crashes in this state, it is less likely to be caused by the earlier non-CPU-slot fast-step experiment and more likely to be caused by decode or bus-window mistakes that remain live.

## New Tool-Backed Results

### 1. SuperRAM invalidation fix now works

Current source:
- `C64_MiSTer/rtl/cpu_cache.vhd:183`
- `C64_MiSTer/rtl/cpu_cache.vhd:287`

Standalone testbench:
- `C:\Users\Caldor\AppData\Local\Temp\mister_supercpu_cache_tb\tb_cpu_cache_invalidate.vhd`

Result in both `ghdl` and `nvc`:
- a filled bank-`$01` line becomes a hit
- a bank-`$01` write clears the valid bit
- the same bank-`$01` address no longer hits after the write

Conclusion:
- the earlier stale-SuperRAM-line bug appears fixed in the current standalone cache implementation

### 2. Bank-`$00` ROM-space writes still enter the dead write buffer until it fills

Current source:
- `C64_MiSTer/rtl/cpu_cache.vhd:154`
- `C64_MiSTer/rtl/cpu_cache.vhd:171`
- `C64_MiSTer/rtl/cpu_cache.vhd:200`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1443`

Standalone testbench:
- `C:\Users\Caldor\AppData\Local\Temp\mister_supercpu_cache_tb\tb_cpu_cache_wb_limit.vhd`

Result in both `ghdl` and `nvc`:
- writes to bank `00:$E000-$E00F` are treated as write hits
- the first write is queued into the write buffer with address `$E000`
- the first `16` writes are absorbed
- the `17th` write no longer hits because the write buffer is full
- `wb_pending` remains asserted because drain is disabled at top level

Conclusion:
- the current live state still allows ROM-visible bank-`$00` writes to consume the write buffer even though top-level drain is intentionally disabled
- this is no longer the old drain-overlap bug; it is a simpler issue: a dead queue is still being fed

Why this matters:
- even if later writes fall back to the normal SDRAM path, the first `16` absorbed writes can still distort boot behavior if they occur in BASIC/KERNAL-visible areas
- with `cache_hit_d1` disabled, there is no offsetting fast-write benefit that justifies keeping this path on

### 3. The current `io_enable` logic still drops the CPUC I/O slot after a turbo RAM access

Current source:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1471`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1481`

Focused scheduler slice:
- `C:\Users\Caldor\AppData\Local\Temp\mister_supercpu_cache_tb\tb_io_enable_drop.vhd`

What the slice models:
- `io_enable <= io_enable and not enableCpu`
- `EXT0` re-arm
- no `CPUB` re-arm
- a RAM turbo access at `CPU8`
- an I/O access attempt at `CPUC`

Result in both `ghdl` and `nvc`:
- `EXT0` arms `io_enable`
- the `CPU8` RAM access produces `enableCpu` at `CPUA`
- `io_enable` is then cleared before `CPUC`
- the `CPUC` I/O slot does not fire when `cs_ram='0'`

Conclusion:
- the current live RTL still contains the dropped-I/O-window behavior that the project docs warned about
- this is still a live crash or hang suspect for boot, IEC, CIA, and VIC-adjacent code

## Current Likely Crash Sources

### 1. Bank-`$00` cacheability is still too broad

Current source:
- `C64_MiSTer/rtl/cpu_cache.vhd:154`

Problem:
- bank `00` is treated as cacheable for every address except `$D000-$DFFF`
- that still includes BASIC-visible and KERNAL-visible regions such as `$A000-$BFFF` and `$E000-$FFFF`
- `cache_flush_bank` helps after bank-register changes, but it does not make the initial fill itself correct

Best interpretation of the live design:
- the code is trying to solve the non-CPU-slot `cs_io/cs_ram` aliasing problem by moving to pure address decode
- that avoids one bad dependency on buslogic timing
- but it overshoots and makes ROM-visible bank-`$00` reads and writes look like RAM

### 2. The write buffer is effectively a dead queue, but write hits are still enabled

Current source:
- `C64_MiSTer/rtl/cpu_cache.vhd:171`
- `C64_MiSTer/rtl/cpu_cache.vhd:200`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1443`

Problem:
- `wb_drain_active` is permanently `0`
- `cacheable_wr` is still active for bank `00` writes
- `cache_hit` still reports those writes as hits

This is not a coherent steady-state design:
- either the write buffer should be active and drainable
- or bank-`$00` write hits should be turned off while the drain path is disabled

### 3. The `CPUB` I/O re-arm is still disabled

Current source:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1481`

Problem:
- the current logic still allows a turbo RAM access to clear `io_enable` before the only normal I/O slot at `CPUC`

The simulator slice shows this directly.

### 4. The cache model is still useful for decode tests, but still not trustworthy for deep timing proof

Current source:
- `C64_MiSTer/rtl/cpu_cache.vhd:87`

Problem:
- both `ghdl` and `nvc` still require relaxed mode because of the shared-variable RAM model
- that does not prove a hardware bug by itself
- it does mean standalone simulation should still be used mainly for decode/coherency/scheduling checks, not for high-confidence cycle proof

## Recommended Next Changes

Priority order:

1. Convert the cache to read-only or invalidate-on-write for now.
   - With `cache_hit_d1` and drain disabled, single-cycle write absorption is not buying enough to justify the risk.
   - Practical implementation: disable `cacheable_wr`, keep read hits, keep invalidation on writes.

2. Stop using pure address decode for bank-`$00` cacheability.
   - Best solution: derive an explicit bank-`$00` cacheable-read signal from buslogic, based on the real current read mapping.
   - If that is too invasive for the moment, use a temporary safe subset of bank-`$00` that is known RAM on reads and exclude BASIC/KERNAL-visible space.

3. Restore the `CPUB` re-arm or replace it with a structurally cleaner I/O-window signal.
   - Minimal fix: re-enable the `CPUB` re-arm.
   - Better fix: stop clearing the CPUC I/O window on turbo RAM enables in the first place. The current `io_enable` signal is trying to serve two unrelated roles.

4. Keep drain disabled until a real `cpu_slot_freed` signal exists.
   - The earlier `cache_hit_d1` experiment mixed up `cpu_fast_step` and `cpu_slot_freed`.
   - The current live code is already backing away from that. It should keep backing away until those are modeled separately.

5. Keep the new fixes that already move in the right direction.
   - active-CPU bank routing
   - active-CPU `cpu_en`
   - bank-switch flush
   - SCPU ROM overlay fill suppression
   - SuperRAM write invalidation

## Best Overall Short-Term Stabilization Plan

If the immediate goal is to stop the current crashes rather than preserve maximum benchmark speed, the most defensible short-term configuration is:

1. read hits only
2. invalidate on all writes
3. no bank-`$00` BASIC/KERNAL caching
4. drain left disabled
5. `CPUB` re-arm restored or the I/O window redesigned so turbo RAM slots cannot suppress CPUC I/O

That configuration matches the direction the live RTL is already moving, but removes the two highest remaining risks:
- ROM/RAM aliasing in bank `00`
- dropped CPUC I/O windows

## Suggested Next Investigations

1. Add a focused slice for the new `cache_flush_bank` logic to verify that it pulses exactly once per `cpuIO(2 downto 0)` transition and not on unrelated cycles.
2. Add a focused slice around `cache_fill_we` plus `scpu_rom_overlay` to prove that overlay mode blocks bad fills without suppressing normal RAM fills.
3. If the live RTL changes again, rerun:
   - `tb_cpu_cache_wb_limit.vhd`
   - `tb_io_enable_drop.vhd`
   - `tb_cpu_cache_invalidate.vhd`

