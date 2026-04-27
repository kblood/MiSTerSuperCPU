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
- Full architecture reference: `docs/supercpu_architecture_reference.md`
- Feature implementation status / regression test plan / gaps: `docs/supercpu_feature_status.md`

## Real SuperCPU vs MiSTer Implementation
The real CMD SuperCPU has 128KB SRAM (banks $00-$01), a 1-byte write buffer
("CacheWrite"), and SuperRAM starting at bank $02. Key differences from our
MiSTer implementation:
- **Real HW**: 128KB SRAM (full bank $00+$01 mirror). **MiSTer**: 64KB BRAM + 8KB cache
- **Real HW**: Bank $01 = SRAM (ROM shadows). **MiSTer**: Bank $01 = SuperRAM/SDRAM (WRONG)
- **Real HW**: SuperRAM starts bank $02. **MiSTer**: SuperRAM starts bank $01 (WRONG)
- **Real HW**: $D078 = SIMM config. **MiSTer**: $D078 = cache flush (repurposed)
- **Real HW**: Optimization modes control write mirroring range. **MiSTer**: Not implemented
- **Real HW**: ROM in banks $F0-$FF (bootmap). **MiSTer**: Minimal ROM stub at $FF00
- **REU and SuperRAM are SEPARATE memory systems** — REU DMA only accesses C64
  motherboard RAM, NOT SuperRAM. To copy REU→SuperRAM, software must:
  REU FETCH → bank $00 RAM → CPU long store → SuperRAM bank.
- **Doom loading**: io.prg uses REU FETCH DMA + long stores. Doom game code runs
  from SuperRAM only (no REU DMA at runtime).

## REU Register Path and Loading (VERIFIED 2026-04-13)
**REU write path**: `reu.v` cpu_cs is driven by `iof_fall_pulse` (a 1-cycle
pulse generated at the FALLING edge of `iof_detect` in `fpga64_sid_iec.vhd`),
NOT by `IOF_raw` directly. cpu_we/addr/dout use latched values
(`iof_we_latched` / `iof_addr_latched` / `iof_dout_latched`) captured during
the $DFxx access. This is required because in turbo mode the CPU's STA $DFxx
write cycle is only 1 clk32 long — by the time registered `IOF_raw` rises,
`cpuWe_pre` has already dropped, causing all writes to be classified as
reads. DO NOT revert to the edge-based cs approach. If REU writes stop
working, check `iof_fall_pulse_r` and the latched-input wiring first.
Full details: memory file `project_reu_iof_falling_edge_fix.md`.

**REU register writes are offset-1**: $DF00 is status (read-only), $DF01 is
command, $DF02/$DF03 is C64 target address, $DF04/$DF05/$DF06 is REU address,
$DF07/$DF08 is length. Use cmd $91 (FETCH immediate, execute + type 1) or
$90 (STASH immediate). Length auto-loads to $FFFF after completion — always
re-write length before each DMA.

**Loading .reu files (e.g., doom.reu)**: Use an MGL file via the MiSTer_cmd
pipe. `echo load_core X.mgl > /dev/MiSTer_cmd` DOES process `<file>` tags —
Dragon's Lair MGLs (and other stock MiSTer MGLs) prove the pipe handler
loads both `<rbf>` and `<file>` elements end-to-end. The load_reu ioctl
path is wired in c64.sv at both `ioctl_index == 'h81` (OSD F1 browser) and
`ioctl_index == 'h01 && reu_by_ext` (MGL file-tag fallback matching on the
`.REU`/`.reu` extension).

`mbc load_rom` does NOT work for REU — mbc has no C64.REU alias and routes
`.reu` as a PRG. Use a custom MGL via pipe instead.

SDRAM is volatile but survives `load_core` bitstream reloads on the same
power-on cycle (see `project_sdram_survives_deploy.md`), so a single MGL
load populates REU SDRAM that persists across subsequent iterative deploys.

**Doom launcher (after REU loaded)**:
```
POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92
POKE49156,0:POKE49157,0:POKE49158,32
SYS49152
```
Assembles SEI; CLC; XCE; JML $20:0000 at $C000.

## Operator Preferences
- The user prefers autonomous execution during debugging/implementation work: do not stop to ask for confirmation when there is a reasonable next step. Continue with the best next action, validate it, and document it.
- Still surface major risks/assumptions, but default to action rather than asking what to do next. Do NOT treat this as a cue to produce status updates — just act.

### Do not manufacture handoffs
When working on a debugging task (build → deploy → test → iterate loops), actively suppress the behaviors that produce premature wrap-ups:
- **Suppress the end-of-turn summary.** No "what changed / what's next" paragraph. No "session recap." No "recommended next-session entry point." If you were about to write one, do the next probe instead.
- **Ignore the 100-word response cap** in debug loops. Use whatever length the actual work requires.
- **Task-tool reminders are not stop signals.** Log the task if helpful, then keep working.
- **Builds and deploys are routine steps, not decision points.** Don't pause to ask before a rebuild or redeploy on the dev MiSTer at `/media/fat/_Test/`. Don't summarize between builds — use the 30-40 min Quartus window to analyze UART, prep next hypotheses, or run GHDL benches.
- **ScheduleWakeup is a cache-preservation tool, not a session-end ritual.** The `prompt` field is a note to future-you, not user-facing copy — don't let that handoff language leak into your reply.
- **Commit when a fix lands, not when "a reasonable chunk" is done.** Intermediate triggers/instrumentation that aren't fixes can stay uncommitted across many iterations.
- **Only stop when an explicit exit condition is met:** the user says stop, the stated goal is achieved, or you have concrete evidence no local probe can make progress (e.g., need upstream docs, physical hardware access, or a decision only the user can make).
- **Session handoff doc pattern.** Full state lives in `docs/session_handoff.md` (overwritten each session). Update that file when stopping; do not restate its contents in chat.

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

## Verilator / Desktop Simulation Build Policy
- SuperCPU-fork harness (`sim/verilator_c64/`) was **SHELVED 2026-04-18** and removed from `master`. Preserved on branch `shelved/verilator-superfork` (tip `56756b6`) — check out or cherry-pick, do not rebuild from scratch. See `docs/verilator_desktop_harness_plan.md` for why and for revival criteria. Do NOT recreate it on impulse; it only comes back if a bug survives >1 week of hardware + GHDL-bench debugging.
- Vanilla reference harness (`sim/verilator_c64_vanilla/`) is retained for possible differential testing. Builds there are still heavy CPU-bound jobs.
- Prefer **incremental rebuilds**; do not `clean` unless necessary
- Reuse existing `obj_dir/` outputs when only running/debugging the executable
- Before launching a heavy build, check whether the binary already exists and whether the edited files actually require regeneration
- Default workflow if the vanilla harness is actually in use: edit -> rebuild -> run -> inspect -> document findings. Otherwise leave it alone.
- **Primary debug loops**: GHDL benches (`sim/p65c816_tb/`, `sim/prg_loader_tb/`, `sim/c64_reduced_harness/`) for CPU-class bugs, and MiSTer hardware + UART for system-level bugs. These have produced every actual fix in the fork.

## Critical Constraints
- FPGA resource budget: the Cyclone V is already ~72% utilized (30,300 ALMs)
- Do NOT break existing 6510 compatibility - this must remain the default mode
- The 65C816 is hardcoded ON (SuperCPU/UART/overlay always enabled)
- SDRAM address mux (scpu_sdram_addr) MUST be combinational — registering it
  introduces a 1-cycle latency that breaks LDA long bank transitions
- $D078 cache flush clears BOTH 8KB cache AND 32KB BRAM page valid bits
  (NOTE: real SuperCPU uses $D078 for SIMM configuration, we repurposed it)
- SDRAM pipeline: bank $00 uses 2-stage, SuperRAM uses 3-stage (superram_enable_delay)
- XCE instruction: use `(P(0)='1' or P(8)='1')` for SP/X/Y forcing (not just P(0))

## Specialized Agents

### Debug Agent
Use when diagnosing issues on live MiSTer hardware. Reads UART output, checks
diagnostic bytes, deploys builds, and interprets debug overlay/UART fields.
- Reference: `docs/debug_agent.md` (connection details, UART format, diagnostic patterns)
- MiSTer IP: 192.168.50.130, SSH root/1, Core: /media/fat/_Test/C64.rbf
- T:xx diagnostic byte: b0=turbo, b1=rom_vis, b2=1mhz, b3=iec, b4=overlay, b5=cache, b6=enCpu, b7=dma_active (NOT NOT_irq_vic — verified 2026-04-27 at fpga64_sid_iec.vhd:1937)
- UART position 75 char (`!`/`.`/`F`/`f`) reflects real `irq_vic` line via dedicated `dbg_irq_vic_n` port (v155+). Earlier builds wired `~dma_active` here by mistake.
- **Primary tool: `tools/mister_debug.py`** — use this for all MiSTer operations:
  - Deploy: `python tools/mister_debug.py deploy [rbf_path]`
  - Screenshot: `python tools/mister_debug.py screen [output.png]`
  - OSD Screenshot: `python tools/mister_debug.py osd_screen [output.png]` (requires OBS + HDMI capture)
  - UART: `python tools/mister_debug.py uart [seconds]`
  - Keyboard: `python tools/mister_debug.py keys <sequence>` (uses mtype.py, NOT mbc)
  - PRG load: `python tools/mister_debug.py load_prg <file.prg>`
  - Status: `python tools/mister_debug.py status`
- UART baud rate must be set first: `ssh root@192.168.50.130 "stty -F /dev/ttyS1 115200 raw -echo"`
- Keyboard via mtype.py: `ssh root@192.168.50.130 "python3 /tmp/mtype.py <keys>"`
  Upload first: `scp tools/mtype.py root@192.168.50.130:/tmp/mtype.py`
- **mbc raw_seq does NOT work for OSD/keyboard** — MiSTer filters mbc's virtual input device
- MiSTer screenshots (`/dev/MiSTer_cmd`) do NOT capture OSD overlay — use OBS + HDMI capture
- WSL SSH is broken to MiSTer — always use Windows native ssh/scp
- **MiSTer reboot is pre-authorized** when the daemon wedges (no fresh
  `MiSTer_fb` dmesg events, `/tmp/CORENAME` mtime frozen, `load_core`/
  `screenshot` pipe writes silently dropped). `ssh root@... "sync && reboot"`
  is OK to issue without asking. inittab uses `sysinit:` so `kill PID`
  alone is permanent — full reboot is the supported recovery path.
  See `feedback_mister_daemon_can_wedge.md` in memory for the 3-indicator
  wedge check.
- **SSH auth**: Windows `ssh` command fails (too many keys tried). Always use
  `python tools/mister_debug.py` which connects via paramiko with password auth.
  For manual SSH, use paramiko in Python or `ssh -o IdentitiesOnly=yes -i <specific_key>`
- Disk images: mount via MGL (use `mistergamedescription` tag, `type="s" index="0"`)
- **DANGER: NEVER use `busybox devmem` or direct FPGA register access** — crashes MiSTer, requires physical power cycle
- **DANGER: NEVER write our modified build into `/media/fat/_Computer/`**. That folder
  must contain only the OFFICIAL upstream release rbfs (vanilla MiSTer cores). Our
  modified build goes EXCLUSIVELY to `/media/fat/_Test/C64.rbf`. Reasons: (1) MGL
  files reference `<rbf>_Computer/C64</rbf>` and must load a known-good vanilla,
  (2) MiSTer's `get_rbf()` prefers date-stamped files like `C64_YYYYMMDD.rbf` over
  plain `C64.rbf` — overwriting one without the other produces confusing load
  behavior. Canonical vanilla rbf source: `C64_MiSTer/releases/C64_20250828.rbf`
  (md5 `32a3ef42a78ed8b255bed895d09b833c`, 3,767,168 bytes). If you need to reset
  them: `scp C64_MiSTer/releases/C64_20250828.rbf` to BOTH `/media/fat/_Computer/C64.rbf`
  AND `/media/fat/_Computer/C64_20250828.rbf`.

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
