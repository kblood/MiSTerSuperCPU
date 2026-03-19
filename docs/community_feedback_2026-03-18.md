# Community Feedback — MiSTer SuperCPU Discord Discussion (2026-03-18)

## Summary

Discussion from the MiSTer FPGA community about the SuperCPU implementation,
with technical feedback on memory architecture, BRAM usage, and the real
SuperCPU's 128KB SRAM.

## Key Points

### 1. dentnz: Real SuperCPU RAM Architecture & Clock Domain Buffering

> "Most people have 128mb [sic, 128KB]... the muxing of the sdram itself
> shouldn't be too hard, it's the buffers required to get contents from the ram
> on the supercpu side to the c64 ram... that's probably how to deal with
> differences in clocks. I think you will find most super cpu software will
> require the standard 6510."

**Referenced code**: [c64.sv line 988](https://github.com/MiSTer-devel/C64_MiSTer/blob/master/c64.sv#L988)
— the SDRAM address mux:

```verilog
.addr( io_cycle ? (cart_mem_req ? cart_addr : io_cycle_addr )
              : ext_cycle ? reu_ram_addr : cart_addr ),
```

**Takeaway**: The real SuperCPU has 128KB of fast SRAM on-board that runs at
20MHz. The CPU reads/writes this SRAM at full speed. A separate write-through
buffer copies CPU writes down to the C64's 64KB DRAM at 1MHz so the VIC-II can
see them. The "optimization modes" ($D074-$D077) control which address ranges
get mirrored (write-through) to the slow C64 DRAM vs which are SCPU-private.

This is different from our current approach where both CPU and VIC share the
same SDRAM. Our cache/BRAM scheme approximates the fast SRAM (cache for
instruction fetch, BRAM for VIC reads of bank 0), but the fundamental
architecture differs.

The SDRAM address mux in the official C64 core shows how different bus masters
(CPU, cartridge, REU) time-share the single SDRAM port. Adding SuperCPU's
128KB fast path would need similar muxing for a second memory space.

### 2. birdybro (FPGA): M10K vs MLAB BRAM Types

> "There are two kinds of bram. M10K is larger in amount, but it's slower.
> MLAB is sparse, but a lot faster. M10K is better for big buffers, MLAB is
> better for shallower buffers that need to be fast and need true dual port
> behavior."

**Current usage**:
- M10K: 496/553 blocks (90%) — used for 32KB VIC BRAM, 8KB cache data, ROMs
- MLAB: used for cache tags (combinational read, 1 cycle)

**Takeaway**: birdybro confirms our architecture choice:
- Cache tags in MLAB = correct (fast combinational lookup)
- Cache data in M10K = correct (large buffer, registered read OK with 1-cycle latency)
- 32KB VIC BRAM in M10K = correct (big buffer for VIC reads)

However, at 90% M10K utilization we're near the limit. The 128KB fast SRAM
would require 1024 M10K blocks (1024 × 10Kbit = 10Mbit > our 5.6Mbit budget).
Even 64KB was too much (95% → fitter failure). Options:

1. **Keep current cache+BRAM approach** — approximates 128KB SRAM with 8KB cache + 32KB BRAM
2. **Use SDRAM for the 128KB** — dedicate a second SDRAM bank or time-slice differently
3. **Reduce M10K elsewhere** — remove some ROM BRAM to free blocks
4. **Wider cache lines** — 1024×64-bit M10K gives 8KB in fewer blocks with burst fill

### 2b. Follow-up: Detailed M10K/MLAB Specifications (birdybro, wickerwaka, semplar)

**birdybro** shared the Cyclone V memory block configuration table and reference:

| Memory Block | Depth (bits) | Programmable Width |
|---|---|---|
| **MLAB** | 32 | x16, x18, or x20 |
| | 256 (via LUT cascade) | — |
| **M10K** | 256 | x40 or x32 |
| | 512 | x20 or x16 |
| | 1K | x10 or x8 |
| | 2K | x5 or x4 |
| | 4K | x2 |
| | 8K | x1 |

Reference: [Cyclone V Embedded Memory Blocks](https://docs.altera.com/r/docs/683694/current/cyclone-v-device-overview/embedded-memory-blocks)

**Key insights from the discussion:**

**birdybro**: Quartus auto-places into MLAB if there's enough space and the
behavior is compatible. You can force placement via synthesis attributes
(`ramstyle = "MLAB"` or `"M10K"`). If it's incompatible or resources are
exhausted, Quartus warns and moves it elsewhere. Async reads force MLAB
(M10K can't do async reads). MLAB consumes logic space (ALM fabric).

**wickerwaka**: "Other way round, right? It'll use M10K if you access patterns
are compatible, it'll fall back to MLAB if you are doing stuff that M10K
can't do." — Clarifying that Quartus prefers M10K for compatible patterns
and falls back to MLAB for async/combinational read patterns.

**birdybro**: "I think MLAB is only *simple* dual port behavior. It's more
restrictive." MLAB supports simple dual-port (1 read + 1 write port).
M10K supports true dual-port (2 read/write ports).

**semplar**: Critical technical details:
> "Input signals to M10K are always registered. Because of this, reads from
> M10K have to be always at the beginning of a clock cycle. But reads from
> MLABs can happen anytime during a clock cycle (async reads), it's the
> advantage."
>
> "On other hand, M10K can do 2 writes in the same clock cycle, while MLAB
> is limited to a single write per cycle."
>
> "Also, there is 10x less MLAB space compared to M10K."

**semplar** also noted: "Fun fact on DE25, user manual says M20K can have
2 reads and 2 writes (4 total operations) in a single cycle" — referring
to the larger DE25-Nano FPGA (Cyclone V E variant with M20K blocks).

**Relevance to our implementation:**
- Our cache tags use `ramstyle = "MLAB, no_rw_check"` → correct, because
  tag_match needs combinational (async) read for same-cycle hit detection.
- Our cache data uses M10K (inferred from shared variable) → correct,
  because data read can tolerate 1-cycle registered latency.
- The 8 parallel 1024x8 M10K banks (wide cache lines) match the 1K depth
  x8 width configuration in the table above — one M10K block per bank.
- MLAB's async read is WHY we can do combinational tag check + cache_hit
  in the same cycle the address is presented.

### 3. kevind: 128KB Base Memory Question

> "The super cpu had a base memory of 128k.... Are you ignoring that and just
> going for the full 16mb expansion?"
>
> "I have to wonder if even the real thing was able to directly access the
> external simm at 20mhz"

**Answer**: The real SuperCPU has:
- **128KB fast SRAM** (on-board, runs at 20MHz) — this is the "base memory"
- **0-16MB SuperRAM SIMM** (expansion, accessed through bank registers)

The 128KB SRAM is split:
- First 64KB mirrors the C64's address space (bank $00)
- Second 64KB is bank $01 (SCPU-private, for relocated zero page, stack, etc.)

The SuperRAM SIMM (banks $02-$FF) was likely NOT accessed at full 20MHz — the
SIMM interface probably ran at a lower speed with wait states. The SCPU achieved
20MHz for code execution from the 128KB fast SRAM, with SIMM access being
slower (similar to how our SDRAM access is slower than cache/BRAM hits).

**Our current approach**:
- Bank $00 CPU reads: 8KB cache + 32KB BRAM (fast path, ~4MHz effective)
- Bank $00 VIC reads: 32KB BRAM port B (zero contention)
- Banks $01-$FF: SDRAM only (1 access per 32-clock rotation)

This is a reasonable approximation. The 128KB fast SRAM would give us more
coverage but the M10K budget doesn't allow it.

### 4. Other Notes

- **semplar**: "finally got my hands on DE25-Nano" — community member getting hardware
- **SHAMAN**: "wait till you try the ps2 core" — off-topic but shows active MiSTer community

## Action Items

1. **Document the 128KB SRAM architecture difference** in our architecture docs
   so contributors understand why our cache/BRAM approach exists.

2. **Investigate wider M10K cache lines** (1024×64-bit) — could improve cache
   hit rate and fill bandwidth without using more M10K blocks.

3. **Consider SDRAM banking for SuperRAM** — banks $02-$FF could map to SDRAM
   regions. The SDRAM is 32MB; the C64 uses only a fraction. Dedicate a region
   for SuperRAM banks.

4. **Keep optimization modes ($D074-$D077) as no-ops for now** — since we don't
   have the dual-memory architecture, all CPU writes go to SDRAM (which VIC
   reads). Mirroring is implicit. When/if we add 128KB fast SRAM, optimization
   modes would control write-through behavior.

5. **MLAB vs M10K awareness** — keep cache tags in MLAB, bulk storage in M10K.
   If we need more fast dual-port buffers, MLAB is the right choice (but scarce).
