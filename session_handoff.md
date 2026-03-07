# Session Handoff — SuperCPU @ Display Artifact FIXED

**Last updated:** 2026-03-07

## Read These Files First (in order)
1. `CLAUDE.md` — Project overview, build commands, architecture
2. `docs/archive/HYPOTHESIS_TRACKER.md` — 31 hypotheses, root cause found and fixed
3. `docs/sdram_vic_datapath.md` — Complete SDRAM-to-VIC data path analysis
4. `memory/p65c816_findings.md` — P65C816 core fixes applied/deferred

## Current State Summary

### The Problem — SOLVED ✅
When SuperCPU (65C816) was enabled, display artifacts appeared (scrolling `@` characters
and lines) on the READY screen. T65 (6510) mode was clean.

### Root Cause: P65C816 frozen WE during badline halt (H31)

When BA goes low (VIC badline), the T65 completes in-progress writes via
`really_rdy = Rdy OR NOT WRn_i`, then halts on the next read cycle with `cpuWe='0'`.

The P65C816 halts IMMEDIATELY (even mid-write) because `EN = RDY_IN AND CE`. Its WE
output freezes at `'1'` (write active). At VIC3, the `cpuHasBus` logic sees `cpuWe='1'`
and grants the bus to the CPU:

```
systemAddr = cpuAddr (CPU's frozen write address)
instead of: systemAddr = vicAddr (VIC screen RAM address)
```

The VIC's c-access reads wrong data → display corruption.

### The Fix (one line)

```vhdl
-- fpga64_sid_iec.vhd, CPU MUX section:
cpuWe_pre <= (cpuWe_816 and baLoc) when supercpu_en = '1' else cpuWe_6510;
```

When BA is low, force system-visible WE to '0' (read). The P65C816 is already halted,
so no write is lost — it completes when BA goes high and the CPU resumes.

### Diagnostic Evidence

1. **T65-as-SuperCPU test:** P65C816 instantiated (FPGA routing pressure) but T65 drives
   the bus → artifact DISAPPEARS. Proves P65C816 behavioral outputs are the cause.
2. **cpuWe fix:** `cpuWe_816 AND baLoc` → artifact GONE. Games tested and working.

### Why Indirect Addressing Triggered It

Indirect modes (`LDA ($zp),Y`) take 7 cycles on P65C816 (vs 5-6 on T65) due to 2 phantom
cycles. Longer instruction time = higher probability that KERNAL IRQ handler writes (stack
push, STA) coincide with a badline. Absolute modes take fewer cycles = lower collision
probability, which is why M9 (absolute) was clean but M8 (indirect) triggered.

### Previous Fixes Applied (still active)

- **Hold register DISABLED** — was injecting wrong data ($00 from ZP reads via early CE)
- **Early CE DISABLED** — CPU8 SDRAM reads returned ZP data, not screen data
- **Turbo slots gated with cpuHasBus** — prevent wasted SDRAM reads during badlines
- **IRQ B-flag fix** (P65C816.vhd): clears bit 4 for hw IRQ/NMI in emu mode
- **XCE D-register reset** (P65C816.vhd): clears D on XCE to emu mode

### Previous VDA/VPA Gating — Why It Failed

The VDA/VPA gating attempt (commit f14a259, reverted b917948) was architecturally correct
(the real SuperCPU does this) but had two implementation bugs:
1. Suppressing `cpu_cyc` during phantom cycles also suppressed `enableCpu` (derived from
   `cpu_cyc` via 2-stage shift register), deadlocking the CPU in phantom states.
2. During badlines, frozen VDA=0/VPA=0 suppressed the VIC's c-access CE at CPUC.
Future re-implementation should gate `ramCE` separately from `cpu_cyc`.

## What's Next

### Phase 3: Clock Domain & Turbo Speed
- Implement 20MHz effective CPU speed (turbo via extra SDRAM slots)
- Implement SuperCPU control registers ($D07A-$D07F speed control)
- I/O access must synchronize to 1MHz (real SuperCPU behavior)

### Future VDA/VPA Gating
- Gate `ramCE` and `ramWE` on VDA/VPA, but NOT `cpu_cyc` (preserve enableCpu)
- Only gate during CPU bus ownership (cpuHasBus='1'), not during VIC c-access
- Use SingleStepTests/65816 JSON vectors to verify P65C816 VDA/VPA correctness

### Real SuperCPU Architecture Reference
- 128KB dedicated SRAM (separate from VIC DRAM — zero contention)
- 1-byte write buffer for C64 DRAM mirroring
- VICE source: `src/scpu64/scpu64cpu.c`
- SuperCPU CPLD reverse-engineered: Altera EPM7064LC84
- Key article: Commodore Hacking #12, "Underneath the Hood of the Super CPU"

## Key Files

### Modified (relative to stock MiSTer C64)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — cpuWe fix + debug + hold/early CE disabled
- `C64_MiSTer/rtl/65C816/P65C816.vhd` — IRQ B-flag fix + XCE D-register reset
- `C64_MiSTer/rtl/fpga64_buslogic.vhd` — Address mux for SuperCPU
- `C64_MiSTer/rtl/cpu_65c816.vhd` — P65C816 wrapper
- `C64_MiSTer/c64.sv` — SDRAM mux, SuperCPU signals, debug wiring
- `C64_MiSTer/rtl/debug_overlay.sv` — On-screen hex display
- `C64_MiSTer/rtl/cartridge.v` — Cart type 99 for SuperCPU

### Unmodified (key reference)
- `C64_MiSTer/rtl/sdram.v` — SDRAM controller (clk64, q-counter)
- `C64_MiSTer/rtl/video_vicII_656x.vhd` — VIC-II
- `C64_MiSTer/rtl/cpu_6510.vhd` — T65 wrapper (for comparison)
- `C64_MiSTer/sys/` — MiSTer framework (READ ONLY)

## Build & Deploy

```powershell
.\build_c64.ps1              # Full build (~9.5 min)
.\build_c64.ps1 -SyntaxOnly  # Syntax check only

scp C64_MiSTer/output_files/C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf
```

## MiSTer Hardware
- IP: 192.168.50.130, SSH root/1
- Core: /media/fat/_Test/C64.rbf
- OSD: SuperCPU toggle = status[82], overlay = status[83], LED = status[85:84]
