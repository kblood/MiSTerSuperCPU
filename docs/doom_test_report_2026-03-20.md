# Doom SuperCPU Test Report — 2026-03-20

## What Works

1. **REU DMA confirmed functional** — STASH/FETCH round-trip preserves data.
   Write 4 bytes (42, 99, 123, 200), read back correctly.

2. **doom.reu loads via MGL** — use `index="1"` (framework auto-detects .reu
   extension and maps to ioctl_index=0x81). `index="129"` does NOT work.

3. **loader.prg runs** — DMA transfers execute, screen shows activity during
   data transfer phase. Loader correctly:
   - Writes $D07A (1MHz) for safe DMA operations
   - Performs REU FETCH transfers to copy game data to C64 RAM
   - Writes $D07B (turbo) after DMA for fast CPU execution
   - Uses 65816 instructions (STA [$FB],Y) for memory copy

## What Doesn't Work

**Doom doesn't launch.** The loader completes DMA, copies data, then executes
`JML [$04FC]` (opcode $DC = Jump Long Indirect). This should load a 24-bit
address from $04FC-$04FE and jump there. Instead, the system returns to BASIC.

## Root Cause Analysis

### Possible Cause 1: JML [$04FC] Instruction Not Working
The P65C816 core may not correctly implement opcode $DC (JML indirect long).
This is a relatively uncommon instruction. Needs testing with a simple JML test.

### Possible Cause 2: Wrong Data at $04FC
The loader's DMA may have copied data to the wrong addresses. Our SuperRAM
mapping uses `REU_ADDR + {bank, addr}` which maps bank $02 to REU offset
$020000. If the game expects a different mapping, the JML target would be wrong.

### Possible Cause 3: Game Code Crashes Immediately
Even if JML works and jumps to the correct address, the game code may crash
due to missing SuperCPU features (optimization modes, memory mirroring,
specific register behavior).

## Diagnostic State During Loader

- UART: T:25 (turbo=1, 1MHz=1, cache=1) — contradictory but transient
  during the loader's $D07A→DMA→$D07B sequence
- CPU stuck at $09A1/$09A3 on first run (outside loader code $0700-$07BA)
- N:0000 — zero turbo enables (1MHz mode during DMA phase)
- Second run: loader completed and returned to BASIC READY

## Working MGL

```xml
<mistergamedescription>
<rbf>_Test/C64</rbf>
<file delay="10" type="f" index="1" path="/media/usb0/Games/C64/SCPU/Doom/doom.reu"/>
</mistergamedescription>
```

## Loading Sequence (for testing)

1. Load doom.reu: `echo 'load_core /media/fat/_doom.mgl' > /dev/MiSTer_cmd`
2. Wait 30 seconds
3. Inject loader: `mbc load_rom C64.PRG /media/fat/games/C64/loader.prg`
4. Type: `RUN` or `SYS2061`

## Next Steps

1. **Test JML instruction** — create a simple test: `JML [$C000]` where $C000
   contains a known address. Verify the CPU jumps correctly.
2. **Check $04FC contents** — after loader DMA, PEEK $04FC/$04FD/$04FE to see
   what address the JML targets.
3. **Compare with VICE** — run the same sequence in xscpu64 and capture the
   execution flow for comparison.
4. **Check all 65816 addressing modes** — the native mode test (scpu_native_test.s)
   has JSL/RTL tests but not JML. Add JML to the test suite.
