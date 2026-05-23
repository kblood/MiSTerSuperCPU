# Session handoff — 2026-05-23 end-of-session

## TL;DR

1. **Bootstrap "PA wedge" RESOLVED** (commit `b869136`). The wedge
   that blocked every multi-page CRT bench wasn't in any bench — it
   was `tools/test_cart/prg_to_crt.py`'s copy loop self-modifying
   `INC $802A` / `INC $802D`, which are in cart ROM (read-only).
   `INC` silently failed, so for any PRG > 256 bytes the 2nd+ pages
   never reached RAM. CPU fetches from $0900+ wedged at the moment
   PC crossed the page boundary. Replaced with ZP-indirect addressing
   (`$FB/$FC` src, `$FD/$FE` dst). 4-variant HW bisect
   (`gen_draw_bisect.py`) pinned it: V1/V2 (1 page) clean; V3/V4
   (2 pages) wedge at PC=$0900. Verified `pass_draw_only.crt` now
   renders all 4 draws and `superram_bench.crt` reaches JML $208000.
2. **CRT auto-boot wrapper is now production-grade** for arbitrary
   PRG sizes up to ~7.9KB. Bootstrap also now masks CIA2 NMI
   (commit `4174d7c`) to eliminate stray-NMI wedges from prior session
   CIA2 timer state — universal hygiene, costs 8 bytes.
3. **Long-mode opcodes ARE NOT broken** (commit `d693ca3`). All 7
   single-op variants (emu/native, $00xxxx ZP / $00xxxx RAM /
   $200080 SuperRAM, STA al / LDA al) execute correctly from
   cart-boot. Re-verified this session: `probe_emu_sta_superram`
   still renders `AAABBBB CCC` (md5 `ecee8914` saved as proof).
4. **Step 7b alt_fire_r2 RTL stays deployed** (commit `09655d8`,
   RBF md5 `108dd072` at `/media/fat/_Test/C64.rbf`). Bank-0 4 MHz
   cap confirmed pre/post. Validation against SuperRAM workload
   blocked by item 5.
5. **NEW BLOCKER for Step 7b validation**: probe-shape-dependent
   wedge. `superram_bench.crt` loader now runs all 4 draws + cache
   flush + JML $208000, but bank-$20 payload's COUNT/PASS updates
   never reach screen. Bisect candidate `copyback_probe.crt` —
   simpler structure with single STA al $200080 — wedges identically
   after the header draw. Yet `probe_emu_sta_superram` with the
   SAME `STA al $200080` instruction renders cleanly on the same
   RBF. So the wedge is sensitive to surrounding probe structure,
   not to the instruction itself. Four differential candidates
   listed below; next session should bisect them.
6. **Native-mode round-trip corruption** (`STA al $200080` +
   marker writes + `LDA al $200080` + `STA $040C`) still TBD.
   PHK/PLB doesn't fix; NMI mask alone doesn't fix. Lower priority
   than item 5 because the EMU-mode bench design sidesteps it.

## What changed this session

### Tooling
- `tools/test_cart/prg_to_crt.py` — CIA2 NMI mask added; bootstrap
  rewritten to use ZP-indirect addressing (commits `4174d7c`,
  `b869136`). The wrapper now produces working CRTs for any payload
  size up to ~7.9KB. Boot sequence: SEI / CLD / TXS / CIA2 ICR mask
  $7F / ack / `$01=$37` / `$D011=$1B` / `$D018=$14` / init ZP src
  $FB/$FC=$8100, dst $FD/$FE=load_page / LDY=0, LDX=pages / inner
  `LDA ($FB),Y; STA ($FD),Y; INY; BNE` / `INC $FC; INC $FE; DEX;
  BNE` / `JMP entry`. Bootstrap is 64 bytes.
- `tools/test_cart/load_crt.py` (pre-existing) + new helpers
  `deploy_superram_bench.py`, `deploy_pass_draw.py`,
  `deploy_copyback.py`, `deploy_alive_probe.py`, `shot.py`. File-based
  paramiko deploy avoids transient `socket.gaierror` issues that hit
  `python -c` inline invocations under this sandbox.

### Bisect / probe scripts
- `tools/test_cart/gen_pass_draw_only.py` — minimal 4-draw + halt.
  Reproduced the wedge before the fix; renders cleanly after.
- `tools/test_cart/gen_draw_bisect.py` + `run_bisect.py` — V1-V4
  variants varying loader size + char content. Proved the wedge was
  position-dependent (PC crossing $0900), not character-dependent.
  Screenshots: `tools/test_cart/out/draw_v{1,2,3,4}_*_shot.png`.
- `tools/test_cart/gen_superram_alive_probe.py` — bank-$20 PB writes
  fixed "ALIVE BANK20" via long STA. Does NOT render — bank-$20
  payload's bank-$00 screen writes don't appear.
- `tools/test_cart/gen_copyback_probe.py` — STA al $200080 + cache
  flush + LDA al + display. Wedges after header even with 1 byte.
  Differential against `probe_emu_sta_superram` (which works) is the
  starting point for next session.

### Commits this session (HEAD = `3ae8868`, branch
`milestone-a-build-c-revival`)
- `3ae8868` test_cart: copyback probe — wedges even at single STA al
- `548dc75` test_cart: bank-$20 alive probe — payload writes invisible
- `b869136` fix(prg_to_crt): bootstrap copy uses ZP-indirect (THE FIX)
- `9905a29` docs: session_handoff TL;DR — PA wedge RESOLVED
- `4174d7c` test_cart: CRT bootstrap masks CIA2 NMI + helpers
- `4503648` docs: session_handoff superram_bench wedges mid-draw
- `94ea20a` docs: correct branch name in session_handoff
- `af315c8` docs: realign session_handoff with path_to_20mhz_plan
- `09cbe7b` test_cart: native LDA al tight-loop probe
- `602abb4` docs/session_handoff: CRT wrapper landed
- `d693ca3` STA al/LDA al cart-boot probe + corrected findings
- `4173954` CRT auto-boot wrapper tooling

## Where Step 7b stands

- RTL alt_fire_r2 term in `fpga64_sid_iec.vhd` gated on
  `scpu_fast_path AND cs_ram AND sdram_busy_cnt <= 1` for CPU2/6/A/E
  slots. Bank-0 unaffected.
- RBF: `output_files/C64.rbf` md5 `108dd072`. Deployed at
  `/media/fat/_Test/C64.rbf`.
- Bank-0 bench (`cpu_bound_bench.prg`): off=$0451, smart4x=$044B,
  full4x=$115A → 4.02× scaling. **Empirically capped at 4 MHz.**
- SuperRAM bench: **STILL NOT VALIDATED**. The path is unblocked
  end-to-end EXCEPT for the bank-$20-payload screen-update wedge
  (TL;DR item 5).

## Path to 10x — canonical roadmap

`docs/path_to_20mhz_plan.md` is the durable framing:

- **Milestone A** (~8 MHz): Build C page-mode revival + Step 6
  plumbing. **DEFERRED** per `project_milestone_a_buildC_bisect_2026_05_23.md`
  (V1-V5 bisect; V5 best-attempt still bus-floats). Next attempt
  should LATCH `is_hit/is_conflict` one cycle before dispatch.
- **Milestone B** (~12-16 MHz): `clk_cpu=64 MHz` + F.3' arbiter
  prefetch. Subsumes the older Phase F MCP plan
  (`docs/async_bridge_mcp_handshake_plan.md`).
- **Milestone C** (~20 MHz+): arbiter decouple, demand-driven CPU
  dispatch.

The earlier "option C = EXT slot reclaim" idea conflicts with
canonical Milestone C; dropped.

## Outstanding bugs

### 1. Bank-$20 payload screen updates invisible (NEW — top priority)
After CRT bootstrap fix, the loader of `superram_bench.crt` runs
cleanly through all 4 draws + cache flush + copy loop + cache flush +
JML $208000. Bank-$20 payload either:
- wedges silently at JML / PHK / PLB / Timer A init, OR
- runs the timing loop but its bank-$20 → bank-$00 screen writes
  are held in the SCPU writeback cache.

Probe `copyback_probe.crt` (single STA al $200080 + readback) wedges
after the header draw. `probe_emu_sta_superram` with the SAME
`STA al $200080` works. So wedge is shape-dependent, not
instruction-dependent.

**Differentials to bisect next session** (in order of
cheap-first):
1. `probe_emu_sta_superram` does NOT write to `$D020`/`$D021`;
   `copyback_probe` does. Remove those writes from copyback as the
   first test.
2. Working probe uses `marker()` macro that interleaves char + color
   writes per cell. Copyback bulk-fills color RAM before draws.
3. Working probe uses `base()` macro raw `a.b(0x9D, ...)` for
   screen-clear loops; copyback uses `sta_absx()` helper. Should be
   byte-identical but worth ruling out.
4. Working probe uses `a.sta_al()` helper; copyback uses raw
   `a.b(0x8F, ...)`. Byte-identical at output but different code
   path in the assembler.

Approach: clone `gen_stalong_probe.py`'s `build_emu_sta_superram`
verbatim, then INCREMENTALLY add copyback features (cache flush
first, then LDA al readback, then hex display). First addition that
wedges identifies the trigger.

Probe artifacts on disk:
- `tools/test_cart/out/superram_probe_emu_sta_superram_t8s.png`
  (md5 `ecee8914`) — WORKING reference.
- `tools/test_cart/out/copyback_probe_t8s.png` (md5 `f8871d8e`) —
  WEDGED probe.
- `tools/test_cart/out/superram_alive_probe_t10s.png` (md5
  `1e2f08b4`) — bank-$20 payload silent-wedge reference.

### 2. Native-mode round-trip corruption (existing — lower priority)
`STA al $200080` + marker writes + `LDA al $200080` + `STA $040C`
in native mode causes chaotic screen corruption. PHK/PLB doesn't fix;
NMI mask alone doesn't fix. The EMU-mode bench design sidesteps it
(no CLC/XCE), so this is a deferred curiosity not a blocker.

## State on disk

- Branch: `milestone-a-build-c-revival` (HEAD = `3ae8868`).
- BRIDGE_ACTIVE='0' / CACHE_ACTIVE='0' at
  `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2703`. The "Step 7b deployed"
  win lives in the arbiter alt_fire_r2 logic, NOT in the bridge.
- Working tree has a large set of pre-existing `M` files
  (`tools/lorenz_run/scpu/*.png`, `c64.sv`, `C64.qpf`,
  `build_c64.ps1`, `tools/doom_v342_test.py`) that aren't from this
  session — they were already modified at session start. None of
  this session's changes are uncommitted; check `git status` after
  reboot to confirm.
- Untracked (gitignored) artifacts in `tools/test_cart/out/`:
  freshly built `*.prg` / `*.crt` for `pass_draw_only`,
  `draw_v{1,2,3,4}`, `superram_bench`, `superram_alive_probe`,
  `copyback_probe`, plus screenshots from each.

## Suggested order of business next session

1. **Bisect the bank-$20 wedge** using the differential list above.
   Each iteration is one PRG edit + one CRT wrap + one deploy + one
   screenshot (~30 seconds wall). First wedging step pinpoints the
   trigger.
2. **Once Step 7b validates**, capture COUNT_a / COUNT_b ratio with
   Step 7b ON vs OFF (need a second RBF build with alt_fire_r2
   gated to '0' — ~30 min Quartus). If ratio ≥ +20%, commit Step 7b
   to `master`. If <+10%, revert.
3. **Move to Milestone B** per `docs/path_to_20mhz_plan.md`. F.0
   prep already done. F.1 = bridge rewrite at clk_cpu=clk_sys with
   MCP toggle handshake. Bridge MCP source backed up at
   `tools/scpu_async_bridge_F1_backup.vhd`.

## Pointers

- `docs/path_to_20mhz_plan.md` — CANONICAL Milestones A/B/C with
  risk registers and exit criteria. Read this first.
- `docs/async_bridge_mcp_handshake_plan.md` — Phase F.0-F.5 detail
  (subsumed by Milestone B; F.3' prefetch still lives here).
- `docs/supercpu_feature_status.md` — feature-completion checklist.
- `.claude/skills/mtype/SKILL.md` — keyboard injection + CRT
  auto-boot reference.
- Memory entries (load via `MEMORY.md`):
  - `project_superram_bench_wedge_2026_05_23.md` — bootstrap fix +
    bank-$20 wedge state
  - `project_sta_al_lda_al_crash.md` — long-mode opcode validation
  - `project_milestone_a_buildC_bisect_2026_05_23.md` — Build C
    revival attempts
  - `project_phaseF1c_BRIDGE_ACTIVE_1_wedge.md` — bridge revival
    history

## How to resume on a fresh shell

```powershell
cd C:\LLM\C64\MiSTerSuperCPU
git status                       # confirm branch + clean state
git log --oneline -15            # see session commits
# Pick up bank-$20 wedge bisect:
code tools/test_cart/gen_copyback_probe.py    # start from this
code tools/test_cart/gen_stalong_probe.py     # working reference
# Iterate: edit probe → python gen_X.py → python prg_to_crt.py out/X.prg
# → python deploy_X.py → Read out/X_t8s.png to verify
```

MiSTer IP `192.168.50.130`, root/1. Current RBF md5 `108dd072` at
`/media/fat/_Test/C64.rbf`. Don't touch `/media/fat/_Computer/` —
vanilla rbfs only.
