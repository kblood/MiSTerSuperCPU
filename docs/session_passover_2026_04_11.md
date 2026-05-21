# Session Passover 2026-04-11: CLC/XCE resolved, Doom runs, I/O slow-down added

## Headline

Three major breakthroughs: (1) CLC/XCE crash was a test code bug, not CPU; (2) Doom game logic confirmed running stably in native mode bank $BD; (3) root cause of missing display identified and fix implemented (I/O slow-down for turbo mode).

## 1. CLC/XCE Crash: RESOLVED — test_xce.prg bug

test_xce.prg had `JMP $081C` at address $081B — jumps into the middle of its own instruction. Fixed in `test_xce_fixed.prg` (added SEI, shifting JMP to $081C for correct self-loop). Verified with mbc+RUN: GREEN border, stable loop.

BRAM stale data theory also ruled out — PEEK returns correct values, POKEd RTS executes correctly.

## 2. Doom REU Loading: WORKS (was always working)

MGL `type="f" index="2"` loads doom.reu correctly. The 24-bit `reu_ioctl_cnt` counter wraps to 0 for exactly 16MB (2^24), which misled us into thinking the file didn't load. User confirmed load visible on MiSTer UI.

**MGL that works:**
```xml
<mistergamedescription>
  <rbf>_Test/C64</rbf>
  <file delay="5" type="f" index="2" path="games/C64/doom.reu"/>
</mistergamedescription>
```

**Doom launcher (POKE+SYS):**
```
POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,0:POKE49156,0
SYS49152
```

## 3. Doom Game Logic: RUNNING (13+ minutes stable)

UART confirms:
- K:BD E:0 T:01 — native mode, turbo, bank $BD (SuperRAM)
- Frame counter incrementing at ~50Hz (39,000+ frames)
- IRQ handler at $BD:FC0D runs every frame
- Previous crash at $20:20FC is GONE — code progressed far past it

## 4. Display: ROOT CAUSE found, fix in progress

**Problem:** VIC register writes from turbo mode are silently dropped.
- VIC write gate (`vicBus <= cpuDo`) guarded by `phi0_cpu = '1'` (line 937)
- `phi0_cpu` only active during 1MHz CPU bus slot
- In turbo mode, CPU writes during cache/BRAM hit cycles where `phi0_cpu = '0'`
- I/O writes never reach VIC/SID/CIA

**Root cause:** Missing I/O slow-down. Real SuperCPU stalls 20MHz CPU for I/O access to synchronize with 1MHz bus.

**Fix applied** in fpga64_sid_iec.vhd — `io_slowdown` signal:
```vhdl
io_slowdown <= '1' when cpuAddr_pre(15 downto 12) = x"D"
                     and addr_hi_816 = x"00"
                     and supercpu_en = '1'
                     and vpa_816 = '0'    -- data access only (not instruction fetch)
                     and vda_816 = '1'    -- valid data cycle (not phantom)
               else '0';
```
Gates BRAM/cache turbo enables in `enableCpu_816` — I/O access falls through to 1MHz `enableCpu` path where `phi0_cpu='1'`.

**First attempt** (without VPA/VDA gates) was too aggressive — also slowed instruction fetches from $D000 range, causing CPU to get stuck at $00:D014 polling a VIC register. Fixed by adding `vpa_816='0' and vda_816='1'` to only trigger on data accesses.

**Build status:** Second build (with VPA/VDA gates) running in background. Build ID: `biga9mswz`.

## 5. Other findings

- `$DF00` register readback works (returns 16 = 0x10, correct REU status)
- `$DF09-$DF0C` ioctl counters work but wrap to 0 for 16MB files
- `$DF20` diagnostic buffer still returns wrong value (separate issue, low priority)
- `scpu_io_en` in buslogic correctly gates I/O to bank $00 only (line 278)
- `mtype.py` keyboard exhaustion: limit to ~4 calls per deploy, reboot between batches

## Files Modified

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — added `io_slowdown` signal + VPA/VDA gates
- `tools/test_cart/test_xce_fixed.prg` — corrected test PRG
- Memory files updated: `project_lda_long_crash.md` (resolved), `MEMORY.md` (Doom status)

## Next Steps (for next session)

### Immediate: Test I/O slow-down build with Doom
1. Wait for build `biga9mswz` to complete (or check if already done)
2. Deploy via MGL: core + doom.reu
3. POKE launcher + SYS49152
4. Check if display updates (screenshot + UART)

### If display still doesn't work
- Check if the VPA/VDA-gated slowdown is triggering (UART should show I/O access patterns different from previous builds)
- Maybe also need to slow reads (not just writes) from I/O — the CPU may be reading VIC status at turbo speed and getting stale values
- Consider whether `cs_io` signal would be a better gate than address-based check
- Check if the write-back buffer needs to handle I/O writes too

### If display works
- Check for visual correctness (Doom title screen should appear)
- Test keyboard input (Doom uses keyboard for controls)
- Profile performance — I/O slow-down may reduce effective speed significantly if Doom does many I/O accesses per frame

## Restoring Stock Core

Our core was copied to `/media/fat/_Computer/C64_20250828.rbf` (backup at .bak). Restore:
```
cp /media/fat/_Computer/C64_20250828.rbf.bak /media/fat/_Computer/C64_20250828.rbf
```
