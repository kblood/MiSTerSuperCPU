# DL/SCPU debug session — 2026-04-30

## Bottom line
DL on `vanilla-cpu-swap` with SCPU=on is **not** broken by $DD00 value
corruption (overlay analysis disproved that). The real cause is that
**P65C816 emulation mode runs the DL gameplay code about 6x slower
than T65**, so cycle-exact raster IRQs mis-fire and split-bitmap
mode-switches land on the wrong scanlines. SCPU never reaches the
fully-rendered gameplay state — it shows a partially-decompressed,
mode-fragmented screen with one quarter of bitmap data and yellow
PETSCII text bleed in the rest. T65 on the same code reaches the full
title screen (castle, dragon, foliage).

Tasks updated: #31 (in_progress) carries this finding; #26 (fix P65C816
to match VICE on divergent instruction) is the next major step.

## How we got here

Started session with v207. Built a layered overlay diagnostic ladder
v207 → v218, all on `vanilla-cpu-swap`. RTL on disk = v218 state
(uncommitted). RBF deployed = v218.

| Build | Trigger / capture                                     |
|-------|-------------------------------------------------------|
| v207  | Per-value $DD00 PC latches P0..P3                     |
| v208  | Concurrent `dd00_pc_now` signal (fixed VHDL syntax)   |
| v209  | Per-value $DD00 8-bit counters                        |
| v210  | $D018 BPC (last-bad-write PC) + B counter + V latch   |
| v211  | 4-deep PC ring T0..T3, frozen on first $D018 != $18   |
| v212  | Trigger narrowed to `(cpuDo and $C0) /= $00`          |
| v213  | Trigger tightened to `(cpuDo and $C0) = $C0`          |
| v214  | Skip-first-16 to escape cold-boot loop                |
| v215  | Skip-first-4096 (cold-boot loop is tight)             |
| v216  | PC-filter on $9558 (mysteriously failed to fire)      |
| v217  | Value-filter on cpuDo=$D8                             |
| v218  | $D8 with skip-first-8 (current)                       |

## What the data showed

- $D018 ring on v218 froze at the legitimate cold-boot init at
  $9069/$906C/$906E/$9071/$9073 (CHRGET → DL entry, both CPUs run it).
  Both T65 and SCPU reach this code; both write $D8 once during init.

- Per-value $DD00 PC latches P0..P3 reveal the same 4 STA $DD00
  instructions on both CPUs:
    - $19BD (writes value-class 11)
    - $3105 (writes value-class 10)
    - $3205 (writes value-class 00)
    - $99BD (writes value-class 01)
  SCPU reports them at +3 PC offset because P65C816 latches PC
  post-fetch while T65 latches at SYNC=1 (instruction start).

- The visible "T65 DD=04, SCPU DD=02" overlay reading is sampling-
  phase artifact, NOT divergent code.

- **The real divergence:** per-value counter rates.
    - T65: each P0..P3 counter +224 per 1.2 s ≈ 187 writes/s/class
      → ≈ 750 $DD00 writes/sec total → ~12.5 writes/frame (≈ 1 per
      raster split — DL split-bitmap engine in full flight).
    - SCPU: each counter +32 per 1.2 s ≈ 27 writes/s/class
      → ≈ 110 writes/sec total → ~1.8 writes/frame.
    - Ratio: T65 ≈ 6.8× faster than SCPU on this exact code path.

- Visible screens confirm: T65 = full DL title screen
  (`tools/dl_screens_v218_t65/20260430_142039-dlair64ld.png`).
  SCPU at the same wall-clock instant = mostly black, garbled
  "DRAGON'S LAIR" text, partial bitmap top-quarter, yellow PETSCII
  text-mode glyphs in the lower half
  (`tools/dl_screens_v218_scpu/20260430_141934-dlair64ld.png`).

## Why it's a CPU throughput / cycle-count bug, not a memory bug

- Both CPUs see the SAME memory subsystem (bank $00 = BRAM, REU = SDRAM).
  No SCPU-specific stall in the bus.
- Both CPUs are clocked by the SAME `enableCpu` CE pulse
  (`fpga64_sid_iec.vhd:1053-1054`), gated by `supercpu_en`. Pulse rate
  identical when only one CPU is active.
- IRQ source is identical (line 1063 vs 1083: same `irq_cia1 and
  irq_vic and irq_n and irq_ext_n`).
- vanilla-cpu-swap base commit `cf49066` correctly fixed RDY-on-write
  (`rdy_gated <= rdy or not localWe`) so SCPU and T65 honor RDY the
  same way.

What's left: P65C816's microcode (`rtl/65C816/MCode.vhd`) drives
opcode duration via the number of micro-states. If emu-mode opcodes
take more micro-states than the NMOS reference, instructions take
more cycles. A 1-cycle-per-instruction overhead on average opcodes
adds up to dozens of scanlines of skew per IRQ — exactly the
fragmentation pattern we see on screen.

## Concrete next steps

1. **Add an opcode-count register to overlay.** 16-bit counter ticked
   on `opcode_fetch_pulse`. Display per-frame and as "PER FRAME"
   delta. Compare T65 vs SCPU on identical code (BASIC `READY.`
   prompt or DL entry). If SCPU/frame is meaningfully lower than
   T65/frame on the same code, cycle-count bug confirmed empirically.

2. **Audit `MCode.vhd` cycle counts** for the hot opcodes used by DL's
   split-bitmap raster IRQ:
   - `LDA #$xx` (immediate) — should be 2 cycles
   - `STA abs` ($DD00 / $D018) — 4 cycles
   - `LDA zp,X` / `STA zp,X` — 4 cycles
   - branches taken — 3 cycles (NMOS), 3 cycles (65C02), 4 in emu
     mode is wrong if it hits 4
   - `INX` / `DEX` — 2 cycles
   - `RTI` — 6 cycles
   - `JMP abs` — 3 cycles
   Reference: NMOS 6502 cycle table at
   https://www.masswerk.at/6502/6502_instruction_set.html

3. **Cheaper alternative** — port master's 32-entry crash-trace ring
   (REU $DF20-$DFA0) to vanilla-cpu-swap, freeze on a specific event,
   read it back from a tiny PRG that prints the ring to screen RAM.
   Gives PC + IR (instruction byte) for 32 consecutive opcode fetches.
   Combined with VICE PC trace of the same starting state, diff
   produces the first divergent PC — the exact instruction whose
   cycle count is wrong.

## RTL state on disk (uncommitted)

`v218`-equivalent. The trigger condition lines in
`fpga64_sid_iec.vhd:1245-1262` are parameterized scaffolding — change
the value/PC/skip count and rebuild to refire. Default state captures
$D018=$D8 with skip=8.

## Diagnostic tooling

- `tools/dl_triage_run.py` — deploys RBF, patches `cfg[10]`, MGL-loads
  REU+PRG, mbc-load_roms `dlair64ld.prg` for autoRUN, takes 15 burst
  screenshots 1.2 s apart. `--t65` for T65, no flag for SCPU.
  `--no-deploy` skips RBF re-upload.
- `tools/decode_overlay.py` — OCRs the 11-row 4×6 yellow overlay from
  PNGs. ROWS=11 currently. Fuzzy Hamming match per cell.
- All v218 captures retained at
  `tools/dl_screens_v218_t65/`, `tools/dl_screens_v218_scpu/`.

## Risks / unknowns

- PC-filter trigger (v216) silently failed: `dd00_pc_now=$9558` was
  observed in BPC latch but my comparator gate
  `if dd00_pc_now(15:0)=x"9558" and (23:16)=x"00"` never fired.
  Synthesis quirk or a one-clock-edge race I missed. Worth
  re-investigating before relying on PC-filtered triggers again.

- The 6× throughput ratio is suspicious — pure cycle-count divergence
  shouldn't be 6× on average code. Possible alternative: SCPU is
  taking a *different code path* (e.g., the IRQ entry pushes a
  different P, the handler reads it back, branches differently).
  An opcode-count register would distinguish "same code, slower" from
  "different code path".
