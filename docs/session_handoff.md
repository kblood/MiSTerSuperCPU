# Session handoff — 2026-05-24 (v8 IEC LOAD restored via passthrough)

## TL;DR — single-bit flip in fpga64_sid_iec.vhd unwedges IEC LOAD

Setting `SAME_CLOCK_PASSTHROUGH => '1'` on the `scpu_async_bridge`
generic (fpga64_sid_iec.vhd:2729) routes all CPU bus signals through
the pre-MCP passthrough wires. The MCP FSM is preserved intact in the
bridge module but its outputs no longer drive the system.

**v8 RBF:** `b1aceea1b93df6a78dc614aed4cb6d97` (3.64 MB), built in
13 minutes, deployed to `/media/fat/_Test/C64.rbf`.

### Confirmed working
| Test | v7 (MCP active) | v8 (passthrough) |
| --- | --- | --- |
| KERNAL boot to READY | ✅ | ✅ |
| PRINT statement | ✅ | ✅ |
| `LOAD"$",8` | ❌ wedge at $EEAC | ✅ SEARCHING → LOADING → READY |
| `LOAD"*",8,1` (turbo) | ❌ wedge at $EEAC | ✅ completes |
| `LOAD"*",8,1` + POKE 53362,0 | ❌ wedge at $EEAC | ✅ completes |
| $D072/$D07A throttle (BASIC TI delta) | ✅ | ✅ (gate still effective) |

Evidence:
- `tools/v8_iec_passthrough_test/04_dirload_t25s.png` — directory load
- `tools/v8_prog_load_test/p1_t10s.png` — program load (turbo)
- `tools/v8_prog_load_test/p2_t10s.png` — program load (throttle)

### Why MCP broke IEC (hypothesis)
The MCP path holds `bus_vpa_out / bus_vda_out = '1'` for the full
round-trip duration (gated by `bus_request_pending_reg`). That keeps
`cs_cia2` asserted across multiple CIA2 internal clock edges per
CPU read, so the KERNAL byte-receive loop at `$EEAC` either sees
the wrong PB6/PB7 sample or trips an internal CIA edge-detect.
v7's $D072 throttle slowed the CPU but did not narrow the
vpa/vda hold — hence the wedge persisted.

A future fix should drop vpa/vda the cycle AFTER `bus_ack_pulse_in`
captures bus_di, not after the ack toggle round-trip completes.

## Speed status — no regression
v8 passthrough runs at the same ~3MHz effective rate as v7. The
arbiter `cpu_cyc` fires only on CYCLE_CPU0/4/8/C slots (gated by
cs_ram), and that — not MCP overhead — is the real bottleneck at
`clk_cpu = clk_sys`. The MCP path provides ZERO speedup until
`clk_cpu = 64MHz` is wired up.

## Files touched
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2720-2738` — generic flip + comment
- `docs/session_handoff.md` — this doc
- `tools/v8_iec_passthrough_test.py` — IEC LOAD probe
- `tools/v8_prog_load_test.py` — program LOAD probe with/without throttle
- Memory: `project_v8_passthrough_iec_fix_2026_05_24.md`

## Open follow-ups

### Likely safe to drop (was a partial mitigation)
The v7 $D072 throttle is no longer needed for IEC LOAD. It's still
useful as a *user-visible* speed-control register that maps to real
SCPU semantics, so the cpu_cyc gating in fpga64_sid_iec stays in.
But the throttle is no longer load-bearing for correctness.

### Verify next session — ALL COMPLETE (2026-05-24)
1. **Lorenz regression** — ✅ PASSED. scpu mode 32-min run to
   `eoriy - ok` (1922s), matches/exceeds v356 baseline.
   Artifacts in `tools/lorenz_run/scpu/`.

2. **Doom / Wolf3D** — ✅ PASSED. Doom shows init banner
   (`tools/test_doom_smoke/t120s.png`). Wolf3D shows title +
   sound config menu (`tools/wolf3d_full/shot_240s.png`).

3. **scpu_speed_bench / $D0B8 read decode** — ✅ WORKING (decode
   was never broken — earlier "FF" claim was v7-MCP-timing
   artifact). v8 bench shows 1MHZ=$01DC vs TURBO=$0650
   (~3.4× ratio honored), $D0B8 STATUS=$00 (correct end-of-phase
   value with both speed_1mhz and sys_1mhz cleared by $D07B/$D073
   writes). Bench-via-MGL runner at `tools/run_scpu_speed_bench_mgl.py`,
   evidence at `tools/scpu_speed_bench_mgl/t30s.png`.

### MCP path revival (only when needed for clk_cpu=64MHz)
The bridge is preserved intact. Setting `SAME_CLOCK_PASSTHROUGH=>'0'`
re-arms MCP. The earlier "vpa/vda stretching cs_cia2" hypothesis
is **WRONG**: `cs_cia2Loc` at `fpga64_buslogic.vhd:473` decodes
purely from `cpuAddr(11..8)`, not vpa/vda. Likewise the C64
fork's only consumer of `bus_vpa_out / bus_vda_out` is
`opcode_fetch_pulse` (`fpga64_sid_iec.vhd:4412`) and it's
already gated by `enableCpu_816`.

The actual MCP-vs-passthrough delta lives in:
- `cpu_di_out`: capture timing (bus_di_capture_reg vs bus_di_in
  combinational).
- `cpu_enable_out`: pulses on CPU_LATCH cycle vs every
  bus_ack_pulse_in.
- `cpuAddr` hold: in MCP path, addr is latched payload held for
  full round-trip; in passthrough, addr is whatever the P65C816
  presents that cycle. At clk_cpu=clk_sys the P65C816 also holds
  addr between enable pulses, so the hold *length* should be
  similar — but the *phase* alignment of addr changes vs
  enableCpu_816 differs, which is what likely confuses CIA2's
  internal phi2 sampling.

Recommended next-session probe path (before any RTL edit):
1. Build with BRIDGE_ACTIVE=1 + SAME_CLOCK_PASSTHROUGH=0 (re-arm MCP).
2. SignalTap or UART-instrument `cpuAddr / enableCpu_816 / cs_cia2`
   during a LOAD attempt — capture the actual edge timing relative
   to CIA2's phi2.
3. Differentially compare against the v8 passthrough capture at
   the same wait point.
4. Only then propose a fix targeting whichever phase mismatch
   shows up.

Test gate: load the v6 RBF (commit 30b7dde) with whatever fix the
trace recommends, repeat the v8 LOAD"$",8 / LOAD"*",8,1 test
suite. Must pass before MCP goes back into active configuration.

### Path to 20MHz target (unchanged)
- F.3' arbiter prefetch (`docs/path_to_20mhz_plan.md`).
- F.4 cache re-enable.
- Build C SDRAM page-mode revival.
All of these gate on clk_cpu=64MHz, which gates on the MCP-vs-CIA2
fix above. None block today's IEC LOAD progress.

## Cooperation note
v8 RBF is at `/media/fat/_Test/C64.rbf` on the MiSTer. Session
lockfile was set during this session; will time out automatically.
MiSTer free at session end.
