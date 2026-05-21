# C64 Turbo Types: Extra Cycles vs Fast PHI2

## Overview

There are two fundamentally different approaches to accelerating a C64 CPU.
We built a **turbo detect tool** that identifies which type is in use by
comparing two independent timing references: the CIA timer (clocked by phi2)
and VIC raster lines (clocked by the fixed video output rate).

| Property | Extra Cycles (SuperCPU / MiSTer) | Fast PHI2 (Ultimate 64) |
|---|---|---|
| How it works | CPU gets more bus slots per frame; phi2 stays at 1 MHz | phi2 clock itself runs faster (e.g. 48 MHz) |
| CIA timer speed | 1 MHz (unchanged) | Accelerated with phi2 |
| VIC raster rate | Fixed (50/60 Hz video) | Fixed (50/60 Hz video) |
| CIA-based speedtest | Shows real turbo speed | Always shows ~1 MHz |
| VIC-based speedtest | Shows real turbo speed | Shows real turbo speed |
| Detection signature | CIA > 1 MHz | CIA ~1 MHz, VIC >> 1 MHz |
| Max speed achieved | ~4 MHz current, 12-20 MHz theoretical | Up to 64 MHz (U64 Starlight) |

## How Each Type Works

### Extra Cycles (SuperCPU / MiSTer)

The original C64 runs a 32-slot bus rotation every microsecond:

```
EXT(4) + DMA(4) + EXT(4) + VIC(4) + CPU(16) = 32 slots at 32 MHz
```

The CPU gets 16 of 32 slots = 1 effective MHz. In turbo mode, the CPU
steals additional slots from the EXT (expansion) window, or the cache
serves data without needing a bus slot at all. The VIC, CIA, SID, and
all other chips still see standard 1 MHz phi2 timing.

**Key property**: phi2 never changes. The CPU simply executes more
instructions between VIC frames by using slots that would otherwise be idle
or by hitting the cache.

Current MiSTer performance (hardware-verified):
- 8KB cache: ~2913 cache hits/frame + ~7624 SDRAM accesses/frame = ~4x
- Theoretical max with cache lookahead: 16 cache + 4 SDRAM = 20 slots/rotation = **20 MHz**

### Fast PHI2 (Ultimate 64)

The Ultimate 64 takes a completely different approach: it increases the
phi2 clock frequency itself. At 48 MHz, every chip connected to phi2
runs 48x faster. The FPGA buffers video frames internally and outputs
them at the standard display rate.

**Key property**: from the CPU's perspective, *everything* is proportionally
faster. A CIA timer that counts 65535 cycles still takes 65535 cycles, but
those cycles complete in 65535/48000000 = 1.4 microseconds of wall time
instead of 65.5 milliseconds.

Measured on Ultimate 64 Starlight (turbo_detect.prg):
- CIA: count = 0x0001 (timer wraps 16-bit counter at 48x speed)
- VIC: count = 0x831F = **43.8 MHz** (raster lines advance at fixed 60 Hz)
- Type correctly detected as: **FAST PHI2**

## Impact on Software Compatibility

### Extra Cycles: High Compatibility

Since phi2 stays at 1 MHz, all timing-sensitive hardware behaves identically:

- **SID music**: Correct pitch and tempo (SID is clocked by phi2)
- **CIA timers**: Serial I/O baud rates, keyboard scanning, jiffy clock all correct
- **Raster effects**: VIC-II timing unchanged; most demos and games work
- **Disk I/O**: IEC serial timing preserved (our core auto-slows to 1 MHz for disk)
- **Broken by turbo**: Only software with cycle-exact CPU-VIC synchronization
  (some protection schemes, tight raster effects that count exact CPU cycles)

### Fast PHI2: Low Compatibility

Everything clocked by phi2 runs faster, breaking timing assumptions:

- **SID music**: Plays at higher pitch and faster tempo (48x at full speed)
- **CIA timers**: All baud rates wrong, keyboard scans too fast
- **Raster effects**: CPU/VIC cycle relationship changes unpredictably
- **Disk I/O**: Serial timing completely wrong at turbo speeds
- **Best for**: Computation-heavy tasks, compilation, non-interactive programs
- **The U64 mitigates this** by allowing per-software speed selection via config

## What Could MiSTer Achieve with Each Approach?

### Extra Cycles (Current Approach) - Theoretical Maximum: 20 MHz

Our current architecture gives the CPU up to 16 of 32 slots per rotation.
With the 8KB MLAB cache serving data in 1 cycle (no SDRAM needed), the CPU
can execute on every cache-hit slot. The bottleneck is SDRAM access for
cache misses, which requires a dedicated bus slot.

```
Current (measured):     ~4 MHz effective (cache + SDRAM mix)
With cache lookahead:   ~12-20 MHz (prefetch next cache line during SDRAM slot)
Hard ceiling:           20 MHz (all 20 non-VIC slots to CPU, perfect cache)
```

The path to 20 MHz:
1. **Cache lookahead** - prefetch the next sequential cache line during idle SDRAM
   slots, so the CPU almost never waits. This is the single biggest win.
2. **BRAM CPU reads enabled** - requires per-byte valid tracking (currently
   disabled due to M10K budget). Would eliminate SDRAM reads for $0000-$7FFF.
3. **Wider SDRAM burst** - read 2-4 bytes per SDRAM access to fill cache lines
   faster (SDRAM is 16-bit hardware, currently using 8-bit interface).

### Fast PHI2 (Hypothetical on MiSTer) - Theoretical Maximum: 64+ MHz

If we ran the entire C64 emulation at a higher phi2, we could potentially reach
very high speeds. The Cyclone V FPGA on the DE10-Nano runs at:

- Current system clock: 32 MHz (derived from 50 MHz PLL)
- FPGA fabric max: ~200-300 MHz for simple logic
- Practical limit for C64 logic: ~64-100 MHz (limited by SDRAM timing)

But the **SDRAM is the real bottleneck**. The DE10-Nano has a single 32MB
SDRAM chip shared between the C64 core and the MiSTer framework (video
scaler, OSD). The SDRAM controller runs at ~130 MHz with CAS
latency, meaning each read takes multiple cycles. At 64 MHz phi2, every memory
access would need to complete in ~15ns, which is at the edge of SDRAM capability.

```
With current SDRAM:     ~16-32 MHz (SDRAM becomes bottleneck)
With full BRAM (64KB):  ~64 MHz (but uses 95% M10K, fitter breaks)
With 32KB BRAM + cache: ~32-48 MHz (realistic sweet spot)
```

### Hybrid Approach: Best of Both Worlds

The ideal MiSTer implementation could combine both:

1. **Extra Cycles for the CPU** (preserving 1 MHz phi2 for CIA/SID/IEC)
2. **Fast internal execution** using BRAM/cache (CPU runs at FPGA speed
   when data is in cache, stalls only on SDRAM misses)
3. **Transparent to software** - CIA timers, SID, serial all run at 1 MHz
   while the CPU effectively runs at 12-20 MHz

This is exactly what the real SuperCPU 64 did: the 65C816 ran at 20 MHz
internally but stalled for I/O accesses that needed the 1 MHz bus. Our
MiSTer implementation follows the same philosophy.

## Turbo Detect Tool

The `turbo_detect.prg` / `turbo_detect.crt` measures both reference clocks
simultaneously and displays:

```
TURBO DETECT
CIA   xxxx  xx.x MHZ    CIA timer reference (phi2-relative)
VIC   xxxx  xx.x MHZ    VIC raster reference (wall-clock)
TYPE  EXTRA CYC / FAST PHI2 / NONE
D0BC  xx                 SuperCPU detect register
PASS  xxxx               Measurement counter
```

### Detection Logic

```
If CIA >= 2 MHz:                     → EXTRA CYC
If CIA < 2 MHz and VIC >= 2 MHz:     → FAST PHI2
If both < 2 MHz:                     → NONE (1 MHz)
```

### Verified Results

| Platform | Turbo Setting | CIA | VIC | Type |
|---|---|---|---|---|
| Ultimate 64 Starlight | Off | 0.9 MHz | 0.9 MHz | NONE |
| Ultimate 64 Starlight | Manual 48 MHz | ~0.0 MHz* | 43.8 MHz | FAST PHI2 |
| MiSTer (no turbo) | Off | 0.9 MHz | 0.9 MHz | NONE |
| MiSTer (turbo) | 4x | ~3.2 MHz** | ~3.2 MHz** | EXTRA CYC |

\* CIA counter wraps 16-bit at extreme speeds
\** Estimated from cache hit rates; needs manual PRG load to verify

### Files

- `tools/test_cart/out/turbo_detect.prg` - PRG version (auto-runs via SYS 2304)
- `tools/test_cart/out/turbo_detect.crt` - CRT version (Ultimax, auto-starts)
- `tools/test_cart/gen_turbo_detect_prg.py` - Generator (builds both)

Deploy to Ultimate 64:
```bash
curl -X POST --data-binary @tools/test_cart/out/turbo_detect.crt http://192.168.50.94/v1/runners:run_crt
# Or PRG:
curl -X POST --data-binary @tools/test_cart/out/turbo_detect.prg http://192.168.50.94/v1/runners:run_prg
```

Deploy to MiSTer: load `turbo_detect.prg` via OSD (F12 > Load).
