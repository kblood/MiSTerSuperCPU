# Session handoff — 2026-05-24 end-of-session (REVISED 7)

## TL;DR — F.3' MCP data path is broken on hardware in every config tested

Continued from F.3' enable (yesterday's wedge analysis) by attempting
3 enable-CDC fix options across both clk_cpu choices. **All 6 builds
wedged.** The clean conclusion is that the bridge's MCP data path
itself is broken on hardware, regardless of enable scheme or clock
matching. The earlier hypothesis ("CPU enable CDC is the gap") is
**superseded**: builds 5 and 6 wedge at matched clocks
(clk_cpu=clk_sys), so CDC cannot be the cause.

Six-build bisect (all 2026-05-24, fully detailed in
`memory/project_f3_mcp_data_path_broken_on_hw_2026_05_24.md`):

| # | Config                                                    | clk_cpu  | RBF md5    | Symptom                                                     |
|---|-----------------------------------------------------------|----------|------------|-------------------------------------------------------------|
| 1 | F.3' enable original (registered rdy, enableCpu_816)      | clk64    | bcde5e56   | PC=$00:0000 STABLE                                          |
| 2 | option (b) sync'd enable_edge, BRIDGE_ACTIVE=0            | clk64    | dcf30491   | PC bouncing in KERNAL IRQ chain                             |
| 3 | option (b) + BRIDGE_ACTIVE=1                              | clk64    | d1daadc1   | PC=$00:0000 STABLE                                          |
| 4 | option (a) CE='1' constant, comb rdy + just_granted        | clk64    | a2af8007   | PC=$4804 STABLE (BRK loop)                                  |
| 5 | option (a) at matched clocks                              | clk_sys  | 41704714   | PC=$4805 STABLE (same minus 1)                              |
| 6 | MCP-only at matched clocks (synced enable, registered rdy)| clk_sys  | 30831060   | PC=$00:0000 STABLE                                          |

Every config where `EFF_BRIDGE_ACTIVE = BRIDGE_ACTIVE AND NOT
SAME_CLOCK_PASSTHROUGH = '1'` wedges, even at matched clocks.
The bench (5/5 scenarios) does not catch this because its model
CPU doesn't reproduce P65C816 microcode-driven VPA/VDA or
continuous DR latch.

The MCP data path has **never booted KERNAL on hardware**, in any
F.1c/d/e/f or F.3' variant. Multiple sessions have iterated bench
scenarios → silicon wedge.

## Recovery state (end of session)

- Branch: `milestone-b-cdc-rewrite` HEAD `159bf8e` (no new commits).
- Working tree: RTL clean at commit `67451ff` (F.1' checkpoint).
- 6 bisect builds' edits stashed: `git stash@{0}` named
  `F.3-prime-enable-bisect-deadend-2026-05-24`. Don't lose this —
  it has the option-a FSM logic + en_sync chain + SDC false-paths
  that may be reusable when the MCP data path itself is fixed.
- Sanity RBF (md5 `c61bfa77`) rebuilt and pushed to MiSTer at
  `/media/fat/_Test/C64.rbf`. (See "next steps" — rebuild was in
  flight at session end; confirm completion on first next-session
  action.)

## Three paths forward (next session — pick one BEFORE iterating)

### Path A — SignalTap the bridge

Capture cpu_fsm + bus_request_pending_reg + strobe_edge + cpu_rdy_reg
+ bus_di_reg over the first 200 clk_sys after KERNAL reset, with
BRIDGE_ACTIVE='1' SAME_CLOCK_PASSTHROUGH='0' clk_cpu=clk_sys
(Build 6 config). The wedge signatures are stable but uninformative
on UART — SignalTap is the cheapest way to see what the bridge is
actually doing inside.

Pros: real silicon data; no new HDL to write.
Cons: SignalTap adds 6+ ALMs and a M10K, may change timing closure;
~30 min per capture; physical access to MiSTer (already accessible via SSH).

### Path B — Real P65C816 in the bench

Replace `bridge_tb.vhd`'s model CPU with an actual `p65c816` instance
+ 256-byte ROM at $FFFC (reset vector → tight loop), and trace
cpu_di/vpa/vda/EN/RDY for the first 100 instructions. If even the
bench wedges, the bug is in the bridge HDL itself, fixable in sim.
If the bench passes but silicon wedges, look at synthesis-level
issues (preserve attributes, MLAB inference, fitter routing skew).

Pros: closes the bench-vs-silicon gap; faster iteration than full builds.
Cons: ~half-day to write the new bench; P65C816 may need stripped-down
config to avoid pulling SDRAM/cache/etc.

### Path C — Abandon the bridge, pursue alternatives

The bridge approach has cost ~12 hardware iterations across F.1c/d/e/f
(passed once), F.3' (sanity), F.3' enable (3 wedges), F.3' bisect
(6 wedges). All to gain clk_cpu=64MHz. Two other speedup levers
don't require the bridge at all:

1. **SDRAM page-mode (Build C / Milestone A revisit).** Page-mode
   FSM bisect at `project_milestone_a_buildC_bisect_2026_05_23.md`
   pinned ≥2 bugs in V1-V5 drafts; V5 fixes ride along when revived.
   The remaining suspect is bank-tracking race on live addr inputs.
2. **Arbiter slot reclamation (Milestone C).** See
   `docs/path_to_20mhz_plan.md`. Reclaims unused EXT/DMA slots
   for CPU at clk_sys without changing clk_cpu.

Pros: no bridge dependency; established methodology from Milestone A.
Cons: gives up the clk_cpu=64MHz target; speedup ceiling lower.

## Recommendation

**Path B first** (≥1 day) — closes the bench gap permanently and
either confirms the bridge HDL has the bug (then Path A becomes
unnecessary) or proves the synthesis path is fundamentally
incompatible (justifies Path C). If Path B passes the bench with a
real CPU, then Path A on hardware to find the synthesis-level skew.
Only fall back to Path C if both A and B are inconclusive.

## What NOT to do

1. **Do not iterate the enable scheme.** All three options tried
   (a/b/c-derived); none fix it. The enable is not the bug.
2. **Do not trust bench-only "improvements."** Bench passing means
   nothing for silicon until a real P65C816 is in the bench.
3. **Do not retry without instrumentation.** Stable PC values are
   uninformative; need bridge internal state.
4. **Do not commit the bisect stash to master.** It's exploration
   work, not a fix. Preserve as a stash or branch only.

## Milestone status

- Milestone A: **closed at ceiling** (see prior handoff §Milestone A).
- Milestone B:
  - [x] F.0: verification + Appendix A/B.
  - [x] F.1': bridge restored with SAME_CLOCK_PASSTHROUGH gate.
  - [x] F.2: bench parametric across RATIO + PASSTHROUGH_MODE.
  - [x] F.3' design sketch + implementation (commit `03bf677`).
  - [x] F.3' enable attempted — wedged (yesterday).
  - [x] F.3' enable bisect (6 builds today) — proved MCP data path
        itself broken; CDC was a red herring.
  - [ ] **NEXT: pick Path A/B/C above before any more builds.**
  - [ ] F.4: Doom/Wolf3D/Lorenz regression (blocked on Path resolution).
  - [ ] F.5: optional cache re-enable.
- Milestone C (slot reclamation): not started; available as Path C fallback.

## State on disk

- Branch: `milestone-b-cdc-rewrite` HEAD `159bf8e`
- RBF on MiSTer: `/media/fat/_Test/C64.rbf` md5 `c61bfa77` (sanity build, rebuilt this session)
- Stashed bisect: `git stash@{0}` named `F.3-prime-enable-bisect-deadend-2026-05-24`
- Wedge screenshots: `tools/test_cart/out/_f3_enable_boot.png` (Build 1 reference)
- Bench artifacts: `sim/scpu_async_bridge_tb/work/`

## Memory entries

- `project_f3_mcp_data_path_broken_on_hw_2026_05_24.md` (NEW; supersedes below)
- `project_f3_enable_cpu_enable_cdc_2026_05_24.md` (SUPERSEDED)
- `project_f3_two_stage_protocol_2026_05_24.md`
- `project_step7b_alt_fire_r2_confirmed_2026_05_23.md`
- `project_milestone_a_buildC_bisect_2026_05_23.md` (Path C source)

## Pointers

- `docs/path_to_20mhz_plan.md` — Milestones A/B/C overview.
- `docs/async_bridge_phase_f_revised.md` — revised Phase F plan.
- `docs/async_bridge_f3_prefetch_sketch.md` — F.3' design sketch.
- `C64_MiSTer/rtl/scpu_async_bridge.vhd` — F.3' two-stage FSM (active).
- `tools/scpu_async_bridge_F1_backup.vhd` — pre-F.3' reference.

MiSTer IP `192.168.50.130`, root/1. RBF md5 `c61bfa77` at
`/media/fat/_Test/C64.rbf`. Don't touch `/media/fat/_Computer/`.
