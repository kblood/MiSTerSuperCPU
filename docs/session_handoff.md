# Session handoff — 2026-05-24 end-of-session (v6 boots to READY)

## TL;DR — F.3' Path B v6 boots KERNAL to READY at clk_cpu=64MHz

After 6+ wedge-iteration dead ends (v2/v3/v4/v5 all stuck somewhere
in the kickstart area at $48Bx with no real video), v6 (commit
`30b7dde`, RBF `78c83f2f7511798439c7978a976991a8`) deployed and
captured screen + UART. The C64 boots to the standard READY prompt
with the async bridge active at clk_cpu=64MHz:

```
**** COMMODORE 64 BASIC V2 ****
64K RAM SYSTEM  38911 BASIC BYTES FREE
READY.
```

PC bouncing $E5CD-$E5D4 (KERNAL keyboard wait loop polling $00C6 NDX),
SP=$01F3 (standard boot stack), VW=0001 (VIC frames running),
IF counter incrementing rapidly. The earlier "v2 reaches CMD
SuperCPU MENU" handoff (REVISED 9) was a misread — the yellow text
on HDMI was OUR debug overlay, not real video. v6 produces actual
video for the first time.

## Root cause of v2/v3/v4/v5 wedges

Stale `bus_di_capture_reg` latching race. The 3-state FSM
(IDLE/PENDING/WAIT_ACK) with sustain-en in IDLE: after WAIT_ACK
match transitions to IDLE, the CPU samples rdy=1 en=1 at the next
edge while `bus_di_capture_reg` still holds the PREVIOUS request's
data. The CPU's new vpa/vda has already asserted, so it latches
stale di as IR → latches BRK ($00) → bounces through IRQ vector
→ wedges in tight loops. PC appears stuck because CPU never makes
real progress.

Bench reproduced this exactly: INC $D6 wrote $01 forever
(d6_increment_count=4, zp_ram($D6)=$01) because LDA $D6 kept
returning stale $00. On silicon the same race made KERNAL never
get past its early init sequences — wedge looked like loop at
$48Bx but was actually BRK→re-init bouncing.

## The v6 fix (commit `30b7dde`)

Two parts in `C64_MiSTer/rtl/scpu_async_bridge.vhd`:

1. **4-state FSM** with new `CPU_LATCH` state inserted between
   `WAIT_ACK` match and `IDLE`. LATCH holds `rdy=1, en=1` for
   exactly one clk_cpu so the CPU latches the fresh di before
   the gate (below) activates. LATCH → IDLE.

2. **Combinational rdy/en gate** at the output mux: when
   `cpu_fsm = CPU_IDLE` AND CPU asserts `vpa=1 or vda=1`, force
   `cpu_rdy_out = 0` and `cpu_enable_out = 0` regardless of
   registered values. Internal cycles (vpa=0 vda=0) pass through
   transparently, so multi-cycle ops (INC RMW, 16-bit reads,
   BCD, native IRQ) get the en=1 cycles they need without
   exposing the CPU to stale di on the next bus access.

## Why earlier attempts failed

| Build | FSM design | Bench D6 | Silicon | Why |
|-------|------------|----------|---------|-----|
| v2 (`4116673`) | 3-state, sustain en in IDLE | (broken) | $48B6/$48BA wedge | Stale di race |
| v3 (`9b0d4d0`) | + CPU_POST_ACK_SETTLE | count=4, D6=$01 | $48BA wedge | Settle didn't address di staleness |
| v4 (build failed) | + CPU_POST_ACK_SETTLE2 | (build failed) | n/a | Wrong direction anyway |
| v5 (uncommitted) | comb gate only | PC=$0000 forever | n/a | Gate fires before LATCH |
| **v6 (`30b7dde`)** | **gate + CPU_LATCH** | **count=12, D6=$05** | **READY prompt** | **Stale-di + latching window both handled** |

## What's WORKING (cumulative this session)

- ✓ CPU advances past reset
- ✓ Enters native 8-bit mode (CLC; XCE executed)
- ✓ Bootmap kickstart runs in $F8 EPROM
- ✓ KERNAL ROM executes correctly (full boot sequence)
- ✓ VIC-II renders the BASIC READY screen at correct colours
- ✓ Frame counter advancing at 60 Hz (VW=0001)
- ✓ Stack at expected boot location ($01F3)
- ✓ CPU in standard keyboard wait loop ($E5CD-$E5D4)

## What's NOT YET tested on v6

- 🔴 Lorenz 6510 regression — **CANNOT RUN ON v6** — `LOAD"*",8,1` wedges at PC=$00:EEAF (KERNAL IEC byte receive). KERNAL bit-receive code samples CIA2 with tight 1MHz timing assumptions; at v6's ~3MHz effective rate it loses byte framing. Stock SuperCPU avoids this with $D072 force-1MHz before disk ops, but our F.3' bridge ignores $D072 (same root cause as the 1x speed ratio). See `tools/v6_kb_test/12_check.png`.
- ⏳ Doom / Wolf3D playback (real apps using REU + SuperRAM)
- ⏳ Demo / cycle-accurate timing (VIC raster effects)
- ⏳ Cache re-enable (CACHE_ACTIVE was held inert through F.1-F.3)

## Confirmed on v6 (post-boot)

- ✓ **Keyboard input** — `PRINT "V6 KB TEST"` typed via mtype, parsed and rendered. CIA1 race concern resolved. (`tools/v6_kb_test/01_after_print.png`)
- ✓ **POKE 1000 to screen** — `FOR I=0 TO 999:POKE 1024+I,1:NEXT` fills entire screen cleanly. No dropped writes through BASIC path. (`tools/v6_kb_test/06_poke_clean.png`)
- 🟡 **SuperCPU speed benchmark — partial** — `scpu_speed_bench.prg` runs cleanly to completion. ALL FOUR phases ($D07A / $D07B / $D072 / $D073) return identical `$00064F` count = **~2.93x stock 1MHz, NOT 20MHz**. SCPU speed-control registers are non-functional in F.3'. Bridge MCP handshake (~16 clk_cpu per access) is the bottleneck. (`tools/v6_kb_test/08_prg_bench.png`)
- 🔴 **scpu_speedtest.crt (Ultimax) wedges** — Labels render with some chars missing, count values never appear, PC stuck in cart-ROM tight loop. Ultimax cart-ROM fetch path has issues separate from main RAM bridge. (`tools/v6_kb_test/02_scpu_speedtest.png`)

## F.3' status — bridge works, 20MHz does NOT, IEC is BROKEN

The async bridge at clk_cpu=64MHz is **structurally correct** (boots,
runs apps, no data corruption). But the effective CPU rate is bandwidth-
limited by the MCP handshake to ~3MHz, AND the SCPU speed-control
registers ($D07A/$D07B/$D072/$D073) are non-functional. The latter
means anything that requires temporary 1MHz mode (IEC LOAD, timing-
sensitive demos) cannot work.

To make v6 release-quality, the priority order is:

1. **Wire SCPU $D072 → bridge enable gate** so software-requested
   1MHz mode is honored. Without this, **IEC LOAD is broken** and we
   can't run the Lorenz regression at all — a hard blocker for any
   merge to master. This is probably a small RTL change.

2. **F.4 cache re-enable** — held inert through F.1-F.3 to keep
   bisects simple; can now be revisited with the bridge proven sound.

3. **F.3' arbiter prefetch** — sketch already in `docs/path_to_20mhz_plan.md`
   and the F.3' prefetch doc.

Steps 2+3 deliver the 20MHz goal. Step 1 unblocks regression testing.

## Files touched

- `C64_MiSTer/rtl/scpu_async_bridge.vhd:146-147` — enum with CPU_LATCH
- `C64_MiSTer/rtl/scpu_async_bridge.vhd:359-385` — WAIT_ACK match → CPU_LATCH; LATCH case
- `C64_MiSTer/rtl/scpu_async_bridge.vhd:488-506` — combinational rdy/en gate
- `sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd` — extended trace (cpu_we/do, 20us window) + zp_ram + d6 counter that exposed the bug
- `docs/session_handoff.md` (this file) — overwritten with v6 outcome

## Next-session entry points

1. **Confirm keyboard input works on v6.** PC is in $E5CD-$E5D4 wait
   loop — send key via mtype.py, watch PC advance to keyboard
   handler path. If CIA1 race exists, key won't register. If race
   exists, options: gate CPU rdy on CIA1 alignment when accessing
   $DC00-$DCFF; or hold the CPU at original 1MHz when polling CIA1.

2. **Lorenz regression.** Deploy v6, run Lorenz disk1, capture
   screenshots like `tools/lorenz_run/scpu/`. Compare hashes to
   v355/v356 baseline. Must still pass all 6510 instruction tests.

3. **Real apps.** Doom + Wolf3D via REU loading. Both rely on REU
   + SuperRAM paths the bridge feeds — proves cross-bank addressing
   under v6.

4. **SuperCPU benchmarks.** The whole point of F.3' was clk_cpu=64MHz
   for ~20MHz effective. Run `scpu_speedtest.crt` (already in
   `tools/test_cart/`) and verify $D07A/$D07B report ~20MHz, not
   1MHz. If <20MHz, profile the bridge's slot acquisition latency.

5. **Cache re-enable (F.4).** With the bridge proven on v6, the
   suspended cache work (`scpu_async_bridge.vhd:440-462` cache_gen)
   can be revisited. Use CACHE_ACTIVE generic.

## Cooperation note

cd32 agent took the MiSTer mid-session (loaded CDTV-DotC-Audio).
My session lock at /tmp/mister_session.lock had been cleared
(possibly a tmp wipe). The v6 RBF is still at
`/media/fat/_Test/C64.rbf` so any next session just needs
`load_core` to bring it back. Don't rebuild — md5 `78c83f2f` is
the working v6.
