# Session Passover - 2026-04-05

## Session Summary
Major debugging session focused on getting Doom to display. Multiple build/test iterations.

## Key Breakthroughs

### 1. ROM Stub Pipeline Fix (CRITICAL)
The external cpuDi mux uses 1-cycle pipelined signals (_d1/_r). In turbo mode with
consecutive CPU enables, the pipeline is stale when the CPU reads — it gets data for
the PREVIOUS address, not the current one. This broke native vector reads.

**Fix**: Moved ROM stub INSIDE cpu_65c816.vhd wrapper. The internal stub provides
data via `localDi` with zero pipeline latency (combinational from `localA`).
This successfully fixed the BRK vector read — the game's BRK dispatch loop started
working (K:9B, A:0202 in UART).

### 2. Native Vector Writes Never Reach Bank $00
Extensive testing proved that **Doom never writes to $00:FFE4-$FFEF**:
- Bank $00 only guard → V:FF00 (defaults unchanged)
- Bank $00+$01 guard → V:0000 (bank $01 garbage corrupts)  
- ALL banks guard → V:0000 (random writes corrupt)
- No enable gate → V:FF00 (still no bank $00 writes)

**Conclusion**: Doom relies on the SuperCPU kickstart ROM having pre-configured
the native vectors AND the handler code in bank $00 SRAM.

### 3. Handler Code Problem (NEW — Session End)
Even with hardcoded correct vectors (BRK→$0202, IRQ→$0D3C), the CPU crashes
because bank $00 at those addresses contains C64 KERNAL/RAM data, not SuperCPU
handler code. The green screen proves Doom ran briefly before crashing.

The real SuperCPU kickstart:
- Copies KERNAL to SRAM
- Installs BRK dispatcher at $00:0202
- Installs IRQ routing code in bank $00
- Sets native vectors to point to these handlers
- Clears bootmap

## Current State of Code
- cpu_65c816.vhd: Internal ROM stub with writable vec_reg registers
  - BRK vector hardcoded to $0202 (Doom dispatcher)
  - IRQ vector hardcoded to $0D3C (Doom raster)
  - Write guard: bank $00, native mode, any clock edge
  - Read: combinational from localA (zero latency)
- fpga64_sid_iec.vhd: External ROM stub DISABLED (scpu_rom_stub_active <= '0')
  - The external pipeline path is unreliable for vector reads
- Both external scpu_native_vec and internal vec_reg exist (cleanup needed)

## Next Steps (Priority Order)

### 1. Implement Minimal Kickstart
Need to provide SuperCPU runtime code in bank $00 SRAM (BRAM):
- BRK dispatcher at $00:0202: reads BRK signature byte, dispatches via JML
- IRQ router: accepts VIC IRQ, routes to game handler
- Study VICE SuperCPU source for exact handler code
- Could hardcode in ROM stub or initialize BRAM during boot

### 2. Understand SuperCPU Runtime
- Check VICE scpu.c / scpu64rom.c for kickstart behavior
- What does the BRK dispatcher at $0202 actually do?
- How does IRQ routing work (direct handler or routing table)?
- Does Doom install its own handlers or use kickstart defaults?

### 3. Alternative: JML Trampoline in ROM Stub
Instead of full kickstart, put JML trampolines at vector targets:
- $FF02: JML to BRK dispatcher (but where in Doom's address space?)
- $FF10: JML to IRQ handler (but what bank does $0D3C live in?)
This requires knowing the exact banks, which we may not have.

## UART Debug Format (Current)
`A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx V:xxxxWxx!`
- V: now shows IRQ vector from internal vec_reg (dbg_irq_vec_816)
- W: first write to $FFEE (from external scpu_native_vec debug)
- !: VIC IRQ asserted

## Build Notes
- 15+ build/deploy/test cycles this session
- Internal ROM stub adds ~17 registers, negligible resource impact
- External ROM stub disabled but code still present
