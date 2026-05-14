# Session handoff — 2026-05-14 (post-v340m: stack leak + IRQ refire confirmed)

## Bottom line

The post-$0EED-fix black-screen wedge is **CPU aborts ORA at $0F:$F1DA after
opcode fetch** because IRQ is persistently asserted. v340l per-LO-nibble
cum-OR + bit-7 marker probe **definitively proved** that operand fetches at
$F1DB-$F1DF never happen on HW (V1-V3/Y/X stayed $00 despite the $80 marker
that would set if any fetch occurred).

v340m attempted to fix by routing IRQ → $00:$FF00 ack stub → JML $00:$0D40 →
Doom handler, but produced **stack leak ~$3FC bytes per UART line** while
still black-screen. Two simultaneous problems:
1. JML target $0D40 wrong — Doom installs at $0D3C (skips 3-byte prologue)
2. IRQ refires despite stub's full ack chain + $D01A=$00 mask → strongly
   suggests **FPGA's $D019 ack doesn't deassert irq_vic** (the suspicion
   already documented at video_vicII_656x.vhd:77)

## Probe series summary (this session)

| RBF | md5 | Probe / Edit | Key result |
|-----|-----|--------------|------------|
| v340g | a7354b... | $4000-$5FFF CPU write last-byte | V0=$00, ambiguous |
| v340h | b620b1... | Cum-OR CPU writes | V0=$FF (KERNAL+Doom pollution) |
| v340i | c7663c... | + VIC bitmap read cum-OR | V3=$00 → SDRAM bitmap really zero |
| v340j | b32f74... | Opcode-fetch latch at $F1DA-$F1DF | V0=$1F (matches VICE), V3/Y/X=$00 |
| v340k | ebd78b... | Restore `STA $00D01A=$00` at $FF1A stub | Delayed wedge ~30s, still wedges |
| v340l | da15a2... | Per-LO-nibble cum-OR + $80 marker | V1-V3/Y/X=$00 → **operand fetches NEVER fire** |
| v340m | 0bc331... | $FFEE/$FFEF → $00FF, stub `JML $00:$0D40` | Stub runs (PC=$FF04/$FF1B/$FF25), JML reaches $0D42, but SP descends $3FC/line, screen black |

## Hypothesis tree (current)

```
ORA $1F at $0F:$F1DA never completes
└─ CPU aborts after opcode fetch (v340l proved)
   └─ IRQ persistently asserted at instruction boundary
      ├─ Hardware ack via stub still leaves IRQ asserted (v340m proves
      │   refire continues despite $D019 STA write-1-clear)
      │   → most likely: FPGA $D019 doesn't deassert irq_vic line on
      │     SCPU writes (myWr_a phase mismatch?)
      └─ Hint at video_vicII_656x.vhd:77: comment explicitly states
         "Used to triangulate why SCPU's $D019 ack writes don't clear IRST"
         → this is a KNOWN suspected issue
```

## Uncommitted state

`C64_MiSTer/rtl/fpga64_sid_iec.vhd` has:
- $FF1A-$FF1D: `STA $00D01A` long instruction (v340k restore — kept)
- $FFEE/$FFEF: hardcoded $00FF (v340m revert of v340e — kept)
- $FF2A-$FF2D: `JML $00:$0D40` (v340m — kept, but target should be $0D3C)
- $0F:$F1Dx capture probe with cum-OR + $80 marker (v340l — debug only)

**Do not commit** until a fix lands. The $F1Dx probe is purely diagnostic.

## How to resume

The cheapest next probe is **fixing the VIC $D019 ack**. The VIC has
existing debug signals `dbg_d019_wr_pulse` (myWr_a fires at addr=$D019)
and `dbg_resetraster_pulse` (resetRasterIrq actually pulses). They feed
counters `vic_d019_wr_count_r` (VW field) and `vic_resetraster_count_r`
(VB/AC field). However, v304 overloaded these counters for DMA $0706
write capture — current UART VW/VB readings reflect DMA activity, not
the original VIC ack pulses.

### Recommended v340n

1. **Remove v304 overload** at fpga64_sid_iec.vhd:3299-3303 so VW/AC
   counters reflect the original VIC ack pulses.
2. **Keep v340l per-nibble probe** for $F1Dx fetch confirmation.
3. **Revert v340m's JML target to $0D3C** (not $0D40) — Doom installs
   at $0D3C.
4. Deploy. If VW (D019 writes) >> AC (resetraster pulses), confirms
   SCPU $D019 writes aren't being seen by the VIC's myWr_a → fix the
   VIC bus phase / timing for SCPU mode.

### Alternative v340n — diagnostic

Force `irq_vic_n='1'` at the c64.sv/fpga64_sid_iec.vhd top level (mask
VIC IRQ entirely). If Doom renders pixels, IRQ refire IS the wedge
cause and the fix is at the VIC ack path. If still black, renderer has
a separate problem.

## Don't repeat these mistakes

- Don't assume $D019 write-1-clear works for SCPU on this branch — the
  RTL comment at video_vicII_656x.vhd:77 explicitly flags it as
  suspected, and v340m's stack leak corroborates.
- Don't JML/JMP to $00:$0D40 in the stub — Doom's entry is $0D3C.
- The v340l cum-OR + bit-7 marker pattern is a great probe template
  for "did this case fire?" disambiguation — reuse it.

## Files

- Memory: `project_doom_v340j_byte_3_not_fetched.md`,
  `project_doom_v340l_*` (subsumed into v340j file),
  `project_doom_v340m_stack_leak_irq_refire.md`.
- UART captures: in conversation log + the v340l/m UART data already
  embedded in memory files.
- Screenshots: `tools/doom_full/shot_v340k_post_return.png`,
  `tools/doom_full/shot_v340m_post_return.png` (both all-black).
