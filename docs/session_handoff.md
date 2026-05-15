# Session handoff — 2026-05-15 (v345e/f/g build cycle)

## Bottom line

**v345g (rebuild of v345e source) is the current best state.** Building now (or
already built — check `C64_MiSTer/output_files/C64.rbf`).

- ✅ Tier 3 mirror PASSES (green border, screen visible) — proven on v345e.
- ✅ Doom no longer SBC,X-corrupted — cpuDi mux gate on bootmap fixes the
  v345d regression where bank-$FF JMLs hit EPROM `$FF` padding.
- ⚠️ **Doom still black at 240s.** CPU healthy in JIT
  (PC bouncing $2C:$2Exx-$34xx, M ring $0D6C IRQ handler, F counter ~50Hz)
  but DD00 stuck at $02 (no page-flip), VW=AC=$18DF=6367 IRQs/240s = ~26Hz
  average (bursty). Symptom matches v345d regression even with the gate
  applied. Likely raster IRQ ($D019 bit0) not firing reliably; CIA1 timer A
  IRQ alone won't drive Doom's double-buffer page-flip.
- ⚠️ **v345c bootmap='1' kickstart→KERNAL wedge unsolved.** v345f tried
  restoring bootmap='1' (matching v344b) + the v345e gate — wedges mid-flight
  because the gate cuts $F8+ to ramDin the moment kickstart clears bootmap
  via `STA $D07E`, while CPU is still executing at $F8:$80FA+. Symptom: SP
  runaway ($D82D→$D5D1), VW>>AC (raster IRQ flood without acks), KERNAL
  $0314 vectors never initialised.

## v345g — applied fix (Option A, gate on bootmap)

`fpga64_sid_iec.vhd:1969-1971`:
```vhdl
ramDin when (supercpu_en = '1' and addr_hi_816 /= x"00"
            and not (scpu_bootmap = '1' and unsigned(addr_hi_816) >= x"F8")) else
cpuDi_raw;
```

`fpga64_sid_iec.vhd:1985-1997`: `scpu_bootmap <= '0'` at reset.

## What v345e/g fixes

The v345c cpuDi mux change unconditionally routed bank-$F8+ reads to
`cpuDi_raw` (buslogic's `scpuRomData`). With v344b's EPROM-mirror clause
(buslogic returns `scpuRomData` for `(native_mode='1' OR bootmap='1') AND
bank>=$F8`), this meant Doom's 693 bank-$FF JMLs and 433 JSLs hit `$FF`
padding (60% of scpu64.mif). The padding executes as `SBC long,X` chain
(opcode `$FF` = SBC long,X) which trashes A register and advances PC by 4.
Doom's runtime state corrupted → black screen.

v345e/g's gate routes bank-$F8+ reads to `ramDin` (uninit SDRAM = `$00` =
BRK opcode) when `bootmap='0'`. Doom's bank-$FF JMLs then BRK → $00:$FF00
ack stub → soft no-op (matches v344b pre-v345c behaviour). Tier 3 mirror
test passes; Doom's CPU stays in legitimate JIT code.

## What remains black

Doom 240s UART (`tools/doom_full/uart_240s.txt`):
- F:3BE0 (15k frames in 240s ≈ 50 Hz frame rate)
- PC:2C35BE (JIT main code in bank $2C)
- VW:AC:$18DF (6367 IRQs total in 240s ≈ 26 Hz average; bursty within a
  capture window 100/s spikes)
- DD00 stuck $02 (VIC bank 1, no $00 alternation — page-flip dead)
- D011=$3B, D016=$D8, D018=$80 (MCM bitmap mode set up correctly)

26 Hz IRQ rate hypothesis: CIA1 timer A fires reliably (60 Hz on PAL → 26
average with periodic dropouts), but raster IRQ doesn't drive Doom's
page-flip at $80:$0B40 (reads $1D04, conditionally writes DD00 to $00 or
$02). If $1D04 never toggles, DD00 stays $02 and only bank-1 frame is
shown.

Compare to v342 success (commit e5ff820, RBF md5
`71722b93a461fc29562f85836ec31bf1`): IF +12043 IRQs/240s = ~50 Hz steady.
DD00 alternated $02/$00 per frame.

## v345c→v345g divergence summary

| Build | bootmap reset | cpuDi $F8+ → | Tier3 | Doom |
|-------|---------------|--------------|-------|------|
| v342 (e5ff820)  | (n/a — pre b50ec0b) | ramDin (no gate) | ? | **renders** |
| v344b (b50ec0b) | '1'           | ramDin (no gate) | ? | claimed render |
| v345c           | '1'           | cpuDi_raw always | ? | regressed   |
| v345d           | '0'           | cpuDi_raw always | PASS  | regressed   |
| v345e (= v345g) | '0'           | cpuDi_raw if bootmap='1', else ramDin | PASS  | black 26 Hz |
| v345f           | '1'           | (same as v345e gate) | wedge | wedge       |

The v344b claim ("renders Doom with bootmap='1'") is suspicious given that
v344b's cpuDi mux has no carve-out — bank-$F8+ reads would have returned
SDRAM=$00, kickstart at $F8:$80C1 should have BRK'd on first fetch. Either
the memory entry is wrong, or there's a SDRAM-init path that loads EPROM
bytes that I haven't traced.

## Next investigation directions

### 1. Verify v344b actually rendered Doom

Check out commit `b50ec0b`, rebuild, deploy, run `tools/doom_full_run.py`.
If it black-screens too, the "v342/v344b" claim in earlier session notes
is wrong and v345g is no worse than v344b for Doom.

### 2. Probe raster IRQ ($D019) state during Doom

Add UART field: 6502 cycles since last `$D019 bit0=1` event, plus current
`$D01A & $01`. If raster IRQ enable bit clears unexpectedly, that's the
cause of the page-flip failure.

### 3. Compare bank $00:$E000-$FFFF in v345g vs v342

If bootmap='0' skips kickstart's KERNAL preparation, but KERNAL still
boots via $FFFC, the difference might be in what registers/state Doom
inherits. Especially $D07x SCPU control bits.

### 4. Page-classify scpu64.mif for an Option B fix

For a future bootmap='1' attempt: replace 60% padding pages with `$6B` in
buslogic. Then bank-$FF JMLs to padding → RTL no-op, but bank-$FF reads
to real code (KERNAL routines) → EPROM bytes. See `docs/v345e_fix_plan.md`
"Option B".

## Files in this session

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1969-1971` — cpuDi mux gate (v345e/g)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1985-1997` — bootmap='0' (was '1' on
  v344b/v345c; tried '1' again on v345f, wedged)
- `tools/v345e_deploy_test.py` — deploy + tier3 smoke runner
- `tools/v345e_results/tier3_shot.png` — green border PASS (v345e)
- `tools/doom_full/shot_240s.png` — black screen (v345e)
- `tools/doom_full/uart_240s.txt` — 26 Hz IRQ pattern
- `docs/v345e_fix_plan.md` — Option A/B/C analysis

## Build/deploy artifacts

- v345e RBF: md5 `6165b0691d1b0b7d3f14fc2eb44dd1c9` (size 3874612) —
  overwritten by v345f build, no longer on disk
- v345f RBF: md5 `48142f459945f002fb61238540319f1e` (size 3837832) —
  current on disk and on MiSTer (broken — kickstart wedge)
- v345g RBF: building now. Source state matches v345e. Expected md5
  similar (synthesis variance may differ).

## Pre-MiSTer-test commit plan

When v345g build completes:
1. Deploy `C64_MiSTer/output_files/C64.rbf` to `/media/fat/_Test/C64.rbf`
2. Smoke: `tools/v345e_deploy_test.py` → tier3 green border (expected PASS)
3. Doom: `tools/doom_full_run.py` → expect same v345e signature (CPU
   healthy, IRQ ~26 Hz, screen black)
4. If both match expectations, commit the v345g source state (cpuDi gate
   + bootmap='0' reverted). Title: "fix: v345g — gate cpuDi $F8+ carve-out
   on bootmap; restores Tier3 + no SBC,X corruption; Doom still black"
