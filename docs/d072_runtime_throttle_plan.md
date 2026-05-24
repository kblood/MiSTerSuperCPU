# $D072 / $D07A runtime throttle plan — unblock IEC LOAD on v6

## Problem statement

v6 (commit `30b7dde`) runs the SCPU at clk_cpu=64MHz → ~3MHz effective
CPU rate after MCP-handshake overhead. The SCPU speed-control registers
`$D072/$D073` (system 1MHz on/off) and `$D07A/$D07B` (software 1MHz / turbo)
are decoded (`fpga64_sid_iec.vhd:2156-2175`) but only used as read-back
data for `$D0B8` status (`fpga64_sid_iec.vhd:1677-1687`). They do NOT
throttle the CPU.

Concrete consequence: `LOAD"*",8,1` hangs at `PC=$00:EEAF` (KERNAL IEC
byte receive inner loop). KERNAL's bit-shift code assumes 1MHz CPU
timing for CIA2 polling; at ~3MHz it loses byte framing. Stock
SuperCPU avoids this by engaging `$D072` before disk operations — our
bridge ignores `$D072`, so IEC LOAD is broken and **Lorenz regression
cannot run on v6**. Hard merge blocker.

## Proposed fix

`scpu_async_bridge.vhd:501-505` already has two enable paths:

```vhdl
cpu_enable_out <= '0' when EFF_BRIDGE_ACTIVE = '1'
                      and cpu_fsm = CPU_IDLE
                      and (cpu_vpa_in = '1' or cpu_vda_in = '1')
                 else cpu_enable_reg when EFF_BRIDGE_ACTIVE = '1'
                 else bus_ack_pulse_in;
```

- **MCP path** (`EFF_BRIDGE_ACTIVE='1'`): `cpu_enable_reg` from the
  FSM fires on each WAIT_ACK→LATCH transition → CPU advances per bus
  round-trip (~3MHz effective on v6).
- **Passthrough path** (`else`): `cpu_enable_out = bus_ack_pulse_in`
  (= `enableCpu_816`, the clk32-domain arbiter slot) → CPU advances
  at arbiter rate (= 1MHz).

`bus_ack_pulse_in` already lives in clk_sys but is wired to a process
inside the bridge that synchronizes it to clk_cpu (see `bus_ack_sync_*`
chain in the bridge). So we can reuse that synchronized version as a
throttle gate.

### Minimum viable change

Add an input port `force_1mhz_in` (asserted when `scpu_speed_1mhz='1'
OR scpu_sys_1mhz='1'`) and AND the MCP-path enable with the synchronized
arbiter pulse when it's high:

```vhdl
-- (a) Bridge entity gains: force_1mhz_in : in std_logic;
-- (b) Bridge architecture gains a synchronized arbiter pulse usable
--     in clk_cpu domain (probably already exists as bus_ack_pulse_sync
--     for the WAIT_ACK comparator; verify).

cpu_enable_out <= '0' when EFF_BRIDGE_ACTIVE = '1'
                      and cpu_fsm = CPU_IDLE
                      and (cpu_vpa_in = '1' or cpu_vda_in = '1')
                 else (cpu_enable_reg and bus_ack_pulse_sync)
                      when EFF_BRIDGE_ACTIVE = '1' and force_1mhz_in = '1'
                 else cpu_enable_reg when EFF_BRIDGE_ACTIVE = '1'
                 else bus_ack_pulse_in;
```

In `fpga64_sid_iec.vhd:2755`:
```vhdl
force_1mhz_in => scpu_speed_1mhz or scpu_sys_1mhz,
```

`scpu_speed_1mhz` and `scpu_sys_1mhz` live in clk32 domain. Need a
2-FF sync into clk_cpu inside the bridge.

### Why not just switch EFF_BRIDGE_ACTIVE at runtime

Switching the data path mid-flight risks coherency hazards: the MCP
FSM holds `bus_di_capture_reg` and `cpu_req_*_reg` that the passthrough
path doesn't see, so a mid-request switch would leak stale data.
Throttling enable (not data) keeps the bridge structurally identical
and only changes the rate at which the CPU advances. Safer.

### Edge cases to verify before silicon

1. **Switch under live load** — write to `$D072` while CPU is mid-bus
   cycle. The throttled enable mustn't drop while CPU is sampling.
   Probably safe because cpu_enable_reg goes low between requests anyway.
2. **CIA2 reads vs writes** — KERNAL's `$DD00` reads (IEC bit-poll)
   need 1MHz timing. Confirm both directions throttle.
3. **VIC badline interaction** — `rdy = baLoc and cpu816_rdy_to_cpu`
   already handles VIC stalls. Throttling enable shouldn't disturb
   baLoc handling.
4. **Speed bench regression** — at $D07B / $D073 (turbo on, sys-1MHz off),
   `force_1mhz_in` must drop to '0' and CPU return to ~3MHz. Verify
   speed bench shows distinct counts for slow vs fast phases.

### Bench coverage needed

Extend `sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd`:
- Add a `force_1mhz` stimulus that toggles mid-run.
- Verify CPU advance rate matches RATIO during turbo phase and matches
  bus_ack_pulse_in rate during 1MHz phase.
- Verify no data corruption at the switch boundary.

## Why this isn't done in this session

The change needs:
- Bridge entity port + sync FF additions
- Bench extension to cover the new throttle path
- New silicon build (~30 min) + IEC LOAD smoke test
- Speed bench re-run to confirm distinct ratios

That's a multi-build effort. Started after-thought late in this session
would risk breaking the proven-good v6 build without time to validate.

## Files touched (anticipated)

- `C64_MiSTer/rtl/scpu_async_bridge.vhd` — add `force_1mhz_in` port,
  sync FF, AND-gate on cpu_enable_out (and possibly cpu_rdy_out for
  full 1MHz emulation).
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2755` — wire
  `force_1mhz_in => scpu_speed_1mhz or scpu_sys_1mhz` (sync FF inside
  the bridge handles CDC).
- `sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd` — bench coverage
  for throttle path.

## Success criteria

- `LOAD"*",8,1` from `lorenz_disk1.d64` completes without wedging.
- `python tools/lorenz_run.py scpu --mins 30` runs to completion with
  test progression visible.
- `scpu_speed_bench.prg` shows DIFFERENT counts for $D07A vs $D07B phases.
- v6 still boots to READY (no regression from change).
