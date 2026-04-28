# Session Handoff — 2026-04-28 — v160 (OSD split + write-buffer probe)

Last updated: 2026-04-28 01:30. This file is overwritten each session.

## One-line status

**v160 deployed and clean: vanilla BASIC boots, Asterix title renders via
load_prg path, BRAM RAW bypass holds. Task #11 (split `scpu_rom_opt` into
its own OSD bit `status[86]`) landed. Task #6 (write-buffer drain enable)
was attempted in v159, hardware-regressed to a black screen, and reverted
— cleaner CPU-write reduced-harness scenario needed before the next try.
Task #12 narrowed: a new `c64_sdram_c000_pagetest_tb` proves IOCTL→SDRAM/
BRAM is clean for `$C000-$CFFF`, so the upper-half write-drop must be in
the CPU-write path (`ramCE` / `cpu_cyc` / wb-drain), not IOCTL.**

## What changed in this session

* **`C64_MiSTer/c64.sv`** — `scpu_rom_opt` is now `status[86] & supercpu_enable`
  instead of hardcoded `1'b0`. Reuses the existing OSD slot
  `"d1O[86],SCPU Kickstart ROM,Off,On"` (was unwired). Defaults Off; gated
  by `supercpu_enable` so 6510 mode is unaffected.

* **`sim/c64_reduced_harness/c64_sdram_c000_pagetest_tb.vhd`** + runner
  `run_c000_pagetest.sh` — task-#12 probe. Loads `$C000-$CFFF` (4 KB) via
  IOCTL `download` + `wr` and verifies both SDRAM and BRAM (Port C) match
  the written pattern. Currently **PASSES** end-to-end, ruling the IOCTL
  upper-half address-decode path out of the search space.

* **`C64_MiSTer/rtl/cpu_cache.vhd`** — v159 attempted to flip
  `cacheable_wr <= '1'` for bank-$00 cacheable writes when the FIFO is not
  full (with `wb_full_i` backpressure). Built cleanly (ALMs 86 %, RAM 95 %,
  timing met) but **boot-failed on hardware**: vanilla BASIC went to a
  black screen, CPU crashing with `K=$FC` PC. Reverted in v160; comment
  block records the failure mode for next attempt.

## What's deployed (v160)

* `C64_MiSTer/output_files/C64.rbf`, 4,302,236 bytes, md5 verified at deploy
* MiSTer `/media/fat/_Test/C64.rbf` matches local

Verified post-deploy:
* Vanilla BASIC: clean READY (`v160_basic_smoke.png`)
* Asterix `mister_debug.py load_prg`: SCE title screen renders
  (`v160_asterix_title.png`)
* BRAM RAW bypass: still present (`a_dout <= a_din_d1 when a_we_d1='1'`),
  regression bench still passes structurally + behaviorally

## Open work

* **Task #6** — write-buffer drain enable. Two attempts (v159 ungated,
  v161 SCPU-gated via the new `wb_enable` cache port wired to
  `supercpu_en`) both black-screened on hardware. v162 keeps the
  `wb_enable` scaffolding but holds `cacheable_wr <= '0'`. Diagnostic
  comment in `cpu_cache.vhd` records the cancel-vs-drain race:
  `cache_hit_d1` fires the SDRAM-pipeline cancel during CPUA-CPUD,
  `enableCpu_816`'s `cache_hit_d1` substitute is gated `not at_cpucd`
  (so the substitute mis-fires in exactly that window), and
  `wb_drain_active` simultaneously hijacks `ramAddr/ramDout/ramWE`.
  The CPUC SDRAM write slot is consumed by the drain and the new
  write neither lands in `c64_ram64k` nor in the FIFO's intended
  `wb_addr`. Next attempt must either suppress `wb_drain_active` for
  one cycle after a fresh push so the new write goes through
  `systemAddr` normally, or defer cache absorption to CPUE-CPU9
  (outside the at_cpucd window).

* **Task #12** — IOCTL path is clean for `$C000+`. Bug, if any, lives in
  CPU-write path. Task #6's drain mechanism may already mitigate it for
  bank $00, but the legacy write path (CPUC slot at `cpu_cyc=1`) needs
  GHDL coverage. Build a `c64_reduced_top_v2`-based bench that runs a
  small PRG doing `STA $C000 / LDA $C000` and checks SDRAM + BRAM
  through `probe_addr` after the CPU stops.

* **Task #6 WriteSmart** — `$D074-$D077` + `$D0B3` register set still
  unwired. Real-HW semantics depend on a 128 KB SRAM mirror across banks
  `$00-$01`, but our bank `$01` is SDRAM/SuperRAM (a separate spec gap).
  Wiring the registers as no-ops for software compatibility is cheap;
  making them actually mirror writes is gated on a bank-`$01` SRAM
  rearchitecture.
