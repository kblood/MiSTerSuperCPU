# SuperCPU spec-gap implementation session — 2026-05-09

## Bottom line — Doom + Wolf3D unblocked at CPU level via 5 commits

This session implemented 5 SuperCPU spec gaps in sequence on the
`vanilla-cpu-swap` branch, each unblocking a downstream wedge:

1. **9a84085** — Populate `$D27C-$D27F` SuperRAM extent variables.
   ($00, $02, $00, $F6) so MIPS-recompiler runtime can size the heap.
2. **8d017b1** — IRQ ack stub at `$00:$FF00` (23 bytes, long-mode
   $D019/$DC0D/$DD0D ack + RTI). Doom past `music_num=-9` trap.
   Wolf3D past IRQ-storm wedge.
3. **246bd3c** — Native IRQ JML trampoline at `$00:$FCEE-$FCF1`
   (default `5C 00 FF 00` = JML to ack stub; latch flips on writes
   for software-installed handlers). Critical `emu_mode_816_i='0'`
   gate because KERNAL ROM has cold-start code at `$FCEE-$FCF1`.
4. **d179e1b** — Bank-$00 SRAM ROM-shadow (native-mode-gated). New
   buslogic clause routes SCPU CPU bank-$00 reads at ROM-shadowed
   windows ($A000/$D000/$E000+) to RAM-under-ROM instead of
   KERNAL/BASIC/CHARGEN bytes. **The big one** — fixes Doom's RTI
   from upper-page native stack returning to KERNAL bytes instead
   of pushed PC.
5. **e8cbf39** — Bank-$01 SRAM ROM shadow (Tier 2.1). When SCPU CPU
   reads bank $01 in native mode at ROM areas, return KERNAL/BASIC/
   CHARGEN bytes instead of SuperRAM SDRAM zeros. Defensive
   spec-compliance — non-regressive against sweep, didn't change
   Doom's blank-screen behavior, but matches real CMD's bank-$01
   pre-loaded SRAM mirror.

Final RBF: `29dd242cca7f42146aa4370ca98ce56b`, ALM 64% (26,781 / 41,910).
T65 + SCPU cold boot READY both modes. Wolf3D regression-free
(still renders title-screen content with bank-$01 shadow active).

## Doom result

- Pre-shadow (commit 8d017b1): wedged in tight loop at `$59:$4252-$4278`
  executing data tables. SP wandered to `$00:$FFF9`; RTI was popping
  KERNAL ROM bytes instead of pushed PC.
- Post-shadow (commit d179e1b, 11-min extended test):
  - PC at `$00:$FF00..$FF16` (ack stub) cycling correctly
  - SP `$01F8`-`$FFE9` works (upper-page stack pops RAM bytes)
  - J ring `EE0B / EE37 / EE75 / EE87 / EEC9 / EED5` — Doom installed
    multiple JML targets via the RAM-backed trampoline at `$FCEE`
  - AC counter advances `0001 → 5329` over 11 min = active execution
  - Screen: cleared dark blue, no game frame visible, no error text

Hypothesis for blank screen: Doom may write bitmap data to bank ≠ $00
(SuperRAM SDRAM, which VIC cannot see). Real CMD shadows bank $01
SRAM into VIC's view; ours doesn't (Tier 2.1 spec gap). Or Doom is in
extended init / waiting for input. Need to read VIC `$D011` / `$D018`
or peek `$0400` / candidate bitmap bases via a non-disruptive probe.

## Wolf3D result

- Pre-shadow: `$00:$FF00` IRQ-storm wedge.
- Post-shadow: PC progressed `loader → bank $20 → $2C → IRQ handler at
  $XX:$0047/$0069`. **Renders title-screen content** — dense PETSCII
  "C" wall pattern + text block in VIC text mode. Color palette
  shifts between snapshots = ongoing VIC writes. No advancement past
  title screen (input-wait?).

## What NOT to do next

- Don't pursue REU coherency snoop (Tier 1.1) — REU DMA writes go
  through the same `cpuAddr/cpuDo/cpuWe` mux as CPU writes and land
  in `c64_ram64k` via `cs_ramLoc`. Already coherent.
- Don't pursue bank $F6-$F7 reservation (Tier 1.3) — Doom only writes
  banks $02-$87 per `doom.reu` non-zero analysis. Out of scope.
- Don't push trampoline-install path further until bank-$01 ROM shadow
  is in place — install location matters for game compatibility.

## Recommended next steps (in order)

1. **Probe Doom's VIC state without disrupting it.** Add a temporary
   debug-overlay field that reports `$D011 / $D018` live, OR write a
   tiny probe PRG and inject via mtype while Doom is paused (won't
   work — Doom runs continuously).
   Better: read `$0400` (text screen RAM) and `$D018` directly via a
   short BASIC program AFTER the test, by switching to T65 mode but
   keeping SDRAM intact (deploy preserves SDRAM per
   `project_sdram_survives_deploy`).

2. **Bank-$01 SRAM ROM shadow (Tier 2.1).** Real CMD's bank $01 has
   KERNAL/BASIC/CHARGEN copies pre-loaded so SCPU CPU reads at
   `$01:$E000-$FFFF` get KERNAL bytes. Our bank $01 = SuperRAM SDRAM
   (zeros at boot). If Doom's translated MIPS reads `$01:$Exxx` for
   any reason (lookup tables, recompiler runtime), gets garbage.
   Implementation: add cpuDi mux clause when `addr_hi_816='01' AND
   addr in ROM area` returning ROM bytes from existing romData/
   charData/etc. Or pre-load bank $01 SDRAM with ROM contents at
   boot via a one-shot DMA.

3. **Joystick injection for Wolf3D**. Wolf3D shows title screen — try
   pressing fire (joystick port 1 button) to advance. Need to wire
   joy port via MiSTer (probably via `joy_*` cfg bits or a `keys`
   sequence that sets joy bits via CIA1).

4. **Doom rendering hypothesis check**. Hex-dump bank-$00 RAM at
   `$0400` (default text screen) and `$4000-$5FFF` (common bitmap
   base) after Doom has been running. If bitmap bytes are present
   somewhere VIC can't see, that's the bank-$01 issue. If bitmap
   bytes ARE in `$4000-$5FFF` but VIC isn't using that bank, it's a
   `$D018 / CIA2 PRA` configuration issue.

## Files modified this session

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — IRQ ack stub, trampoline,
  scpu_native_mode wiring, $D27C-$D27F clauses
- `C64_MiSTer/rtl/fpga64_buslogic.vhd` — bank-$00 ROM-shadow clause,
  scpu_native_mode port
- `CLAUDE.md` — agent cooperation section
- `docs/agent-cooperation.md` — copied from CD32 project

## Test artifacts

- `tools/doom_full/{shot,uart}_*` — 4-min Doom test (post-shadow)
- `tools/doom_extended/{shot,uart}_*` — 11-min Doom test
- `tools/wolf3d_full/{shot,uart}_*` — 4-min Wolf3D test
- `tools/rom_shadow_test/boot_{t65,scpu}.png` — cold boot READY
- `logs/scpu_sweep_20260509T024329.csv` — regression sweep 9/10 PASS
- `rbf_archive/rom_shadow_native_5ef026f9.rbf` — final shipped RBF
