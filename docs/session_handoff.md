# Session handoff — 2026-05-24 (v7 throttle: $D072 wired, IEC still wedges)

## TL;DR — $D072 throttle gate landed; BASIC slows on demand, IEC LOAD still blocked

v7 (commit `44559a8`, RBF `0AA93CFDEA31AAFD6E48DB439C1BAEF8`) adds an
arbiter-side throttle: when software writes `$D072` (system 1MHz) or
`$D07A` (SCPU 1MHz), `cpu_cyc` is restricted to a single `CYCLE_CPUC`
slot per 1MHz period, dropping the bus rate from ~3MHz (turbo) back
to stock 6510 cadence. Bridge stays untouched (`enableCpu_816 =
cpu_cyc_s(1)` so the throttle propagates through the MCP ack pulse
naturally).

**Confirmed working** via BASIC TI delta test:
- Turbo: `FOR I=1 TO 500:NEXT` → `TI = 18` jiffies (0.3s)
- After `POKE 53362,0` (= $D072): same FOR loop runs >30s without
  finishing — throttle drops BASIC by ≥100x (interpretive overhead
  scales with bus rate)
- Screenshots: `tools/d072_throttle_test/20_turbo_ti.png`,
  `21_1mhz_ti.png`, `22_1mhz_ti_30s.png`

**IEC LOAD still wedges** (the original goal):
- v6 wedge: PC stuck at `$00:EEAF` indefinitely (BIT/AND #$04 on $DD00)
- v7 + POKE 53362,0: PC=`$00:EEAC` with M slots cycling through
  `EA31 / FE66 / F1CA` — one byte earlier in the same IEC byte-receive
  loop, CPU IS making IRQ progress but still polling CIA2 forever for
  IEC clock to go high.
- 1MHz CPU rate alone is NOT sufficient. Either the IEC stub never
  asserts CLKIN high, or the bridge's MCP timing corrupts CIA2 reads
  in some subtle way.

## scpu_speed_bench.prg shows no slowdown — separate puzzle

All four phases still return `$00064F` (identical to v6) and
`$D0B8 STATUS: FF` (open-bus value, our decode at `fpga64_sid_iec.vhd:1680`
isn't matching the bench's read). This contradicts the BASIC TI proof,
suggesting either:
1. The bench's `sta $D07A` writes don't propagate (less likely — same
   opcode as BASIC POKE)
2. The bench's tight count loop dodges the throttle somehow (more
   likely — its INC ZP + LDA VIC_RASTER mix may not hit the gated slots)
3. $D0B8 read decode has been broken since v6 (separate, pre-existing bug)

The BASIC TI test is the trusted ground truth. The bench is unreliable
as a throttle indicator.

## Files touched

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1214` — `scpu_force_1mhz` signal
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2817` — `scpu_force_1mhz <= scpu_speed_1mhz or scpu_sys_1mhz`
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2820-2825` — cpu_cyc turbo slots + alt-fire gated on `scpu_force_1mhz = '0'`
- `docs/d072_runtime_throttle_plan.md` — design discussion (arbiter-side chosen over bridge port additions)
- `tools/d072_throttle_test.py` — boot + POKE + LOAD smoke test

## IEC differential evidence (added 2026-05-24 second loop)

Differential test against vanilla MiSTer C64 (`/media/fat/_Computer/C64.rbf`,
md5 `32a3ef42a78ed8b255bed895d09b833c`, mounted same MGL + same `lorenz_disk1.d64`):

- **Vanilla**: `LOAD"*",8,1` shows `SEARCHING FOR *` → `LOADING` → `READY.`
  in ~17 seconds. IEC and disk path fully functional.
  (Screenshots `tools/d072_throttle_test/30-33_vanilla_*.png`)
- **v7 + POKE 53362,0**: `LOAD"*",8,1` wedges at PC=`$EEAC` (LDA $DD00
  in IEC byte-receive). `LOAD"$",8` (directory) also wedges at
  `$EAC3` (IEC TALK phase) with `M: EB48 EA31 EB48 EA31`. CPU IS
  cycling through IEC code, never completes the handshake.
  (Screenshots `40-41_v7_dir_load_*.png`)

The wedge is in the IEC HANDSHAKE itself, not file-fetch specifics —
directory load uses a different protocol phase and also fails.
**Regression introduced by the bridge work** (Phase C onward; master is
the v356 baseline where IEC LOAD was confirmed working per
`project_v356_lorenz_pass.md`).

Likely candidates (not confirmed):
1. clk_cpu=64MHz CDC affects CIA2 read/write timing
2. MCP handshake produces shorter vpa/vda hold than vanilla's full bus cycle
3. cs_cia2 strobe edge differs in MCP mode vs vanilla's CPU-direct

## Next-session entry points

1. **Bisect the IEC regression** through the bridge phase commits:
   - Pre-bridge baseline: master (or commit `db149d6` v356)
   - Phase C (`f7ba6d7`): P65C816 moved to clk_cpu — first bridge
   - Phase D1 (`5cc9fc7`): passthrough module
   - Phase D2-D4 (`0bff0d9` through `5c72dbd`): CDC + cache scaffolding
   - F.1' (`da1a684`): MCP FSM restored
   - F.3' Path B v6 (`30b7dde`): MCP + LATCH gate
   - v7 (`44559a8`): + $D072 throttle (current)
   Each build ~30 min. Try LOAD"$",8 (faster signal than LOAD"*",8,1).
   The commit where IEC first wedges names the structural culprit.

2. **Surgical bridge tests** without bisect:
   - Set SAME_CLOCK_PASSTHROUGH=1 (line 2726 in fpga64_sid_iec.vhd) →
     EFF_BRIDGE_ACTIVE='0', pure passthrough. If IEC works here, MCP
     is the problem. If wedges, clk_cpu=64MHz or P65C816-side is.
   - Extend bus_vpa_out/vda_out by 1 clk_sys cycle after ack (held
     longer than `bus_request_pending_reg` allows). If IEC fixes,
     CIA needs longer strobe.

3. **F.4 cache re-enable** still on roadmap (held inert in F.1-F.3).

4. **F.3' arbiter prefetch** (per `docs/path_to_20mhz_plan.md`) — main
   path to 20MHz target.

2. **Verify bench-vs-BASIC discrepancy.** Write a controlled PRG that:
   - Writes `$D072` then increments a visible screen char in a tight
     loop at some rate, then writes `$D073` and increments a different
     screen char. Visually compare rates. Either confirms or refutes
     "bench tight loops dodge the throttle."

3. **F.4 cache re-enable** still on roadmap (held inert in F.1-F.3).

4. **F.3' arbiter prefetch** (per `docs/path_to_20mhz_plan.md`) — main
   path to 20MHz target.

## Cooperation note

cd32 took the device mid-session and released it back. MiSTer is free
at session end. v7 RBF is at `/media/fat/_Test/C64.rbf` — next session
just needs `load_core` to bring it back.
