## Project Overview
Adding 65C816 (SuperCPU) support to the MiSTer FPGA C64 core.
The C64 core is VHDL-based, targeting the Intel Cyclone V FPGA on the DE10-Nano.
The goal is to allow the core to run SuperCPU software (65C816 native mode at 20MHz)
alongside the existing 6510 emulation mode.

## Tech Stack
- Language: VHDL (primary), some Verilog and SystemVerilog modules
- Target: Intel Cyclone V 5CSEBA6U23I7 (DE10-Nano)
- Synthesis: Intel Quartus Prime 17.0+
- Simulation: ModelSim-Intel or GHDL
- Framework: MiSTer sys/ framework (do not modify sys/ files)

## Repository Structure
- C64_MiSTer/           - Cloned official MiSTer C64 core (all edits happen here)
  - rtl/                - Core RTL source files
    - fpga64_sid_iec.vhd  - Top-level C64 system (bus arbitration, clock domains)
    - cpu_6510.vhd         - Current T65-based 6510 CPU wrapper
    - sid/                 - SID sound chip
    - video_vicII_656x.vhd - VIC-II video
    - cartridge.v          - Cartridge/expansion port logic
  - rtl/65C816/        - NEW: 65C816 CPU core files (from SNES core adaptation)
  - sys/               - MiSTer framework (READ ONLY - never modify)
  - c64.sv             - Top-level MiSTer module (directly instantiates fpga64_sid_iec)
  - C64.qpf/.qsf      - Quartus project files

## Build Commands
- Full synthesis: `.\build_c64.ps1` (PowerShell, uses WSL + Quartus)
- Syntax check only: `.\build_c64.ps1 -SyntaxOnly`
- Clean build: `.\build_c64.ps1 -Clean`
- Manual WSL build: see BUILD_GUIDE.md

## Key Architecture Concepts
- The system clock is 32MHz derived from 50MHz input via PLL
- Bus arbitration in fpga64_sid_iec.vhd uses a state machine (sysCycleDef)
  with cycles: EXT(8) + DMA(4) + VIC(4) + CPU(16) = 32 total per 1MHz period
- The T65 CPU core uses an `enable` signal for clock gating
- VIC-II always runs at original speed; CPU speed can vary
- The existing turbo mode gives CPU extra cycles from EXT slots
- SuperCPU mode needs: 65C816 instruction decode, 20MHz effective CPU,
  24-bit addressing, 16MB SDRAM access, SuperCPU control registers

## Code Conventions
- VHDL signals: lowercase with underscores (e.g., cpu_data_out)
- VHDL entities: PascalCase (e.g., T65, VIC_II)
- Verilog modules: lowercase (e.g., cartridge)
- All new code must synthesize on Cyclone V - no simulation-only constructs
- Keep changes isolated: prefer new files over modifying existing ones
- Use generics/parameters for configurable behavior (e.g., CPU mode select)

## Testing Strategy
- After any CPU change: verify C64 KERNAL boots to READY prompt
- Run Lorenz CPU test suite (all tests must pass for 6510 mode)
- For 65C816: verify emulation mode boots normally, then test native mode
- Check VIC-II timing is not affected (demo compatibility)

## Critical Constraints
- FPGA resource budget: the Cyclone V is already ~70% utilized by the C64 core
  plus framework. Monitor ALM/register usage after adding 65C816.
- Do NOT break existing 6510 compatibility - this must remain the default mode
- The 65C816 should be selectable via OSD menu option
