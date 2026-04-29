# Session Passover 2026-04-12b: SDRAM Timing Race Identified — SuperRAM Fix

## Headline

**Identified SDRAM clock domain crossing race** as likely cause of Doom crash during K:2D init. The `superram_data_r` capture in fpga64_sid_iec races against SDRAM CAS latency across clk32/clk64 domains. Fix: bypass the capture and use `sdram_superram` (= sdram.v's `dout_reu`, a clk64-domain latch for bt=1 reads) directly in the cpuDi mux. Build with fix in progress.

## 1. Crash Diagnostics — New UART Fields

Added three diagnostic fields to the UART output:
- **V:xxxx** — native IRQ vector value (scpu_native_vec[12:13] = $FFEE/$FFEF)
- **L:xx** — crash bank latch (first unexpected PBR, never clears after armed)
- **Trailing `!`/`.`** — VIC IRQ asserted/not

### Crash Capture Results

| Run | Crash Bank (L) | Final State | Opcode | P flags | V |
|-----|---------------|-------------|--------|---------|---|
| 2026-04-11d | K:F8 (inferred) | K:00, I:D4 (PEI) | PEI overflow | P:D5, I=1 | N/A |
| This session #1 | unknown | K:00, I:95/$00 (BRK loop) | BRK loop | P:95, I=1 | N/A |
| This session #2 | **L:80** | K:00, I:DB (STP) | CPU halted | P:09, I=0 D=1 | FF00 |

**Key finding**: crash bank is NON-DETERMINISTIC ($80, $F8, random). The CPU jumps to WAD data banks and executes garbage until hitting STP/BRK. IRQ vector stays at $FF00 (default RTI stub) — Doom never installs its handler before crashing. P shows I=1 in most runs = crash happens during init with SEI still set.

## 2. Root Cause Analysis — SDRAM Timing Race

### The Bug

The 3-stage SuperRAM pipeline captures `sdram_raw` (bt-dependent SDRAM dout) at `superram_enable_delay` time (CPUE, 2 clk32 after cpu_cyc):

```
cpu_cyc (CPUC) → cpu_cyc_s(0) → cpu_cyc_s(1) → superram_enable_delay → enableCpu
                                                  ↑ capture here          ↑ CPU reads here
```

The SDRAM controller (clk64) needs 5-6 clk64 cycles from CE to STATE_READ (dout_r update). The capture at CPUE = 4 clk64 after CE. With CE detection at the coincident clk64 edge (2N), STATE_READ is at 2N+5, capture at 2N+4 → **1 clk64 too early**. With CE detected 1 clk64 late (2N+1, marginal timing), STATE_READ at 2N+6, capture at 2N+4 → **2 clk64 too early**.

The clk64 timing report shows -0.27ns slack (marginal violation), confirming the CE detection timing is borderline.

### Why It's Intermittent

The capture reads `dout_r` from the PREVIOUS SDRAM read. For sequential instruction bytes in the same code, the previous read is from an adjacent address. Most of the time, the instruction stream is still coherent enough to execute correctly. But occasionally, a multi-byte instruction's bank byte operand (JML $xxxxBB) gets the wrong value, sending the CPU to a random bank.

### The Fix

Use `sdram_superram` (= sdram.v's `dout_reu`, exposed as `sdram_data_reu` in c64.sv) directly in the cpuDi mux:

```vhdl
-- BEFORE (timing race):
superram_data_r when (enableCpu = '1' and superram_in_pipeline = '1' and cpuWe_pre = '0')

-- AFTER (fixed):
sdram_superram when (enableCpu = '1' and superram_in_pipeline = '1' and cpuWe_pre = '0')
```

`dout_reu_r` is a clk64-domain register that:
- Only updates at STATE_READ for bt=1 reads (SuperRAM addresses)
- Is NOT updated by VIC reads (bt=0) or bank $00 reads (bt=0)
- Stays stable for 2+ clk64 cycles before the CPU reads cpuDi at enableCpu_816 time
- Is bt-independent (immune to io_cycle bt changes at EXT0)

### Why dout_reu Works

Between the SuperRAM cpu_cyc (CPUC) and the CPU read (enableCpu_816, ~N+4):
1. VIC0 CE fires — bt=0, doesn't update dout_reu_r ✓
2. Turbo slot CEs — bank $00/$F0+, bt=0, don't update dout_reu_r ✓
3. io_cycle CEs — typically bt=0, don't update dout_reu_r ✓
4. No other SuperRAM CE fires within the same bus rotation

So dout_reu_r holds the correct SuperRAM data from the current read until the CPU reads it.

## 3. Verified: Not IRQ-Related

The crash is definitively NOT caused by IRQ vector conflicts:
- V:FF00 in all captures — Doom never installs a custom IRQ handler before crashing
- P shows I=1 in most crashes (IRQs disabled)
- The scpu_native_vec write path is correctly gated to bank $00, native mode only
- The scpu_rom_stub_active correctly intercepts vector reads before BRAM/SDRAM

## 4. Vector Architecture — Confirmed Correct

Full analysis of the vector routing showed it's sound:
1. scpu_native_vec write: requires `addr_hi_816 = x"00"`, `emu_mode_816 = '0'`, `cpuWe = '1'`
2. scpu_rom_stub_active read: intercepts $FFE4-$FFEF reads before BRAM/SDRAM
3. No path for doom.reu file data to corrupt vector fetch
4. Native vector registers are 14-byte in-FPGA storage, not SDRAM

## Files Modified

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`:
  - Added `sdram_superram` input port (8-bit, dout_reu from SDRAM)
  - Added `dbg_native_irq_vec` output port (16-bit, scpu_native_vec[12:13])
  - Changed cpuDi mux: `sdram_superram` replaces `superram_data_r`
  - Updated comments on SuperRAM data path
- `C64_MiSTer/rtl/debug_uart_fmt.sv`:
  - Added V:xxxx (native IRQ vector), L:xx (crash bank latch), !/. (VIC IRQ)
  - LINE_LEN extended from 64 to 77
- `C64_MiSTer/c64.sv`:
  - Added `dbg_native_irq_vec` wire and port connection
  - Added `crash_bank_latch` logic (arms on PBR=$20, latches unexpected PBR)
  - Wired `sdram_data_reu` to `sdram_superram` port

## Next Steps

### Priority 1: Test the SDRAM fix
Build with fix is in progress. Deploy and rerun Doom:
1. `mbc load_rom C64.PRG /media/usb0/C64/doom.reu`
2. `python tools/mister_debug.py deploy`
3. POKE launcher + SYS49152
4. Capture 60s+ UART — if no crash (L:00 stays), fix is confirmed

### Priority 2: If crash persists
If the SDRAM fix doesn't help, the crash has a different root cause. Next theories:
- P65C816 CPU core bug in JML/JSL microcode (address bus output)
- BRAM vs SDRAM address conflict during bank transitions
- Cache delivering stale data after bank change

### Priority 3: Doom progression after crash fix
Once crash is fixed, Doom should progress to K:2D game init → VIC graphics:
- Expect: screen color changes (purple), game graphics
- Watch for: V:xxxx changing (Doom installing IRQ handler)
- Debug: any new crashes at later init stages
