# Session handoff — 2026-05-14 (v341 built, ready to deploy)

## Bottom line

**v341 RBF built and committed (md5 `a1faa08cece10efabddc04b1ea0565be`).**
Adds three probe fields to the per-vblank UART line to disambiguate the
black-screen wedge that remains after v340n fixed the post-$0EED IRQ flood.

New UART fields per line:
- `1D:####` (bytes 194-201) — last cpuDi/cpuDo at bank-$00:`$1D02` / `$1D04`
  (Doom's page-flip handshake). Gated on supercpu_bank=$00 so JIT
  bank-$XX:`$1D02` hits don't shadow the real handshake words.
- `D6:##` (bytes 220-225) — last cpuDo to `$D016`. MCM bit (bit 4) must
  be set for multicolor-bitmap mode.

Line length 224 → 230. R7 (always-zero diag slot) repurposed for 1D.

MiSTer is loaned to another agent — deploy when free.

## Why these probes

VICE xscpu64 + doom.reu + loader.prg (warp 30-240s) **renders Doom title
bitmap** at t=180s while HW v340n black-screens with identical code.
Code therefore correct; bug is in our FPGA infrastructure.

VICE state at t=180s+ (visible Doom title):
- D011=$BB (DEN+BMM+RSEL, raster_msb=1)
- D016=$D8 (**MCM=1, CSEL=1** → multicolor bitmap)
- D018=$81 (screen=$2000 in-bank, bitmap=$0000)
- DD00 toggles $C0↔$C2 (bank 3 ↔ bank 1) every frame — double-buffer
- $FFEE=$EAEA (**VICE Doom has NO native IRQ vector installed**)

HW state at t=240s (v340n):
- D1=3B, D8=80, C2=02 (correct mode, bank 1, screen $2000) — basic VIC setup matches
- DD00 stuck at $02 (bank 1 only) — **page-flip not happening**
- VW=AC=9, IF=001C (9 raster IRQs total over 240s)
- PC drifts $2C:$2FE6-$36xx — CPU running JIT but in a tight ~1KB span

## Three live hypotheses to discriminate with v341

1. **Bitmap-fill code never runs** — PC stuck in a polling loop early in
   `R_Init` aftermath, before the renderer ever touches $4000-$5F3F.
   v341 signal: `1D:####` shows both bytes at boot defaults ($00 or
   garbage), never updates. D6 stays at boot default.

2. **$D01A=$00 mask kill breaks Doom's frame scheduler** — our stub
   at $FF1A masks all VIC IRQs every ack. If Doom polls $1D04 from
   main but the producer at $0F58 is IRQ-driven, $1D04 never changes
   → main waits forever.
   v341 signal: `1D:####` shows static value (e.g., `0101` or `0000`),
   D6 updated to $D8 once during init.

3. **Page-flip stuck on bank 1** — Doom's flip code at $80:$0B40 reads
   $1D04, BEQs, picks DD00. If $1D04 != 0 it always picks bank 1.
   v341 signal: `1D:####` shows $1D02 and $1D04 BOTH non-zero, equal
   to each other and stable.

VICE differential expectation: $1D04 should toggle between two values
each frame (oldest+1, oldest, oldest+1, ...) and $1D02 should follow.

## v341 deploy procedure (when MiSTer free)

```bash
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf
# Load doom.reu via MGL with absolute path
ssh root@192.168.50.130 'echo load_core /media/fat/_Test/doom_reu_only.mgl > /dev/MiSTer_cmd'
# After ~30s for REU load + load_prg loader, type loader sequence:
python tools/mister_debug.py keys 'POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92\nPOKE49156,0:POKE49157,0:POKE49158,32\nSYS49152\n'
# Capture UART
python tools/mister_debug.py uart 300 > tools/doom_full/v341_uart.txt
python tools/mister_debug.py screen tools/doom_full/v341_screen.png
```

Then `grep -oE "1D:[0-9a-fA-F]{4}" tools/doom_full/v341_uart.txt | sort -u`
to see the unique $1D02/$1D04 values across the run. Empty or one-value
→ probe doesn't trigger or stays constant. Multiple distinct values →
handshake is alive somehow.

## Resource budget v341

- ALMs: 27,060 / 41,910 (**65%**) — down from prior 73% baseline
  (some pruning during fitter optimization, no logic intentionally
  removed by this commit)
- M10K: 403 / 553 (73%)
- WNS: +3.568ns (HDMI PLL counter) — no failed paths
- Build time: 12:26

## Open items behind this surface

Still pending root-cause regardless of v341 outcome:
- VICE has $D011=$BB but HW has $D011=$3B (bit 7 / raster_msb differs).
  Doom on HW may never reach the code that sets raster_msb=1 (renderer
  not running) — see hypothesis 1.
- WriteSmart still MISSING but should not matter for vanilla-cpu-swap
  branch (single c64_ram64k BRAM shared CPU+VIC; no separate SCPU SRAM
  to mirror from).

## Files modified for v341

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — `dbg_mem_1d02`/`dbg_mem_1d04`
  ports + signals + read/write latches at lines 3645-3667
- `C64_MiSTer/c64.sv` — wires + instance connections + pool assignments
- `C64_MiSTer/rtl/debug/debug_pkg.svh` — `mem_1d02`/`mem_1d04` pool fields
- `C64_MiSTer/rtl/debug/debug_uart_pool_fmt.sv` — LINE_LEN=230, R7→1D,
  +D6 field bytes 194-201 and 220-225

Commit: `df066a8`
