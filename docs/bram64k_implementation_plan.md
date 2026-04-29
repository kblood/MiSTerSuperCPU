# 64KB Dual-Port BRAM Implementation Plan

## Goal
Replace the 8KB cache with 64KB dual-port M10K BRAM for bank $00 C64 RAM.
CPU reads/writes via Port A at full speed. VIC-II reads via Port B independently.
Target: 20+ MHz effective CPU speed for bank $00 code.

## Resource Budget

```
Current:     30,591 ALMs (73.0%)    464 M10K (83.9%)
Remove cache: -4,710 ALMs           -8 M10K
Add 64KB BRAM:  +350 ALMs          +64 M10K
Result:      26,231 ALMs (62.6%)   520 M10K (94.0%)
```

## Architecture

```
              ┌──────────────────────────────────────────────┐
              │         fpga64_sid_iec.vhd                   │
              │                                              │
              │   ┌──────────────────┐   ┌──────────────┐   │
              │   │  64KB Dual-Port  │   │   P65C816    │   │
              │   │  BRAM (M10K)     │   │   (65C816)   │   │
              │   │                  │   │              │   │
              │   │  Port A: CPU     │──▶│ di ← bramDo  │   │
              │   │  rd/wr, 0 wait   │   │              │   │
              │   │                  │   │ enable ←─────│───│── bram_hit_d1
              │   │  Port B: VIC-II  │   │        OR enableCpu (SDRAM)
              │   │  rd only, indep  │   │              │   │
              │   └────────┬─────────┘   └──────────────┘   │
              │            │ vicBramDo                       │
              │            ▼                                 │
              │   ┌──────────────────┐                      │
              │   │    VIC-II        │                      │
              │   │  reads from BRAM │                      │
              │   │  port B (bank 0) │                      │
              │   └──────────────────┘                      │
              │                                              │
              │   SDRAM path: SuperRAM (banks $01-$EF) only  │
              └──────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. BRAM Address Space
- 64KB = 65,536 bytes at addresses $0000-$FFFF (bank $00)
- Covers ALL RAM including "under ROM" areas ($A000-$BFFF, $E000-$FFFF)
- ROM overlay (KERNAL, BASIC, chargen) handled by buslogic mux as before
- I/O ($D000-$DFFF) goes to real I/O hardware, not BRAM

### 2. CPU Data Path (Port A)
- **Reads**: CPU addr → BRAM Port A → registered output (1-cycle latency)
  - `bram_hit` = combinational: bank=$00, addr not I/O, not ROM overlay active
  - `bram_hit_d1` = registered: fires every cycle when bram_hit=1 (NO suppress)
  - `cpuDi` mux: bram_do when bram_hit_d1, else SuperCPU regs, else cpuDi_raw
- **Writes**: CPU write → BRAM Port A write enable (same cycle)
  - Also write to SDRAM via existing path (for cartridge/DMA coherency)
  - Or: only write BRAM, skip SDRAM for bank $00 (simpler, VIC reads BRAM)

### 3. VIC-II Data Path (Port B)
- VIC presents `systemAddr` (14-bit, extended to 16-bit) to BRAM Port B
- BRAM Port B output → `vicBramDo` → feeds VIC data input
- Replaces SDRAM reads for bank $00 character, bitmap, and sprite data
- VIC color RAM is separate (already in FPGA registers)

### 4. Enable Model (No Suppress)
```vhdl
-- bram_hit: combinational, trivial address check
bram_hit <= '1' when cpu_bank = x"00"
                 and cpuAddr(15 downto 12) /= x"D"  -- not I/O
                 and cs_ram = '1'                     -- RAM selected (not ROM)
                 and cpuWe = '0'                      -- read only (writes handled separately)
            else '0';

-- bram_hit_d1: registered, fires EVERY cycle (no suppress!)
process(clk32)
begin
    if rising_edge(clk32) then
        if bram_en = '1'
           and not dma_active and baLoc
           and not scpu_speed_1mhz
           and not iec_slow_mode
           and not cpu_cyc_s(0) and not cpu_cyc_s(1) and not enableCpu
        then
            bram_hit_d1 <= bram_hit;
        else
            bram_hit_d1 <= '0';
        end if;
    end if;
end process;
```

No self-clearing `if bram_hit_d1 = '1' then '0'` — that was the suppress.
The M10K registered output and registered bram_hit_d1 naturally align:
both deliver data/enable for the SAME address, 1 cycle after presentation.

### 5. Write Path
CPU writes to bank $00:
- Write to BRAM Port A (immediate, 1 cycle)
- Also write to SDRAM (for DMA/cartridge coherency) — or skip if VIC reads BRAM
- Decision: **skip SDRAM write for bank $00** since VIC reads from BRAM Port B.
  Only write SDRAM for SuperRAM (banks $01-$EF).

### 6. Initial RAM Loading
- HPS (ioctl) loads programs via SDRAM. Need to also write to BRAM for bank $00.
- Route ioctl writes to BRAM when target is bank $00.
- KERNAL boot: writes go through CPU → BRAM Port A (normal operation).

### 7. SuperRAM (Banks $01-$EF)
- Still use SDRAM path (no change from current)
- SDRAM bandwidth improved: VIC no longer uses SDRAM for bank $00
- Can repurpose VIC SDRAM slots for additional SuperRAM bandwidth

## Files to Modify

| File | Changes |
|------|---------|
| `rtl/c64_ram64k.vhd` | **NEW**: 64KB dual-port BRAM entity |
| `rtl/fpga64_sid_iec.vhd` | Replace cache with BRAM, new enable model, VIC data path |
| `c64.sv` | Route VIC data from BRAM, adjust SDRAM path for bank $00 |
| `rtl/fpga64_buslogic_roms.vhd` | Possibly adjust RAM/ROM mux for BRAM source |
| `rtl/cpu_cache.vhd` | **REMOVE** from build (or keep but unused) |
| `C64.qsf` | Add new file, optionally remove cache |

## Implementation Phases

### Phase 1: BRAM Entity
Create `c64_ram64k.vhd` with:
- Port A: 16-bit addr, 8-bit data, read/write, clk
- Port B: 16-bit addr, 8-bit data, read only, clk
- Pure M10K inference (no MLAB)

### Phase 2: Integrate BRAM into fpga64_sid_iec
- Instantiate BRAM, wire Port A to CPU address/data
- Add `bram_hit` / `bram_hit_d1` logic (no suppress)
- Wire `bram_hit_d1` into CPU enable path
- Update `cpuDi` mux to use BRAM output
- Wire Port B to VIC address, feed output to VIC data input

### Phase 3: Adjust SDRAM Path
- Skip SDRAM reads for bank $00 CPU accesses (BRAM handles them)
- Skip SDRAM writes for bank $00 (VIC reads BRAM, not SDRAM)
- Keep SDRAM for SuperRAM (banks $01-$EF)
- Handle ioctl/HPS writes to bank $00 → route to BRAM

### Phase 4: Remove Cache
- Remove cpu_cache instantiation from fpga64_sid_iec
- Remove cache-related signals
- Remove cache from QSF file list

### Phase 5: Test & Iterate
- Syntax check
- Full build (verify ALMs < 85%, M10K < 95%)
- Deploy to MiSTer
- Boot test (READY prompt)
- Speed test (measure effective MHz)
- VIC display test (screen corruption = VIC Port B wiring issue)
- IEC disk load test
- SuperRAM test (if applicable)

## Speed Expectations

| Scenario | Enables/Rotation | Effective Speed |
|----------|-----------------|-----------------|
| Current (8KB cache) | 6.8 | ~6.2 MHz |
| BRAM, non-CPU slots only | 16 + 4 SDRAM | ~20 MHz |
| BRAM, all slots | 32 | ~32 MHz |
| BRAM, practical (I/O stalls) | 24-28 | ~24-28 MHz |
| Real SuperCPU (reference) | N/A | 20 MHz |

## Risk Mitigation

1. **M10K at 94%**: If fitter fails, try 48KB BRAM ($0000-$BFFF) = 48 M10K, 91.1%
2. **VIC display broken**: Port B wiring error → verify systemAddr mapping
3. **Boot failure**: BRAM not initialized → ensure HPS/ioctl writes reach BRAM
4. **Write coherency**: DMA/cartridge writes to bank $00 must update BRAM
5. **Rollback**: Keep cache code, togglable via OSD or ifdef
