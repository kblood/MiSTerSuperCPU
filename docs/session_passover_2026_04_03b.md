# Session Passover 2026-04-03b: 64KB BRAM + SuperRAM Cache + Crash Analysis

## Goal
Get Doom fully running on MiSTer SuperCPU.

## Summary
Extended bank $00 BRAM from 32KB to 64KB for native mode SRAM shadow, added PBR/DBR
debug output to UART, enabled SuperRAM cache fills, and analyzed the persistent ~180s crash.

## Changes (Committed)

### 1. 64KB BRAM for Native Mode SRAM Shadow (commit 1120e84)
- **Root cause**: Real SuperCPU has 128KB SRAM for banks $00/$01. In native mode,
  $8000-$FFFF is writable SRAM. Our 32KB BRAM only covered $0000-$7FFF.
- **Fix**: Extended c64_ram64k from 32KB to 64KB. Added `bram_hit_native` signal
  for $8000-$FFFF in native mode (excluding $D000-$DFFF I/O).
- **Result**: Doom no longer crashes at ~160s when accessing $E000-$FFFF in bank $00.
  Previous crash was PBR jumping to $04 with wild stack corruption.
- **Resources**: 73% ALMs (30,512), 95% RAM blocks (528/553)
- **Previous session's approach failed**: bankSwitch override caused black screen.
  BRAM approach works because it doesn't modify buslogic — BRAM has priority
  in cpuDi mux, and BRAM fills naturally from emulation mode ROM reads.

### 2. PBR/DBR/SP Debug UART (commit 36c135c)
- Exposed PBR and DBR from P65C816 through cpu_65c816 → fpga64_sid_iec → c64.sv
- Replaced D: (data bus, unused) with K: (PBR) in UART output
- Replaced R: (cpu_cyc count) with S: (stack pointer) in UART output
- Format: `A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx`

### 3. SuperRAM Cache Fills (commit 36c135c)
- Removed `not superram_in_pipeline` gate from cache_fill_we
- Added mux: `cache_fill_data <= superram_data_r when superram_in_pipeline else cpuDi_raw`
- Result: 15x cache hit increase (C:134D vs C:014F), 4x instruction throughput
- Doom code in bank $2D now served from 8KB cache after first read

### 4. Registered SDRAM Address (REVERTED, commit cc26529)
- Attempted to register scpu_superram_addr_r on clk32 to reduce clk64 timing violation
- CAUSED WORSE CRASHES: 1-cycle stale address when BRAM hits fire at CPUB
  (1 cycle before cpu_cyc at CPUC). SDRAM reads previous address.
- Reverted. SDRAM address mux MUST remain combinational.

### 5. mister_debug.py Fixes
- SSH: added PubkeyAuthentication=no for scp commands (too many SSH keys)
- mtype.py: increased timeout from 15s to 30s
- keys command: detect mtype.py native arguments (f12, down, enter, etc.)
  and pass through unquoted instead of wrapping in single quotes

## Crash Analysis

### The ~180s Crash (Deterministic, Still Present)
- **Pattern**: PBR jumps from $2D to $00, I:BF (LDA long,X), stack corrupted
- **Happens at the same game state**: ~20M CPU steps without cache, ~76M with cache
  (faster execution reaches the same game point sooner in wall-clock time)
- **Not caused by $8000-$FFFF BRAM** (fixed separately, was a different crash)
- **Not caused by vectors** (stable BRK→RTI loop when crash manifests differently)
- **Likely cause**: SDRAM timing violation (-15ns on clk64 domain, -8ns on clk32)
  corrupts a SuperRAM instruction fetch. A single wrong opcode byte can cascade
  into PBR change + stack corruption.
- **Evidence**: crash only happens during bank $2D execution (SuperRAM/SDRAM),
  never during the polling loop (bank $00/BRAM). BRAM-served code is immune.

### UART Observations During Doom Execution
- Normal: K:2D B:2D (instruction fetch from SuperRAM bank $2D)
- Normal: K:2D B:00 (data access to bank $00 via DBR=$00 or direct page)
- Normal: K:2D B:BE (data access to bank $BE — game data)
- Crash: K:00 B:00/04 I:BF S:FF31 (PBR=$00, LDA long,X, corrupted stack)
- Post-crash: Stuck in BRK→$FFE6→$FF00→RTI loop or LDA long,X loop

### Doom Initialization Code (from doom.reu at $200000)
```
SEI / CLD / CLC / XCE         → native mode
REP #$30                       → 16-bit A, X, Y
LDA #$0000 / TCD              → DP = $0000
LDA #$01FF / TCS              → SP = $01FF
SEP #$20 / LDA #$00 / PHB/PLB → DBR = $00
STA $DC0E / $DC0F / $DD0E / $DD0F → stop all CIA timers
STA $D015 / $D01A             → disable sprites, VIC IRQs
LDA #$7F / STA $DC0D / $DD0D  → clear CIA IRQ masks
LDA $DC0D / $DD0D             → acknowledge pending IRQs
STA $D019                     → clear VIC IRQ flags
LDA #$35 / STA $01            → bankSwitch = $35 (I/O visible, ROMs off)
STA $D07E                     → hwenable strobe
STA $D07B                     → turbo enable
STA $D076                     → BASIC optimization
STA $D07F                     → hwenable disable
```

## Build State
- RBF: `C64_MiSTer/output_files/C64.rbf`
- Resources: 73% ALMs (30,446), 95% RAM blocks (528/553)
- Timing: clk64 -15.5ns, clk32 -5.8ns (unchanged)

## Next Steps (Priority Order)
1. **Fix SDRAM timing**: The -15ns clk64 violation is the root cause of the crash.
   Registering the address didn't work. Need to find and break the specific
   long combinational paths in the clk32→clk64 domain crossing.
2. **Alternative**: Run Doom exclusively from BRAM/cache (no SDRAM instruction fetch).
   This requires enough BRAM to cover all of Doom's active code. 8KB cache may
   not be sufficient — larger cache or code-specific BRAM preloading needed.
3. **P65C816 RTI investigation**: Verify RTI correctly restores PBR in all cases.
   If RTI has a subtle bug (e.g., pops wrong byte count in certain P states),
   that could also cause PBR corruption.
4. **Doom polling loop**: After crash fix, Doom reaches a polling loop at $00:F6C0
   comparing $59:0002 vs $59:DC02. This suggests the IRQ handler isn't updating
   game state. Needs investigation after crash is resolved.

## Test Commands
```bash
# Deploy
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf

# Load REU + skip loader
python tools/mister_debug.py keys "f12 wait:2 down down down down enter wait:1 down enter"
# Wait 55s for REU load
python tools/mister_debug.py keys '10 FORI=0TO6:READA:POKE49152+I,A:NEXT\r20 DATA120,24,251,92,0,0,32\r30 SYS49152\rRUN\r'

# Monitor UART (new format with PBR and SP)
python tools/mister_debug.py uart 300
# K: = PBR, S: = Stack pointer (new fields)
```
