# SuperCPU Full Implementation Plan — vanilla-cpu-swap → Doom-capable

**Date**: 2026-05-11
**Branch**: `vanilla-cpu-swap` (tip `b49c489`)
**Trigger**: User pivot — "I think we might as well implement everything we
can, and then begin to debug it using doom"
**Constraint**: NO MiSTer hardware access for the foreseeable plan window
(other agent owns the device). All work is off-device: RTL drafting +
GHDL benches + cocotb diff + VICE source reads.

This document supersedes the Doom-only scope of `docs/vice_scpu_reu_logic_plan.md`.
That plan stays valid as the **REU/EPROM slice** of the bigger picture
described here.

---

## 1. TL;DR

`vanilla-cpu-swap` branched off `master` at commit `a1e5c95` (v169 era,
late April 2026). Since then **master** has accumulated many SCPU
correctness fixes (most notably the **IOF falling-edge** REU timing
fix) that this branch never received. Meanwhile **vanilla-cpu-swap** has
gone 137 commits deep into Doom-debug instrumentation — but the
underlying SCPU implementation here is **less complete** than master.

The right move now: stop hunting Doom-specific symptoms and instead
**bring vanilla-cpu-swap up to a true SCPU-spec implementation**, then
re-run Doom as the integration test.

**Sequenced phases** (each is a buildable, syncs to Doom progress):

| Phase | Scope | Doom expectation | Off-device feasible? |
|------:|-------|-------------------|---------------------|
| 0 | Audit + plan freeze | (none — paper) | YES |
| 1 | REU IOF falling-edge port | acks actually fire; clear v294/v296 wedges deterministically | YES (GHDL+cocotb) |
| 2 | I/O cycle stretching | REU + CIA + VIC register I/O reliable at 20 MHz | YES |
| 3 | EPROM-driven boot + RAM kernel | native BRK/IRQ/NMI vectors land in real handlers (not synthesized stubs) | YES |
| 4 | Bank $01 SRAM shadow | ROM shadow reads succeed; matches VICE memory map | YES (sim only) |
| 5 | WriteSmart + write buffer drain | perf doubles; turbo writes don't bottleneck | YES |
| 6 | $D0BC R/W + $D0BE/$D0BF DOS extension | software-detect parity with real HW | YES |
| 7 | $D078 unrepurpose + bootmap ROM mapping | EPROM-on-reset path identical to VICE | YES |
| 8 | 1 MHz badline emulation | VIC-driven titles don't drift in turbo | YES |
| **Doom gate** | Hardware regression on Doom REU + game start | reaches first playable frame | NO — needs MiSTer (deferred) |

Phases 1-8 produce a single clean RBF that we **don't deploy** until
MiSTer is free. All correctness gating happens in cocotb + GHDL.

---

## 2. Gap audit — master features missing on vanilla-cpu-swap

Cross-reference: `docs/supercpu_feature_status.md` (master-aligned,
dated 2026-04-25) vs current `vanilla-cpu-swap` HEAD.

### 2.1 Confirmed missing (verified via `git diff master..vanilla-cpu-swap`)

| Feature | Master location | vanilla-cpu-swap state | Evidence |
|---|---|---|---|
| **IOF falling-edge pulse generator** (`iof_fall_pulse_r`) | `fpga64_sid_iec.vhd:925-933` master | absent on this branch | `Grep iof_fall` → no matches in `C64_MiSTer/` |
| **reu.v cpu_cs driven by 1-cycle pulse** | `c64.sv:825` master | `c64.sv:661` `cpu_cs(IOF)` (raw) | direct file inspection |
| **iof_we_latched / iof_addr_latched / iof_dout_latched** REU input wiring | `c64.sv:821-824` master | reu.v wired to raw `c64_addr/c64_data_out/ram_we` | direct file inspection |
| **CPUE fallback for IOF reads** | per commit `295db8e` (on this branch but never integrated with falling-edge) | partially present | commit log |
| **`reu_reg_status`/`reu_reg_cmd` bypass mux** (direct register exposure) | `c64.sv:830-845` master | uses CPU readback only | direct file inspection |
| **VICE-aligned SCPU64 EPROM dprom at bank $F8** | master had it; we just landed v298 | NOW DONE (commit `0f0a52c`) | v298 commit |
| **Bank $01 SRAM shadow (64 KB)** | partial on master via `e8cbf39` cherry | partial on vanilla-cpu-swap too | per Phase D minimal SCPU memory |
| **`cacheable_wr` / write buffer drain** | DISABLED on master, infra exists | also disabled here | structural — never enabled |

### 2.2 Confirmed missing per `docs/supercpu_feature_status.md` (both branches)

These are gaps on master too — we're not catching up, we're filling in.

| Feature | Spec ref | Where it would live | Difficulty |
|---|---|---|---|
| **WriteSmart $D074-$D077 enforcement** (mirror mask) | spec §6 | `fpga64_sid_iec.vhd` write path | High |
| **$D0B3 enhanced opt (V2)** | spec §6 | new decode + ZP/stack exclusion logic | Med |
| **$D078 SIMM config (un-repurpose cache flush)** | spec §6 | move flush to free register | Low |
| **$D0BC write path** (currently read-only) | spec §6 | add `case 16#BC#` in write decoder | Trivial |
| **$D0BE/$D0BF DOS extension** | spec §6 | new register handlers; no software impact for Doom | Low |
| **Bootmap ROM $F0-$FF in bootmap=1** | spec §5 | dprom + cs decode in `fpga64_buslogic.vhd` | Med |
| **EPROM-driven boot at reset** | (this plan) | RESET vector → $F8:$FFFC path | Med |
| **RAM-resident IRQ kernel at $801A-$8054** | spec §5 + EPROM disasm | mux-out, copied by EPROM on boot | Med |
| **I/O cycle stretching at $DFxx/$DCxx/$DDxx** | VICE `scpu64cpu.c` | sysCycleDef extension or per-access stall | Med-High |
| **1 MHz badline emulation in turbo** | spec §7 | VIC bus pause during raster fetch | Med |
| **Cache `cacheable_wr` re-enable + FIFO drain** | spec §8 | `cpu_cache.vhd` per v164 path-(b) | High |

### 2.3 Vanilla-cpu-swap unique additions (worth preserving)

These are wins **only on this branch** — must not be lost in the master-port:

- ⭐ DBG_UART pool-dump infrastructure (`rtl/debug/`, hardcoded ON)
- ⭐ Modular debug gates (`DBG_TRACE`/`DBG_UART`/`DBG_OVERLAY`/`DBG_BUS_CAPTURE`)
- ⭐ Doom-specific wedge instrumentation (`pc_main_r`, `pc_irq_r`, OP/R7 probes)
- ⭐ 27-byte ack stub mux at `$00:$FF00..$FF1A` (Doom workaround)
- ⭐ Native-vector intercept `$00:$FFE4..$FFEF` → `$00:$FF00` (v286)
- ⭐ Bank-$01 SRAM ROM-shadow (commit `e8cbf39`, partial)
- ⭐ EPROM dprom at bank `$F8` from VICE SCPU64 V0.07 (v298)
- ⭐ cocotb + VICE oracle differential testing (Layers 1-3 GREEN)
- ⭐ Verification benches under `sim/cocotb/` — make targets:
  `test-doom-loader`, `test-doom-bank20`, `test-doom-gameplay`,
  `test-doom-loader-body`

---

## 3. VICE source map per missing feature

(All paths under `github.com/VICE-Team/svn-mirror/vice/src/`.)

### 3.1 REU register clearing
- `c64/cart/reu.c:174-176` — `case REU_REG_R_STATUS` clears `status &= ~0xE0`
  AND `maincpu_set_irq(reu_int_num, 0)` on read.
- `c64/cart/reu.c:109` — `irq <= (|(status[6:5] & intr[6:5])) & intr[7]`.
- Our `reu.v:174` already implements this. The bug is upstream: cpu_cs
  never asserts cleanly at $DFxx in turbo mode.

### 3.2 I/O cycle stretching
- `scpu64/scpu64cpu.c:scpu64_clock_read_stretch_io()` — stalls CPU clock
  for the number of cycles needed for a 1 MHz device read.
- `scpu64/scpu64cpu.c:scpu64_clock_write_stretch_io_start/end()` — paired
  stretch for writes.
- `scpu64/scpu64mem.c:scpu64_clock_read_stretch_io` calls — every $Dxxx /
  $E000-$FFFF I/O access calls one of these.
- **FPGA analogue**: extend `sysCycleDef` so CPU phases stall N extra
  clk32 cycles when `cs_io='1'`, OR add a "stretch counter" that pulls
  `enableCpu_816` low for the stretch duration.

### 3.3 EPROM-driven boot
- `scpu64/scpu64-cmdline-options.c` / `scpu64/scpu64rom.c` — loads
  `scpu64.rom` (64KB) at boot.
- `scpu64/scpu64mem.c:scpu64_mem_pla_config_changed()` — switches between
  bootmap (EPROM in $F0-$FF) and non-bootmap modes per `mem_reg_bootmap`.
- `scpu64/scpu64mem.c` $D0B6/$D0B7 register handlers — toggle
  `mem_reg_bootmap`.
- EPROM RESET vector at `$F8:$FFFC` = `$00FC` → ends up at `$F8:$80C1`
  which is the kickstart copy loop.

### 3.4 RAM kernel install (handlers at $801A-$8054)
- The EPROM does this itself — we just need to let it run.
- Disassembly (from session_handoff):
  ```
  COP   (native) $FFE4/5 = $FC98 → JML $00:$801A
  BRK   (native) $FFE6/7 = $FC9C → JML $00:$801A
  ABORT (native) $FFE8/9 = $FCA0 → JML $00:$8051
  NMI   (native) $FFEA/B = $FCA4 → JML $00:$8023
  IRQ   (native) $FFEE/F = $FCAC → JML $00:$8025
  ```
- The kickstart routine in EPROM `$F8:$80C1` copies 53 bytes from
  `$F8:$xxxx` (EPROM area) to `$00:$801A`. After that, ALL handlers run
  from RAM.

### 3.5 WriteSmart
- `scpu64/scpu64mem.c:mem_reg_optim` — set by writes to $D074-$D077.
- `scpu64/scpu64mem.c:store_*()` family — checks `mem_reg_optim` to
  decide whether to mirror to slow C64 DRAM.
- Mapping to our RTL: §6 of `supercpu_feature_status.md` has the
  exact ranges per opt mode.

### 3.6 Bootmap ROM
- `scpu64/scpu64mem.c:scpu64_mem_pla_config_changed()` calls into
  `mem_set_bootmap()` which remaps banks $F0-$FF to point at the EPROM
  image when `mem_reg_bootmap=1`.

### 3.7 SIMM config ($D078)
- `scpu64/scpu64mem.c:mem_set_simm()` — configures SIMM size mux
  (1/4/8/16 MB). For us this is the SDRAM REU region size — already
  16 MB, so the register is informational. But we need to **stop using
  $D078 for cache flush** to avoid VICE/SW-detect divergence.

---

## 4. EPROM disassembly — full vector summary

Source: VICE `data/SCPU64/scpu64.rom` (Wiebo de Wit V0.07, 64 KB),
loaded at bank `$F8` in v298.

```
RESET (emu)   $FFFC/D = $FC90 → JML $F8:$00FC → JML $F8:$80C1 (kickstart)
COP   (emu)   $FFF4/5 = $FC?? → JML $F8:$????  (rarely used)
ABORT (emu)   $FFF8/9 = $FC?? → JML $F8:$????  (rarely used)
NMI   (emu)   $FFFA/B = $FC?? → JML $F8:$????
IRQ/BRK (emu) $FFFE/F = $FC94 → JML $00:$8054

RESET (nat)   $FFFC/D = $FC90 → same as emu
COP   (nat)   $FFE4/5 = $FC98 → JML $00:$801A
BRK   (nat)   $FFE6/7 = $FC9C → JML $00:$801A
ABORT (nat)   $FFE8/9 = $FCA0 → JML $00:$8051
NMI   (nat)   $FFEA/B = $FCA4 → JML $00:$8023
IRQ   (nat)   $FFEE/F = $FCAC → JML $00:$8025
```

RAM-resident handler layout after kickstart:
```
$00:$801A  COP/BRK handler (entry)
$00:$8023  NMI handler
$00:$8025  IRQ handler  ← Doom's REU FETCH IRQ lands here when wired right
$00:$8051  ABORT handler
$00:$8054  IRQ/BRK (emu) handler
```

What this means for us: once EPROM boot runs, the **synthesized 27-byte
stub at `$00:$FF00..$FF1A`** becomes redundant. Real handlers live at
`$00:$8025` etc. and they DO know how to read `$DF00` to ack REU.

---

## 5. Prioritized implementation order

Each phase: **what** + **why** + **acceptance test** + **estimated effort**.

### Phase 1 — Port IOF falling-edge fix (1-2 days)

**What**: bring back commits `iof_fall_pulse_r` + latched cpu_we/addr/dout
into `fpga64_sid_iec.vhd`, route them through `c64.sv` into `reu.v`'s
`cpu_cs`/`cpu_we`/`cpu_addr`/`cpu_dout` ports. Master's reference
is `fpga64_sid_iec.vhd:916-937` and `c64.sv:815-826`.

**Why**: without this, ANY `$DFxx` access from SCPU turbo mode is too
short for REU to register. v299's `LDA $00DF00` ack-stub read is currently
a no-op on this branch — verified by re-runs showing the wedge persists.

**Acceptance test** (cocotb, off-device):
- New `sim/cocotb/tests/test_reu_iof_ack.py`: drive SCPU turbo at 20 MHz
  effective, do `LDA $00DF00`, verify `reu.v status[7:5]` clears AND
  `irq` deasserts.
- Existing `test_brk_native_rti.py` (DUT-only, no VICE) should still pass.

**Estimated**: 1-2 sessions. Mechanical port.

### Phase 2 — I/O cycle stretching (2-3 days)

**What**: when CPU is in turbo and accesses `cs_io='1'` (any of
$D000-$DFFF), stall `enableCpu_816` for a configurable count (3-5 clk32
cycles seems right per VICE comments). Implemented as a stretch counter
gating `enableCpu_816` in `fpga64_sid_iec.vhd:1232-1262`.

**Why**: REU isn't the only 1 MHz device. VIC raster registers, CIA1/2
timers, SID — all benefit. Cycle stretching mimics VICE
`scpu64_clock_*_stretch_io()` exactly.

**Acceptance test** (cocotb):
- `test_io_stretch.py`: turbo CPU writes to $D020 (VIC border color);
  measure clk32 cycle count from `enableCpu_816` falling on `cs_io`
  to next `enableCpu_816` rising. Expect ≥3 clk32 stretch.
- Doom GHDL/cocotb integration: `test_doom_loader_diff` should still
  MATCH (5000 instr) — stretch must not affect correctness.

**Estimated**: 2-3 sessions. Tricky because the bus arbitration FSM is
already complex.

### Phase 3 — EPROM-driven boot + RAM kernel (2-3 days)

**What**:
- (a) Reset vector path: on system reset with SCPU enabled, force
  RESET fetch to read `$F8:$FFFC` (EPROM) instead of bank-$00 RAM.
- (b) Keep EPROM at $F8 visible in native mode (already partially
  done in v298 — verify).
- (c) Disable the 27-byte synthesized ack stub at `$00:$FF00`: it's
  redundant once EPROM-installed RAM handlers exist.
- (d) Disable the `$00:$FFE4..$FFEF` mux intercept: EPROM writes real
  vectors here.

**Why**: pivots Doom's IRQ handling from our hand-rolled mux stub to
the real SCPU64 EPROM IRQ chain. Matches VICE behavior bit-for-bit.

**Acceptance test** (cocotb):
- New `test_eprom_boot_kickstart.py`: cold reset → run 4096 fetches →
  verify $00:$801A through $00:$8054 contain non-zero bytes matching
  the EPROM's kickstart copy data.
- Existing Doom diff tests should still MATCH (the EPROM doesn't run
  during gameplay).

**Estimated**: 2-3 sessions. Most of the work is verifying the EPROM
binary in v298 is actually byte-identical to VICE's.

### Phase 4 — Bank $01 SRAM shadow (3-5 days)

**What**: 16 KB BRAM region for $01:A000-$01:DFFF (BASIC + CHARGEN);
for $01:E000-$01:FFFF (KERNAL) reuse the 64 KB BRAM via bank-bit aliasing.
Boot stub (or EPROM) copies ROM during first ~256 cycles.

**Why**: matches real HW. Some titles read bank-$01 ROM shadows directly.

**Acceptance test**:
- GHDL bench `bank01_sram_tb` (already exists per master) — port and run.
- Lorenz Test Suite (T65 mode regression) — must stay GREEN.

**Estimated**: 3-5 sessions. M10K-constrained; may need to shrink cache
to fit.

### Phase 5 — WriteSmart + write buffer drain (5-10 days)

**What**: per `docs/supercpu_feature_status.md` §6 and §8, plus v164
path-(b) design from memory `project_v164_writebuf_path_b_design.md`.

**Why**: largest perf gap (4 MHz → 10-15 MHz potential).

**Acceptance test**: cache coherency PRG, plus Doom should run faster
than current.

**Estimated**: 5-10 sessions. High risk — past 4 attempts (v159/v161/v164)
all black-screened on hardware. Off-device cocotb harness is REQUIRED
before re-deploying.

### Phase 6 — $D0BC R/W + $D0BE/$D0BF DOS extension (1 day)

**What**: trivial RTL additions in `fpga64_sid_iec.vhd` register
decoder. Per VICE `scpu64mem.c` $D0BC/BE/BF handlers.

**Why**: software detect parity. Low impact for Doom, but useful for
JiffyDOS-class titles.

**Acceptance test**: PRG that reads/writes registers, checks readback.

### Phase 7 — $D078 unrepurpose + bootmap ROM (1-2 days)

**What**:
- Move cache flush from `$D078` to a free register (e.g., `$D0BD`)
- Implement bootmap ROM mapping in `fpga64_buslogic.vhd` so that when
  `mem_reg_bootmap=1`, banks $F0-$FF serve EPROM data instead of SDRAM

**Why**: VICE-parity for any software that polls $D078 SIMM size.
Bootmap is what EPROM expects.

**Acceptance test**: software reads $D078 → gets 0x40 (16 MB SIMM); test
PRG verifies bootmap toggle via $D0B6/B7.

### Phase 8 — 1 MHz badline emulation in turbo (2-3 days)

**What**: when VIC is doing badline fetches, pause CPU like real HW.

**Why**: demo compatibility, but also affects some games.

**Acceptance test**: VIC demo regressions; visual gating only.

### Doom integration gate (hardware-required)

After Phases 1-3 land cleanly off-device, deploy ONE RBF to MiSTer
and run:
1. `doom_v298_transition_zoom.py` — must NOT show $2B:$2292 wedge.
2. `doom_v298_wedge_capture.py` — must NOT show $0F BRK-march.
3. Visual: Doom title splash + first playable frame.

If wedges persist, the bug is in Phase 5+ territory (data layer, REU
SuperRAM coupling). If gone, run the cocotb diff harness extended past
2499 instructions to find the next divergence.

---

## 6. Session-by-session plan (assuming NO MiSTer)

| Session | Goal | Output |
|---|---|---|
| **A (now)** | This plan + Phase 1 RTL draft | new `iof_fall_pulse_r` block in `fpga64_sid_iec.vhd`, syntax-checked |
| **B** | Phase 1 cocotb test | `test_reu_iof_ack.py` PASS |
| **C** | Phase 2 RTL draft + bench | stretch counter + `test_io_stretch.py` PASS |
| **D** | Phase 2 integration + Doom diff re-run | `test-doom-loader` still MATCH |
| **E** | Phase 3 EPROM boot path | `test_eprom_boot_kickstart.py` PASS |
| **F** | Phase 3 RAM kernel verify | mem dump $00:$801A-$8054 matches VICE expected |
| **G** | Phase 4 bank $01 SRAM | `bank01_sram_tb` PASS + Lorenz green |
| **(MiSTer frees)** | Doom gate | deploy ONE RBF; run wedge probes |

---

## 7. Risks and mitigations

### 7.1 Quartus M10K block budget
Current 73% RAM, 64% ALM. Phase 4 (bank $01 SRAM) adds 16 KB BRAM.
Phase 5 (write buffer FIFO) and Phase 7 (bootmap dprom) also consume
M10K. If we exceed 95% RAM, fitter will fail.

**Mitigation**: M10K R3 (4 KB cache) was a one-time reclaim and is
already cashed. If we need more: shrink cache to 2 KB, or move IRQ stub
out of dprom (now redundant after Phase 3 anyway).

### 7.2 Cycle stretching can break timing
Phase 2 adds a stall path that may push clk64 critical path past
-1 ns slack. Master tried similar and reverted twice.

**Mitigation**: implement as a CPU-enable gate (purely combinational
on enableCpu_816), NOT as a sysCycleDef extension. Less invasive.

### 7.3 Doom-specific instrumentation may rot
The 27-byte stub mux + native-vector intercept + DBG_UART pool dump are
heavy customizations of `fpga64_sid_iec.vhd`. Phase 3 disables the
first two; they should be guarded behind a `DOOM_SHIM` macro for
quick revert.

**Mitigation**: wrap our Doom-specific shims in compile-time gates
BEFORE starting Phase 3.

### 7.4 Master diverged too far to cleanly port
`git diff master..vanilla-cpu-swap -- C64_MiSTer/rtl/fpga64_sid_iec.vhd`
shows 4528 lines changed. Cherry-picking individual master commits
will conflict heavily.

**Mitigation**: don't cherry-pick. Read master's code as reference,
manually re-implement on top of our current state. Phase 1 is a clean
~50 line addition.

### 7.5 Lockstep cocotb diff harness is the only correctness check
With no MiSTer access, we can't validate that the RTL changes don't
break stock C64 boot, Lorenz, SST sweep, etc.

**Mitigation**: prioritize the GHDL benches that DO work off-device:
- `sim/p65c816_tb/` (CPU-class)
- `sim/c64_reduced_harness/` (system-class)
- `sim/cocotb/` (DUT vs VICE)
Run all three after each phase. Defer hardware-only regressions
(Lorenz, SST sweep, library compat sweep) to the post-MiSTer session.

---

## 8. What this plan does NOT cover

- **Phase 5 (write buffer)** is high-risk and may need its own dedicated
  hardware iteration. If it stalls, defer to a post-Doom-works session.
- **20 MHz parity** with real HW is explicitly out of scope. Architecture
  ceiling on Cyclone V is ~12-15 MHz effective per `supercpu_feature_status.md` §7.
- **Demo compatibility regressions** (badlines, sprite-VIC races) are
  Phase 8 territory; defer until MiSTer is free.
- **REU diagnostic registers** ($DFA1-$DFBF on master) — useful but not
  blocking. Add ad-hoc when needed.

---

## 9. Files this plan touches

Direct edits:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — Phases 1, 2, 6, 7, 8
- `C64_MiSTer/c64.sv` — Phase 1 (REU wiring), Phase 7
- `C64_MiSTer/rtl/fpga64_buslogic.vhd` — Phase 7 (bootmap ROM)
- `C64_MiSTer/rtl/cpu_cache.vhd` — Phase 5 only

New files:
- `sim/cocotb/tests/test_reu_iof_ack.py` — Phase 1 acceptance
- `sim/cocotb/tests/test_io_stretch.py` — Phase 2 acceptance
- `sim/cocotb/tests/test_eprom_boot_kickstart.py` — Phase 3 acceptance

Updated docs:
- `docs/session_handoff.md` — track per-phase progress
- this file — mark phases complete as they land

---

## 10. Entry point for the next session

Start Phase 1: port IOF falling-edge.

1. Read `master:C64_MiSTer/rtl/fpga64_sid_iec.vhd` lines 916-937 (the
   `iof_fall_pulse_r` block) and lines 359, 225 (signal/port decls).
2. Read `master:C64_MiSTer/c64.sv` lines 815-826 and 1914, 1923, 2404
   (top-level wiring).
3. Insert equivalent block into current `fpga64_sid_iec.vhd` (where
   `IOF <= iof_i;` lives at line 1371).
4. Modify `c64.sv:657-661` to use the new latched signals + pulse.
5. Run `build_c64.ps1 -SyntaxOnly` to catch typos.
6. Write `test_reu_iof_ack.py` and validate.

NO MiSTer access. Once Phase 1 cocotb passes, decide whether to chain
into Phase 2 or hand off for hardware deploy.
