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

## Pending / next

- iter-31b lever already committed (`48b6f3c`). Pushes still gated.
- **Speed frontier re-closed** for the loop. Next autonomous work = the COMPAT
  frontier (real SCPU software on HW: GEOS / SCPU-library / timing demos), the
  documented pivot — low-risk, no risky builds, reuses the rig + observer harness.
- Optional/deferred (not a gate): a clean native Doom frame-rate number to put a
  precise figure on the k=2 ~1.24-1.33× model.

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
