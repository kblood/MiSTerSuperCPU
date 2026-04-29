# Turbo Cache Architecture Reference

## Bus Cycle Rotation (32 slots per 1MHz period)

```
Slot#  0    1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16   17   18   19   20   21   22   23   24   25   26   27   28   29   30   31
Name: EXT0 EXT1 EXT2 EXT3 DMA0 DMA1 DMA2 DMA3 EXT4 EXT5 EXT6 EXT7 VIC0 VIC1 VIC2 VIC3 CPU0 CPU1 CPU2 CPU3 CPU4 CPU5 CPU6 CPU7 CPU8 CPU9 CPUA CPUB CPUC CPUD CPUE CPUF
```

### SDRAM Usage with 4x Turbo (turbo_m = "111")

```
SDRAM:  ··   ··   ··   ··   ··   ··   ··   ··   ··   ··   ··   ··   VIC  (p)  (d)  ··   T0   (p)  (d)  ··   T1   (p)  (d)  ··   T2   (p)  (d)  ··   CPU  (p)  (d)  ··
                                                                     ↑                   ↑                   ↑                   ↑                   ↑
                                                                  c-access            turbo                turbo                turbo              normal
```
- `VIC`: VIC-II c-access read (character data)
- `T0/T1/T2`: Turbo SDRAM reads (cpu_cyc at CPU0/CPU4/CPU8)
- `CPU`: Normal CPU SDRAM read (cpu_cyc at CPUC)
- `(p)`: Pipeline stage (cpu_cyc_s(0))
- `(d)`: Data delivery (enableCpu fires)
- `··`: Idle — SDRAM unused

### Cache Hit Availability (4x Turbo)

```
Slot:  EXT0 EXT1 EXT2 EXT3 DMA0 DMA1 DMA2 DMA3 EXT4 EXT5 EXT6 EXT7 VIC0 VIC1 VIC2 VIC3 CPU0 CPU1 CPU2 CPU3 CPU4 CPU5 CPU6 CPU7 CPU8 CPU9 CPUA CPUB CPUC CPUD CPUE CPUF
Guard:  ok   ok   ok   ok   ok   ok   ok   ok   ok   ok   ok   ok   ok   ok   ok   ok   CYC  s(0) s(1) ENA  CYC  s(0) s(1) ENA  CYC  s(0) s(1) ENA  CYC  s(0) s(1) ENA
ch_d1:  HIT  sup  HIT  sup  HIT  sup  HIT  sup  HIT  sup  HIT  sup  HIT  sup  HIT  sup   ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─
```
- `HIT`: cache_hit_d1 can fire (if cache_hit='1')
- `sup`: 1-cycle suppress (M10K BRAM read latency)
- `─`: Blocked by SDRAM pipeline guard (cpu_cyc_s or enableCpu)

**Max per rotation: 8 cache hits + 4 SDRAM enables = 12 enables = ~12 MHz**

### With Suppression Elimination (Dual-BRAM Lookahead)

```
ch_d1:  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT  HIT   ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─    ─
```
- Consecutive cache hits for sequential code (same line, bytes valid)
- Falls back to suppress on line boundary crossing (byte_offset = 7)

**Max per rotation: 16 cache hits + 4 SDRAM enables = 20 enables = ~20 MHz**

---

## Data Flow Diagram

```
                    ┌──────────────────────────────┐
                    │         SDRAM (16MB)          │
                    │  Bank $00: C64 RAM (64KB)     │
                    │  Banks $01-$EF: SuperRAM      │
                    └──────────┬───────────────────-┘
                               │ ramDin (8-bit)
                    ┌──────────▼───────────────────┐
                    │   cartridge.v (passthrough)    │
                    └──────────┬───────────────────-┘
                               │ c64_data_in
              ┌────────────────▼────────────────────────┐
              │      fpga64_buslogic_roms.vhd           │
              │  ┌─────────┐  ┌─────────┐  ┌────────┐  │
              │  │  KERNAL │  │  BASIC  │  │  CHAR  │  │
              │  │  BRAM   │  │  BRAM   │  │  BRAM  │  │
              │  └────┬────┘  └────┬────┘  └───┬────┘  │
              │       └────────┬───┘───────────┘        │
              │           ┌────▼─────┐                  │
              │           │ ROM/RAM  │  ← cpuIO(2:0)   │
              │           │   MUX    │    banking ctrl  │
              │           └────┬─────┘                  │
              │                │ dataToCpu              │
              └────────────────┼────────────────────────┘
                               │ cpuDi_raw
              ┌────────────────▼────────────────────────┐
              │         fpga64_sid_iec.vhd              │
              │                                         │
              │   cpuDi priority MUX:                   │
              │     1. cache_di (when cache_hit_d1)     │
              │     2. SuperCPU registers ($D07x,$D0Bx) │
              │     3. cpuDi_raw (SDRAM/ROM/I/O)        │
              │                                         │
              │   ┌──────────────┐    ┌──────────────┐  │
              │   │  cpu_cache   │    │   T65 CPU    │  │
              │   │  (8KB M10K)  │    │  or P65C816  │  │
              │   │              │    │              │  │
              │   │ Fill: cpuDi  │    │ enable ←─────│──│── enableCpu_6510
              │   │   (buslogic  │    │        (cache_hit_d1 AND turbo_en)
              │   │    output)   │    │         OR (enableCpu AND NOT dma)
              │   │              │    │              │  │
              │   │ Hit: cache_di├───→│ di ← cpuDi  │  │
              │   └──────────────┘    └──────────────┘  │
              └─────────────────────────────────────────┘
```

### Why ROM Prefetch from SDRAM Fails

```
CPU reads $E000 (KERNAL ROM enabled):
  SDRAM addr $E000 → returns C64 RAM data (stale/wrong)
  buslogic intercepts → substitutes KERNAL BRAM data ✓

Prefetch reads $E001 during EXT slot:
  SDRAM addr $E001 → returns C64 RAM data (wrong!)
  buslogic NOT consulted (cpuHasBus='0', buslogic processes VIC addr)
  Cache fills with RAM data instead of ROM data ✗
```

**Safe prefetch regions** (SDRAM = correct data, no ROM overlay):
- Bank $00: $0000-$9FFF (always RAM)
- Banks $01-$EF: all addresses (SuperRAM)

**Unsafe** (ROM in BRAM, not SDRAM):
- Bank $00: $A000-$BFFF (BASIC ROM), $E000-$FFFF (KERNAL ROM)

---

## Cache Hit Rate Analysis

### Why 35% Non-CPU Hit Rate

During non-CPU slots, CPU address is **static** (last address from CPU phase).
- If CPU ended on a **cached address**: cache_hit='1' → 8 hits (50% duty, suppress)
- If CPU ended on an **I/O address** ($D000-$DFFF): cache_hit='0' → 0 hits
- If CPU ended on an **unfilled address**: cache_hit='0' → 0 hits

Measured: 35% ≈ 70% cacheable × 50% suppress duty cycle

### Improvement Paths

| Approach | Expected Max | Complexity | Status |
|----------|-------------|------------|--------|
| Current (suppress) | 12 MHz | Baseline | **Working** (6.2 MHz actual) |
| Dual-BRAM lookahead | 20 MHz | Moderate | **Failed** (73%→85% ALMs) |
| Line buffer lookahead | 20 MHz | Low | **Failed** (73%→85% ALMs) |
| SDRAM prefetch (RAM regions) | ~14 MHz | Moderate | Deferred (ROM limit) |
| MLAB data store (no M10K latency) | 20 MHz | High (~4K ALMs) | Not viable (73%→83%) |
| Wider SDRAM (16-bit reads) | ~14 MHz | High (sys/ changes) | Not viable (read-only) |

### Why Suppress Elimination Fails on Cyclone V

All three approaches to eliminating the 1-cycle suppress penalty failed with the
same ~5,000 ALM increase (73%→85%), causing fitter failure. The root cause is NOT
the data storage (BRAM vs registers) but the **validity checking logic**:

```
next_valid = cacheable_rd
           AND (byte_offset /= "111")               -- 3-bit compare
           AND tag_match                              -- 11-bit compare (already computed)
           AND valid_mem(line_index)(byte_offset+1)   -- MLAB read + 3-bit mux
           AND (line_buf_idx = line_index)             -- 10-bit compare
           AND (line_buf_tag = expected_tag)            -- 11-bit compare
           AND (data_addr = next_addr_reg)              -- 13-bit compare
```

This combinational chain feeds into the `cache_hit_d1` process, which controls
`enableCpu_6510` — a timing-critical path. Quartus duplicates and retimes logic
across the design to meet 32 MHz timing, inflating ALMs by ~5,000.

### Real Bottleneck: Per-Byte Fill Rate

With suppress, max cache hits/rotation = 8 (16 non-CPU slots × 50% duty).
Actual hits = 2.8/rotation (35% hit rate). Eliminating suppress would at best
double to ~5.6 hits. The low hit rate comes from **per-byte fill**: each SDRAM
read fills only 1 of 8 bytes in a line. Sequential code walks through the line
faster than it fills.

To significantly improve speed, need either:
- Burst SDRAM fills (8 bytes per SDRAM read) — requires sys/ changes
- SDRAM prefetch during idle slots — blocked by ROM-in-BRAM issue
- Wider SDRAM bus — hardware limitation

---

## SuperCPU (P65C816) Cache — Why Not Yet

| Issue | Description | Fix Required |
|-------|-------------|--------------|
| Phantom cycles | VDA=0,VPA=0 → no valid bus cycle, CPU ignores data. Cache_hit_d1 would advance CPU past internal processing. | Gate cache_hit_d1 on `vda_816 OR vpa_816` |
| Enable model | P65C816 uses `EN = RDY AND CE`. Arbitrary enables may break internal micro-sequencing. | Verify enable-per-cycle semantics match T65 |
| Write timing | P65C816 freezes mid-write during badlines. Cache_hit_d1 during write setup → corrupted write. | Gate on `NOT cpuWe` |
| Multi-bank instructions | Single instruction accesses PBR + DBR. Cache bank context may be wrong mid-instruction. | Track bank switches per-cycle |

**Approach**: Get T65 turbo solid first, then add P65C816 with VDA/VPA gating as separate enableCpu_816 path.
