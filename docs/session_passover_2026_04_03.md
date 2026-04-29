# Session Passover 2026-04-03: REU FETCH Fix + Writable Vectors → Doom Partially Running

## Goal
Fix REU FETCH DMA and get Doom running on MiSTer SuperCPU.

## Summary
Fixed two critical bugs that were preventing Doom from working:
1. REU FETCH DMA returned wrong data (byte toggle clobbering in SDRAM controller)
2. Native mode vector ROM stub was read-only (Doom couldn't install its IRQ handler)

With both fixes, Doom enters native mode, executes game code from SuperRAM bank $2D
for ~160 seconds, writes to screen memory, then eventually crashes.

## Changes (Committed)

### 1. REU FETCH DMA Fix (commit 2cee62d)
- **Root cause**: REU SDRAM reads have addr[24]=1 (high byte), but `bt` in sdram.v
  gets overwritten by io_cycle CEs with addr[24]=0 → wrong byte returned
- **Prior attempts that failed**:
  - `!io_cycle` gate on reu_sdram_capture
  - Delay-based 3-stage shift register (captured before STATE_READ)
- **Fix**: Added `dout_reu` register in sdram.v that captures `sd_data[15:8]` only
  when `q == STATE_READ && bt && !wr`. Immune to bt clobbering.
- **Files**: `C64_MiSTer/rtl/sdram.v`, `C64_MiSTer/c64.sv`
- **Verified**: STASH $AA→FETCH→PEEK = 170 ✅, SuperRAM round-trip $42 = 66 ✅

### 2. Writable Native Mode Vectors (commit abc4160)
- **Root cause**: ROM stub at $FFE4-$FFEF was combinational read-only, always returning
  $FF00 (RTI). Doom writes its own IRQ handler address but reads got hardcoded values.
- **Fix**: 14-byte register array `scpu_native_vec` in fpga64_sid_iec.vhd
  - Index 0-1: $FF00/$FF01 (RTI/RTL, writable)
  - Index 2-13: $FFE4-$FFEF (native mode vectors, writable)
  - Initialized to ROM stub defaults at reset
  - Writes in native mode + bank $00 update registers
- **File**: `C64_MiSTer/rtl/fpga64_sid_iec.vhd`

### 3. mister_debug.py Shell Quoting Fix
- `cmd_keys` now properly shell-quotes mtype.py arguments with `\r`→`enter` translation
- Fixes bash syntax errors from parentheses in BASIC commands like `PEEK(1280)`

## Hardware Test Results

### REU FETCH DMA
- STASH $AA to REU addr 0, FETCH back to $0500: PEEK(1280) = **170** ✅
- Previous builds returned 32 (wrong byte from bt clobbering)

### SuperRAM Round-trip
- STA $42 to $02:$0100, LDA back: PEEK(2) = **66** ✅ (not broken by sdram.v change)

### Doom Data Verification
- LDA long $200000 after OSD loading doom.reu: PEEK(2) = **120** ($78 = SEI) ✅
- First byte of Doom matches expected entry point opcode

### Doom Execution (Skip Loader: JML $200000)
- **Phase 1 (working, ~160 seconds)**:
  - UART: E:0, B:2D (bank $2D = SuperRAM), T:FF (turbo on)
  - Real 65816 opcodes: LDA, STA, REP, SEP, ADC, JML, STA [dp], etc.
  - Stack at $057F-$0580 (normal)
  - Screen filled with character data (Doom's display buffer)
- **Phase 2 (crash)**:
  - UART: E:0, B:00, I:00 (BRK), T:FE (turbo off), R:04CC
  - CPU stuck in BRK→vector→BRK loop
  - Screen frozen on last character pattern

## Crash Analysis
The crash after ~160 seconds suggests one of:
1. **SuperRAM instruction fetch corruption**: SDRAM returns wrong opcode during execution
   from bank $2D, causing CPU to jump to wrong address in bank $00
2. **Missing kernal shadow SRAM**: Doom may need full writable $E000-$FFFF, not just vectors.
   The game might store code or data at $E000-$FFDF which currently falls through to
   C64 KERNAL ROM or SDRAM via buslogic
3. **VIC-II timing interaction**: VIC bad line or DMA stealing cycles at wrong moment
   corrupts CPU state during SuperRAM access
4. **Specific 65816 instruction not implemented correctly**: a rare instruction or
   addressing mode triggers after enough game execution

## Build State
- RBF: `C64_MiSTer/output_files/C64.rbf` (2026-04-03 02:52)
- Resources: 72% ALMs (30,245), 68% RAM
- Deployed and running on MiSTer

## Next Steps (Priority Order)
1. **Determine crash trigger**: Add UART diagnostic that triggers when PBR transitions
   from non-zero to $00 in native mode — capture the address and last instruction
2. **Test with loader.prg**: The skip loader bypasses REU DMA. Test the full path:
   OSD load doom.reu → BASIC load+run loader.prg → loader does FETCH DMA → JML
3. **Kernal shadow investigation**: Check if Doom writes/reads $E000-$FFDF in bank $00.
   If yes, need writable SRAM shadow for that range (8KB BRAM)
4. **SuperRAM fetch stability**: The ~160s working period suggests the fetch path works
   but has an intermittent corruption (possibly timing-related)
5. **VIC-II display**: The character pattern on screen may be correct — Doom uses a custom
   character set. Check if VIC $D018 is pointing to the right charset location

## Test Commands
```bash
# Deploy
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf

# Load doom.reu via OSD (physical F12 recommended):
# F12 → down×4 → Enter → down → Enter → wait 50s

# Skip loader (after doom.reu loaded):
# Type: 10 FORI=0TO6:READA:POKE49152+I,A:NEXT
#        20 DATA120,24,251,92,0,0,32
#        30 SYS49152
#        RUN

# Monitor UART during execution:
python tools/mister_debug.py uart 5
```

## MiSTer Status
- IP: 192.168.50.130 — online, latest build deployed
- doom.reu loaded in REU SDRAM (OSD load confirmed by screenshot filename)
- Virtual keyboard may be dead (multiple mtype.py invocations)
