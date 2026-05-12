# Session handoff — 2026-05-12 (v313 cleared IRQ wedge, back at music_num=-9)

## Bottom line

The v305-v312 BRK/IRQ wedge cluster is **fully collapsed**. v313 extended
the `$FF00` ack stub from 27 to 43 bytes (`$FF00-$FF2A`) with hard
IRQ-source disables (`STA $D01A=$00`, `STA $DC0D=$7F`, `STA $DD0D=$7F`)
and removed the `emu_mode_816_i='0'` gate from all stub bytes. Doom now
reaches the **documented `music_num=-9` trap** at `$2C:$A95C` — same
state as the v286/v296 baseline before the recent regression cluster.

The trap chain is canonical (`$85A1 → $85B6 → $85E8 → $85F6 → $A95C`
self-trap JML) and the on-screen text confirms `Error: Bad music
number -9`. CPU/wedge-control work has produced an identical
end-state to v286 — the open question is now ONLY the music_num
producer.

## Working state

- **HEAD**: `3c4609f` on `vanilla-cpu-swap`
- **Deployed RBF**: md5 `1a93f82b7939fac96ffdf983d0fb43a1`, 3,860,772 bytes
- **Source**: clean
- **Trace**: `tools/doom_full/uart_240s.txt` shows `N:$2C:$A95C` pinned

## Why v311/v312 didn't work and v313 did

- v311 forced BRK vector reads `$00:$FFE6/$FFE7 → $00/$FF`. Broke the
  `$0705/$0B05` BRK chain, but Doom-installed `$00:$AF00` IRQ handler
  was just `PLP; RTI` (no source ack) → infinite IRQ refire loop.
- v312 mirrored the trick to `$FFEE/$FFEF` IRQ vector. Trace was
  **byte-identical** to v311. SP-delta analysis: post-RTI `SP += 3` =
  emu-mode RTI semantics — but our stub bytes were native-gated and
  still visible. **Contradiction** → XCE-drop bug had desynced internal
  EF flag from `emu_mode_816_i` output.
- v313 removed the emu-mode gate AND added the IRQ-source disable
  sequence to the stub. Both changes were needed: ack alone doesn't
  stop a continuously-firing source, and the gate prevented the stub
  from running in whatever mode the CPU thought it was in.

## What v313 trace shows at t=240s

```
F:3B59 PC:2CA95F P:00 V:E8 E8 F6 0E SP:FFFF WP:2C8605 OP:5C5C
CY:5B71 J:A95C A95C A95C A95C M:85A1 85B6 85E8 85F6 G:7D 07 00
N:2CA95C I:00FF2A B:58 VW:000C VB:00FF W5:8D 7A D0 A9
```

- N = `$2C:$A95C` (the JML self-trap, pinned)
- M ring = the documented `$85A1→$85B6→$85E8→$85F6` error chain
- J ring = last 4 JMLs, all `$A95C` (target of self-trap)
- I = `$00:$FF2A` (RTI inside our ack stub — IRQ infrastructure healthy)
- W5 = `8D 7A D0 A9` (Doom's `STA $D07A` speed-write, ran post-recompiler)

Screenshot: white text "Error: Bad music number -9" on dark blue.

## Open issue — music_num producer

Per memory (`project_doom_v293_85a1_chain_decoded.md`,
`project_doom_v286_brk_loop_broken.md`, the 6 cocotb+VICE lockstep
proofs in `project_doom_*_match*.md`):

- CPU microcode is **proven correct** on Doom code paths.
- Bug is HW-only / REU→SuperRAM data-path related.
- music_num=-9 is a `$FFF7` "lookup failed" sentinel that appears at
  21 sites in REU.
- Producer ran during **loader phase before the trap**.
- VICE oracle for Doom xscpu64 hangs at FLI raster IRQ, can't be used
  as oracle for music_num divergence.

## Integrity test PRG built — deployment blocked

Built two test PRGs (commit `71261e5`):

- `tools/superram_minimal.prg` (53 bytes): minimal SuperRAM round-trip
  (long-store + long-LDA) with tripwires at `$0400-$0403`.
- `tools/reu_superram_integrity.prg` (252 bytes): full pipeline —
  ramp write, REU STASH, REU FETCH, SuperRAM round-trip, mismatch
  count. Output to screen `$0400-$0405`.

**Deployment friction found this session**:
1. `mbc load_rom` (used by `python tools/mister_debug.py load_prg`)
   suppresses debug UART output. After load_rom, UART goes silent
   even though VIC-II keeps running (single keypress test shows
   `X` appears on screen).
2. After `load_rom`, `python tools/mister_debug.py keys 'SYS 2061\r'`
   does not produce a visible "SYS 2061" command echo on screen
   across multiple attempts. mtype.py runs without error but the
   keys don't seem to reach BASIC reliably.
3. The mbc-corrupts-BASIC-stub note in `CLAUDE.md` is known, but
   SYS-keypress is the documented workaround — and that's failing
   too in this session's tests.

## Next-session priorities

1. **Get the integrity test PRG running**. Options:
   - **Self-displaying loop**: rewrite both PRGs to spin forever
     at the end, painting the result onto the entire screen RAM
     ($0400-$07E7) so any screenshot shows the result without
     needing BASIC to print READY. Avoids `mbc load_rom` race
     with BASIC.
   - **MGL autorun**: create an MGL that loads the PRG via
     `<file>` tag (similar to how doom.reu is loaded). Stock
     MGL loaders DO process `<file>` tags via the pipe (see
     CLAUDE.md "Loading .reu files" section).
   - **Read screen RAM via SSH**: install a small helper on
     MiSTer that reads `/dev/fb0` or VRAM, OR use the existing
     `python tools/mister_debug.py screen` and post-process the
     PNG to identify written byte values (visually).

2. **Don't blindly rebuild more probes** — the music_num search has
   consumed many sessions already with the same dead-end shape. Before
   another wedge-instrumentation pass:
   - Re-read `project_doom_v293_dispatcher_pointer_smoking_gun.md`,
     `project_doom_v293_85a1_chain_decoded.md`, and the lockstep proofs.
   - The CPU is correct. So the producer of `$FFF7` is reading the
     wrong byte from memory at runtime. That implies REU→SuperRAM
     transfer corruption OR a memory-aliasing bug.

3. **Stop chasing music_num via UART rings.** The wr02/wr03 ring
   approach has been tried with multiple filters (PBR=$2B, PBR=$2C,
   unfiltered). It hasn't found the producer because the producer is
   probably one of thousands of generic byte stores that look identical
   to every other store. A REU→SuperRAM integrity test is more
   discriminating — assuming we can get it running.

## Commits this session

```
71261e5 debug/doom: REU→SuperRAM integrity test PRG (WIP — deployment friction)
7f355aa docs/session_handoff: v313 cleared IRQ wedge, back at music_num=-9
3c4609f verif/doom: v313 — extended ack stub clears IRQ wedge, reaches music_num=-9
a9b4fda verif/doom: v312 trace — IRQ vector force at $FFEE/F unchanged
5ab1fab verif/doom: v312 — force IRQ vector reads to $00:$FF00
37272eb verif/doom: v310→v311 — wedge shifts $0705→$0B05, force BRK→$FF00
```

## Memory files updated/created this session

- `project_doom_v311_irq_wedge_at_af00.md` — NEW. v311 progress + new IRQ wedge.
- `project_doom_v312_emu_mode_wedge.md` — NEW. SP-delta contradiction; XCE-drop hypothesis.
- `project_doom_v313_irq_wedge_cleared.md` — NEW. v313 success state, back at music_num=-9.
- `MEMORY.md` — top entries updated to reflect v311-v313 chain.
