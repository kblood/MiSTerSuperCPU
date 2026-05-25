# Session handoff — 2026-05-25 late evening → IRQ-race falsified in sim; sim path exhausted

## 0. TL;DR for the next agent

The shipped baseline (`d564dea` / RBF md5 `8a7489ef`) is **still the ship answer** — passthrough + CIA gates, fully validated end-to-end. This session did **NOT** change the active build.

This session's continuation **executed the IRQ-race probe** that the prior session's §6 option (a) called for. Result: **the bench wedged because of a bench bug (no stack RAM model), not because of an actual bridge bug**. With the bench fixed, MCP IRQ delivery passes cleanly. The IRQ-vector-fetch race hypothesis is now **falsified in sim**, joining 4 prior MCP wedge hypotheses on the falsified list.

Per the design doc's own §C.3 decision tree, "both races falsified" means the strategic options collapse to:
1. **Pivot to Milestone A or C** (or accept the ~3MHz passthrough baseline and stop).
2. **Build the bridge-internal UART probe and run on HW** anyway — observational, captures FSM state during the silicon wedge regardless of mechanism. ~2-3 hours wall clock (RTL wiring + Quartus + deploy + analysis).
3. SignalTap is documented but never produced a capture in this project (`memory/reference_signaltap_documented_not_working.md`). Don't recommend.

**No code committed.** Bench fixes are uncommitted in the Milestone B worktree on top of `4b4087e`.

---

## 1. State of the tree

**Active build (unchanged):** `/media/fat/_Test/C64.rbf` on MiSTer: `8a7489ef` from commit `d564dea`. Source state: `SAME_CLOCK_PASSTHROUGH => '1'` (MCP disabled), CIA1 write-only gate, CIA2 `cia2_write_safe` gate, Option F+G UART probes intact.

**Three worktrees from earlier this session** (parallel subagents, design + sim only):
- `worktree-agent-a282ad7488dff33e3` — Milestone A: `sim/sdram_pm_tb/` GHDL bench passes, design doc `docs/milestone_a_buildc_design.md`.
- `worktree-agent-a9a3d6f3a7a3800f2` — Milestone B: `sim/scpu_async_bridge_tb/cpu_cia_irq_tb.vhd` + design doc `docs/milestone_b_bridge_probe_design.md`. Subsequent in-place edits in this worktree (uncommitted, see §3) fixed the bench-side wedge.
- `worktree-agent-a7842d2f07c035f24` — Milestone C: `sim/arbiter_demand_tb/` 18/18 PASS, design doc `docs/milestone_c_arbiter_design.md`.

None of these are merged. Branches `worktree-agent-*` exist on disk; user can merge or cherry-pick on their timeline.

---

## 2. The IRQ-race falsification, in detail

### What the Milestone B subagent built

A new bench `cpu_cia_irq_tb.vhd` derived from `cpu_cia_real_tb.vhd`, with: SEI dropped, `cia_irq_n` wired to CPU `irq_n`, Timer A configured for periodic underflow. Goal: reproduce the silicon LOAD"*" wedge by exercising the IRQ-vector-fetch sequence the prior 3 benches all skipped (they SEI'd).

### What I observed first

Bench output under MCP (RATIO=2, SAME_CLOCK_PASSTHROUGH='0'):
- Final PC = $0266, max PC = $EAEB (NOP fill)
- Handler visits = 52, vec_fetch_count = 208 (~4 per IRQ)
- Main loop counter $C2 never advanced past 0
- `req-ack gap = -998` (mock arb firing 2x ack per req)

I initially called this "first sim reproduction of the silicon wedge" and wrote a memory entry to that effect. **That entry has been retracted** (`memory/project_irq_race_bench_wedges_mcp_2026_05_25.md`).

### The real diagnosis (PC trace)

Adding a per-PC-change print to the bench revealed the actual mechanism:
- IRQ fires at $021D → handler runs $0260 → $0265 (RTI) → handler exits to **$EAEA** (NOP fill)
- CPU loops in NOP-fill until next IRQ → handler again → RTI → $EAEA again → repeat

Root cause: the bench's mock arbiter only modelled RAM for `$00:$00xx` (zp). Accesses to `$00:$01xx` (stack page) fell through to `rom_byte` which returns `$EA` for unmapped addresses. So every IRQ-entry push went to nowhere and every RTI pulled `$EA $EA $EA` → PC = $EAEA. The "4 fetches per IRQ" pattern I misread as a race signature was the CPU spinning in NOP-fill firing more IRQs than expected.

### After the bench fix

Three small changes to `cpu_cia_irq_tb.vhd` (uncommitted, see §3):
- `zp_ram` extended from 256 to 512 bytes
- Mock arb decodes both `$00:$00xx` AND `$00:$01xx` as RAM (9-bit index)
- (Also added: `pending_valid='0'` guard on mock-arb latch; PC trace process — harmless, more accurate to real arb)

Bench result (MCP, RATIO=2, 500us): **PASS_NO_RACE**. iter=4, handler visits=173, no wedge.

Bench result (MCP, RATIO=2, 2ms long-run): iter advances monotonically 4→8→12→17 across the four snapshots, handler visits=74. Clean.

The IRQ-vector-fetch race hypothesis is **falsified**.

---

## 3. Uncommitted changes (Milestone B worktree only)

In `C:\LLM\C64\MiSTerSuperCPU\.claude\worktrees\agent-a9a3d6f3a7a3800f2`, on top of commit `4b4087e`, file `sim/scpu_async_bridge_tb/cpu_cia_irq_tb.vhd`:
- `type zp_ram_t is array (0 to 511)` — was 0 to 255
- Stack page decode added to mock arb
- `pending_valid='0'` gate on mock-arb latch
- pc_trace process for in-window PC logging

These should be **committed** (and ideally merged or cherry-picked into the milestone-b-cdc-rewrite branch alongside the design docs) — they're a real fix to a real bench bug and they prove the IRQ-race falsification.

Memory updates:
- `project_irq_race_bench_wedges_mcp_2026_05_25.md` — now contains retraction
- `MEMORY.md` — index entry updated

---

## 4. Falsified hypotheses (cumulative across sessions)

| Hypothesis | Falsified by |
|---|---|
| Phantom write to CIA1 IMR/CRA | v13d gate (cs-write-only) restored IM stability |
| Phantom write to CIA2 IMR/CRA | Option F UART probe — values constant during wedge |
| Phantom write to CIA2 PRA/PRB/DDRA/DDRB | Option G UART probe — values legitimate |
| Variable-latency on basic CIA reads | `cpu_cia_bridge_tb.vhd` PASS |
| MCP-induced spurious ICR clear-on-read | `cpu_cia_real_tb.vhd` PASS |
| Passive W/R interleaving with mock 1541 | `cpu_cia_rw_tb.vhd` PASS |
| IRQ-vector-fetch race (race α / race β) | `cpu_cia_irq_tb.vhd` PASS (after stack-RAM fix) |

That's seven falsified mechanisms. The silicon wedge mechanism remains **unidentified**.

Possibilities not yet tested in sim:
- Real IEC handshake (CIA2 PRA/PRB drive vs IEC bus state during KERNAL IECIN). The wedge always sits in IECIN. Needs a mock IEC-peer device that responds to bus drives — not just a CIA.
- Real arbiter `enableCpu_816` cadence on the C64 wheel (1MHz typical at base; ~1.5 clk_sys at 20MHz turbo) vs the mock arb's fixed 4-clk_sys cadence. Could cause bridge issues when slots arrive non-uniformly.
- Multi-CIA contention (CIA1 keyboard scan + CIA2 IEC + Timer A on both). Bench only has CIA2.
- `cpuDi` mux in `fpga64_sid_iec.vhd` has many sources (RAM/ROM/CIA1/CIA2/VIC/SID/REU/cache/cartridge). MCP may expose a path the mux can't satisfy in time.

---

## 5. Strategic options on the table

The honest decision space, given seven falsified hypotheses and no current sim-side reproduction:

### (a) Build the bridge-internal UART probe + HW build
Per `docs/milestone_b_bridge_probe_design.md` §B. Five new ports through `scpu_async_bridge.vhd` → `fpga64_sid_iec.vhd` → `c64.sv` → `debug_uart_pool_fmt.sv` (LINE_LEN 319 → ~352). Cost: ~1 hour RTL wiring + 30-40 min Quartus + 5-10 min deploy + analysis. **Pass/fail rubric (design doc §C) was written to discriminate race α vs β — now mostly observational since both are falsified.** What it WILL tell us: bridge FSM state at the moment of wedge, req/ack gap (is bridge actually stalled?), is the wedge site interruptible. What it WON'T tell us: which downstream component (CIA, bus mux, IEC peer) is the actual culprit — those need a different probe.

### (b) Accept passthrough baseline and ship Milestone B parked
Update `docs/path_to_20mhz_plan.md` to mark Milestone B at "parked at passthrough, sim infrastructure complete, seven hypotheses falsified, no silicon reproduction available." Tag `milestone-b-passthrough-shipped`. The native SuperCPU at ~3MHz running Doom/Wolf3D/Lorenz/IEC is already a real deliverable.

### (c) Pivot to Milestone A
Per `docs/milestone_a_buildc_design.md` (worktree A): Build C SDRAM page-mode revival + Step 6 plumbing target ~8MHz. Sim infrastructure (sdram_pm_lite_tb) already passes 4 scenarios + Step 6 closure check. Does NOT depend on MCP. Independent track. Different wedge history (Build C v1-v4 all wedged HW per `step5-build-c-altslot-conflict-gate` branch); the design doc proposes the registered `alt_fire_r` pattern to dodge it.

### (d) Pivot to Milestone C
Per `docs/milestone_c_arbiter_design.md` (worktree C): demand-driven arbiter. Bench (18/18 PASS) demonstrates the interface. But per the design doc §F, C-alone (without B) gives ~0 measurable speedup over the shipped baseline. So this only makes sense after B lands — which is parked.

---

## 6. If next agent must do something today

Pick (a), (b), or (c). **All three are defensible.** The benches and memory updates from this session stand regardless of the choice.

If picking (a): start by reading `docs/milestone_b_bridge_probe_design.md` §B for the exact port additions and LINE_LEN bump. Verify Option G's wiring pattern in `c64.sv` and `debug_uart_pool_fmt.sv` (search for `dbg_pra_cia2` and `"PA:"`). Implement, build, deploy.

If picking (b): commit the three worktrees' work (or cherry-pick), commit the bench-bug fix from §3, tag, update `path_to_20mhz_plan.md`. Update `architecture_diagrams.md` to reflect current state.

If picking (c): the Milestone A worktree has a working sdram_pm_lite bench. The next step is the real `sdram_pm.v` HIT path RTL edits, then a Quartus build. Risk: Build C wedge history (4 prior attempts). The design doc's `alt_fire_r`-registered pattern is the proposed mitigation.

---

## 7. Cross-refs (memory)

- `passthrough-plus-gates-baseline-2026-05-25` — shipped build, fully validated
- `irq-race-bench-wedges-mcp-2026-05-25` — **RETRACTED**, contains the bench-bug analysis
- `option-e-three-benches-pass-mcp-2026-05-25` — earlier 3 benches (still valid)
- `parallel-subagents-only-for-design-fronts-2026-05-25` — the pattern that produced this session's 3 worktrees
- `reference-signaltap-documented-not-working` — SignalTap reality check
- `v13d-mcp-iec-load-fix-2026-05-25` — last partial MCP fix
- `optionF-cia2-imrcra-no-phantom-2026-05-25` + `optionG-cia2-port-no-phantom-2026-05-25` — CIA register state ruled out
- `v12-mcp-cia1-irq-stops-2026-05-24` — HW evidence that motivated option (a); the "0 IRQs" data was likely incidental, not a real CIA1 IRQ generation bug, and is now superseded by sim evidence that CIA1 can fire IRQs cleanly under MCP

---

## 8. Lesson worth remembering

When a sim bench reports "wedge reproduced" and the symptom is qualitatively different from any known mock-side bench wedge, **add PC trace logging before claiming sim reproduction**. The distinguishing question: is the CPU stuck on a real bridge-stalled bus access, OR is it freely running through nonsense addresses? In this case the CPU was running NOPs at full clock — clearly not bridge-stalled. The 4-fetches-per-IRQ pattern I read as "race α signature" was actually the CPU's free-running re-entry into the handler. ~30 minutes of analysis would have caught this before the first memory entry was written.
