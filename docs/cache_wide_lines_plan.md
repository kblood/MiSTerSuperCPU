# Wide Cache Lines Implementation Plan (1024x64-bit)

## Summary
Change cache data RAM from 8192x8 to 1024x64-bit to eliminate the 1-cycle
suppress penalty for sequential byte accesses within the same 8-byte line.

## Current Bottleneck
- Each cache hit requires a 1-cycle suppress (M10K registered read latency)
- Pattern: HIT, suppress, HIT, suppress = 50% utilization
- 16 CPU slots per rotation, max 8 cache hits = ~8MHz effective
- Bottleneck is NOT cache size (8KB is enough for idle loop), it's suppress cycles

## Proposed Change
- Data RAM: 1024 lines x 64 bits (instead of 8192 x 8 bits)
- Same 8KB total, same M10K block count (~7-8 blocks)
- Add 3-bit byte-select MUX on 64-bit output
- Add "same-line" detection: if new address has same line_index as previous hit,
  skip suppress and select byte from stored 64-bit word

## Expected Performance
- Sequential code (instruction fetch): up to 16 hits per rotation (no suppress)
- Effective speed: ~16MHz for sequential access
- Random access: same as current (~8MHz, suppress still needed on line change)

## M10K Cost: ~0 (same 8KB, different organization)
- Cyclone V M10K max width at 1024 depth: 10 bits
- 1024x64 requires 7 blocks of 1024x10 in parallel (using 64 of 70 bits)
- Current 8192x8 uses ~8 blocks
- Net delta: approximately neutral

## ALM Cost: ~150
- 8:1 byte-select MUX on 64-bit word
- Same-line comparator (10-bit line index match)
- Previous-line register
- Fill buffer logic changes

## Implementation Steps

### Step 1: Modify cpu_cache.vhd
1. Change data_ram from 8192x8 to 1024x64 (use std_logic_vector(63 downto 0))
2. Write port: byte-addressed writes into the 64-bit word (use byte enables)
3. Read port: output full 64-bit word, add byte-select MUX
4. Fill: still byte-at-a-time from SDRAM, accumulate into correct byte lane

### Step 2: Add same-line detection in fpga64_sid_iec.vhd
1. Register previous cache hit's line_index
2. On next access, if line_index matches AND tag matches (same line, valid):
   - Assert cache_hit_d1 WITHOUT the 1-cycle suppress
   - Select byte from the already-read 64-bit word via addr[2:0]
3. If line_index differs: normal 1-cycle suppress for M10K read

### Step 3: Modify fill path
- Current: each SDRAM byte goes directly into data_ram at full address
- New: each SDRAM byte goes into a fill register, written to data_ram when
  complete (or use byte enables on the 64-bit write port)

## Risks
- Fitter pressure from wider data paths (64-bit routing)
- Byte-enable support varies by M10K configuration
- Fill logic complexity increases

## Future Enhancement: SDRAM Burst Mode
- Modify sdram.v to use burst-of-4 (4x16-bit = 8 bytes)
- Fill entire cache line in 1 SDRAM access instead of 8
- Reduces cold-miss penalty by 8x
- Independent of wide cache lines (can be done separately)
