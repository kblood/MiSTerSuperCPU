# Session handoff

## CURRENT STATE (2026-06-21) — Gideon / Ultimate-64 knowledge-transfer package SHIPPED + committed + pushed

**One-line:** Assembled a self-contained handoff package for Gideon Zweijtzer
(Ultimate-64 author) so he can add 65C816 SuperCPU support to the C64U — because
the U64 FPGA bitstream is closed to us (firmware-only repo; no CPU integration
point). We hand off findings + reusable RTL + ROM instead of forking.

**Package:** `C64U/for-gideon/` (1.4 MB, sendable). Cover `README.md` +
`docs/00_PORTING_GUIDE.md` (= `docs/supercpu_for_c64_ultimate.md`) +
NEW `docs/06_LATEST_FINDINGS.md` (VICE 14.75× vs our 2.85× gap = bank-$00 memory
tier; k=2 datapath floor; SST forbids pipelining; Kicks-intro flicker; 1MHz-default
CMD contract; SIMM-detect fix) + NEW `docs/07_REGISTER_DECODE.md` (literal
$D07x/$D0Bx/$D27x/native-vector decode) + docs 01-05 (arch ref, feature status,
changes-vs-upstream, diagrams, VICE-differential methodology) + `rtl/65C816/` +
`rtl/cpu_cache.vhd` + `roms/scpu64.mif`. `C64U/README.md` updated to reflect the
closed-investigation pivot. Memory: `project_for_gideon_handoff_package`.

**Git:** 3 commits this session — (1) BANK00_BADLINE_FAST falsified record +
cooperation-protocol CLAUDE.md + doom_v342 guard fix; (2) build archive metadata +
prune stale `tools/doom_full/`; (3) the Gideon package. **PUSHED** to
`origin/milestone-b-cdc-rewrite` (tip `fde5850`, upstream now set; user-authorized).
Reverted build-tool noise (C64.qpf regen, pagehit_uart.txt). Left regenerated
lorenz_run PNGs + scratch tcl/txt uncommitted (test-artifact churn, not relevant).

**Tree state:** clean for source/docs. `BANK00_FASTFIRE=true` +
`BANK00_BADLINE_FAST=false` (shipped `4c9cd300` config). The RTL line below this
section is the prior (still-valid) Kicks-flicker investigation state.

---

## PRIOR STATE (2026-06-19, end of session) — Kicks-intro flicker: 2 fixes FALSIFIED + Codex/Explore review → next = read-only $D021/$D011/$D012 timing probe

**One-line:** The SCPU-Kicks DMAGIC intro raster overlay flickers on our core (steady on
VICE). Two cheap fix attempts both HW-FALSIFIED (cadence-uniformity; badline-independence,
which made it WORSE). Independent Codex + Explore reviews CONVERGED: root = CPU PHASE vs
the VIC raster (the $D021/$D011/$D012 write/read timing relative to the beam), not pixels,
not data. No clean architectural fix exists (k=2 datapath ceiling, pipeline SST-forbidden,
20MHz unreachable). AGREED next step = a wedge-safe READ-ONLY probe of $D021/$D011/$D012
per-frame timing to classify the bug, then decide. NOT yet built.

**Tree state:** clean — both experiments reverted behind their gates. `BANK00_FASTFIRE=true`
+ `BANK00_BADLINE_FAST=false` (HW-FALSIFIED comment in source) = shipped `4c9cd300` config.
Nothing to commit. Builds produced this session: `eb49592e` (FASTFIRE-off A/B) + `de147ffc`
(badline-fast, falsified) — both archived, neither shipped.

**Rig state:** I released to MENU + cleared my lock when done. As of last check CORENAME=C64
(re-loaded after me, NOT by me — likely the AO486 sibling agent's "will restore" step) and
the lockfile is the AO486 agent's `NOLOCK ... rig free`. I hold no lock.

**The read-only timing probe (next build, scoped, wedge-safe):** clone the existing "v267
$D012 timing" capture (`fpga64_sid_iec.vhd:5094-5100`) for $D021 (`cpuAddr(5:0)="100001"`)
and $D011 (`"010001"`): per frame capture the raster line (`dbg_raster_y`) of the FIRST bar
write + the per-frame $D021 write COUNT. Needs the standard dbg-port plumbing (entity ports
→ c64.sv → a UART slot + parse script); read-only so it folds out of the shipped RBF.
DECISION RULE: first-write raster line JITTERS frame-to-frame → phase drift → try ONE gated
phase-bias build (Codex's lever: +1-3 clk32 delay after raster IRQ / selected bank-$00
reads — but HEURISTIC/demo-specific, NOT architectural fidelity, fixes only THIS demo).
First-write line STABLE but COUNT drops on bad frames → bar loop misses its deadline (cycle
budget) → log as a known SuperCPU timing incompat and move to a higher-yield target.
Codex output: `tools/codex-out/kicks-flicker-review.txt`. Full review: memory
`project_kicks_intro_raster_flicker` ("Codex + Explore convergent review" section).

**VICE reference (operator asked to keep one):** canonical clean DMAGIC-intro capture saved
`tools/scpukicks_vice/vref_intro_canonical.png` (steady ~4.5KB/frame = no flicker); no-skip
capture tool `tools/scpukicks_vice/vice_intro_ref.py` (does NOT poke the $8146 fire-gate,
which skips the intro). Side-by-side artifact `tools/scpukicks_vice/intro_compare_vice_vs_hw.png`.

**Cooperation-protocol fixes landed this session (CLAUDE.md + memory
`feedback_lock_only_during_active_rig_use`):** (1) lock the rig ONLY during active use, NOT
during a ~35-min local build; (2) "releasing the core" = return MiSTer to MENU
(`echo load_core /media/fat/menu.rbf > /dev/MiSTer_cmd`, verify CORENAME=MENU) AND clear the
lock — not just clear the lock.

---

## (2026-06-19) — earlier in session: cadence hypothesis FALSIFIED, root refined to bank-$00 cycle-budget+jitter; badline-aware fast read attempt

Operator-driven HW-vs-VICE differential on the SCPU-Kicks DMAGIC title intro (the
FIRST concrete rendering/timing compat divergence of the fork; see memory
`project_kicks_intro_raster_flicker`). The intro = greetings TEXT screen + a cycle-timed
RASTER-BAR overlay. On VICE the overlay is rock-stable; on our core it **flickers**
(overlay lands on some frames, collapses to plain text on others).

**A/B done (build `eb49592e`, `BANK00_FASTFIRE=false` both files, BRAM kept as data
source):** uniform 4-apart cadence FLICKERS IDENTICALLY to the shipped bursty k=2
fast-fire (`4c9cd300`). Operator live: "full text thing again, colors a bit better."
Capture `tools/scpukicks_vice/hw_intro_noskip.py` → `intro_05.png` (overlay fully landed,
matches VICE) alternates with `intro_00.png` (overlay collapsed). ⇒ **cadence-uniformity
is NOT the cause.** Source reverted to shipped `BANK00_FASTFIRE=true` (faster for Doom,
no compat cost). Rig still has `eb49592e` loaded (both flicker; doesn't matter for live view).

**Refined root cause:** the overlay was written for a real SuperCPU running bank $00 from
stable SRAM at ~20 MHz. Our bank $00 runs ~4 MHz effective in BOTH arms (~5× cycle-budget
deficit), and residual jitter (VIC-badline cycle-steal, $D021 I/O writes still on the
4-apart SDRAM path, IRQ-entry latency) makes per-line raster timing wobble → overlay
misses on marginal frames. HARD CEILING: 65C816 datapath can't close faster than k=2
(~8 MHz peak from BRAM; k=1 STA-falsified, pipeline SST-forbidden) — so even a perfect
bank-$00 SRAM tier stays short of the demo's 20 MHz target. May reduce, not guarantee
eliminate, the flicker.

**Badline-aware fast read: BUILT + HW-FALSIFIED (build `de147ffc`), REVERTED.** Added
gated `BANK00_BADLINE_FAST` (bank-$00 BRAM reads advance through VIC badlines). GHDL
elaborated clean + baseline no-op; build green TNS=0. HW result: WORSE — operator "It
looks really bad"; the intro logo renders garbled + alternates with fully-black frames.
Reverted constant to false (HW-FALSIFIED in source); restored shipped `4c9cd300` to rig;
lock released. WHY it backfired: the bar writes are `$D021` I/O (1 MHz-synced regardless);
the badline stall on the bank-$00 code *between* them was partly keeping the CPU phase
CLOSER to the VIC raster — removing it ran the CPU further ahead so each `$D021` landed at
a more-wrong raster position. ⇒ Both cheap levers (cadence-uniformity A/B; badline-
independence) FALSIFIED. The flicker is a delicate fast-code/1MHz-I-O-sync dance, not a
single removable stall. With the k=2 datapath ceiling (<20 MHz) the big bank-$00 SRAM tier
likely can't fully fix THIS demo either. RECOMMEND: log the Kicks DMAGIC-intro raster
overlay as a known SuperCPU-timing incompat (the demo RUNS; only the cycle-timed overlay
flickers) and redirect the loop to a higher-yield compat/speed target. See memory
`project_kicks_intro_raster_flicker` (full both-falsification record).

**(Original candidate writeup, now falsified, kept for context): badline-aware bank-$00 fast read.** The fast
path requires `baLoc='1'` (`fpga64_sid_iec.vhd:4038`), so our bank-$00 execution STALLS
on every VIC badline — UNLIKE a real SuperCPU (off the C64 bus, runs from SRAM through
badlines). A bank-$00 BRAM fast READ touches no bus, so it could safely advance during a
badline = more uniform + faster + more faithful, and would help MANY cycle-timed SCPU
programs (operator: "would help with a lot of other things"). RISK = black-screen class:
advancing the CPU during a badline shifts the FOLLOWING cycle's timing; if that next
access is a write/I-O/SuperRAM op it can collide with VIC badline fetches (bank $00 =
screen/char RAM in shared SDRAM). This is real arbiter surgery, NOT a quick edit.

**GHDL-first plan (the "fix it with sim tests?" answer):** `sim/c64_reduced_harness/
c64_internal_fastfire_tb.vhd` wraps the REAL `fpga64_sid_iec` (so `baLoc`/badline logic is
real) and already measures `cpu_cyc` fires, `sdram_busy`, `en_gap`, cadence spacing +
enforces invariants (no `cpu_cyc` on internal cycles). Use it (with `CLK64_SDRAM=true`,
faithful `clk64_sdram_model`) to PROVE the badline-aware change is arbiter-safe: no
spurious `cpu_cyc`, no `sdram_busy_cnt` disturbance, no fast fire landing in a VIC slot.
Put the change behind a NEW gated constant (default false = RBF-identical) like prior
levers. Harness GAP: does NOT model the c64.sv BRAM override or VIC-badline *bus
contention* with real VIC fetches — so the badline-FIDELITY question and the visual
flicker still need ONE HW build to confirm. SDRAM-busy coupling map (from this session):
fast reads already skip `cpu_cyc`(`:3829-3832`)/`ramCE`(`:3650`); only residual coupling
is `sdram_busy_cnt` load at `:3891` (gated on `cpu_cyc='1' and cs_ram='1'`, which fast
reads don't trigger) — so the read-side hard-split is ~done; the surgery is the badline gate.

---

## (2026-06-16, iter-34) — emu bank-$00 fast-fire BUILT, HW-A/B-FALSIFIED, REVERTED

Acted on the operator's "continue": extended the shipped native-only k=2 bank-$00
fast-fire to emulation mode (gate `emu_mode_816_i='0'` → `emu_mode_816_i='0' or
turbo_m="111"`, `fpga64_sid_iec.vhd`). Build `f0e8be5b` clean (setup slack +0.424ns).

**FALSIFIED by clean HW A/B (identical OSD Smart 4x turbo):** control `4c9cd300` (emu
fast-fire OFF) = **2.85x** (= operator's number), iter-34 (ON) = **2.67x** — uniformly
slower every row including `nop`. Root cause: emu mode runs ~100% from bank $00 incl. the
dense instruction-FETCH stream, so the change routed ALL fetches off the reliable 4-apart
turbo `cpu_cyc` onto the gated 2-apart FAST branch, which is slower for a dense stream.
Native fast-fire wins on Doom only because Doom code runs from SuperRAM (fetches stay off
FAST); FAST helps SPARSE bank-$00 data reads, not as the primary read path.

REVERTED (`git checkout`, no commit — never shipped). `_Test` restored to control
`4c9cd300`. Probe: `tools/synthmark_turbo_probe.py` (uses Smart 4x; NOTE C128 turbo is a
no-op for C64-mode programs — needs the $D030 turbo_state). Compat-safe emu turbo (Smart
4x = 2.85x) is the emu ceiling short of a real bank-$00 SRAM tier / CPU rewrite. Speed
frontier re-confirmed closed. Detail: memory `project_synthmark_vice_speed_differential.md`.

## Latest (2026-06-16, iter-33c follow-up) — SynthMark64 speed differential vs VICE

After the SIMM-detect fix shipped, the operator ran SynthMark64 for speed: **0.94x at
our 1 MHz default**, **2.85x with turbo on** (`POKE 53371,0` = `$D07B`). Differential vs
VICE 3.10 `xscpu64` (real-SuperCPU model, fast-by-default): **14.75x** (operator-reproduced;
our run screenshot `tools/synthmark/vice_result_14_75x.png`).

VICE per-op breakdown is the diagnostic: compute/ram/zeropage **~20–21x**, long store/move
**~15–18x**, color-RAM + I/O **1.77–4.0x** (1 MHz C64 bus, un-accelerable even on real HW
— why even real-SCPU = 14.75x not 20x). **Our 2.85x→14.75x gap is the `ram load/store/move`
rows**: our bank $00 is SDRAM-passthrough vs real-HW fast SRAM ⇒ memory-bound, NOT
CPU-bound (corroborates speed-frontier-closed).

**Top speed lever this points to (operator-gated, NOT autonomous):** extend the shipped
k=2 bank-$00 BRAM fast-fire (`b00_fast_read`, currently native-only) to **emulation mode**
+ emu turbo. SynthMark64 is emu-mode so gets zero benefit today. Risk: emu fast-fire was
HW-falsified once (iter-31b `03d9f2ee` broke Lorenz scpu serial + CIA-tick); any emu
bank-$00 acceleration must keep Lorenz 100% and stay inside the SDRAM-busy gate. GHDL-first.
Full detail: memory `project_synthmark_vice_speed_differential.md`.

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
