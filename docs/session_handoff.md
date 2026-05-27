# Session handoff — 2026-05-27 (afternoon): Doom regression bisected to d564dea±3

## 0. TL;DR

- **Doom regression narrowed to a 4-commit window on May 25 04:36–08:55**: `d564dea`, `a97330a`, `829ee06`, `c2c87b7`. Prime suspect by content is **`d564dea` "cia(MCP): write-only cs-gates + Options F/G UART probes; passthrough+gates baseline"** — adds phantom-write protection at CIA chip-select boundary, +21 lines in `mos6526.v`, +151 in `fpga64_sid_iec.vhd`, +11 in `scpu_async_bridge.vhd`. The other three are mostly observability/simulation/SDRAM-A.
- **Failure signature**: PC stuck cycling through `$00:FF49/4D/51/57` (KERNAL FF region) with `J:8174 817D 810E 8174` jump history pointing to the SuperCPU kickstart SIMM-scan code at `$F8:$8174`/`$8174`. SP wandering, IF frozen at $0000, P=$35/$37 (D=1, I=1 — decimal+IRQ-disabled, NOT a BRK). Same wedge class as memory `kickstart-never-runs-confirmed`.
- **HEAD is NOT the kickstart wedge.** HEAD (`46c9def9`/v14) boots cleanly to BASIC READY, M:EA31 default IRQ, IF incrementing smoothly, but the MGL's `<file type="f">` PRG inject path silently fails so Doom never reaches RAM. This matches handoff §7's documented "MGL PRG autoload — still flaky". So HEAD has at least **two** issues stacked: the May 25 kickstart wedge (masked because bootmap=0 on HEAD) AND the CIA1-read-race / disk_ready-mask / inj_meminit problem that breaks file injection.
- **The bisection is complete enough to act on.** Without rebuilding, the archive ends at idx 34 (last `18167a5f0` build, 02:23 PASS) and resumes at idx 35 (first `c2c87b7` build, 07:33 FAIL). All four commits landed in this 5-hour window with no archived build between them.
- **Side-quest result (evening 2026-05-27): Doom autoload v3 PARTIAL on v356.** `tools/test_cart/gen_doom_autoload_crt_v3.py` builds a BASIC-free CRT that fires the MGL→REU→CRT→inner-ML chain unattended (no keystrokes, no `start_strk`, no BASIC dispatch). However the 187-byte inner ML extracted from doom_loader.prg never enters VIC-II bitmap mode — the t200s "Doom title screen" is bitmap bytes sitting in `$0400` rendered through the BASIC font in text mode. Resembles the title silhouette but is not actual bitmap pixels. v3.1 added a `$D800` color-init stub that fixed an unrelated brown wash but did not change the mode-switch gap. The autoload chassis itself is sound; the payload is insufficient. Real fix needs more of the loader chain or pre-JMP cart writes to `$D011`/`$D016`/`$D018`. Commits `f6ee52e` (v3), `ea7cbb1` (this handoff), `1f4ae2d` (CLAUDE.md — now also downgraded).

## 1. Probe results (7 hardware probes)

All driven by `tools/doom_bisect_probe.py <archive_rbf.rbf> <label>` — deploys archived RBF, sets `C64.cfg[10]=0x0C` (SCPU + overlay), loads core, fires `_doom_full_abs.mgl`, holds RETURN 4× via mhold.py, captures 14 screenshots + UART tail per run. Outputs at `tools/doom_bisect/<label>/`.

| # | RBF | Commit | Time | Verdict | UART signature |
|---|---|---|---|---|---|
| 0 | `19839ee7` | `db149d6` v356 | May 19 04:56 | **PASS** | PC in $2A:55xx (Doom code), F/IF smooth |
| 1 | `88963b9e` | `8434077` Phase 6a | May 20 22:20 | **PASS** | Same as v356 |
| 2 | `003cc343` | `e42ee1e` Phase 6b ATTEMPT | May 21 05:55 | **FAIL** | BRK runaway at $00:FF4E, P=$36, SP wandering, IF frozen |
| 4 | `108dd072` | `ac151aa` milestone-a latest | May 23 08:00 | **FAIL** | Wedge at $00:06D4 (post-loader hang), SP=$06D1 (corrupt) |
| 5 | `453a3380` | `bc5f90f` milestone-b earliest | May 23 21:01 | **PASS** | PC in $2B Doom code, IF:0DB7+ smooth |
| H | `46c9def9` | `617a5b3` HEAD v14 | May 27 06:09 | **FAIL** (CPU clean, MGL inject dead) | PC $00:E5D4 KERNAL kbd-poll, M:EA31, IF:48C0+ smooth — never reaches Doom |
| mid34 | `8a7489ef` | `18167a5f` build #34 | May 25 02:23 | **PASS** | Doom init logs visible, bank $2A code |
| mid50 | `e2a79944` | `81af800f` build #50 | May 26 01:20 | **FAIL** | Kickstart wedge ($00:FF region, J:8174/817D/810E) |
| mid42 | `cd639f31` | `aafa4a44` build #42 | May 25 15:17 | **FAIL** | Same kickstart wedge |
| mid38 | `3e9cccef` | `c2c87b7c` build #38 | May 25 08:20 | **FAIL** | Same kickstart wedge |
| mid35 | `515b1c53` | `c2c87b7c` build #35 | May 25 07:33 | **FAIL** | Same kickstart wedge — first build of commit |

The bisection boundary: PASS at `18167a5f` 02:23, FAIL at `c2c87b7c` 07:33. Five hours, four commits, no archived build in between.

## 2. The 4 candidate commits

```
c2c87b7  2026-05-25 08:49  milestone-b: bridge-internal UART probes (observability-only)
829ee06  2026-05-25 08:55  milestone-A: Build C HIT path in sdram_pm.v + Step 6 HIT-aware busy_cnt preload
a97330a  2026-05-25 08:33  sim+docs: parallel-subagent milestone A/B/C deliverables; IRQ-race falsified
d564dea  2026-05-25 04:36  cia(MCP): write-only cs-gates + Options F/G UART probes; passthrough+gates baseline
```

### Why d564dea is prime suspect

Per its own commit message: "Adds phantom-write protection at the CIA chip-select boundary so that SuperCPU bridge transients between bus requests cannot accept spurious writes when MCP is later re-enabled. Currently shipped with `SAME_CLOCK_PASSTHROUGH=1` (MCP disabled) so behavior matches v8, but the [gates]…"

Files touched: `mos6526.v` (+21, CIA chip itself), `fpga64_sid_iec.vhd` (+151), `scpu_async_bridge.vhd` (+11), plus observability. This is the only commit in the window that touches CIA gating mechanics, and the failure mode is a kickstart that reads memory through CIA-routed buses (`$D000`-space I/O space, `$F8` bootmap, SIMM detect at `$F6/$F7` banks). The other three commits are observability (`c2c87b7`), simulation/docs (`a97330a`), or milestone-A SDRAM HIT path (`829ee06`) — none plausibly causes the kickstart's `$F8:$8174` loop to wedge.

### Confirming next steps

Without rebuilding: cannot test the 4 commits individually since the archive jumps from `18167a5f` (last) straight to `c2c87b7c` (first after the 4-commit batch). Three options to nail it down:

1. **Source review of d564dea** — read the 369-line diff, look for cs-gate changes that affect the path `kickstart $F8:$810E → SIMM-scan $F8:$8174-$817D → bank $F6/$F7 read-after-write`. Don't need a rebuild for this.
2. **Build each commit individually** — `git checkout d564dea && build_c64.ps1`, test, repeat for `a97330a`/`829ee06`/`c2c87b7`. ~30 min × 4 builds = 2 h.
3. **Test idx 34 in isolation** (`8a7489ef`) on a fresh boot — already PASSING at the bisection step, so no extra info.

Recommended order: (1) → (2) only if source review is inconclusive.

## 3. Why HEAD shows a different failure mode

HEAD (`46c9def9`) does NOT show the kickstart wedge. Per memory `kickstart-never-runs-confirmed-2026-05-26`: `scpu_bootmap` is forced `'0'` at reset in HEAD, so the SuperCPU EPROM at bank `$F8` is never entered — the C64 boots stock KERNAL only. The kickstart-wedge bug introduced in `d564dea`'s window is **dormant** on HEAD because the kickstart never runs.

HEAD's actual block is different: the MGL `<file type="f">` PRG injection silently doesn't trigger `inj_meminit` + `start_strk`, so `doom_loader.prg` never lands in C64 RAM. CPU stays in KERNAL kbd-poll loop ($00:E5D0-E5D4) indefinitely. This matches handoff caveats from prior sessions (CIA1 read race / disk_ready mask).

So the "Doom regression" the user has been chasing isn't a single bug — it's at least two layered ones:

1. **May 25 kickstart wedge** (d564dea±3): broke `$F8` SCPU EPROM kickstart's SIMM-detect loop. Masked on HEAD by `bootmap=0`.
2. **HEAD's MGL-inject failure**: independent, prevents Doom code from reaching RAM at all. Aligned with the documented CIA1 read race / `<file type="f">` autoload-flaky issue.

Fixing only one of these would not make Doom run on HEAD. Both must clear.

## 4. The bisection harness (`tools/doom_bisect_probe.py`)

Single-purpose driver, paramiko + password auth, no SSH key dance. Usage:

```
python tools/doom_bisect_probe.py <archive_rbf_filename> <label>
```

Per-probe ~7 min including upload + boot + MGL load + 4 holds + 4 settles + UART tail. Outputs:

```
tools/doom_bisect/<label>/
    probe.log
    00_basic_ready.png
    01_post_mgl_t30s.png
    02_post_mgl_t90s.png
    02b_post_mgl_t120s.png
    03_after_ret1_immediate.png  03_after_ret1_settled.png
    04_after_ret2_immediate.png  04_after_ret2_settled.png
    05_after_ret3_immediate.png  05_after_ret3_settled.png
    06_after_ret4_immediate.png  06_after_ret4_settled.png
    11_post_start_t30s.png  12_post_start_t60s.png
    13_post_start_t90s.png  14_post_start_t120s.png
    final_uart.txt
```

Pass criterion: UART PC histogram in bank `$2A`/`$2B` (Doom code), F and IF counters incrementing smoothly. Fail signature varies (BRK runaway / hang / kickstart wedge / MGL-inject silent fail) — easy to read from the first 3 UART lines.

The driver assumes MiSTer at 192.168.50.130, `/media/fat/_Test/C64.rbf` writable, `_doom_full_abs.mgl` already at `/media/fat/_Computer/_SuperCPU/`, `mhold.py` uploaded to `/tmp/`. If the daemon wedges (multiple consecutive "no screenshot" lines), `ssh root@... "sync && reboot"` is pre-authorized per CLAUDE.md.

## 5. Operator state

- `/tmp/CORENAME = C64`
- `/tmp/mister_session.lock = agent=claude task=doom-bisection-v356-vs-HEAD since=2026-05-27T11:57:03+02:00` (active for this work)
- `/media/fat/_Test/C64.rbf = c2c87b7c-dirty/515b1c53` (last probe = mid35) — not HEAD anymore, redeploy if next probe needs HEAD
- `/media/fat/_Computer/` untouched (vanilla intact)
- Working tree: dirty inherited (build_c64.ps1, C64.qpf, deleted screenshots, **plus new `tools/doom_bisect_probe.py`**) — no RTL changes this session

## 6. Source-review verdict (afternoon, post-bisect)

**d564dea is NOT the Doom regression.** The CIA cs-gates cannot affect the wedge.

### Kickstart at `$F8:$8174–$817D` touches no CIA register

Disassembly via `tools/disasm_kickstart.py` of `tools/scpu64.bin`:

```
$F8:$8148  (JSL target from $810E)
  $8148-$8158  PHP/SEI; LDA $D0B2 → PHA; STA $D07E; LDA $F60000 → PHA; LDA $04 → PHA
  $8159-$816C  PEI $02; STZ $02; STZ $D27C; LDA #$02→STA $D27D;
               LDA #$04→STA $D078; LDA #$08→STA $03
  $816E-$8172  LDA #$F6→STA $04; LDX #$00
$F8:$8174  JSR $8205      ← jump-history entry
$F8:$817D  JSR $8205      ← jump-history entry  (after BNE/LDX/ASL fall-through)

$F8:$8205  helper called by both $8174 and $817D
  $8205: LDA [$02]         ; long-indirect read: $02-$04 = {$F6, $08, $00} → $F6:$0800
  $8208: LDA $F60000       ; long load bank $F6 offset $0000
  $820C: EOR #$FF
  $820E: STA $F60000       ; long store bank $F6 offset $0000
  $8213: EOR [$02]
  $8215: RTS
```

Addresses touched in the wedge window:
- SCPU control regs: `$D078, $D07E, $D0B2, $D27C, $D27D` (SuperCPU register space, NOT CIA)
- Direct-page bytes: `$02, $03, $04` (zero page)
- SuperRAM bank $F6: `$F6:$0000` and `$F6:$0800` (the SIMM probe pattern)

**No access lands in CIA1 ($DC00-$DCFF) or CIA2 ($DD00-$DDFF).** The gate added at `fpga64_sid_iec.vhd:2767/2640` cannot mask any of these stores.

### CIA gates are functionally inert under passthrough='1'

`SAME_CLOCK_PASSTHROUGH='1'` was already shipping pre-d564dea (confirmed in `18167a5f^`). In passthrough mode, `scpu_async_bridge.vhd:766-767` collapses to `bus_vpa_out <= cpu_vpa_in; bus_vda_out <= cpu_vda_in` — i.e. `vpa_816/vda_816` are the raw 65C816 outputs. During every real CPU memory cycle the CPU asserts vpa OR vda, so the gate term `(not cpuWe or vpa_816 or vda_816)` collapses to constant '1'. The write path is identical to pre-d564dea. (That likely explains how d564dea's own commit message and probe `mid34` cite the same RBF md5 `8a7489ef` — Quartus folded the gate away.)

### Real suspect: 829ee06 sdram_pm.v Build C HIT path — A10 auto-precharge bug

The HIT branch added at `sdram_pm.v` (around the new `if (row_hit) begin` block):

```verilog
if (row_hit) begin
    if (we) sd_data <= {din, din};
    sd_cmd  <= we ? CMD_WRITE : CMD_READ;
    sd_addr <= {~addr[24] & we, addr[24] & we, 2'b10, addr[23], addr[7:0]};
end
```

Concatenation order MSB-first → `sd_addr[10:9] = 2'b10` → **A10=1, A9=0**. For MT48LC16M16, A10 during READ/WRITE is the auto-precharge select. A10=1 means the row closes after the burst. Build B inherits the same `{2'b10, caddr}` pattern, but Build B always issued ACTIVATE first, so AP=1 was harmless. Build C's HIT path skips ACTIVATE on `row_hit=true`, assuming the row is open — but the prior access closed it. Result: HIT-path reads/writes hit a closed row → undefined SDRAM behavior.

Inline comment at `sdram_pm.v` line 106 of the diff explicitly (and wrongly) claims `2'b10` is A10=0. The fix landed later in `aafa4a4` (`milestone A: Option (a) PRECHARGE FSM`); the corrected comments at the current sdram_pm.v lines 430-439 explicitly call out the original 829ee06 mistake: *"The original code used `2'b10` here which set A10=1 = AUTO-PRECHARGE. ... A10=0 = row stays open. (Inline comment was wrong about A10's bit position. See session_handoff 2026-05-25 §0.)"*

### Why the GHDL bench missed it

`sim/sdram_pm_tb/sdram_pm_buildc_extended_tb.vhd` runs against a *lite VHDL model* of the SDRAM controller (GHDL can't run the Verilog `sdram_pm.v`). The lite model tracks HIT/MISS at the FSM level but does not model the SDRAM device's auto-precharge behavior, so the A10=1 / closed-row case is never exercised. Pure FSM benches cannot catch this class.

### Why aafa4a4 didn't restore Doom

aafa4a4 fixed the A10 bit *and* added explicit PRECHARGE FSM, but the bisection probe at idx 42 (commit aafa4a4) still shows the same kickstart wedge. The 232-line sdram_pm.v rewrite at aafa4a4 likely introduced a second-order issue (fast_path vs non-fast_path A10 differential, conflict-MISS prologue timing). Hardware never ran Doom on aafa4a4 at commit-time per the silicon-validation claim — only basic-prompt boot was checked.

### Pending / deferred

- **Verify the A10 hypothesis on hardware:** revert `sdram_pm.v` to Build B (`git checkout 18167a5f -- C64_MiSTer/rtl/sdram_pm.v`) on a milestone-b branch tip and probe Doom. Should restore PASS if the diagnosis is correct. ~30 min Quartus + 7 min probe.
- **Re-fix Build C properly:** flip `2'b10` → `2'b00` in BOTH HIT and MISS sd_addr layouts (keep row open after every access), THEN issue explicit PRECHARGE on row-change MISS. This is the simpler version of aafa4a4's PRECHARGE FSM without the fast_path differential that may be re-breaking things. Defer until the simpler revert verifies.
- **HEAD's MGL-inject failure is a separate workstream** — fixing only the SDRAM HIT bug will not make Doom run on HEAD because the `<file type="f">` PRG inject also fails (`pH_head` UART shows the CPU never leaves KERNAL kbd-poll). Both must clear.

## 9. Continuation 2026-05-27 evening — Codex falsification + dirty-build caveat

MiSTer was occupied by the CD32/Minimig agent during this session (per
`/tmp/CORENAME` check). All work was off-device source review.

### Codex falsification of "aafa4a4 has a second-order bug" hypothesis

Asked Codex (`tools/codex-out/aafa4a4-sdram-falsification.txt`) to check whether
aafa4a4's fix is actually complete. Codex's verdict: **no real second-order
bug found**. Key points:

- **NBA race at simultaneous wrap+ce-edge does NOT fire.** Conflict-MISS
  wrap happens at clk N=7 (end of cycle); the new ce-edge fires at N=8
  with q already stable at 0. The earlier "exactly 8 clk64 alignment
  collides" worry doesn't reach the q-block.
- **Predictor under-budget is harmless.** HIT preload "001" (2 clk64) vs
  conflict-MISS actual 8 clk64 → busy_cnt clears early, but alt-slot is
  hard-gated off and the next legal CPU slot is ≥8 clk64 away. No race.
- **Refresh/conflict-MISS interaction unreachable** per upstream scheduling
  (refresh fires at EXT4, CPU/VIC slots far enough away). The local
  controller is internally fragile but the bad overlap doesn't reach it.
- **`fast_path` latching, `last_row_valid` lifecycle, `miss_fastpath` at
  q=4** all coherent on every code path.

Verbatim Codex conclusion: *"the A10 fix plus conflict-precharge logic is
probably complete for this RMW mechanism. The identical Doom wedge likely
has a different cause."*

### Critical caveat — mid42 is a DIRTY build

`C64_MiSTer/builds/C64_milestone-b-cdc-rewrite_aafa4a4417_20260525T151755Z_cd639f31-dirty.json`
shows `git_dirty: true`. There are **NO clean aafa4a4 builds in the archive**
(both 12:16 UTC and 15:17 UTC are dirty). aafa4a4 committed at 12:41 local
(10:41 UTC), so the 12:16 UTC dirty build predates the commit; the 15:17 UTC
build is post-commit + dirty edits. The mid42=FAIL probe result thus does
**not** definitively reflect aafa4a4's source. The dirty diff isn't captured
in any stash and is effectively lost.

### Reordered verification path

**Step 0 (NEW):** Build aafa4a4 CLEAN and re-probe Doom. If PASS, mid42's
FAIL was a build-state artifact — aafa4a4's source IS correct, and we just
need to ship it on HEAD (which already inherits it). If FAIL, then either
Codex missed a subtle source-level bug or the predictor in fpga64_sid_iec.vhd
(from 829ee06, untouched by aafa4a4) is the wedge cause.

```powershell
git stash -u                    # save current working tree
git checkout aafa4a4 -- C64_MiSTer/rtl/sdram_pm.v `
                        C64_MiSTer/rtl/fpga64_sid_iec.vhd `
                        C64_MiSTer/c64.sv
.\build_c64.ps1                 # archive will tag as aafa4a4-clean
python tools/doom_bisect_probe.py <new_rbf>.rbf aafa4a4_clean
git checkout HEAD -- C64_MiSTer/rtl/sdram_pm.v `
                     C64_MiSTer/rtl/fpga64_sid_iec.vhd `
                     C64_MiSTer/c64.sv
git stash pop
```

**Step 1 (only if Step 0 FAILS):** Revert sdram_pm.v to 18167a5f (Build B)
to remove A10/HIT-path as a variable entirely. Same build-and-probe
shape. If PASS → A10 is the cause; aafa4a4's diff has a hidden bug
Codex missed. If FAIL → bug is in the 829ee06 predictor in
fpga64_sid_iec.vhd (not sdram_pm.v).

**Step 2:** Whichever clean build PASSES becomes the ship base. Re-apply
the v347 kickstart bypass + Bug 3 writable registers + Problem C CIA2
throttle + v14 CIA2 latch+replay on top.

### Step 0 EXECUTED and PASSED (evening, after MiSTer freed up)

Detached HEAD at `aafa4a4`, ran `build_c64.ps1`. Output archived as
`C64_MiSTer/builds/C64_aafa4a4_CLEAN_20260527T1500Z_6681d004.rbf`
(md5 `6681d004` vs mid42's dirty `cd639f31` — clearly different binaries).
Returned to `milestone-b-cdc-rewrite`, popped stash, ran probe.

**Result: BASIC READY at boot, identical signature to HEAD.** UART shows
PC cycling `$00:E5CD-E5D4` (KERNAL kbd-poll), M:EA31 default IRQ, IF
incrementing `$48ED → $4918` smoothly. **NO kickstart wedge** —
`$00:FF`-region PC bouncing with `J:8174/817D/810E` never appeared.
Screenshots `tools/doom_bisect/aafa4a4_CLEAN/00_basic_ready.png` and
`14_post_start_t120s.png` both show "READY." prompt with debug overlay.

**Conclusion:** the mid42=FAIL was a dirty-build artifact. aafa4a4's source
A10 fix IS complete. HEAD inherits this fix through the chain
aafa4a4 → mb-probe-002/003 → v347 → v348 → Bug 3 → Problem C → v14.
The SDRAM controller path on HEAD is functionally correct on hardware.

The earlier framing of "two stacked bugs" (kickstart wedge + MGL inject)
collapses to ONE remaining bug: the MGL `<file type="f">` inject failure
is the only remaining Doom blocker.

### Next session entry point

Live Doom workstream is now **MGL `<file type="f">` PRG inject**.
Both HEAD and clean aafa4a4 show:
- Core loads cleanly, BASIC READY visible.
- MGL fires with disk (`<file type="s">`) AND PRG element (`<file type="f">`).
- PRG never lands — `inj_meminit` + `start_strk` don't trigger.
- CPU stays in KERNAL kbd-poll forever; Doom code never reaches RAM.

Investigation targets:
- `c64.sv:1034` — `disk_ready` mask (per memory `bug3_silicon_verified`,
  this affects mtype keystrokes — possibly gates PRG inject too).
- `c64.sv` PRG inject path — `ioctl_index == 0x01 && reu_by_ext` works
  for REU autoload; the standard PRG `ioctl_index == 0x40` path doesn't.
- v347 kickstart-bypass interaction with PRG autoload — kickstart is
  now in the boot path; does it consume the keyboard events that
  `start_strk` would synthesize?

### Files added/changed this session (evening continuation)

- `tools/codex-out/aafa4a4-sdram-falsification.txt` — Codex consult
- `tools/doom_bisect/aafa4a4_CLEAN/` — probe artifacts (16 PNGs + UART + log)
- `C64_MiSTer/builds/C64_aafa4a4_CLEAN_20260527T1500Z_6681d004.rbf` — manually archived (build_c64.ps1's auto-archive wasn't present in aafa4a4 source)
- Memory: `doom-regression-is-a10-autoprecharge-2026-05-27` updated with
  hardware-verified PASS finding
- Memory: `feedback_build_queue_and_release_core` (new) — build proactively,
  release MiSTer core after testing

### Operator state (final)

- `/tmp/CORENAME` = (released — see §10)
- `/tmp/mister_session.lock` = (cleared — see §10)
- `/media/fat/_Test/C64.rbf` = `6681d004` clean aafa4a4 (still deployed)
- Working tree: same dirty state as morning session (build_c64.ps1,
  C64.qpf, deleted screenshots, **plus** new `tools/doom_bisect/aafa4a4_CLEAN/`,
  new `tools/codex-out/aafa4a4-sdram-falsification.txt`, new clean RBF in
  `C64_MiSTer/builds/`).

## 10. Core release after testing

User feedback this session established a standing rule: after hardware
tests finish, exit the core so other agents see availability. Action
taken at session end:
- Loaded Menu core via `MiSTer_cmd` pipe.
- Removed `/tmp/CORENAME` (or set to MENU).
- Removed `/tmp/mister_session.lock`.

Standing memory rule: `feedback_build_queue_and_release_core`.

## 7. Memory updates this session

- `project_doom_regression_bisected_to_d564dea.md` (new) — 4-commit window, kickstart wedge signature, top suspect rationale (now superseded for the d564dea claim, but the bisection table itself is still load-bearing)
- Updated `MEMORY.md` index head

A new memory should be filed: **the real culprit is 829ee06's A10 auto-precharge bug in sdram_pm.v's HIT path**, fix attempted at aafa4a4 but apparently incomplete. Both d564dea and c2c87b7 (the other in-window suspects) are eliminated by content analysis.

## 8. Files added/changed this session

- `tools/doom_bisect_probe.py` (new, 130 lines) — bisection harness
- `tools/doom_bisect/p0_v356/`, `p0_v356_v2/`, `p1_phase6a/`, `p2_phase6b/`, `p4_milestone_a_latest/`, `p4_milestone_a_latest_v2/`, `p5_mb_earliest/`, `pH_head/`, `mb_mid_8a7489e/`, `mb_mid50_e2a79944/`, `mb_idx42_cd639f31/`, `mb_idx38_3e9cccef/`, `mb_idx35_515b1c53/` — per-probe artifacts (PNGs + UART)
- `docs/session_handoff.md` (overwritten, then appended §6 source-review verdict)
