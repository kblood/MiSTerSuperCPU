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

## Next-session entry points

1. **Root-cause IEC LOAD wedge.** Either:
   - **(a)** Inspect MiSTer's IEC subsystem from inside our build to see
     what `$DD00` returns during the spin. If our bridge corrupts CIA2
     reads under certain race conditions, that's a bridge bug; if the
     IEC controller never asserts CLKIN, that's an IEC subsystem bug.
   - **(b)** Compare against vanilla MiSTer C64 (commit known-good
     `/media/fat/_Computer/C64.rbf` per CLAUDE.md), confirm LOAD works
     there at 1MHz. If vanilla works and ours doesn't, the bridge or
     SCPU path is breaking IEC even at matched clock rate.
   - **(c)** Try `LOAD"$",8` (directory load — smaller IEC protocol).
     If directory works but file fetch wedges, the wedge is in a
     specific protocol phase.

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
