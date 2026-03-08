# MiSTer C64 Bus Architecture & SuperCPU Speed Scaling

## Purpose

This document describes the current bus architecture of the MiSTer C64 FPGA core,
explains how it limits CPU speed scaling, and presents the planned solution: a BRAM
cache that gives the CPU up to 32MHz effective speed (exceeding the real SuperCPU's
20MHz) while keeping all peripheral chips at correct 1MHz timing.

---

## 1. Current Clock and Bus Architecture

### 1.1 Clock Sources

The DE10-Nano provides a 50MHz reference clock. The PLL generates:
- **clk64** (~63MHz) — drives the SDRAM controller
- **clk_sys / clk32** (~32MHz) — drives the entire C64 core (all logic, all chips)
- **clk48** (~47MHz) — HDMI audio

Everything inside the C64 core runs on the single 32MHz clock domain.

### 1.2 The 32-Cycle Bus Arbitration State Machine

The core divides every 32 clock cycles into a rotating state machine
(`sysCycleDef` in `fpga64_sid_iec.vhd`). One full rotation = 32 clocks = 1 microsecond
= one C64 "phi2" cycle at 1MHz.

```
Slot:  EXT0 EXT1 EXT2 EXT3 | DMA0 DMA1 DMA2 DMA3 | EXT4 EXT5 EXT6 EXT7 | VIC0 VIC1 VIC2 VIC3 | CPU0 CPU1 CPU2 CPU3 | CPU4 CPU5 CPU6 CPU7 | CPU8 CPU9 CPUA CPUB | CPUC CPUD CPUE CPUF
Group: -------- EXT --------|-------- DMA ---------|-------- EXT ---------|-------- VIC ---------|----------------------------------- CPU --------------------------------------------------------|
Count:          8 slots              4 slots                (above)                4 slots                                         16 slots
```

### 1.3 Slot Allocation

| Slot Group | Count | Purpose |
|------------|-------|---------|
| **EXT** (0-3, 4-7) | 8 | Cartridge/REU SDRAM access, SDRAM refresh |
| **DMA** (0-3) | 4 | DMA transfers (REU) |
| **VIC** (0-3) | 4 | VIC-II character/bitmap/sprite fetches from SDRAM |
| **CPU** (0-F) | 16 | CPU execution — shared between RAM and I/O access |

### 1.4 How the CPU Gets Its Cycles (Current Turbo System)

At **1MHz** (no turbo), only **CPUC** (slot 28) fires as a CPU enable pulse. This is
the standard C64 phi2 cycle — one CPU clock per 32-slot rotation.

With the **turbo system**, additional CPU slots can fire:
- **CPU0** (slot 16): turbo slot 1, gated by `turbo_m(0)` AND `cs_ram` AND `cpuHasBus`
- **CPU4** (slot 20): turbo slot 2, gated by `turbo_m(1)` AND `cs_ram` AND `cpuHasBus`
- **CPU8** (slot 24): turbo slot 3, gated by `turbo_m(2)` AND `cs_ram` AND `cpuHasBus`
- **CPUC** (slot 28): always fires (1MHz base), handles both RAM and I/O

Turbo modes: 2x = one extra slot, 3x = two extra, 4x = all three extra slots.

**Critical constraints:**
- Turbo slots are gated on `cs_ram = '1'` — they can ONLY do RAM/SDRAM accesses
- I/O chip accesses ($D000-$DFFF: VIC, SID, CIA, color RAM) can ONLY happen at CPUC
- This means **I/O is always 1MHz**, regardless of turbo setting
- Maximum achievable: **4x = ~4MHz** (4 SDRAM accesses per microsecond)

### 1.5 SDRAM Bandwidth Limits

The SDRAM controller runs at 64MHz. Single-byte access, no burst mode.
Access latency: ~5 SDRAM clocks (~78ns). The SDRAM is shared between:
- VIC-II reads (1-4 slots depending on display mode and sprites)
- CPU reads/writes (1-4 slots depending on turbo)
- Cartridge/REU (EXT/DMA slots)
- Refresh (periodic, uses EXT slots)

At 4x turbo, the CPU uses all 4 available SDRAM CPU slots. There are no more
slots to give — the VIC, cartridge, and refresh need theirs. **This is the hard
ceiling of the current architecture: 4MHz max.**

---

## 2. How I/O Chip Access Works

### 2.1 The io_enable Mechanism

A signal called `io_enable` gates all I/O chip selects in `fpga64_buslogic.vhd`:
```vhdl
cs_vic   <= cs_vicLoc   and io_enable and scpu_io_en;
cs_sid   <= cs_sidLoc   and io_enable and scpu_io_en;
cs_cia1  <= cs_cia1Loc  and io_enable and scpu_io_en;
cs_cia2  <= cs_cia2Loc  and io_enable and scpu_io_en;
cs_color <= cs_colorLoc and io_enable and scpu_io_en;
```

`io_enable` is set to '1' at CYCLE_EXT0 (start of each rotation) and cleared when
`enableCpu` fires. This ensures each I/O chip gets exactly one access per phi2 cycle.

### 2.2 The io_enable Bug (Fixed)

When turbo is active, turbo slots (CPU0/CPU4/CPU8) fire for RAM accesses. Each fires
`enableCpu`, which clears `io_enable`. By the time CPUC arrives, `io_enable = '0'`.
If the CPU now needs to access I/O (e.g., CIA2 for IEC), the CPUC slot sees
`io_enable='0'` AND `cs_ram='0'` → `cpu_cyc='0'` → **I/O cycle silently dropped**.

**Fix applied:** Re-arm `io_enable = '1'` at CYCLE_CPUB (one slot before CPUC). The
last turbo `enableCpu` fires at CPUA (from CPU8's 2-clock pipeline), so CPUB is safe.

### 2.3 IEC Serial Bus (Disk Drives)

The IEC serial bus is bit-banged via CIA2 Port A ($DD00):
- Bit 3: ATN out, Bit 4: CLK out, Bit 5: DATA out
- Bits 6-7: CLK in, DATA in (active-low, open-drain)

IEC outputs are driven directly from CIA2: `iec_data_o <= not cia2_pao(5)`, etc.
IEC inputs are sampled once per rotation at CYCLE_EXT5.

**The IEC protocol is bit-banged by the KERNAL ROM.** The KERNAL uses carefully
calibrated timing loops (in RAM) between CIA2 accesses. These loops assume 1MHz.

---

## 3. The Speed Scaling Problem

### 3.1 What the Real CMD SuperCPU Does

The CMD SuperCPU (hardware cartridge, ~1997) achieves 20MHz by:

1. **Dedicated 128KB SRAM** for the CPU — independent of C64 DRAM
2. **VIC-II reads C64 DRAM independently** — zero CPU/VIC bus contention
3. **1-byte write buffer** — CPU writes drain to C64 DRAM during idle bus slots
4. **Automatic I/O slowdown** — access to $D000-$DFFF waits for next 1MHz phi2 edge
5. **BA monitoring** — watches VIC-II's Bus Available signal for badline coordination
6. **SuperCPU ROM** — replaces KERNAL with speed-aware IEC/tape routines

### 3.2 What Our FPGA Implementation Does (Before Cache)

We share a **single SDRAM** between CPU and VIC-II via the 32-slot state machine:

- **Maximum 4x speed** — only 4 of 32 slots can be CPU cycles
- **I/O always at 1MHz** — turbo slots are RAM-only, I/O at CPUC only (correct)
- **No dedicated CPU memory** — every CPU access competes with VIC for SDRAM
- **No SuperCPU ROM** — stock KERNAL with timing loops calibrated for 1MHz

### 3.3 Why Disk Access Breaks at Turbo Speed

Even with I/O accesses working correctly at 1MHz, the **time between I/O accesses**
is wrong:

```
1MHz (correct):    CIA_write --- 20 cycles of timing loop --- CIA_read
                   |<------------ 20 microseconds ------------>|

4x turbo (broken): CIA_write --- 20 cycles at 4x speed --- CIA_read
                   |<------------ 5 microseconds ----------->|
```

The KERNAL's timing loops between CIA2 accesses execute at turbo speed. The IEC
protocol's hold times are violated. Result: "device not present" error.

---

## 4. The Solution: BRAM CPU Cache

### 4.1 Key Insight

The CPU already runs on clk32 (32MHz) but is only enabled at specific slots via
`enableCpu`. Currently, `enableCpu` fires at most 4 times per microsecond (4MHz).

**If we add a BRAM cache, the CPU can be enabled on EVERY clk32 cycle for cached
RAM accesses — up to 32MHz = 32x the original speed.** I/O stays gated at 1MHz
via the existing CPUC mechanism.

The 65C816 is multi-cycle (LDA abs = 4 cycles). At 32MHz with cache:
4 × 31ns = 125ns per instruction = **~8 MIPS**. Real SuperCPU at 20MHz:
4 × 50ns = 200ns = ~5 MIPS. **32MHz with cache already exceeds real hardware.**

No clock changes needed. No PLL reconfiguration. No retiming of VIC/SID/CIA.

### 4.2 Architecture Overview

```
                    ┌─────────────────────────────────────────────┐
                    │              FPGA (32MHz clk32)             │
                    │                                             │
                    │  ┌──────┐    ┌──────────┐    ┌──────────┐  │
                    │  │ CPU  │◄──►│ BRAM     │    │ Write    │  │
                    │  │(T65/ │    │ Cache    │    │ Buffer   │  │
                    │  │P816) │    │ 8KB      │    │ 16-entry │  │
                    │  └──┬───┘    └────┬─────┘    └────┬─────┘  │
                    │     │             │               │         │
                    │     │ I/O path    │ Miss fill     │ Drain   │
                    │     ▼             ▼               ▼         │
                    │  ┌──────────────────────────────────────┐   │
                    │  │  32-Slot Bus Arbitration (unchanged) │   │
                    │  │  EXT|DMA|EXT|VIC|CPU0..CPUF          │   │
                    │  └──────────────┬───────────────────────┘   │
                    │                 │                            │
                    │  ┌──────┐   ┌───┴───┐   ┌──────┐           │
                    │  │VIC-II│   │ SDRAM │   │ CIA  │           │
                    │  │      │◄──│ Ctrl  │   │ SID  │           │
                    │  │      │   │ 64MHz │   │ etc  │           │
                    │  └──────┘   └───────┘   └──────┘           │
                    └─────────────────────────────────────────────┘
```

**Two paths for CPU data access:**
1. **Fast path (cache hit):** CPU reads/writes BRAM directly. No SDRAM needed. CPU
   enable fires every clk32 cycle. Up to 32MHz.
2. **Slow path (cache miss or I/O):** Falls back to existing 32-slot arbitration.
   CPU stalls until SDRAM fill completes (miss) or CPUC slot arrives (I/O).

### 4.3 Cache Design

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Size | 8KB | Fits in 10 M10K blocks (of 97 available) |
| Organization | Direct-mapped | Simple, sufficient for linear 6502/65816 code |
| Line size | 8 bytes | Balance between fill cost and spatial locality |
| Lines | 1024 | 8KB / 8 bytes per line |
| Tag bits | 11 | addr[23:13] (covers full 24-bit address space) |
| Write policy | Write-through | No dirty bits needed; write buffer handles SDRAM |
| Write allocation | Write-allocate | Correct for self-modifying code |
| I/O handling | Uncacheable | $D000-$DFFF in bank $00 always bypasses cache |

**Address mapping** (24-bit physical address):
```
[23 ........... 13] [12 ........... 3] [2 .. 0]
     11-bit tag       10-bit index     3-bit offset
                      (1024 lines)     (8 bytes/line)
```

### 4.4 CPU Enable: Fast Path vs Slow Path

Current `enableCpu` generation (in `fpga64_sid_iec.vhd`):
```vhdl
cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc;   -- 2-stage shift register
enableCpu <= cpu_cyc_s(1);              -- fires 2 clocks after cpu_cyc
```

New: add `enableCpu_fast` for cached accesses:
```
enableCpu_fast: fires EVERY clk32 cycle when:
  - Cache is enabled (turbo mode active)
  - Cache hit (data available in BRAM)
  - CPU is not stalled (no pending miss, write buffer not full)
  - Access is NOT to I/O region
  - DMA is not active

enableCpu_816/enableCpu_6510:
  = enableCpu_fast   when cache active AND not I/O access
  = existing slot-based enableCpu   otherwise
```

**I/O accesses always use the slow path** — the existing CPUC slot at 1MHz. This
guarantees VIC-II, SID, CIA, and color RAM see proper phi2 timing regardless of
CPU speed.

### 4.5 Write Buffer

When the CPU writes (cache hit):
1. Update cache data RAM immediately (CPU doesn't stall)
2. Push {addr, data} to 16-entry FIFO write buffer
3. Write buffer drains to SDRAM during idle bus slots

**Drain slots:** The CPU's freed-up SDRAM slots (CPU0/CPU4/CPU8 are no longer
needed for CPU reads — the cache serves those). Plus any unused EXT slots.

**Throughput:** 4 drain slots per microsecond. 65C816 at 32MHz produces ~5-16 writes
per microsecond (1 write per 2-6 instructions). The CPU stalls when the buffer is
near-full (>12 entries), creating natural back-pressure. Write-heavy code runs
slower — matching real hardware behavior.

### 4.6 Cache Line Fill (Miss Handling)

On cache miss:
1. CPU stalls (`cache_stall = '1'`, suppresses `enableCpu_fast`)
2. Fill controller requests 8 sequential bytes from SDRAM
3. Fill uses the CPU's own SDRAM slots (CPU0/CPU4/CPU8/CPUC when not doing I/O)
4. At 4 slots per microsecond, an 8-byte line fill takes ~2 microseconds
5. After fill: tag updated, valid bit set, CPU resumes from cache

**Miss penalty:** ~2 microseconds (64 clk32 cycles). At >90% hit rate (typical
for sequential 6502/65816 code), average impact is small.

### 4.7 VIC-II Coherency

VIC-II always reads SDRAM directly via its VIC0 slot — this is unchanged.

When CPU writes to bank $00 (C64 RAM visible to VIC), the write-through policy
ensures SDRAM gets updated via the write buffer. VIC may see stale data for a few
microseconds until the buffer drains. For screen updates this is invisible — VIC
scans at ~1MHz and the write buffer drains at 4 bytes/μs.

For raster effects: the CPU is at 1MHz during I/O access anyway (VIC register writes
go through CPUC), and screen RAM writes drain within one scanline.

### 4.8 Cache Invalidation

The cache must be flushed when external agents modify RAM:

| Trigger | Action | Frequency |
|---------|--------|-----------|
| DMA/REU transfer | Flush entire cache | Rare |
| Cartridge bank switch | Flush entire cache | Rare |
| OSD reset | Flush entire cache | Manual |
| Software trigger ($D078) | Flush entire cache | On demand |

Flush = clear all 1024 valid bits in one cycle (bulk reset on tag RAM).

---

## 5. Applicability to Both CPUs

This cache architecture benefits **both** the T65 (6510) and P65C816 (65C816):

| Feature | T65 (6510 mode) | P65C816 (SuperCPU mode) |
|---------|-----------------|-------------------------|
| Cache enabled by | OSD turbo setting | SuperCPU mode + $D07B |
| Address space | 16-bit (64KB, bank $00) | 24-bit (16MB, bank $00-$FF) |
| Max effective speed | 32MHz from cache | 32MHz from cache |
| I/O slowdown | Always 1MHz at CPUC | Always 1MHz at CPUC |
| IEC compatibility | Needs speed-aware KERNAL at >1MHz | Needs speed-aware KERNAL at >1MHz |

For the T65 in turbo mode, the cache replaces the current 4x turbo system with
a much faster cache-based system. The existing `turbo_mode` and `turbo_speed`
OSD settings would select: Off (1MHz, no cache), or On (cache-accelerated, up to 32MHz).

---

## 6. SuperCPU ROM / Speed-Aware KERNAL

### 6.1 The IEC Timing Problem

At any speed above 1MHz, the stock C64 KERNAL's IEC timing loops are too fast.
This breaks disk access regardless of whether I/O chips are properly accessed.
**This is a software problem, not a hardware problem.** The cache architecture
correctly handles chip access timing — it's the KERNAL code between I/O accesses
that runs too fast.

### 6.2 What the SuperCPU ROM Does

The real SuperCPU includes a ROM that overlays the C64 KERNAL at $E000-$FFFF:
- Replaces IEC serial routines with speed-aware versions
- Replaces tape routines
- Adds SuperCPU initialization code
- Drops to 1MHz ($D07A) before IEC transactions, restores speed ($D07B) after
- Provides KERNAL entry point compatibility (same vectors, different implementations)

### 6.3 Our Implementation Path

We already have `scpu_rom.mif` (64KB BRAM) for the SuperCPU kickstart ROM.
A speed-aware KERNAL could be:

1. **Loaded as a ROM option** — selectable via OSD alongside standard/JiffyDOS KERNALs
2. **Applied to both CPUs** — when T65 turbo is active, use the same speed-aware
   KERNAL. The patched IEC routines simply write $D07A (1MHz) before serial bus
   operations and $D07B (fast) after. This works for both CPUs.
3. **Based on the real SuperCPU ROM** — the SuperCPU ROM image exists in the wild
   (it was distributed with the hardware). Its IEC patches are well-documented.

This is independent of the cache hardware — it's a ROM image that writes speed
control registers ($D07A/$D07B) at the right moments.

---

## 7. FPGA Resource Budget

### 7.1 Available Resources

| Resource | Used | Total | Available | Cache Cost | After Cache |
|----------|------|-------|-----------|------------|-------------|
| M10K blocks | 456 | 553 | 97 (18%) | ~10 | 87 (16%) |
| Block memory bits | 3.54M | 5.66M | 2.12M (37%) | ~74K | 2.05M (36%) |
| ALMs | 25,527 | 41,910 | 16,383 (39%) | ~580 | 15,803 (38%) |
| PLLs | 3 | 6 | 3 | 0 | 3 |

The cache fits comfortably within available resources.

### 7.2 No Clock Change Needed

The 32MHz system clock is sufficient. At 32MHz with cache, the CPU exceeds real
SuperCPU performance. Changing to 64MHz would require retiming every module in
the design (VIC-II, SID, CIA, bus logic) — high risk, no benefit over cache approach.

### 7.3 Future: DDRAM for SuperRAM

The HPS DDR3 (DDRAM) is completely unused by this core. In the future, banks $01-$FF
(SuperRAM) could be moved from SDRAM to DDRAM, freeing SDRAM bandwidth entirely
for VIC-II and cache fills. This is a separate, later optimization.

---

## 8. Implementation Phases

### Phase 4A: Read-Only Cache (Prove Concept)
- New file: `rtl/cpu_cache.vhd` — 8KB direct-mapped, read-only
- Modify `fpga64_sid_iec.vhd` — add `enableCpu_fast` path
- CPU reads from cache at 32MHz, writes and I/O use existing slow path
- Test: C64 boots, runs programs faster, I/O chips work correctly

### Phase 4B: Write Support
- Add write-through with 16-entry write buffer
- Write buffer drains via freed CPU SDRAM slots
- Test: screen RAM writes visible, programs that modify code work

### Phase 4C: Cache Control and Invalidation
- Flush on DMA/REU, cartridge bank switch, reset
- Add $D078 software-triggered flush register
- Connect to $D07A/$D07B speed registers (cache disabled at 1MHz)
- Test: REU transfers, cartridge loading, speed switching

### Phase 4D: Both-CPU Support
- Enable cache for T65 turbo mode (OSD-controlled)
- Enable cache for P65C816 SuperCPU mode (software-controlled)
- Test: both CPUs benefit from cache acceleration

### Phase 5: Speed-Aware KERNAL ROM
- Create/adapt SuperCPU ROM with speed-aware IEC routines
- Make selectable via OSD for both CPU modes
- Test: disk access works at full turbo speed

---

## 9. Key Questions for External Research

1. **How do other MiSTer cores handle fast CPUs with slow peripherals?** (SNES runs
   65C816 at 3.58MHz, GBA at 16MHz, ao486 at various speeds — do any use BRAM cache?)

2. **What is the actual cache hit rate for typical C64/SuperCPU software?** 6502/65816
   code has small working sets and is highly sequential. Direct-mapped 8KB should
   give >90% hit rate, but what about DMA-heavy or self-modifying code?

3. **Can the SDRAM controller be modified for burst reads?** Currently single-byte.
   Burst-of-8 would fill a cache line in fewer SDRAM cycles, reducing miss penalty.

4. **What does the real SuperCPU ROM's IEC patch look like?** Does it simply
   bracket IEC operations with $D07A/$D07B writes, or is it more complex?

5. **DDRAM latency on MiSTer:** What is the practical access latency for HPS DDR3
   from FPGA fabric? Could it serve as SuperRAM with acceptable performance?
