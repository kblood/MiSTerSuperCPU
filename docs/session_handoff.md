# Session handoff — 2026-05-23 (V8 page-mode addr-latch attempt + V6 reconfirm + 10x roadmap)

## TL;DR
Two flavors built/tested this session on top of `83d7716` (Milestone A
scaffolding):

1. **V6 reconfirm** — Build B + V6 cycle-shorten (`if (q == 3'd5 && !reset)
   q <= 3'd0;`). md5 `a993d7b7`. **Boots clean** — KERNAL READY, PC
   $E5CD keyboard wait loop, VW=AC=1 (VIC ack chain healthy). Bench
   shows $0001DC same as Build B (bench is I/O-bound on $D012/$DC0D so
   V6's 25% SDRAM throughput improvement is invisible).
2. **V8 = V5 + addr-latch** — preserved at
   `rtl/sdram_pm.v.V8_addrlatch_FAILED.draft`. md5 `022076ba`.
   **Wedges WORSE than V5**: PC stuck at $00:$0002 with 16 BRK pushes
   per UART frame ($30 SP drop), M ring shows continuous vector
   fetches at $FFFF/$FFB4/$FF34 — CPU is bricked at boot, never gets
   past reset vector. Earlier than V5's $0109+ wedge.

## Why V8 made things worse
The "top suspect" identified at the end of the V5 bisect was that
`is_hit`/`is_conflict` read `row_valid[req_bank]` combinationally on
*live* `addr`, which might be in transition around the ce-edge.

The V8 fix introduced `reg [24:0] addr_l_r; always @(posedge clk)
addr_l_r <= addr;` and routed every bank/row reference and ce-edge
dispatch through `addr_l_r`. **But `addr_l_r` is captured 1 clk64
BEFORE the ce-rising edge dispatch fires** (NBA semantics: at the
dispatch posedge, the combinational reads of `addr_l_r` see the
pre-edge value, which is the value captured 1 clk64 ago). With the
arbiter's likely timing — clk32 posedge drives both addr and ce — the
first clk64 posedge where `ce && !last_ce` fires reads `addr_l_r` that
hasn't yet captured the new addr. **Result: dispatch sees the
PREVIOUS access's bank/row.** At reset, addr_l_r=0 → row=0 → ACTIVE at
row 0, then COLD READ → physical address 0, not $FFFC. CPU gets
garbage as the reset vector → infinite BRK loop.

**Conclusion**: the addr-latch is wrong direction. The CORRECT fix
requires either (a) using live `addr` at ce-edge dispatch but
guaranteeing addr stability via the arbiter (= Build C original,
which wedged with the V5 signature for some OTHER reason), or (b)
delaying dispatch by 1 clk64 to let addr_l_r catch up. Neither is
trivially achievable from the current ce-edge structure.

## Path to 10x — architectural analysis

Current state: **4 MHz** when OSD turbo is on (4 fires per 32 clk32
sysCycleDef at CPU0/4/8/C). Bench reports 1x ($0001DC at all OSD
settings) because the speedtest itself is I/O-bound on $D012/$DC0D —
the 4x is real but invisible to that probe.

**Why 4 MHz is the hard cap today**:
- Arbiter fires CPU0/4/8/C (spaced 4 clk32 apart)
- V6 SDRAM cycle = 6 clk64 = 3 clk32 busy
- `sdram_busy_cnt` is set to 3 at any cpu_cyc fire that drives an
  SDRAM transaction (= bank-$00 RAM AND SuperRAM via cart_ce)
- alt_fire_r latch at CPU1 sees sdram_busy=1 → never latches → alt-slot
  is dormant on V6/Build B
- Comment at `fpga64_sid_iec.vhd:786-789` confirms: "On Build B
  (counter=3, 4-clk32 SDRAM cycle) sdram_busy=1 at CPU1 so alt_fire_r
  latches 0 → no alt fire → bit-identical behaviour to Step 2 /
  bisect-1. On Build C HIT (counter=1) alt_fire_r latches 1 → CPU2
  fires next clk32 → 8 MHz cadence."

**Three viable paths to 10x — all major work**:
1. **Build C HIT path** (`docs/path_to_20mhz_plan.md` Milestone A
   continuation). Page-mode HIT = 5 clk64 = 2.5 clk32 busy. Counter
   becomes 1. alt_fire_r latches 1 at CPU1 → alt-slot at CPU2 fires →
   8 MHz cap. **Blocker**: V5/V8 wedge mechanism still unsolved.
   Bench needs bypass of the I/O floor to even verify the throughput
   gain.
2. **Phase F MCP** (`docs/async_bridge_mcp_handshake_plan.md`,
   commit `e1147a6`). Boost clk_cpu to 64 MHz (2x current 32 MHz).
   With a correct CDC handshake the CPU can issue ~2x as many bus
   accesses per sysCycleDef. **Blocker**: F.1c-f all wedged at
   PC:000000 (see memory `project_phaseF1c_BRIDGE_ACTIVE_1_wedge.md`).
   Needs SAME_CLOCK generic OR pre-emptive capture redesign.
3. **Arbiter rewrite** for sub-cycle scheduling. With V6 SDRAM (3
   clk32 busy), max throughput = 32/3 = 10.67 fires per sysCycleDef.
   Need a brand-new scheduler that fires every 3 clk32 regardless of
   the current CYCLE_CPUx alignment. Step 2 alt-slot attempt
   (CPU2/6/A/E) wedged Doom with both OUTER and INNER busy gates;
   Step 6 registered-fire fix is in place but dormant. Untested
   above the alt-slot: full scheduler rewrite.

**Math summary**:
| SDRAM cycle (clk32) | Max fires/sysCycleDef | Max CPU MHz | Status        |
|---------------------|------------------------|-------------|---------------|
| 4 (Build B)         | 4 (existing)           | 4           | working       |
| 3 (V6)              | 4 (existing) / 8 alt   | 4 / 8       | V6 boots, alt dormant |
| 3 (V6) + new arb    | 10                     | 10          | requires arb rewrite |
| 2.5 (Build C HIT)   | 8 alt-slot enabled     | 8           | Build C wedges |
| 2.5 + Phase F 64MHz | ~13                    | 13          | Phase F wedges |

## Tree state (uncommitted)
- Branch: `async-cpu-bridge` (HEAD `83d7716`)
- `C64_MiSTer/rtl/sdram_pm.v` — V6 active (Build B + cycle-shorten)
- `C64_MiSTer/rtl/sdram_pm.v.V6_cycle6.draft` — V6 reference
- `C64_MiSTer/rtl/sdram_pm.v.V7a_CL1.draft` — failed CL=1 attempt
  (MT48LC16M16A2-7E doesn't support CL=1)
- `C64_MiSTer/rtl/sdram_pm.v.V8_addrlatch_FAILED.draft` — V5 + addr-latch
  (this session's experiment; wedges at PC $0002)
- `C64_MiSTer/rtl/sdram_pm.v.buildC.draft` / `.buildC_V5.draft` — prior
  Build C variants

## MiSTer state
- Active core: V6 RBF on `/media/fat/_Test/C64.rbf` (md5 `a993d7b7`),
  boots clean to KERNAL READY.
- Daemon: healthy (UART responsive, /tmp/CORENAME free).

## Next-session entry points (in priority order)
1. **Build a CPU-bound bench** that bypasses $D012/$DC0D so the 4x →
   10x progression is actually measurable. Pattern: CIA1 Timer A
   one-shot with IRQ-driven termination + tight ZP-only inner loop.
   ~half-day work; unblocks every subsequent throughput experiment.
2. **Revisit Build C wedge** with a different hypothesis: NOT addr
   stability (V8 confirms addr-latch is wrong direction). Candidates:
   (a) refresh-storm under load (V4's `refresh_pending` stays high
   if every idle gets a new ce-edge), (b) row_open/row_valid update
   race vs ce-edge dispatch (NBA semantics: row_open write at COLD
   may not be visible to is_hit check 1 clk64 later), (c) GHDL bench
   testbench coverage gap — bench has succeeded for every variant
   that then wedged on HW.
3. **Phase F MCP redesign** per `docs/async_bridge_mcp_handshake_plan.md`
   updated entry "F.1c-f BRIDGE_ACTIVE wedge" (memory
   `project_phaseF1c_BRIDGE_ACTIVE_1_wedge.md`). Required for Path 2.

## Reference
- Memory `project_milestone_a_buildC_bisect_2026_05_23.md` — prior V1-V5
  bisect table.
- Memory `project_milestone_a_buildC_wedge_2026_05_22.md` — early Build C
  attempts.
- Memory `project_phaseF_mcp_handshake_plan.md` — Phase F plan summary.
- Memory `project_phaseF1c_BRIDGE_ACTIVE_1_wedge.md` — F.1c-f wedge.
- `docs/path_to_20mhz_plan.md` — three-milestone plan with risk registers.
- `docs/async_bridge_mcp_handshake_plan.md` — Phase F MCP detail.
