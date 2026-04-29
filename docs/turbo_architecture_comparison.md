# Turbo Architecture Comparison: MiSTer vs Real SuperCPU vs Ultimate 64

## Real SuperCPU (20 MHz)

```
┌──────────┐     ┌──────────────┐     ┌──────────┐
│ 65C816   │────▶│ 128KB SRAM   │     │ C64 DRAM │◀──── VIC-II reads
│ 20 MHz   │◀────│ (dedicated)  │     │ (64KB)   │      independently
└──────────┘     └──────┬───────┘     └─────▲────┘
                        │                    │
                 ┌──────▼───────┐     ┌─────┴────┐
                 │ 1-byte write │────▶│ Bus      │
                 │ buffer       │     │ interface│
                 └──────────────┘     └──────────┘
```

- CPU has its OWN 128KB SRAM. Never waits for SDRAM.
- VIC reads C64 DRAM on its own bus. ZERO contention.
- Writes mirror to C64 DRAM via 1-byte buffer during idle slots.
- I/O ($D000-$DFFF): CPU drops to 1MHz, accesses C64 bus directly.
- Speed: 20MHz sustained (SRAM = 0 wait states)

---

## Ultimate 64 (up to 48 MHz)

```
┌──────────┐     ┌──────────────┐     ┌──────────┐
│ 6510     │────▶│ Internal     │     │ FPGA     │
│ (FPGA)   │◀────│ block RAM    │     │ VIC-II   │
│ 1-48 MHz │     │ (64KB mirror)│     │          │
└──────────┘     └──────┬───────┘     └─────┬────┘
                        │                    │
                   ┌────▼────────────────────▼────┐
                   │   Dual-port BRAM (64KB)      │
                   │   CPU port: full speed        │
                   │   VIC port: 1MHz reads        │
                   └──────────────────────────────┘
```

- ALL 64KB of C64 RAM is in dual-port BRAM inside FPGA.
- CPU reads/writes at full speed on port A.
- VIC-II reads at 1MHz on port B. ZERO contention.
- No cache needed — entire RAM is "cached."
- I/O: directly connected inside FPGA (no bus to slow down).
- Speed: 48MHz sustained (BRAM = 0 wait states)
- Cost: ~32 M10K blocks for 64KB (Cyclone V has 553 total)
- The U64 uses a MUCH LARGER Artix-7 FPGA with more BRAM.

---

## MiSTer C64 Turbo (current: ~6 MHz)

```
┌──────────┐     ┌──────────────┐
│ T65 CPU  │────▶│ 8KB cache    │──miss──┐
│ (FPGA)   │◀─┬──│ (M10K BRAM)  │        │
│ 1-6 MHz  │  │  └──────────────┘        │
└──────────┘  │                           ▼
              │                    ┌──────────────┐     ┌──────────┐
              │                    │   SDRAM      │     │ FPGA     │
              └────────────────────│   (16MB)     │     │ VIC-II   │
                 enableCpu        │   shared!    │◀────│          │
                 (1 per 8 slots)  └──────────────┘     └──────────┘
```

### Bus Slot Allocation (32 slots per 1MHz period)

```
┌───────┬───────┬───────┬───────┬──────────────────────────────────┐
│EXT × 4│DMA × 4│EXT × 4│VIC × 4│           CPU × 16               │
│       │       │       │  VIC  │  SDRAM   SDRAM   SDRAM   SDRAM   │
│       │       │       │ reads │  slot0   slot1   slot2   slot3   │
└───────┴───────┴───────┴───────┴──────────────────────────────────┘
 ◀── cache hits here ──▶         ◀── SDRAM enables here ──▶
 (max 8, alternating              (max 4 with 4x turbo)
  hit/suppress)
```

### Bottlenecks

- **SDRAM contention**: CPU and VIC-II share the same SDRAM
- **1-cycle suppress**: M10K BRAM read latency halves cache throughput
- **Per-byte fill**: 1 byte per SDRAM read, 8 reads to fill a cache line
- **Suppress elimination won't fit**: all approaches cost +5000 ALMs (73%→85%)

### Performance

- Cache hit: 1 cycle (but 1-cycle suppress = 50% duty)
- SDRAM read: 3-cycle pipeline (cpu_cyc → s(0) → enableCpu)
- Fill: 1 byte per SDRAM read (8 reads to fill a line)
- Actual: 6.2 enables/rotation = ~6.2 MHz
- Theoretical max: 8 cache + 4 SDRAM = 12 MHz

---

## Comparison Table

|                    | Real SuperCPU    | Ultimate 64       | MiSTer C64          |
|--------------------|------------------|-------------------|---------------------|
| CPU memory         | 128KB dedicated SRAM | 64KB dual-port BRAM | 16MB shared SDRAM |
| VIC-II memory      | Separate C64 DRAM | Same BRAM, port B | Same SDRAM          |
| Contention         | None             | None              | **CPU vs VIC share SDRAM** |
| CPU read latency   | 0 (SRAM)         | 0 (BRAM)          | 0 (hit) or 3 (miss) |
| Write latency      | 0 + deferred mirror | 0 (VIC sees immediately) | 3 (must wait for slot) |
| FPGA               | N/A (discrete)   | Artix-7 (larger)  | Cyclone V (73% full) |
| Max speed          | 20 MHz           | 48 MHz            | ~6 MHz actual, 12 MHz theoretical |

---

## The Core Problem

Both the real SuperCPU and Ultimate 64 give the CPU its own dedicated memory
that doesn't compete with VIC-II. The MiSTer core has everything going through
one shared SDRAM. The 8KB cache tries to paper over this, but it can only serve
~35% of accesses due to slow per-byte filling.

---

## Potential Fix: 64KB Dual-Port BRAM (Ultimate 64 approach)

The Ultimate 64 approach (64KB dual-port BRAM) is the cleanest solution:
- Cost: ~32 M10K blocks (84% → ~90% RAM blocks). Might fit.
- CPU reads/writes BRAM at full speed, VIC reads same BRAM on separate port.
- No cache, no contention, no suppress penalty.
- Requires refactoring SDRAM data path in c64.sv and fpga64_buslogic_roms.vhd
  to redirect CPU RAM accesses to BRAM instead of SDRAM.
- Architecturally cleaner but a bigger refactor than the cache approach.
- SuperRAM (banks $01-$EF) would still use SDRAM — only bank $00 (64KB) in BRAM.
