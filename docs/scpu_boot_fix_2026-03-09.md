# SuperCPU Boot Fix - 2026-03-09

## Symptom

After reintroducing `VDA/VPA` qualification for the 65C816 bus, the core no longer
showed the earlier hard-black failure, but SuperCPU mode still produced unstable
boot/runtime behavior:

- moving repeated-character corruption on the BASIC screen
- intermittent "looks alive but wrong" READY state
- debug overlay still showed `K:F8`, meaning kickstart had completed

## Root Cause

The `scpu_bus_valid` gate was applied too broadly in
[`fpga64_sid_iec.vhd`](C:/LLM/C64/MiSTerSuperCPU/C64_MiSTer/rtl/fpga64_sid_iec.vhd).

This part was correct:

- `supercpu_cycle` should require a valid 65C816 external bus cycle
- banked SDRAM addressing should only happen for CPU-owned valid bus cycles

This part was wrong:

- `ramCE` was also gated by `scpu_bus_valid` during `CPUC`

During a badline, `cpuHasBus='0'` and the VIC owns the address bus at `CPUC` for the
screen-code c-access fetch. If the halted 65C816 happened to present `VDA=0` and
`VPA=0`, the old expression suppressed that VIC fetch entirely:

```vhdl
ramCE <= cs_ram when sysCycle = CYCLE_VIC0 or (cpu_cyc = '1' and scpu_bus_valid = '1') else '0';
```

That recreated the VIC-side corruption path: the CPU validity gate was accidentally
blocking a VIC-owned memory cycle.

## Fix

Keep `scpu_bus_valid` on CPU-owned SDRAM cycles only, and let badline `CPUC`
continue to fire when the VIC owns the bus:

```vhdl
ramCE <= cs_ram when sysCycle = CYCLE_VIC0 or
                 (cpu_cyc = '1' and (cpuHasBus = '0' or scpu_bus_valid = '1')) else '0';
```

Relevant live code:

- [fpga64_sid_iec.vhd:1152](C:/LLM/C64/MiSTerSuperCPU/C64_MiSTer/rtl/fpga64_sid_iec.vhd:1152)
- [fpga64_sid_iec.vhd:1468](C:/LLM/C64/MiSTerSuperCPU/C64_MiSTer/rtl/fpga64_sid_iec.vhd:1468)

## Why This Is The Right Boundary

- CPU phantom cycles still do not drive banked SDRAM accesses.
- CPU-owned invalid cycles still do not assert `ramCE`.
- VIC c-access at `CPUC` is no longer coupled to 65C816 `VDA/VPA`.
- `enableCpu` timing was not touched, so this does not reintroduce the earlier
  phantom-cycle deadlock.

## Verification

### Simulators

Focused slice test `tb_scpu_ramce_gate.vhd` passed in:

- `ghdl`
- `nvc`

Checks covered:

- badline `CPUC` with `cpuHasBus='0'` and `scpu_bus_valid='0'` still asserts `ramCE`
- phantom CPU-owned cycle with `cpuHasBus='1'` and `scpu_bus_valid='0'` does not
  assert `ramCE`
- valid CPU-owned cycle still asserts both `ramCE` and `supercpu_cycle`

### Quartus

- syntax/elaboration: passed
- full compile: passed

Build artifact:

- [C64.rbf](C:/LLM/C64/MiSTerSuperCPU/C64_MiSTer/output_files/C64.rbf)

### Hardware

Deployed to MiSTer and captured screenshots plus UART:

- clean BASIC `READY.` screen in SuperCPU mode
- moving repeated-character corruption no longer present
- 15-second screenshot comparison changed only in the debug overlay region
- debug UART frame counter continued incrementing, proving the core remained alive

Representative UART sample after the fix:

```text
A:E5CF D:00 B:00 S:01F3 P:32 I:A5 E:1 F:1266
A:E5D6 D:00 B:00 S:01F3 P:32 I:F0 E:1 F:1269
A:E5D1 D:00 B:00 S:01F3 P:32 I:85 E:1 F:126F
A:00C6 D:00 B:00 S:01F3 P:32 I:A5 E:1 F:1273
```

This is a live idle-loop pattern, not a dead frame.

## Tooling Follow-Up

[`tools/mister_debug.py`](C:/LLM/C64/MiSTerSuperCPU/tools/mister_debug.py) was updated
to configure `/dev/ttyS1` as `115200 raw -echo` before reading the debug UART.
Without that, the UART output looked like garbage even though the debug stream was valid.
