# Session handoff — 2026-05-22 (Phase F.1/F.2/F.3 prep landed; HW deploy gated on MiSTer cooperation)

## Status: F.1 + Build B both compiled cleanly. HW deploy blocked by other agent's core occupancy. Resume by deploying when MiSTer frees up.

**Current branch:** `vanilla-cpu-swap` (tip `7f9dced` — "async-bridge Phase F.1-F.3 prep")
**Uncommitted working-tree change:** `fpga64_sid_iec.vhd:2676 BRIDGE_ACTIVE => '1'` (Build B; flip back to `'0'` for the baseline-match build).

### What's in the tree right now
- **Bridge rewrite** (`rtl/scpu_async_bridge.vhd`, 290 lines): full MCP / word-synchronizer handshake. Source FSM `CPU_IDLE` → `CPU_WAIT_ACK`; sink-side `req_sync1/2_reg` + `ack_toggle`. Payload-stable-hold via `cpu_req_*_reg` registers. `preserve` + `SYNCHRONIZER_IDENTIFICATION FORCED IF ASYNCHRONOUS` attributes on all 4 sync FFs.
- **Bus mux fix** (committed): when `BRIDGE_ACTIVE='0'` all `bus_*_out` ports passthrough live CPU signals (not stale latched regs). When `BRIDGE_ACTIVE='1'` they drive `cpu_req_*_reg` gated by `bus_request_pending_reg`.
- **Bench** (`sim/scpu_async_bridge_tb/bridge_tb.vhd`, 401 lines): two independent clocks (CLK_SYS_PERIOD=31.25ns, CLK_CPU_PERIOD=15.625ns). Model arbiter with programmable `stall_cycles`. Five scenarios E/F/G/H/I all assert clean.
- **SDC** (`C64.sdc`): `set_false_path` declarations for bridge MCP CDC endpoints (req/ack toggle → sync1; payload bus; capture register).
- **Plan doc** (`docs/async_bridge_mcp_handshake_plan.md`): 6-phase plan F.0–F.5 with Appendix A confirming F.0 claims (PASS/PASS/PASS, corrected the F.0 agent's SDRAM-stale claim).

### Build results (this session)

| Build | Generic | RBF md5 | ALMs | Setup slack | Sync chains |
|---|---|---|---|---|---|
| F.1 baseline | `BRIDGE_ACTIVE=>'0'` | `64116f31f0d6b3a2678db2736c123b51` | 26,783 / 64% | +0.108 ns | 403 |
| F.1c Build B | `BRIDGE_ACTIVE=>'1'` | `0e414443fe8c31af3b08192d2d067455` | 26,550 / 63% | +0.625 ns | 568 |

Both archived in `C64_MiSTer/builds/` with timestamps `20260521T221546Z` / `20260521T224957Z`.
Setup/hold both positive on both flavors. Build B reports a 1-register shortest chain — investigated, all 4 bridge sync regs carry `preserve`+`SYNCHRONIZER_IDENTIFICATION FORCED IF ASYNCHRONOUS`; the 1-FF chain Quartus finds is unrelated noise (single-clock build, no real CDC paths yet — that comes in F.3).

### GHDL bench — PASS at two clock domains
`sim/scpu_async_bridge_tb/run_bridge_tb.ps1 -StopTime 25us` runs to `=== DONE ===` with no assertions firing. Five scenarios verify single-cycle ack, 4-cycle stall, 16-cycle stall, back-to-back reads, write-then-read across bank boundaries.

### What's NEXT
1. **Wait for MiSTer to free.** Current `/tmp/CORENAME=CDTV-DuneMVP` (other agent's CD32 work). Empty `/tmp/mister_session.lock`. /media/fat/_Test/C64.rbf still the May 21 21:59 build.
2. **Deploy F.1 baseline first.** RBF `64116f31...` to `/media/fat/_Test/C64.rbf`. Power-cycle or load_core C64. KERNAL must boot to READY identical to pre-F.1.
3. **Deploy Build B (BRIDGE_ACTIVE='1').** RBF `0e414443...`. Same hardware test. This validates the MCP handshake at clk_cpu=clk_sys=32MHz (same-clock, so no real CDC, but the FSM gymnastics still run).
4. **F.3 — flip clk_cpu=clk64.** Edit `c64.sv:328 wire clk_cpu = clk_sys;` → `wire clk_cpu = clk64;`. Rebuild. Deploy. This is where Phase E.1 wedged; Phase F's MCP should make it work.
5. **F.4 regression.** Lorenz Disk1 (t65 + scpu, 30 min cap), Doom mhold sequence, Wolf3D menu walk. Hashes vs v356 baselines.

### Phase F plan and decision points
Full plan at `docs/async_bridge_mcp_handshake_plan.md`. All 5 decision points defaulted (write-data don't-care on writes, unified MCP, 2-FF chain depth, drop-to-48MHz fallback, MLAB→flop fallback for F.5).

### Open items (no action required this session)
- 1-register shortest sync chain in Build B report — re-check Synchronizer Statistics in F.3 build to see if it persists when real CDC paths exist.
- Cache (F.5) deferred until F.3 + F.4 prove the MCP unlocks 64 MHz.
- `c64.sv:1779-1780` notes "hardcoded turbo_mode(2'b10)" in CLAUDE.md is STALE per `project_wolf3d_post_space_wedge_was_turbo_off` memory; turbo is OSD-driven from `status[47:46]`.

### Files modified this session (uncommitted at handoff)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2676` — `BRIDGE_ACTIVE => '1'` (Build B state). Flip back to `'0'` for baseline rebuild.
