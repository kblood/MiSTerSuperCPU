# v345e fix plan — Doom regression + kickstart wedge

## Doom regression — v345d → v345e fix (Option A)

### Root cause (off-hardware analysis, 2026-05-15)

The cpuDi mux change in `fpga64_sid_iec.vhd:1964-1966` causes the Doom
regression on v345d. Was added in v345c to support kickstart bootmap='1'
mode where the $F8:$00FC reset chain needs to fetch real EPROM bytes
from buslogic's `scpuRomData`. But the carve-out is unconditional, so
even with bootmap='0' (v345d's default), bank $F8-$FF reads come from
buslogic — which serves scpuRomData. 60% of the EPROM image is `$FF`
padding. Doom's 693 bank-$FF JMLs all target padding addresses
(`$FF:$6A6A`, `$FF:$FF00` etc.), so the CPU executes
`SBC $FFFFFF,X` chains there → state corruption → black screen.

On v344b, the carve-out didn't exist, so bank $F8-$FF reads hit
uninit SDRAM (= `$00` = BRK) → handled by `$00:$FF00` BRK ack stub
→ soft no-op. Doom rendered title screen.

### Proposed fix (Option A — minimal, MiSTer-testable)

`fpga64_sid_iec.vhd` line 1964:

```vhdl
-- v345c (2026-05-15): exclude bank >= $F8 ONLY when bootmap='1', so the
-- reset chain $F8:$00FC → $F8:$80C1 kickstart fetch gets real EPROM
-- bytes from buslogic's scpuRomData mirror. After kickstart clears
-- bootmap (STA $D07E with A=$00 in our impl), bank $F8-$FF reverts to
-- ramDin = uninit SDRAM = $00. Doom's $FF JMLs then BRK → $00:$FF00 ack
-- stub → soft no-op (matches v344b behaviour where Doom rendered title).
ramDin when (supercpu_en = '1' and addr_hi_816 /= x"00"
            and not (scpu_bootmap = '1' and unsigned(addr_hi_816) >= x"F8")) else
cpuDi_raw;
```

### Trade-off

- Doom: works (back to v344b behaviour)
- Wolf3D: same as v343/v344b — bank $F4/$F5/$FC reads serve `$00` after
  bootmap clears. Wolf3D recompiler dispatches to these addresses
  (Wolf3D had 67 JMLs to $F4, 98 to $F5, 49 to $FC); they BRK → ack
  stub → continue. Should not regress (it was already barely working).

### Better long-term fix (Option B, separate effort)

Static page-classification: add a 256-entry boolean table indicating
which scpu64.mif pages are CODE vs PADDING. Buslogic returns
`scpuRomData` for code pages, `$6B` (RTL) for padding pages.

Pages (from `tools/disasm_kickstart.py` analysis):
- CODE: `$00xx-$60xx`, `$80xx-$82xx`, `$FCxx`, `$FFEx-$FFFx`
- PADDING: everything else (~155 pages out of 256)

This makes BOTH Doom and Wolf3D's recompiler dispatches work cleanly:
real EPROM calls reach KERNAL routines, padding addresses act as RTL
no-ops.

## Kickstart wedge — v345c bootmap='1' (pending HW retest)

### Static-analysis findings

`tools/disasm_kickstart.py` confirmed the kickstart code at `$F8:$80C1`
in scpu64.mif:

1. SEI; CLC; XCE (native)
2. Set up SP=$01FF, DP=$0000
3. 3× MVN $01,$F8 (BASIC/KERNAL/CHARGEN shadow copies into bank $01)
4. SEP #$30, TDC, PHA, PLB → DBR=$00
5. STA $D07E (A=$00) → enable HW regs; our impl side-effect clears bootmap
6. STA $D0B6 (A=$00) → clear bootmap (redundant on our impl)
7. JSL $F8:$8148 (SIMM detect)
8. PHB, REP #$20, LDA $FFFC (=$FCE2 from KERNAL ROM), DEC, PHA, SEC, XCE, RTL

Stack at RTL (native SP=$01FC):
- $01FF=$00 (PHB pushed DBR)
- $01FE=$FC, $01FD=$E1 (PHA pushed $FCE1)

XCE→emu (SP preserved at $01FC because high byte was already $01).
RTL pops 3 bytes: PC LO=$E1, PC HI=$FC, PB=$00 → PC=$FCE2, PB=$00.
Lands at C64 KERNAL RESET entry in emu mode.

### Wedge symptom

PC bouncing $FF48-$FF58 (KERNAL IRQ entry vector at $FF48), $0314=$00.
Indicates IRQ fires before RAMTAS ($FD15) initialises $0314.

### Suspect list (need HW test to distinguish)

1. **Cold-boot IRQ source not cleared by kickstart**: VIC $D019 (raster
   pending bit), CIA1 timer A, CIA2 timer A. Kickstart doesn't ack
   these — KERNAL IOINIT/RAMTAS does. Window between RTL and ICR clear
   is the wedge target.

2. **65C816 P(2) I-flag glitch**: would require a GHDL bench to verify.
   Static reading of P65C816.vhd LOAD_P="101" (XCE) shows I preserved.

3. **bootmap not cleared at RTL time**: our impl clears bootmap as
   side-effect of $D07E STA with bit7=0 (line `fpga64_sid_iec.vhd:2019-2021`).
   Should be off by step 5 of kickstart. Verifiable on HW by reading
   $D0xx status after kickstart.

4. **Buslogic clauses overlapping**: with bootmap='0' the bootmap
   overlay clause shouldn't fire, BUT with v345d's widening to `$8000+`
   the clause's address window is now $8000-$FFFF instead of $E000-$FFFF.
   If `scpu_bootmap` is somehow stuck at '1' after kickstart, KERNAL
   $E000+ reads would still hit scpuRomData = EPROM bytes (which is
   $FF padding for most $Exxx-$Fxxx, since scpu64.mif only has code
   at $FC00-$FCFF + $FFE0-$FFFF in the top half).

### Test plan when MiSTer is free

Build v345e with Option A applied. Boot with bootmap='0' (default
v345d behaviour). Confirm:
1. tier3_mirror_test.prg → green border
2. doom_full_run.py → title renders at 240s (Doom regression FIXED)
3. Lorenz t65 + scpu suites → no regression

If all three pass: investigate v345c's bootmap='1' path next.
Specifically:
- Build with `scpu_bootmap <= '1'` at reset
- Probe scpu_bootmap state after kickstart RTL ($D0xx readback)
- UART instrument: latch P(2) at $FC..xx PC range to detect I-flag clear
