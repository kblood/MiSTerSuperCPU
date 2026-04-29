# Session Passover 2026-04-09b: LDA/JML long crash — candidate fix applied

## Headline

The LDA/JML long crash class — `$AF`, `$5C`, `$8F`, `$CF` (4-byte
bank-operand instructions) — has a coherent **regression theory** with a
**targeted candidate fix** applied to `C64_MiSTer/rtl/fpga64_sid_iec.vhd`.
Quartus syntax check passes; full build queued. Not yet hardware-tested.

## What changed in source

Three edits to `C64_MiSTer/rtl/fpga64_sid_iec.vhd`. All three are a
**re-application of commit `c2ddf69`'s "BRAM 1MHz fix"**, which had been
reverted by commit `96e9262` for reasons that no longer apply.

### Edit 1 — `enableCpu_816` BRAM term, ~line 1214

```vhdl
-- BRAM hit advances CPU regardless of turbo_en: BRAM is the only fast path
-- at 1MHz/IEC slow mode and must serve bank $00 reads independently of speed
-- gating. Cache/phantom remain gated by turbo_en (cache is opt-in turbo).
enableCpu_816  <= ((bram_hit_d1 and not at_cpucd) or
                   (cache_hit_d1 and turbo_en and not at_cpucd) or
                   (phantom_enable and turbo_en and not at_cpucd) or
                   (enableCpu and not dma_active))
                  when supercpu_en = '1' else '0';
```

### Edit 2 — `bram_hit_d1` registered process, ~line 1598

```vhdl
-- Speed flag gates removed (re-applies c2ddf69): BRAM must serve bank $00
-- reads at 1MHz mode and during IEC slowdown. Without this, the post-fetch
-- of 4-byte bank-operand instructions ($AF/$5C/$8F/$CF) falls through to
-- cpuDi_raw → SDRAM dout_lo, which holds the prior PC-stream byte (= $00
-- bank operand for bank=$00) and triggers a BRK warm restart.
-- The original SuperRAM disruption that motivated re-adding these gates
-- (96e9262) was independently fixed by 9833fce's superram_data_r latch.
elsif bram64k_en = '1'
   and dma_active = '0' and baLoc = '1'
   and cpu_cyc = '0'
   and cpu_cyc_s(0) = '0'
   and cpu_cyc_s(1) = '0'
   and superram_enable_delay = '0'
   and enableCpu = '0'
then
```

(removed `scpu_speed_1mhz='0' and scpu_sys_1mhz='0' and iec_slow_mode='0'`)

### Edit 3 — Pipeline cancel, ~line 2126

```vhdl
-- Cancel on bram_hit_d1 INDEPENDENTLY of turbo_en: BRAM hits at 1MHz/IEC
-- slow mode also advance the CPU and must cancel any in-flight SDRAM
-- pipeline to prevent a double-enable that would skip a CPU state.
if (bram_hit_d1 = '1') or ((cache_hit_d1 = '1' or phantom_enable = '1') and turbo_en = '1') then
```

## The regression chain

| Commit | Date | What it did |
|---|---|---|
| `c2ddf69` | Apr 2 | Removed speed/iec gates from `bram_hit_d1`. Fixed BRAM at 1MHz. **Side effect:** ungated `bram_hit_d1` disrupted SuperRAM SDRAM pipeline (it was canceling pending superram reads inappropriately). |
| `96e9262` | Apr 2 | Reverted all three c2ddf69 edits to fix the SuperRAM disruption. **This re-broke BRAM at 1MHz.** Also reverted `superram_data_r` → used raw `sdram_raw` in cpuDi mux. |
| `9833fce` | Apr 2 | Restored `superram_data_r` in cpuDi mux with the bt-correct capture path. **This fixed the SuperRAM disruption a different way** — the byte-toggle (`bt`) clobbering by io_cycle CEs was the real SuperRAM problem, not BRAM. |
| **gap** | — | Nobody re-removed the BRAM 1MHz gates after `9833fce` made the `96e9262` revert obsolete. |
| `2026-04-09b` | Today | Re-applied c2ddf69's three edits. |

## Why this matches the GHDL bench's smoking gun

From `project_ghdl_p65c816_bench.md` and `docs/session_passover_2026_04_08f.md`:

The bare-CPU GHDL bench eliminated:
- CPU microcode bugs (the encoding is correct)
- Single CE drops at any state of $AF (benign)
- Single-byte data corruption mid-instruction (benign)
- Wrapper `localDi` mux (passes `di` through cleanly)
- `accessIO` glitches

The bench's `SC_CORRUPT_S0_NEXT` scenario reproduces the **exact** observed
warm-restart symptom by injecting `D_IN=$00` for one cycle when the CPU
fetches the post-$AF opcode. The bench's structural finding was:

> $AF has an extra PC-stream RAM fetch (state 3 = bank operand) immediately
> before the I/O cycle that $AD does not. The byte stuck in `dout_r` during
> the I/O cycle is the bank operand for $AF (= $00 BRK for bank=$00) but is
> the AAH operand for $AD (= $D0 BNE, benign).

And:

> At 1 MHz mode, BRAM and cache paths are both gated off, so the wrong byte
> must come from `cpuDi_raw` (the standard C64 buslogic `dataToCpu` output).
> Likely 1-cycle staleness in the buslogic data path after the state-4 I/O
> fetch transitions back to a RAM fetch.

This fix addresses exactly that: re-enabling BRAM at 1MHz/IEC-slow so
post-fetches are served by BRAM (correct byte) instead of falling through
to `cpuDi_raw` (stale SDRAM `dout_lo`).

## What the fix should and should not affect

**Should fix (theory):**
- `tools/test_cart/sr_slow.prg` — explicit `$D07A` 1MHz mode
- `tools/test_cart/sr_jml.prg` — *if* iec_slow_mode is asserted during
  test execution because BASIC's RUN command read `$DD00` recently
- KERNAL boot at 1MHz mode (the original c2ddf69 use case)
- Any code that does CIA2 IEC interaction then runs 4-byte instructions

**Should NOT affect (theory):**
- Anything in turbo mode that's not in iec_slow window
- SuperRAM read paths (now properly served by `superram_data_r` latch)
- VIC timing
- Existing 6510 mode

**Risk of regression:**
- Marginal `clk32` slack (-0.37 ns per CLAUDE.md). The change adds
  `bram_hit_d1` paths into more terms (no longer gated by turbo_en in two
  places). If this pushes setup violations on the BRAM read path, the
  full build will tell us.
- The `96e9262` SuperRAM disruption: the `bram_hit_d1` cancel of
  `cpu_cyc_s` could in theory still kill an in-flight SuperRAM pipeline.
  The protection that *should* prevent this is `9833fce`'s
  `superram_data_r` latch — it captures SDRAM at CPUE before any cancel
  matters at the CPU sampling edge. **Worth testing SuperRAM round-trip
  on hardware to confirm.**

## How to test on hardware

1. Wait for full build to complete (not yet done at time of writing this passover).
2. Verify timing report: `clk32` setup and `clk64` setup must both be ≥0
   (or marginally negative as before). If significantly worse, this fix
   is too expensive and a different approach is needed.
3. Deploy: `python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf`
4. **Test 1 — KERNAL boot at default speed.** Should boot to READY.
5. **Test 2 — `sr_slow.prg`.** Load via `mbc load_rom C64.PRG sr_slow.prg`.
   Expected: BLUE border (the program reaches `lda #$06 / sta BORDER` after
   the LDA long survives). Failure: warm-restart wipe to READY.
6. **Test 3 — `sr_jml.prg`.** Load same way. Expected: digits "1234" in
   row 0 of screen, then idle loop. Failure: warm-restart.
7. **Test 4 — `sr_lram.prg`** (LDA long with bank=$00, target=$00:0810).
   Same expected pass/fail.
8. **Test 5 — SuperRAM round-trip.** A simple write/read PRG that does
   `STA long` to SuperRAM then `LDA long` back. This is the regression
   sentinel for the `bram_hit_d1` cancel race that motivated the
   `96e9262` revert.
9. **Test 6 — Doom launcher.** If 1-5 pass, the Doom blocker should be
   gone. Load via OSD: F12 → Load REU → games/C64/doom.reu, then run the
   loader PRG with `JML $20:0000`.

## If sr_slow passes but sr_jml at full turbo still fails

Then there is a separate turbo-mode mechanism for the same bug class.
Hypotheses to explore in that case:

1. **bram_hit_d1 race at turbo:** the BRAM hit may register on a cycle
   where `cpu_cyc` for SuperRAM is in flight, so the cancel at line 2126
   kills it. But sr_jml is bank-$00 only — no SuperRAM in the test.
2. **at_cpucd suppression window:** during CPUA-CPUD, BRAM is suppressed
   in `enableCpu_816` (to prevent racing past I/O reads). For 4-byte
   instructions whose post-fetch happens to land in this window, the
   CPU could fall through to the SDRAM path, which has the same staleness.
3. **Different enable racing:** the post-fetch may still go through the
   SDRAM `enableCpu` path and the CPU samples `cpuDi_raw` directly if
   bram_hit_d1 wasn't registered yet.

For these, the next step is **on-hardware diagnostic capture**: a small
ring buffer in `fpga64_sid_iec.vhd` that records `(cpuAddr_pre, cpuDi,
IR, sysCycle)` at every `enableCpu` and freezes when IR transitions to
`$00` after IR was `$AF` or `$5C`. Dump via UART.

## Files modified this session

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — three edits described above
- `~/.claude/.../memory/MEMORY.md` — updated LDA long entry
- `~/.claude/.../memory/project_lda_long_crash.md` — added "candidate fix" header

No other files changed. No new files created in `C64_MiSTer/`.

## Doom context (the actual goal)

Per the user's standing directive: **"Doom is the test to return to...
the main task is to get doom to run as part of the test to ensure the
SuperCPU implementation is working."**

The chain of dependencies:
1. doom_loader.prg ends with `5C 00 00 20` (`JML $20:0000`)
2. `$5C` is in the same buggy 4-byte bank-operand instruction class as
   `$AF`/`$8F`/`$CF` — confirmed live by sr_jml.prg crashing
   pixel-identically to sr_slow.prg
3. Therefore the loader BRKs on its own bank operand fetch and warm-restarts
4. doom.reu IS correctly loaded into SDRAM at `0x1200000` (= bank
   $20:$0000) — verified separately
5. **The only thing standing between the current state and Doom running
   is fixing the LDA/JML long bug class.**

If today's fix works, Doom should immediately advance past the launcher.
The previously documented `$20:20FC` SuperRAM crash from session 04_05d
may or may not still be present after this fix — that's the next test
beyond launcher survival.
