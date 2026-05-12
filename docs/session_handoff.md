# Session handoff — 2026-05-12 (REU + SuperRAM data layers proved clean)

## Bottom line

Two real-data probes ran against v313 (RBF md5 `1a93f82b7939fac96ffdf983d0fb43a1`).
Both came back **byte-perfect**: REU SDRAM contains doom.reu unchanged, and
the loader's REU→SuperRAM copy lands correct bytes at music-data offsets.

The music_num=-9 producer is **not** a data-layer bug. The remaining
hypothesis space is CPU-execution-time state (bank-$00 RAM/zero-page,
I/O state at trap evaluation, or a runtime access pattern not exercised
by synthetic probes).

## What we proved this session

### Probe 1: REU FETCH on real doom.reu bytes (`reu_peek_doom_hex.prg`)
Reads 6 known bytes from doom.reu via REU FETCH and paints them as hex
on screen row 0. Result:
```
78 D8 FF 8C 53 43
```
matches expected file bytes EXACTLY at REU offsets:
- `$200000`=$78 (Doom bank $20 first byte / SEI)
- `$200001`=$D8
- `$400000`=$FF
- `$400001`=$8C
- `$800000`=$53 ('S' from SCPUMIPS)
- `$800001`=$43 ('C')

Border = $08 = lo-nibble of $78 (independent visual check). Screenshot:
`tools/doom_full/reu_peek_hex.png`.

### Probe 2: SuperRAM long-LDA after loader runs (`superram_peek_doom_hex.prg`)
After full Doom runs to wedge at music_num=-9, this probe long-LDAs
12 SuperRAM locations and paints them as hex. Result:
```
Row 0:  78 D8 FF 8C 53 43   (anchor bytes — match Probe 1)
Row 1:  6D 4B FF A1 A5 5C   (music area + error trap)
```
All 12 bytes match doom.reu, including:
- `$86:$E9C0` = $4B (head of music table area)
- `$86:$EACF` = $FF (mid music table)
- `$2B:$1A23` = $A5 (music check disasm target)
- `$2C:$A95C` = $5C (first byte of `JML $2C:$A95C` self-trap)

Screenshot: `tools/doom_full/superram_peek_after_doom.png`.

## Disassembly of the error chain

Expected doom.reu bytes at `$2C:$85A1..$85A8`:
```
A9 03 00 85 90 64 92 A9
```
Disassembled in M=16 native mode:
- `LDA #$0003`   ; load default music_num
- `STA $90`      ; → zero-page $90/$91
- `STZ $92`      ; clear upper word
- `LDA #...`     ; next

So `$2C:$85A1` is the **error-screen music initializer** (sets music
to track 3 for the error display), NOT where -9 is computed.

Expected bytes at `$2B:$245A..$245D`:
```
85 90 A5 8A
```
- `STA $90`   ; write A → music_num
- `LDA $8A`   ; load $8A into A

This matches the v290/v291 finding that `$2B:$245A` is the **printf
arg-walker** that writes whatever's in A to $90. The value $F7 (low byte
of -9 = $FFF7) was previously latched 245 times here.

So the actual producer of $FFF7 is **upstream of `$2B:$245A`** —
something computes -9 in A then JMPs/JSRs through the printf walker.

## Deployment method (KEEP THIS)

Two-step sequential MGL+pipe:
1. `doom_reu_only.mgl` — single `<file>` tag for `doom.reu` only.
   Pipe `load_core /media/fat/_Test/doom_reu_only.mgl`. Wait 20 s for
   the 16 MB transfer.
2. `reu_peek_doom_hex.mgl` (or `superram_peek_doom_hex.mgl`) — single
   `<file>` tag for the probe PRG. Pipe `load_core`. REU+SuperRAM
   SDRAM both survive the core bitstream reload.

For probe 2, run **full Doom first** via `_doom_full_abs.mgl` (loader +
reu in same MGL — this multi-file pattern DOES work for Doom because
the second file is a regular `.prg` autorun on the existing READY
prompt), wait 60 s for the wedge, **then** load the peek MGL.

**Multi-file MGL with `.reu` first + `.prg` second does NOT autorun the
second tag** regardless of delay (tried `delay="1"/"8"` and `"3"/"15"`).
Use two pipe writes.

## New tooling in this session

- `tools/build_reu_peek_doom_hex.py` → `reu_peek_doom_hex.prg` (542 B)
- `tools/build_superram_peek_doom_hex.py` → `superram_peek_doom_hex.prg`
  (628 B)
- `tools/doom_reu_only.mgl` (REU-only load for sequence step 1)
- `tools/reu_peek_doom_hex.mgl`, `tools/superram_peek_doom_hex.mgl`
- `tools/doom_full/reu_peek_hex.png`,
  `tools/doom_full/superram_peek_after_doom.png` (PASS evidence)

Hex-paint helper inline in both build scripts: nibble→screen-code
conversion via `CMP #$0A / BCC digit / SBC #$09` for A-F, `CLC; ADC #$30`
for 0-9. Branch offsets are pre-computed and verified.

## Working state

- **HEAD**: `3c4609f` on `vanilla-cpu-swap` (no new commits this session)
- **Deployed RBF**: md5 `1a93f82b7939fac96ffdf983d0fb43a1`, 3,860,772 B
- **Source**: probe scripts uncommitted; all RTL untouched

## Open hypotheses (post-session)

The bug must be in one of:
1. **Bank $00 (C64 motherboard RAM) state during execution.**
   Cannot probe directly because bank $00 is BRAM (volatile across core
   reload). Best probe: add an RTL `wrXX_*` ring targeting a critical
   bank-$00 zero-page address (e.g., $0090, $0094, $00A1) and surface
   via UART pool dump. Cheapest implementation: change the `cpuAddr_pre
   = x"00FC"` filter at `fpga64_sid_iec.vhd:3127` to `x"0090"` (or
   another suspect). The wr02_pc + wr02_v0..v3 + cnt_wr02 surfaces
   already exist — repointing is one line.
2. **I/O state at trap-evaluation time** (CIA/VIC/SID/REU regs).
   Less likely given the trap is in a pure code/data error chain.
3. **Runtime access pattern triggering a bug** that synthetic ramps
   and long-LDA don't exercise. Possible candidates: 16-bit indexed
   long-LDA, MVN/MVP block moves, or specific cycle alignments. Worth
   trying if the wrXX probe doesn't surface a clear producer.

The CPU microcode is proven correct by cocotb+VICE lockstep over 15574
instructions (`project_doom_bank20_prologue_match.md`) and another
5000-instr gameplay run (`project_doom_gameplay_match_5000.md`), so
deep CPU-internal bugs are ruled out for the post-loader path.

## Next session entry point

1. Pick a bank-$00 zero-page address most likely to surface the
   producer. Candidates (ranked):
   - `$0090` — last-known music_num write target (v290/v291)
   - `$008A` — read by `$2B:$245A` printf walker (`LDA $8A`)
   - `$00A1` — common zero-page printf temp
2. Edit `C64_MiSTer/rtl/fpga64_sid_iec.vhd:3127`: change `x"00FC"` to
   the chosen address. Keep wr02_* signal names — they already plumb
   through to UART V/WP/CY fields.
3. Build RBF (~30 min, `./build_c64.ps1`).
4. Deploy to `/media/fat/_Test/C64.rbf`, run `_doom_full_abs.mgl`,
   capture UART for 90 s.
5. Decode V/WP/CY: V should show the 4 most recent values written; WP
   shows the writer PC; CY shows total count. If V trends toward $F7
   (low byte of $FFF7) and WP is in bank $2B with a PC that ISN'T
   `$245C`, that's the producer's writer PC.

This is the highest-leverage probe given everything ruled out.
