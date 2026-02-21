# 65C816 SuperCPU Implementation Plan

## Overview

This plan adds 65C816 (SuperCPU) support to the MiSTer FPGA C64 core in incremental,
testable phases. Each phase produces a buildable, verifiable result. The plan is based on
the research in "65C816 MiSTer C64 AI Plan.md" and adapted for our confirmed build
environment (Quartus 22.1 in WSL, build_c64.ps1 automation).

---

## Phase 0: Build Pipeline Smoke Test
**Goal:** Make a trivial change to the VHDL/SystemVerilog, rebuild, and confirm the
modified core still compiles cleanly.

**Why first:** Before touching anything complex, we need confidence that our edit-build-verify
loop works. A broken build pipeline would block everything else.

**Tasks:**
1. Add a new OSD menu section header in `c64.sv` CONF_STR (e.g., "SuperCPU" section)
2. Add a placeholder OSD toggle: "SuperCPU,Off,On" mapped to an unused status bit
3. Wire that status bit to a new `supercpu_enable` signal in `c64.sv` (unused for now)
4. Pass `supercpu_enable` into `fpga64_sid_iec` as a new port (active-low, ignored internally)
5. Run `.\build_c64.ps1` — must produce 0 errors
6. Diff resource usage vs. vanilla build — should be negligible change

**Files modified:**
- `C64_MiSTer/c64.sv` — CONF_STR addition, signal wiring
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — new port declaration (unused internally)

**Verification:**
- Build succeeds with 0 errors
- Resource usage delta < 10 ALMs (the change is cosmetic)
- The OSD toggle exists but does nothing yet

---

## Phase 1: 65C816 CPU Core Adaptation
**Goal:** Create a standalone, synthesizable 65C816 CPU module with a T65-compatible interface.

**Tasks:**
1. Clone the SNES MiSTer core's `65C816` VHDL files into `C64_MiSTer/rtl/65C816/`
2. Study the SNES P65C816 entity ports vs. the T65 ports used by `cpu_6510.vhd`
3. Create `cpu_65c816.vhd` — a wrapper that presents cpu_6510-compatible ports:
   - `clk`, `enable`, `reset`, `nmi_n`, `irq_n`, `rdy`
   - `di(7:0)`, `do(7:0)`, `addr(15:0)`, `we`
   - Plus new: `bank_addr(7:0)` output for 24-bit addressing
   - Plus new: `emulation_mode` output status signal
4. Handle the 6510 I/O port ($0000-$0001) in the wrapper — the 65C816 doesn't have this
   natively, so the wrapper must emulate it for C64 compatibility in emulation mode
5. Verify standalone synthesis: `.\build_c64.ps1 -SyntaxOnly`

**Key decision:** Use the SNES core's P65C816 (complete, proven) rather than trying to
enable T65's incomplete Mode="11" 65C816 support.

**Files created:**
- `C64_MiSTer/rtl/65C816/*.vhd` — copied from SNES core
- `C64_MiSTer/rtl/cpu_65c816.vhd` — compatibility wrapper

**Verification:**
- Syntax check passes with new files included in project
- Wrapper entity ports match cpu_6510 interface (plus bank_addr, emulation_mode)

---

## Phase 2: Dual-CPU Infrastructure
**Goal:** Instantiate both CPUs, MUX between them based on the OSD toggle from Phase 0.

**Tasks:**
1. In `fpga64_sid_iec.vhd`, instantiate `cpu_65c816` alongside existing `cpu_6510`
2. Add MUX logic controlled by `supercpu_enable`:
   - When OFF: cpu_6510 drives addr/data/we (identical to vanilla core)
   - When ON: cpu_65c816 drives addr/data/we, cpu_6510 held in reset
3. Wire `bank_addr` out through fpga64_sid_iec to c64.sv (unused for now — all
   access stays in bank $00 which is the normal C64 memory map)
4. Wire `emulation_mode` status to an OSD indicator
5. Add the new VHDL files to `files.qip` so Quartus finds them
6. Full build and verify

**Critical constraint:** With `supercpu_enable = '0'`, the core MUST behave identically
to the unmodified version. No regressions allowed.

**Files modified:**
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — dual CPU instantiation, MUX
- `C64_MiSTer/c64.sv` — bank_addr wiring, status indicators
- `C64_MiSTer/files.qip` — add 65C816 source files

**Verification:**
- Full build succeeds
- With SuperCPU OFF: core boots to READY prompt (regression test)
- With SuperCPU ON: 65C816 in emulation mode should also boot (it's 6502-compatible)
- Resource usage increase noted (expected: +2000-4000 ALMs for second CPU)

---

## Phase 3: Clock Domain — 20MHz CPU
**Goal:** Run the 65C816 at 20MHz effective speed with proper bus arbitration.

**Tasks:**
1. Analyze the `sysCycleDef` state machine in `fpga64_sid_iec.vhd`:
   - Current: EXT(8) + DMA(4) + VIC(4) + CPU(16) = 32 cycles per 1MHz
   - Target: VIC(4) + DMA(4) + CPU_FAST(24) = 32 cycles (give 65C816 all remaining slots)
2. In SuperCPU mode, modify cycle allocation:
   - VIC-II keeps its 4 cycles (must not break video)
   - DMA keeps its 4 cycles (for REU compatibility)
   - 65C816 gets 24 enable pulses per 32-clock period → ~24MHz effective
   - Actual SuperCPU was 20MHz, so may need to skip some cycles
3. VIC-II badline stealing must still work — VIC gets priority, CPU stalls
4. I/O region ($D000-$DFFF) access throttle: when the 65C816 accesses I/O, slow to 1MHz
   so SID/VIC/CIA timing is correct
5. Do NOT modify the PLL — keep the 32MHz system clock, just change cycle allocation

**Human checkpoint required:** Bus arbitration changes risk breaking VIC-II timing.
Review waveforms or test with demos before proceeding.

**Files modified:**
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — state machine, enable generation

**Verification:**
- Full build succeeds
- SuperCPU OFF: still boots normally (regression)
- SuperCPU ON: boots faster, programs run at accelerated speed
- VIC-II output still correct (no visual glitches, no black screen)

---

## Phase 4: Extended Memory (24-bit Addressing)
**Goal:** Give the 65C816 access to 16MB address space via SDRAM.

**Tasks:**
1. Bank $00 = normal C64 64KB (RAM, ROM, I/O) — no change
2. Banks $01-$0F = SDRAM fast RAM (15MB, matching SuperCPU's 16MB)
3. Create `supercpu_mem.vhd` — memory controller that routes based on bank byte:
   - bank_addr = $00 → existing C64 memory bus
   - bank_addr != $00 → SDRAM via MiSTer framework
4. Study existing REU (`reu.v`) and SDRAM (`sdram.v`) for arbitration patterns
5. Wire through c64.sv to the MiSTer SDRAM interface
6. Implement SuperCPU memory mirroring (ROM shadowing in upper bank $00)

**Human checkpoint required:** SDRAM arbitration must not conflict with VIC-II DMA,
file loading, or the MiSTer framework's own SDRAM usage.

**Files created:**
- `C64_MiSTer/rtl/supercpu_mem.vhd` — bank-aware memory controller

**Files modified:**
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — memory routing
- `C64_MiSTer/c64.sv` — SDRAM interface wiring

---

## Phase 5: SuperCPU Control Registers
**Goal:** Implement hardware registers so SuperCPU software can detect and control the hardware.

**Tasks:**
1. Create `supercpu_regs.vhd` with registers at documented addresses:
   - `$D07A` — Speed control (read: current speed; write: set speed)
   - `$D07B` — Speed bit (0=1MHz, 1=20MHz)
   - `$D07C`-`$D07F` — Hardware identification (software reads to detect SuperCPU)
   - `$D0B0`-`$D0BF` — RAM configuration registers
2. Reference: VICE xscpu64 source (`src/scpu64/`) for exact register behavior
3. Reference: c64-wiki.com SuperCPU page for register addresses
4. Wire into I/O address decoder in fpga64_sid_iec.vhd

**Files created:**
- `C64_MiSTer/rtl/supercpu_regs.vhd`

**Files modified:**
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — I/O decode for SuperCPU registers

**Verification:**
- SuperCPU detection programs identify the hardware
- Speed switching between 1MHz and 20MHz works

---

## Phase 6: D2M Disk Image Support
**Goal:** Support CMD HD D2M disk images needed for SuperCPU Doom.

**Tasks:**
1. Add D2M as recognized file extension in c64.sv CONF_STR
2. Implement D2M-to-sector translation (D2M is a raw sector dump format)
3. This is primarily HPS-side (ARM Linux) file I/O + C64 IEC protocol work
4. May require modifications to the 1541/1581 drive emulation

**Note:** This phase is the least well-documented and most likely to need extensive
human guidance. Consider deferring until Phases 0-5 are solid.

---

## Phase 7: Integration Testing and Polish
**Goal:** End-to-end verification with real SuperCPU software.

**Tasks:**
1. Regression: C64 KERNAL boots in 6510 mode (must pass)
2. Regression: Lorenz CPU test suite passes in 6510 mode
3. SuperCPU toggle via OSD: boots with 65C816 in emulation mode
4. Run SuperCPU detection software
5. Load simple SuperCPU-enhanced programs
6. Test Wolfenstein 3D (SuperCPU port)
7. Test Doom (SuperCPU port, requires Phase 6)
8. FPGA resource utilization check — must fit within Cyclone V budget
9. Timing closure check — no negative slack on critical paths

---

## Risk Assessment

| Phase | Risk | Mitigation |
|-------|------|------------|
| 0 | Very low | Trivial change, easy to revert |
| 1 | Low | Copying proven SNES core, wrapper is structural |
| 2 | Medium | MUX logic is straightforward but must not regress |
| 3 | **High** | Bus arbitration is timing-critical, VIC-II interaction is subtle |
| 4 | **High** | SDRAM arbitration complexity, race conditions possible |
| 5 | Low | Register logic is straightforward, well-documented |
| 6 | **High** | Poorly documented format, may need custom drive emulation |
| 7 | Medium | Testing-focused, issues found here may require revisiting earlier phases |

## Resource Budget Estimate

| Component | ALMs (est.) | Notes |
|-----------|-------------|-------|
| Vanilla C64 core | ~26,300 | Current baseline |
| 65C816 CPU core | +3,000-5,000 | Based on SNES core size |
| Memory controller | +500-1,000 | Bank routing logic |
| SuperCPU registers | +200-400 | Simple register file |
| MUX/glue logic | +100-300 | CPU selection |
| **Total estimate** | ~30,000-33,000 | Of 41,910 ALMs available (~75-79%) |

The Cyclone V has headroom for this, but it will be tight. Monitor after each phase.
