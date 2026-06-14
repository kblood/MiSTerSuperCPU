# Session handoff

## Current state (2026-06-14, iter-31b)

**The authoritative bank-$00 BRAM fast-fire speed lever LANDED and is HW-validated —
the first speed lever to ship after the long dead set.**

- **Shipped/new HEAD build:** `41944346` (md5 `41944346d0249c5ba0c420842e0de683`),
  currently on the MiSTer `_Test/C64.rbf`. Control baseline = `3698680a`.
- **Design:** native-only fast-fire on bank-$00 reads. `b00_fast_read` (in
  `fpga64_sid_iec.vhd`) fires the CPU 2-apart for bank-$00 READS served by the
  on-chip authoritative BRAM (`c64.sv` `bank00_mem` continuous read), gated to
  NATIVE mode (`emu_mode_816_i='0'`). `emu_serial_throttle` now fires at $00:$ED/$EE
  in BOTH modes to protect the SCPU64 ROM's native serial LOAD.
- **Why native-only:** emu/turbo fast-fire (`03d9f2ee`) was HW-falsified — it broke
  the Lorenz scpu KERNAL serial LOAD ($ED5A) and would fail the CIA-timer tests
  (CPU-cycles-per-tick ratio changes). Native-only makes all emu-mode code
  control-equivalent (compat) while Doom (native) keeps the win.

## Validation (A/B vs control `3698680a`)

- Build green, TNS=0 (setup +0.381 / hold +0.247), 66% ALM / 84% RAM blocks.
- Boot clean to READY, idle PC range $E5CD–$E5D6.
- Lorenz scpu: matches control test-for-test (62s=ldaa = control), clears the
  step-6 serial wedge, lda→sta→ldx all `-ok` over the full 9-min run.
- Lorenz t65: bit-identical to control by construction (supercpu_en=status[82]=0
  ⇒ fast-fire disabled in t65).
- Doom: A/B identical to control (same engine frame, 125 UART lines, native PC
  $2A55xx, fast-fire active = the ~1.24-1.33× win).

## iter-31c (2026-06-14) — k=1 fast-fire STA-FALSIFIED (no build) — k=2 is the floor

The documented follow-on speed step (k=1 / 1-apart native fast-fire, ~1.41×) is
**STA-infeasible** — killed by a 15-second `quartus_sta` query on the already-fitted
iter-31b design (`C64_MiSTer/k1_sta_probe.tcl`), no Quartus build, no HW risk.

- clk32 period = **31.719ns** (counter[2], 31.53 MHz). At k=1 the CPU fires on
  consecutive clk32 edges, so every path `-to P65C816` gets 1 clk32 instead of the
  2 it has today (`C64.sdc:44` `set_multicycle_path -setup 2 -to *P65C816:cpu|*`).
- Worst P65C816-**internal** setup path: `MCode|MI.addrInc[0] → P65C816:cpu|P[1]`
  (the Zero flag), data delay **31.394ns**, clock skew −0.493ns ⇒ slack at −setup 2
  = +31.361ns ⇒ **at −setup 1 = −0.358ns** = masked-timing violation (the death
  class). This is the SAME irreducible **result→zero-flag** dependency iter-31's
  carry-select AddSubBCD surgery already hit — the 65C816 datapath cannot complete
  in one clk32.
- (The worst path INTO P65C816 overall, +17.339ns, is `sdram_pm|dout_r → sdram_data_eff
  mux → cpuDi → CPU ALU` = the SuperRAM read path; it stays 4-apart at k=1 and keeps
  −setup 2, so it is NOT a k=1 concern. The bank-$00 BRAM `bram_q` path isn't in the
  worst 40 — on-chip M10K is fast. The CPU-internal floor, not memory, kills k=1.)

**Verdict: k=2 (shipped iter-31b `41944346`) is the architectural floor for the
bank-$00 fast-fire lever at the current clock + datapath.** Every in-CPU / in-clock
speed lever is now exhausted (7 dead levers + page-mode + write-buffer dropped +
k=1 STA-dead + k=2 shipped). Further speed needs a multi-month CPU-arch project
(dual-mode CPU or a raised CPU clock with CDC) = operator-funded, not loop work.

## COMPAT frontier — sweep prepped (2026-06-14), HW run pending rig

Accuracy is effectively done (SST 100%/5.12M + Lorenz 100% both modes; only the
XCE M/X auto-force workaround re-test remains, cosmetic). The live frontier is
non-instruction COMPAT: run real SCPU software on HW and triage failures against
the known stubs (WriteSmart $D074-$D077/$D0B3, bootmap OS ROM $F0-$FF,
badline-during-turbo, DOS ext $D0BE/$D0BF) — most marked "no known consumer", so
the sweep is what turns them into a concrete fix queue.

**Real software staged on the rig** (catalogued via new `tools/d64_dir.py`):
- `SCPU1.D64` = "*** DMAGIC ***" SuperCPU demo disk (note: "REQUIRED: SCPU WITH
  1MB RAM"). Runnable PRGs: `SCPU KICKS !/DMA` (loader, = "*"), `SUPERCPU KICKS
  A`/`B`/`C` (demo parts). Timing demos = highest-value probes (hit badline-turbo).
- `CP-ClockF83_1.3.D64` = `CP-CLOCK-1.3` CMD utility.
- No GEOS present (would need sourcing).

**Sweep harness built + validated offline:** `tools/scpu_compat_sweep.py` — sets
cfg 0x0c, mounts each disk + a generated `LOAD"NAME",8,1` autoload PRG via MGL
(same start_strk path as `lorenz_run.py`), captures screenshots + UART per program
to `tools/scpu_compat_sweep/<slug>/`. Has a COOPERATION GUARD: refuses load_core
unless `/tmp/CORENAME` is C64/MENU/empty. `--list` / `--only` / `--secs` flags.
The generated `"*"` PRG is byte-identical to `lorenz_autoload.prg` (tokenizer
verified).

## iter-32 prep (2026-06-14) — full demo set staged + sweep expanded; static triage proven noise-bound

Continuation of the COMPAT-sweep prep while the rig was busy (AO486 slice).

- **All 3 SuperCPU Kicks disks catalogued** (`tools/d64_dir.py`): SCPU1 = loader +
  parts A/B/C; SCPU2 = parts D/E/F/G; SCPU3 = parts H/I/J/K. SCPU2.D64
  (md5 `b7ff343b`) + SCPU3.D64 (md5 `111ac31`) **staged to the rig**
  `/media/fat/games/C64/` and md5-verified (non-disruptive scp; AO486 untouched).
- **Sweep expanded to 13 targets**: `tools/scpu_compat_sweep.py` TARGETS now covers
  the loader + all 11 Kicks parts A–K + CP-Clock (~45 min HW). `--list` verified.
- **Static feature-triage attempted and FALSIFIED as noise-bound**:
  `tools/scpu_prg_triage.py` (new) extracts each PRG and byte-scans for SuperCPU
  control-register operands + 65816 long ops. Result is at the random-chance floor:
  a 51KB crunched demo yields ~10-13 register-address "hits" vs ~14 expected purely
  by chance (p≈1/65536 × 51199 positions × 18 regs). Control: Lorenz 6510 PRGs
  (~600 B) give 0 hits, and the rate scales linearly with size — confirming pure
  noise. The demos are crunched (payload load addrs $B200/$EA00/etc.), so a byte
  scan can't see the real code. **Conclusion: no reliable static pre-classification
  is possible for these demos; the HW sweep is the only ground truth.** (The tool is
  kept — harmless, and useful on uncrunched PRGs — with the caveat in its docstring.)

## Pending / next

- **Run the expanded sweep when the rig is free**: `python tools/scpu_compat_sweep.py`
  (rig is on AO486 = another slice; the coop guard refuses until CORENAME is
  C64/MENU/empty). Then triage each program's screen/UART → map failures to stubs.
  Per-target output under `tools/scpu_compat_sweep/<slug>/`.
- iter-31b lever committed (`48b6f3c`); k=1 STA-death committed (`bd5e20a`). Pushes
  still gated.
- Optional/deferred: a clean native Doom frame-rate number for the k=2 model.

## Artifacts

- Memory: `project_bank00_bram_lever_sized_go.md` (full record, iter-31b section).
- Lorenz A/B runs preserved: `tools/lorenz_run/scpu_control_3698680a`,
  `tools/lorenz_run/scpu_iter31b_41944346`. Doom: `tools/doom_autoload/
  single_prg_iter31b_41944346`.
- Helper: `tools/lorenz_fine_capture.py` (fine-grained Lorenz screenshot capture).
- Codex reviews: `tools/codex-out/iter31b-native-only-review.txt`,
  `tools/codex-out/bank00-fastfire-step6-v3-review.txt`.

## Rig

Freed: menu core loaded (CORENAME=MENU), `/tmp/mister_session.lock` released.
iter-31b (`41944346`) left on `_Test/C64.rbf` for the next C64 session.
