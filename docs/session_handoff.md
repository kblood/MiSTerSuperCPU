# SuperCPU spec-gap implementation session — 2026-05-09

## Bottom line — Doom + Wolf3D unblocked at CPU level via 6 commits

This session implemented 6 SuperCPU spec gaps in sequence on the
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
6. **c591d33** — Bank $F0-$FF $6B-RTL stub + VIC bank-select UART
   probe. Real CMD has CMD-OS ROM in banks $F0-$FF; ours had SDRAM
   zeros, so Doom JMLs to e.g. $FC:$85A1 walked SDRAM zeros executing
   $00=BRK forever (pc_main pegged at $FC:$EE6D..$EEF9). New buslogic
   clause returns $6B (RTL) for SCPU CPU reads at bank $F0-$FF in
   native mode — JSL frames bounce back, JML targets pop a recent
   return. Doom's main thread escapes the bank-$FC wedge; now writes
   $D011=$00 ($DEN=0$ display BLANKED, mid-config), $D018=$10 (screen
   $C400), $DD00=$10 (VIC bank 3). pc_main moves to $00:$0074 — the
   JML[$74] dispatcher scratchpad. The $6B byte appears in V ring as
   data corruption of dispatch targets — Doom reads bank-$Fx as data,
   gets stub byte, computes wrong dispatch. Companion VIC-bank probe
   adds `D1:## D8:## C2:##` to UART line (reuses obsolete AW/PA bytes).

Final RBF: `ae0df95c8fac88a9a2b80adb5dbe055c`, ALM 64% (26,744 / 41,910).
T65 + SCPU cold boot READY both modes. Wolf3D regression-free (still
renders title-screen content). Sweep 9/10 PASS (same single
pre-existing `vanilla_basic` UART-format fail).

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

- Post-bank-$01 + bank-$Fx stub (commit c591d33): pc_main moved
  $FC:$EE6D → $00:$0074 (JML[$74] dispatcher). VIC config NOW
  reached: D1=$00 ($DEN=0$), D8=$10 (screen $C400), C2=$10 (VIC
  bank 3). Screen pure black (display blanked mid-config). V ring
  shows $6B (RTL stub byte) being read as data and corrupting
  dispatch. Forward progress, NEW blocker = data-byte reads from
  bank $F0-$FF need real CMD ROM contents.

Hypothesis for blank screen (current, 2026-05-09 c591d33): Doom calls
CMD ROM library routines that compute results consumed downstream.
Our $6B stub means routines "return" without effect; A/X/Y stay
garbage; subsequent `STA $0074 / STX $0075 / JML [$74]` lands at
garbage. VICE's open SCPU64 v0.07 ROM (md5 006862e9...) is mostly
$FF past $84FF — no usable substitute; the proprietary CMD ROM is
required for Doom to render.

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

1. **Last-bank-$Fx-call probe.** Add latches in `fpga64_sid_iec.vhd`
   that capture the JML/JSL operand bytes (target bank $Fx + addr +
   caller PC) on every cross-bank fetch into bank $F0-$FF. Surface in
   UART. Identifies the small set of CMD ROM routines Doom actually
   invokes at runtime (most static $5C/$22 occurrences in REU are
   noise from data bytes mistaken for opcodes). If <20 distinct
   routines, hand-written shims are feasible. If hundreds, dead end.

2. **Joystick injection for Wolf3D.** Wolf3D shows title screen but
   doesn't advance — likely waiting for fire button. Investigate
   joy_0 wire in c64.sv, see if MiSTer cfg bits or keyboard sequence
   can trigger CIA1 PRA1 bit 4 (fire).

3. **CMD SCPU64 ROM acquisition.** Open V0.07 ROM (VICE) is mostly
   `$FF` past `$84FF`. Real CMD ROM is proprietary (CMD/CMD-Maurice
   Randall). Without it, Doom cannot complete its CMD-OS dependency
   chain. Possible paths: (a) implement enough CMD-OS routines as
   hand-written 65C816 stubs in an embedded ROM, (b) acquire the
   real ROM image (legal status unclear).

4. **Cocotb diff harness for Doom's specific failure.** Per existing
   memory, P65C816 microcode is proven correct on Doom paths via
   lockstep with VICE. If we narrow to the specific instruction
   sequence around the JML[$74] dispatcher confusion, we may find
   a CPU-level divergence the lockstep harness missed. Lower-priority
   than (1).

## Files modified this session

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — IRQ ack stub, trampoline,
  scpu_native_mode wiring, $D27C-$D27F clauses, $D011 latch + port
- `C64_MiSTer/rtl/fpga64_buslogic.vhd` — bank-$00 ROM-shadow clause,
  bank-$01 ROM-shadow clause, bank-$Fx $6B-RTL stub clause,
  scpu_native_mode port
- `C64_MiSTer/rtl/debug/{debug_pkg.svh, debug_uart_pool_fmt.sv,
  capture/cap_vic_wr.sv}` — VIC-bank probe (D1/D8/C2 in UART)
- `C64_MiSTer/c64.sv` — wires for `scpu_dbg_d011`
- `CLAUDE.md` — agent cooperation section
- `docs/agent-cooperation.md` — copied from CD32 project

## Test artifacts

- `tools/doom_full/{shot,uart}_*` — 4-min Doom test (latest = post-c591d33)
- `tools/doom_extended/{shot,uart}_*` — 11-min Doom test (post-shadow)
- `tools/doom_vic_probe_baseline/{shot,uart}_*` — pre-bank-$Fx-stub baseline
- `tools/doom_bank_fx_stub/{shot,uart}_*` — post-bank-$Fx-stub evidence
- `tools/wolf3d_full/{shot,uart}_*` — 4-min Wolf3D test (post-c591d33)
- `tools/rom_shadow_test/boot_{t65,scpu}.png` — cold boot READY
- `tools/doom_vic_probe.py`, `tools/find_jml_bank_fx.py`,
  `tools/find_ee1d_xrefs.py` — analysis tooling
- `logs/scpu_sweep_20260509T024329.csv` — regression sweep 9/10 PASS
  (post-shadow)
- `logs/scpu_sweep_20260509T091508.csv` — regression sweep 9/10 PASS
  (post-bank-$Fx-stub)
- `rbf_archive/rom_shadow_native_5ef026f9.rbf` — bank-$00 shadow RBF
- `rbf_archive/bank01_shadow_29dd242c.rbf` — bank-$01 shadow RBF
- `rbf_archive/bank_fx_rtl_stub_ae0df95c.rbf` — final shipped RBF (c591d33)
