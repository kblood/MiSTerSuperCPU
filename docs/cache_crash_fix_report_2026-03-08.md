# SuperCPU Cache Crash Findings and Fix Ideas

Date: 2026-03-08

Scope:
- Based on the current dirty tree while another agent is editing the RTL.
- No Quartus build was run.
- VHDL-only checks were done with `ghdl 5.1.1` and `nvc 1.19.2`.
- This report is based on the latest state where `C64_MiSTer/rtl/cpu_cache.vhd` has a `cpu_en` port and `C64_MiSTer/rtl/fpga64_sid_iec.vhd` uses the non-CPU-slot `cache_hit_d1` experiment.

## Tool-Backed Findings

1. `cpu_cache.vhd` only analyzes cleanly in `ghdl`/`nvc` with relaxed mode because the BRAM is modeled as a non-standard shared variable.
   - File: `C64_MiSTer/rtl/cpu_cache.vhd:87`
   - Both tools warn on `shared variable data_ram : data_array_t;`
   - This is not necessarily the runtime crash, but it makes simulator behavior less trustworthy and harder to debug.

2. A focused decode testbench passed in both `ghdl` and `nvc` and showed that:
   - bank `$00:$D000` is not cacheable
   - bank `$00:$E000` does become a cache hit after fill
   - a bank `$00:$E000` write with `cpu_en='1'` is treated as a write hit and enters the write buffer
   - Implication: the new address-only bank-0 decode now caches ROM-visible space and allows writes in that space to poison the cache.

3. A focused SuperRAM testbench passed in both `ghdl` and `nvc` and showed that:
   - a filled bank `$01:$2000` line becomes a read hit
   - a write to bank `$01:$2000` is not treated as a write hit
   - the same address still reports a read hit after that write
   - Implication: non-bank-0 writes do not invalidate or update cached SuperRAM lines, so stale reads are possible.

4. A broader fill/readback testbench failed in both `ghdl` and `nvc` when checking data readback after a fill.
   - The failure was on the expected post-fill data value, not on syntax.
   - This may be a pure simulation-model issue, a timing expectation error in the testbench, or a real cache pipeline problem.
   - Either way, the current cache model is not giving deterministic confidence in standalone simulation yet.

5. A focused scheduler-slice testbench modeled the current `cache_hit_d1` and `wb_drain_active` logic from `fpga64_sid_iec.vhd` and showed:
   - `8` `cache_hit_d1` pulses across the `16` non-CPU slots when `cache_hit='1'` continuously
   - `0` write-buffer drain opportunities across the full 32-slot rotation when `cpu_cyc` is asserted at `CPU0/CPU4/CPU8/CPUC`
   - Implication: the current experiment advances the CPU from cache during EXT/DMA/VIC time, but does not create any freed CPU-slot drain window for the write buffer.

## Current Likely Crash Causes

### 1. Bank-0 ROM/BASIC/KERNAL Space Is Now Cacheable

Relevant code:
- `C64_MiSTer/rtl/cpu_cache.vhd:143`
- `C64_MiSTer/rtl/cpu_cache.vhd:153`
- `C64_MiSTer/rtl/cpu_cache.vhd:170`
- `C64_MiSTer/rtl/fpga64_buslogic.vhd:398`
- `C64_MiSTer/rtl/fpga64_buslogic.vhd:402`
- `C64_MiSTer/rtl/fpga64_buslogic.vhd:440`
- `C64_MiSTer/rtl/fpga64_buslogic.vhd:446`

Why this matters:
- The old design used buslogic truth (`cs_io` / `cs_ram`) to decide cacheability.
- The current design uses pure address decode for bank `$00`, excluding only `$D000-$DFFF`.
- In the C64, bank-0 `$A000-$BFFF` and `$E000-$FFFF` are not always RAM on reads.
- `fpga64_buslogic.vhd` explicitly shows read-vs-write differences for BASIC and KERNAL areas:
  - KERNAL reads can go to ROM while writes go to RAM
  - BASIC reads can go to ROM while writes go to RAM
- The cache now ignores that distinction.

Crash risk:
- A read can fill the cache with ROM-visible data.
- A later write can update the cached line as if it were plain RAM.
- Subsequent reads can hit the cache even while ROM is still visible.
- That is enough to break boot flow, vectors, or KERNAL code/data assumptions.

Fix ideas:
- Immediate safe option: only cache bank-0 regions that are always RAM.
- Better option: pass an explicit `cacheable_bank0` signal from buslogic instead of reconstructing it locally.
- Do not allow write hits in bank-0 ROM-visible regions.

### 2. The `io_enable` CPUB Re-Arm Is Still Disabled

Relevant code:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1422`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1426`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1433`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1438`
- `docs/bus_architecture_and_speed_scaling.md:94`

Why this matters:
- The repo docs already describe the original bug: turbo-era CPU enables clear `io_enable` before `CPUC`, which drops the only I/O slot.
- The latest RTL still has the `CPUB` re-arm commented out.

Crash risk:
- Boot code that mixes RAM accesses and CIA/VIC/SID accesses can silently lose the I/O phase.
- That can look like random hangs or crashes even if the cache itself is mostly working.

Fix ideas:
- Re-enable the `CPUB` re-arm first.
- If that causes a separate boot issue, isolate that issue behind a narrower condition instead of disabling the global fix.

### 3. The Fast-Step Pulse and Write-Buffer Drain Pulse Are Still Coupled Incorrectly

Relevant code:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1091`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1097`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1101`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1401`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1404`
- `docs/cache_implementation_plan.md:269`
- `docs/cache_implementation_plan.md:274`

Why this matters:
- The original plan assumed the write buffer drains in freed CPU SDRAM slots.
- The current experiment generates `cache_hit_d1` only from non-CPU slots and also uses that same pulse to decide when a freed CPU slot exists.
- That is not the same event.
- The scheduler-slice testbench confirms the practical result: with cache hits continuously available, the current logic yields `8` fast-step pulses in non-CPU time and `0` write-buffer drain pulses in actual CPU slots.

Crash risk:
- The CPU fast-step path can move ahead while the drain logic never sees a valid overlap with a real drain slot.
- That can leave the design in a bad state under write-heavy code or during boot initialization.

Fix ideas:
- Split this into two signals:
  - `cpu_fast_step`: when the CPU is allowed to advance from cache
  - `cpu_slot_freed`: when a real SDRAM CPU slot is available for drain
- Do not reuse `cache_hit_d1` for both.
- If necessary, back down to read-only/invalidate-on-write until this is stable.

### 4. SuperRAM Writes Leave Valid Cached Lines Behind

Relevant code:
- `C64_MiSTer/rtl/cpu_cache.vhd:153`
- `C64_MiSTer/rtl/cpu_cache.vhd:170`
- `C64_MiSTer/rtl/cpu_cache.vhd:247`
- `C64_MiSTer/rtl/cpu_cache.vhd:275`

Why this matters:
- Banks `$01-$EF` are read-cacheable.
- Writes are still bank-0-only for the cache write path.
- The tests confirmed that a bank-1 line remains a read hit after a bank-1 write.

Crash risk:
- Native-mode code or data in SuperRAM can read stale cache lines after a write.
- That is enough to produce invalid code fetches or corrupted state.

Fix ideas:
- Minimum fix: invalidate the touched line on any non-bank-0 write.
- Better fix: support cache update on non-bank-0 writes without using the bank-0 write buffer.

### 5. T65 Mode Is Still Not Wired Cleanly Through the Cache

Relevant code:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1062`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1064`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1072`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1078`
- `C64_MiSTer/rtl/cpu_65c816.vhd:155`

Why this matters:
- The cache is enabled for `supercpu_en or turbo_en`.
- But `cpu_bank` and `fill_bank` still come from `addr_hi_816`.
- `cpu_en` is tied to `enableCpu_816`, not the active CPU.

Risk:
- T65 turbo mode depends on the inactive 65C816 bank output being benign.
- T65 cache writes are no longer explicitly described or controlled.
- This is probably not the current crash, but it is a latent integration bug.

Fix ideas:
- Make bank selection explicit:
  - bank `x"00"` for T65 mode
  - `addr_hi_816` for SuperCPU mode
- Make `cpu_en` come from the selected active CPU.
- If T65 writes are meant to bypass the cache, make that explicit rather than accidental.

### 6. The Current Simulation Model Is Good Enough to Find Decode Bugs, But Not Yet Good Enough to Trust Data Timing

Relevant code:
- `C64_MiSTer/rtl/cpu_cache.vhd:87`
- `C64_MiSTer/rtl/cpu_cache.vhd:195`
- `C64_MiSTer/rtl/cpu_cache.vhd:207`

Why this matters:
- `ghdl` and `nvc` agree on the decode/coherency findings.
- They also agree that the shared-variable BRAM model is non-standard.
- The simple post-fill readback test did not behave deterministically enough to trust as a full functional proof.

Fix ideas:
- Keep using `ghdl`/`nvc` for decode/coherency tests.
- For deeper cache-data timing tests, consider a simulation-only RAM model that uses standard signals instead of a shared variable.
- Do not trust a passing Quartus synth alone as proof that the cache micro-architecture is correct.

## Recommended Change Order

1. Restore the `CPUB` I/O re-arm so CPUC I/O is reliable again.
2. Remove the address-only bank-0 cacheability rule.
3. Back the cache down to read-only or invalidate-on-write until the core stops crashing.
4. Fix SuperRAM coherency by invalidating non-bank-0 lines on write.
5. Split fast CPU stepping from write-buffer drain scheduling.
6. Make the active CPU bank and `cpu_en` routing explicit for T65 vs 65C816.
7. Only then reintroduce full write-through acceleration and write-buffer draining.

## Practical Short-Term Strategy

If the goal is to stop the current crashes quickly, the safest near-term configuration is:
- read hits only
- no bank-0 ROM/BASIC/KERNAL caching
- invalidate-on-write instead of write-through acceleration
- CPUC-only I/O with the `CPUB` re-arm restored
- keep `$D07A/$D07B` speed control and `$D078` flush

That gives up some headline speed, but it removes the three highest-risk failure modes:
- ROM/RAM aliasing in bank 0
- dropped I/O slots
- stale SuperRAM lines after writes

## Commands Used

These were the relevant simulator checks:
- `ghdl -a --std=08 -frelaxed C64_MiSTer/rtl/cpu_cache.vhd`
- `nvc --std=2008 -a --relaxed C64_MiSTer/rtl/cpu_cache.vhd`
- custom temporary testbenches for:
  - bank-0 decode and write-queue behavior
  - SuperRAM stale-line behavior

No Quartus build was run.
