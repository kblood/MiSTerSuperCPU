# SuperCPU spec-gap implementation session — 2026-05-09 (continued)

## Bottom line

8 commits this session on `vanilla-cpu-swap`. The most recent two
(`edd36b5` narrow bank-$Fx stub, `095b176` NMI vector RAM-back v2)
**unblock the JML[$74] dispatcher trap** but Doom still wedges in a
tight wait loop at `$41:$DB93` polling some condition that never
becomes true. Wolf3D regression-clean across all 8 commits (still
renders title-screen content, no advancement).

## Commit chain (tip last)

1. `9a84085` — `$D27C-$D27F` SuperRAM extent variables
2. `8d017b1` — IRQ ack stub at `$00:$FF00..$FF16`
3. `246bd3c` — IRQ JML trampoline at `$00:$FCEE-$FCF1`
4. `d179e1b` — Bank-$00 SRAM ROM-shadow (native-mode-gated)
5. `e8cbf39` — Bank-$01 SRAM ROM shadow (Tier 2.1)
6. `c591d33` — Bank `$F0-$FF` $6B-RTL stub (broad — REVERTED logically)
7. `edd36b5` — Narrowed stub to `$F6-$FF` only (heap survives in `$F0-$F5`)
8. `095b176` — NMI vector at `$00:$FFEA/$FFEB` RAM-backed via shadow
   register, captures writes from bank `$00` AND bank `$FF` (per
   `.databank $ff` in `recomp_research/hello/native.s`)
9. `2645049` — docs+tools: NMI v2 session handoff + `recomp_analyze_emit.py`
10. `74e9c74` — debug/uart: `$00:$0707` read-capture probe (R7:#### field).
    Syntax-checked, NOT YET BUILT/DEPLOYED — gated on MiSTer availability.
11. `1a049a6` — `tools/doom_uart_analyze.py` learns R7 field.

Last built RBF: `7614312678cf9726562957aa746bdbff` (095b176), ALM 26,762
/ 41,910 = 64 %. T65 + SCPU cold boot READY. Sweep 9/10 PASS (single
pre-existing `vanilla_basic` UART-format fail).

## Current Doom state (post-095b176)

UART pattern (240 s into run, byte-identical to bank-Fx-narrow
baseline):

| Field | Value | Notes |
|-------|-------|-------|
| PC    | `$00:$FF17` | RTI in IRQ ack stub |
| N     | `$41:$DB93` | main thread last-fetch PC, fixed |
| SP    | `$FFEF` | native upper-page IRQ stack |
| WP    | `$2C:$8570` | recompiled JAL trampoline (writer to `$0002`) |
| J ring | `FCEE FCEE FCEE FCEE` | only IRQ trampoline target |
| M ring | `854E 854E 854E 854E` | only one indirect-jump target (the JAL prologue) |
| AC    | `0x2232` (~50/sec) | VIC raster-IRQ ack count, sane |
| VW    | `0xEA0B` (~245/sec) | vblank-write count, sane |
| VIC   | D1=`9B`, D8=`17`, C2=`97` | text mode default — **no bitmap config attempted** |

The NMI v2 fix (095b176) made **zero observable difference** —
Doom does not write to `$FFEA/$FFEB` from either bank `$00` or `$FF`,
so it isn't using AmiDog's `_tick_install` recipe.

## What the wait loop is NOT

Ruled out via tests this session:
- Not waiting for keyboard input (`tools/doom_input_probe.py` injected
  SPACE/RETURN/Y/ESC/F1 — zero AC/WP/VIC change).
- Not waiting for `_tick_count` (NMI vector v2 had no effect; no
  `STA $FFEA/$FFEB` writes detected in the trace).
- Not stuck in dispatcher trap at `$00:$0074` — that's pre-narrow
  behavior (`c591d33`); narrow stub (`edd36b5`) escaped to bank `$41`.
- Not init/bss-clear loop — duration is steady-rate for 11 minutes
  in `tools/doom_extended/`; init loops finish in seconds.
- VIC bitmap config never reached, so it's not stuck inside Doom's
  render path either.

## Disassembly clue at `$41:$DB93`

`tools/dis65816.py doom.reu 41:DB93 60` (with offset adjustments) shows
a recurring 10-byte recompiled-MIPS-instruction emit pattern:

```
41:DB94  00 00                pad
41:DB96  df 07 07 00          CMP $00:$0707, X
41:DB9A  b0 03                BCS +3 → $DB9F  (skip wedge if [mem] >= A)
41:DB9C  d0 fe                BNE -2 → $DB9C  (self-loop if [mem] != A)
41:DB9E  00 00                pad
41:DBA0  d2 07                CMP ($07)
41:DBA2  07 00                ORA [$00]
...
```

The `BCS skip ; BNE *` pattern is the recompiler's standard emit for
"wait until memory equals A" — a polling loop. `$00:$0707` is just an
example operand; the X register selects which slot. The address space
`$0400-$FFFF` is "Unused" per `recomp_research/recomp.txt`, so
`$00:$07xx` is Doom-specific scratch.

`grep` of doom.reu for storer patterns (`8F/9F 07 07 00`) gives only
1 hit (at `$74:$FD2F`) which sits inside what looks like asset-data
bytes, not code. So the storer that should set the wait variable is
unidentified — likely produced by another code path Doom doesn't
take in our emulation, or is mis-decoded MIPS data.

## Possible non-MiSTer next probes

(All can be done off-device; pick up when MiSTer is free again.)

### A. RTL probe — DONE in commit 74e9c74. Build + deploy needed.

`R7:#### ` field (positions 194-201) replaces VC. Format `R7:LLDD`
where LL is the low byte of the last $00:$07xx read addr and DD is
the byte returned. Locked = wait condition pinned. Cycling = inner
loop has structure.

Sequence:
1. Re-build (Quartus full, ~12 min — code path unchanged from
   095b176 + ~62 lines).
2. Deploy via `python tools/mister_debug.py deploy`.
3. Run `python tools/doom_full_run.py`.
4. Run `python tools/doom_uart_analyze.py tools/doom_full/` —
   look at the R7 distinct-set count.

Original probe spec: was at `docs/probe_plan_07xx_read_capture.md`.
Implemented per spec; minor variation: instead of building dbg_pool
fields with new byte names, reused `lat_irq_vec` slot (with the
old VC field still latched off-line for backward compatibility).

```vhdl
signal dbg_last_read_addr : std_logic_vector(23 downto 0);
signal dbg_last_read_data : std_logic_vector(7 downto 0);
-- on every cpu fetch where cpuWe='0', latch supercpu_bank & cpuAddr
-- + the data byte returned. Surface as new UART field "RD:bbaaaa=dd".
```

If the field locks at `$00:$07xx=00` we've identified the wait
condition. If it cycles, the loop is doing more reads than the
self-loop alone implies.

### B. Recompiler output reverse-engineering

`tools/recomp_research/recomp.exe -opt` can take a MIPS binary and
emit its 65816 translation. If we had Doom's MIPS source binary we
could decode the recompiler's emit patterns symbolically. Since we
don't, but we DO have the example `hello/main.c` + `hello/bin/`,
running `recomp.exe` on it and comparing the output to `hello.s` would
tell us which emit pattern corresponds to which MIPS opcode — letting
us decode the bytes around `$41:$DB93` definitively. **Cheap and
local.**

### C. VICE oracle for Doom (still BLOCKED)

`xscpu64` hangs DL at `$3093`; current cocotb/VICE-oracle setup can
only diff individual instruction sequences, not the full Doom run.
Per `project_doom_loader_body_match_500.md` we already know the CPU
microcode is correct on Doom paths. The bug is data-path (REU stores,
SuperRAM mapping, or hardware-only timing) — not CPU. So VICE diff
will keep matching even though hardware halts.

### D. `tools/doom_vice_*.py` — write a writer-PC tracer for `$00:$0707`

Adapt `tools/doom_vice_74_writers.py` (which traced `$0074-$0076`)
to `$00:$0707`. Run on hardware (when free) with the patched `loader.prg`
that breaks before the wedge. Identifies who SHOULD write the wait
variable and confirm whether it ever happens at all.

## What NOT to do next

- Don't pursue another RBF rebuild for "more vector backing" — NMI v2
  proved Doom isn't using vector installs. Adding more backed vectors
  is no-op.
- Don't keep guessing what `$0707` is from disassembly alone — the
  recompiler emits MIPS-load addresses based on its own RAM map. Get
  the ground truth from `recomp.exe` output (probe B above).
- Don't try `recomp_research/recomp.d81` boot sequence on hardware —
  the recompiler IS the runtime; running it as an app isn't useful.

## Files modified this session (final 8 commits)

| Commit | File(s) | Purpose |
|--------|---------|---------|
| `9a84085` | `fpga64_sid_iec.vhd` | `$D27C-$D27F` SuperRAM extent |
| `8d017b1` | `fpga64_sid_iec.vhd` | IRQ ack stub bytes |
| `246bd3c` | `fpga64_sid_iec.vhd` | IRQ trampoline bytes + install latch |
| `d179e1b` | `fpga64_buslogic.vhd` + `fpga64_sid_iec.vhd` | bank-$00 ROM shadow |
| `e8cbf39` | `fpga64_buslogic.vhd` | bank-$01 ROM shadow |
| `c591d33` | `fpga64_buslogic.vhd` + debug | bank-$Fx broad $6B-RTL stub |
| `edd36b5` | `fpga64_buslogic.vhd` | narrow stub to $F6-$FF |
| `095b176` | `fpga64_sid_iec.vhd` | NMI vector RAM-back v2 |

## Test artifacts

- `tools/doom_full/{shot,uart}_*` — 4-min Doom test (latest = NMI v2)
- `tools/doom_input_probe/{shot,uart}_*` — keyboard injection probe
- `tools/doom_extended/{shot,uart}_*` — 11-min Doom test (post-shadow)
- `logs/scpu_sweep_20260509T222751.csv` — sweep 9/10 PASS (post-NMI-v2)

## Memory updates needed before next session

- Add entry for `095b176` NMI v2 (RAM-back, no Doom impact): file
  `project_nmi_vector_v2_no_doom_impact.md` — captures the
  ".databank $ff" hypothesis and its refutation.
