# AI Agent Implementation Plan: 65C816 SuperCPU Support for MiSTer C64 Core

## Executive Summary

This report provides a comprehensive plan for using AI coding agents (Claude Code or Codex CLI) to implement 65C816 SuperCPU support in the open-source MiSTer FPGA C64 core. It covers three interconnected domains: (1) how AI agents currently perform with VHDL/Verilog HDL tasks and what strategies maximize success, (2) how to structure the project's configuration files (CLAUDE.md, AGENTS.md, SKILL.md) to give the agent sufficient context, and (3) a phased technical implementation plan that breaks the FPGA work into AI-tractable subtasks.

***

## Part 1: State of AI Agents + HDL Development

### Can AI Agents Write VHDL/Verilog?

Yes, with important caveats. Current LLMs have demonstrated meaningful capability in hardware description language generation, but the field is less mature than software code generation.

**AutoChip** is the most rigorously studied framework. Developed at NYU, it uses an iterative feedback loop where an LLM generates Verilog, a compiler/simulator checks the output, and error messages are fed back to the LLM for refinement. This approach achieved an **89% pass rate** on HDLBits test cases — a 24.2% improvement over zero-shot generation without feedback. The key insight is that *iterative refinement with EDA tool feedback* is essential; single-shot HDL generation is unreliable.[^1][^2]

**Berkeley's hdl2v research** (2025) showed that fine-tuning LLMs on VHDL-to-Verilog translation pairs improved Verilog generation by up to 23% (pass@10), and notably found that **VHDL training data produces better results than C training data** for the same target Verilog designs. This suggests LLMs have meaningful structural understanding of HDL semantics.[^3]

**Practitioner experience** on the r/FPGA subreddit and FPGA forums indicates that Claude Sonnet is considered "quite effective for VHDL" and that GPT-4 handles synthesis-aware VHDL reasonably well. A YouTube series called "Agentic Verilog" demonstrates Claude Code successfully organizing and writing Verilog for iCE40 FPGA projects in a real development workflow.[^4][^5]

### Known Weaknesses of LLMs in HDL

LLMs commonly fail in specific ways when generating HDL:[^6]

- **Bit width precision**: Not tracking signal widths correctly across operations, leading to synthesis errors
- **Synthesis vs. simulation confusion**: Generating code that simulates correctly but cannot synthesize (e.g., using `for` loops where state machines are needed)
- **Timing constraints**: Poor understanding of clock domain crossings and setup/hold requirements
- **Complex state machines**: Multi-state FSMs with many transitions are error-prone
- **Integration work**: Connecting modules within a larger existing design requires understanding signal conventions the LLM may not grasp from context alone

### Mitigation Strategy: The Feedback Loop

The most successful approach, validated by AutoChip and HaVen, is a **compile-simulate-fix loop**:[^7][^1]

1. LLM generates or modifies VHDL/Verilog
2. Run through Quartus synthesis (or GHDL/Icarus for simulation)
3. Feed compilation errors and simulation waveform mismatches back to the LLM
4. Repeat until passing

For Claude Code specifically, this maps to: write VHDL → run a Quartus compile script → parse errors → fix code → repeat. The CLAUDE.md should encode these build commands explicitly.

***

## Part 2: Project Configuration Files

### CLAUDE.md Structure

The CLAUDE.md file is the primary context document that Claude Code reads automatically at session start. For this FPGA project, it needs to be concise but comprehensive about the hardware context that Claude cannot infer from code alone.[^8][^9]

**Recommended CLAUDE.md:**

```markdown
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
- rtl/               - Core RTL source files
  - fpga64_sid_iec.vhd  - Top-level C64 system (bus arbitration, clock domains)
  - cpu_6510.vhd         - Current T65-based 6510 CPU wrapper
  - sid_*.vhd            - SID sound chip
  - video_vicii_*.vhd    - VIC-II video
  - cartridge.v          - Cartridge/expansion port logic
- rtl/65C816/        - NEW: 65C816 CPU core files (from SNES core adaptation)
- sys/               - MiSTer framework (READ ONLY - never modify)
- C64.sv             - Top-level MiSTer module (directly instantiates fpga64_sid_iec)
- C64.qpf/.qsf       - Quartus project files

## Build Commands
- Full synthesis: `quartus_sh --flow compile C64` (takes ~15 min)
- Syntax check only: `quartus_map --analysis_and_elaboration C64`
- Simulation: `ghdl -a --std=08 rtl/*.vhd && ghdl -e fpga64_sid_iec`

## Key Architecture Concepts
- The system clock is 32MHz derived from 50MHz input via PLL
- Bus arbitration in fpga64_sid_iec.vhd uses a state machine (sysCycleDef)
  with cycles: IDLE(8) + IEC(4) + VIC(4) + CPU(16) = 32 total per 1MHz period
- The T65 CPU core uses an `enable` signal for clock gating
- VIC-II always runs at original speed; CPU speed can vary
- The existing turbo mode gives CPU extra cycles from IDLE slots
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
```

### AGENTS.md (for Codex CLI)

The Codex CLI equivalent uses the same principles but with its three-level hierarchy:[^10][^11]

**Global (~/.config/codex/agents.md):**
```markdown
## Personal Preferences
- Use descriptive signal names; avoid single-letter names in HDL
- Always include comments explaining clock domain relationships
- When modifying VHDL entities, update the corresponding testbench
- Prefer `std_logic_vector` over `unsigned` for port signals
```

**Project (./AGENTS.md):** Same content as the CLAUDE.md above.

**Folder (./rtl/65C816/AGENTS.md):**
```markdown
## 65C816 CPU Core
- This directory contains the 65C816 CPU adapted from the SNES MiSTer core
- The CPU must support both emulation mode (6502-compatible) and native mode
- Entity interface must match T65-style ports for drop-in integration
- Reference: WDC 65C816 datasheet and SNES core at github.com/MiSTer-devel/SNES_MiSTer
- VICE xscpu64 source code is the behavioral reference implementation
```

### SKILL.md Files

Claude Code skills provide modular, on-demand knowledge. For this project, several custom skills would be valuable:[^12][^13]

**Skill 1: VHDL Synthesis Check (~/.claude/skills/vhdl-synth-check/)**
```yaml
---
name: VHDL Synthesis Check
description: Run Quartus synthesis analysis on modified VHDL files and fix errors iteratively
---

## Instructions
1. After modifying any .vhd or .v file, run: `quartus_map --analysis_and_elaboration C64`
2. Parse the output for errors (look for "Error:" lines)
3. For each error, identify the file and line number
4. Fix the issue in the source file
5. Re-run synthesis check
6. Repeat until clean (max 5 iterations, then ask human for guidance)

## Common VHDL Synthesis Errors
- For reference on common pitfalls, see [reference.md](reference.md)
```

**Skill 2: MiSTer Core Integration (~/.claude/skills/mister-core-integration/)**
```yaml
---
name: MiSTer Core Integration
description: Guidelines for modifying MiSTer FPGA cores while maintaining framework compatibility
---

## Instructions
- Never modify files in sys/
- The top module must be named `emu` with the standard MiSTer port interface
- OSD menu options are defined in the CONF_STR parameter in C64.sv
- To add a new OSD toggle: add to CONF_STR, wire through hps_io, connect to core
- For reference on MiSTer framework signals, see [reference.md](reference.md)
```

**Skill 3: 65C816 Architecture Reference (~/.claude/skills/65c816-reference/)**
```yaml
---
name: 65C816 Architecture Reference  
description: Technical reference for the WDC 65C816 CPU architecture, instruction set, and modes
---

## Key Concepts
The 65C816 starts in emulation mode (behaves as 65C02) and switches to native
mode via CLC + XCE instruction sequence.

## Register Differences from 6502
For complete register and opcode reference, see [reference.md](reference.md)
For SuperCPU-specific registers, see [supercpu_registers.md](supercpu_registers.md)
```

**Skill 4: Planning With Files (~/.claude/skills/planning-with-files/)**

This skill, based on the open-source "planning-with-files" pattern, ensures the agent maintains persistent state across context windows:[^14][^15]

```yaml
---
name: Planning With Files
description: Maintain task plans, findings, and progress logs as markdown files for complex multi-session projects
---

## Instructions
Before starting work, check for existing plan files:
- task_plan.md: The current implementation plan with phases and subtasks
- findings.md: Technical discoveries, gotchas, and decisions made
- progress.md: Log of completed work and current status

If no plan exists, create one before writing any code.
Update progress.md after completing each subtask.
If you discover something unexpected, log it in findings.md immediately.
```

***

## Part 3: Phased Implementation Plan

This plan is designed so each phase produces a testable deliverable and can fit within a single Claude Code context window session. Phases are ordered by dependency and risk.

### Phase 0: Repository Setup and Knowledge Acquisition

**Goal:** Get the AI agent oriented in the codebase and create the project scaffolding.

**Tasks:**
1. Clone the C64 MiSTer core repository[^16]
2. Clone the SNES MiSTer core repository for 65C816 reference[^17]
3. Download VICE xscpu64 source code as behavioral reference[^18]
4. Create all CLAUDE.md / AGENTS.md / SKILL.md files as specified above
5. Create `task_plan.md` with all phases documented
6. Have the agent read and summarize:
   - `rtl/cpu_6510.vhd` — understand T65 entity interface and Mode generic
   - `rtl/fpga64_sid_iec.vhd` — understand bus arbitration state machine
   - `C64.sv` — understand top-level integration and OSD wiring
   - SNES core's `rtl/65C816/` directory — understand the complete 65C816 VHDL
   - The SuperCPU register map from c64-wiki.com

**AI Agent Prompt:**
> Use /plan mode. Read the C64 core's cpu_6510.vhd, fpga64_sid_iec.vhd, and C64.sv. Also read the SNES core's 65C816 directory. Summarize: (a) the T65 entity ports and Mode generic, (b) the bus arbitration state machine and how CPU cycles are allocated, (c) how the SNES 65C816 entity differs from T65, (d) what would need to change to swap or extend the CPU. Write findings to findings.md.

### Phase 1: 65C816 CPU Core Adaptation

**Goal:** Create a standalone, synthesizable 65C816 CPU module with a T65-compatible interface.

**Tasks:**
1. Copy the SNES core's 65C816 VHDL files into `rtl/65C816/`
2. Create a wrapper entity `cpu_65c816.vhd` that presents the same port interface as `cpu_6510.vhd` (Address, Data_In, Data_Out, R_W, Enable, Clk, Reset, etc.)
3. The wrapper must handle the 65C816's 24-bit address bus, exposing the upper 8 bits (bank byte) as a separate port for memory mapping
4. Add an emulation/native mode status output signal
5. Verify the module synthesizes standalone with `quartus_map --analysis_and_elaboration`

**Key Technical Detail:** The T65 core in the C64 uses a `Mode` generic set to `"00"` for NMOS 6502 behavior. The T65 supposedly supports `"11"` for 65C816 but this is incomplete. The SNES core's P65C816 is a completely separate, fully functional implementation. The safer approach is to use the SNES implementation with a compatibility wrapper rather than trying to complete T65's 65C816 mode.[^19][^20]

**AI Agent Prompt:**
> Read the SNES 65C816 entity ports and the C64 cpu_6510.vhd entity ports. Create a wrapper module cpu_65c816.vhd that instantiates the SNES 65C816 core but presents ports compatible with how cpu_6510 is instantiated in fpga64_sid_iec.vhd. Add a bank_address(7 downto 0) output port for the upper address byte. Run quartus_map analysis after writing.

### Phase 2: Dual-CPU Infrastructure

**Goal:** Allow the top-level system to instantiate both CPU cores and switch between them.

**Tasks:**
1. Modify `fpga64_sid_iec.vhd` to instantiate both `cpu_6510` and `cpu_65c816`
2. Add a `supercpu_enable` input signal that selects which CPU drives the bus
3. When `supercpu_enable = '0'`: existing behavior, 6510 drives everything
4. When `supercpu_enable = '1'`: 65C816 drives address/data/R_W, 6510 is held in reset
5. Wire `supercpu_enable` through to `C64.sv` and add an OSD menu toggle
6. **Critical:** Verify that with `supercpu_enable = '0'`, the core boots identically to the unmodified version (no regression)

**AI Agent Prompt:**
> Modify fpga64_sid_iec.vhd to instantiate both cpu_6510 and the new cpu_65c816 wrapper. Add a supercpu_enable generic/signal. Use a MUX to select which CPU's outputs drive the bus signals. When supercpu_enable is low, behavior must be identical to the current core. Wire the signal through C64.sv as an OSD option. Run synthesis check.

### Phase 3: Clock Domain — 20MHz CPU

**Goal:** Generate a 20MHz clock for the 65C816 and modify bus arbitration to give it 20 CPU cycles per microsecond.

**Tasks:**
1. Modify the PLL configuration to output an additional 20MHz clock (or derive via clock divider)[^20]
2. Redesign the `sysCycleDef` state machine for SuperCPU mode — the 65C816 needs ~20 bus cycles per 1MHz system period while VIC-II still gets its 4 cycles
3. The state machine must be modified so that in SuperCPU mode, the IDLE and current CPU slots are all allocated to the 65C816
4. VIC-II steal cycles must still work (the VIC needs bus access for badlines)
5. When the 65C816 accesses I/O registers ($D000-$DFFF), it must slow down to 1MHz for peripheral timing compatibility

**Key Technical Detail from Forum Research:** A MiSTer forum member (dentnz) attempted feeding a 20MHz clock directly to the T65 with `enable = '1'` constant, which caused the CPU to hog the bus and produce a black screen. The correct approach is to keep the 32MHz system clock but modify the state machine to grant more cycles to the CPU, with the VIC-II still getting priority during its allocated slots. The SuperCPU's real hardware used a similar scheme — the 65C816 ran at 20MHz but was stalled whenever the VIC-II needed the bus.[^20]

**AI Agent Prompt:**
> Read the sysCycleDef state machine in fpga64_sid_iec.vhd carefully. In SuperCPU mode, redesign the cycle allocation: VIC still gets CYCLE_VIC0-3, IEC still gets CYCLE_IEC0-3, but all remaining cycles (currently IDLE + CPU) become fast CPU cycles for the 65C816. The 65C816 enable signal should be pulsed once per allocated cycle. Ensure the VIC can still steal cycles for badlines. When the CPU address is in the I/O range ($D000-$DFFF), throttle to 1MHz. Update progress.md.

### Phase 4: Extended Memory (24-bit Addressing)

**Goal:** Give the 65C816 access to 16MB of address space via the DE10-Nano's SDRAM.

**Tasks:**
1. The DE10-Nano has 32MB SDRAM. Map the 65C816's bank bytes (addresses $010000-$FFFFFF) to SDRAM
2. Bank $00 remains the normal C64 64KB memory map (RAM, ROM, I/O)
3. Banks $01-$0F map to SDRAM (15MB of fast RAM, matching SuperCPU's 16MB space)
4. Add SDRAM read/write arbitration — the 65C816 accesses SDRAM during its bus cycles, the MiSTer framework may also need SDRAM access for file loading
5. Implement the SuperCPU's memory mirroring behavior (upper 64KB of bank $00 mirrors ROM)

**AI Agent Prompt:**
> Implement a memory controller module that routes the 65C816's 24-bit address. Bank $00 goes to existing C64 RAM/ROM/IO. Banks $01+ go to SDRAM via the MiSTer SDRAM interface. Study how the existing REU implementation accesses SDRAM for a model of the arbitration pattern. Create sdram_bank_controller.vhd.

### Phase 5: SuperCPU Control Registers

**Goal:** Implement the hardware registers that SuperCPU software uses for detection and control.

**Tasks:**
1. Implement registers at the SuperCPU's documented addresses:[^20]
   - Speed control register (`$D07B` — switch between 1MHz and 20MHz)
   - Hardware enable/disable registers
   - Identification registers (software reads these to detect SuperCPU presence)
   - RAM configuration registers
2. Reference the VICE xscpu64 source code for exact register behavior[^21][^18]
3. Wire these registers into the I/O address decoder in fpga64_sid_iec.vhd

**AI Agent Prompt:**
> Using the VICE xscpu64 source (src/scpu64/) as behavioral reference and the c64-wiki.com SuperCPU page for register addresses, implement the SuperCPU control registers as a new VHDL module supercpu_regs.vhd. Include: speed control at $D07B, identification registers, and RAM banking control. Wire into the I/O decoder in fpga64_sid_iec.vhd so reads/writes in the SuperCPU register range are routed to this module.

### Phase 6: Disk Image Support (D2M)

**Goal:** Add D2M disk image loading support needed specifically for SuperCPU Doom.

**Tasks:**
1. Implement D2M image mounting via the MiSTer framework's file I/O system
2. This is primarily a firmware/HPS-side change (the ARM side loads files)
3. Add D2M as a recognized file extension in C64.sv's CONF_STR
4. Implement the D2M-to-sector translation logic

**Note:** This phase is the least well-documented and may require the most human guidance. The D2M format is specific to CMD hard drives and is not widely implemented outside VICE.

### Phase 7: Integration Testing and Polish

**Goal:** End-to-end verification with real SuperCPU software.

**Tasks:**
1. Boot test: C64 KERNAL must still boot in 6510 mode (regression test)
2. Toggle SuperCPU via OSD: system should reset and boot with 65C816 in emulation mode
3. Run SuperCPU detection software — verify identification registers work
4. Load and run simple SuperCPU-enhanced programs
5. Attempt Wolfenstein 3D SuperCPU port
6. Attempt Doom SuperCPU port (requires D2M support from Phase 6)
7. Resource utilization check — verify FPGA is not overutilized

***

## Part 4: AI Agent Workflow Best Practices

### Plan Mode First, Always

For every phase, start Claude Code in plan mode (`/plan` or Shift+Tab). Have it:[^22][^23]
1. Read the relevant source files
2. Produce a plan with specific file changes
3. Get human approval before executing

This is especially critical for FPGA work where a bad change can be difficult to diagnose (black screen, no error message).[^20]

### Multi-Phase Context Management

Each phase should fit within one Claude Code context window. Between phases:[^23][^24]
1. Update `progress.md` with completed work
2. Update `findings.md` with any surprises or decisions
3. Start a fresh session for the next phase
4. The new session reads CLAUDE.md + progress.md + findings.md to resume

### The Compile-Fix Loop

Encode this in CLAUDE.md as the standard workflow:
1. Make changes
2. Run `quartus_map --analysis_and_elaboration C64`
3. If errors, fix and re-run (max 5 iterations)
4. If clean, run full synthesis to check timing
5. Log results in progress.md

This mirrors the AutoChip methodology that achieved 89% success rates.[^1]

### Human Checkpoints

Certain decisions require human judgment and should be flagged:
- Any modification to `fpga64_sid_iec.vhd`'s bus arbitration (risk of breaking VIC-II timing)
- PLL configuration changes (risk of clock instability)
- SDRAM arbitration changes (risk of memory corruption)
- Any change that causes synthesis to exceed 85% FPGA utilization

### Reference Code Strategy

Rather than pasting entire reference files into context, use the SKILL.md pointer approach:[^25]
- Point to VICE xscpu64 source files by path for behavioral reference
- Point to SNES core's 65C816 VHDL for implementation reference
- Let the agent read specific files on demand rather than loading everything upfront

***

## Part 5: Realistic Assessment

### What AI Can Do Well Here
- Adapting the SNES 65C816 entity ports to match T65 conventions (structural wiring)
- Implementing SuperCPU control registers (straightforward register logic)
- Writing the OSD integration in C64.sv (well-patterned, many examples in other cores)
- Memory address decoding logic (combinational, well-specified)
- Iterative compilation error fixing (proven by AutoChip research)

### What Will Likely Need Heavy Human Guidance
- Bus arbitration timing changes (the VIC-II interaction is subtle and timing-critical)
- Clock domain crossing between 20MHz CPU and 1MHz peripherals
- SDRAM arbitration (complex existing logic, risk of race conditions)
- D2M disk image support (poorly documented format)
- Debugging black-screen failures (no error output, requires waveform analysis)

### Estimated Effort
Based on the complexity and the AI assistance level:
- **Phase 0-1:** 1-2 sessions, high AI autonomy
- **Phase 2:** 1-2 sessions, moderate human guidance needed
- **Phase 3:** 3-5 sessions, significant human guidance (clock domains are hard)
- **Phase 4:** 2-3 sessions, moderate human guidance
- **Phase 5:** 1-2 sessions, high AI autonomy (register logic is straightforward)
- **Phase 6:** 2-4 sessions, significant human guidance (poorly documented)
- **Phase 7:** Ongoing testing, primarily human-driven

Total: roughly 15-25 Claude Code sessions spread across what would likely be several weeks of part-time work for an experienced FPGA developer working alongside the AI agent.

---

## References

1. [AutoChip: Automating HDL Generation Using LLM Feedback - arXiv](https://arxiv.org/html/2311.04887v2)

2. [AutoChip: Automating HDL Generation Using LLM Feedback](http://arxiv.org/pdf/2311.04887.pdf)

3. [Improving LLM Performance in Generating Verilog by Fine ...](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2025/EECS-2025-104.pdf)

4. [Chatgpt does vivado tcl pretty well](https://www.reddit.com/r/FPGA/comments/1g9uofu/chatgpt_does_vivado_tcl_pretty_well/) - Chatgpt does vivado tcl pretty well

5. [Organize Messy FPGA Projects in Seconds with AI | Agentic Verilog #6](https://www.youtube.com/watch?v=AQPwXujJukA) - Is your FPGA project folder a mess? Learn how to use Claude AI to organize your Verilog project file...

6. [Simplifying FPGA code development: How ChatGPT is ...](https://liquidinstruments.com/blog/simplifying-fpga-code-development-how-chatgpt-is-changing-the-game/)

7. [HAVEN: Hallucination-Mitigated LLM for Verilog Code ...](https://github.com/Intelligent-Computing-Research-Group/HaVen) - HaVen is a novel framework designed to enhance the alignment of large language models (LLMs) with ha...

8. [Maximising Claude Code: Building an Effective CLAUDE.md](https://www.maxitect.blog/posts/maximising-claude-code-building-an-effective-claudemd) - Max is a former architect turned software engineer. He blogs about topics related to computational d...

9. [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices) - Tips and patterns for getting the most out of Claude Code, from configuring your environment to scal...

10. [Codex CLI AGENTS.md Deep Dive: The 3 Levels of Project ...](https://www.youtube.com/watch?v=W8I4vk1K72Q) - AGENTS.md gives Codex permanent project memory through a 3-level system: global preferences, project...

11. [Custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md/) - Codex reads AGENTS.md files before doing any work. By layering global guidance with project-specific...

12. [How to create custom Skills | Claude Help Center](https://support.claude.com/en/articles/12512198-how-to-create-custom-skills)

13. [Extend Claude with skills - Claude Code Docs](https://code.claude.com/docs/en/skills) - Skill files can contain any instructions, but thinking about how you want to invoke them helps guide...

14. [Planning with Files | Claude Code Skill for Complex Tasks](https://mcpmarket.com/ko/tools/skills/structured-file-based-planning)

15. [OthmanAdi/planning-with-files: Claude Code skill ...](https://github.com/OthmanAdi/planning-with-files) - How it works: Checks for previous session data in ~/.claude/projects/; Finds when planning files wer...

16. [MiSTer-devel/C64_MiSTer](https://github.com/MiSTer-devel/C64_MiSTer) - Based on FPGA64 by Peter Wendrich with heavy later modifications by different people. Features. C64 ...

17. [GitHub - MiSTer-devel/SNES_MiSTer: SNES for MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer) - SNES for MiSTer. Contribute to MiSTer-devel/SNES_MiSTer development by creating an account on GitHub...

18. [1 About VICE](https://vice-emu.sourceforge.io/vice_1.html)

19. [Overview :: T65 CPU](https://opencores.org/projects/t65)

20. [Super CPU Support? - MiSTer FPGA Forum](https://misterfpga.org/viewtopic.php?t=1878) - Re: Super CPU Support? Seems that the T65 implementation (the CPU of the current c64 core) is actual...

21. [Versatile Commodore 8-bit Emulator (xscpu64)](https://github.com/kodi-game/game.libretro.vice_xscpu64) - VICE stands for the Versatile Commodore Emulator. The current version emulates the C64, the C64DTV, ...

22. [Plan Mode | Claude AI Dev](https://claudeai.dev/docs/mechanics/foundation/plan-mode/) - What is Plan Mode?

23. [How I use Claude Code for real engineering](https://www.youtube.com/watch?v=kZ-zzHVUrO4) - In this video, I walk through my complete workflow for tackling large coding projects using Claude C...

24. [What Actually Is Claude Code's Plan Mode?](https://lucumr.pocoo.org/2025/12/17/what-is-plan-mode/) - A plan in Claude Code is effectively a markdown file that is written into Claude's plans folder by C...

25. [Writing a good CLAUDE.md](https://www.humanlayer.dev/blog/writing-a-good-claude-md) - `CLAUDE.md` is a high-leverage configuration point for Claude Code. Learning how to write a good `CL...

