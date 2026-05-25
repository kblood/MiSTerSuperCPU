# Milestone C — Demand-Driven CPU Arbiter Design

*Status: design sketch + GHDL stub. No master-RTL edits yet.*
*Companion bench: `sim/arbiter_demand_tb/`.*
*Per `docs/path_to_20mhz_plan.md` lines 80-105.*

## Context

Today's CPU dispatch in `fpga64_sid_iec.vhd` is **wheel-driven**: a 32-state
`sysCycleDef` FSM (clk32) tells the CPU exactly when its window opens
(`CYCLE_CPU0`, `CYCLE_CPU4`, `CYCLE_CPU8`, `CYCLE_CPUC` at turbo, plus
`alt_fire_r` slots at CPU{2,6,A,E}). The CPU has no say — when its slot
arrives, it goes; when it does not, it stalls regardless of whether SDRAM
is idle.

Milestone C inverts the CPU side of that contract: **CPU asks, arbiter
grants**. VIC and DMA remain wheel-driven (they MUST stay dot-clock-locked
for VIC accuracy and DRAM-refresh-equivalent for DMA), but CPU's
`cpu_grant` becomes a function of "do you (CPU) want it?" AND "is SDRAM
free?" AND "is no higher-priority master taking the bus?".

This file is the **architecture sketch**. It is what an implementer should
read before opening a session that touches
`fpga64_sid_iec.vhd:2697-2702` (the current `cpu_cyc` expression) and the
surrounding logic.

---

## Section A — Current wheel architecture

### A.1 The 32-cycle wheel

```
clk32: 32 cycles per 1 MHz period (32 MHz / 32 = 1 MHz dot-clock equiv)

 sysCycle index   0  1  2  3 | 4  5  6  7 | 8  9 10 11 |12 13 14 15
 phase            EXT0  ..  EXT3 DMA0  .. DMA3 EXT4  .. EXT7 VIC0 .. VIC3
 owner           cart/REU       REU DMA          cart/REU      VIC fetch

 sysCycle index  16 17 18 19 |20 21 22 23 |24 25 26 27 |28 29 30 31
 phase           CPU0 1  2  3 CPU4 5  6  7 CPU8 9  A  B CPUC D  E  F
 owner           CPU   (alt)  CPU   (alt)  CPU   (alt)  CPU+IO (alt)
```

(Source: `fpga64_sid_iec.vhd:684-693`, the `sysCycleDef` type.)

### A.2 Where CPU is gated today

The single current `cpu_cyc` expression — `fpga64_sid_iec.vhd:2697-2702`:

```vhdl
cpu_cyc <= '1' when (sdram_busy = '0' and (
            (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1' ) or
            (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1' ) or
            (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1' ) or
            (sysCycle = CYCLE_CPUC and (io_enable = '1'  or cs_ram = '1'))
        )) or alt_fire_r = '1' else '0';
```

Note four things:

1. **Wheel-driven**: `sysCycle = CYCLE_CPUx` literals dominate the
   expression. CPU's "request" (cs_ram, io_enable) is anded into the
   wheel positions, not the other way around.
2. **`sdram_busy` is already a real-world demand gate** — a local 3-bit
   countdown started on each fire, blocking new fires until SDRAM
   completes. This is exactly the kind of signal the new arbiter will
   key on.
3. **`alt_fire_r`** (`:2731-2743`) is a one-clk32-ahead latched grant for
   the SCPU SuperRAM fast-path. Memory `project_alt_fire_r_dead_on_buildB_2026_05_23.md`
   confirmed Build B never benefits from it (0% delta) — the wheel's
   CPU0/4/8/C cadence already saturates the 8-clk64 SDRAM cycle. The
   alt-slot signal is preserved for Build C revival.
4. **VIC fixed slot**: `ramCE <= cs_ram when sysCycle = CYCLE_VIC0 or
   cpu_cyc = '1' else '0';` (`:2670`). VIC ownership of `CYCLE_VIC0` is
   coded outside the `cpu_cyc` expression — these two clauses run in
   parallel on the same `ramCE` line.

### A.3 enableCpu chain (consumer side)

```
cpu_cyc (combinational, line 2697)
  -> cpu_cyc_s shift register (1-clk32 delay, line 2745)
     -> enableCpu (line 2746)
        -> enableCpu_6510 = enableCpu AND NOT dma_active AND NOT supercpu_en
        -> enableCpu_816  = enableCpu AND NOT dma_active AND     supercpu_en
            -> T65.Enable (cpu_6510.vhd:71)
            -> P65C816.Enable (cpu_65c816.vhd via cpu_65c816_inst)
```

The `enable` input on both CPU cores is a *one-clk32 pulse*. T65 advances
exactly one cycle of its internal state per pulse. P65C816 is the same
(via the cpu_65c816 wrapper). Cadence in 6510 mode = 1 MHz = one pulse
per 32-clk32 wheel rotation.

---

## Section B — Proposed demand-driven arbiter

### B.1 New entity (sketch)

```vhdl
entity bus_arbiter_demand is
port (
    clk         : in  std_logic;             -- clk32 (clk_sys)
    reset       : in  std_logic;

    -- Wheel inputs (computed from sysCycle in fpga64_sid_iec.vhd)
    vic_active  : in  std_logic;             -- '1' during VIC slot (CYCLE_VIC0)
    dma_active  : in  std_logic;             -- '1' while DMA/REU owns bus
    sdram_busy  : in  std_logic;             -- '1' while SDRAM controller busy

    -- CPU side
    cpu_req     : in  std_logic;             -- CPU has work to do
    cpu_grant   : out std_logic              -- one-cycle grant pulse for CPU
);
end entity;
```

### B.2 Grant equation

```
cpu_grant = cpu_req
         AND NOT vic_active
         AND NOT dma_active
         AND NOT sdram_busy
```

Priority: **VIC > DMA > CPU**. The arbiter never pre-empts a VIC or
DMA slot. If multiple masters request simultaneously, VIC wins by
construction (its slot is fixed in the wheel; CPU just sees
`vic_active='1'` and stays off). DMA likewise wins over CPU because
`dma_active` masks the grant.

### B.3 What `cpu_req` is driven by

In SCPU mode: `cpu_req <= (vpa_816 OR vda_816) AND NOT cpu_rdy_stalled`.
The CPU asserts vpa/vda whenever it has a valid bus address; the bridge
already converts this into a request. So `cpu_req` is essentially "the
P65C816 wants the bus".

In 6510 mode (this design preserves wheel behavior — see Section C):
`cpu_req` is irrelevant because the mux below picks the old wheel-driven
`cpu_cyc`.

### B.4 Multi-cycle grants

Today's `cpu_cyc` is one clk32 wide per slot. The new arbiter's
`cpu_grant` is **also one clk32 wide** per grant. If the CPU has a
multi-cycle access (e.g. P65C816 long bank crossing), it re-asserts
`cpu_req` and re-races for the next free cycle. This matches the bridge
FSM's per-access toggle pattern (`cpu_req_toggle_reg` in
`scpu_async_bridge.vhd:158`) and means no internal grant-extension state
is needed for correctness.

### B.5 Architectural diagram

```
                wheel-driven (preserved)
        +--------------------+
sysCycle ->| sysCycle decoder | -> vic_active   -+
        +--------------------+                    \
                                                   \   priority
        +--------------------+                      \   logic
DMA req ->|  DMA arbiter      | -> dma_active   -----+--> grant_eq
        +--------------------+                      /
                                                   /
        +--------------------+                    /
SDRAM    | sdram busy ctr   | -> sdram_busy   --+
        +--------------------+                  /
                                               /
        +--------------------+                /
P65C816  | bridge / vpa,vda  | -> cpu_req  --+        ----> cpu_grant
        +--------------------+                                |
                                                              v
                                                  cpu_enable / bridge.strobe
```

---

## Section C — 6510 mode compatibility (Risk C.2)

**Constraint:** in non-SCPU non-turbo mode, T65 must see its `Enable`
input at canonical 1 MHz cadence. T65 has no concept of "stall the
arbiter and wait for permission" — it expects exactly one pulse per
1 MHz canonical period or its internal timing (especially the
write-cycle semantics around `R_W_n` / `Sync`) breaks.

### C.1 Proposed mux

Replace `:2697-2702` with:

```vhdl
-- 6510 path: keep wheel-driven (preserves T65 cadence + bit-exact
-- compatibility for non-SCPU builds).
cpu_cyc_wheel <= '1' when (sdram_busy = '0' and (
            (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1') or
            (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1') or
            (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1') or
            (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1'))
        )) else '0';

-- SCPU path: demand-driven via new arbiter instance.
arbiter_inst: entity work.bus_arbiter_demand
port map (
    clk        => clk32,
    reset      => reset,
    vic_active => vic_slot_active,    -- '1' when sysCycle = CYCLE_VIC0
    dma_active => dma_active,
    sdram_busy => sdram_busy,
    cpu_req    => scpu_bus_req,       -- vpa OR vda from P65C816
    cpu_grant  => cpu_grant_scpu
);

cpu_cyc <= cpu_grant_scpu when supercpu_en = '1' else cpu_cyc_wheel;
```

`supercpu_en` is the existing runtime select bit. When SCPU is off, the
wheel rules unchanged; when SCPU is on, the demand-driven arbiter rules.

### C.2 Where this mux lives

`fpga64_sid_iec.vhd:2697-2702` — the existing `cpu_cyc` assignment is
**replaced** by the mux above. Estimated diff: -6 lines / +20 lines for
the mux + arbiter instantiation. The arbiter entity body lives in a new
file `C64_MiSTer/rtl/bus_arbiter_demand.vhd` (NOT created in this
sketch; the implementation session will add it).

### C.3 6510-turbo compatibility

When SCPU is off but 6510 turbo is on (`turbo_m(0|1|2)='1'`), the wheel
path still rules (per the mux above). This matches today's behavior —
no regression risk in non-SCPU configurations.

---

## Section D — VIC accuracy preservation (Risk C.1)

VIC must keep its dot-clock-locked slot at `CYCLE_VIC0`. The new arbiter
must NEVER grant the CPU during a VIC fetch. Two mechanisms enforce
this:

### D.1 vic_active sourcing

```vhdl
vic_slot_active <= '1' when sysCycle = CYCLE_VIC0 else '0';
```

Driven directly off the wheel — same source as today's
`ramCE <= cs_ram when sysCycle = CYCLE_VIC0 or cpu_cyc = '1'` clause
(`:2670`). VIC slot bound = wheel bound. The mux at the consumer
(`ramCE`) is unchanged; both clauses still feed it in parallel, but the
CPU branch is now `cpu_grant_scpu` (or `cpu_cyc_wheel` in 6510 mode).

### D.2 Sample window

The arbiter samples `cpu_req` combinationally and produces `cpu_grant`
combinationally. There is **no race** with VIC because `vic_active`
goes high on the same clk32 edge that brings `sysCycle = CYCLE_VIC0`,
and the grant equation includes `NOT vic_active`. CPU cannot win a
cycle that VIC owns.

### D.3 Bad-line emulation

The existing `rdy => baLoc` wiring on both CPU cores (`:2602, :2623`)
gives VIC the ability to stall the CPU mid-cycle during badlines. This
is orthogonal to the arbiter and is preserved. Software running in SCPU
mode still sees the bad-line stall, matching CMD SuperCPU "1 MHz badline"
behavior (per `:2585-2589` comments).

---

## Section E — Bridge interaction (Milestone B coupling)

Milestone B's `scpu_async_bridge.vhd` exposes a `bus_request_strobe_in`
port (`:102`) that is fired by the arbiter to prefetch the next read.
Today this is wired to `cpu_cyc` (per plan §B). Under the new arbiter:

```vhdl
-- Replaces today's cpu_cyc -> bus_request_strobe_in wiring.
bridge_inst: entity work.scpu_async_bridge
port map (
    ...
    bus_request_strobe_in => cpu_grant_scpu,
    bus_ack_pulse_in      => enableCpu_816,   -- unchanged
    ...
);
```

This is the key new wire: the bridge sees `cpu_grant_scpu` rise the
moment SDRAM is free AND VIC/DMA aren't busy AND the CPU is asking. The
bridge's prefetch toggle fires immediately rather than waiting for the
next wheel slot. **This is where Milestone C's win comes from** — the
SDRAM-free-window detection becomes immediate instead of quantized to
the CPU0/4/8/C cadence.

The `bus_ack_pulse_in` (= `enableCpu_816`) is unchanged because that's
the latch-edge for the CPU's data path; the arbiter doesn't replace it,
it just relaxes the upstream timing constraint.

---

## Section F — C-without-B speculation (1 paragraph)

The shipped baseline (memory `project_passthrough_plus_gates_baseline_2026_05_25.md`)
runs at clk_cpu = clk_sys = 32 MHz with the bridge in passthrough.
Effective CPU rate is ~3 MHz (limited by the 32-clk32 wheel rotation
giving 4 dispatch slots = 4 MHz peak, derated by SDRAM busy +
non-cs_ram cycles + DMA). If C is layered on this baseline (without B's
clk_cpu = 64 MHz), the new arbiter can fire on **every clk32 where
SDRAM is free**, not just CPU0/4/8/C. That's potentially 24 of the 32
slots (the 8 used by VIC + DMA are still off-limits, but the 8 EXT
slots and the 8 alt-CPU slots become available). At a sustained
8 clk64 / 4 clk32 SDRAM cycle, the arbiter can issue one access every
4 clk32 max — which is exactly today's CPU0→CPU4 cadence. **So C
without B should give roughly the same throughput as today (~3 MHz)
for memory-bound code**, with marginal improvement on I/O-heavy code
that can use the EXT slots when DMA is idle. **Conclusion: C-alone is
NOT worth pursuing as an independent track.** It only delivers
meaningful win once B drops the SDRAM cycle (or lifts clk_cpu so the
CPU can issue more requests per clk32 wheel rotation). C should wait
for B.

---

## Section G — Validation plan

### G.1 Local GHDL bench (this sketch)

`sim/arbiter_demand_tb/arbiter_demand_tb.vhd` validates the
combinational priority logic in isolation. Checks:

| # | Scenario                                              | Expected         |
|---|-------------------------------------------------------|------------------|
| 1 | Idle: nothing active                                  | grant = 0        |
| 2 | CPU req alone                                         | grant = 1        |
| 3 | CPU req + VIC active                                  | grant = 0        |
| 4 | CPU req + DMA active                                  | grant = 0        |
| 5 | CPU req + SDRAM busy                                  | grant = 0        |
| 6 | CPU req, blocker drops -> grant rises next sample     | grant = 1        |
| 7 | All blockers simultaneously                           | grant = 0        |

### G.2 Integration GHDL bench (future, NOT in this sketch)

Add a new harness `sim/arbiter_integ_tb/` that instantiates:
- The new `bus_arbiter_demand`.
- The real `scpu_async_bridge` (passthrough mode + MCP mode).
- The real `cpu_65c816` (driving cpu_req via vpa/vda).
- A behavioral SDRAM model with the bank $00 2-stage / SuperRAM
  3-stage latency split.

Drive a 100-instruction P65C816 program (mix of bank $00 + SuperRAM
accesses, some long bank crosses, an REU-DMA window inserted to verify
DMA pre-emption). Verify:

1. Instruction count completes in ≤ N clk32 (vs the wheel-only baseline).
2. VIC slot at CYCLE_VIC0 is never overlapped by `cpu_grant`.
3. During DMA window, `cpu_grant=0` for the full DMA duration.
4. After DMA window, CPU resumes within 1 clk32.

### G.3 Hardware regression (post-implementation)

Per plan §C validation:
- Doom loop: target ≥1.5× over Milestone B (~20-24 MHz).
- Wolf3D + Lorenz regressions clean.
- 6510 mode timing-sensitive demo (e.g. Comaland intro) — verify cycle
  parity vs VICE.
- KERNAL boot to READY in both 6510 and SCPU modes.

---

## Section H — Exit criteria for RTL implementation session

Before opening a session that touches `fpga64_sid_iec.vhd`, confirm:

1. ✅ **Milestone B is stable on master** — the bridge MCP path closes
   STA at clk_cpu=64MHz AND boots KERNAL AND completes Lorenz at SCPU
   mode. Per Section F, C-without-B is not worth shipping; if B is not
   stable, defer C.
2. ✅ **GHDL stub at `sim/arbiter_demand_tb/` PASSES.** Confirms the
   priority logic is bug-free in isolation.
3. ✅ **Integration bench (G.2) drafted and PASSING** in passthrough
   mode (bridge inactive). MCP-mode passing is a nice-to-have but not
   strictly required — the MCP path can be tested separately on HW
   after the arbiter change lands.
4. ✅ **Resource budget verified** — current build at ~72% ALMs. The
   arbiter itself is <50 ALMs (combinational), but the diff in
   `fpga64_sid_iec.vhd` removes wheel-side terms only when SCPU is on,
   so wheel logic stays present. Estimate: net +~80 ALMs.
5. ✅ **Rollback path documented** — the mux at C.2 means a one-line
   revert (`cpu_cyc <= cpu_cyc_wheel`) restores wheel-driven dispatch
   entirely. No FSM state to migrate.
6. ✅ **SDC clock-groups reviewed** — the arbiter is single-clock
   (clk32), no new CDC. But if Milestone B is active, ensure the
   bridge's `bus_request_strobe_in` -> bridge.req_toggle_reg path is
   in a clock-group constraint that matches the existing
   `cpu_cyc -> bus_request_strobe_in` path.

When all six are checked: open the implementation session, create
`C64_MiSTer/rtl/bus_arbiter_demand.vhd`, edit
`fpga64_sid_iec.vhd:2697-2702`, run incremental Quartus, smoke-test
on `/media/fat/_Test/C64.rbf`.

---

## Appendix — Files referenced

| Path                                              | What                                        |
|---------------------------------------------------|---------------------------------------------|
| `C64_MiSTer/rtl/fpga64_sid_iec.vhd:684-693`       | sysCycleDef wheel                           |
| `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2697-2702`     | current `cpu_cyc` expression                |
| `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2725-2729`     | sdram_busy_cnt countdown (reused as-is)     |
| `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2731-2743`     | alt_fire_r (preserved, dead on Build B)     |
| `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2745-2747`     | cpu_cyc -> enableCpu pipeline               |
| `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2591-2592`     | enableCpu_6510 / enableCpu_816 split        |
| `C64_MiSTer/rtl/cpu_6510.vhd:25-49`               | T65 enable / cadence expectation            |
| `C64_MiSTer/rtl/scpu_async_bridge.vhd:102`        | bus_request_strobe_in (prefetch port)       |
| `docs/path_to_20mhz_plan.md:80-105`               | Milestone C plan-of-record                  |
| `sim/arbiter_demand_tb/`                          | this sketch's GHDL bench                    |
