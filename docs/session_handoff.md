# Session handoff — 2026-05-20

## This session: page-mode SDRAM investigation — SHELVED

**Outcome:** Build C (page-mode with COLD/HIT/CONFLICT paths) wedges KERNAL
boot on hardware. Root cause is **not** an SDC constraint issue (793fa12
fixed that, but Build C2 wedged identically). Page-mode is fundamentally
incompatible with the existing bus arbiter without Layer 2.

**HEAD:** `9f9e2c2` on branch `vanilla-cpu-swap`.
**Live `sdram_pm.v`:** Build B (baseline + `output ready`), byte-equivalent
to commit `cc89d27`.
**Build C draft preserved at commit `50d8bd3`** for future revival.

### Root cause (full detail in `memory/project_sdram_page_mode_needs_layer2.md`)

The bus arbiter at `fpga64_sid_iec.vhd:2620` is a 2-stage clk32 shift
register → `enableCpu` fires ~6 clk64 cycles after `cpu_cyc` asserts.
Build C's CONFLICT path (PRECHARGE → tRP → ACTIVE → tRCD → READ → CL) needs
sample-q=7, which is 1 cycle past the 6-cycle CPU read deadline. KERNAL
boot's ZP↔stack alternation (different rows, same bank) hits CONFLICT every
other access → CPU latches the previous access's dout_r → garbage RAM →
PC bounces $0107-$013B with M=$FFFF FFFF FFFF FFFF.

### Decision point for next session

Three credible paths, choose one before resuming SDRAM work:

1. **Layer 2** — gate `cpu_cyc_s` advancement on synchronized `sdram_ready`.
   Significant change to the C64 bus arbiter (fpga64_sid_iec.vhd:2617-2622).
   Highest risk; unlocks Build C; preserves both 6510 + SCPU compatibility
   if done carefully.
2. **Alternative speedup** — pre-PRECHARGE during idle (kills HIT benefit,
   moot), reclaim EXT slots (iter-1.5 attempt, previously failed), DDR3
   (high-latency, unsuitable for per-instruction fetch). None obviously
   better than Layer 2.
3. **Stop SDRAM speedup** — return to v356-era priorities: investigate
   Doom's 3 fps render rate (IRQ overhead? JIT cache thrash?), missing
   SCPU registers, Wolf3D in-game inputs.

### State of the dev MiSTer

- **Live RBF:** still v356 at `/media/fat/_Test/C64.rbf` (md5 `19839ee...`).
  Page-mode builds B/C/C2 were deployed and rolled back during this
  session; the v356 image is what's left.
- **CORENAME:** `C64_doomturbo` (Doom MGL was the last interactive load).
- **C64.sdc:** keeps the `*sdram_pm:sdram|sd_*` filter (commit 793fa12).
  This is the right pattern even if `sdram_pm.v` is byte-equivalent to
  baseline `sdram.v`, because the entity is named `sdram_pm`.

### Commits this session

- `9f9e2c2` — revert sdram_pm.v to Build B (page-mode shelved)
- `793fa12` — C64.sdc filter pattern fix (`sdram` → `sdram_pm`)
- `50d8bd3` — draft Build C (preserved for future revival)
- `cc89d27` — Build B (baseline + ready output)
- `b46aad2` — Build A reset-counter fix
- `faef16f` — Build A smoke-test wire-up

### Memory updates this session

- `project_sdram_page_mode_needs_layer2.md` — full Build C analysis
- `feedback_renaming_sdram_entity_breaks_sdc.md` — SDC filter gotcha

## v356 milestones (still valid from yesterday)

| Title       | Status   | Verified              | Reproducer                          |
|-------------|----------|-----------------------|-------------------------------------|
| Wolf3D      | PLAYABLE | E1L1 starting room    | menu break via SPACE at HS→demo     |
| Doom        | PLAYABLE | E1M1 3D corridor+HUD  | `tools/doom_v356_PLAY.py`           |
| Lorenz t65  | PASS     | 32m SCPU regtest      | `tools/lorenz_run.py t65 --mins 32` |
| Lorenz scpu | PASS     | `orazx - ok` at 32m   | `tools/lorenz_run.py scpu --mins 32`|

## Background processes (none active)
