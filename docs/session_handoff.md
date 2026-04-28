# Session Handoff — 2026-04-28 (latest) — Phase A bench landed; Phase B/C blocked

Last updated: 2026-04-28 ~17:30 UTC. Overwritten each session.

## One-line status

**v167 (bank-$01 SRAM shadow) deployed and green. Phase A kickstart-drain
GHDL bench landed (commit 4a714de) — discriminates HEAD vs v164 stash.
Phase B/C (re-attempt v164 hardware as v166) blocked: needs either
deeper S_A5 investigation, task #25 system bench, or accept-the-cost
hardware bisect cycles. User decision needed.**

## What's on the dev MiSTer right now

- `/media/fat/_Test/C64.rbf` = **v167 GOOD build** (commit edbf1f0).
- `.v167_vanilla.png`, `.v167_asterix.png` = green smoke screenshots.
- `logs/scpu_sweep_20260428T165254.csv` = sweep result.

## What's on master (top of log)

```
4a714de  Phase A: kickstart-drain GHDL bench (sim discriminator HEAD vs v164)  [HEAD]
99783be  docs: session handoff reflects v167 Phase D landing
edbf1f0  v167: bank-$01 SRAM shadow (real CMD SuperCPU parity)
459de4c  Harness CPU now boots: signal-init patches for sim-only undefined wedge
aec4b6b  Revert v164 RTL changes only — v166 hardware FAILED
5e78ac5  v166 prep: complete v164 write-buffer drain design (path-(b)) + cpu_cache unit test
22bc10d  v165: M10K reclaim R1 — drop 4 unused KERNAL/chargen dproms
```

## What changed this session

### v167 Phase D (DONE earlier — commit edbf1f0)
- Bank-$01 SRAM dprom in fpga64_buslogic.vhd. Real CMD SuperCPU parity.
- bank01_sram_tb 10/10 PASS, hardware all green.

### Phase A kickstart-drain bench (DONE — commit 4a714de)
- `sim/p65c816_tb/p65c816_kickstart_drain_tb.vhd` + runner.
- Auto-detects v167 HEAD vs v164 stash via `wb_pending` after pushes.
- v167 HEAD: 8/8 PASS (cacheable_wr=0, no pushes).
- v164 stash (applied via worktree): 7/8 — S_A5 wb_pending residual
  after 4 push + 4 drains. Cause unconfirmed.

## Open task graph

- `#10/#11/#12/#13` — DONE (v167 Phase D complete).
- `#14 A24 kickstart-drain bench` — DONE (4a714de).
- `#25 Wire BRAM probe through fpga64_sid_iec` — open. Required for
  system-level kickstart repro. ~3-5h work.
- `#26 v164 bisect — cpu_cache only OR fpga64_sid_iec only` — open.
  Hardware deploy of each half separately. ~1h per round.

## What to do next — DECISION POINT

Three concrete paths to unblock another v166 hardware attempt. Each has
a different cost/payoff. **User input recommended** before committing
the cycles.

1. **Investigate S_A5 wb_pending residual** (~1h, cheap)
   - Add wave-dump observer on `wb_count`/`wb_head`/`wb_tail` in the
     bench, identify whether the residual is a stimulus bug or a real
     v164 cpu_cache.vhd issue.
   - If real: candidate root cause for the kickstart hang.
   - If stimulus: bench needs polish but no new hardware insight.

2. **Build task #25 + system bench** (~3-5h, definitive)
   - Wire `bram_probe_data` through `fpga64_sid_iec` →
     `c64_reduced_top_v2` → `c64_kernal_drain_tb`.
   - Load real `rtl/roms/scpu64.mif` at SDRAM offset `0xF80000` in
     `simple_sdram_model.vhd`.
   - Re-run kernal_drain bench, watch for K:F8/I:2F kickstart hang.
   - Deterministic system reproducer for the v166 failure.

3. **Hardware bisect** (~1h per round, 2-3 rounds expected)
   - Round 1: apply v164 cpu_cache.vhd-only, build, deploy. If vanilla
     boots → fpga64_sid_iec.vhd half is the culprit.
   - Round 2: apply v164 fpga64_sid_iec.vhd-only, build, deploy. If
     vanilla boots → cpu_cache.vhd is the culprit.
   - Risk: another v166-style hang with no new sim signal.

Recommended order: option 1 first (cheap, possibly informative), then
option 3 (data-rich at known cost), option 2 only if 1+3 don't yield.

## Memory-system gaps

- Task #25 — BRAM probe through fpga64_sid_iec for system-level
  kernal_drain coverage.
- $D078 Step 2 (move cache flush off $D078) — deferred.

## Useful commands cheat-sheet

```bash
# Deploy current build
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf

# Smoke vanilla BASIC
python tools/mister_debug.py uart 8
python tools/mister_debug.py screen vanilla.png

# Run full SCPU library sweep
python tools/scpu_library_sweep.py

# Asterix title via load_prg path (NOT MGL)
python tools/mister_debug.py load_prg asterix.prg
python tools/mister_debug.py keys "RUN\n"

# Bank-$01 dprom unit bench (regression guard)
bash sim/p65c816_tb/run_bank01_sram_tb.sh   # 10/10 PASS expected

# Kickstart-drain bench (HEAD baseline)
bash sim/p65c816_tb/run_kickstart_drain_only.sh  # 8/8 PASS on HEAD

# v164/v166 GHDL benches (still useful for future bisect)
bash sim/p65c816_tb/run_cpu_cache_v164_tb.sh   # 28/28 PASS expected
bash sim/c64_reduced_harness/run_harness_v2.sh  # 84/84 PASS expected
bash sim/c64_reduced_harness/run_kernal_drain.sh  # CPU now boots (post 459de4c)
```

## Do-not-touch list

- `/media/fat/_Computer/C64.rbf` — must stay vanilla MiSTer.
- v164 path-(b) hardware deploy is NOT cleared until either S_A5 root
  cause identified OR system bench reproduces the K:F8 hang AND a fix
  verifies in sim.
- v167 RAM is at 98% — any new M10K consumer needs another reclaim
  pass (R2 chargen_j, R3 cache 8KB→4KB, etc.).
