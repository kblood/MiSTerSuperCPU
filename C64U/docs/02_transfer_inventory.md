# What transfers from MiSTer SuperCPU work to U64

## Direct file transfers (likely no changes)

| File / Dir | Lines | Purpose |
|---|---|---|
| `C64_MiSTer/rtl/65C816/` | ~3000 | 65C816 CPU core (P65C816) — self-contained, no MiSTer deps |
| `C64_MiSTer/rtl/cpu_cache.vhd` | ~400 | 8KB SCPU cache + 32KB BRAM page-valid tracking |
| `C64_MiSTer/rtl/roms/scpu64.mif` | 64KB binary | SCPU ROM (SOCI/SINGULAR open ROM, identical to VICE) |
| `tools/lorenz/` | — | Lorenz CPU test suite disks (.d64) |
| `games/C64/wolf3d/` | — | Wolf3D loader + REU image (for regression) |
| `doom.reu`, `loader.prg` | — | Doom test assets |
| `crt/*.crt`, `crt/*.mgl` | — | Compiled test cartridges |

## Transfer with adaptation (concept transfers, code adapts)

| Concept | MiSTer file | What stays | What changes |
|---|---|---|---|
| Diagnostic UART | `fpga64_sid_iec.vhd` UART block | Output format (`F:PC:P:V:...`) | UART pin mapping to U64 hardware |
| SCPU register decode | `fpga64_sid_iec.vhd` $D07x/$D0Bx | Register semantics (verified vs VICE) | Bus integration |
| IRQ stub at $00:$FF00 | `fpga64_sid_iec.vhd` `cpuDi` mux | The byte sequence (the v342 NOP-out-D01A fix) | Mux infrastructure |
| Bootmap intercept | `fpga64_buslogic.vhd` `scpu_bootmap` | Concept of overlaying $E000-$FFFF with ROM | Where the overlay sits in U64 |
| Native vectors $FFE0-$FFEF | `fpga64_sid_iec.vhd` `scpu_native_vec` | Writable vector array | Mux infrastructure |
| REU loader recipe | `tools/doom_v342_test.py` | MGL pattern, mtype.py keystrokes, loader.prg | SSH/deploy mechanism (Ultimate has REST API) |

## Tooling transfers (just needs deploy-driver swap)

| Tool | Purpose | Adaptation needed |
|---|---|---|
| `tools/mister_debug.py` | Deploy/screenshot/UART | Replace with U64 REST API client (already partial in `docs/ultimate64_agent.md`) |
| `tools/lorenz_run.py` | Lorenz regression harness | Swap MGL load + screenshot path |
| `tools/wolf3d_v342_test.py` | Wolf3D test recipe | Re-target to U64 disk loading |
| `tools/vice_*.py` | VICE differential oracle | No change — VICE is platform-independent |
| `tools/mtype.py` | Virtual keyboard injection | U64 has equivalent via REST `keyboard:type` |

## Knowledge that transfers (documentation/methodology)

- The full IRQ wedge investigation (v340j → v342) and what each diagnostic
  byte means — see `MEMORY.md` entries.
- The "I/O decode must respect SCPU bank" insight (commit b2d44d1).
- The bug-classification methodology (`docs/debug_methodology.md`).
- The mtype.py 6s setup penalty / batch-per-line pattern.
- The Lorenz suite cycle position (verified the v342 regression test).
- The bug list in `docs/supercpu_feature_status.md`.
- The fact that wolf3d needs the bootmap+kickstart path (not naive ROM
  mirroring) — proven by JML-target analysis of wolf3d.reu.

## MiSTer-specific, NOT transferable

- `fpga64_sid_iec.vhd`'s `sysCycleDef` state machine (EXT/DMA/VIC/CPU
  slot arbitration — fundamentally tied to 32 MHz clk / 1 MHz CPU
  ratio).
- `fpga64_buslogic.vhd`'s vanilla-mode bank decode (specific to MiSTer
  SDRAM mux).
- `c64.sv` top-level (MiSTer framework: HPS_IO, sys/ instantiation,
  hardware config bytes 0..10 mapping).
- The SDRAM bit-24 byte-pack trick (REU + SuperRAM share SDRAM region).
- The MiSTer-cmd pipe (`/dev/MiSTer_cmd`) and `mbc load_rom` PRG loading.
- The 30-40 min Quartus build cycle vs U64's potentially-faster toolchain.

## Time investment recovery estimate

If the U64 host core is buildable and has a CPU integration point similar
in shape to MiSTer's, we estimate:

- **First U64 bitstream with vanilla CPU**: 1-2 days (toolchain setup,
  understand build flow).
- **65C816 CPU swap into U64 bus**: 3-5 days (adapt bus interface,
  verify Lorenz vanilla mode passes).
- **SCPU register decode + ROM mapping**: 2-3 days (port `$D07x`,
  bootmap, $FF00 stub).
- **REU loader works**: 1 day (mostly tool adaptation, the loader.prg
  itself doesn't change).
- **Doom renders**: ~1-2 days if no new bugs.
- **Wolf3D renders**: depends on whether U64's bus architecture makes
  banks $F0-$FE accessible for kickstart copy-to-RAM.

vs. continuing MiSTer:

- **Fix MiSTer kickstart wedge**: unknown, was estimated multi-day in
  the v343 retry plan.
- **Implement 20 MHz CPU clock on MiSTer**: probably 1-2 weeks (touches
  bus arbiter, SDRAM pipeline, every I/O cycle).

The break-even is unclear without first seeing the U64 core structure.
