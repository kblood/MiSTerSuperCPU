# BRAM CPU Cache — Implementation Plan

## Goal

Add an 8KB BRAM cache to the MiSTer C64 core so the CPU (both T65 and P65C816)
can run at up to 32MHz for cached RAM accesses, while I/O chips stay at 1MHz.
No clock changes — the CPU is simply enabled more frequently on the existing 32MHz
system clock.

---

## Architecture

```
  CPU (T65 or P65C816)
    |
    |  addr/data/we
    v
  ┌─────────────┐
  │  cpu_cache   │──── cache_hit ──> enableCpu_fast (fires every clk32 on hit)
  │  8KB BRAM    │──── cache_di  ──> cpuDi (data to CPU, bypasses SDRAM)
  │  direct-map  │
  │  8-byte line │
  └──────┬───────┘
         │ miss / write-through
         v
  ┌──────────────────────────────┐
  │  32-Slot Bus Arbitration     │  (UNCHANGED)
  │  EXT|DMA|VIC|CPU0..CPUF     │
  └──────────┬───────────────────┘
             │
         ┌───┴───┐
         │ SDRAM │
         │ 64MHz │
         └───────┘
```

**Two CPU enable paths:**
- **Fast path (cache hit):** CPU enabled every clk32 cycle. Data from BRAM.
- **Slow path (miss or I/O):** CPU enabled via existing cpu_cyc slots. Data from SDRAM.

---

## Cache Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Total size | 8KB | 10 M10K blocks for data |
| Organization | Direct-mapped | Simple, sufficient for 6502/65816 |
| Line size | 8 bytes | 8 SDRAM accesses per fill |
| Number of lines | 1024 | 8KB / 8 bytes |
| Tag storage | MLAB (distributed RAM) | Combinational read for 0-cycle hit check |
| Data storage | M10K (block RAM) | 1-cycle read latency |
| Write policy | Write-through + write buffer | CPU doesn't stall on writes |
| Write allocation | Write-allocate | Handles self-modifying code |
| I/O handling | Uncacheable | $D000-$DFFF always via CPUC slot |

**Address mapping (24-bit):**
```
[23:16]  [15:13]  [12:3]      [2:0]
 bank     3-bit   10-bit      3-bit
 (tag)    (tag)   line index  byte offset
 └── 11-bit tag ──┘
```

**Tag:** 11 bits (bank[7:0] + addr[15:13]) + 1 valid bit = 12 bits per entry.
Stored in MLAB for combinational (same-cycle) read. 1024 x 12 bits = 12,288 bits
in distributed RAM (~48 ALMs, well within budget).

**Data:** 8192 bytes in M10K. Addressed by {index[9:0], offset[2:0]} = 13-bit,
8-bit wide. Read latency: 1 clk32 cycle.

---

## Timing Pipeline (Critical Path)

To achieve 32MHz (1 CPU step per clk32 cycle), we need a 2-stage pipeline
with data forwarding:

```
Cycle N:   CPU presents address A
           Tag check (MLAB, combinational): hit/miss known immediately
           Data BRAM read initiated (registered, result at cycle N+1)

Cycle N+1: Data BRAM output valid for address A
           CPU enable fires (enableCpu_fast)
           CPU steps, presents address A+1
           Tag check for A+1 (combinational): hit/miss known
           Data BRAM read initiated for A+1

Cycle N+2: Data for A+1 valid, CPU enable fires, presents A+2...
```

**Result:** After the initial 1-cycle warmup, the CPU sustains 1 step per clk32
cycle = 32MHz. Sequential hits (the common case for 6502/65816 code) maintain
this throughput.

**Data forwarding for writes:** When the CPU writes to address X and immediately
reads X, the write updates the data BRAM in cycle N, and the read in cycle N+1
gets the updated value (normal BRAM behavior: write-first mode).

---

## Phase 1: Read-Only Cache, SuperCPU Only

**Goal:** Prove the cache concept. P65C816 reads are accelerated. Writes and
T65 mode use the existing slow path.

### New File: `rtl/cpu_cache.vhd`

```vhdl
-- Entity ports:
--   clk, reset, enable
--   cpu_addr(15:0), cpu_bank(7:0), cpu_we
--   cache_di(7:0)      -- data output to CPU
--   cache_hit           -- '1' when data will be valid next cycle
--   cacheable           -- '1' when address is in cacheable range
--   sdram_data(7:0)     -- SDRAM read data for line fill
--   fill_we             -- write pulse to fill cache from SDRAM
--   fill_index(12:0)    -- {line_index, byte_offset} for fill write
--   flush               -- invalidate all entries
--   cs_io, cs_ram       -- from buslogic (cacheability inputs)

-- Internal:
--   Tag MLAB: 1024 x 12 bits (combinational read, synchronous write)
--   Data M10K: 8192 x 8 bits (synchronous read/write, write-first)
--   Fill state machine: IDLE, FILLING (counts 0-7 bytes)
```

**Cacheability (combinational):**
```
cacheable = enable AND cs_ram AND NOT cs_io AND NOT cpu_we
            AND (cpu_bank = x"00")   -- Phase 1: bank $00 only
```

**Tag check (combinational from MLAB):**
```
line_index = cpu_addr(12 downto 3)
expected_tag = cpu_bank & cpu_addr(15 downto 13)
stored_tag = tag_mlab(line_index)
cache_hit = cacheable AND stored_tag.valid AND (stored_tag.tag = expected_tag)
```

**Fill logic:**
On a cache miss during a `cpu_cyc` SDRAM slot:
1. The normal SDRAM read returns data for `cpuAddr`
2. This data is written into the cache data BRAM at the correct position
3. The fill controller tracks the current fill byte (0-7)
4. Subsequent `cpu_cyc` slots fill the remaining bytes of the line
5. After all 8 bytes: tag is updated with valid=1

For Phase 1, filling is opportunistic: whenever a `cpu_cyc` slot fires for
a miss address, the returned data is captured. The CPU runs at the normal
slow speed during filling. After the line is filled, subsequent accesses hit.

### Changes to `rtl/fpga64_sid_iec.vhd`

**Signal declarations (add after line ~309):**
```vhdl
signal cache_hit       : std_logic;
signal cache_di        : unsigned(7 downto 0);
signal cacheable       : std_logic;
signal cache_hit_d1    : std_logic := '0';  -- 1-cycle delayed hit
signal cache_di_d1     : unsigned(7 downto 0) := (others => '0');
signal cache_flush     : std_logic;
```

**Cache instantiation (after CPU MUX, ~line 1033):**
```vhdl
cache_inst: entity work.cpu_cache
port map (...);

cache_flush <= reset or dma_active;
```

**Modified CPU enable (replace lines 957-958):**
```vhdl
-- Pipeline: cache_hit is combinational (MLAB tag). Delay 1 cycle to align
-- with data BRAM output.
process(clk32)
begin
    if rising_edge(clk32) then
        cache_hit_d1 <= cache_hit and not dma_active and baLoc;
        cache_di_d1  <= cache_di;
    end if;
end process;

enableCpu_6510 <= (enableCpu and not dma_active)
                  when supercpu_en = '0' else '0';

enableCpu_816  <= (cache_hit_d1 or (enableCpu and not dma_active))
                  when supercpu_en = '1' else '0';
```

**Modified cpuDi (modify line 651 fallback):**
```vhdl
-- Replace: cpuDi_raw;
-- With:
cache_di_d1 when (cache_hit_d1 = '1' and supercpu_en = '1') else
cpuDi_raw;
```

The SuperCPU register overlay conditions ($D0xx) all require `cs_vic='1'` which
means I/O space — uncacheable. So cache_hit_d1 is always '0' during register
reads, and the overlay chain works unchanged.

**SDRAM path unchanged:** When cache misses, the existing cpu_cyc/enableCpu path
handles the SDRAM read. The cache passively captures the returned data to fill
the line.

### Changes to `C64.qsf`

Add: `set_global_assignment -name VHDL_FILE rtl/cpu_cache.vhd`

### Phase 1 Testing

| Test | Expected Result |
|------|-----------------|
| Boot T65 mode (SCPU off) | Normal 1MHz, cache disabled |
| Boot SCPU mode, 1MHz ($D07A) | Normal speed, cache enabled but no fast enable |
| Boot SCPU mode, turbo | Faster than 4x — cache hits bypass SDRAM |
| Run BASIC program | Correct results (cache transparent) |
| Demo/game | No VIC glitches (cache doesn't touch VIC path) |
| Lorenz test suite (T65) | All pass (cache disabled in T65 mode) |

---

## Phase 2: Write-Through Support

**Goal:** CPU writes also benefit from cache. Writes update cache immediately
and queue to SDRAM via write buffer.

### Changes to `rtl/cpu_cache.vhd`

**Add write buffer (register-based FIFO):**
```vhdl
type wb_entry_t is record
    addr : unsigned(23 downto 0);  -- full 24-bit address
    data : unsigned(7 downto 0);
end record;
signal wb_fifo  : array(0 to 15) of wb_entry_t;
signal wb_head  : unsigned(3 downto 0) := (others => '0');
signal wb_tail  : unsigned(3 downto 0) := (others => '0');
signal wb_count : unsigned(4 downto 0) := (others => '0');
```

**Write behavior:**
- CPU write to cacheable address: update data BRAM + push to write buffer
- `cache_hit` asserts for writes too (write completes in 1 cycle)
- CPU stalls only if write buffer is full (wb_count = 16)

**New ports:**
```vhdl
wb_pending  : out std_logic;               -- write buffer non-empty
wb_addr     : out unsigned(23 downto 0);    -- next write address
wb_data     : out unsigned(7 downto 0);     -- next write data
wb_ack      : in  std_logic;               -- SDRAM accepted write
```

**Update cacheability:** Remove the `NOT cpu_we` condition:
```
cacheable = enable AND cs_ram AND NOT cs_io AND (cpu_bank = x"00")
```

### Changes to `rtl/fpga64_sid_iec.vhd`

**Write buffer drain during freed CPU slots:**

When cache_hit_d1='1', the CPU didn't use the current SDRAM slot. If we're in
a cpu_cyc slot AND the write buffer has data, redirect the SDRAM access to drain:

```vhdl
-- Write buffer drain: use CPU's SDRAM slots when CPU runs from cache
wb_drain_active <= '1' when cpu_cyc = '1' and wb_pending = '1'
                        and cache_hit_d1 = '1' else '0';

-- Modified RAM control
ramDout <= wb_data when wb_drain_active = '1' else cpuDo;
ramAddr <= wb_addr(15 downto 0) when wb_drain_active = '1' else systemAddr;
ramWE   <= '1' when wb_drain_active = '1'
           else systemWe when sysCycle >= CYCLE_CPU0 else '0';
```

### Phase 2 Testing

| Test | Expected |
|------|----------|
| STA to screen RAM ($0400) | Character appears on screen (write-through to SDRAM, VIC reads it) |
| Self-modifying code | Correct execution (write-allocate updates cache) |
| Rapid consecutive writes | No stall unless >16 queued (monitor wb_count via debug) |
| BASIC string operations | Correct (heap writes go through cache) |

---

## Phase 3: T65 Turbo Cache

**Goal:** The cache accelerates T65 mode when OSD turbo is enabled.

### Changes to `rtl/fpga64_sid_iec.vhd`

```vhdl
-- T65 gets cache when turbo is active
enableCpu_6510 <= ((cache_hit_d1 and turbo_en) or (enableCpu and not dma_active))
                  when supercpu_en = '0' else '0';
```

Cache stays enabled for both modes (`cache_enable <= '1'`). The `turbo_en` gate
ensures stock 1MHz T65 mode is unaffected.

### Phase 3 Testing

| Test | Expected |
|------|----------|
| T65, turbo OFF | Exact 1MHz (Lorenz suite passes) |
| T65, turbo ON | Much faster than 4x — cache accelerated |
| T65, turbo ON, disk access | Depends on IEC timing — may need 1MHz KERNAL |

---

## Phase 4: SuperRAM Caching (Banks $01-$EF)

**Goal:** 65C816 native mode code running in SuperRAM also benefits from cache.

### Changes to `rtl/cpu_cache.vhd`

Tags already include the bank byte (11-bit tag = bank[7:0] + addr[15:13]).
Just update the cacheability check:

```vhdl
cacheable <= '1' when enable = '1'
             and ((cpu_bank = x"00" and cs_ram = '1' and cs_io = '0')
              or  (cpu_bank > x"00" and cpu_bank < x"F0"))  -- SuperRAM
             else '0';
```

Banks $F0-$FF are SuperCPU ROM (served from BRAM already, no caching needed).

### Changes to `c64.sv`

The SDRAM fill path for non-bank-$00 must route through `scpu_sdram_addr`
(which prepends the bank byte). The existing logic at line 1037-1039 handles
this when `supercpu_cycle='1'`.

For cache line fills in non-bank-$00, the fill controller must assert
`supercpu_cycle` and present the bank byte so `scpu_sdram_addr` generates
the correct 25-bit SDRAM address.

---

## Phase 5: Speed Register + Cache Control

**Goal:** Connect $D07A/$D07B to cache enable. Add $D078 cache flush.

### Changes to `rtl/fpga64_sid_iec.vhd`

```vhdl
-- $D07A (1MHz): suppress cache fast path
enableCpu_816 <= ((cache_hit_d1 and not scpu_speed_1mhz)
                  or (enableCpu and not dma_active))
                 when supercpu_en = '1' else '0';

-- $D078 write: software-triggered cache flush
elsif cpuAddr = x"D078" then
    cache_flush_sw <= '1';

cache_flush <= reset or dma_active or cache_flush_sw;
```

---

## Resource Budget

| Component | M10K | ALMs | Notes |
|-----------|------|------|-------|
| Data BRAM (8KB) | 8 | - | 8192 x 8-bit |
| Tag MLAB (distributed) | 0 | 48 | 1024 x 12-bit in LUT RAM |
| Cache controller | 0 | 200 | State machine, comparators |
| Write buffer (16 x 32) | 0 | 80 | Register-based FIFO |
| Fill controller | 0 | 100 | Counter + state machine |
| **Total** | **8** | **~430** | Of 97 M10K / 16K ALMs avail |

---

## Risk Register

| Risk | Severity | Mitigation |
|------|----------|------------|
| MLAB tag read timing | Medium | Verify in TimeQuest that combinational path from cpuAddr through MLAB to cache_hit meets 32MHz setup |
| Double-enable on same cycle | Low | OR gate: cache_hit_d1 OR enableCpu → single CE pulse |
| Write buffer overflow | Medium | Stall CPU when wb_count >= 14; monitor via debug |
| VIC sees stale data | Low | Write-through ensures SDRAM updated within ~4μs |
| DMA coherency | Medium | Full cache flush on dma_active (conservative but safe) |
| P65C816 back-to-back CE | Low | SNES core runs at higher CE rates; verified in SNES MiSTer |
| I/O accidentally cached | High | cs_io check is combinational from buslogic; well-tested path |
| Badline interaction | Medium | baLoc gate on cache_hit_d1 prevents cache during badlines |

---

## Implementation Order

1. **Phase 1** — new file `cpu_cache.vhd`, modify `fpga64_sid_iec.vhd`, update `C64.qsf`
2. **Syntax check** — verify 0 errors before proceeding
3. **Full build** — check resource usage, timing closure
4. **Hardware test** — boot, run programs, verify speedup
5. **Phase 2** — add write support to `cpu_cache.vhd`, drain logic to `fpga64_sid_iec.vhd`
6. **Phase 3** — enable for T65 turbo (one-line change)
7. **Phase 4** — extend cacheability to SuperRAM banks
8. **Phase 5** — speed register integration

Each phase is a separate commit with its own test cycle.
