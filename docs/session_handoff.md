# Doom debug — 2026-05-11 v299 lands, BOTH wedges cleared

## Bottom line: v299 clears the SECOND wedge — Doom back at music-number trap

v299 commit `18068b8`, RBF `94b6c3c0d4f8d1585e7a1b269073b965`.
ALM 64% (unchanged), RAM 73% (EPROM dprom from v298 retained).

Two-byte revert at `fpga64_sid_iec.vhd:1648-1651`:

```
$FF15  $0E  ->  $00     ; v297 $DC0E low byte -> v299 $DF00 low byte
$FF16  $DC  ->  $DF     ; v297 CIA1 base    -> v299 REU base
```

Restores the `LDA $00DF00` REU ack that v297 removed in error.

## How we found this

`tools/doom_v298_transition_zoom.py` captured 45s of continuous
UART starting at t=125s post-load (no `head -c` truncation),
catching the previously-missed bank-$20 → bank-$0F transition:

```
F:1945 PC:2B2292 ... SP:007B ... J:22B4 DB94 DBCE DBAC
F:1946 PC:2B2292 ... SP:0065 ...    (SP delta -$16)
F:1947 PC:2B2292 ... SP:004F ...    (SP delta -$16)
F:1948 PC:2B2292 ... SP:0039 ...    (SP delta -$16)
F:1949 PC:2B2292 ... SP:0023 ...    (SP delta -$16)
F:194A PC:2B2292 ... SP:000D ...    (SP delta -$16)
F:194B PC:00FF15 ... SP:FFF9 ...    (WRAP via $FFFF, in ack stub)
F:194C PC:00FF19 ... SP:FFF9 ...    PB now = $0F, BRK-march starts
```

22 unbalanced bytes per vblank = 5-6 IRQ entries unbalanced.
Mechanism: Doom's recompiler armed a REU FETCH whose completion-
IRQ fires when transfer ends. Our v297/v298 stub doesn't read
$DF00 → REU IRQ stays asserted → refires immediately after every
RTI. PHP+PHA balance pop, but stack overflows from the IRQ entry
push-4 every time.

## v299 result (same probe)

| Metric | v298 | v299 |
|--------|------|------|
| Bank-$0F transition seen | YES (frame 248) | **NO** |
| PC dominant bank | $0F (BRK-march) | $2C (1093/1339 frames) |
| SP behavior | decreased $16/vblank | stable at $FFFF |
| Final halt | $0F:xxxx BRK-march | $2C:$A95C JML self-loop |
| Screen | blank blue rect | **"Error: Bad music number -9"** |

## Where we are now

Back at the v286-era trap. Every wedge fix is now landed:
- $00:$FFE4..$FFEF native vector intercept (v286)
- bank-$00 SRAM ROM-shadow (d179e1b)
- bank-$01 SRAM ROM shadow (e8cbf39)
- bank $F6-$FF $6B-RTL stub (edd36b5)
- v295 PB-based pc_main_r gate
- v296+v299 27-byte ack stub with REU $DF00 ack
- v298 EPROM dprom at bank $F8

The music-number `-9` halt is **not** a CPU microcode issue per
existing cocotb+VICE lockstep proofs:
- bank-20 prologue MATCH 15574 instr
- gameplay $2A:$55A3 MATCH 5000 instr
- loader body MATCH 500+5000 instr

VICE xscpu64 with same `loader.prg + doom.reu` reaches PB=$2A
PC=$55A1 in NATIVE mode with bitmap VIC ($D011=$C9). Doom WORKS
on VICE. So our hardware diverges from VICE in some specific
code path or data load between loader handoff and the
music-number lookup.

## Next probes

Per existing memory:

1. **Writer-PC ring on $FFF7 sentinel emission** — track which
   instruction stores the $FFF7 "lookup failed" value that
   becomes the -9 music_num display

2. **REU→SuperRAM transfer verification** — peek SuperRAM at
   the music-number data location vs REU contents. Known
   precedent: $00:$6C00 `$AB,$AB,$AB,$00` transfer corruption

3. **HW-vs-VICE I/O divergence** — what does Doom read from
   $D0xx / $DCxx / $DDxx that differs between VICE and our
   hardware path?

## Files for next session

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1648-1651` — v299 stub bytes
- `tools/doom_v298_transition_zoom.py` — the diagnostic that
  caught the SP-leak wedge (template for future high-resolution
  capture)
- `tools/doom_full/shot_v299_after_test.png` — music-number halt
  screen
- `project_doom_v293_85a1_chain_decoded.md` — error chain
  disassembly
- `project_doom_vice_oracle_runs_doom.md` — VICE oracle reference

## Build state

- Branch `vanilla-cpu-swap`, tip commit `18068b8`
- ALM 64%, RAM 73%, build 11:40
