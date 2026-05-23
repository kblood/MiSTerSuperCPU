# F.3' arbiter prefetch — design sketch (2026-05-23)

**Status:** sketch / pre-implementation. Sits between
`async_bridge_phase_f_revised.md §F.3'` (the high-level decision)
and the actual bridge rewrite. No code lands until the user weighs
in on the open questions at the tail.

**Premise:** at `clk_cpu = clk64 = 64 MHz` and `clk_sys = clk32 = 32
MHz` (2:1 ratio), the arbiter must issue the CPU's bus request
2-3 clk_sys *before* the planned `enableCpu_816` edge so the
MCP-handshake round-trip completes by the time the CPU is allowed
to advance. This sketch decides where the prefetch strobe is
tapped, how the bridge consumes it, and how preemption (DMA / VIC
bus-take) cancels a pending prefetch.

## 1. Latency budget at 2:1 clock ratio

Round-trip from prefetch-strobe to CPU's read-data being valid:

| step | event | latency from strobe |
|---|---|---|
| 0 | arbiter raises `bus_request_strobe_in` (clk_sys T) | T |
| 1 | bridge source-side 2-FF sync into clk_cpu | T + 1-2 clk_cpu |
| 2 | bridge latches payload + flips `cpu_req_toggle_reg` | T + ~2 clk_cpu = T + 1 clk_sys |
| 3 | toggle propagates source→sink via clk_sys 2-FF | T + 3 clk_sys |
| 4 | sink fires `bus_ack_toggle_reg` on `enableCpu_816` | T + (variable, 1-32 clk_sys; typ. 2-8) |
| 5 | ack propagates sink→source via clk_cpu 2-FF | step 4 + 2 clk_cpu |
| 6 | source captures `bus_di_capture_reg` on ack edge | step 5 + 1 clk_cpu |
| 7 | CPU latches `cpu_di_out` on next clk_cpu rising | step 6 + 1 clk_cpu |

**Worst-case combined steps 1-3:** ~3 clk_sys. So the strobe needs
to fire ≥3 clk_sys before `enableCpu_816` if we want zero stall.

## 2. Strobe source — `cpu_cyc` is the natural candidate

```
fpga64_sid_iec.vhd:2782-2787 (Build B HEAD, 2026-05-23):
cpu_cyc <= '1' when (sdram_busy = '0' and (
                (sysCycle = CYCLE_CPU0 and turbo_m(0) and cs_ram) or
                (sysCycle = CYCLE_CPU4 and turbo_m(1) and cs_ram) or
                (sysCycle = CYCLE_CPU8 and turbo_m(2) and cs_ram) or
                (sysCycle = CYCLE_CPUC and (io_enable or cs_ram))
            )) or alt_fire_r or alt_fire_r2 else '0';

cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc;
enableCpu <= cpu_cyc_s(1);
```

`cpu_cyc` is combinational on `sysCycle` (one-hot CYCLE_* tags) +
`sdram_busy` + `cs_ram` + turbo masks. It fires exactly 2 clk_sys
before `enableCpu`. At 2:1 clock ratio, **2 clk_sys = 4 clk_cpu of
advance** — comfortably above the 3-clk_sys latency budget when
the ack falls on the natural CPU slot.

The 2 unused alt-fire branches (`alt_fire_r`, `alt_fire_r2`) are
both gated `'0'` in current source (Build B confirmed too slow for
either); they re-engage on Build C and should keep cooperating with
the prefetch strobe automatically.

### Why not `cpu_cyc_s(0)`?
The original plan suggested `cpu_cyc_s(0)`. That's only 1 clk_sys
ahead of `enableCpu` = 2 clk_cpu margin. Too tight: the bridge's
own clk_sys→clk_cpu sync chain on the strobe input alone is 1-2
clk_cpu, leaving zero margin for the round-trip.

### Why not register `cpu_cyc` into clk_cpu directly?
The "obvious" cleanup — register `cpu_cyc_cpu_r` on clk_cpu in the
arbiter itself — re-introduces a clk_sys→clk_cpu CDC at exactly
the point the plan wants to consolidate at. Keep CDC inside the
bridge entity where it belongs (doc 24 §3.2).

## 3. Cancel path — DMA preemption

The risk per revised plan §F.3' Risk B.4: REU DMA starts mid-
prefetch. The CPU's planned access must be dropped and re-issued.

Current arbiter signals:
- `dma_active` (line 2881-ish): set at CYCLE_EXT1/EXT5 from
  `dma_req`. Registered; visible 1-2 clk_sys before the DMA
  starts contending for SDRAM.
- VIC bus-take: implicit in `baLoc` going low during VIC badline
  fetches. Already gates `cpu_rdy_out` per commit 80dc8d7.

**Proposal:** combinationally derive
`bus_request_cancel <= dma_active or not baLoc`. Bridge ANDs
this with its accept-toggle: if the source-side FSM is in
`CPU_REQUEST` state and `cancel` is asserted, drop the toggle
(roll back `cpu_req_toggle_reg`) and return to `CPU_IDLE`. The
CPU sees `cpu_rdy_reg` stay '0' until the cancel clears, then
re-issues on the next `bus_request_strobe_in` edge.

Risk: rolling back a registered toggle is non-trivial if the
source-side has already presented it to the sink-side sync chain.
Safer alternative: don't roll back; let the sink-side ack the
toggle as normal but ignore the payload (since cancel was
asserted by the arbiter, the sink's `bus_ack_pulse_in` will not
fire during DMA, so the bridge just stalls until DMA clears and
the original request resumes). **Recommendation: do nothing on
the bridge side; let the existing baLoc / DMA gating of
`enableCpu_816` naturally hold the ack until safe.** The CPU is
stalled (`cpu_rdy_reg='0'`) the whole time anyway.

## 4. Port signature change at the bridge

Current bridge entity ports (after rename in commit at line 2727
of fpga64_sid_iec.vhd):

```vhdl
bus_addr_out, bus_addr_hi_out, bus_do_out, bus_we_out,
bus_vpa_out, bus_vda_out : out  -- payload outputs (unchanged)
bus_di_in                : in unsigned(7..0)
bus_ack_pulse_in         : in std_logic   -- = enableCpu_816 (unchanged)
```

For F.3' add one port and one generic:

```vhdl
generic (
    BRIDGE_ACTIVE          : std_logic := '0';
    CACHE_ACTIVE           : std_logic := '0';
    SAME_CLOCK_PASSTHROUGH : std_logic := '1';  -- NEW, default '1'
);
port (
    ...
    bus_request_strobe_in  : in std_logic;       -- NEW
);
```

Instantiation in fpga64_sid_iec.vhd:

```vhdl
SAME_CLOCK_PASSTHROUGH => '1',  -- F.3' will flip to '0' when clk64 active
bus_request_strobe_in  => cpu_cyc,
```

When `SAME_CLOCK_PASSTHROUGH='1'`, bridge outputs combinational
passthrough as today; new port is unused. When `'0'`, MCP FSM
engages.

## 5. Open questions for the user

1. **Prefetch over-issue tolerance.** If the bridge issues a
   prefetch and the CPU then *doesn't* advance (because of a
   stall the bridge didn't anticipate — interrupt vector fetch,
   for instance), how should the in-flight toggle be reconciled?
   Default proposal: the sink-side waits for `bus_ack_pulse_in`
   regardless; the toggle just takes longer to resolve.
   **Settled 2026-05-24 by §1' below — two-stage protocol means
   we never toggle without a real CPU request, so over-issue
   simply cannot happen.**

2. **Bench upgrade scope (F.2).** Two-domain GHDL bench is a hard
   requirement before F.3' lands. Should the bench bring up
   `clk_cpu=clk_sys*2` or do we go straight to `clk_cpu=64MHz`
   constants? **Settled F.2 (commit ac7caf1): parametric RATIO
   generic, validated 1/2/3 × PASSTHROUGH 0/1.**

3. **Build C revival timing.** Step 5/7b alt-fires plus F.3'
   prefetch compose multiplicatively: alt-fires double the slot
   density, F.3' doubles the per-slot throughput. Order of
   landing: F.3' first (Milestone B), Build C after (Milestone B
   integration)?

## 1'. Source-side trigger protocol — decision (2026-05-24)

The three candidates listed in the session handoff:

- **(a) Strobe replaces vpa/vda.** Source FSM ignores vpa/vda
  for triggering; toggle fires every synced strobe edge. Payload
  (including vpa/vda) is latched at the same edge.
  *Cost:* ghost toggles when CPU has no request — burns arbiter
  slots and an MCP round-trip per strobe regardless. *Risk:*
  on writes, the sink would drive bus_we_out without a real
  request, potentially mutating arbiter state.

- **(b) Strobe is an additional gate.** Source fires only when
  `(vpa|vda) AND synced_strobe_edge` aligns on the same clk_cpu.
  *Cost:* if vpa/vda asserts immediately after strobe arrives,
  the CPU waits a full STROBE_PERIOD (~4 clk_sys = 8 clk_cpu at
  RATIO=2) for the next strobe. *Risk:* low.

- **(c) Two-stage protocol.** vpa/vda latches payload immediately
  and drops cpu_rdy (CPU stalled within 1 clk_cpu). Strobe edge
  is the second-stage trigger that flips the cross-domain toggle.
  *Cost:* one extra FSM state. *Risk:* same as (b) — worst-case
  one STROBE_PERIOD wait between request and dispatch.

**Decision: option (c).** Reasons:

1. The CPU's `rdy` semantics expect a 1-cycle response: assert
   `vpa/vda`, see `rdy=0` on the next edge, then wait for `rdy=1`
   plus valid `cpu_di`. Options (a) and (b) leave `rdy='1'` until
   the strobe fires, so the CPU continues to execute (or attempt
   to) for several clk_cpu cycles before being stalled. Option
   (c) drops `rdy` on the first cycle after `vpa/vda` rises,
   exactly matching the P65C816 protocol.
2. Option (a) toggles even with `vpa=0, vda=0` — a sink-side
   `bus_we_out` would assert as part of the latched payload. The
   arbiter would see a write request when the CPU intended none.
   Option (c) never issues a toggle without a real request.
3. The extra FSM state is one bit of register; the synthesizer
   collapses the equivalent of `(rdy_drop AND wait_strobe)` into
   a clean two-stage flow with no extra LUT depth.

**Reference plan §F.3' point 2 (`docs/async_bridge_phase_f_revised.md`)
originally proposed option (a) but the analysis above supersedes
it.** The revised plan note has been updated.

## 3.1 Back-to-back accesses + rdy semantics

After `CPU_WAIT_ACK` captures the ack, the FSM transitions to
`CPU_IDLE` and `cpu_rdy_reg` goes high — both at the same clk_cpu
edge. The CPU latches `cpu_di_out` (= captured `bus_di_reg`) on
the *following* edge. If the CPU immediately re-asserts `vpa/vda`
(common in tight loops), the next clk_cpu observes `vpa/vda=1` in
`CPU_IDLE` and transitions to `CPU_REQ_PENDING` with new payload
latched. Worst-case dead time between accesses: 1 clk_cpu for the
IDLE pass-through. Best-case strobe alignment: 0 clk_cpu wait if
strobe fires the same edge IDLE→REQ_PENDING completes; worst-case
strobe wait: STROBE_PERIOD - 1 clk_sys.

## 3.2 Bench validation summary (2026-05-24)

`sim/scpu_async_bridge_tb/run_bridge_tb.ps1` runs cleanly across
all 6 (RATIO ∈ {1,2,3}) × (PASSTHROUGH_MODE ∈ {0,1}) combinations.

| RATIO | PASSTHROUGH | scenarios | failures |
|-------|-------------|-----------|----------|
| 1 | 0 | 5/5 | 0 |
| 1 | 1 | 5/5 | 0 |
| 2 | 0 | 5/5 | 0 |
| 2 | 1 | 5/5 | 0 |
| 3 | 0 | 5/5 | 0 |
| 3 | 1 | 5/5 | 0 |

RATIO=2 PASSTHROUGH=0 is the F.3' deploy target; round-trip
observed at ~258 ns / ~8.3 clk_sys for scenario E (1-cycle ack)
— consistent with §1 latency budget plus the additional 1-stage
of REQ_PENDING and worst-case strobe wait.

## 6. Files for the F.3' implementation

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2701-2730` — bridge instance
  (add `SAME_CLOCK_PASSTHROUGH`, wire `bus_request_strobe_in`).
- `C64_MiSTer/rtl/scpu_async_bridge.vhd` — replace 67-line diag
  with hybrid passthrough + MCP. Reference: 363-line F.1 source
  at `tools/scpu_async_bridge_F1_backup.vhd`.
- `C64_MiSTer/c64.sv:328` — `clk_cpu` retarget (later in F.3').
- `C64_MiSTer/C64.sdc` — async clock-group declarations + max/min
  delay on toggle signals.
- `sim/scpu_async_bridge_tb/bridge_tb.vhd` — F.2 bench upgrade.

## 7. Pointers

- Revised plan: `docs/async_bridge_phase_f_revised.md`
- Original plan + F.0 appendix: `docs/async_bridge_mcp_handshake_plan.md`
- MCP FSM reference: `tools/scpu_async_bridge_F1_backup.vhd`
- HDL guideline: `docs/hdl-coding-guidelines/24-cdc-multi-bit.md §3.3, §4.1`
- Anti-pattern lookup: `docs/hdl-coding-guidelines/90-anti-patterns.md`
  entries 19, 24, 60
