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

## Pending / next

- **Commit** the lever (c64.sv + fpga64_sid_iec.vhd + docs). Pushes still gated.
- Optional: a clean native (Doom) frame-rate measurement to put a precise number on
  the ~1.24-1.33× model (nice-to-have, not a gate).
- Possible follow-on speed: k=1 (1-apart) native fast-fire if STA allows (~1.41×
  per the sizing model) — would need its own STA proof + HW A/B.

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
