# Session Handoff — 2026-04-29 — v168/v169 + Tasks #25, M10K R3

Last updated: 2026-04-29 ~00:25 UTC. Overwritten each session.

## One-line status

**v167 still shipped baseline. Loop ran for 3 tasks: (#1) Asterix MGL
autorun — v168 attempted, FAILED (start_strk timing was wrong layer);
(#25) BRAM probe wiring — DONE (commit 82bd475); (#3 = M10K R3) cache
8KB→4KB — committed (4275388), v169 build in progress for hardware
validation.**

## Recent commits (top of master)

```
4275388  M10K R3: shrink cpu_cache from 8KB to 4KB              [HEAD]
8713403  v168: defer start_strk auto-RUN pulse until reset_n=1
82bd475  Task #25: wire BRAM probe through c64_reduced_top_v2
c420134  kernal_drain bench: external-name probes + lower PASS bar
f0958f9  docs: handoff captures Phase A finding (v164 cpu_cache exonerated)
30978eb  Phase A bench fix: stimulus timing — exonerates v164 cpu_cache half
4a714de  Phase A: kickstart-drain GHDL bench (sim discriminator HEAD vs v164)
```

## Loop progress

### Task #1 — Asterix MGL autorun (status: FIX ATTEMPTED, NOT WORKING)

v168 commit 8713403 deferred the `start_strk` pulse until `reset_n=1`,
hypothesising the act SM was clearing act on reset. Hardware test
2026-04-29 ~00:11 UTC:

- Vanilla BASIC: GREEN (`.v168_vanilla.png`).
- SCPU library sweep: 10/10 PASS (`logs/scpu_sweep_20260429T001728.csv`).
- `asterix.mgl`: STILL HANGS at corrupt-BASIC READY
  (`.v168_asterix_mgl.png`). PEEK returns OUT OF MEMORY.

Real bug, deeper than start_strk: under MGL initial-startup,
ioctl_download rises while cold-boot RESET is asserted, so the
PRG-load-reset trigger at `c64.sv:447` (`~old_download &
ioctl_download & load_prg`) loses to the RESET branch at line 443.
By the time RESET deasserts, ioctl_download has no fresh rising edge
→ 100000-cycle PRG re-reset never fires → BASIC NEW chain incomplete
→ BASIC pointers stay corrupt.

v168 fix is theoretically sound for one race and harmless to vanilla
+ sweep — KEPT in tree. v170 next attempt: extend PRG-load-reset
trigger to also fire on RESET-fall + ioctl_download-still-high.

Memory: `project_v168_start_strk_defer_partial.md`.

### Task #25 — BRAM probe wiring (status: DONE)

Commit 82bd475. `sim/c64_reduced_harness/c64_reduced_top_v2.vhd` now
exposes the c64_ram64k.ram shared variable through `bram_probe_data`
via VHDL-2008 external-name upward path
`<< variable ^.dut.dut.ram64k_inst.ram : ram_t >>`. Works because all
4 benches label the c64_reduced_top_v2 instance `dut`. Zero synthesis
impact (sim-only).

GHDL gotcha discovered: external-name aliases inside sensitized
processes (`process(clk32)`) crash with TYPES.INTERNAL_ERROR. Use
wait-based process. Documented for future sim work.

Sim regressions still PASS:
- `run_kernal_drain.sh`: 64189/65536 bank-$00 nonzero
- `run_harness_v2.sh`: 84/84

Memory: `project_task25_bram_probe_wiring.md`.

### Task #3 — M10K R3 cache shrink (status: COMMITTED, BUILDING)

Commit 4275388. `C64_MiSTer/rtl/cpu_cache.vhd`:
- 1024 → 512 lines (8KB → 4KB).
- Tag width 11→12 bits (now `bank(8) & addr(15:12)`).
- Line index `addr(11:3)`.
- All array bounds, signal widths, flush terminal compare updated.

Sim regressions PASS at HEAD: kickstart_drain 8/8, kernal_drain
64189/65536, harness_v2 84/84. v169 Quartus build in progress
(background task `bispvpvfu`, log `.v169_build.log`). Expected
RAM utilisation: 98 % → ~96 %; ALM ~85 %; rbf size unchanged.

Memory: `project_m10k_r3_cache_shrink.md`.

## What's on the dev MiSTer right now

- `/media/fat/_Test/C64.rbf` = v168 (8713403, md5
  `8ba431fd2192799d14e0260913129473`). Vanilla GREEN, sweep 10/10.
- v167 cached at `.v167_restored.rbf` md5
  `9cbd4b6b8e52d1957f528cb486a27ae5` for fast revert if v169 fails.
- v168 cached at `.v168_built.rbf`.

## Open task graph (post-loop)

- **Task #1 (deferred)** — extend PRG-load-reset trigger condition to
  fire on RESET-fall + ioctl_download-still-high. v168's start_strk
  fix is in place but doesn't cover this. Next attempt: v170.
- **Task #3 follow-up** — once v169 builds, deploy + smoke vanilla +
  sweep + asterix-via-load_prg + bank01_sram_tb. If all pass, v169
  becomes new baseline; if any fail, revert 4275388.
- **Task #26 (still open)** — hardware bisect of fpga64_sid_iec.vhd
  v164 subsets. Closed structurally per
  `project_v166_bisect_failed_three_rounds.md` — only revisit if a
  new approach replaces the cache_hit_rd-on-write fanout.
- **$D078 Step 2** — move cache flush off $D078, deferred until
  multi-program demand justifies.
- **Task #14 system bench** — wire scpu64.mif into
  simple_sdram_model.vhd so kernal_drain can exercise kickstart ROM
  path. Still 3-5h work; deferred while bisect is closed.

## Useful commands cheat-sheet

```bash
# Deploy current build
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf

# Smoke vanilla BASIC
python tools/mister_debug.py uart 8
python tools/mister_debug.py screen vanilla.png

# Run full SCPU library sweep
python tools/scpu_library_sweep.py

# Asterix title via load_prg path (NOT MGL — MGL still broken)
python tools/mister_debug.py load_prg asterix.prg
python tools/mister_debug.py keys "RUN" && python tools/mister_debug.py keys "enter"

# Bank-$01 dprom unit bench (regression guard for v167 RTL)
bash sim/p65c816_tb/run_bank01_sram_tb.sh   # 10/10 PASS expected

# Kickstart-drain bench (HEAD baseline + v164 verifier)
bash sim/p65c816_tb/run_kickstart_drain_only.sh  # 8/8 PASS on HEAD

# Harness benches (system-level regression guards)
bash sim/c64_reduced_harness/run_harness_v2.sh    # 84/84 PASS
bash sim/c64_reduced_harness/run_kernal_drain.sh  # bank-$00 nonzero ≥32k
```

## Do-not-touch list

- `/media/fat/_Computer/C64.rbf` — must stay vanilla MiSTer.
- v164 path-(b) revival is shelved per
  `project_v166_bisect_failed_three_rounds.md`. Do not re-attempt
  without a fresh approach.
- v167 RAM was at 98 %; v169 (M10K R3) targets ~96 %. Any new M10K
  consumer still needs another reclaim pass (R4 chargen_d/p ~3
  blocks each).
