# sim/c64_reduced_harness — Phase 4 / Phase 4b reduced-system GHDL bench

Two GHDL benches live here:

- **Phase 4 (v1)**: `c64_reduced_top.vhd` + `c64_reduced_harness_tb.vhd`
  — instantiates the real `cpu_65c816` against a behavioral SDRAM/BRAM
  model. No `fpga64_sid_iec.vhd`.
- **Phase 4b**: `c64_reduced_top_v2.vhd` +
  `c64_reduced_harness_tb_v2.vhd` + stubs under `stubs/` +
  `rom_loader_pkg.vhd` — instantiates the **real**
  `C64_MiSTer/rtl/fpga64_sid_iec.vhd` with VHDL stubs for every Verilog
  child (`mos6526`, `sid_top`) and GHDL shims for the two VHDL files
  that cannot be parsed under `--std=08` (`cpu_6510`,
  `fpga64_rgbcolor`). Loads the stock C64 KERNAL+BASIC ROM from
  `C64_MiSTer/rtl/roms/std_C64.mif` so the BASIC boot path is exercised.

Run v1 via `./run_harness.sh` (or `.\run_harness.ps1`), run v2 via
`./run_harness_v2.sh` (or `.\run_harness_v2.ps1`).

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

After a successful run the `work/` directory (Phase 4 v1) or
`work_v2/` directory (Phase 4b) contains:

- `*_tb*.log` — full simulation transcript
- `*_tb*.fst` — FST waveform (GTKWave / Surfer / pywellen)
- `*.cf` / `*.o` — GHDL analyse/elaborate objects

The `work*/` contents are git-ignored per the bench's `.gitignore`.

## Phase 4b: real `fpga64_sid_iec.vhd` harness

Phase 4b replaces the behavioral memory/CPU stack with the real DUT,
so the bench exercises:

- sysCycle 32-phase bus arbitration (EXT / DMA / VIC / CPU slots)
- Turbo mode scheduling
- Real `cpu_cache` (8 KB direct-mapped with write-through)
- Real 64 KB dual-port BRAM (`c64_ram64k`)
- Real `fpga64_buslogic` (ROM/RAM/IO map, bank switching)
- Real `video_vicII_656x` (pixels go to the void, but bus-arb logic runs)
- Real 65C816 wrapper (`cpu_65c816` → `P65C816`)
- KERNAL+BASIC served from the stock C64 ROM via
  `C64_MiSTer/rtl/roms/std_C64.mif` parsed at elaboration time

### Files

| File | Role |
|---|---|
| `stubs/mos6526_stub.vhd` | VHDL stub matching Verilog `mos6526.v` port list |
| `stubs/sid_top_stub.vhd` | VHDL stub matching SystemVerilog `sid_top.sv` port list |
| `stubs/cpu_6510_stub.vhd` | GHDL shim (real file uses `work.T65` direct-instantiation syntax that GHDL --std=08 rejects) |
| `stubs/fpga64_rgbcolor_stub.vhd` | GHDL shim (real file's case-on-unsigned lacks `when others`) |
| `stubs/reu_stub.vhd` | Placeholder (not instantiated inside fpga64_sid_iec — reu.v is at the c64.sv level) |
| `stubs/sdram_stub.vhd` | Placeholder (not instantiated inside fpga64_sid_iec — sdram.v is at the c64.sv level) |
| `stubs/cartridge_stub.vhd` | Placeholder (not instantiated inside fpga64_sid_iec) |
| `stubs/c1351_stub.vhd` | Placeholder (not instantiated inside fpga64_sid_iec) |
| `rom_loader_pkg.vhd` | Parses `.bin` / `.mif` KERNAL+BASIC ROMs at elaboration |
| `c64_reduced_top_v2.vhd` | Top: real fpga64_sid_iec + SDRAM model + PRG loader + ROM loader |
| `c64_reduced_harness_tb_v2.vhd` | Testbench: scenarios A/B/C/D/E/F/G |
| `run_harness_v2.sh` / `.ps1` | GHDL runner (patches fpga64_sid_iec into `build_staging/`, analyzes everything, runs) |
| `build_staging/fpga64_sid_iec.vhd` | Auto-generated by the runner. Copy of the real file with two minimal sim-only patches (see below). Never committed. |

### GHDL workarounds applied

The following issues were discovered and worked around without
modifying any file under `C64_MiSTer/rtl/`:

1. **`fpga64_rgbcolor.vhd`** — `case index is ... when X"0" .. X"F" ...`
   lacks `when others`. Under `--std=08` with `unsigned(3 downto 0)`,
   strict VHDL-2008 requires `when others` to cover 'U','X','Z' etc.
   *Fix*: analyze `stubs/fpga64_rgbcolor_stub.vhd` *instead of* the real
   file. The stub has the same port list and a black-output arch.

2. **`cpu_6510.vhd`** — line 58 has `cpu: work.T65` which is VHDL-87
   "component-by-name" syntax. VHDL-93/08 requires `cpu: entity work.T65`
   or a `component T65` declaration. *Fix*: analyze
   `stubs/cpu_6510_stub.vhd` instead (the 65C816 is the active CPU so
   the 6510 body is never executed).

3. **`fpga64_sid_iec.vhd` line ~2580** — `case turbo_speed is
   when "00" .. "11" end case;` covers all 4 std_logic_vector(1 downto 0)
   values but lacks `when others`. Same VHDL-2008 strictness as (1).
   *Fix*: runner copies the file to `build_staging/` and injects
   `when others => turbo_m <= "000";` via `sed` / PowerShell regex.

4. **`fpga64_sid_iec.vhd` line ~689** — `preCycle <= sysCycleDef'succ(preCycle);`
   followed by an `if preCycle = high then preCycle <= low; end if;`
   guard. GHDL evaluates the RHS of the first assignment eagerly, so
   when `preCycle = high` the `'succ` raises a bounds error even
   though the second assignment would overwrite it. *Fix*: the runner
   rewrites the process body in the staging copy to flip the order
   (`if high then low; else succ(preCycle); end if;`).

Both staging patches are applied at the start of every run. The real
files under `C64_MiSTer/rtl/` are untouched.

### Scenarios

| Phase | What it does | Real-ROM required? |
|---|---|---|
| A | Soft CPU-liveness check (20 000 cycle warm-up after ROM load) | no |
| B | Scripted PRG load at $0801 with BASIC link-byte header | no |
| C | Immediate SDRAM-probe verify of payload | no |
| D | +2000 cycles + re-verify (catches post-load wipe) | no |
| E | Second PRG load at $1001 (sysCycle slot-gating stress) | no |
| F | 50 000-cycle wait + re-verify (BASIC auto-RUN window) | yes |
| G | Third PRG load at $2001 mid-execution | no |

Phase F is conditional on `status_rom_found='1'`. Since the in-repo
`std_C64.mif` is always present, Phase F runs by default.

### Verifying stub ↔ Verilog port match

The stubs in `stubs/` were authored by reading the `component`
declaration blocks inside `fpga64_sid_iec.vhd` directly (lines 602-666
for `sid_top` and `mos6526`). That component declaration is the
VHDL-side "contract" that the Verilog module must satisfy in the real
build, so reproducing it exactly guarantees our stubs compile against
the real instantiation code.

For the placeholder stubs (`reu_stub`, `sdram_stub`, `cartridge_stub`,
`c1351_stub`) the port lists were read from the `module ... (...);`
headers in the respective `.v` files. They are NOT referenced by any
source in the current Phase 4b analyze order because the real modules
are instantiated at the `c64.sv` level, not inside `fpga64_sid_iec`.

### Running

```bash
cd sim/c64_reduced_harness
./run_harness_v2.sh            # default --stop-time=5ms, ~20 s wallclock
STOP_TIME=10ms ./run_harness_v2.sh  # longer run
```

Windows:

```powershell
cd sim\c64_reduced_harness
.\run_harness_v2.ps1
.\run_harness_v2.ps1 -StopTime 10ms
```

Expected PASS output (abbreviated):

```
==> Analyze (Phase 4b)
    ...P65816_pkg.vhd
    ...P65C816.vhd
    ...cpu_65c816.vhd
    ...cpu_6510_stub.vhd
    ...fpga64_rgbcolor_stub.vhd
    ...mos6526_stub.vhd
    ...sid_top_stub.vhd
    ...c64_ram64k.vhd
    ...fpga64_buslogic.vhd
    ...video_vicII_656x.vhd
    ...build_staging/fpga64_sid_iec.vhd  (patched)
    ...rom_loader_pkg.vhd
    ...c64_reduced_top_v2.vhd
    ...c64_reduced_harness_tb_v2.vhd
==> Elaborate
==> Run (stop-time=5ms)
rom_loader: found=true src=rtl/roms/std_C64.mif
==== Phase A: CPU liveness check ====
==== Phase B: scripted PRG load at $0801 ====
==== Phase C: verify payload (SDRAM probe) ====
...
==== Phase G: ioctl download DURING CPU execution ====
==== SUMMARY: pass=84  fail=0 ====
c64_reduced_harness_tb_v2: PASS
RESULT: PASS
```

### Known limitations

- **Phase A soft**: the CPU does not necessarily advance
  `dbg_cpu_addr` from $0000 during the 20 000-cycle ROM-load window
  because reset is held while the c64rom_wr handshake is still
  streaming. Phase A is a NOTE-level diagnostic, not a hard fail.
- **Chargen blank**: we cannot load `chargen.mif` without modifying the
  RTL to add a write port.
- **SCPU kickstart bypassed**: `supercpu_rom='0'`, so the kickstart
  path is not exercised. This matches how `c64.sv` runs when the ROM
  OSD option is off.
- **SDRAM probe vs BRAM check**: the scoreboard verifies the SDRAM
  side of the loader path. For a complete check a future iteration
  should read through the CPU bus by stepping `dbg_cpu_addr` and
  watching `dbg_data_in`.
- **CIA1 stub returns $FF**: "no keys pressed". Any BASIC auto-RUN that
  waits for keyboard input will hang at the READY prompt. The
  inj_meminit path is independent of keyboard state, so this does not
  affect Phases B-G.
- **No ioctl_index=$81 REU loading**: the REU path is not wired. REU
  testing needs a Phase 4c variant that instantiates `c64.sv` instead.
