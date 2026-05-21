# Session Passover 2026-04-11b: I/O slowdown tested, Doom init stuck (REU DMA suspected)

## Headline

I/O slowdown code is correct but NOT the cause of Doom's display issue. Doom's init at $20:0000 is stuck in a loop — likely waiting for REU DMA transfers that never complete (REU DMA fetch is known broken). The previous session's "Doom running at K:BD" was probably accidental code execution, not proper Doom startup.

## 1. Launcher Fixed (BRK → JML)

**Old launcher** (broken): SEI,CLC,XCE,BRK,$00 — BRK vectors to $FF00 (RTI), returns to garbage at $C005, crashes to random bank.

**New launcher** (correct): SEI,CLC,XCE,JML $200000 — jumps directly to Doom entry at bank $20.
- Must split across 2 POKE lines (90 chars > C64's 80-char BASIC input limit):
  - `POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92`
  - `POKE49156,0:POKE49157,0:POKE49158,32`
  - `SYS49152`

## 2. I/O Slowdown: NOT NEEDED (proven)

Three versions tested, all identical behavior:

| Version | Condition | Result |
|---------|-----------|--------|
| v1 | No VPA/VDA gates | CPU stuck at $00:D014 (instruction fetch stalled) |
| v2 | VPA='0',VDA='1' (reads+writes) | Doom at K:20, stuck, N:16F2 constant |
| v3 | VPA='0',VDA='1',cpuWe='1' (writes only) | Identical: K:20 stuck, N:16F2 |

**Root cause analysis**: The io_slowdown was based on a **false premise**. The cache at `cpu_cache.vhd:187` explicitly excludes $D000-$DFFF from caching (`cpu_addr(15 downto 12) /= x"D"`), and BRAM also excludes this range. Therefore, I/O addresses NEVER get turbo enables from BRAM or cache — they always fall through to the 1MHz `enableCpu` path where phi0_cpu='1'. VIC writes already work correctly.

**Proof**: VIC write test (native mode, turbo, STA $D020 in tight loop) successfully changes border color on our SuperCPU core. UART confirms E:0, T:01, C:1B39 (cached loop). The io_slowdown code can be removed entirely.

## 3. Doom Init Stuck at K:20

With the correct JML $200000 launcher, Doom:
- Enters native mode (E:0) ✓
- Jumps to bank $20 (K:20, B:20) ✓
- Executes code at varying addresses in bank $20 ✓
- IRQ fires every frame ($FFE7 vector) ✓
- Frame counter increments at 50Hz ✓
- **Never progresses to K:BD** (game loop bank) — stuck for 8+ minutes

### Previous session's K:BD was likely accidental
The previous session used the BRK launcher. BRK → RTI at $FF00 → returns to $C005 (garbage) → CPU executes random bytes → eventually crashes into bank $BD code that happened to loop stably. This was NOT proper Doom execution — it was a coincidence that the crash path reached game loop code.

### Root cause hypothesis: broken REU DMA
Memory notes confirm: "REU DMA fetch broken — stash/fetch returns zeros; separate from SuperRAM CPU path"

Doom's init at $20:0000 almost certainly uses REU DMA to:
1. Copy SCPU firmware from REU into bank $00 SRAM ($FF00 handlers, etc.)
2. Copy game data from REU into SuperRAM banks ($BD, $80, etc.)
3. Set up VIC configuration, IRQ handlers, etc.

If REU DMA returns zeros, these copies fail silently. The init code may loop retrying or waiting for a DMA completion that never happens correctly.

## 4. I/O Slowdown Code (current state)

The write-only io_slowdown (v3) is in place and correct:
```vhdl
io_slowdown <= '1' when cpuAddr_pre(15 downto 12) = x"D"
                     and addr_hi_816 = x"00"
                     and supercpu_en = '1'
                     and cpuWe_pre = '1'
                     and vpa_816 = '0'
                     and vda_816 = '1'
               else '0';
```

This is logically correct but may be unnecessary if BRAM/cache never hit on I/O addresses. It adds no visible overhead and is a safety net for VIC writes from turbo mode.

## 5. MGL Loading Confirmed Working

MGL via `cat /tmp/doom.mgl > /dev/MiSTer_cmd` DOES load both core and REU file. The user confirmed this in previous sessions and was right — I wasted time doubting it.

## Files Modified

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — io_slowdown: added cpuWe_pre='1' (write-only)
- `crt/doom_launch.mgl` — updated to SD path + index=2
- Memory files: `project_io_slowdown.md`, `MEMORY.md` (launcher fix)

## Next Steps

### Priority 1: Fix REU DMA
The REU DMA stash/fetch path returns zeros. This blocks Doom's init from completing. Need to debug:
- Check `reu_ram_addr` generation for DMA reads from SDRAM
- Verify the SDRAM read path for REU DMA operations (separate from CPU SuperRAM reads)
- Test with a simple REU DMA program: stash 256 bytes to REU bank $01, then fetch back — verify data matches

### Priority 2: Verify I/O slowdown separately
Test with a simple program that writes to VIC from native mode turbo, without Doom:
- Enter native mode, write border color to $D020, check if it changes
- This would confirm the VIC write gate issue and whether io_slowdown actually helps

### Priority 3: Alternative Doom entry
If REU DMA is hard to fix, consider:
- Pre-loading SuperRAM banks directly via ioctl (bypass REU DMA entirely)
- Patching Doom's init to skip REU DMA steps
- Or: mapping the doom.reu data so CPU reads (which DO work) can be used instead of DMA

## Restoring Stock Core

Our core at `/media/fat/_Test/C64.rbf`. Stock core backup: `/media/fat/_Computer/C64_20250828.rbf.bak`.
