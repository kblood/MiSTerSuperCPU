# Session handoff — 2026-05-22 (Phase F.1 deploy revealed bridge wedges hardware regardless of BRIDGE_ACTIVE)

## CRITICAL FINDING

**Every async-cpu-bridge variant (D1→F.1) wedges KERNAL boot on hardware**, including BRIDGE_ACTIVE='0' which was supposed to be bit-for-bit baseline passthrough. The previous "B + C + D inert = bit-identical to baseline" claim in the prior session_handoff was apparently based on synthesis output only, not validated on hardware. Resume by deciding the strategic direction (see "Open question for user" below).

## Evidence gathered this session

### Builds deployed to MiSTer (192.168.50.130:/media/fat/_Test/C64.rbf), screenshot evidence in `tools/`

| RBF | Branch tip | Bridge state | Result |
|---|---|---|---|
| 88963b9e | `8434077` Step 6 Phase 6a (PRE-bridge) | no bridge entity | **CLEAN BOOT** — "**** COMMODORE 64 BASIC V2 ****" + READY. (`tools/phaseF_88963b9e_baseline.png`) |
| 3929f892 | `5d97ac2` D4 inert | BRIDGE_ACTIVE='0', CACHE_ACTIVE='0' | **WEDGES** — blue screen, no READY (`tools/phaseF_5d97ac2_D4_inert.png`) |
| 64116f31 | `e647f67` F.1 baseline | BRIDGE_ACTIVE='0', CACHE_ACTIVE='0' | **WEDGES** — garbled charset, `$AB AB AB AB` on every data-bus read (`tools/phaseF_baseline_boot.png`, `tools/phaseF_baseline_boot_15s.png`) |
| 0e414443 | `e647f67` Build B (active MCP) | BRIDGE_ACTIVE='1', CACHE_ACTIVE='0' | **TOTAL FREEZE** — CPU stuck at PC:000000, F: timer counting but no instruction advance (`tools/phaseF_BuildB_BRIDGE_ACTIVE_1.png`) |

UART captured during all four states. PC values, F counter, IRQ source bits all logged.

### Wedge signatures

- **F.1 BRIDGE_ACTIVE='0'**: `V:AB AB AB AB W5:AB AB AB AB YX:ABAB` everywhere. CPU reads $AB on every memory access. Loops $00EA0D / $00FD2E (KERNAL IRQ/RESET addresses) endlessly. Matches D4.2 wedge signature in `memory/project_bridge_cache_d4_2_wedge.md` ("$AB on every ZP read").
- **Build B BRIDGE_ACTIVE='1'**: CPU never advances past reset (PC:000000), but F: timer pulses normally. Indicates `cpu_rdy_out` is stuck low — the MCP handshake's ack-toggle never returns to the CPU side. Bench (sim/scpu_async_bridge_tb) passes scenarios E/F/G/H/I but that uses a synthetic ack model that fires every clk_sys cycle regardless of arbiter state — the bench doesn't replicate the real arbiter's CPU-slot gating (CYCLE_CPU0/4/8/C at 1 MHz cadence with turbo masks).

### What's confirmed

1. **Hardware is fine** — 88963b9e clean READY confirms MiSTer + power supply + monitor + everything is OK.
2. **Build process is fine** — Quartus produces RBFs with correct MD5, transfer to MiSTer is bit-perfect (verified via md5sum on device).
3. **GHDL bench is misleading for the real arbiter** — both BRIDGE_ACTIVE configs pass bench but break on hardware.

### What's still unknown

- **Where exactly the F.1 baseline diverges from passthrough**. The output muxes at `scpu_async_bridge.vhd:347-361` are conditionals like `when BRIDGE_ACTIVE = '1' else cpu_addr_in`, which should reduce to direct passthrough at synthesis time. Yet hardware behavior doesn't match.
- **Whether D1 (simplest passthrough bridge, no D2+ scaffolding) ever worked on this hardware**. No RBF archive exists for D1/D2/D3 commits to test directly. The earliest bridge-bearing RBF in `C64_MiSTer/builds/` is 3929f892 (D4-inert, already wedged).
- **Whether 5cc9fc7 (D1 passthrough) was hardware-validated or just synthesized**. The prior `b47b389 docs: async-bridge handoff — Phases A/B/C done` predates D1, so the only confirmation in memory is for Phases A/B/C (the clk_cpu wire renames), not the bridge entity introduction.

## Open question for user

Three reasonable paths forward:

**Path A — Roll back to pre-bridge, retry Phase F with a different bridge topology.**
Start from `8434077` (88963b9e), apply ONLY Phases A/B/C (clk_cpu wire renames), then design a NEW bridge that's incrementally validated on hardware at each step. The current bridge entity has accumulated 14 commits of scaffolding that all share the same wedge fingerprint — likely a topology problem, not a code bug.

**Path B — Build a hardware-verified D1 reference.**
Check out `5cc9fc7` (D1 passthrough), build, deploy, see if it wedges. If yes, the bridge entity itself broke things. If no, bisect through D2/D3/D4 to find the introducing commit.

**Path C — Diagnose the F.1 wedge directly via targeted UART instrumentation.**
Add per-cycle bridge state to the UART overlay (req_toggle, ack_toggle, bus_request_pending, cpu_rdy). Rebuild with BRIDGE_ACTIVE='1' (Build B). Read what the FSM is actually doing on hardware. This is ~1-2 builds away from a real answer if it's an FSM bug, but won't help if it's a timing/synthesis bug.

Recommendation: **B first** (cheap, ~1 build + 5-min HW test), then A if B shows D1 is broken, or C if D1 works.

## Current MiSTer state

- `/media/fat/_Test/C64.rbf` restored to **88963b9e** (known-good, clean READY prompt)
- `/tmp/mister_session.lock` cleared
- `/tmp/CORENAME=C64` (loaded via load_core after restore)

## Local working tree

- HEAD: `e647f67` on branch `async-cpu-bridge` (was `vanilla-cpu-swap` per opening session-reminder, since switched)
- Uncommitted: `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2676 BRIDGE_ACTIVE => '1'` (Build B state — flip to '0' for baseline rebuild)
- Plan doc: `docs/async_bridge_mcp_handshake_plan.md`
- Bench (verified clean): `sim/scpu_async_bridge_tb/run_bridge_tb.ps1 -StopTime 25us`

## Memory note to add when path chosen

`feedback_*` entry: "GHDL bench scenarios E/F/G/H/I were validated as passing twice (at 32MHz same-clock and at 64/32MHz two-clock), but BOTH BRIDGE_ACTIVE='1' Build B (MCP active) and BRIDGE_ACTIVE='0' baseline (supposed passthrough) wedge on hardware. Bench passes ≠ HW works for this design — the bench model's arbiter fires bus_ack_pulse_in regardless of CPU-slot scheduling, which the real arbiter only does at CYCLE_CPU0/4/8/C with turbo masks at ~1 MHz cadence. Don't trust this bench's ack as a hardware predictor."
