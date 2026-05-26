# Session handoff — 2026-05-26 (night): Bug 3 outer mux empirically validated, CDC theory dead

## 0. TL;DR

- **SHIP BUILD: v347 Phase 2 (`b95b4fe`, md5 `cfcbf617`).** Unchanged. Boots to BASIC READY.
- **The previous handoff's CDC theory is WRONG.** `clk_cpu === clk_sys` at `c64.sv:349` — there is no CDC. The "outer mux dead" symptom from the prior session was a measurement artifact, not a real bug.
- **Empirical proof the outer cpuDi mux works:** RBF md5 `0a8490a5` (commit `81af800f91`-dirty) added a bridge-side data-latch that captured `bus_di_in` (the outer mux's actual output) at the $D27D ack edge. UART telemetry showed `GM=$02` — exactly `scpu_simm_27d`'s reset default. If the mux were unreachable, GM would have been `$FF`. See `memory/project_bug3_outer_mux_actually_works.md`.
- **Bug 3 Stage 1 IS a clean writable-register addition.** No CDC fix needed. Working tree now contains only the production fix (4 signals + reset defaults + 4 read mux clauses + 4 write-process clauses, ~30 lines net).

## 1. Where things stand now

- **Working tree (uncommitted):**
  - `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — clean Bug 3 production fix. Diagnostic v2 comment about GM/VF repurpose removed. Massive falsified-journey comment in the cpuDi mux replaced with a short accurate one. Syntax check PASSED 2026-05-26 20:56 (0 errors, 116 warnings).
  - `C64_MiSTer/rtl/scpu_async_bridge.vhd` — reverted to HEAD (diagnostic v2/v3: planted $A5, dbg_clksys_d27_data_reg, VF/GM repurpose all gone).
  - Other tracked changes (build_c64.ps1, docs, lorenz_run.py, .gitignore, c64.qpf, deleted screenshots) are pre-existing and orthogonal to Bug 3.
- **Build in progress:** full Quartus build of cleaned Bug 3 launched 2026-05-26 ~21:00 (background `bua0syogt`, log `build_bug3_clean.log`). ETA ~30-40 min.
- **MiSTer at `/media/fat/_Test/C64.rbf`:** still RBF `0a8490a5` (the diagnostic build with plant + data-latch). Will be overwritten by the new clean build when ready.
- **HEAD:** v348 (`81af800`) on `milestone-b-cdc-rewrite`. v347 ship build untouched on disk.

## 2. What we learned (and what we got wrong)

### 2.1 The journey

Three sessions burned ~12 Quartus builds chasing a CDC bug that doesn't exist. The chain of misreads:

- Session N-2: probe_d27.prg returns `FF FF FF FF FF` for $D27C-$D27F → conclude outer mux dead → memory `cs_vic_gated_scpu_reg_reads_are_dead`.
- Session N-1: try cpuAddr_816 + 16-bit compare → build #6 source comment notes `$85` return → next-session TL;DR misreads as `$55` (the planted constant) → conclude cpuAddr_816 works.
- Session N: build #7 with signal sources via cpuAddr_816 returns `FF FF FF FF FF` → build #8 with planted constants $A1-$A4 same → conclude cpuAddr_816 ALSO broken → invent CDC theory.
- This session: data-latch in bridge proves outer mux output IS `$02` at the kickstart $D27D ack. The "$FF" from probe_d27.prg has a different cause.

### 2.2 What the `FF FF FF FF FF` symptom actually was

Candidates ranked by plausibility (per `bug3_outer_mux_actually_works`):

1. **mbc load_rom C64.PRG silently switched to vanilla rbf** (`_Computer/C64_20250828.rbf` — no SCPU regs, $D27D is VIC mirror = $FF). CLAUDE.md documents mbc CART has this pathology; PRG path may share it.
2. **PRG ran with DBR≠$00** so addr_hi_816 ≠ $00 → mux clause fails. P65C816 abs uses [DBR:operand] in both emu and native modes, no zero-override. If BASIC SYS to ML left DBR=$F8, every LDA $D27x targets `$F8:D27D`.
3. **Build #8's planted constants placed wrong in the mux ladder** — without seeing the exact source from that build it can't be fully ruled out.

The cheap verification (re-run probe_d27.prg on the new clean build) is **blocked** by broken input paths: `mtype.py` keyboard injection silently drops in milestone-b passthrough builds, and `<file type="f">` MGL autostart didn't trigger in this session's attempts.

### 2.3 What's actually true about CDC in this codebase

`c64.sv:349` does `assign clk_cpu = clk_sys;`. The async-bridge FSM still goes through its full handshake protocol (CPU_REQ_PENDING / WAIT_ACK / IDLE), but the two clocks are identical edges. There is no CDC. The `bus_addr_out` combinational path is fine. The handoff's whole "single bit didn't propagate" mechanism was impossible.

## 3. Bug 3 production fix (uncommitted)

`fpga64_sid_iec.vhd`:
1. Signal decls at line ~1362-1368: `scpu_simm_27c/d/e/f` with reset defaults `$00 / $02 / $00 / $F6`.
2. cpuDi mux clauses at ~line 1890-1898 (4 entries): `scpu_simm_27X when (supercpu_en='1' AND addr_hi_816=x"00" AND cpuAddr_816=x"D27X") else`.
3. Reset assignments in the SCPU-regs reset clause.
4. Write process clauses (cpuAddr = $D27C..$D27F → scpu_simm_27X <= cpuDo).

Diff stat: `fpga64_sid_iec.vhd | 56 ++++++++++++++++++++++++--` vs HEAD. The 56 is mostly comment lines; functional change is ~25 lines.

## 4. Next steps

- **When current build finishes** (notification will arrive automatically — don't poll):
  1. Deploy RBF to `/media/fat/_Test/C64.rbf` via `tools/mister_debug.py deploy`.
  2. `load_core` + screenshot. Verify BASIC READY (regression check — Bug 3 must not break boot).
  3. UART capture 8s. Verify VF/GM telemetry is back to original semantics (IRQ vector count / gap_max snapshot), not the diagnostic v2 repurpose.
  4. If clean + asked by user → commit Bug 3 with reference to `bug3_outer_mux_actually_works` memory. **Do not commit without explicit user authorization** (CLAUDE.md rule).

- **Open question deferred:** verify Bug 3 actually writes successfully (silicon-confirm STZ at $F8:$81EB-$81F0 lands a `$00` in scpu_simm_27d). Requires running a probe PRG — blocked by input-injection issue. Punt to a future session when MGL autostart is fixed, or hand-type the BASIC PEEK at the keyboard if the user is at the machine.

- **Bug 3 silicon-truth status:** the read mux is empirically validated (GM=$02). The write path is logically correct (mirrors existing native-vector write clauses that work) but not silicon-validated. Reasonable confidence to ship.

## 5. References

- `memory/project_bug3_outer_mux_actually_works.md` — empirical proof + falsification of prior memories.
- `memory/project_cpu_addr_816_path_also_broken.md` — superseded.
- `memory/project_outer_mux_cpu_addr_d27d_mystery.md` — superseded.
- `tools/_d27_plant_v3.png` + `tools/_d27_plant_v3_uart.txt` — the evidence.
- `tools/deploy_and_observe_d27.py` + `tools/analyze_d27_uart.py` — reusable diagnostic toolchain (still useful for future Bug-4+ register additions).
- `codex_bridge_diff_review.txt` — Codex's review of the diagnostic diff (no blocking issues found).
- `codex_mux_paradox.txt` — Codex's structured walk through why the outer mux paradox pointed at bridge capture path.
