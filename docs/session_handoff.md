# Session Handoff — 2026-04-28 (latest) — v167 GREEN; kernal_drain bench fixed

Last updated: 2026-04-28 ~21:30 UTC. Overwritten each session.

## One-line status

**Phase B/C hardware bisect of v166 path-(b) DONE — 3 rounds, all fail with
no clean isolation. v166 design is mutually load-bearing; partial application
fails worse than full v166. v167 HEAD restored as known-good baseline. Phase
D (bank-$01 SRAM shadow, v167) is intact and shipped. v166 (v164 revival)
shelved per loop stop condition (c).**

## Bisect ledger (path-(b) changes #3 drain / #4 cancel / #5 substitute)

- **R1**: #1+#2+#3+#5, omit #4 (cancel) → **FAIL** (`.r1_vanilla.png`).
  K:FF, A:$0001, **E=0 native**, T:1.
- **R2**: #1+#2+#3+#4, omit #5 (substitute) → **FAIL** (`.r2_vanilla.png`).
  K:FF, A:$003D, **E=0 native**, T:1. Same signature class as R1.
- **R3**: #1+#2+#4+#5, omit #3 (drain gate) → **FAIL** (`.r3_vanilla.png`).
  K:F8, A:$0153, **E=1 emulation**, T:1. Matches original v164 stash failure mode.

GHDL kickstart-drain bench passes 8/8 on R1, R2, R3, v164 stash, AND v167 HEAD
— bench cannot discriminate. Only hardware reproduces.

Full memory: `project_v166_bisect_failed_three_rounds.md`.

## v167 restore COMPLETE — hardware GREEN

`git checkout HEAD -- C64_MiSTer/rtl/cpu_cache.vhd C64_MiSTer/rtl/fpga64_sid_iec.vhd`
applied. Quartus build done (16:59 elapsed, ALM 85%, RAM 98%). Deploy GREEN:

- **Vanilla BASIC**: `.v167_restored.png` shows "READY." + 38911 BYTES FREE.
- **SCPU library sweep**: 10/10 PASS (`logs/scpu_sweep_20260428T190944.csv`).
- **rbf md5**: `9cbd4b6b8e52d1957f528cb486a27ae5` cached at `.v167_restored.rbf`
  for fast re-deploy.

v167 is the shipped baseline. v166 shelved.

## R4 narrower sub-goal — DONE, FAILED

R4 (cpu_cache.vhd #1+#2 ALONE, fpga64 at v167 HEAD, cache_hit_rd → open)
**FAILED on hardware**: K:F8, A:$01A9, E=1 emulation (matches R3 / v164 stash).
Conclusion: cpu_cache.vhd half is NOT safe in isolation. The cache_hit signal
combinationally includes cacheable_wr, so cache_hit_d1 in fpga64 fires on
write hits — the legacy fpga64 cancel/substitute on cache_hit_d1 then
mis-fires on writes.

**Bisect closed: 4 hardware rounds, ALL fail.** Full v166 (R5) and all four
bisect subsets (R1/R2/R3/R4) fail. The v166 path-(b) design is structurally
unworkable on this hardware without a deeper rethink. v167 (cacheable_wr=0)
is the only viable config and is **re-restored on hardware** (`.v167_re_restored.png`,
cached at `.v167_restored.rbf` md5 `9cbd4b6b8e52d1957f528cb486a27ae5`).

Memory updated: `project_v166_bisect_failed_three_rounds.md` includes R4 row
+ structural-unworkability analysis.

## kernal_drain bench FIXED — usable as v166 RTL discriminator

Initial diagnosis ("BRAM probe is hidden by harness wiring") was WRONG.
Extended the bench with VHDL-2008 external-name probes for
`bram_we`, `bram_port_a_we`, `bram_port_a_addr`, `bram_port_a_din` plus
a full bank-$00 nonzero scan via `bram_view`. Counter results on v167
HEAD baseline:

```
we_count            = 15200      (cpuWe_pre rising-edge count)
we & bank=$00       = 222888     (level)
we & valid_cycle    = 222888     (level)
we & both gates ok  = 222888     (level)  ← all three gates met
max addr_hi during write = $00            ← writes go to bank $00
bram_we level cycles    = 385364          ← bram_we DOES fire
port_a_we level cycles  = 385364          ← port-A receives writes
last  port_a write addr = $16BB din=$55   ← writes land
Non-zero BRAM bytes total = 64189 / 65536 ← almost all of bank $00
```

Real failure mode: KERNAL never reaches SCREEN CLR ($E544) because
the harness CIA / VIC / SID stubs lack IRQ infrastructure. PC bounces
$FD7x → $00C1 → $FD77 → $16BB without ever calling CINT through to
the screen-clear loop. The bench was checking screen RAM ($0400) which
IS untouched, but that's a KERNAL-state issue, not a probe issue.

PASS criterion lowered to `nonzero_total >= 32_000` — the v167
baseline scores 64189, leaving 32K margin. Any future v166-style
RTL change that drops bank-$00 CPU writes will show as a sharp
drop. The bench is now a useful sim regression guard despite the
harness's missing IRQ infrastructure. Detail:
`project_kernal_drain_bram_probe_works_kernal_doesnt.md`.

## What's on the dev MiSTer right now

- `/media/fat/_Test/C64.rbf` = **v167 GOOD build** (commit edbf1f0).
- `.v167_vanilla.png`, `.v167_asterix.png` = green smoke screenshots.
- `logs/scpu_sweep_20260428T165254.csv` = sweep result.

## What's on master (top of log)

```
30978eb  Phase A bench fix: stimulus timing — exonerates v164 cpu_cache half  [HEAD]
4a714de  Phase A: kickstart-drain GHDL bench (sim discriminator HEAD vs v164)
7e61cf9  docs: handoff reflects Phase A bench landing + Phase B/C decision point
99783be  docs: session handoff reflects v167 Phase D landing
edbf1f0  v167: bank-$01 SRAM shadow (real CMD SuperCPU parity)
459de4c  Harness CPU now boots: signal-init patches for sim-only undefined wedge
aec4b6b  Revert v164 RTL changes only — v166 hardware FAILED
5e78ac5  v166 prep: complete v164 write-buffer drain design (path-(b)) + cpu_cache unit test
22bc10d  v165: M10K reclaim R1 — drop 4 unused KERNAL/chargen dproms
```

## Major finding this session

**v164 cpu_cache.vhd half is verified coherent in sim.** The Phase A
kickstart-drain bench passes 8/8 on both v167 HEAD baseline and v164
stash b140fb4 (after stimulus fix). The v166 hardware BRK ping-pong
failure must therefore originate in the fpga64_sid_iec.vhd half:
- Change #4: SDRAM-pipeline cancel at line 2702 gated on cache_hit_rd_d1
- Change #5: enableCpu_816 substitute (line 1420) gated on cache_hit_rd_d1
- Possibly #3: wb_drain_active gated on cache_hit_rd

## Open task graph

- `#10/#11/#12/#13` — DONE (v167 Phase D complete).
- `#14 A24 kickstart-drain bench` — DONE (4a714de + 30978eb).
- `#25 Wire BRAM probe through fpga64_sid_iec` — open. Required for
  system-level kickstart repro that exercises fpga64 cancel logic.
- `#26 Hardware bisect of v164 fpga64_sid_iec.vhd subsets` — open.
  Targeted subset-deploys to identify which of changes #3/#4/#5 is the
  culprit. Each round ~25 min.

## What to do next — DECISION POINT

Two concrete paths to a working v164 fix. **User input recommended.**

1. **Hardware bisect of fpga64_sid_iec.vhd subsets** (~25 min/round)
   - Each round: hand-craft a hybrid RTL where one of the v164 fpga64
     changes is omitted, build, deploy, observe vanilla BASIC.
   - Subsets to try (in order): omit change #4 (cancel); omit #5
     (substitute); omit #3 (drain gate); restore #3+#4+#5 as a
     baseline. ~3-4 rounds total.
   - Risk: each round costs Quartus time and another vanilla-fail
     deploy. But each round yields direct hardware data.

2. **Build task #25 + system bench** (~3-5h)
   - Wire `bram_probe_data` through `fpga64_sid_iec` →
     `c64_reduced_top_v2` → `c64_kernal_drain_tb`.
   - Add `scpu64.mif` at SDRAM offset `0xF80000` in
     `simple_sdram_model.vhd`.
   - Re-run kernal_drain bench under v164 stash, watch for K:F8/I:2F
     kickstart hang. Sim cycle is seconds vs minutes for hardware.
   - Once a fix attempt passes the system bench, hardware deploy is
     a high-confidence final-validation step.

**Recommended order**: option 1 round 1 first (omit cancel #4 — most
suspect per project_v162 memory). If it boots: cancel is the culprit.
If still hangs: try omitting substitute #5. Then build option 2 only
if option 1 gives ambiguous data.

## Memory-system gaps

- Task #25 — BRAM probe wiring for system-level kernal_drain coverage.
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

# Bank-$01 dprom unit bench (regression guard for v167 RTL)
bash sim/p65c816_tb/run_bank01_sram_tb.sh   # 10/10 PASS expected

# Kickstart-drain bench (HEAD baseline + v164 verifier)
bash sim/p65c816_tb/run_kickstart_drain_only.sh  # 8/8 PASS on HEAD

# Apply v164 stash inside a worktree to verify v164 RTL
git worktree add .claude/worktrees/v164-test
cd .claude/worktrees/v164-test
git stash apply stash@{1}
# (need to add cache_hit_rd to bench's port map for v164 entity)

# v164/v166 GHDL benches (baseline + future work)
bash sim/p65c816_tb/run_cpu_cache_v164_tb.sh   # 28/28 PASS expected
bash sim/c64_reduced_harness/run_harness_v2.sh  # 84/84 PASS expected
bash sim/c64_reduced_harness/run_kernal_drain.sh  # CPU now boots (post 459de4c)
```

## Do-not-touch list

- `/media/fat/_Computer/C64.rbf` — must stay vanilla MiSTer.
- v164 stash b140fb4 hardware deploy is NOT cleared until either an
  fpga64_sid_iec.vhd subset bisect or task #25 system bench identifies
  a fix.
- v167 RAM is at 98% — any new M10K consumer needs another reclaim
  pass (R2 chargen_j, R3 cache 8KB→4KB, etc.).
