# Session handoff — 2026-05-12 (REU + SuperRAM data clean; $0090 disproved as -9 carrier)

## Bottom line

Three big findings narrowed the music_num=-9 hypothesis space dramatically.

**REU and SuperRAM data layers are byte-perfect** for the music data
region. The loader's REU→SuperRAM copy is clean.

**doom.reu contains zero int32 -9 (`F7 FF FF FF`) constants** — the value
-9 is computed at runtime, not loaded from a literal.

**v314 wr02 ring at `$0090` shows `00 03 00 FF` with no `$F7`** —
`$0090` is NOT where music_num=-9 lives at error-print time. The v291
interpretation was wrong.

## What we proved this session

### Data layer (REU + SuperRAM) is clean
- `reu_peek_doom_hex.prg`: 6/6 anchor bytes match doom.reu via REU FETCH
  (`78 D8 FF 8C 53 43` at REU $200000/01 / $400000/01 / $800000/01)
- `superram_peek_doom_hex.prg`: 12/12 SuperRAM bytes match file
  (anchor row + music-table area $86:$E9C0 / $86:$EACF / $87:$0000 /
  $2B:$1A23 / $2C:$A95C)
- `superram_peek_argptr.prg`: $87:$EAD8..$EADD = 0 (match file);
  $87:$EB0C..$EB0F = 0 (match file); $86:$EAD0..$EAD1 = `$18 $B3`
  (RUNTIME OVERRIDE — file has zero)

Screenshots:
- `tools/doom_full/reu_peek_hex.png`
- `tools/doom_full/superram_peek_after_doom.png`
- `tools/doom_full/superram_peek_argptr.png`

### v314 RTL probe: $0090 doesn't carry -9
- Built `acf30af`+1 (RTL change at `fpga64_sid_iec.vhd:3132` repointing
  wr02_* from `$00FC` to `$0090`). RBF md5
  `91b23d253438e3fd29bdb105307baa47`.
- After full Doom run + wedge at music_num=-9:
  - V (last 4 writes to $0090): `00 03 00 FF`
  - WP: `$2C:$85FB` (after `STA $90` at $85F9, the cleanup)
  - CY: `$0713` = 1811 writes total
  - M chain: `$85A1 → $85B6 → $85E8 → $85F6` (canonical error chain)
- Snapshot in `tools/doom_full/v314_uart_150s.txt`
- Screen: `tools/doom_full/v314_wedge_150s.png` (confirms "-9" displayed)

### doom.reu literal scan
- `F7 FF FF FF` (int32 -9 LE): **0 occurrences in 16 MB**
- `F7 FF` (int16 -9): 67 (likely byte coincidences)
- `5C XX 85 2C` JML-to-$2C-bank table at `$85:$65A0..$65BC` with two
  entries (idx 13/14) pointing to `$2C:$85A1` music error
- No `7C XX XX` JMP-abs-X, `22 XX 65 85` JSL, or `A9 XX 65` LDA-imm
  referencing this table → dispatcher reaches it via COMPUTED address

### Disasm of error chain at $2C:$85Axx
- `$2C:$85A1` is the **error-screen DEFAULT music initializer** —
  `LDA #$0003; STA $90; STZ $92` sets music_num to 3 (not -9!), then
  JMLs to `$2B:$76F9` (a thin trampoline that JMLs through `[$74]`).
- `$2C:$85B6 → $85E8 → $85F6 → $A95C` is the post-print chain.
  `$85F6` sets `$90/$92 = $FFFFFFFF` then JML self-trap.
- printf format string at `$86:$02C0` = `"Bad music number %d\0"`.
  No 24-bit pointer (`C0 02 86`) to it exists in doom.reu — accessed
  by computed address.

## Working state

- **HEAD**: `acf30af` on `vanilla-cpu-swap` (v314 RTL change uncommitted
  in working tree until next commit)
- **Deployed RBF**: md5 `91b23d253438e3fd29bdb105307baa47` (v314,
  3,853,328 B)
- **New artifacts** (uncommitted):
  - `tools/build_reu_peek_doom_hex.py`, `.prg`, `.mgl` (committed in
    `acf30af`)
  - `tools/build_superram_peek_doom_hex.py`, `.prg`, `.mgl` (committed)
  - `tools/build_superram_peek_argptr.py`, `.prg`, `.mgl` (new)
  - `tools/v314_doom_capture.py` (new)
  - `tools/doom_full/v314_wedge*.png`, `v314_uart*.txt` (new)
  - `C64_MiSTer/rtl/fpga64_sid_iec.vhd` (1-block edit at line 3127-3132)

## Why "-9" appears on screen but $90 holds $03 at trap time

The screen text "Error: Bad music number -9" was rendered during
gameplay, MINUTES before the trap chain ran. printf was called with
music_num = -9 at that earlier moment. By the time the trap chain
($85A1...) runs, the screen still shows the old text but $90 has been
overwritten with the error-screen default (3) and then the chain's
final value ($FFFF).

So the trap chain we see in M ring is the **post-print halt**, not the
producer. The actual `LDA #$??? / STA $90` (or wherever music_num is
held) for -9 happened earlier and was overwritten.

## Open hypotheses (ranked)

1. **music_num lives in a different zero-page slot** — try `$0094`
   or `$0098` next (the printf-walker working registers at
   `$2B:$76xx`). Same one-line RTL repoint.
2. **music_num lives in SuperRAM, not zero-page** — Doom global var
   in a static struct. Locate via wider SuperRAM scan (a probe-PRG
   that scans 256 KB and reports any address holding `$F7 $FF $FF $FF`).
3. **The "$F7 $FF" was a transient value during printf int-to-ASCII
   conversion** — never stored, computed in a register sequence.
   Would require a CPU-A register trace at $2B:$77xx printf-walker
   entry. Harder to instrument.

## Next-session entry point

**Try $0094 first** (least cost — 1-line RTL change + 12-min build).

1. Edit `C64_MiSTer/rtl/fpga64_sid_iec.vhd:3132`:
   change `x"0090"` to `x"0094"`. Update preceding comment.
2. `./build_c64.ps1` (12 min wall).
3. `python tools/v314_doom_capture.py` (auto-deploys + 75s wait +
   re-captures at 150s if not wedged + UART analysis).
4. Decode V ring: if `$F7` appears, WP is the producer's PC and
   M ring shows what code path got there. If still no `$F7`,
   move to the broader SuperRAM scan probe.

The SuperRAM scan probe (option 2) is also straightforward — paint
each bank's first matching offset to a hex row. Builds on the existing
`superram_peek_*` PRG patterns.

## Tested deployment pattern (locked in)

Two-step sequential MGL+pipe (when probe needs Doom-populated SuperRAM):
1. `_doom_full_abs.mgl` — loader + reu, wait 60-75s for wedge.
2. `<probe>.mgl` — single-file probe PRG, autoruns; SDRAM survives.

For REU-only-with-no-loader experiments: `doom_reu_only.mgl` (single
`.reu` tag) + 20-s wait, then probe MGL.

Multi-file MGL with `.reu` + `.prg` does NOT autorun the second tag.
