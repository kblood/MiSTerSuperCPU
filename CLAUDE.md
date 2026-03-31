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
- FPGA resource budget: the Cyclone V is already ~72% utilized (30,300 ALMs)
- Do NOT break existing 6510 compatibility - this must remain the default mode
- The 65C816 is hardcoded ON (SuperCPU/UART/overlay always enabled)
- SDRAM address mux (scpu_sdram_addr) MUST be combinational — registering it
  introduces a 1-cycle latency that breaks LDA long bank transitions
- $D078 cache flush clears BOTH 8KB cache AND 32KB BRAM page valid bits
- SDRAM pipeline: bank $00 uses 2-stage, SuperRAM uses 3-stage (superram_enable_delay)
- XCE instruction: use `(P(0)='1' or P(8)='1')` for SP/X/Y forcing (not just P(0))

## Specialized Agents

### Debug Agent
Use when diagnosing issues on live MiSTer hardware. Reads UART output, checks
diagnostic bytes, deploys builds, and interprets debug overlay/UART fields.
- Reference: `docs/debug_agent.md` (connection details, UART format, diagnostic patterns)
- MiSTer IP: 192.168.50.130, SSH root/1, Core: /media/fat/_Test/C64.rbf
- T:xx diagnostic byte: b0=turbo, b1=rom_vis, b2=1mhz, b3=iec, b4=overlay, b5=cache, b6=enCpu
- **Primary tool: `tools/mister_debug.py`** — use this for all MiSTer operations:
  - Deploy: `python tools/mister_debug.py deploy [rbf_path]`
  - Screenshot: `python tools/mister_debug.py screen [output.png]`
  - OSD Screenshot: `python tools/mister_debug.py osd_screen [output.png]`
  - UART: `python tools/mister_debug.py uart [seconds]`
  - Keyboard: `python tools/mister_debug.py keys <sequence>`
  - PRG load: `python tools/mister_debug.py load_prg <file.prg>`
  - Status: `python tools/mister_debug.py status`
- UART baud rate must be set first: `ssh root@192.168.50.130 "stty -F /dev/ttyS1 115200 raw -echo"`
- Keyboard via mtype.py: `ssh root@192.168.50.130 "python3 /tmp/mtype.py <keys>"`
  Upload first: `scp tools/mtype.py root@192.168.50.130:/tmp/mtype.py`
- WSL SSH is broken to MiSTer — always use Windows native ssh/scp
- Disk images: mount via MGL (use `mistergamedescription` tag, `type="s" index="0"`)
- **DANGER: NEVER use `busybox devmem` or direct FPGA register access** — crashes MiSTer, requires physical power cycle

### Ultimate 64 Agent
Use for testing and comparing against real Ultimate 64 hardware via its REST API.
Can deploy CRTs/PRGs, reset the machine, read screen RAM, and control settings remotely.
- Reference: `docs/ultimate64_agent.md` (full API reference, deploy workflow)
- Ultimate 64 IP: 192.168.50.94
- API base: `http://192.168.50.94/v1`
- Deploy+run CRT: `curl -X POST --data-binary @test.crt http://192.168.50.94/v1/runners:run_crt`
- Reset: `curl -X PUT http://192.168.50.94/v1/machine:reset`
- Read screen RAM: `curl "http://192.168.50.94/v1/machine:readmem?address=0400&length=03E8"`
- Note: scpu_speedtest.crt shows 0.9-1.1MHz on U64 because $D07A/$D07B are SuperCPU-specific

### Software Architect Agent
Use for planning, creating/updating architecture diagrams, and comparing implementations.
Maintains Mermaid diagrams of core architectures and identifies next steps.
- Reference: `docs/architecture_diagrams.md` (Mermaid diagrams of all core variants)
- Compares: Original MiSTer C64, Current SuperCPU, Ultimate 64, Planned target
- Updates diagrams when architecture changes
- Plans implementation phases and identifies issues to fix
