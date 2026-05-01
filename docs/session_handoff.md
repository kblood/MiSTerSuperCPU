# DL/SCPU debug session — 2026-04-30 evening

## Bottom line (2026-04-30 evening)

We've narrowed the DL/SCPU rendering bug down through three bundled
overlay-probe builds:

- **v234**: $D019 read divergence proven. T65 reads `$F1` (raster only),
  SCPU reads `$F7` (raster + sprite-bg + sprite-sprite collisions).
  Same `$D01A=$01` enable mask written. → "Upstream branch divergence
  already happened before the IRQ handler runs." NOT a CPU dispatch
  bug, NOT an ack bug.

- **v235**: Sprite *control* registers identical T65 vs SCPU.
  `$D015=$FF`, `$D01B=$FF`, `$D01C=$80`, write-count both `$30`.
  Writer PC differs by +3 (T65 latches at SYNC=1, P65C816 latches
  post-fetch — known calibration). → Bug is NOT in sprite-enable
  / priority / multicolor / Y-X-expand. Must be in sprite *positions*
  or *bitmap data*.

- **v236 (in progress)**: bundled probe for sprite 0/1 X+Y positions
  (`$D000-$D003`) plus `$D010` high-X bits. New row 13 in overlay.
  Y_HI bumped 258→264. Build kicked at 23:35. Decoder ROWS extended
  to 14.

## What v236 will tell us

| v236 row 13 result | Interpretation |
|---|---|
| `S0X##Y##` differs T65 vs SCPU | Sprite positions diverge → bug is in sprite-position-update routine |
| `S0X##Y##` identical T65 vs SCPU | Bug in sprite *bitmap data* → need v237 to probe sprite-pointer reads at `$07F8-$07FF` |

## VICE oracle dead-end

xscpu64 + dl00.reu hangs at `PC=$3093` (CLI/LDA $45/BEQ $309B/JMP
$3093 wait loop). Loop exits on `$45==0`; DL's IRQ never fires on
VICE because `$D01A=$F0` (no IRQ source enabled). Even bypass-poke
of `$45=00` is immediately overwritten by background code. VICE is
doubly blocked because `$D01A=$F0` also means VICE has no working
FLI raster IRQ for gameplay. Tools at `tools/vice_diff/` retained
for non-DL SCPU regressions. Memory:
`project_vice_xscpu64_blocks_dl_oracle.md`.

## Older context (now superseded but kept for grep)

The "P65C816 6.8× slower per opcode" claim from the morning of
2026-04-30 was wrong (cycle audit of `MCode.vhd` matched NMOS
counts). The "I=1 stuck on SCPU" hypothesis from `project_dl_iflag_
permanent_scpu.md` is on master, not vanilla-cpu-swap; here we still
need to explain why SCPU ends up triggering sprite collisions when
sprites are configured identically.

## Build artifacts

- v234 RBF: `md5 772853597314bdb27466d2054f206862` (output_files at 22:14)
- v235 RBF: `md5 3309f9c7ca1cf7b2d269163ddf169008` (output_files at 23:27)
- v236 RBF: building (background task `b5r7iy5gy`)

## Captures

- `tools/dl_screens_v234_t65/` 8 PNGs — RD=F1 EM=01 SB=F WR=F2
- `tools/dl_screens_v234_scpu/` 8 PNGs — RD=F7 EM=01 SB=F WR=F8
- `tools/dl_screens_v235_t65/` 8 PNGs — D5=FF P=003015 N=30 B=FF C=80
- `tools/dl_screens_v235_scpu/` 8 PNGs — D5=FF P=003018 N=30 B=FF C=80
- v236 captures pending build completion

## Open tasks

- #22 in_progress — Port crash trace ring buffer (lower priority)
- #23/#25 BLOCKED — VICE oracle dead-end
- #35 in_progress — v236 sprite-position probe build

## Next steps after v236

1. Decode `tools/dl_screens_v236_{t65,scpu}/` row 13.
2. If positions differ → v237 latches `$D000-$D00F` write *PC*
   (24-bit) + counter, same approach as `$D015` in v235. PC
   identifies the divergent code path.
3. If positions identical → v237 captures sprite *pointer* reads
   at `$07F8-$07FF` (VIC bus snoop, harder — needs VIC-side probe).

## Hygiene

- Don't burn one-shot builds. Bundle 3+ probes per build.
- Don't use `-Release` flag during overlay/UART debug — it disables overlay.
- Decoder is at `tools/decode_overlay.py`. Always update `ROWS` when adding rows.
- `tools/dl_triage_run.py --t65` flag toggles cfg byte 10 between
  `0x08` (overlay only, T65 path) and `0x0C` (SCPU + overlay).
- `--no-deploy` skips the rbf upload — use this for the second
  capture run with the same rbf.
- After each `dl_triage_run.py`, rename `tools/dl_screens` to
  `tools/dl_screens_v###_{t65,scpu}` before the next run.
