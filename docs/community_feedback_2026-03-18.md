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
