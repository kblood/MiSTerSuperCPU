# Async-Bridge Phase F — Revised Plan (post F.1c-f wedge)

**Status:** supersedes the F.1/F.3 portions of `docs/async_bridge_mcp_handshake_plan.md` after the 2026-05-22 four-rung wedge ladder.
**Authoritative finding:** the MCP-at-matched-clocks assumption baked into the original plan is invalid. Grounded in `docs/hdl-coding-guidelines/24-cdc-multi-bit.md §2-3.3` ("MCP holds the level long enough to pass through CDC, regardless of relative clock frequency" — i.e. round-trip is non-negotiable) and `90-anti-patterns.md` entry #60 ("MCP without payload-stable hold") which is a textbook description of our wedge.

## Why the original plan failed
- Original F.1 set `clk_cpu = clk_sys = 32 MHz` and assumed the MCP would degrade to combinational passthrough. It does not. The 2FF sync chain + toggle exchange add 2-3 clk_cpu cycles of round-trip latency regardless of clock relationship (doc 24 §2).
- The C64 arbiter aligns `enableCpu_816` to the cycle SDRAM data lands combinationally on `bus_di_in` (`fpga64_sid_iec.vhd:2604, 1650`). At that edge the bridge's `bus_di_capture_reg` still holds its pre-edge value. CPU latches zero → PC=0000 forever. Four variants (F.1c gated, F.1d comb vpa, F.1e fully-comb bus, F.1f + comb rdy) all wedge identically. Evidence: `tools/phaseF_F1c_wedge_uart.txt`, RBF hashes in `docs/session_handoff.md`.
- The framework (`mister-framework-reference/30-sdram.md §4`) does not promise combinational data at the CPU enable edge — the local combinational path is a *C64 arbiter* design choice, and anything that inserts a register between SDRAM and CPU violates it.
- The mixed registered-forward / combinational-back attempt (F.1e) is itself an anti-pattern (`21-skid-buffers §7` #51): mixing registered and combinational on the same interface destroys composability without buying timing.

## Revised phase structure

### F.1' — Bridge no-op at matched clocks (replaces original F.1)
**Goal:** preserve the port-shape and MCP source so that F.3' can engage it, but keep `BRIDGE_ACTIVE='0'` permanently for `clk_cpu = clk_sys`. The bridge contributes only a rename / port-signature change at 32 MHz; the data path stays combinational through `cpuDi`.

**Concrete work:**
1. Keep the MCP FSM source in tree (preserved at commit `7f9dced`); do not delete.
2. In `fpga64_sid_iec.vhd:2681` lock `BRIDGE_ACTIVE => '0'` and add a `SAME_CLOCK_PASSTHROUGH` generic to the bridge entity, defaulting `'1'`. When `'1'`, all bus-side outputs are combinational from CPU inputs and `cpu_di_out <= bus_di_in;` is unconditional — the MCP FSM is generated but its outputs are masked. This avoids the F.1e mux hazard because there is exactly one driver of `cpu_di_out` in the synthesized variant.
3. Validate against baseline RBF (`88963b9e` if still applicable, otherwise current HEAD). Exit when Doom + Wolf3D + Lorenz regress clean. **No CDC validation in this phase** — there is no CDC to validate.

**Cost:** essentially free; the rename is for plan structure only. The MCP source is dead code at this point.

### F.2 — (unchanged) Bench upgrade for two clock domains
Still needed for any future MCP work. No revision required from the original plan.

### F.3' — Arbiter pre-fetch redesign (replaces original F.3)
**Goal:** make the bridge actually usable at `clk_cpu = clk64`. The original plan attempted this by changing the bridge alone; that cannot work because the arbiter still aligns `enableCpu_816` to combinational data arrival — when the MCP sits in front, the destination capture latches *after* the enable edge, and the CPU misses by 2-3 clk_cpu cycles.

**The fix is arbiter-side, not bridge-side:** add a request-issue advance, so the bridge starts its MCP round-trip 2-3 clk_cpu cycles *before* the planned `enableCpu_816` edge.

**Concrete work:**
1. In `fpga64_sid_iec.vhd:2740-2826`, derive a new signal `cpu_prefetch_window` that fires at `cpu_cyc_s(0)` (one clk_sys earlier than the current `enableCpu` registered at `cpu_cyc_s(1)`). Expose it on the bridge port as `bus_request_strobe_in`.
2. Bridge source-side FSM uses `bus_request_strobe_in` (not `vpa or vda`) to flip `cpu_req_toggle_reg`. Payload registers (addr/do/we/vpa/vda) latch on the same edge — which is the source-side latch-before-toggle pattern from doc 24 §3.3 (also matches anti-pattern #60's "hold from before the load-toggle until after the return-toggle settles" rule).
3. Sink-side fires the ack-toggle on `enableCpu_816` as before. By that edge, the source-issued payload has had ~2 clk_cpu cycles to settle through the sink's 2FF, and the destination's `bus_di_capture_reg` has captured the combinational `bus_di_in` value. Source's `bus_di_capture_reg` then reloads from sink within 2-3 more clk_cpu cycles — which is fine because the CPU does not advance again until the next `enableCpu_816`.
4. SDC: add `set_max_delay`/`set_min_delay` constraints across the toggle signals per doc 24 §6, plus the clock-groups from the original Phase F.3 plan.

**Risk:** the prefetch window means the arbiter speculatively issues a CPU bus access one slot earlier than the CPU actually advances. If the slot's address changes between request and accept (e.g. DMA preempts mid-request), the access must be cancelled. Mitigation: add a `bus_request_cancel` line driven by `dma_active` or VIC bus-take; the bridge drops the pending toggle and re-issues on the next clean window. This is the FSM-level equivalent of `cpu_request_pending` in the existing MCP source.

**Alternative (cheaper but lower ceiling) — Path C from session handoff:**
Skip F.3' entirely. Revive `alt-slot` arbiter scaffolding from `project_step2_alt_slot_wedges_doom.md` with the busy-counter gate. This stays at `clk_cpu = clk_sys = 32 MHz` but reclaims EXT slots for the CPU, raising effective dispatch rate from 4 MHz toward ~6-8 MHz without any CDC. Pros: no MCP risk, no SDC churn. Cons: ceiling is below what clk_cpu=clk64 would offer.

**Decision point #2 (new):** which of F.3'-prefetch vs Path-C-alt-slot to pursue first. Default: Path C alt-slot first because (a) it builds on existing in-tree scaffolding, (b) it avoids the synthesis-hazard class that bit D4.2 and the F.1 ladder, (c) if it tops out below user expectations, F.3'-prefetch remains as the next step. The MCP source preserved at F.1' is unaffected by deferring F.3'.

### F.4 — Performance validation (unchanged from original)
Same Doom / Wolf3D / Lorenz suite; targets adjust to whichever of F.3' / Path C is chosen.

### F.5 — Optional cache re-enable (unchanged from original)
Still gated on having a single-driver `cpu_di_out` path. F.1' satisfies that.

## Tree implications
- `BRIDGE_ACTIVE='0'` is the steady state at HEAD. Don't try to flip it to `'1'` again until either F.3' arbiter prefetch is wired up, OR clk_cpu actually differs from clk_sys.
- `SAME_CLOCK_PASSTHROUGH` generic is the lock against accidentally re-engaging the MCP at matched clocks during refactor.
- Phase F plan original (`async_bridge_mcp_handshake_plan.md`) stays in tree for context. This file is the supersession marker.

## Open questions for the user
1. Pursue **Path C alt-slot** first (32 MHz, no CDC) or **F.3' arbiter prefetch** (clk64, with CDC redesign)? Default suggested: Path C first.
2. If Path C: revive busy-counter scaffolding from `project_step2_alt_slot_wedges_doom.md` and address the synthesis hazard there?
3. If F.3' prefetch: is one-slot prefetch enough, or should we measure round-trip and size the prefetch window from the SDC report?
