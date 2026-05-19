# Session handoff — 2026-05-19 (afternoon)

## Major milestone landed: v356 fully validated

**RBF MD5: `19839ee723662d8fb439208dd0ca6e7b`** (3,837,164 bytes)
**Branch: `vanilla-cpu-swap`** — see `git log --oneline | head -8`

### What works on v356

| Title    | Status     | Verified by                  | Reproducer                      |
|----------|------------|------------------------------|---------------------------------|
| Wolf3D   | PLAYABLE   | E1L1 starting room visible   | menu break via SPACE at HS→demo |
| Doom     | PLAYABLE   | E1M1 3D corridor + HUD       | `tools/doom_v356_PLAY.py`       |
| Lorenz t65 | PASS    | runs 32m through SCPU regtest | `tools/lorenz_run.py t65 --mins 32` |
| Lorenz scpu | PASS   | `orazx - ok` at 32m cap       | `tools/lorenz_run.py scpu --mins 32` |

### Critical new tooling

- **`tools/mhold.py`** — uinput keyboard that HOLDS a key for N seconds.
  Required for Doom because HW Doom runs at ~3 fps internal; mtype.py's
  40 ms tap is shorter than one Doom frame.
- **`tools/doom_v356_PLAY.py`** — canonical 4-step Doom recipe.
- **`tools/jtype.py` / `tools/joyfire.py`** — virtual gamepad via uinput
  (spoofs VID/PID 0810/e501 to pick up the existing C64 map). Doom didn't
  end up needing this, but it's available for cores that genuinely require
  joystick input.

### Memory updates (top of MEMORY.md)

1. **v356 LORENZ REGRESSION PASS** — `project_v356_lorenz_pass.md`
2. **DOOM PLAYABLE** — `project_doom_v356_PLAYABLE.md`
3. **WOLF3D PLAYABLE FROM MENU** — `project_wolf3d_v356_RUNS.md`
4. v356 IRQ wedge fix — `project_wolf3d_v356_irq_wedge_fixed.md`

### Commits this session (top-down)

- `faf5c4f` — Lorenz regression PASS both modes
- `61bdafa` — Doom v356 reaches 3D gameplay (mhold.py recipe)
- `5b63445` — Wolf3D level1 movement test results
- `3aa3bdf` — Wolf3D v356 PLAYABLE (full menu path)
- `1e01f23` — Wolf3D attract cycle proof
- `a953952` — Wolf3D v356 RUNS — extended monitor
- `db149d6` — v356 RTL fix: universal IRQ ack via $FF00 stub

## Candidate next tasks (in rough priority order)

1. **Implement missing SCPU registers.** Per
   `project_scpu_register_implementation_status.md`, $D072/$D073
   (system 1 MHz), $D074-$D077 (optim mode), $D0BC (detect), $D07E/$D07F
   (gating), $D0B4 (optim status) are stubbed. Wolf3D may poll one of
   these during its second wedge; Doom doesn't seem to need them.

2. **Investigate Doom's 3 fps render rate.** UART shows main loop
   spinning $2A:$55A0–$55D2 at ~3 frames/s. Likely causes: IRQ overhead
   from $FF00 stub, slow SuperRAM access for JIT recompiler, unmapped
   ROM-bank stalls. Could improve to 6-10 fps with targeted RTL work.

3. **Wolf3D "Working..." wedge** (after setup screen). Memory notes the
   Bliss-Box second wedge case-study is now superseded by Turbo Off →
   Smart 4x being the actual cause. With v356, Wolf3D reaches L1 starting
   room but is stuck — keyboard movement keys don't advance the player.
   Joystick port 2 may be required for in-game movement.

4. **Doom in-game inputs.** Tested 2026-05-19: keyboard (all arrows +
   WASD/IJKL/CTRL/SPACE/ALT/TAB/ESC up to 10 s sustained holds) AND
   virtual USB gamepad at js0/joyA/port-2 (real device unbound) — NO
   view change. View stays static; player does not move/turn/shoot.
   Hash flips are face-icon animation only. Likely DEMO playback or
   port-1 vs port-2 mapping. See `project_doom_v356_ingame_unresponsive.md`
   for next-probe ideas.

5. **U64 differential** — Ultimate 64 hardware is available at 192.168.50.94
   for cross-validation if any new bug surfaces.

## State of the dev MiSTer

- **CORENAME**: `C64_doomturbo` (last loaded was the doom MGL)
- **RBF**: v356 at `/media/fat/_Test/C64.rbf` (md5 `19839ee...`)
- **Bliss-Box / usb gamepad / 8BitDo keyboard**: all rebinded after
  earlier USB-unbind tests for the joystick rabbit hole.
- **C64.cfg**: standard turbo config; `C64_doomturbo.cfg` mirrored for
  the Doom MGL's setname.

## Background processes (none active)

No long-running scripts on either side as of commit `faf5c4f`.
