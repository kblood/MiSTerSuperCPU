# C64 Ultimate (U64) Investigation — Overview

## Why we're considering a pivot

After ~6 months of SuperCPU work on the MiSTer C64 core, the practical
ceiling we've hit is **CPU clock speed**, not correctness:

- Doom now renders the id Software credits screen (v342, 2026-05-14) — proving
  the 65C816 core, IRQ stub, memory mapping, REU loader path, and JIT
  recompiler dispatch all work end-to-end.
- Lorenz CPU test suite passes on both vanilla 6510 mode and SuperCPU
  mode through 30 min of cycling.
- But everything runs at **1 MHz effective CPU clock** (4 MHz with smart
  turbo). Real CMD SuperCPU is 20 MHz, and Doom needs that to be playable.

The MiSTer C64 core's clocking model is fundamentally designed around the
1 MHz CPU + VIC-II raster slot arbitration. Decoupling the CPU clock from
the VIC-II clock for a 20× speedup is non-trivial — it would touch
`fpga64_sid_iec.vhd`'s bus arbiter, SDRAM pipeline timing, I/O cycle
stretching, and the existing turbo path that gives CPU extra cycles from
EXT slots.

## Why the Ultimate

The **Commodore 64 Ultimate / Ultimate 64 (U64)** hardware:
- FPGA-based C64 (not cartridge — full standalone C64 replacement).
- Designed by Gideon Zweijtzer.
- Built-in cartridge slot, IEC bus, audio/video, USB.
- Has a "turbo" mode that's reportedly more flexible than MiSTer's,
  reaching ~48 MHz 6510-equivalent on some operations.
- We already have a physical U64 at 192.168.50.94 with REST API access
  (see `docs/ultimate64_agent.md` in main project).
- Parts of the core are open source on GitHub (Gideon's repos).

If the U64 host core can be modified to swap in our existing 65C816 CPU
work AND benefit from the higher turbo ceiling, the same effort that
unlocked Doom rendering on MiSTer might unlock Doom *playable* on U64.

## Open architectural questions (to resolve before committing)

1. **Is the C64-host part of the U64 actually buildable from source?**
   Some projects open the cartridge/expansion code but keep the standalone
   hardware bitstream closed. We need to confirm we can BUILD the full
   bitstream from the repo, not just read it.

2. **Does the U64 turbo path actually decouple CPU from VIC?** A "fast 6510"
   that still gates on VIC slots wouldn't help our 65C816 reach 20 MHz.

3. **What FPGA does U64 use?** If it's Cyclone V (same as MiSTer), our
   Quartus toolchain and resource budget knowledge transfers. If it's
   ECP5 / Xilinx, we'd be learning a new toolchain.

4. **License compatibility.** Our 65C816 core derives from the
   `MiSTer-devel/SNES_MiSTer` VHDL 65C816 core, which is **GPL-3.0** (verified
   June 2026 — the earlier "MIT-ish" note was wrong). We back-port fixes from
   `pcornier/iigs_simulation` (an unlicensed Verilog port of the same SNES core),
   used only as a reference. The MiSTer C64 core is also GPL, so our stack is
   GPL-consistent; mixing with U64's license needs verification by Gideon.

## What transfers from MiSTer work

| Component | Transfers? | Notes |
|---|---|---|
| 65C816 CPU core | ✓ Mostly | Self-contained (`rtl/65C816/`) |
| Diagnostic UART | ✓ Concept | UART output format / Python parsers |
| REU loader research | ✓ Fully | Loader.prg, MGL pattern, .reu data layout |
| Doom v342 IRQ stub fix | ✓ As recipe | The "NOP $D01A" insight is portable |
| Lorenz regression harness | ✓ Test logic | Need new deployment driver for U64 |
| SCPU ROM (SOCI/SINGULAR) | ✓ Same file | `scpu64.mif` (64KB, identical to VICE) |

## What's MiSTer-specific (not portable)

- Bus arbitration in `fpga64_sid_iec.vhd` (sysCycleDef state machine)
- SDRAM controller + scpu_sdram_addr mux
- `c64.sv` top-level (HPS_IO, MiSTer framework interface)
- I/O decode chains in `fpga64_buslogic.vhd`
- The MiSTer-cmd pipe + screenshot mechanism

## Plan (high-level)

1. **Settle MiSTer v343 retry first.** Bootmap re-enable retry is in flight.
   If it works, MiSTer SuperCPU may be feature-complete enough to ship.
2. **Inventory U64 repos** (agent investigating).
3. **Build the stock U64 bitstream unmodified** to validate toolchain.
4. **Identify U64 CPU integration points** for 65C816 drop-in.
5. **Stage SuperCPU port** in a separate branch / fork of the U64 repo.

This folder (`C64U/`) holds all U64-specific exploration. The main project
remains MiSTer-focused until U64 work is proven viable.
