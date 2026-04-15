# sim/c64_reduced_harness — Phase 4 reduced-system GHDL bench

A GHDL-only bench that exercises the real 65C816 CPU core against a
reduced behavioral model of the MiSTer C64 memory system. Sits one
layer above the Phase 2 `prg_loader_tb` narrow bench and one layer
below a hypothetical "full `fpga64_sid_iec.vhd` in simulation" bench.

## Why this bench exists

The Phase 2 narrow bench at `sim/prg_loader_tb/` models the
`inj_meminit` + `bram_invalidate` + `cache_flush` + cache-fill-gate
semantics behaviorally and PASSES 54/54 checks. The hardware PRG-load
symptom ("PRG loads, then memory seems to reset") is therefore NOT
explained by anything at that abstraction level.

Phase 4 raises the fidelity by:

- Instantiating the **real** `cpu_65c816` wrapper (and the real
  `P65C816` CPU core + MCode + ALU + AddrGen) so the CPU side of the
  bus is no longer modelled, it is executed.
- Adding a pipelined SDRAM model with 2-stage read latency for bank
  $00 and 3-stage for SuperRAM, matching the pipeline comment in
  `fpga64_sid_iec.vhd` at line ~385.
- Adding a 1-cycle-latency cache stub with the exact `not
  bram_invalidate` fill gate that the real `cache_fill_we` uses at
  `fpga64_sid_iec.vhd` ~line 1515.

## Why it does NOT instantiate the real `fpga64_sid_iec.vhd`

The task brief acknowledges this path. `fpga64_sid_iec.vhd` depends
on Verilog children that GHDL cannot analyze:

- `mos6526.v` (CIA)
- `sid_top` (SID top, from `rtl/sid/`, Verilog)
- `reu.v` (REU)
- `sdram.v` (SDRAM controller)
- `cartridge.v` (cartridge / expansion port)
- plus various `sys/*` modules from the MiSTer framework

Providing VHDL stubs for all of those would be a much larger task
than the Phase 4 skeleton requirement. Instead we build a custom
reduced top (`c64_reduced_top.vhd`) that instantiates the real CPU
core and models the memory subsystem.

If a future iteration needs cycle-accurate VIC/CIA interaction, the
path forward is to author VHDL behavioral stubs for each Verilog
child and drop them into the `sources` list — the runner scripts
already support per-file analysis order.

## Files

| File | Purpose |
|---|---|
| `c64_reduced_top.vhd` | Reduced C64 system: real CPU + behavioral memory |
| `c64_reduced_harness_tb.vhd` | Testbench: reset, PRG-load stimulus, scoreboard |
| `run_harness.ps1` | Windows PowerShell runner (3-step GHDL flow) |
| `run_harness.sh` | Bash runner (WSL / Linux / macOS) |
| `README.md` | This file |

Also depends on (not duplicated here):

- `C64_MiSTer/rtl/65C816/*.vhd` — real CPU core
- `C64_MiSTer/rtl/cpu_65c816.vhd` — real CPU wrapper
- `sim/prg_loader_tb/prg_loader_pkg.vhd` — shared helpers (byte arrays,
  expected BASIC pointers, hex formatters)
- `sim/common/memory_models/simple_sdram_model.vhd` — shared SDRAM
  behavioral model (created as part of Phase 3's common-utils tree)

## What the reduced top models

The `c64_reduced_top.vhd` wrapper includes:

- Real `cpu_65c816` instance, enable held continuously high. There is
  no VIC/CPU time slice arbitration — Phase 1 already ruled out
  CE-gap bugs for the native-switch / REP / immediate-width paths.
- 64 KB BRAM for bank $00 with a 256-entry page-valid bitmap.
- Behavioral SDRAM with 2-stage / 3-stage read latency pipeline.
- `inj_meminit` state machine (faithful reimplementation of
  `c64.sv` lines ~1396-1443).
- `bram_invalidate` level = `ioctl_download or inj_meminit`, with the
  registered rising-edge pulse driving `cache_flush` (mirrors
  `fpga64_sid_iec.vhd` lines ~1481-1489).
- 1-cycle-latency cache stub with the `not bram_invalidate` fill
  gate (mirrors `cache_fill_we` at `fpga64_sid_iec.vhd` ~line 1515).
- Boot stub at BRAM $0400: `NOP; NOP; JMP $0400` so the CPU has
  something legal to execute after reset, independent of BASIC/KERNAL.
- Reset vector $FFFC/$FFFD pointing at $0400.

## What it does NOT model

- KERNAL / BASIC / CHARGEN ROMs (reset jumps to the bespoke $0400
  boot stub instead of the KERNAL reset routine)
- VIC-II, CIA1/2, SID, cartridge, IEC, REU, tape
- `sysCycle` bus arbitration (EXT/DMA/VIC/CPU 32-phase)
- Turbo-mode scheduling / `superram_enable_delay`
- BASIC auto-RUN / `RUN` / `SYS` keyboard handling (there is no
  keyboard; software cannot launch the loaded PRG)
- Write buffer drain, SCPU ROM stub, native-mode vector SRAM,
  `$D07E`/`$D07F` register disable, `$D078` flush register

## Scenario

Currently implements a single scenario:

- **Phase A**: reset + 500-cycle warm-up, confirm CPU is executing
  the boot stub at $0400..$0404.
- **Phase B**: scripted PRG load at $0801 (8-byte payload
  `LDA #$42; STA $0400; JMP $0800`).
- **Phase C**: after `inj_meminit` drops, immediately read back
  every payload byte via the combinational BRAM probe and verify
  all BASIC zero-page pointers ($2B/$2C, $2D/$2E, ..., $AE/$AF).
- **Phase D**: advance simulation another 2000 cycles and re-verify
  the payload + pointers. Catches the "bytes correct immediately but
  wiped later" symptom — the CPU is still spinning on the boot stub
  at $0400 during Phase D so any corruption of $0801..$0808 is from
  the cache/BRAM path itself, not from the loaded PRG executing.

A single elaboration can host additional scenarios later; see "Next
iteration" below.

## Running

### Windows (PowerShell)

```powershell
cd sim\c64_reduced_harness
.\run_harness.ps1
```

### WSL / Linux / macOS

```bash
cd sim/c64_reduced_harness
./run_harness.sh
```

Override stop-time with `-StopTime 20ms` (ps1) or
`STOP_TIME=20ms ./run_harness.sh` (sh). The default 10 ms is enough
for reset + PRG load + 2000 post-load CPU cycles.

Expected PASS output (abbreviated):

```
==> Analyze
    .../P65816_pkg.vhd
    .../P65C816.vhd
    .../cpu_65c816.vhd
    .../prg_loader_pkg.vhd
    .../simple_sdram_model.vhd
    .../c64_reduced_top.vhd
    .../c64_reduced_harness_tb.vhd
==> Elaborate
==> Run (stop-time=10ms)
==== Phase A: boot-stub warm-up (500 cycles) ====
A: CPU PC in boot-stub range ($0400)
==== Phase B: scripted PRG load at $0801 ====
B: inj_end = $0809
==== Phase C: verify payload + BASIC pointers ====
C payload[0]: OK  $00:0801 = $A9
...
C LEND_HI($AF): OK  $00:00AF = $08
==== Phase D: run 2000 extra cycles + re-verify ====
D payload[0]: OK  $00:0801 = $A9
...
==== SUMMARY: pass=41  fail=0 ====
c64_reduced_harness_tb: PASS
RESULT: PASS
```

## Interpreting failures

| Symptom | Likely cause |
|---|---|
| `ghdl -a` fails on one of the CPU core files | Path to `C64_MiSTer/rtl/65C816/*.vhd` is wrong; check `$rtl816` in the runner |
| `ghdl -e` fails with "no default binding for component" | A VHDL file was forgotten from the `sources` list; re-check the list matches the entity name |
| `ghdl -r` exits 2 with "access beyond bounds" | The SDRAM model was asked for an out-of-range address; increase `SDRAM_BYTES` generic |
| Phase A: CPU PC NOT in boot-stub range | Reset vector fetch failed or the CPU is stuck in an illegal state; check `dbg_pc` / `dbg_ir` in the FST waveform |
| Phase C passes, Phase D fails | "Bytes correct immediately but wiped later" — **this is the bug Phase 4 was built to reproduce**. Inspect `cache_valid_r`, `bram_pgvalid`, and `bram_invalidate` in the waveform around the 2000-cycle window |
| Phase C payload FAILs | `inj_meminit` or the io_cycle write path is broken; check `io_bram_we_pulse`, `ioctl_load_addr`, `inj_end` in the waveform |

## Known limitations

- The reduced top holds `cpu_enable` high continuously. The real
  system gates it on sysCycle CPU0..CPUF. If the production bug is
  sensitive to the *schedule* of enables (e.g. a race between
  `io_cycle` writes in EXT slots and `enableCpu` in CPU slots), this
  bench will not reproduce it.
- There is no keyboard / OSD / BASIC. The CPU cannot RUN or SYS the
  loaded PRG. Scenarios that need the loaded code to actually execute
  must manually steer `dbg_pc` / use a "forced reset vector" approach
  (not yet wired into the harness).
- Cache lines are byte-wide (direct mapped, 256 entries, 1 byte per
  line). The real cache is 1024 × 8 bytes (8 KB) with 64-bit lines —
  but the stub's topology is not the bug class we are chasing here.
- The SDRAM model is a flat byte array with no refresh, no tRCD, no
  burst behavior. The only thing that matters is the read latency.

## Next iteration

In priority order, if this bench PASSES but the real hardware bug
still isn't understood:

1. **Add a "RUN-like" scenario**: patch the reset vector to `$0801`
   after the PRG load completes, then run the CPU for N cycles and
   watch for the CPU itself writing over the loaded payload
   (e.g., BASIC-style NEW clearing $0801/$0802).
2. **Add a cache-line-collision scenario**: load a PRG at $0801 and
   then a second PRG at a cache-colliding address ($08 vs $18 if
   the cache were 256B = index-by-low-byte), and verify the first
   is not evicted/corrupted.
3. **Add a sysCycle gate model**: introduce a 32-phase enable on
   `cpu_enable` so the CPU only fires in CPU0..CPUF slots. Then
   introduce `io_cycle` writes in EXT slots and watch for race
   conditions.
4. **Phase 4b: real `fpga64_sid_iec.vhd` instantiation**: author
   VHDL behavioral stubs for every Verilog child
   (`mos6526_stub.vhd`, `sid_top_stub.vhd`, `reu_stub.vhd`,
   `sdram_stub.vhd`, `cartridge_stub.vhd`) and list them first in
   the sources. Every stub only needs the entity interface — port
   map, no behavior. This gives us the real bus arbitration
   (`sysCycle` / `enableCpu`) + real cache (`cpu_cache`) + real
   bus logic (`fpga64_buslogic`) without the Verilog dependency
   problem.

Option 4 is the true "reduced `fpga64_sid_iec` harness" the task
description described. It was deferred for this first iteration
because authoring ~5 stub entities that analyze cleanly against
the real VHDL instantiations is a multi-hour task in itself, and
the task brief explicitly said a "working skeleton that runs" is
acceptable for Phase 4.

## Output files

After a successful run the `work/` directory contains:

- `c64_reduced_harness_tb.log` — full simulation transcript
- `c64_reduced_harness_tb.fst` — FST waveform (inspect with
  GTKWave / Surfer / pywellen)
- `*.cf` / `*.o` — GHDL analyse/elaborate objects

The `work/` contents are git-ignored per the bench's `.gitignore`.
