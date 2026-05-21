# MiSTer C64 SuperCPU: Solutions for 20MHz Speed Scaling on DE10-Nano

## Executive Summary

The MiSTer C64 core's current 32-slot bus arbitration state machine limits CPU speed to 4× (approximately 4MHz), far short of the 20MHz target needed for authentic SuperCPU emulation. The fundamental constraints are: a single shared SDRAM between the CPU and VIC-II, I/O peripherals that must remain at 1MHz, and a stock KERNAL ROM with timing loops calibrated for 1MHz operation. This report evaluates eight architectural approaches to solving this problem, ranked by feasibility and impact within the DE10-Nano's Cyclone V FPGA resources.

***

## The Problem in Detail

### Current Architecture Limits

The core divides every microsecond into 32 clock slots (at 32MHz), allocating 16 slots to the CPU, 4 to VIC-II, 4 to DMA, and 8 to EXT/cartridge/refresh. At 1MHz, only slot CPUC (slot 28) fires. In turbo mode, up to 3 additional slots (CPU0, CPU4, CPU8) activate — but *only for RAM accesses*. I/O accesses are restricted to the CPUC slot, correctly implementing the SuperCPU's I/O slowdown behavior.[^1]

Even with the identified `io_enable` bug fixed (re-arming at CPUB), the *inter-access timing* between I/O operations is compressed at turbo speeds. The KERNAL's IEC serial timing loops execute at 4× speed, shrinking the required hold times from ~20μs to ~5μs, which breaks the bit-banged IEC protocol.[^1]

### What the Real SuperCPU Did

The original CMD SuperCPU solved this with dedicated hardware: 128KB of fast SRAM (64KB replacing C64 RAM, 64KB for shadowed ROM), a 1-byte write buffer for write-throughs, and a replacement KERNAL with speed-aware IEC routines. The CPU and VIC-II operated on completely independent memory buses with zero contention. JiffyDOS was built in, providing a serial bus protocol that eliminates the hand-shaking delays that break at high speeds.[^2][^3][^4][^1]

***

## Solution 1: BRAM Cache for CPU (Recommended — Highest Impact)

### Concept

Use the Cyclone V's on-chip M10K block RAM as a fast, zero-wait-state CPU cache, absorbing most CPU memory accesses without contending for SDRAM bandwidth. This mirrors how the real SuperCPU used dedicated 128KB SRAM to decouple the CPU from the C64's main DRAM bus.[^2]

### Available Resources

The DE10-Nano's Cyclone V SE 5CSEBA6U23I7 contains 110K logic elements. The Cyclone V SE A6 variant provides 553 M10K blocks totaling approximately 5,530 Kb (~691 KB) of block RAM, plus 994 MLAB blocks adding ~621 Kb. The C64 core currently uses roughly 57% of logic elements. A significant fraction of the BRAM should remain available — M10K blocks can operate at 100MHz or above with no issues.[^5][^6][^7][^8][^1]

### Implementation

An 8–32KB direct-mapped cache would capture the vast majority of CPU accesses. The 65C816's working set during typical operation (zero page, stack, program code) fits comfortably within this range. The MiSTer GBA core already demonstrates this approach: its cycle-accurate version places 256KB of WRAM in FPGA block RAM specifically to fulfill low-latency requirements. Similarly, the ao486 core achieved dramatic speed improvements by implementing L2 cache in BRAM, enabling CPU speeds up to 100MHz against SDRAM-backed main memory.[^9][^10][^11]

A practical implementation would:

- Allocate 16–32KB of M10K blocks as a direct-mapped or 2-way set-associative cache
- CPU reads hit the cache with single-cycle latency; misses go to SDRAM via the existing slot mechanism
- CPU writes use a write-through or write-back policy, with a small write buffer (like the real SuperCPU's 1-byte cache latch) draining to SDRAM during idle bus slots[^12]
- On cache miss, the CPU stalls for 1–2 SDRAM access cycles, but the hit rate for typical code should exceed 90%

### Trade-offs

- **Pro**: Minimal architectural disruption; the 32-slot state machine stays intact for VIC/DMA/EXT
- **Pro**: Well-proven pattern (ao486, GBA cores)
- **Con**: Adds BRAM consumption — need to verify how much the C64 core already uses
- **Con**: A cache does not guarantee deterministic 20MHz for every cycle; worst case (all misses) degrades to SDRAM-limited speed

***

## Solution 2: Increase the System Clock to 64MHz+

### Concept

Doubling the system clock from 32MHz to 64MHz would provide 64 slots per microsecond instead of 32. This could give the CPU 20+ slots while maintaining the VIC-II, SID, CIA, and other peripherals at their original 4-slot allocation (still representing 1MHz behavior).[^1]

### Implementation

- Regenerate PLL to produce 64MHz system clock and 128MHz SDRAM clock
- Expand `sysCycleDef` from 32 to 64 entries: keep VIC/DMA/EXT slots at the same positions relative to the phi2 cycle, fill the additional 32 slots with CPU slots
- Gate all peripheral chip enables to only assert on their original slots (every 64th cycle for 1MHz equivalence)
- The SDRAM controller would need to run at 128MHz; some MiSTer cores and SDRAM board tests have demonstrated the DE10-Nano's SDRAM operating reliably at 96MHz or above[^10]

### Trade-offs

- **Pro**: Straightforward conceptual extension of the existing architecture
- **Pro**: Could reach up to 20× CPU multiplier within a 64-slot rotation
- **Con**: All peripheral logic (VIC-II, SID, CIAs, color RAM) must be re-verified at the new clock — ensuring setup/hold times are still correct is non-trivial
- **Con**: 128MHz SDRAM is at the edge of what DE10-Nano PCB traces can support reliably, though some community members have achieved it[^10]
- **Con**: SID filter and CIA timer timing depends on clock cycle counting; incorrect gating could introduce subtle audio or timing artifacts

***

## Solution 3: SDRAM Bank Interleaving

### Concept

The IS42S16320D SDRAM on the DE10-Nano has 4 internal banks. Bank interleaving allows one bank to precharge/activate while another is being read, effectively pipelining CPU and VIC accesses to overlap rather than serialize.[^13][^14]

### Evidence from Other Cores

Testing by MiSTer community members showed that bank interleaving at 96MHz increased throughput from 48 MB/s to 126 MB/s — a 2.6× improvement. However, newer SDRAM modules with A12/A11 shorted to DMH/DML reduced this benefit to only 1.5×. A redesigned SDRAM controller could partition: assign banks 0–1 to CPU accesses and banks 2–3 to VIC-II/DMA, allowing concurrent access with minimal bank conflicts.[^10]

### Trade-offs

- **Pro**: Significant bandwidth increase without changing the system clock
- **Pro**: Could be combined with Solution 1 (cache) for multiplicative benefit
- **Con**: Requires a substantially rewritten SDRAM controller
- **Con**: Dependent on which SDRAM module revision the user has (A12/A11 issue)
- **Con**: Random access patterns still incur bank conflict penalties

***

## Solution 4: Dual SDRAM Configuration

### Concept

The DE10-Nano has two 40-pin GPIO headers, and MiSTer supports dual SDRAM modules. Dedicating one SDRAM module entirely to the CPU and the other to VIC-II/peripherals directly mirrors the real SuperCPU's architecture of separate CPU SRAM and C64 DRAM buses.[^15][^2]

### Implementation

- SDRAM 0 (GPIO 0): VIC-II reads, DMA, cartridge, refresh — exactly the current non-CPU slots
- SDRAM 1 (GPIO 1): CPU-exclusive, can run its own access pipeline with no contention
- The CPU SDRAM controller could use burst reads to prefetch instruction streams

### Trade-offs

- **Pro**: Cleanest architectural separation — zero bus contention, just like the real hardware
- **Pro**: No changes needed to the VIC-II, SID, or CIA timing
- **Con**: Requires the user to have a dual SDRAM setup, which also requires the Digital I/O board rather than Analog I/O[^15]
- **Con**: Very few existing cores use dual SDRAM, so the framework support may need work[^16]

***

## Solution 5: HPS DDR3 for CPU Memory

### Concept

The DE10-Nano includes 1GB of DDR3 SDRAM connected to the HPS (ARM) side. The ao486 core already uses this DDR3 as its main memory backing, achieving CPU speeds up to 100MHz with a BRAM L2 cache in front. The FPGA-to-SDRAM (F2S) bridge provides a direct path from FPGA fabric to HPS DDR3.[^17][^7][^8]

### Implementation

- Map the 65C816's 16MB address space into HPS DDR3 via the F2S bridge
- Use a BRAM cache (Solution 1) as L1 to absorb the higher latency of DDR3
- Reserve a portion of DDR3 using device tree modifications to prevent Linux from using it[^18]

### Trade-offs

- **Pro**: Massive memory bandwidth; no contention with VIC-II's SDRAM
- **Pro**: Proven approach in the ao486 core
- **Con**: DDR3 latency is higher than SDRAM — requires an effective cache layer
- **Con**: Adds complexity via the F2S bridge and clock domain crossing between FPGA and HPS
- **Con**: Integrating with MiSTer's framework (which handles DDR3 for some cores) requires careful coordination

***

## Solution 6: SuperCPU ROM / Speed-Aware KERNAL

### Concept

The real SuperCPU shipped with a replacement KERNAL ROM that contained speed-aware IEC routines, eliminating the timing loop problem entirely. JiffyDOS, which was built into every SuperCPU, rewrites the serial bus protocol to use burst-style block transfers that are inherently speed-independent. This achieved 6–10× faster disk transfers than stock on a 1541.[^3][^4][^2]

### Implementation

- Load a SuperCPU-compatible KERNAL ROM that contains JiffyDOS or equivalent speed-aware IEC routines
- The KERNAL image could be loaded via the existing OSD ROM loading mechanism (the C64 core already supports loadable KERNAL/drive ROMs)[^19]
- The replacement KERNAL would know the CPU is fast and adjust or eliminate timing-dependent loops accordingly

### Trade-offs

- **Pro**: Directly addresses the IEC timing problem at the software level, with zero FPGA resource cost
- **Pro**: The real SuperCPU did exactly this — the approach is historically validated
- **Con**: Requires sourcing or developing a SuperCPU-compatible KERNAL ROM
- **Con**: Does not solve the SDRAM bandwidth limit — only fixes the IEC protocol issue
- **Con**: Some software may rely on stock KERNAL timing for other purposes

***

## Solution 7: IEC-Aware Automatic Speed Switching

### Concept

Automatically drop the CPU to 1MHz whenever IEC bus activity is detected, then return to turbo when done. This extends the existing "Smart Turbo" mode, which already disables turbo briefly during disk operations.[^20][^19]

### Implementation

- Monitor writes to CIA2 Port A ($DD00 bits 3–5) for IEC signal transitions[^1]
- When IEC activity begins (ATN/CLK/DATA transitions), force turbo_m = "000" (1MHz mode) for the duration of the transfer
- Detect end-of-transfer via protocol state tracking or a timeout, then re-enable turbo
- Implement $D07A/$D07B software speed control registers so SuperCPU-aware software can explicitly manage speed[^1]

### Trade-offs

- **Pro**: Zero BRAM cost; entirely logic-based
- **Pro**: Compatible with stock KERNAL — no ROM replacement needed
- **Con**: Crude speed switching may introduce brief glitches during transitions
- **Con**: Does not help achieve 20MHz — only ensures IEC works at whatever turbo level is available
- **Con**: Some IEC timing loops span many instructions before/after CIA2 access; the switch needs to engage early enough

***

## Solution 8: Variable Slot Allocation

### Concept

Make the state machine dynamic, allocating more CPU slots when VIC-II doesn't need them. During vertical blanking (no character/bitmap/sprite fetches), the VIC-II needs zero bandwidth, and those slots could be given to the CPU.[^1]

### Implementation

- Monitor VIC-II's current scanline position and sprite enable bits
- During VBlank: reallocate all VIC slots to CPU → up to 20 CPU slots per μs
- During active display: prioritize VIC-II, with CPU getting the remainder
- During badlines: VIC-II takes maximum slots, CPU gets minimum

### Trade-offs

- **Pro**: Extracts maximum bandwidth from existing hardware
- **Pro**: No additional BRAM or memory hardware needed
- **Con**: CPU speed varies per scanline — creates non-deterministic behavior
- **Con**: Complex to implement correctly; VIC-II bandwidth needs vary within a single line (sprite fetches occur at specific positions)
- **Con**: Still limited to 32 total slots per μs — cannot exceed ~20 CPU accesses even in best case

***

## Solution Comparison

| Solution | Max Speed | BRAM Cost | Complexity | IEC Fix | Hardware Req. |
|----------|-----------|-----------|------------|---------|---------------|
| 1. BRAM Cache | ~10–20MHz effective | 16–32 KB | Medium | No (combine with 6/7) | None |
| 2. 64MHz System Clock | ~20MHz | Minimal | High | No (combine with 6/7) | None |
| 3. Bank Interleaving | ~8–10MHz | None | Medium-High | No (combine with 6/7) | SDRAM module dependent |
| 4. Dual SDRAM | ~20MHz | Minimal | Medium | No (combine with 6/7) | Dual SDRAM boards |
| 5. HPS DDR3 | ~20MHz+ | 16–32 KB (L1) | High | No (combine with 6/7) | None |
| 6. SuperCPU ROM | N/A (software) | None | Low | Yes | None |
| 7. IEC Speed Switch | N/A (logic) | None | Low-Medium | Yes | None |
| 8. Variable Slots | Up to ~20MHz peak | None | Medium | No (combine with 6/7) | None |

***

## Recommended Approach

The optimal path combines multiple solutions in phases:

### Phase 1: Fix IEC Timing (Quick Win)
Implement **Solution 7** (IEC-aware auto speed switching) alongside the existing `io_enable` fix. This ensures disk access works at the current 4× turbo without requiring a ROM replacement. In parallel, add **Solution 6** (loadable SuperCPU KERNAL) for users who want maximum IEC speed via JiffyDOS.

### Phase 2: BRAM Cache (Primary Speed Boost)
Implement **Solution 1** (BRAM cache). An 8–16KB direct-mapped cache would let the CPU run many cycles without touching SDRAM at all, dramatically increasing effective speed. This is the approach that transformed the ao486 core from barely running DOS to handling Windows 95, and that the GBA cycle-accurate core uses for its working RAM. The 65C816's tight code loops and small working sets make it an excellent cache candidate.[^11][^9]

### Phase 3: Expand Bandwidth (Full 20MHz)
To reach true 20MHz, combine the BRAM cache with either **Solution 2** (64MHz clock with expanded state machine) or **Solution 4** (dual SDRAM). The 64MHz clock approach keeps it as a single-board solution; dual SDRAM provides the cleanest separation but requires extra hardware. **Solution 3** (bank interleaving) can supplement either path for additional bandwidth margin.

***

## Open Questions

1. **BRAM budget**: How many M10K blocks does the current C64 core consume? The Cyclone V SE A6 has 553 M10K blocks — the remaining budget determines maximum cache size.[^5]
2. **SDRAM clock ceiling**: What is the maximum reliable SDRAM clock on the DE10-Nano with typical SDRAM modules? Community reports suggest 96MHz works; 128MHz needs testing.[^10]
3. **The `alynna` C128 SuperCPU fork**: An unofficial C128 core with partial 65816 support and SuperCPU register stubs exists. Its approach to timing and memory mapping could provide useful reference code.[^19]
4. **Cache coherence with VIC-II**: If the BRAM cache holds CPU data, writes to VIC-visible memory ($0400–$07FF screen RAM, bitmap areas) must still reach SDRAM promptly for display. A write-through policy for the $0000–$FFFF bank 0 range, combined with the existing CPUC slot, could handle this.

---

## References

1. [bus_architecture_and_speed_scaling.md](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/9390987/27dde07c-8c8a-4f94-9d05-a5c89c2fc947/bus_architecture_and_speed_scaling.md?AWSAccessKeyId=ASIA2F3EMEYERRNRUAMC&Signature=L7BsS96lSEs5rNg%2FhQZf9sxEOM8%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEEkaCXVzLWVhc3QtMSJIMEYCIQDS8NONlaSLWqIpdfZNFwjbLDFp%2BPrxtaCxVyFENSRKuQIhALPATd23wvzb8aAg5hdCcJrEO6d1W5pUmtrJ4dam%2Brn9KvMECBIQARoMNjk5NzUzMzA5NzA1IgwGmb17ORUMmGoMsyAq0ASYgCTNGOEcbc%2FhnvphfOjA9fydmu%2FrnvID6bMiOlmEj1jpWZTYqxHBErHIhFWt5HeOVcRxl5dTHJPBdWaFnWk92UNfrw0SXV6%2Fl57c5JpwUkx90FEaWRvtnUUeZKmWohF4d3g5oOckqXOO14gJgW2oplIzO87n%2FLsHp%2Fjs0%2F5fEXi2Ap%2BmZE6LZZun4ayEwqyE7j6IJmlOGwHmT24JpMiIRmsMUmul4zMMrMz8jQRIvq8mAemwzYQKzgX%2B5t8%2FgXrq5gJG22OW2yqEcvUnnZFXAO6GQKKNggzozmKcE8GBEDNok5PVQlYYwBsoe%2FzJDd1JKEh0f3irpNDQ0dK%2Fj1Tpmn1XAu%2B15v%2BYLsOVKT6azZHJd4Q8NBrXFr5n0uw6unk7ojeEj5A8tJhB7VgIKmjlHKnRiXjKUdkDEDkaQ%2FBx2d%2FX8dFscxY743ZC5z1ZqOMG%2B23U%2BgbNu%2FuASobGpaKzfCfCF3hC4gnpuYsPV1j7tWyesOExkmK26YlSgOjKmd2zg454E%2BqJB6QYdvBSxOWC%2BbqiuCeobVzymaaKQtknWmatfo22ppOOo%2BxS4tS1yVZippRE2%2FPxWhFNEgG0EjiwbR7HLaq8ilQzAgd3qtUc9pvWk%2BKstp801C%2FMjktqdrYY8k2wJ4wAtl77s3mQWXuJ5ZeJj%2Fx2Io%2F9t7oIKgJ0URjrzy4zrBdH0Fah5nIWEMkWg8fBxINOGoezp17k6BfrsgOYDLePAKzzvL7MddCrwL4GjaXkpQAikOsByZdTaOzbojD8pRpcz5gicPdeeASyMITktM0GOpcBODHOkRaPrNvIb6v%2BK2NNRuss69L3w%2FGLwtrMQXur1t3BOR%2BuGAHGbfP6j0yqqOMNiWi5oBkGkjdVB5kAANm1F%2FZGEHoET%2FvXf77lNVnzKNPfLh6KHxhydKq5E7abPnfsIp8Y3ck%2FvajLuZN9WfSprftetMxXGhZXlU%2F2Fn9Exec0EX5B2Hnzg8Phdy8WgNigSoDnM7vR8A%3D%3D&Expires=1772963989) - # MiSTer C64 Bus Architecture & SuperCPU Speed Scaling Problem

## Purpose

This document descri...

2. [SuperCPU General Specifications](http://elysium.filety.pl/tools/supercpu/superspec.html) - The SuperCPU is an accelerator module that plugs into the C64/128 Cartridge port. At its heart is th...

3. [SuperCPU - Wikipedia](https://en.wikipedia.org/wiki/SuperCPU)

4. [Command Reference](https://wiki.retrotechcollection.com/JiffyDOS_Kernal_Upgrade) - JiffyDOS is a drop-in firmware upgrade for Commodore 8-bit computers and their disk drives. By repla...

5. [Embedded Memory Capacity in Cyclone V Devices - Intel](https://www.intel.com/content/www/us/en/docs/programmable/683694/current/embedded-memory-capacity-in-cyclone.html)

6. [DE1-SoC FPGA memory examples ECE 5760 Cornell University](https://people.ece.cornell.edu/land/courses/ece5760/DE1_SOC/Memory/index.html) - NOTE: M10k and MLAB blocks require two cycles to read. BUT you can double the clock rate to the RAM ...

7. [DE10-Nano Kit - Semiconductor Business -Macnica](https://www.macnica.co.jp/en/business/semiconductor/articles/intel/2075/)

8. [DE10-Nano Development and Education Board - Terasic](https://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&CategoryNo=167&No=1046&PartNo=2) - 800MHz Dual-core ARM Cortex-A9 processor · 1GB DDR3 SDRAM (32-bit data bus) · 1 Gigabit Ethernet PHY...

9. [MiSTer FPGA - Testing an upcoming AO486 core that has CPU lvl2 cache support](https://www.youtube.com/watch?v=OeidZSiQvhA) - The core for running DOS and Windows 95-98 on the MiSTER is called the AO486 core, and it works quit...

10. [ao486 core and SDRAM performance - MiSTer FPGA Forum](https://misterfpga.org/viewtopic.php?t=1654) - The AO486 uses DDR3 and profits from the high burst speed, as all(performance critical) reads go thr...

11. [NEW Gameboy Advance CYCLE ACCURATE CORE is Here | Tested on 3 x MiSTer FPGA Systems](https://www.youtube.com/watch?v=OIKmYsutJE0) - Support the Channel
https://www.patreon.com/PixelCherryNinja

Join the Pixel Cherry Ninja Gaming Dis...

12. [[PDF] CMD SUPERCPU RAM EXPANSION & TIMING - Lyon Labs](https://www.lyonlabs.org/commodore/hardware/suprtime.pdf)

13. [9.4.4. Bank Interleaving](https://www.intel.com/content/www/us/en/docs/programmable/683663/24-1-19-1-2/bank-interleaving.html)

14. [11.2.4. Bank Interleaving](https://docs.altera.com/r/aigN1Vypic5yu3QMv5nT6w/G1AnjGsEwR995HI0DFSNBQ) - You can use bank interleaving to sustain bus efficiency when the controller misses a page, and that ...

15. [Install Dual SDRAM on MiSTer FPGA](https://misterfpga.co.uk/dual-sdram-mister-fpga/) - This quick setup guide will walk you through the process of configuring your MiSTer for dual RAM ope...

16. [What's the reason MiSTer is limited to 128MB RAM sticks?](https://www.reddit.com/r/fpgagaming/comments/q5q3nl/whats_the_reason_mister_is_limited_to_128mb_ram/) - What's the reason MiSTer is limited to 128MB RAM sticks?

17. [ao486 - Page 6 - Atari-Forum](https://www.atari-forum.com/viewtopic.php?t=33759&start=125) - Re: ao486 Performance Technical Discussion​​ This core does not use the SDRAM but the DDR ram on the...

18. [[Solved] Cyclone V (de10-nano) SDRAM controller](https://www.eevblog.com/forum/fpga/cyclone-v-(de10-nano)-sdram-controller-how-to-reserve-memory-for-fpga/?wap2)

19. [alynna/SuperCPU128DX_MiSTer - GitHub](https://github.com/alynna/SuperCPU128DX_MiSTer) - External ROMs can be loaded to replace the standard ROMs in OSD->Hardware. ROM 1/4: Expects a 16kB, ...

20. [Turbo speed - MiSTer FPGA Forum](https://misterfpga.org/viewtopic.php?t=2598) - Smart mode: In this mode any access to disk will disable turbo mode for short time enough to finish ...

