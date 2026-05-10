# Doom debug — 2026-05-10 BRK/RTI cocotb LANDED, microcode CLEAN

## Bottom line: hardware halt is **IRQ-refire chain**, not microcode bug

`sim/cocotb/tests/test_brk_native_rti.py` LANDED 2026-05-10. Two tests
both PASS:

- **Test 1** (CLI before JML): native BRK at `$41:$DB93` → ack stub at
  `$00:$FF00` → RTI returns to `$41:$DB95` with **P=$23 / I=0**. RTI
  pops the pushed P verbatim, including the I-bit. Microcode is correct.
- **Test 2** (`IRQ_N` held low, simulating an unacked IRQ source):
  reproduces v294 hardware pattern EXACTLY:
  ```
  $DB93 fetches=19, $DB95 fetches=0, RTI fetches=18, $FF00 entries=18
  ```
  CPU loops: BRK→ack stub→RTI→IRQ refires (still asserted, I=0 popped)
  →handler→RTI→IRQ refires… Main never advances past $DB95.

## Reframe of v294 hardware data

`pc_main_r <= cpu_pc_now` is gated by `cpu_p_now(2)='0'` (I-flag clear,
fpga64_sid_iec.vhd:2604-2616). Two scenarios both produce "pc_main_r
frozen at $DB93":

1. **Main runs with I=1** (recompiler convention) — pc_main_r blind.
   CPU may be running fine; the latch never updates.
2. **IRQ source not acked → IRQ refires every RTI** — main never
   reaches I=0 fetch in caller context. CPU is wedged in a hot IRQ
   loop. **Test 2 demonstrates this.**

The trace_op ring data (`E248 AFAF 2840 1D00` across 70 vblanks) is now
fully consistent with scenario 2 — what we see is the IRQ stub's own
fetches plus the `1D 00` pair that happens once per refire when the
main thread momentarily emits a non-stub byte (likely the JIT trampoline
target byte at $FCEE if the latch flipped to RAM-backed).

## What this RULES OUT

- "P65C816 BRK pushes wrong P" — cocotb shows it pushes verbatim.
- "RTI doesn't restore I=0" — pops D_IN(2)→P(2) verbatim
  (P65C816.vhd:511, MCode.vhd:600).
- "RTI in native mode is broken" — Test 1 returns to $DB95 perfectly.

## What this RULES IN

The IRQ ack stub at `$00:$FF00..$FF16` (synthesized in
fpga64_sid_iec.vhd:1581-1633) reads `$D019`, `$DC0D`, `$DD0D`. Some IRQ
source is NOT being cleared by these reads/writes. Candidates:

1. **VIC raster compare keeps re-firing** — `STA $D019` clears IRST
   flags but the next raster line still satisfies the compare, re-arming
   immediately. The real CMD SCPU EPROM must do more: maybe rewrite
   `$D012` (raster compare) past current line, or clear the enable mask.
2. **NMI source still active** — but NMI uses `$FFEA/EB`, separate
   path. If $FFEA captured a corrupted vector (BRK push wrap could
   write $00:$FFEA — see `scpu_nmi_vec_lo` capture at
   fpga64_sid_iec.vhd:1712), NMI handler is wrong but IRQ should still
   work. Probably not this.
3. **Expansion port IRQ (REU IRQ?)** — REU has an IRQ-mask register at
   `$DF09`. If REU IRQ enabled and a transfer-complete fires, our stub
   never reads `$DF09` to ack. Plausible since loader runs many REU
   FETCHes.
4. **CIA timer-interrupt re-arms** — LDA $DC0D acks the CIA1 ICR but
   if a CIA timer is freerunning and underflows again, IRQ refires on
   the next underflow. Real SCPU handler may stop the timer.

## Probe priority queue

### Probe A: Hunt for unacked IRQ sources

Scan the actual hardware UART for non-zero post-halt values of:
- VIC `$D019` (after STA, should be $00 or near-$00)
- VIC `$D011` raster IRQ enable bit
- VIC `$D012` raster compare value
- CIA1 `$DC0D`, CIA2 `$DD0D` ICR
- REU `$DF00` status

We have these registers visible in fpga64_sid_iec.vhd debug overlay
already (need to confirm) — if not, surface to UART.

### Probe B: Remove I=0 gate on pc_main_r temporarily

If main is actually doing something OTHER than BRK-looping (e.g., legit
recompiler code with SEI'd I=1), removing the gate would show the real
PC distribution. Edit fpga64_sid_iec.vhd:2604-2609 to drop the
`cpu_p_now(2) = '0'` check and capture every fetch. One-line RTL
change, ~10 min build.

### Probe C: Improve the IRQ ack stub

Make the stub clear ALL plausible sources at once:
```
$FF00: 08           PHP
$FF01: E2 30        SEP #$30
$FF03: 48           PHA
$FF04: AF 19 D0 00  LDA $00D019
$FF08: 8F 19 D0 00  STA $00D019    ; ack VIC
$FF0C: AF 0D DC 00  LDA $00DC0D    ; ack CIA1
$FF10: AF 0D DD 00  LDA $00DD0D    ; ack CIA2
+ NEW: AF 00 DF 00  LDA $00DF00    ; ack REU + auto-clear status bits
+ NEW: A9 00        LDA #$00
+ NEW: 8F 11 D0 00  STA $00D011    ; disable VIC raster IRQ enable
$FF14: 68           PLA
$FF15: 28           PLP
$FF16: 40           RTI
```
Synthesize the new stub in the read-mux intercept. Tests whether *any*
one of these candidate sources is the offender.

### Probe D: Hunt $FCEE-$FCF1 indirect writers in REU (deferred)

Original task #2. Less urgent now — `1D 00` in trace ring is
explainable by IRQ-refire pattern alone. Revisit only if Probe A/C
don't yield.

## Files updated this session

- `sim/cocotb/tests/test_brk_native_rti.py` — NEW, 2 tests both PASS
- `sim/cocotb/Makefile` — added `test-brk-native-rti` target
- New memory entry: `project_doom_brk_rti_microcode_clean.md`
- MEMORY.md: promoted microcode-clean finding to top of Doom Status

## Known dead-ends (do not revisit)

- "P65C816 native BRK bug" — refuted by cocotb Test 1
- "RTI doesn't restore I-flag" — refuted by cocotb Test 1
- All earlier wait-loop / JIT-template / $0707 entries — see prior
  handoff for full list

## Open question

**Which IRQ source is unacked by the stub?** Probe A or Probe C will
tell. Probe C is more actionable (single ~10 min build to test).
