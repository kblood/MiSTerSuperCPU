# MiSTer SuperCPU Roadmap

Snapshot date: **2026-04-25**.

This is the dependency-ordered work plan. For per-feature implementation
status see `docs/supercpu_feature_status.md`. For active session debug
context see `docs/session_handoff.md`.

---

## Working principles

1. **No new probes until the build-cache mystery resolves.** Every hardware
   build is presumed wasted while edits don't propagate.
2. **Sim-first.** Any hypothesis testable in GHDL or the reduced-system
   harness must be tested there before a Quartus build.
3. **Don't compound bugs.** Performance work (write buffer / WriteSmart) is
   gated on compatibility (Asterix + Doom) being stable, because writing a
   write buffer on top of a broken cache invariant masks the cause.
4. **Differential debugging beats probe-driven debugging.** VICE's xscpu64
   runs Asterix to title — that's our oracle. Capture its PC trace and
   diff against our sim/hardware.
5. **One bisect per blocker.** Before any new probe sequence, ask whether
   `git bisect` between a known-good and known-bad commit would resolve
   the question faster.

---

## Three lanes

The work splits into three lanes that run in parallel after the P0 tooling
unblocks them. Within a lane, items are dependency-ordered.

```
P0 Tooling: build-cache fix + VICE diff harness
              │
              ▼
    ┌─────────┴─────────┬─────────────┐
    │                   │             │
Compatibility    Performance    Architecture
(games run)      (~10-15 MHz)   correctness
    │                   │             │
    ▼                   ▼             ▼
[Asterix]         [WB drain]    [$D200-$D3FF]
[Doom verify]     [WriteSmart]  [Bank $01 SRAM]
[SCPU library]    [Cache widen] [Bootmap ROM]
[Regression]                    [$D078 unrepurpose]
```

---

## Phase 0 — P0 Tooling Unblock

These two items gate everything that follows. Drop everything else until
they're solved.

### 0.1 Build-cache propagation diagnosis (P0) — **RESOLVED 2026-04-25 (no bug)**

**Original concern**: Source edits compile cleanly with new md5, deploy,
deployed md5 matches local — but runtime UART behavior unchanged.

**Diagnostic result** (`docs/session_handoff.md` for full data): MD5
matches end-to-end through the build pipeline. The "didn't propagate"
symptom was caused by source files being edited AFTER the build
completed — the running rbf is correct AS OF its build time; subsequent
source edits don't appear until the next rebuild. Verify source mtime
is EARLIER than rbf mtime before claiming an edit was lost.

**Action going forward**: no caching bug to fix. Hardware iteration is
unblocked. The Asterix probe ring (item A.1) can proceed.

### 0.2 VICE PC-trace diff harness — IN PROGRESS

**Why**: VICE's `xscpu64.exe` runs Asterix to title. Differential PC tracing
(VICE log vs sim/hardware log → first divergent PC) is the highest-leverage
debug technique we haven't fully tapped. Cuts iteration from 30-min Quartus
loop to 2-min sim loop with deterministic oracle.

**Status (2026-04-25)**:
- ✅ Trace format spec: `tools/vice_diff/trace_format.md`
- ✅ Diff tool: `tools/vice_diff/vice_diff.py` with smoke test (matching
  + divergent synthetic traces both behave as expected)
- ✅ P65C816-side trace dumper added to `sim/p65c816_tb/p65c816_asterix_full_tb.vhd`,
  gated by VPA & VDA, armed at phase-2 entry ($0852). Produces 500K
  entries covering dispatcher + decompressor.
- ⏳ VICE-side trace capture: scaffold at `tools/vice_diff/vice_trace_asterix.cmd`
  but actual `xscpu64` invocation untested (path varies by user system).
- ⏳ Reduced-harness trace dumper (system-level, with cache+SDRAM):
  not yet added to `sim/c64_reduced_harness/c64_reduced_top_v2.vhd`.
- ⏳ Hardware-side capture mode: not yet designed.

**Remaining**:
1. User runs xscpu64 against asterix.prg with the moncommands file;
   tune format until the line layout matches our spec.
2. Once VICE produces a trace, run `vice_diff.py` between VICE and
   `work_asterix_full/ours_trace.txt`. Bare-CPU bench passes already
   so divergence — if any — would be a CPU-core bug.
3. Replicate the trace dumper in the reduced harness for system-level
   diffing (cache, SDRAM, BRAM coherency surfaces).

**Effort remaining**: ~1 session for VICE wiring + reduced-harness trace.
**Exit criteria**: One full VICE-vs-bare-CPU diff for Asterix from
phase-2 entry to $CB00, with no divergence (proves CPU correct) — or
divergence located if present.

**Sequencing**: independent of 0.1; both can proceed in parallel.

---

## Lane A — Compatibility

Games and software running correctly. Currently the active focus.

### A.1 Asterix SCPU-ON root cause (active)

**Why**: Black-screen hang after MGL load. Sole open compatibility blocker
once Doom status resolves.

**Plan** (gated on 0.1 + ideally 0.2):
1. **First**: capture VICE Asterix PC trace from boot to title screen.
2. Run `p65c816_asterix_full_tb.vhd` with PC dumper added; diff against VICE.
3. If sim diverges: bug is in CPU core or harness. Localize via diff.
4. If sim matches: bug is hardware-only (cache/SDRAM/turbo timing/IRQ delivery).
   Capture hardware UART PC trace; diff against sim.
5. Hypotheses already on the table (Option D handoff): vector-table corruption
   ($C003 indirect), cache stale data outside $82-$8E, buslogic priority mux,
   self-modifying dispatcher.

**Effort**: 1-3 sessions once 0.1 + 0.2 land. Currently bottlenecked.
**Exit criteria**: Asterix title bitmap renders. UART P:I=0 after CLI fires.

### A.2 Doom status re-verify

**Why**: Two contradictory narratives in memory: 2026-03-22 "deterministic
crash at K:2D→K:00" vs 2026-04-18 "90s stable execution captured". Must
resolve which is current.

**Plan**:
1. Build current head, deploy.
2. Load doom.reu via MGL (absolute path), run launcher.
3. Capture 5 minutes UART. Look for: K:2D fetches, BRK cascades, X-flip events.
4. Update `project_doom_*.md` memory files with definitive current state.
5. If crash present: triage via PC-trace diff vs VICE (same machinery as A.1).
6. If stable: declare Doom shipped and move to A.3.

**Effort**: 1 session. **Blocked by**: 0.1 (build-cache).

### A.3 SCPU software library compatibility sweep

**Why**: Asterix + Doom are the two known cases. There may be others, and
the user already reports "multiple games hang on copy loops"
(`project_games_hang_on_copy_loops.md`).

**Plan**:
1. Compile a list of canonical SuperCPU PRGs/D64s: scpu_speedtest, Synthmark816,
   badline tests, Asterix, Doom, plus 5-10 others from the SCPU community.
2. Test each in SCPU-ON mode. Capture pass/fail + symptom.
3. Categorize failures by suspected cause (CPU op, cache, REU, banking).
4. Add to bug tracker in feature_status.md §2.

**Effort**: 1-2 sessions. **Blocked by**: A.1 stable.

### A.4 Automated regression suite

**Why**: Today every fix could regress prior fixes silently. We have the
GHDL benches but no `make regress` that validates a build smoke-style.

**Plan**:
1. `tools/run_regression.sh`: builds all GHDL benches, runs them, reports
   pass/fail per scenario.
2. Hardware-side: `tools/hw_smoke.py` deploys current rbf, runs a sequence
   of test PRGs via mtype/mbc, captures UART pass/fail markers, summarizes.
3. Pre-commit hook (optional): block commit if regressions.
4. CI (optional): GitHub Actions on push.

**Effort**: 1-2 sessions. **Blocked by**: A.3 (need a stable test set).

---

## Lane B — Performance (4 MHz → ~10-15 MHz)

**Whole lane gated on Lane A reaching A.1 + A.2 stable.** Adding write
buffer drain on top of a broken cache compounds bugs.

### B.1 Re-enable cacheable_wr + write buffer drain (Phase B)

**Why**: Currently `cacheable_wr=0` in `cpu_cache.vhd:203` so every CPU write
blocks on SDRAM. The 16-entry write-buffer FIFO infrastructure exists but the
drain logic is dormant. This is the single biggest performance lever.

**Plan**:
1. Re-enable `cacheable_wr=1` for cacheable bank-$00 ranges.
2. Push writes into the 16-entry FIFO with `{addr[15:0], bank[7:0], data[7:0]}`.
3. Drain logic: steal SDRAM slots when CPU is running from cache_hit_d1
   (no SDRAM access needed for the read).
4. Stall CPU only when FIFO full.
5. Maintain coherency: cache + BRAM updated immediately on absorption;
   SDRAM updated on drain.
6. Sim verify in `c64_reduced_harness` — extend pagetest to write-then-read
   under heavy CPU load.

**Effort**: ~5-10 days. **Blocked by**: A.1 + A.2 stable.
**Exit criteria**: cache hits/frame increases, enables/frame increases,
measured MHz climbs above 6. No regression in any A-lane test.

### B.2 WriteSmart optimization modes ($D074-$D077, $D0B3)

**Why**: Decoded but no effect. Real SCPU uses these to control which writes
mirror to slow C64 DRAM — direct lever on write throughput.

**Plan**:
1. Define `optim_mirror_mask` from `scpu_optim_mode`:
   - `$D077` (no-opt): mirror $0000-$FFFF
   - `$D076` (BASIC): mirror $0400-$07FF only
   - `$D075` (VIC bank 1): mirror $4000-$7FFF only
   - `$D074` (VIC bank 2): mirror $8000-$BFFF only
2. For writes IN mask: existing slow SDRAM path (VIC sees data).
3. For writes OUTSIDE mask: cache + BRAM only, bypass SDRAM.
4. V2 enhanced ($D0B3): also exclude ZP ($00-$FF) and stack ($100-$1FF).

**Effort**: ~2-3 days. **Blocked by**: B.1 (needs cacheable_wr=1).
**Exit criteria**: scpu_speedtest shows speed increase when $D076/$D074 set.

### B.3 Cache widening / lookahead (Phase C, deferred)

**Why**: Phase A1-A3 already done. Phase C (lookahead to break the
hit/suppress alternation barrier) was deferred per architecture diagrams.

**Plan**: prefetch next address during suppress cycle. Requires extra
M10K which is constrained.

**Effort**: ~5+ days, possibly impossible on current resource budget.
**Status**: NOT PLANNED unless B.1 + B.2 are insufficient and M10K frees.

---

## Lane C — Architecture Correctness

Spec-compliance work. Mostly independent of A and B; can run in parallel
when bandwidth allows.

### C.1 $D200-$D3FF I/O hole SRAM verification (DONE-untested → DONE)

**Why**: 512 bytes ($D200-$D2FF system, $D300-$D3FF user) that real SCPU
provides; multiple SCPU programs use it. **Already implemented** in
`fpga64_buslogic.vhd:132-303` (was misidentified as MISSING in prior status
doc). Implementation correctly gates on `supercpu_en && bank=$00 &&
cpuAddr(15:9)="1101001"`, suppresses cs_vic to prevent register
corruption, and reset-sweeps the 512-byte array.

**Plan** (verification only — no RTL change needed):
1. Add VHDL bench `sim/scpu_sysram_tb/scpu_sysram_tb.vhd`:
   - Instantiate `fpga64_buslogic` standalone
   - Drive `cpuAddr`, `cpuWe`, `cpuData` to write pattern $AA/$55/seq to
     $D200-$D3FF
   - Read back via `dataToCpu`
   - Assert match → exit code 0/1
2. Add runner `sim/scpu_sysram_tb/run.sh`.
3. Run, confirm pass.
4. Promote status from DONE-untested → DONE in feature_status.md.

**Effort**: ~2 hours. **Blocked by**: nothing.
**Exit criteria**: bench reports 0 mismatches over all 512 addresses with
both write patterns.

### C.2 Bank $01 SRAM shadow

**Why**: Real HW maps bank $01 to 64 KB SRAM with KERNAL/BASIC/CHARGEN
shadow + user space. MiSTer maps bank $01 to SuperRAM/SDRAM (WRONG per
CLAUDE.md). Software probing $01:E000 expects KERNAL bytes; gets SDRAM.

**Plan**:
1. Add 16 KB BRAM region for $01:A000-$01:DFFF (BASIC + CHARGEN shadow).
2. For $01:E000-$01:FFFF (KERNAL shadow), reuse the 64 KB BRAM via bank-bit
   aliasing trick (cheaper than another 8 KB block).
3. Boot stub copies ROM into BRAM during first ~256 cycles.
4. Update `scpu_sdram_addr` mux: bank $01 + relevant ranges → BRAM, else SDRAM.
5. Move SuperRAM start from bank $01 to bank $02 (per real HW).
6. Sim test: read $01:E000-$01:FFFF, expect KERNAL bytes.

**Effort**: ~3-5 days. **Blocked by**: M10K budget (16 KB more BRAM = ~13
M10K blocks; currently at 95%). Need to free M10K first via:
- Shrink 8 KB cache to 4 KB (~4 blocks freed)
- Remove unused diagnostic register space
- Use distributed RAM for $D200-$D3FF (already C.1)

**Exit criteria**: $01:E000 reads KERNAL ROM bytes; SuperRAM still works
starting bank $02; SCPU mode detect ($D0BC bit 7) still correct.

### C.3 Bootmap ROM ($F0-$FF)

**Why**: Real SCPU has 64-512 KB EPROM with the SuperCPU OS firmware in banks
$F0-$FF when bootmap=1. We have a minimal stub (RTI/RTL at $FF00).

**Plan**:
1. Decide whether to use real CMD SCPU OS dump (legal grey area; check
   community licensing) OR write a minimal SCPU-compatible boot ROM.
2. If minimal: implement enough to cold-boot, copy ROM shadows to bank $01,
   execute bootmap=0, hand off to KERNAL.
3. Add 64 KB BRAM (or distributed) for the boot ROM.

**Effort**: ~5-10 days if writing minimal ROM. M10K-constrained.
**Blocked by**: M10K budget; arguably C.2 (bank $01 SRAM is what bootmap
ROM populates).

**Sequencing**: deferred until C.2 lands and we know real-software demand
for it.

### C.4 $D078 unrepurpose

**Why**: We use $D078 for cache flush. Real HW uses it for SIMM
configuration. If software writes $D078 expecting SIMM config and we
flush the cache instead, behavior diverges.

**Plan**:
1. Audit: how often do real SCPU programs write $D078? (probably rare —
   SIMM size is detected once at boot)
2. If usage is rare: move cache flush to a custom register (e.g., $D079
   alias variant or a new $D0Bx register), restore $D078 to read-only
   SIMM config returning fixed value (16 MB SIMM).
3. If usage common: needs deeper redesign; consider hardware-level flush
   trigger instead.

**Effort**: ~1 day if rare usage. **Blocked by**: nothing (independent).

### C.5 DOS extension $D0BE/$D0BF

**Why**: JiffyDOS-style fast loaders + SCPU file extensions. Most non-IEC
software ignores it.

**Plan**: implement read/write handlers for $D0BC/$D0BE/$D0BF. Minimal
state machine. ~1 day.

**Status**: LOW PRIORITY unless specific software demands it.

---

## Phase Sequencing (the actual order)

Concrete ordered list combining all three lanes. Each item must complete or
be explicitly de-prioritized before the next.

| # | Item | Lane | Effort | Blockers |
|---|------|------|--------|----------|
| 1 | Build-cache propagation fix | P0 | 1-2 sessions | — |
| 2 | $D200-$D3FF I/O hole SRAM | C.1 | 1 day | — (sim-testable now, no hw build needed) |
| 3 | VICE PC-trace diff harness | P0 | 1-2 sessions | — |
| 4 | Asterix SCPU-ON root cause | A.1 | 1-3 sessions | 1, 3 |
| 5 | Doom status re-verify | A.2 | 1 session | 1 |
| 6 | $D078 unrepurpose | C.4 | 1 day | — (parallelizable) |
| 7 | SCPU software library sweep | A.3 | 1-2 sessions | 4 |
| 8 | Automated regression suite | A.4 | 1-2 sessions | 7 |
| 9 | Free M10K (cache shrink etc.) | prep for C.2 | 1-2 days | 8 |
| 10 | Bank $01 SRAM shadow | C.2 | 3-5 days | 9 |
| 11 | Phase B: write buffer drain | B.1 | 5-10 days | 4, 5 stable |
| 12 | WriteSmart optimization | B.2 | 2-3 days | 11 |
| 13 | Bootmap ROM | C.3 | 5-10 days | 10 |
| 14 | DOS extension $D0BE/$D0BF | C.5 | 1 day | — (low priority) |

**Critical path**: items 1, 3, 4 → most other items unblock from there.
**Quick wins parallelizable now**: items 2, 6, 14.

---

## Decisions to revisit at each milestone

- **After item 1**: confirm hardware iteration is fast/reliable; if not,
  invest in the loop further.
- **After item 4**: Asterix fix may reveal whether the broader "games hang
  on copy loops" memory describes the same bug. If yes, A.3 may collapse
  into a single fix verification.
- **After item 11**: measure achieved MHz. If <8 MHz, reassess Phase C.
- **After item 12**: full SCPU regression. If WriteSmart breaks any games,
  revisit the mirror mask design.

---

## What this roadmap is NOT

- **Not a 20 MHz commitment.** Realistic ceiling on Cyclone V is ~10-15 MHz
  per architecture analysis. 20 MHz parity probably requires moving the C64
  RAM out of SDRAM into dedicated BRAM, which busts the M10K budget by
  10x. If 20 MHz is required, that's a separate FPGA-redesign project.
- **Not a Doom-specific roadmap.** Doom is an A-lane test case among many.
- **Not a GUI/UX plan.** OSD changes / nicer overlays are out of scope.
- **Not a 6510 mode improvement plan.** SCPU-OFF compatibility is currently
  fine per commit `25bf8ad`.
