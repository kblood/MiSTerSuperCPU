# Option C: drop VIC/EXT throttle when SCPU is running in SuperRAM

**Goal.** Lift the CPU's effective rate from ~4 MHz to ~16-20 MHz on
SuperRAM-resident code by allowing `enableCpu_816` to fire on every
CPU/VIC/EXT slot while the CPU is fetching from bank ≠ $00 and not
touching $D000-$DFFF I/O. Bank $00 (motherboard RAM) and I/O still
go through the existing 4-MHz Turbo-4x arbitration, so VIC raster
fetches, CIA timing, and badline cycles remain unchanged.

This mirrors what a real CMD SuperCPU does in Optimization Mode 2:
the 65C816 detaches from the slow C64 bus when running entirely in
fast SRAM.

## Why this gain is available

Today's frame (32 cycles of `clk_sys` = 32 MHz):

```
sysCycle  EXT0..3  DMA0..3  EXT4..7  VIC0..3  CPU0  CPU1  CPU2  CPU3  CPU4 .. CPUF
                                              ^                     ^         ^
                                              turbo_m(0)            turbo_m(1) turbo_m(2)/CPUC
```

`fpga64_sid_iec.vhd:2610-2614`:
```vhdl
cpu_cyc <= '1' when
    (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1') or
    (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1') or
    (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1') or
    (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1')) else '0';
```

At Turbo 4x (`turbo_m="111"`) this fires at CPU0/CPU4/CPU8/CPUC =
**4 enables per μs = 4 MHz effective**.

The other 28 slots are unused by the CPU. Of those:
- VIC0-3 (4 slots): always reserved for VIC's bank-$00 fetches (BRAM
  port). If the CPU is NOT touching bank $00, VIC's BRAM port and
  the CPU's SDRAM port are physically independent — no conflict.
- EXT0-3, EXT4-7 (8 slots): partially used for refresh + cartridge.
  `rfsh_cycle` is two bits that gate this; many cycles are idle.
- DMA0-3 (4 slots): only used while `dma_active='1'`. Idle by default.
- CPU1-3, CPU5-7, CPU9-B, CPUD-F (12 slots): unused.

Total reclaimable when CPU is in SuperRAM and refresh/DMA idle: up
to 24-28 slots = **24-28 MHz effective**.

We target a conservative subset: **16 CPU slots + 4 VIC slots = 20
slots → 20 MHz effective**.

## Mechanism — single new `cpu_cyc` term

Introduce `scpu_fast_path` — a 1-bit signal asserted when:
- `supercpu_en = '1'`
- CPU address is bank ≠ $00 (i.e., `supercpu_bank /= x"00"`)
- CPU address is NOT in I/O ($D000-$DFFF)
- DMA is idle (`dma_active = '0'`)

When `scpu_fast_path = '1'`, set `cpu_cyc <= '1'` for **every**
sysCycle in CPU0..CPUF and VIC0..VIC3. Existing terms remain so
bank-$00 / I/O accesses still get the 4-MHz path.

```vhdl
-- Conservative version: fire on all 16 CPU slots + 4 VIC slots when
-- the CPU is executing in SuperRAM and not touching I/O.
scpu_fast_path <= '1' when supercpu_en = '1'
                       and supercpu_bank /= x"00"
                       and not_in_io
                       and dma_active = '0' else '0';

cpu_cyc <= '1' when
    -- existing 4-MHz path (unchanged)
    (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1') or
    (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1') or
    (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1') or
    (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1')) or
    -- new fast-path: any CPU/VIC slot while in SuperRAM
    (scpu_fast_path = '1' and
     (sysCycle >= CYCLE_VIC0 and sysCycle <= CYCLE_CPUF))
    else '0';
```

That's the entire core change — one term, one signal definition.
20 slots × 32 MHz/32 = **20 MHz effective**. Symmetric with the real
SuperCPU's behavior.

## Risks

### Risk 1: P65C816 timing closure
**Severity: high.** The SDC currently grants `*P65C816:cpu|*` a
multicycle-2 setup budget (C64.sdc:26-29). That budget reflects "CPU
enable fires at most every 2nd clk_sys cycle". Fast-path enables on
*consecutive* clk_sys edges (CPU0→CPU1, etc.), so the multicycle-2
becomes multicycle-1 and the worst path slips.

**Mitigation A:** keep CPU advances at most every 2nd clk_sys cycle
by alternating slots (e.g., only even CPU slots fire fast-path). That
halves the gain to 10 MHz but preserves multicycle-2.

**Mitigation B:** tighten the P65C816 critical path (decoder/ALU). The
worst path on `perf-experiments` was SDRAM→P[1] (Z-flag). Bypassing
that into a register before the flag-update logic would buy back
multicycle.

**Mitigation C:** drop multicycle-2 and run `quartus_sta` to see
what slack is left. If clk_sys still closes at TNS=0, no further
work needed. (Cheapest experiment — 15 sec STA pass on the existing
netlist.)

Decision: **start with Mitigation C** — re-run STA with the SDC
constraint removed and see whether the existing netlist closes at 32
MHz with single-cycle CPU enables. If it does, no RTL change beyond
the cpu_cyc term. If not, choose A or B.

### Risk 2: SDRAM throughput
**Severity: med.** SuperRAM lives in SDRAM, accessed via a 3-stage
pipeline running at clk64 (`project_sdram_pipeline.md` if it exists,
or check `sdram.v`). Throughput limit: one access per 3-4 clk64
cycles = ~16-21 MHz. If CPU asks for SDRAM data every clk_sys cycle,
the pipeline will stall.

The natural backpressure is `cpu_cyc` itself — `enableCpu_816` is
derived from `cpu_cyc_s(1)`, a 2-stage shift register. If we fire
cpu_cyc every cycle but SDRAM can't keep up, enableCpu still advances
the CPU but `cpuDi` returns stale data → wrong instruction → wedge.

**Mitigation:** gate `scpu_fast_path` on SDRAM ready signal. Add a
`sdram_busy` input from the SDRAM controller; suppress fast-path
enables while busy. The CPU stalls naturally.

### Risk 3: SCPU EPROM accesses
**Severity: low.** Banks $F8-$FF read the SCPU EPROM stub. Today the
stub returns from a small ROM (see `project_scpu_eprom_mirror_F8FF.md`
in memory). When CPU runs in $F8 bank, `supercpu_bank /= x"00"` is
true → fast-path fires. The ROM stub is BRAM-backed (single-cycle),
so this is fine — but worth verifying that bank $F8-$FF read mux is
fast enough.

### Risk 4: Cycle-counted code breaks
**Severity: low for SuperCPU software.** Real SuperCPU programs are
expected to handle async CPU↔C64-bus timing — that's the whole point
of optimization modes. The 6510-emulation path (`supercpu_en='0'`)
is untouched, so vanilla C64 programs (including Lorenz CPU tests in
t65 mode) see no change.

### Risk 5: Interrupt latency
**Severity: low.** IRQ entry / RTI is a CPU-internal sequence; fast-
path just makes it execute in 1/5 the wall time. The $FF00 ack stub
and $FFEE/$FFEF native vector path (commits `db149d6`, `5b557da`) are
all in banks ≥ $F0 → fast-path applies to them. Good — interrupts
will dispatch *faster*, not slower.

## Test plan

Pre-condition: branch `vanilla-cpu-swap` (current v356 tip
`e845b20`). Land Option C as a new feature branch
`perf-option-c-supercpu-fast`.

| Step | What | Pass criterion | Why |
|------|------|---------------|-----|
| 1 | STA pass with SDC multicycle removed | TNS=0, clk_sys slack > 0 | Settles risk #1 cheaply before any RTL change |
| 2 | RTL diff — add `scpu_fast_path` + extra `cpu_cyc` term | Synthesizes cleanly, no warnings on `cpu_cyc` cone | Smallest possible change |
| 3 | GHDL bench `sim/p65c816_tb` | Existing tests pass | CPU still semantically correct |
| 4 | Synthesize & STA | Slack ≥ 0 on all clocks | Catch timing regressions |
| 5 | HW deploy to `/media/fat/_Test/` | Boots to KERNAL READY | Sanity smoke |
| 6 | Lorenz disk1 t65 mode 32 min | `andix - ok` reached (matches v356 baseline) | 6510 path unchanged |
| 7 | Lorenz disk1 scpu mode 32 min | Same final test as v356 baseline `tools/lorenz_run/scpu_2026-05-19_v356_baseline/` | SCPU semantics unchanged |
| 8 | SCPU speed bench `tools/run_scpu_speed_bench.py` | Cycle count ≤ baseline/4 (4× speedup) | **The actual measurement.** |
| 9 | Doom v356 PLAY recipe `tools/doom_v356_PLAY.py` | Reaches 3D rendered E1M1 with HUD | Doom render path unaffected |
| 10 | Wolf3D v356 menu nav | Reaches Level 1 starting room | Wolf3D render path unaffected |

If steps 1-7 pass but step 8 shows ≤2× speedup, fast-path isn't firing
often enough — instrument `scpu_fast_path` on a UART column and
check what fraction of frames it's high. If steps 9-10 fail, fast-
path is too aggressive — bisect by gating fast-path on individual
slot ranges (e.g., CPU only, not VIC).

## Rollback

Behind a build-time `SCPU_FAST_PATH` macro / `generic` so a single
flag flip reverts to v356 behavior. Don't put this behind a runtime
config bit (no need — it's safe-by-construction for SCPU code, and
adding a runtime gate burns logic for no benefit).

## What this does NOT do

- Does not lift bank-$00 code to 20 MHz. Bank-$00 (motherboard RAM)
  still goes through 4-MHz arbitration so VIC raster + badline
  semantics stay correct.
- Does not lift I/O ($D000-$DFFF) to 20 MHz. CIA/VIC/SID still see
  the same 1-MHz access pattern as today.
- Does not change the C64-side cycle counter for software that does
  `LDA $D012; DEX; BNE` raster sync. If such code runs from SuperRAM,
  it loops faster — but $D012 itself is still I/O so the access
  cadence stays 1 MHz. Net effect: software polls $D012 more times
  per raster line. Should be benign.
- Does not implement WriteSmart mirroring (real SuperCPU writes to
  SuperRAM also propagate to bank $00 in some optimization modes).
  We already don't mirror; software that needs $00↔SuperRAM coherence
  uses CPU long stores explicitly.

## Expected outcome

Doom on v356 currently runs the JIT recompiler main loop at the
observed ~3 fps (UART F counter +3/sec, memory file
`project_doom_v356_PLAYABLE.md`). The recompiler is bank $20-$2C
code → fast-path fires → 5× speedup → **~15 fps**, comparable to
VICE's xscpu64.

Lorenz scpu mode runs all in bank $00 or via I/O probes → no speedup,
same wall-clock. (Good — confirms semantics are unchanged.)

SCPU regtest speed bench currently shows 1× (4 phases all count
$0001DC, per `project_scpu_register_implementation_status.md`). If
the bench runs from bank $00, we still see 1×; if it runs from
SuperRAM, we expect ~5×. Worth checking the PRG layout first.

## Open questions

1. Does the SCPU speed bench actually run from SuperRAM, or from bank
   $00? Check before relying on it as a success oracle.
2. What is the actual `sdram_busy` signal name in `sdram.v`?
3. Is `not_in_io` cheap to compute combinationally, or does it need a
   registered version? CPU address bits $14:$12 ≠ $D needed.
4. Does the existing `cpu_cyc_s(0)` → `cpu_cyc_s(1)` shift register
   need lengthening when cpu_cyc fires every cycle, to maintain SDRAM
   pipeline alignment?
