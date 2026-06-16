# Session handoff

## Current state (2026-06-16, iter-33c) — SIMM-detect compat fix building

**First real-software-driven COMPAT fix in flight.** SynthMark64 v0.2 (4th real-
software title confirmed running on our SuperCPU, after Doom / Kicks / BoulderMark)
boots fine and detects `CPU 65816` correctly, but its status line reads
`RAM 0 KB (0 BANKS)`. Root-caused (disassembled, high confidence): its SIMM-size
probe ($220A) walks banks $00 upward writing a 0..255 ramp to `bank:$0400` and
reading it back, with a **single-byte counter and NO upper bound** — it only stops
when a bank fails readback. Our SuperRAM echoes ALL 256 banks, so the counter wraps
$FF→$00 → reports 0. Real HW reserves high banks ($F0-$FF) as bootmap ROM (non-
echoing), so the probe terminates there.

**Fix:** `c64.sv:1117-1170` `SIMM_CAP` — SCPU CPU reads of SuperRAM banks $F0-$FE
return a sentinel (latency-matched via `is_capped_q`, same pattern as the bank-$00
BRAM override). Probe then stops at $F0 = **240 banks / 15360 KB**. Only
`sdram_data_eff` (CPU/cart read) is gated; VIC reads raw `sdram_data`. Gated
`~io_cycle & ~ext_cycle` so the REU doom.reu load and the loader's $FF DMA table read
are untouched. NOT the reverted `simm_remap_bank` mechanism (`81af800`, kickstart ROM).

**Two builds — the sentinel value matters:**
- Build #1 `4a7b171b` (sentinel **$FF**): SynthMark64 FIXED (240 BANKS confirmed) but
  **REGRESSED DOOM**. A/B vs control `41944346` decisive: control UART PC=`2C0Cxx`
  (Doom engine, bank $2C); $FF build PC stuck bank $00/$FF, never reached $2C. The
  doom_loader reads a high-bank byte and got $FF instead of the $00 empty banks hold
  → bad pointer → wedge.
- Build #2 `4c9cd300` (sentinel **$00**): BOTH PASS. SynthMark64 reads 240 BANKS /
  15360 KB; Doom runs (UART PC cycling banks $23/$25 = SuperRAM engine, like control).
  $00 = the real (zero) content of empty $F0-$FE → cap is a behavioral no-op for any
  reader that doesn't write-then-read those banks (only the detection probe does), so
  Doom v2 ≡ control bit-for-bit on every read it makes.
- **Lorenz scpu:** PASS — all tests "ok", continuous progress, no halt (final frame
  stxzy..phan all ok). t65: cap structurally unreachable (supercpu_enable=0), bit-
  identical by construction.
- **COMMITTED `ec118c5`** (build `4c9cd300` on `_Test`). Files: `c64.sv` (SIMM_CAP $00),
  `tools/synthmark_detect_probe.py`, `.gitignore` (synthmark artifacts). Push still gated.
- Memory: `project_simm_detect_256bank_wraparound.md`.
- **First real-software-driven compat fix to ship on the fork.** Next compat candidates
  (need user-supplied register-exercising disks): GEOS / SuperCPU-library titles
  exercising the $D074-$D077/$D0B3 WriteSmart stubs. Speed frontier remains closed
  (native k=2 shipped, emu turbo opt-in works).

## Prior state (2026-06-14, iter-31b)

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

## iter-32 SWEEP RAN (2026-06-14) — SuperCPU Kicks demo PASSES; per-part launch invalid

Rig freed (CORENAME=MENU); ran the full 13-target sweep (build `41944346`, cfg 0x0c).
Fixed two harness bugs first: out-dir must pre-exist for the log redirect, and
`coop_ok` misused `L.run()` (returns a `(stdout,stderr)` tuple — now unpacked).

**Result — 1 real PASS, the rest are launch-method artifacts (NOT core bugs):**
- **scpu1_loader = PASS.** The DMAGIC / "SuperCPU Kicks" demo (disk 1, its own
  `SCPU KICKS !/DMA` loader) boots and runs: coherent greetings/credits scroller
  in a black panel over blue with intentional top/bottom raster bars, animating
  cleanly across the whole capture. **First real SuperCPU *demo* validated on our
  core beyond Doom** — a concrete compat win.
- **kicks_a..k + cp_clock = INVALID test, not failures.** These load to scattered
  high addresses ($B200/$EA00/$2200/...) — non-BASIC binaries the loader chains.
  `LOAD"name",8,1` + `RUN` makes BASIC execute a binary → `?FORMULA TOO COMPLEX
  ERROR` floods (b,k), frozen-READY (g,i), blank screens (a,c,d,e,f), partial
  garbage (h,j). The BASIC errors actually confirm our SCPU64 ROM BASIC is healthy.
  Methodology note added to `scpu_compat_sweep.py` TARGETS.
- Captures: `tools/scpu_compat_sweep/<slug>/` (6-8 shots + UART each); run log
  `sweep_run.log`; visual triage by subagent (1 PASS / 2 PARTIAL / 10 launch-artifact).
- **PASS re-confirmed stable**: a 360s loader-only re-run (`loader_confirm.log`)
  showed continuous coherent animation every sample for the full 6 min — no freeze,
  no crash. Final frame `scpu1_loader/0327s.png` = same scroller, text advanced.
- Committed `821fcb5` (coop_ok fix + methodology note). Rig released (CORENAME=MENU,
  lock NOLOCK). Sweep artifacts left local/untracked (large PNG+UART).

## iter-33 (2026-06-16) — BoulderMark runs (compat PASS); speed number joystick-gated

User freed the rig ("you can use the mister now"). No new register-exercising
software was supplied, so picked the highest-value rig work available: `bmark11.d64`
= **BOULDERMARK**, the classic C64 speed benchmark (BASIC-runnable, unlike the demo
parts). Staged + ran in scpu mode.

- **BoulderMark PASS (runs):** loads, executes the Boulder Dash cave simulation, and
  reaches a static end-state by ~65s. **3rd real-software title confirmed running on
  our SuperCPU** (after Doom + SuperCPU Kicks). Captures: `bouldermark/`.
- **Speed multiplier NOT extracted = deferred.** The result screen is a full cave
  with NO printed numeric score (verified by upscaling — pure tiles, no digits). The
  program sits on the cave waiting for **joystick fire** to start the timed run;
  `RUN` + keyboard SPACE (mtype) does not advance it (mtype is keyboard-only, and a
  fresh uinput joystick isn't reliably auto-mapped to the C64 joy port without OSD
  config). Stepped back rather than rabbit-hole a joystick helper.
- **Reusable wins committed:** (a) the on-screen debug overlay (status bit 83) sits
  in the lower screen and obscures bottom-screen program output — added a `--cfg`
  flag to `scpu_compat_sweep.py` so `--cfg 0x04` = SuperCPU **on**, overlay **off**
  (0x0c=on/on, 0x08=t65). Confirmed: with overlay off the BoulderMark screen is
  clean & stable. (b) bmark added as a sweep target.
- **To get a real-software speed number next:** use a CPU-bound benchmark that
  PRINTs a text result (readable via screenshot), or build a configured uinput
  joystick helper (`tools/mjoy.py`) to fire BoulderMark's timed run.

## iter-33b (2026-06-16) — CORRECTED: emu BASIC = 1.00x default, 4.04x on $D07B opt-in

Drove a real CPU-speed measurement: `tools/basic_speed_bench.py` types a timed BASIC
loop over mtype and reads the jiffy clock, both modes, overlay off.

**First pass led to a WRONG conclusion** ("scpu==t65, ZERO emu speedup, build a
compat-safe emu accel"). A no-build RTL investigation + a HW opt-in test corrected it:
**the compat-safe emu turbo is ALREADY implemented and shipping.**
- `$D07A` = force 1 MHz, `$D07B` = force 20 MHz turbo — decoded correctly at
  `fpga64_sid_iec.vhd:2891-2896` (matches `docs/architecture_diagrams.md:446-447`).
  **No polarity bug.**
- Emu turbo is OPT-IN: `turbo_m="111"` only when `scpu_speed_reg_written ∧
  ¬scpu_speed_1mhz` (i.e. software wrote $D07B), `fpga64_sid_iec.vhd:4090-4097`.
  Default = safe 1 MHz.
- **HW test (emu/BASIC, N=20000):** baseline **1397** jiffies → `POKE53371,0`($D07B)
  → **346** (= **4.04x**) → `POKE53370,0`($D07A) → back to **1397**. Toggle works.

**The 1.00x-by-default is CORRECT, not a gap:** stock BASIC/Lorenz never write $D07B,
so they stay at the safe 1 MHz default → Lorenz scpu stays 100%. This IS the
CMD-SuperCPU contract (1 MHz default, turbo on explicit request, with the
`scpu_force_1mhz` auto-throttle net). iter-31b reverted an *unconditional* emu turbo
that broke Lorenz; the landed model is exactly this opt-in. **Nothing to build here.**
Full record: memory `project_emu_basic_no_speedup_measured.md`.

## Pending / next

- **Test parts A-K properly = run THROUGH the loader** (it chains A-C on disk 1;
  D-K need the demo's own disk-swap on SCPU2/SCPU3), or build per-part ML launcher
  stubs once entry points are known. Standalone `LOAD,8,1`+`RUN` cannot launch them.
- Source GEOS / a SuperCPU-library title for a register-exercising compat target
  (the Kicks demo touches few of our stub regs at the loader stage). **This needs
  the user to supply disk images** — no register-exercising SCPU software is staged
  locally, and the loop won't auto-download copyrighted titles. = current loop blocker.
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
