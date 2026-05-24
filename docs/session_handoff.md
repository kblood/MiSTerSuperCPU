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

### Verify next session
1. **Lorenz regression** — does v8 passthrough still pass the t65 and
   scpu Lorenz suites? Expected yes (passthrough is bit-equivalent to
   pre-bridge baseline for arbiter wiring), but worth a 32-min run.
   Compare against `tools/lorenz_run/scpu_2026-05-19_v356_baseline/`.

2. **Doom / Wolf3D** — both ran on v356 baseline; verify they still
   run on v8. Tests in `tools/doom_v356_PLAY.py` and equivalents.

3. **scpu_speed_bench / $D0B8 read decode** — the bench's $D0B8 read
   returns FF (open bus) since v6. Separate pre-existing bug at
   `fpga64_sid_iec.vhd:1680`. Not blocking but worth fixing for
   bench credibility.

### MCP path revival (only when needed for clk_cpu=64MHz)
The bridge is preserved intact. Setting `SAME_CLOCK_PASSTHROUGH=>'0'`
re-arms MCP. Before doing so, fix the vpa/vda hold:
- **Candidate fix**: in `scpu_async_bridge.vhd`, drop
  `bus_request_pending_reg` the cycle after `bus_ack_pulse_in`,
  not after `bus_ack_toggle_reg` flips. Or gate `bus_vpa_out`/
  `bus_vda_out` with a single-cycle pulse rather than the held
  pending flag.
- **Alternative**: route CIA1/CIA2 reads through a "direct" passthrough
  path that bypasses MCP, since they're 1MHz-clocked anyway.
- Test: load v6 RBF (commit 30b7dde) with the proposed fix, repeat
  the v8 LOAD"$",8 / LOAD"*",8,1 test suite. Must pass before MCP
  goes back into active configuration.

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
