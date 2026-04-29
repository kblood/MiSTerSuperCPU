# Session Passover 2026-04-19 (Part 2): Probe-removal fix APPLIED and verified — both release and debug builds now fit in reasonable time

## Headline

The async BRAM probe port identified in `session_passover_2026_04_19.md`
(part 1) has been removed. Both build flavors now fit cleanly and in
reasonable time:

| Build          | ALMs             | Fit time | RBF size |
|----------------|------------------|----------|----------|
| `-Release`     | 30,090 (72%)     | 13:48    | 3.99 MB  |
| `-Debug` (all) | 35,103 (84%)     | 16:08    | 4.09 MB  |

Design is back to baseline, not 469,442 ALMs / 1120% / unfittable.

## What was changed (4 files)

1. `C64_MiSTer/rtl/c64_ram64k.vhd` — removed `probe_addr`/`probe_dout`
   entity ports and the async read driver.
2. `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — removed the matching
   `bram_probe_addr`/`bram_probe_data` ports and the port map in the
   `ram64k_inst` instantiation.
3. `C64_MiSTer/c64.sv` — removed the tied-to-zero `.bram_probe_addr(...)`
   and left-open `.bram_probe_data()` on the `fpga64_sid_iec` instance.
4. `sim/verilator_c64_vanilla/verilator_c64_vanilla_top.vhd` — removed
   matching entity ports, signal declaration, assignment, and port map.
   `sim/verilator_c64_vanilla/host/main.cpp` — stubbed `probe_bram()` to
   return 0 (vanilla harness screen-capture features disabled until a
   synchronous probe is wired in).

No other async-read or missing-ramstyle landmines found during audit
(see "Debug audit" section below).

## Validation on real hardware

- Deployed `C64.rbf` (release) to `/media/fat/_Test/C64.rbf` via
  `python tools/mister_debug.py deploy C64.rbf`.
- Screenshot confirms boot to READY prompt with "64K RAM SYSTEM
  38911 BASIC BYTES FREE" (saved as `boot_after_probe_fix.png`).
- Release build has `DEBUG_RELEASE=1` so **no UART emission** — the
  `mister_debug.py load_prg` tool's UART-alive check fails against a
  release build. This is expected.

## What is NOT yet validated

The PRG auto-RUN classification fix from commit **0bcfabe** ("WIP: latch
PRG vs REU classification at first ioctl_wr") — the fix compiles and
the core boots, but the auto-run behavior was not independently
verified this session:

- MGL via pipe successfully registered the PRG filename with MiSTer
  (screenshot filename `...-autorun_test.png` proves the `<file>` tag
  reached the ioctl handler — so it was not dropped as REU).
- `mtype.py` hit its "one-batch-per-MiSTer-lifetime" limitation before
  a clean RUN+ENTER sequence could be sent to type RUN and verify the
  colour-change code fired. Per memory
  `feedback_mister_input_fragility.md`, a MiSTer main restart is
  needed between mtype batches.
- **To finish validation next session:**
  1. Fresh-boot the C64 core (deploy again or `kill $(pidof MiSTer);
     nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf &`).
  2. Build with `-Debug` OR a narrow `-DbgUart` variant so UART comes
     back and `load_prg` works.
  3. One single mtype batch: upload PRG via mbc/MGL, then one call to
     `mtype.py "RUN" enter` to exercise the auto-run and observe
     border/background colour change ($D020=$02 red, $D021=$05 green)
     for `autorun_test.prg`.
  4. Diagnostic counters at **$DFC0-$DFC7** (added by 0bcfabe) should
     show the classification actually fired — PEEK them via BASIC or
     inspect via UART stream.

## Debug audit (what else is in the synthesis path)

All other debug features are either properly `ifdef`-gated or actively
used in production:

| Feature | Gate | Purpose |
|---|---|---|
| Crash trace ring ($DF20-$DFA0) | `DBG_TRACE` | Ring buffer of last 128 (PC, PBR, IR) |
| UART debug stream (T:/A:/K:/B:/...) | `DBG_UART` | Per-frame status overlay via /dev/ttyS1 |
| Debug video overlay | `DBG_OVERLAY` | On-screen diagnostic text |
| Bus capture diagnostics | `DBG_BUS_CAPTURE` | CIA1/VIC/$0801/SuperRAM capture |
| REU FETCH counters ($DFA1-$DFBF) | unconditional, tiny | $DF00 mux, ~100 ALMs |
| PRG classification counters ($DFC0-$DFC7) | unconditional, tiny | Added by commit 0bcfabe |

SignalTap present in `C64.qsf` (debug revision) but **not in
`C64_release.qsf`** — confirmed clean.

The `ifdef` gates work at preprocessor level — when the macro is
undefined, Quartus never sees the code. Zero fit cost for excluded
categories.

## Recommended next session opening steps

1. **Pick up PRG auto-run validation** on a fresh MiSTer boot using a
   `-Debug` or `-DbgUart` build so UART diagnostics are available.
2. **Consider committing** the probe-removal fix. Changes are
   uncommitted in working tree (see `git status`). Suggested message:

   ```
   Remove dead async BRAM probe port, restoring M10K inference

   The probe_addr/probe_dout port in c64_ram64k.vhd was added for
   desktop-harness use but tied-to-zero / left-open in c64.sv. Its
   async read pattern forced Quartus to synthesize 64 KB x 8 in
   524,288 LUT flip-flops, ballooning the design to 469,442 ALMs
   (1120% of device). Removed from c64_ram64k, fpga64_sid_iec, c64.sv,
   and the vanilla Verilator harness. Vanilla harness `probe_bram()`
   stubbed to return 0 pending a synchronous probe if needed.

   Release build: 30,090 ALMs (72%), fit 13:48.
   Debug build:   35,103 ALMs (84%), fit 16:08.
   ```
3. **Vanilla Verilator harness** text-screen capture features are
   currently stubbed. If that harness needs to be revived for
   differential testing, replace the stub with either (a) a registered
   version of the same probe, or (b) a Verilator DPI reading the ram
   array directly. Cross-reference the shelved-on-branch SuperCPU-fork
   harness (`shelved/verilator-superfork`) for prior patterns.

## Reference build logs

- `build_release_probe_fix_2026-04-19.log` — release build log, 13:48.
- `build_debug_probe_fix_2026-04-19.log` — debug build log, 16:08.
- `boot_after_probe_fix.png` — screenshot of READY prompt on real HW.

## Current repo state (working tree, uncommitted)

Touched:
- `C64_MiSTer/c64.sv`
- `C64_MiSTer/rtl/c64_ram64k.vhd`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd`
- `sim/verilator_c64_vanilla/host/main.cpp`
- `sim/verilator_c64_vanilla/verilator_c64_vanilla_top.vhd`

New artifacts (not to commit):
- `build_release_probe_fix_2026-04-19.log`
- `build_debug_probe_fix_2026-04-19.log`
- `boot_after_probe_fix.png`
- `after_prg_load.png`, `after_run.png`, `after_run2.png`, `peek_test.png`, `peek2.png`
- `test_prg.mgl`

The PRG-fix commit 0bcfabe is still HEAD on master. Nothing was
reverted.
