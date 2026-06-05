# Session Handoff — iter-23 (2026-06-05)

## North star
Make the SuperCPU as compatible and fast as possible. The live speed lever is the
HW-proven 3.0x "same-line alt-fire" cache speedup (commit `0deb093`), **blocked**
by cache "Bug 2": with `CACHE_READ_PATH=true` the SuperRAM cache serves a stale
byte on a bank-$20 read after the loader populates it, crashing Doom. Three prior
UNIT-bench fixes (FILL_TXMATCH iter-16, FILL_DATAVALID_GATE residual iter-18,
FILL_CANCEL_ON_WRITE iter-22) were all HW no-ops because the cpu_cache unit bench
can't model the real fill-fire / write / read ordering. iter-22 demanded a
**SYSTEM-level** repro. This session built it.

## What landed this session (iter-23)
**The first system-level cache-coherency bench where the REAL 65C816 executes a
real program through the real cpu_cache + scpu_async_bridge + bus arbitration +
buslogic + a behavioral SDRAM, with cache ON/OFF via one flag.** This is the
iter-22 deliverable.

Files (all under `sim/c64_reduced_harness/`):
- `c64_superram_coherency_tb.vhd` (NEW) — drives `c64_reduced_top_v2` with
  `TEST_ROM=1`; scoreboard + rich diagnostics (PC trace, cpuAddr-change monitor,
  SDRAM write-port monitor, external-name observers for emu_mode/cpuDi/cpuDo).
- `run_superram_coherency.sh` (NEW) — build+run; `CACHE_READ_PATH=0|1` env flag
  (patch#3 flips the RTL constant). `CACHE_READ_PATH=0` = sanity, `=1` = the test.
- `rom_loader_pkg.vhd` — `make_bug2_test_rom`: emu copy-stub @ $E000 relocates a
  NATIVE body to RAM $0800, which does CLC;XCE then long store/read to $20:00AE.
- `c64_reduced_top_v2.vhd` — SuperRAM-aware SDRAM write/read mux (was hardcoded
  bank $00), `SDRAM_BYTES=0x300000`, `TEST_ROM` generic.

### Three harness blockers found & fixed (in order)
1. **`clk_cpu` was unmapped** in the tb DUT port map -> defaulted '0' -> the 816 was
   never clocked (cpuAddr frozen $00:0000, emu='1' forever). Both prior v2 tbs
   leave it unmapped because they only test the loader path, not CPU execution.
   Fix: map `clk_cpu => clk` (passthrough, SCPU_MCP_ACTIVE='0' => clk_cpu = clk32).
2. **Native-mode ROM shadow**: after XCE, reads of $E000-$FFFF come from the
   bank-$00 SRAM ROM-shadow (`fpga64_buslogic.vhd:412`, gated `scpu_native_mode=1`)
   which the harness never populates (no kickstart MVN) => $00 = BRK, derailing into
   the $FF00 stub. Fix: run the native body from RAM ($0800, `cs_ramLoc`, not
   shadowed) via an emu copy-stub. (Earlier emu-only variant also works.)
3. **`scpu_rom_vis` patch (#4) was a no-op** — `supercpu_rom_vis` is an unused port
   in buslogic; the real reset-vector serving is via `cs_romLoc -> romData` (dprom),
   addressed `cpuAddr(14)&cpuAddr(12:0)` => $FFFC->offset $3FFC. (Patch left in; harmless.)

## Result (the finding)
Sanity AND the Bug-2 test both PASS — `witness[1] re-read = $4A` (coherent),
`SDRAM truth $20:00AE = $4A` — in **all four** combinations: {emu, native} x
{cache OFF, cache ON}. The store->delay->reread-same-address pattern is COHERENT
in-system; the write's invalidate works (tag_match=1 on the allocated line).

=> **In-system falsification** of Codex candidate (a) write/pending-fill race AND
(b) native long-store write-strobe addr/bank skew — *for this access pattern*.
Consistent with iter-18: Bug 2 is the fill-DATA-phase / ordering bug, not a simple
invalidate miss.

## The one remaining fidelity gap (-> next step)
`sdram_data_valid` is an input port of `fpga64_sid_iec` defaulting **'1'**, and the
harness top never drives it => `sdram_data_valid_sync` is stuck '1' =>
`FILL_DATAVALID_GATE` (true) is **neutered**: `rp_fill_fire = rp_fill_req AND '1'`,
so the fill fires immediately and **never goes pending**. The deployed HW residual
(cache=$00/SDRAM=$4A) is precisely a **fill-pending-across-the-write** window
(fill gated on real ~q5 read latency). The harness cannot exercise that window yet.

**NEXT (GHDL-first, concrete):** drive `sdram_data_valid` from the top to model the
real read-completion latency (assert ~3-5 clk32 after a CPU SuperRAM read issues,
matching `simple_sdram_model`'s 3-stage pipeline + the 1-flop sync), so the fill
defers. THEN craft the reproducing sequence:
- (a) write to a SuperRAM line whose fill is still pending (write within the
  pending window), and/or
- (b) back-to-back reads of two DIFFERENT SuperRAM lines so the 2nd fill latches
  the 1st read's `dout` (the iter-18 stale-dout mechanism).
Observe the built-in divergence detector `diag_mm_count/addr/cache/sdram`
(`fpga64_sid_iec.vhd:5178`, the same WD detector used on HW) via external names; a
HIT serving cache!=SDRAM => Bug 2 reproduced in-system, with the exact addr+bytes.

Real `sdram_pm.v` is Verilog => not usable in this mcode GHDL; model data_valid in VHDL.

## Status / housekeeping
- Bench is GREEN (RESULT: PASS, exit 0) for all four combos.
- MiSTer untouched this session (pure GHDL work). No HW deploy. Shipped RBF
  baseline unchanged (`CACHE_READ_PATH=false`, Doom-safe).
- Committed: the harness + test ROM + this finding (unpushed; pushes still gated).
- Lorenz / Doom regression status unchanged from `e6b3405` (last shipped: MVN/MVP
  fix, Lorenz 100% both modes).
