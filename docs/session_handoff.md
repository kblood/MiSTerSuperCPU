# Session handoff — 2026-05-16 (Doom black-screen RESOLVED via v347 instrumentation)

## Bottom line

**Doom DOES render on the v347 MiSTer SuperCPU build** — it just takes ~5
minutes wall-clock from launcher SYS to reach the bitmap renderer. The
"intermittent render" / "black screen at t=240s" framing from prior sessions
was wrong; the t=240s screenshot was simply too early. `tools/doom_v347_test.py`
+ a post-test screenshot at ~t=505s shows the id Software credits screen
fully rendered (same image as v342_DOOM_RENDERS.png from commit `e5ff820`).

RBF: `4143cf5de84477deb7221f026c568588` — built but uncommitted prior to
this writeup. Commit lands with this handoff.

## What v347 instrumentation proved

Per-frame saturating counters of CPU SDRAM writes to bank-0 SDRAM
$4000-$5FFF (B1) and $C000-$DFFF (B3), latched on vsync rising edge.
UART pool gains `B1:## B3:##` at byte positions 232-243, LINE_LEN 236→245.

| Capture window | B1 nz frames | B3 nz frames | Interpretation |
|---|---|---|---|
| 0-30s | 0/125 | 0/125 | No bitmap writes |
| 0-120s | 0/125 | 0/125 | No bitmap writes |
| 0-240s | 0/125 | 0/125 | No bitmap writes |
| 240-485s (extended 240s UART) | 126/6015 ($FF peak) | 250/6015 ($FF peak) | Real bitmap-fill activity |

Both pages SATURATE to $FF in active frames — that's the CPU writing >255
bytes per frame to each bitmap region. Real render activity, not noise.

**F-counter timeline** (PAL 50Hz):
- Launcher SYS → t=240s: zero bitmap writes (all three short captures + t=240s shot black)
- F:52E4 = start of extended capture (~t=240s)
- F:5D5C (line 1341/6015 of extended UART, +2680 frames ≈ 53s into extended ≈ **t=293s**): first B3 saturating fire, first DD00=$02→$00 flip
- F:5E22 (line 1440, ~t=295s): first B1 saturating fire
- F:81E0 (line 6015, ~t=480s): end of capture
- Post-test screenshot at ~t=505s: **id Software credits fully rendered**

`tools/doom_full/v347_post_test_now.png` is the proof shot.

## Why Doom is slow on HW (next debug axis)

VICE xscpu64 hits the bitmap renderer in ~10s warp. HW takes ~290s. ~30×
slower. Candidate causes:

1. **IRQ rate** — v342 fixed the $D01A=$00 mask kill in $FF1A IRQ stub; IF
   counter now advances ~50Hz (was 2 IRQs/240s pre-fix). Maybe Doom needs
   more frequent IRQs to drive its loaders. Could push to 60Hz NTSC?
2. **SuperRAM long-store throughput** — every `STA long $bb:$hhll` goes
   through the 3-stage SuperRAM pipeline. Doom's recompiler emits many
   ZP-to-SuperRAM spills via 3-byte STA shims; if pipeline stalls per-shim,
   that's a ~30× hit easy.
3. **Recompiler stalls on unmapped ROM banks $F0-$FE** — see wolf3d-ROM-gap
   memory: doom.reu has 22 JMLs to $FC (vs wolf3d's 49/67/98). Maybe Doom is
   also taking slow paths through those banks but recovers, where wolf3d
   dead-ends.
4. **Cache/TLB-like state warm-up** — unlikely on this branch (no I-cache),
   but page-valid bits in the 32KB BRAM may incur first-touch latency.

**Diagnostic next steps** when this debug branch resumes:
- Measure ms-per-frame in JIT main loop via per-frame timestamp: add a
  monotonic 16-bit counter to UART pool, see how many ticks per F advance.
- Time `STA long $bb:$hhll` round-trip in `cart_we → sdram_ack` — should be
  3 clk32 (~90 ns) per write. If stalled longer, that's the bottleneck.
- Compare F-counter advance rate in our HW vs VICE running same binary:
  CPU instruction throughput, not just IRQ rate.

## Build / test reproduction

```bash
# Build (Quartus 17.0.2 Lite via WSL):
./build_c64.ps1

# Deploy + run Doom + parse B1/B3:
python tools/doom_v347_test.py

# Verify post-test render:
python tools/mister_debug.py screen tools/doom_full/v347_post_test_now.png
```

The test script auto-deploys, loads doom.reu via MGL, injects loader.prg,
types RUN+launcher POKE+SYS49152, captures UART at t=30/120/240s, then
240s extended capture, then **(NEW)** a screenshot at t≈485s.

## Files in this commit

**v347 RTL:**
- `C64_MiSTer/c64.sv` — bm1_writes_r/lat, bm3_writes_r/lat, vsync_prev_for_bmcount
  regs (line 1315-1319); dbg_pool assigns (line 1756-1757); always block after
  vsync wire decl (line 2344+) under DBG_OVERLAY.
- `C64_MiSTer/rtl/debug/debug_pkg.svh` — bm1_writes / bm3_writes appended to dbg_pool_t.
- `C64_MiSTer/rtl/debug/debug_uart_pool_fmt.sv` — LINE_LEN 236→245; lat regs;
  format bytes 232-243 emit ` B1:## B3:##`.

**Tooling:**
- `tools/doom_v347_test.py` — deploy + run + parse B1/B3/B6.
- `tools/doom_v342_test.py` — added t=485s screenshot capture at end of extended UART.
- `tools/build_bitmap_render_test*.py` + `run_bitmap_render_test*.py` —
  differential PRGs that prove VIC bitmap mode + bank-1 SDRAM fetch + SCPU
  Tier-3 mirror all work. All 3 PASS on v346 (RBF `f792d37edb1ff1e1705017fe2c6f3501`).
- `tools/build_peek_bitmap.py` — diagnostic PRG that paints 32 hex bytes from
  $4000-$5FFF and $C000-$DFFF to screen, with border color signalling which
  regions have data.

**Evidence:**
- `tools/doom_full/v342_uart.txt` (6015 lines, 240s extended capture).
- `tools/doom_full/v342_uart_30s.txt`, `v342_uart_120s.txt`, `v342_uart_240s.txt`.
- `tools/doom_full/v347_post_test_now.png` — Doom credits screen at ~t=505s.
- `tools/doom_full/bitmap_render_test*_PASS.png` — bitmap-mode reference test passes.

## Status of overall Doom debug effort

✅ **Doom renders on MiSTer SuperCPU.** Bug class for "black screen" was
TIMING (slow init), not WEDGE (stuck). v342 (commit `e5ff820`) was the
load-bearing fix; v347 is the instrumentation that confirmed it.

Open: Doom is ~30× slower on HW vs VICE. That's a perf debug task, not
a correctness debug task — separate from this branch's goal of "boot
Doom on SuperCPU". Resume on a new branch / new session when there's a
specific perf hypothesis to test.

Wolf3D remains stuck — root cause is the missing SCPU ROM banks $F0-$FE
(see `project_wolf3d_v342_root_cause_F0FE_rom_gap.md` memory entry).
