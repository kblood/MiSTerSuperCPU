# Session handoff — 2026-05-24 end-of-session (REVISED 9)

## TL;DR — Path B v2 reaches CMD SuperCPU kickstart MENU at clk_cpu=64MHz

After REVISED 8's v1 partial-success (PC=$48BB, but unclear what
$48BB was), v2 (sustain-enable variant, commit `4116673`, RBF
`0af2d5b9`) was built, deployed when cd32 freed the device, and
captured screen + UART. **The MENU is the CMD SuperCPU kickstart
boot screen.** Yellow text shows "Press F1" / "Press C=" prompts.
This is the **first F.3' build to produce video output of any kind**.

The PC=$48BB sticky observation is now identified: it's the keyboard
polling loop in the kickstart-installed handler RAM. mtype.py
keystrokes (f1, enter, space, 50× spam) don't advance the loop.
Most likely cause: CIA1 read race at 64MHz — CPU polls ~50 MHz
effective via the bridge, but CIA1 updates at 1 MHz phi2, so the
CPU reads stale "no key" data faster than CIA1 can latch the new
matrix state from the MiSTer USB-HID → keyboard translation.

Full state at `memory/project_f3_pathB_v2_kickstart_menu_2026_05_24.md`.

## What's WORKING (cumulative this session)

- ✓ CPU advances past reset (was wedged at $0000 in 6 prior builds)
- ✓ Enters native 8-bit mode (CLC; XCE executed)
- ✓ Bootmap kickstart runs in $F8 EPROM
- ✓ Handlers installed at $00:$801A-$8054
- ✓ Bootmap cleared, control transferred
- ✓ CMD SuperCPU MENU renders on HDMI (yellow text screen)
- ✓ Frame counter advancing at 60 Hz
- ✓ SP cycling rapidly (CPU executing instructions continuously)

## What's NOT working

- ✗ Keyboard input not advancing past the kickstart menu
- ✗ Therefore KERNAL READY prompt not reached
- ✗ Therefore Lorenz / Doom / Wolf3D regression blocked

After REVISED 7's six-build dead end, Path B (real P65C816 in bench)
ran. Result: bench reproduced the silicon wedge in 30 seconds and
root-caused it as a 1-cycle sync skew between cpu_enable (synced from
bus_ack_pulse) and cpu_rdy (synced from bus_ack_toggle via ack_sync
chain). At clk_cpu>clk_sys, enable fires one clk_cpu BEFORE rdy goes
high, so P65C816's internal `EN = RDY AND CE` never asserts.

Sim-validated fix (commit `c1c8d5c`): added `cpu_enable_out` port to
the bridge that fires on the SAME clk_cpu edge that releases
cpu_rdy_reg (WAIT_ACK → IDLE). All 3 RATIOs (1, 2, 3) + 4 PT modes
pass in sim.

HW deploy (RBF md5 `c4499192`, clk_cpu=clk64, BRIDGE_ACTIVE='1',
SAME_CLOCK_PASSTHROUGH='0'): one 3-second UART window captured before
cd32 agent took the device. Symptom changed dramatically:

| Symptom        | Pre-Path-B (6 wedges)   | Post-Path-B (this build)     |
|----------------|-------------------------|------------------------------|
| PC             | $0000 stable            | $48BB stable                 |
| SP             | $0100 stable            | Cycling $012A-$01FE          |
| Frame counter  | Stuck/barely moving     | Advancing 2/sample @60Hz     |
| Mode           | Emulation (post-reset)  | Native 8-bit (CLC;XCE done)  |

CPU IS running (~150 stack ops per 33ms sample), but PC sticky at
$48BB suggests either tight loop, sticky debug reg, or multi-cycle-op
starvation. Distinct from prior wedges — fix is working in the
direction of progress, just not all the way.

Full analysis at
`memory/project_f3_pathB_partial_2026_05_24.md`.

## Path B sim infrastructure (durable artifact)

- `sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd` — real `cpu_65c816`
  + `scpu_async_bridge` + mock arbiter with 3-byte ROM. Detects
  silicon-style wedge in 30 seconds.
- `sim/scpu_async_bridge_tb/run_cpu_in_bridge_tb.ps1` — compiles full
  P65C816 IP tree + bench, runs with RATIO/STOP_TIME generics.
- Reusable for every future bridge variant. Always run before any
  silicon iteration touching the bridge.

## Next-session entry — pick one (HDL change vs verification first)

1. **VICE differential.** Run xscpu64 with the same SCPU EPROM
   image. Does the kickstart MENU appear in VICE? If yes, it's
   expected behavior — narrow next probe to keyboard path. If no,
   the menu is a v2 timing artifact — debug clock-rate effects on
   the kickstart's $D0B6 / $D072 register reads.
2. **Sanity baseline comparison.** Re-deploy RBF `036110c5` (pre-
   Path-B passthrough). Does it ALSO show the SCPU menu (timing out
   quickly), or boot straight to KERNAL READY without a menu? If
   straight to READY, the menu is v2-specific = clk_cpu change
   altered kickstart's behavior.
3. **Stretch CIA1 reads in the bridge.** If race is suspected, gate
   bus_di_in capture for I/O range ($D000-$DFFF) with an extra
   1-clk_sys hold so CIA1 has time to settle. Bench-test, then
   build. Risk: I/O timing changes might break other things.
4. **Extend cpu_in_bridge_tb** with KERNAL ROM dump + CIA1 model.
   Lets you reproduce the menu + keyboard polling in sim. Higher
   investment but unlocks autonomous iteration.
5. **SignalTap the bridge** during keyboard polling. Capture bus_di
   path + bus_addr decode for accesses to $DC01. ~30 min/build.

Default recommendation: **option (1) then (2)** — verify scope BEFORE
any HDL change. The bench can't currently model CIA1 keyboard, so
sim won't help until extended (option 4).

## State on disk (end of session)

- Branch: `milestone-b-cdc-rewrite` HEAD `c1c8d5c`
  (was `1cd6261` before Path B work).
- RBF deployed to MiSTer: `c4499192` (Path B fix active). cd32 agent
  has overwritten with CannonFodder; redeploy required next session.
- Pre-Path-B sanity RBF: `036110c5` (commit `67451ff` = F.1' checkpoint
  with passthrough). Use this if Path B build needs to be reverted.
- Bisect stash from earlier today: `git stash@{0}` named
  `F.3-prime-enable-bisect-deadend-2026-05-24` (preserved).

## Three paths forward (UNCHANGED from REVISED 7, status updated)

### Path A — SignalTap the bridge
Still applicable. Now better-targeted: capture state during $48BB
stall, not $0000 wedge. ~30 min per capture.

### Path B — Real P65C816 in bench
**LANDED.** Bench infrastructure exists, fix sim-validated, HW
deploy showed progress. Continue iterating from here.

### Path C — Abandon the bridge
Lower priority now that Path B made progress. Keep as fallback if
$48BB stall is not resolvable.

## What NOT to do (lessons from this session)

1. Don't iterate the enable scheme in isolation — sync-chain skew was
   the bug, fixed properly only by deriving enable INSIDE the bridge
   from the same FSM edge as rdy.
2. Don't run bench scenarios alone before silicon — the model-CPU
   bench passed 5/5 even when EFF_BRIDGE_ACTIVE=1 was utterly broken.
   The cpu_in_bridge_tb.vhd is the new floor for credible validation.
3. Don't deploy when cd32 agent has the lock. The MiSTer is shared.

## Milestone status

- Milestone A: **closed at ceiling** (unchanged).
- Milestone B:
  - [x] F.0/F.1'/F.2/F.3' design + impl + sanity.
  - [x] F.3' enable attempts: 1 wedge → 6-build bisect → Path B fix.
  - [-] **NEXT: resolve $48BB residual stall on HW.** Options (1)/(3)
        above.
  - [ ] F.4: Doom/Wolf3D/Lorenz regression (blocked).
  - [ ] F.5: optional cache re-enable.
- Milestone C: dormant.

## Commits this session

| commit  | what                                                     |
|---------|----------------------------------------------------------|
| 67451ff | bridge(F.3' enable rollback): document CPU enable CDC gap |
| 1cd6261 | docs(handoff): F.3' enable 6-build bisect — MCP path broken |
| c1c8d5c | bridge(F.3' Path B): cpu_enable_out aligned with rdy release |

## Memory entries (new + updated)

- `project_f3_pathB_partial_2026_05_24.md` (NEW — partial-success state)
- `project_f3_mcp_data_path_broken_on_hw_2026_05_24.md` (LARGELY SUPERSEDED — fix found)
- `project_f3_enable_cpu_enable_cdc_2026_05_24.md` (SUPERSEDED — wrong hypothesis)
- `project_f3_two_stage_protocol_2026_05_24.md`

## Pointers

- `docs/path_to_20mhz_plan.md` — Milestones A/B/C overview.
- `docs/async_bridge_phase_f_revised.md` — revised Phase F plan.
- `C64_MiSTer/rtl/scpu_async_bridge.vhd:67-75` — new cpu_enable_out port.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2649-2663` — wired enable from bridge.
- `sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd` — Path B bench (KEEP).

MiSTer IP `192.168.50.130`, root/1. cd32 agent has the device as of
03:26:50. Confirm `/tmp/CORENAME` and lock before any deploy.

----

# OLD CONTENT (REVISED 7) ARCHIVED BELOW for reference



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
