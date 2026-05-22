# Path to 20 MHz SuperCPU — Multi-Milestone Plan

**Status:** strategic plan (2026-05-22). Replaces ad-hoc speedup work after the Phase F.1 wedge ladder revealed that piecemeal arbiter/bridge changes are stalling. Goal: reach ≥20 MHz effective SCPU dispatch (real-hardware parity) via three sequenced milestones, with explicit exit conditions if any milestone wedges.

**Why three milestones, not one big rewrite:** the fork's history shows architectural rewrites cost 50-100 builds to stabilize (D4.2 cache wedge, Build C wedge ladder, Step 2 alt-slot wedges, Phase E.1 64 MHz wedge, Phase F.1 four-rung wedge). Each milestone gates the next so we can pivot early if a piece doesn't pan out. Pivot targets: U64 hardware, accept current ~6 MHz ceiling, or partial parity at lower MHz.

## Baseline (today, HEAD `80dc8d7`)

- `clk_sys = clk_cpu = 32 MHz`; `clk64 = 64 MHz` (SDRAM only)
- Step 5a alt-slot live → ~5-6 MHz effective on SCPU-bank code (1.5× over 4 MHz steady)
- BRIDGE_ACTIVE='0' (bridge is plumbed but inert per F.1 wedge analysis)
- Build B SDRAM controller (`sdram_pm.v`, 8-clk64 = 4-clk32 fixed cycle)
- Resource: 26,834 ALMs (64% Cyclone V)

References for context: `docs/async_bridge_phase_f_revised.md`, memory files `project_phaseF1c_BRIDGE_ACTIVE_1_wedge.md`, `project_step2_alt_slot_wedges_doom.md`, `project_doom_speedup_via_turbo_osd.md`.

---

## Milestone A — ~8 MHz steady (Build C page-mode revival + Step 6 plumbing)

**Goal:** prove the alt-slot can fire reliably (not just opportunistically) by shortening the SDRAM cycle on cache HITs to 3 clk64, making alt-slot at CPU2 fit within the busy window.

**Estimated effort:** 2-3 weeks if no wedge ladder, +1-3 weeks if Build C wedges as it did before.

**Files touched:**
- `C64_MiSTer/rtl/sdram_pm.v` — re-enable page-mode HIT path (3 clk64 vs 8 clk64). Was attempted on branch `step5-build-c-altslot-conflict-gate` and wedged HW. Refit with CONFLICT detection learned from that attempt.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — Step 6: replace `sdram_busy_cnt` static `:= "011"` preload with `sdram_ready_sync(1)` feedback. Sync chain already plumbed (line 2769). Counter becomes "asserts busy on cpu_cyc fire, deasserts when ready_sync rises." Removes the fixed-cycle-length assumption.
- `C64.sdc` — re-verify multicycle constraints for the variable cycle length. Reference: memory `feedback_renaming_sdram_entity_breaks_sdc.md` (rename → SDC filter dropped → wedge).

**Risk register:**
- *Risk A.1 — Build C wedge ladder repeats.* The `step5-build-c-altslot-conflict-gate` branch tried v1-v4 of conflict gate; all wedged on HW despite passing static trace. Root cause: synthesis hazard on cpu_cyc → ramCE → cart_ce when page-mode timing tightens. **Mitigation:** start from Step 5a's registered `alt_fire_r` pattern (which avoided the Step 2 wedge); add Build C HIT path BEHIND the same register; do NOT introduce additional combinational gating on `cpu_cyc`.
- *Risk A.2 — sdram_ready_sync latency wider than cycle.* 2-FF sync = 2 clk32 latency from real ready edge. On a 3-clk64 HIT, real ready edge at ~1.5 clk32 → sync sees it at ~3.5 clk32. Counter clears too late, alt-slot at CPU2 (clk32 2) still blocked. **Mitigation:** experiment with single-FF on HIT path only (data_valid is a level signal so single-FF is metastability-safe per existing comment on line 740-744). Or accept Build B-only behavior at Milestone A and defer HIT speedup to Milestone B's CDC rework.
- *Risk A.3 — REU DMA interaction.* REU FETCH/STASH uses SDRAM cycles back-to-back. With variable-length cycles, REU throughput might shift. **Mitigation:** Lorenz + Doom + Wolf3D regression after the change; if REU regresses, gate page-mode on `!dma_active`.

**Validation:**
- GHDL bench at `sim/c64_reduced_harness/` for the busy-counter feedback alone (no Build C).
- HW Doom loop: target ≥2× speedup over current ~1.5× alt-slot baseline → effective ~8 MHz on SCPU-bank code. Existing scripts: `tools/option_c/step5_doom_smoke.py`, `tools/doom_v356_PLAY.py`.
- Lorenz regression (t65 + scpu) — must reach `andix - ok` at 30-min cap, matching v356 baseline.
- Wolf3D regression — must still reach Level 1 playable view.

**Exit / pivot:**
- **PASS:** Doom reaches 3D bitmap in ≤200s (vs ~300s today) AND Lorenz clean AND Wolf3D playable → proceed to Milestone B.
- **WEDGE >2 weeks:** revert Build C, keep Step 6 plumbing (cheap, no regression even if unused). Reassess whether Milestone B alone (without Build C) is still worth pursuing. ~12 MHz at clk_cpu=64 MHz without Build C is still useful but less than Milestone B+Build C combined.
- **WEDGE >4 weeks total:** abandon Build C entirely. Accept Milestone A as ~6 MHz ceiling. Consider whether Milestone B is still worth the risk.

---

## Milestone B — ~12-16 MHz (`clk_cpu = 64 MHz` + F.3' arbiter prefetch)

**Goal:** lift the per-clk_sys CPU-step ceiling from 1 to 2 by doubling clk_cpu, with the arbiter pre-issuing CPU requests so the MCP bridge has time to settle before the CPU latch edge.

**Estimated effort:** 3-4 weeks core work + 1-2 weeks integration debug. Highest wedge-risk milestone — the F.1 wedge already showed how brittle CDC at the CPU↔SDRAM boundary is.

**Files touched:**
- `C64_MiSTer/c64.sv` — restore Phase B `clk_cpu = clk64` wire (was `clk_cpu = clk_sys` per Phase F.1 rollback at line 328).
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — expose new `cpu_prefetch_window` signal at `cpu_cyc_s(0)` (one clk_sys earlier than `enableCpu_816`). Add port to bridge for `bus_request_strobe_in`.
- `C64_MiSTer/rtl/scpu_async_bridge.vhd` — re-engage `BRIDGE_ACTIVE='1'`. Source-side FSM toggles `cpu_req_toggle_reg` on `bus_request_strobe_in` edge, holds payload until ack-toggle returns. MCP source preserved in `tools/scpu_async_bridge_F1_backup.vhd` (per HEAD commit `80dc8d7` notes).
- `C64.sdc` — add clock-groups for clk_sys↔clk_cpu, `set_max_delay`/`set_min_delay` across toggle signals per `hdl-coding-guidelines/24-cdc-multi-bit.md §6`.
- `C64.qsf` — confirm SDC_FILE assignment (per memory `feedback_renaming_sdram_entity_breaks_sdc.md`).

**Risk register:**
- *Risk B.1 — Phase E.1 wedge repeats.* The previous `clk_cpu = clk64` attempt wedged 3 bridge configs (memory `project_phaseE1_64mhz_wedge.md`). Root cause was missing request/ack handshake. **Mitigation:** F.3' prefetch IS the missing handshake. The F.1 wedge analysis specifically identified why same-clock MCP failed; the F.3' design pre-issues 2-3 clk_cpu cycles before enableCpu, giving the MCP round-trip time to settle.
- *Risk B.2 — Resource budget.* Estimated +1500-2500 ALMs for the prefetch logic + active bridge FSMs. Pushes us from 64% → ~70-72% (back to fork's historical peak). **Mitigation:** if Quartus reports fitter struggle, disable Build C cache (Milestone A's `sdram_pm` HIT path is the speedup, the cache is a separate thing) to free RAM blocks.
- *Risk B.3 — VIC bus contention.* clk_cpu=64 MHz means CPU steps mid-clk_sys-cycle. VIC still owns its slots. If CPU pre-fetches a SDRAM address that conflicts with a VIC fetch in progress, ramCE flickers. **Mitigation:** prefetch window must check VIC bus-take BEFORE issuing the bridge toggle. Add an early-cancel path so the bridge can drop a pending request without confusing the CPU.
- *Risk B.4 — DMA preemption mid-prefetch.* If REU DMA starts during the prefetch window, the CPU's planned access needs to be cancelled and re-issued. **Mitigation:** `bus_request_cancel` line driven by `dma_active`; bridge FSM handles cancel-and-retry.

**Validation:**
- GHDL bench at `sim/p65c816_tb/` with two-domain harness (already prepped per memory `project_phaseF_mcp_handshake_plan.md`).
- STA: clk_sys and clk_cpu must both close with positive slack; document worst path before/after.
- HW Doom loop: target ≥3× over Milestone A baseline → ~12-16 MHz on SCPU-bank code.
- Lorenz + Wolf3D regressions as Milestone A.

**Exit / pivot:**
- **PASS:** Doom reaches 3D bitmap in ≤100s AND Lorenz clean AND Wolf3D playable AND STA closes → proceed to Milestone C.
- **WEDGE >3 weeks:** roll back to Milestone A baseline. Reassess: is Milestone C alone (arbiter decouple at clk_cpu=clk_sys) worth pursuing as a smaller win, or do we cap the fork at Milestone A?
- **STA fails closure:** the F.3' prefetch may need tuning of the prefetch window width (1 vs 2 vs 3 clk_cpu cycles). Treat as a tuning loop, not a wedge.

---

## Milestone C — ~20 MHz+ (arbiter decouple, demand-driven CPU dispatch)

**Goal:** remove the fixed-slot wheel for CPU dispatch. CPU asks the arbiter "may I go now?" instead of arbiter telling CPU "your slot is now." Combined with Milestone A's variable-length SDRAM and Milestone B's faster clk_cpu, this unlocks the remaining bandwidth.

**Estimated effort:** 2-4 weeks. Lowest unknown-risk milestone *if* Milestones A and B are stable, because the architectural separation is cleanest. But: if A or B are wobbly, integration debug here can balloon.

**Files touched:**
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — major rewrite of `cpu_cyc` derivation. Today it's a combinational gate on `sysCycle`; new design: CPU drives `cpu_req` continuously when running, arbiter grants `cpu_grant` when SDRAM is free AND no higher-priority requester (VIC, DMA) is active. The 32-cycle wheel still controls VIC and DMA windows; CPU just opportunistically uses whatever's left.
- Possibly `C64_MiSTer/rtl/cpu_6510.vhd` and `C64_MiSTer/rtl/scpu_async_bridge.vhd` — ensure both CPU paths use the same request/grant interface.
- New SDC constraints for the grant signal.

**Risk register:**
- *Risk C.1 — VIC accuracy regression.* The fixed wheel currently guarantees VIC's slots arrive at exact dot-clock cycles. Decoupling means VIC's grant must take strict priority. **Mitigation:** preserve the existing VIC slot gating verbatim; only the CPU slots become opportunistic.
- *Risk C.2 — 6510 mode compatibility.* The 6510 (T65) wrapper expects its `enable` pulse at C64-canonical 1 MHz cadence when turbo is off. New arbiter must preserve that exact behavior for SCPU=Off / Turbo=Off paths. **Mitigation:** 6510 path keeps the old fixed-wheel cpu_cyc; only SCPU goes opportunistic.
- *Risk C.3 — Resource budget overrun.* Combined with B's bridge + A's controller, total fork may push past 75%. **Mitigation:** drop debug overlay (saves ~3000 ALMs) — restore only for debug builds.

**Validation:**
- HW Doom loop: target ≥1.5× over Milestone B → ~20-24 MHz.
- HW Wolf3D + Doom + Lorenz regressions all clean.
- 6510 mode (turbo Off, SCPU Off) — verify VICE-comparable cycle timing for at least one demo (e.g., Comaland intro or other timing-sensitive demo).
- C64 KERNAL boot to READY prompt — non-negotiable.

**Exit / pivot:**
- **PASS:** ≥20 MHz with all regressions clean → ship as v1.0 of fast SCPU.
- **WEDGE:** fall back to Milestone B baseline (~12-16 MHz). That's already ~3× current — still a win.

---

## Decisions open before starting

1. **Start with Milestone A's Step 6 plumbing or Build C revival first?** Step 6 alone gives no speedup on Build B (verified earlier in this conversation) but is risk-free. Build C revival is where the speedup actually lives but carries the wedge history. Recommendation: Step 6 first as scaffolding (1-3 days), then Build C on top.

2. **Branch strategy?** Currently on `async-cpu-bridge`. Options: (a) keep one branch, sequence the milestones, (b) one branch per milestone, merge as each passes. Recommendation: (b) — easier to roll back if a milestone wedges.

3. **SDRAM frequency?** Default 64 MHz works for all milestones. 100 MHz is a possible boost layered on Milestone B but adds PLL/SI risk. Recommendation: defer 100 MHz; revisit only if Milestone C falls short.

4. **Resource budget contingency?** If we hit ALM limits at Milestone B or C, what gets cut first? Suggested priority: drop debug overlay → drop cache → drop debug UART → reduce REU/SuperRAM. Confirm before we get there.

5. **Pivot threshold?** At what point do we cut losses if a milestone wedges? Recommendation: 2 weeks per milestone before reassessment; 4 weeks per milestone as hard pivot trigger.

## Out of scope

- VICE timing parity (separate effort, would require cycle-exact emulation rather than dispatch rate).
- New SuperCPU registers ($D07A/$D07B speed readback) — separate item per memory `project_scpu_register_implementation_status.md`.
- 100 MHz SDRAM — deferred per Decision #3.
- Cache rework — explicitly excluded; the D4.2 cache wedge is its own separate problem space and re-introducing the cache here would compound risk.
