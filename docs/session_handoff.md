# Session Handoff — 2026-04-28 (latest) — v167 Phase D LANDED

Last updated: 2026-04-28 ~17:00 UTC. Overwritten each session.

## One-line status

**v167 (commit edbf1f0) deployed: bank-$01 SRAM shadow live. Vanilla
BASIC GREEN, scpu_library_sweep 10/10 PASS, Asterix title renders.
Phase A→D plan complete.**

## What's on the dev MiSTer right now

- `/media/fat/_Test/C64.rbf` = **v167 GOOD build** (commit edbf1f0).
- `.v167_vanilla.png` = vanilla BASIC READY screenshot.
- `.v167_asterix.png` = Asterix title bitmap (SCE Presents).
- `logs/scpu_sweep_20260428T165254.csv` = sweep result.

## What's on master (top of log)

```
edbf1f0  v167: bank-$01 SRAM shadow (real CMD SuperCPU parity)  [HEAD]
459de4c  Harness CPU now boots: signal-init patches for sim-only undefined wedge
aec4b6b  Revert v164 RTL changes only — v166 hardware FAILED
5e78ac5  v166 prep: complete v164 write-buffer drain design (path-(b)) + cpu_cache unit test
22bc10d  v165: M10K reclaim R1 — drop 4 unused KERNAL/chargen dproms
```

## What changed this session

### Phase A — harness CPU debugged (DONE, commit 459de4c)
- Fixed sim-only `'U'` wedge in fpga64_sid_iec.vhd via signal-init sed
  patches in `run_kernal_drain.sh`. enableCpu_816_pulses 0 → 247120.
- Bench's SDRAM probe still mismatches because SCPU bank-$00 writes
  go to BRAM. Task #25 (BRAM probe wiring) deferred — not blocking
  Phase D.

### Phase B/C — v166 deploy + revert (DONE, commits 5e78ac5/aec4b6b)
- v166 (full v164 path-(b) design) FAILED on hardware: BRK ping-pong,
  E=0 native mode, F advancing. Surgical RTL revert kept the bench
  infrastructure for future iteration.

### Phase D — bank-$01 SRAM shadow LANDED (DONE, commit edbf1f0)
- Added 64KB `bank01_sram` dprom + `bank01_cs` decode + `dataToCpu`
  mux branch in `fpga64_buslogic.vhd`. Real CMD SuperCPU parity
  (banks $00 + $01 = SRAM, SuperRAM starts $02).
- SDRAM mirror left ON for writes — minimum blast radius. Reads
  intercepted by dprom only.
- Unit bench `sim/p65c816_tb/bank01_sram_tb`: 10/10 PASS.
- Hardware: vanilla BASIC GREEN, scpu sweep 10/10, Asterix renders.
- Resource budget: ALM 85%, RAM 98%, block-mem 75%. Tight on RAM but
  under the 95% pre-R1 ceiling. Quartus packed bank-$01 dprom to
  ~65 M10K blocks (more than the ~16 design estimate).

## Open task graph (updated)

- `#7  C7: Quartus full build (v166)` — DONE (failed → reverted).
- `#8  C8: Deploy v166 + smoke matrix` — DONE (revert + v165 verified).
- `#10 D10: bank01_sram 64KB dprom` — DONE (commit edbf1f0).
- `#11 D11: Re-route bank $01 to SRAM dprom` — DONE.
- `#12 D12: GHDL bench bank $01 SRAM round-trip` — DONE 10/10.
- `#13 D13: Build / deploy / smoke v167` — DONE.
- `#25 Wire BRAM probe through fpga64_sid_iec` — open. Needed for
  kernal_drain bench to verify SCPU bank-$00 writes that land in BRAM.
- `#26 v164 bisect — cpu_cache only OR fpga64_sid_iec only` — open.
  Defer until task #25 lands so sim can reproduce v166 BRK ping-pong.

## What to do next

1. **Doom regression on v167** (nice-to-have): Doom uses bank $20+,
   orthogonal to bank-$01 dprom; SCPU sweep already covers SuperRAM
   path. To test, build a custom MGL pointing at
   `/media/fat/_Test/C64.rbf` (current doom.mgl targets vanilla
   `_Computer/C64.rbf`).
2. **Task #25**: wire BRAM probe through fpga64_sid_iec entity port
   → c64_reduced_top_v2 → c64_kernal_drain_tb. Unblocks #26.
3. **Task #26**: v164 bisect to find which half of v164 path-(b) breaks
   vanilla BASIC. Hardware iterations: cpu_cache.vhd-only deploy, then
   fpga64_sid_iec.vhd-only deploy. Use task #25's bench to reproduce
   in sim before re-trying on hardware.
4. **Bank $01 ROM image** (potential v168): real CMD SuperCPU populates
   bank $01 with KERNAL/BASIC ROM shadow at boot. Currently zero-init.
   Add kickstart-time copy-from-bank-$00-ROM fill if a specific title
   needs it.
5. **SDRAM mirror cleanup** (potential v168): gate `cart_we` off for
   bank $01 in c64.sv to save SDRAM bandwidth — no correctness impact,
   defer until profiling motivates it.

## Memory-system gaps remaining

- Task #25 — BRAM probe through fpga64_sid_iec for kernal_drain bench.
- $D078 Step 2 (move cache flush off $D078) — deferred until a real
  SCPU title shows demand.

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

# Bank-$01 dprom unit bench
bash sim/p65c816_tb/run_bank01_sram_tb.sh   # 10/10 PASS expected

# v164/v166 GHDL benches (still useful for future bisect)
bash sim/p65c816_tb/run_cpu_cache_v164_tb.sh   # 28/28 PASS expected
bash sim/c64_reduced_harness/run_harness_v2.sh  # 84/84 PASS expected
bash sim/c64_reduced_harness/run_kernal_drain.sh  # CPU now boots (post 459de4c)
```

## Do-not-touch list

- `/media/fat/_Computer/C64.rbf` — must stay vanilla MiSTer.
- v164 path-(b) hardware deploy is NOT cleared. Re-build only after the
  v166 BRK-ping-pong failure is reproduced in sim AND a fix verified.
- v167 RAM is at 98% — any new M10K consumer must include another
  reclaim-pass (R2 chargen_j, R3 cache 8KB→4KB, etc.) or pack into
  the existing dproms. Adding a stand-alone new dprom likely overflows.
