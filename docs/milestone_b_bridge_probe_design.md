# Milestone B — Bridge-Internal UART Probe Design

Status: **design / research** (no master RTL edits, no Quartus).
Author: Milestone B sub-agent, 2026-05-25.
Sibling sim deliverable: `sim/scpu_async_bridge_tb/cpu_cia_irq_tb.vhd` + `run_cpu_cia_irq_tb.ps1`.

## 0. Why this doc exists

The MCP bridge wedges `LOAD"*",8,1` in every build despite five RTL build-test
loops and three GHDL benches all passing under MCP in sim. The current ship
baseline (`d564dea`, RBF `8a7489ef`) flips `SAME_CLOCK_PASSTHROUGH => '1'` so
the MCP path is disengaged. Milestone B's open goal is restoring
`clk_cpu = clk64` with the MCP path active, which is the only way to get the
~12–16 MHz dispatch projected in `docs/path_to_20mhz_plan.md` §B.

Five hypotheses have been falsified (see
`memory/project_option_e_three_benches_pass_mcp_2026_05_25.md`,
`memory/project_optionF_cia2_imrcra_no_phantom_2026_05_25.md`,
`memory/project_optionG_cia2_port_no_phantom_2026_05_25.md`):

1. Phantom write to CIA1 IMR/CRA (gated at cs_cia1; v13d).
2. Phantom write to CIA2 IMR/CRA (Option F — values constant).
3. Phantom write to CIA2 PRA/PRB/DDRA/DDRB (Option G — values legitimate).
4. MCP-induced spurious ICR clear-on-read (sim `cpu_cia_real_tb` PASS).
5. Passive W/R interleaving with mock 1541 (sim `cpu_cia_rw_tb` PASS).

The highest-probability **unfalsified** hypothesis is the IRQ-vector-fetch
micro-sequence racing the bridge's `bus_di_capture_reg` / `cpu_enable_out`
release. This doc:

- A. Spells out the mechanism cycle-by-cycle so the next agent can argue with
  the model instead of re-deriving it.
- B. Specifies a bridge-internal UART probe build that will either confirm or
  falsify the IRQ-race in <1 RTL build cycle.
- C. Writes the pass/fail rubric for the HW probe before we run it (so we don't
  rationalise an ambiguous result after the fact).

## A. IRQ-vector-fetch race hypothesis (detailed)

### A.1 Sequence under passthrough (baseline, works)

When a Timer A IRQ fires at clk_cpu = clk_sys = 32 MHz, passthrough:

1. CIA1 `cia_irq_n` drops on a `phi2_p` underflow tick.
2. `cia_irq_n` ANDs into the CPU's `irq_n` net combinationally.
3. P65C816 samples `irq_n` at the end of the current instruction's last cycle.
4. P65C816 enters interrupt sequence:
   - cycle 1–3: push PB / PC-hi / PC-lo / P (4 writes for native, 3 for emu).
   - cycle 4: VPB drops, fetch vector low byte at `$00FFFE` (for IRQ).
   - cycle 5: VPB still low, fetch vector high byte at `$00FFFF`.
   - cycle 6: load PC from {high,low}, begin handler fetch.
5. Each bus cycle takes exactly one `enableCpu_816` slot (the arbiter's CYCLE_CPUF).
   `cpu_di_out` mux is **direct passthrough**: `cpu_di_out <= bus_di_in` always
   (because `EFF_BRIDGE_ACTIVE = '0'`). No latency between `bus_di_in` and CPU
   sample edge — they're in the same clk_sys domain. The vector fetch reads
   the *current* `cpuDi` mux output at every CYCLE_CPUF, which always reflects
   the address the CPU has been driving on `cpuAddr` for the prior clk_sys cycle.

### A.2 Sequence under MCP (suspected race)

When clk_cpu = 64 MHz, clk_sys = 32 MHz, MCP active (`EFF_BRIDGE_ACTIVE='1'`):

1. CIA1 fires IRQ in clk_sys domain — same as passthrough.
2. `cia_irq_n` → `cpu_irq_n` crosses domains **unsynchronised** (it's an active-low
   level that the P65C816 happens to sample at the end of an instruction).
   This is **not** an MCP signal — it's the legacy direct path. The CPU
   samples it on a clk_cpu edge.
3. P65C816 enters interrupt sequence as before. Each bus cycle now goes
   through the bridge FSM (`CPU_IDLE → CPU_REQ_PENDING → CPU_WAIT_ACK →
   CPU_LATCH → CPU_IDLE`).
4. **Critical detail (lines 308–386 of `scpu_async_bridge.vhd`):** each new
   request stalls the CPU via the combinational gate at lines 502–516. The
   gate forces `rdy_out=0` and `enable_out=0` on the same clk_cpu the CPU
   asserts vpa/vda AND `cpu_fsm = CPU_IDLE`. That's the IRQ-fetch's first
   bus cycle — the gate fires.
5. After `strobe_edge` (synchronised arbiter prefetch), the FSM enters
   `CPU_WAIT_ACK`. The sink side meanwhile sees the req-toggle, waits for
   `bus_ack_pulse_in` (i.e. `enableCpu_816`), captures `bus_di_in` into
   `bus_di_reg`. Then `bus_ack_toggle_reg` flips. Sync chain (2 FFs) returns
   the ack toggle to clk_cpu. On the cycle `ack_sync2_reg == cpu_req_toggle_reg`,
   the bridge:
   - latches `bus_di_capture_reg <= bus_di_reg` (combinational `bus_di_reg`!)
   - releases `cpu_rdy_reg <= '1'`, `cpu_enable_reg <= '1'`
   - transitions FSM `WAIT_ACK → LATCH → IDLE`.
6. The CPU consumes the byte during the `CPU_LATCH` state (one clk_cpu cycle
   long).

### A.3 Where the race could land

Two distinct races to consider:

**Race α — vector second-byte aliases first-byte's stale capture.**
After cycle 4 (`$00FFFE` fetch) completes via `CPU_LATCH → CPU_IDLE`,
`bus_di_capture_reg` holds the low byte of the vector. The very next clk_cpu,
the CPU asserts vpa/vda for `$00FFFF` (cycle 5). The combinational gate
forces `rdy_out=0, enable_out=0` — but does it do so *fast enough* to
prevent the CPU from latching `cpu_di_out`'s last-cycle value into its
P-low register? The gate path is:

```
cpu_vpa_in (combinational from CPU) → cpu_rdy_out (combinational mux)
                                    → CPU's RDY_IN port
                                    → CPU's EN <= RDY_IN AND CE next clk_cpu
```

At clk_cpu = 64 MHz the setup time on RDY_IN for the *current* clk_cpu's
EN evaluation is ~6 ns. If the CPU's vpa/vda assertion and the gate's
rdy=0 collapse arrive at RDY_IN with > 6 ns combinational delay, the CPU
samples `enable=1, rdy=1, cpu_di_out=(stale low-byte)` for the high-byte
fetch — the high byte of the IRQ vector is **the low byte again**. The
ISR then jumps to `$xxxx` where xxxx has its top byte replaced. This
explains why every MCP wedge lands in a different KERNAL site: each
wedge corresponds to the IRQ that happened to fire during a different
KERNAL routine, and each ISR landed at `vector_low << 8 | vector_low`,
i.e. `$xxxx` where xxxx is whatever low-byte happened to be on the bus.

Test: probe `last_bus_di` over time during a wedged LOAD. If we see two
consecutive bytes with identical value during an IRQ window, this race
fires.

**Race β — ack_toggle mid-fetch dropped, FSM stuck in WAIT_ACK.**
The `bus_ack_pulse_in` signal is wired to `enableCpu_816` which is
`enableCpu AND NOT dma_active AND supercpu_en`. During the IRQ sequence
the CPU is doing back-to-back bus cycles with no internal cycles between.
Each one needs its own `enableCpu_816` pulse. The arbiter's CYCLE_CPUF
schedules `enableCpu` on a fixed cadence (every 32 clk_sys = 1 MHz);
turbo mode reclaims EXT slots to bump this. At 20 MHz target the arbiter
fires `enableCpu` ~every 1.5 clk_sys. The bridge needs each pulse to
fire AFTER its req-toggle crosses to clk_sys.

If two pulses fire in quick succession but the req-toggle for cycle N+1
hasn't crossed yet (sync chain takes 2 clk_sys), the sink ignores the
second pulse — `bus_request_pending_reg=0` at that moment. Then when the
toggle does cross, the next `enableCpu_816` pulse is whatever the arbiter
scheduled — possibly long after — and the bridge "loses" one slot per
back-to-back access. Over an IRQ vector fetch (5+ back-to-back bus
cycles) this could compound into multiple-clk_sys stall. Vector fetches
that should take ~7 clk_sys take 20+. The CIA's Timer A is still
underflowing on its own schedule and CIA1 IRQs can re-fire while the
ISR's first instruction is still trying to load — CPU sees back-to-back
interrupts and never advances. **Matches the HW evidence**:
v12_mcp saw CIA1 IRQ rate stay at 55–60/s during wedge.

Test: `cpu_req_count` and `cpu_ack_count` should diverge during the wedge
(req > ack). `bridge_fsm_state` should be observed stuck in WAIT_ACK
(state value `2`) at the wedge moment.

### A.4 Why the existing benches don't catch this

`cpu_cia_real_tb.vhd` runs with `SEI` set in the test program (lines
166–203 of the bench's ROM at `$0200` start with `78 SEI`). No IRQs ever
fire. Even with `mos6526_lite.vhd` modelling Timer A underflow and ICR
clear-on-read, the irq_n line on the CIA can fall — but the bench wires
`irq_n => '1'` constant at the CPU port (line 89 + 224 of
`cpu_cia_real_tb.vhd`). The CPU never takes an interrupt, never does the
vector fetch sequence, never exercises the race in §A.2 / A.3.

The new bench (`cpu_cia_irq_tb.vhd`) fixes both: drops the SEI, wires
`cia_irq_n` to `cpu.irq_n`.

## B. Bridge-internal UART probe spec

This section specifies a future RTL build (out of scope for this session) that
adds five new fields to the debug UART pool format. Implementation should be
~1 hour of RTL work: 5 new outputs from `scpu_async_bridge.vhd`, 5 ports
threaded through `fpga64_sid_iec.vhd` → `c64.sv` → `debug_uart_pool_fmt.sv`,
and 5 new ASCII fields in the UART line layout.

### B.1 Probe signals (added inside `scpu_async_bridge.vhd`)

| Signal | Width | Drives | Purpose |
|---|---|---|---|
| `dbg_fsm_state` | 4 bits | combinational from `cpu_fsm` | 0=IDLE 1=REQ_PENDING 2=WAIT_ACK 3=LATCH |
| `dbg_last_bus_di` | 8 bits | `bus_di_capture_reg` directly | Last byte the bridge handed the CPU. Race α detector. |
| `dbg_req_count` | 16 bits | Saturating counter of `cpu_req_toggle_reg` flips (IDLE→REQ_PENDING) | Race β detector (req-vs-ack divergence). |
| `dbg_ack_count` | 16 bits | Saturating counter of `WAIT_ACK→LATCH` transitions | Race β detector. |
| `dbg_irq_vec_fetch_count` | 8 bits | Saturating counter; increment when `cpu_req_addr_hi_reg = x"00"` AND `cpu_req_addr_reg(15:1) = 15'b111111111111111` (i.e. addr ∈ {`$FFFE`,`$FFFF`}) AND `cpu_we_in = '0'` AND FSM enters WAIT_ACK | Proves IRQs are actually firing during wedge. |

All five are clk_cpu domain. The UART formatter is clk_sys but the values are
"snapshot at vblank-rise" so a 2-FF sync chain on each is sufficient (the
counters are slow-changing). Existing Option F/G probes use this pattern.

### B.2 Port additions

In `scpu_async_bridge.vhd` entity, after `dbg_is_slow`:

```vhdl
dbg_fsm_state            : out unsigned(3 downto 0);
dbg_last_bus_di          : out unsigned(7 downto 0);
dbg_req_count            : out unsigned(15 downto 0);
dbg_ack_count            : out unsigned(15 downto 0);
dbg_irq_vec_fetch_count  : out unsigned(7 downto 0);
```

In `fpga64_sid_iec.vhd` add five matching signals (around line 2883 where
`cpu816_dbg_is_slow` is wired) and thread them out the entity port list
(this is the pattern used for Option F/G: see `dbg_imr_cia2` and the
follow-on `dbg_pra_cia2` etc.).

In `c64.sv`, thread the five signals into the existing
`debug_uart_pool_fmt` instantiation port list and bump `LINE_LEN` from 319 to
**357** (38 added bytes for `" FS:# DI:## RQ:#### AK:#### VF:##"` — note
spaces and newline are accounted for; see B.3 layout).

### B.3 UART line layout (proposed)

Current line ends after Option G with `... DA:## DB:##\n` (38 bytes added by
F+G combined, total LINE_LEN = 319).

Append five fields **before** the `\n`:

```
... DA:## DB:## FS:# DI:## RQ:#### AK:#### VF:##\n
```

- ` FS:#` — bridge FSM state, 1 hex char (4 bits → values 0..3 visible, 4–F unused).
- ` DI:##` — last_bus_di, 2 hex chars.
- ` RQ:####` — req count, 4 hex (wraps every 65536; the human compares vs AK).
- ` AK:####` — ack count, 4 hex.
- ` VF:##` — IRQ vector fetch count, 2 hex (wraps every 256; enough to see "this is incrementing").

Byte budget: ` FS:#`=5 + ` DI:##`=6 + ` RQ:####`=8 + ` AK:####`=8 +
` VF:##`=6 = 33 bytes added. New LINE_LEN = 319 + 33 - 1 (the \n was already
in the 319) = **352** (round up to 357 for safety; matches Option G's
allocation pattern).

In `debug_uart_pool_fmt.sv`:
- Bump `LINE_LEN` localparam.
- Add the new field clauses in the byte_idx case statement, modelled on the
  Option G entries (search for `"PA:"` in the source).

### B.4 What changes outside the formatter

No other module changes. The five signals are pure observability; they have
no functional effect. Quartus build risk: nil — the FSM signal alone uses 4
new register bits + 16 sync FFs (4 outputs × 4 FFs each per port crossed
into clk_sys). The two 16-bit counters use 32 LEs each. Total: <100 LEs.

## C. Pass/fail criteria for the HW probe

Run the probe build on hardware. Mount `lorenz_disk1.d64` via MGL and trigger
`LOAD"*",8,1` (the canonical wedger). Capture UART for ~30 s past the
"SEARCHING FOR *" message.

### C.1 Race α confirmation (vector-byte aliasing)

**Symptoms during wedge:**
- `DI` field cycles through a small set of values repeatedly.
- KERNAL wedge site decoded from `PC` matches a "bad address" pattern: PC's
  high byte equals PC's low byte (e.g. `$1212`, `$4848`, `$EEEE`). This is
  the signature of the high-byte fetch returning the low-byte's value.
- `VF` is incrementing (IRQs are firing) and `RQ`–`AK` ≤ 1 (bridge not
  stalled).

**If confirmed:** the fix is to widen the combinational `cpu_rdy_out=0` gate
to also cover one clk_cpu of *propagation delay*, e.g. register a "next
cycle is gated" flag and OR it into the gate. Specifically: when `CPU_LATCH`
transitions to `CPU_IDLE`, hold rdy=0 for one extra clk_cpu even before the
CPU asserts the next vpa/vda. That gives `bus_di_capture_reg` time to be
either updated (next IDLE→PENDING flow) or held stable (no new request).

### C.2 Race β confirmation (ack-stall accumulation)

**Symptoms during wedge:**
- `RQ` keeps growing.
- `AK` lags by >2 and the gap widens.
- `FS` reads as `2` (WAIT_ACK) for many UART samples in a row (UART
  refreshes once per vblank ≈ 20 ms — if FS=2 for 5+ samples = 100+ ms stuck
  in WAIT_ACK, that's a hard stall).
- `VF` may or may not be incrementing — if IRQs are firing but their
  vector fetches are themselves the stalled requests, VF could be growing
  in lock-step with the stall.

**If confirmed:** the fix is in the sink-side process (lines 400–420 of
`scpu_async_bridge.vhd`). Either:
- Latch `bus_request_pending_reg` immediately on req-edge AND retroactively
  on a missed `bus_ack_pulse_in` (the cycle ack pulsed while pending=0,
  remember it and replay on the next observed req-edge).
- OR widen `bus_ack_pulse_in` from a 1-cycle clk_sys pulse to a level (the
  CPU slot's full 2-clk_sys window from CYCLE_CPUF). This requires touching
  the arbiter wiring at line 2876 of `fpga64_sid_iec.vhd`.

### C.3 Both races falsified

If `DI` doesn't show aliasing AND `RQ`/`AK` track tightly AND `FS` is rarely
2 — then the IRQ-fetch race is also wrong and the next step is **not** more
sim. It is:

1. Add SignalTap on `cpu_addr` + `cpu_di` + `cpu_we` + `enable` + the
   bridge's five debug ports, capture 8192 samples at the wedge moment.
   (Per `memory/reference_signaltap_documented_not_working.md`, SignalTap
   setup is its own sub-project — budget ~1 day of fighting JTAG before any
   useful capture appears.)
2. OR — pivot to Milestone C / accept passthrough baseline per
   `docs/path_to_20mhz_plan.md` strategic option (b).

### C.4 No wedge under probe (the "Heisenberg" case)

The probe adds combinational logic on `cpu_fsm` and might marginally shift
timing. If the build doesn't wedge AT ALL (the LOAD"*",8,1 completes
cleanly) that is *information*: the wedge is timing-marginal, not
structural. The fix is timing analysis (Quartus TimeQuest report on the
bridge's failing paths) rather than more probes. This is rare and would be
a happy outcome — would let us ship the probe build with the comment "the
extra observability registers happened to fix the race."

## D. References

- Bridge source: `C64_MiSTer/rtl/scpu_async_bridge.vhd` (FSM at 308–386, gate at
  502–516, sink at 400–420).
- Bridge integration: `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2821–2884`.
- UART formatter pattern: `C64_MiSTer/rtl/debug/debug_uart_pool_fmt.sv` lines
  170–595 (Option F/G as the template).
- New sim bench: `sim/scpu_async_bridge_tb/cpu_cia_irq_tb.vhd` (sibling to
  this doc).
- Wedge history: `memory/project_passthrough_plus_gates_baseline_2026_05_25.md`,
  `memory/project_option_e_three_benches_pass_mcp_2026_05_25.md`,
  `memory/project_v12_mcp_cia1_irq_stops_2026_05_24.md`,
  `memory/project_mcp_cycle_trace_2026_05_24.md`.
- Why **not** SignalTap as first choice:
  `memory/reference_signaltap_documented_not_working.md`.
