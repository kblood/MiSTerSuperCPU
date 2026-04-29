# Minimal SuperCPU Plan — vanilla-cpu-swap → optional SuperCPU mode

**Branch:** `vanilla-cpu-swap`
**Goal:** Add a minimal CMD SuperCPU 64 implementation as an **OSD-toggleable
option** on top of the vanilla MiSTer C64 core. T65-based 6510 stays the
default; P65C816 + SuperCPU registers + SuperRAM via SDRAM + the genuine
kickstart ROM activate when the user enables SuperCPU mode in the OSD.

This is an **update to the existing C64 core**, not a fork. Vanilla 6510
behavior must remain bit-identical when SuperCPU is off.

---

## Strategy

Cherry-pick proven RTL from `master` rather than rewrite. Master spent ~30
hardware iterations stabilising these blocks; we lift the parts that work and
deliberately leave behind everything that's debug instrumentation,
performance accelerator, or accumulated workaround.

---

## Reuse map (from master)

| Lifted | Source | Lines | Why |
|---|---|---|---|
| `rtl/cpu_65c816.vhd` | master | 197 | Clean P65C816 wrapper — bank/emu_mode/VPA/VDA exports, NMI-ack via VPB, 6510 IO port, comb-currentIO Asterix fix |
| `rtl/65C816/*.vhd` | already in branch | — | P65C816 core sources (already on branch from earlier work) |
| `rtl/roms/scpu64.mif` | master | 64 KB | Genuine CMD kickstart ROM image |
| `$D07x` register block in `fpga64_sid_iec.vhd` | master | ~150 | VICE-verified read mux + write SM. State: `scpu_hwenable`, `scpu_regs_enabled`, `scpu_rom_vis`, `scpu_bootmap`, `scpu_speed_1mhz`, `scpu_optim_mode` |
| ROM patches in `fpga64_buslogic.vhd` | master | ~80 | `scpu_rom` dprom, `scpu_sysram` (512 B at $D200-$D3FF), `scpu_rom_en`, `scpu_io_en`, `scpu_sysram_cs`, sysram reset-sweep |
| `sdram.v` extra outputs | master | ~15 | `dout_hi`, `dout_lo`, `dout_reu` |
| `scpu_sdram_addr` mux + cpuDi clause | master | ~15 | Bank ≠ $00 → `{1, bank, addr16}`. Combinational (verified critical) |
| `iof_detect` bank-$00 gate | master | 1 | Prevents bank ≠ $00 `$DFxx` from triggering REU |
| `supercpu_bank` plumbing | master | port + signal | Out from fpga64_sid_iec, used by c64.sv for SDRAM addr + REU/IOF gating |
| Dual-CPU mux pattern | master | ~50 | `cpuAddr_6510 / cpuAddr_816` muxed on `supercpu_en`, separate `enableCpu_*` |

**Estimated total lift:** ~600 lines of RTL + the 64 KB ROM image.

## Skip from master (deliberately)

- `cpu_cache.vhd` + write-buffer + `c64_ram64k.vhd` — performance accelerators
  irrelevant at 1 MHz; source of v162-v166 cancel/drain race headaches.
- Bank-$01 SRAM dprom (Phase D from master) — real-CMD parity but not boot-
  required. Bank $01 will hit SuperRAM via SDRAM. ~13 M10K saved.
- 3-stage SuperRAM pipeline (`superram_enable_delay`) — only needed when turbo
  steals EXT slots. Use 2-stage initially.
- Debug overlay, UART formatter, trace ring buffer, bug-frozen, `dbg_diag`,
  `$DFxx` peek registers, autorun-link override, PRG-load-reset extension.
- `scpu_native_vec` (14-byte native-vector RAM) — superseded by the kickstart,
  which installs vectors itself.
- `scpu_rom_overlay` / `scpu_rom_opt` OSD knobs (master's late-stage debug
  toggles).
- Real 20 MHz turbo. CPU stays at 1 MHz (or vanilla turbo C128/Smart if user
  enables it via OSD).
- CMD-DOS commands (unrelated, drive-side).

---

## Phases

### Phase A — CPU wrapper + dual-instantiation (1 day)

- Drop `cpu_65c816.vhd` from master into `rtl/`. Update `files.qip`.
- In `fpga64_sid_iec.vhd`, instantiate **both** T65 (via current `cpu_6510`)
  and P65C816 (via `cpu_65c816`). Both fed clk + reset + irq/nmi.
- Add separate `enableCpu_6510` and `enableCpu_816` enable-gating: only the
  active CPU gets pulses (`supercpu_en` selects).
- Mux `cpuAddr / cpuDo / cpuWe / cpuIO / nmi_ack` from the selected CPU.
- Expose `addr_hi_816` (renamed `supercpu_bank` at port boundary) and
  `emu_mode_816` out of the entity.
- Port the `vanilla-cpu-swap` `rdy_gated <= rdy or not localWe` fix into
  `cpu_65c816.vhd`. Verify it doesn't already match.
- Add `supercpu_en` OSD bit in `c64.sv`. Default **off** (vanilla 6510).
- **Validation:** vanilla BASIC boots cleanly with `supercpu_en=0` (regression
  gate). With `supercpu_en=1` and no other phases done, machine resets but
  may not boot — that's expected.

### Phase B — `$D07x` register block (1 day)

- Lift the read-mux clauses + write SM from master's `fpga64_sid_iec.vhd`.
  Keep state: `scpu_rom_vis`, `scpu_hwenable`, `scpu_regs_enabled`,
  `scpu_bootmap`, `scpu_speed_1mhz`, `scpu_sys_1mhz`, `scpu_optim_mode`.
- Skip `scpu_native_vec` (kickstart will install vectors).
- Skip `scpu_rom_overlay` / `scpu_rom_opt` debug toggles.
- Init: `scpu_rom_vis=1`, `scpu_bootmap=1`, `scpu_hwenable=0`,
  `scpu_regs_enabled=1`, `scpu_speed_1mhz=0`, `scpu_optim_mode="11"`.
- **Validation:** `supercpu_en=1` with kickstart NOT yet wired: registers
  read sane defaults via probe; boot still hangs (kickstart not in ROM mux
  yet).

### Phase C — Kickstart ROM stack (1-2 days)

- Add `rtl/roms/scpu64.mif` (64 KB, untouched from master).
- In `fpga64_buslogic.vhd`:
  - Add ports: `supercpu_en`, `supercpu_rom`, `supercpu_rom_vis`,
    `supercpu_bank`.
  - Instantiate `scpu_rom` dprom (16-bit address, 64 KB).
  - Instantiate `scpu_sysram` (512 B at bank $00 `$D200-$D3FF`, plus reset-
    sweep counter).
  - Add `scpu_rom_en` decode: bank $F8 full + bank $00 `$8000-$9FFF` (gated
    by `supercpu_rom_vis`).
  - Add `scpu_io_en` gate: bank $00 only for I/O chip selects.
  - Update `romData` mux: `scpuRomData when supercpu_en & supercpu_rom &
    supercpu_rom_vis else romData_c64`.
  - Update read-back data path to mux `scpu_sysram_data` when
    `scpu_sysram_cs=1`.
- In `fpga64_sid_iec.vhd`: add `supercpu_rom` signal (always `'1'` on this
  branch — no OSD knob to toggle ROM-only mode), wire to buslogic instance.
- **Validation:** `supercpu_en=1`, machine boots through kickstart → C64
  KERNAL → BASIC READY prompt. This is the headline gate of the project.

### Phase D — SuperRAM via SDRAM (1-2 days)

- Apply 3 additive outputs to `sdram.v`: `dout_hi`, `dout_lo`, `dout_reu`.
- In `c64.sv`:
  - Add `scpu_sdram_addr` combinational mux: `{1'b1, supercpu_bank,
    dbg_cpu_addr}` when `supercpu_en && cpu_has_bus && supercpu_bank ≠ $00`,
    else `cart_addr`. Must be combinational.
  - Extend SDRAM input mux at `c64.sv:988`-style location to add SuperRAM
    addr/we/data path alongside REU and cart paths.
- In `fpga64_sid_iec.vhd`:
  - Add `iof_detect` bank-$00 gate.
  - Add cpuDi clause: `sdram_superram when (enableCpu='1' and
    superram_in_pipeline='1' and cpuWe_pre='0')`.
  - 2-stage pipeline (skip master's 3-stage `superram_enable_delay`).
- **Validation:** `STA $02:0000 / LDA $02:0000` round-trip works. Doom-class
  software not required.

### Phase E — Validation gate (1 day)

Hard gates (all must pass):
1. `supercpu_en=0`: vanilla BASIC boots, `38911 BYTES FREE`, no visual
   artifacts. (Regression gate against the vanilla-cpu-swap baseline.)
2. `supercpu_en=1`: kickstart hands off → BASIC READY.
3. `supercpu_en=1`: SuperCPU detection PRG (`scpu_test.prg` or equivalent)
   prints "SuperCPU present", reads sane values from `$D0B0`, `$D0B2`,
   `$D0B6`, `$D0BC`.
4. `supercpu_en=1`: long-store/long-load round-trip into bank $02 SuperRAM.
5. `supercpu_en` toggle off in OSD → reset → vanilla BASIC again. (Live
   regression check.)

Soft gates (nice-to-have, don't block):
- A small native-mode demo with software-installed IRQ handler.
- REU still works in both modes (vanilla retains REU; SuperCPU mode adds
  SuperRAM alongside).

---

## Resource forecast

Vanilla branch baseline: ALM 59 %, RAM 53 % (≈ 293 / 553 M10K).

| Add | ΔALM | ΔM10K |
|---|---|---|
| P65C816 core (alongside T65) | +~3500 ALMs (~7 %) | +0 |
| `cpu_65c816` wrapper + bank plumbing | +~50 ALMs | +0 |
| `$D07x` regs + write SM | +~150 ALMs | +0 |
| `scpu64.mif` 64 KB dprom | +0 | +~32 M10K |
| `scpu_sysram` 512 B | +0 | +1 M10K |
| Bus gates (rom_en, io_en, sysram_cs) | +~30 LUTs | +0 |
| SDRAM mux + IOF gate | +~20 LUTs | +0 |
| Dual-CPU mux | +~20 LUTs | +0 |

**Estimated landing:** ALM ~67 %, RAM ~60 %. Plenty of headroom.

If we later need to claw back: master's M10K R1 (drop 3 unused KERNAL dproms
+ chargen_j) frees ~52 M10K blocks. Easy small commit.

---

## Risks

- **Dual-CPU mux glitches.** Outputs from the inactive CPU might leak if mux
  isn't strict. Mitigate: gate by `supercpu_en` registered, not combinational
  flapping during reset.
- **Kickstart MVN to bank $01** without bank-$01 SRAM goes to SuperRAM
  (SDRAM). Should work — master booted this way before v167 — but slower.
  Watch for boot wedge during MVN block-moves.
- **SIMM detection at bank $F6** must return RAM. SuperRAM mux covers all
  bank ≠ $00 → SDRAM, so this works automatically.
- **`scpu_rom_vis` reset coupling.** When user toggles SuperCPU on/off in
  OSD, `scpu_rom_vis` must reset to 1 so kickstart starts fresh. Master's
  pattern: rising edge of `supercpu_en` triggers state reset. Lift verbatim.
- **REU + SuperRAM SDRAM contention.** REU uses `reu_ram_active` slot,
  SuperRAM uses CPU slots. They don't overlap on the cycle wheel; vanilla
  REU keeps working. Verify with REU test in `supercpu_en=1` mode.
- **Timing closure.** `scpu_sdram_addr` is combinational and crosses
  `clk32`/`clk64` boundary. Master had timing margins; we should re-check
  TimeQuest after Phase D. Target: clk32 / clk64 slack non-negative.

---

## Out of scope (Phase F+ if ever)

- Real 20 MHz turbo (just a clock-multiplier change in the bus state machine,
  but interacts with REU + SuperRAM arbitration; defer until baseline solid).
- Bank-$01 SRAM shadow (real CMD parity).
- cpu_cache + write buffer (only relevant under heavy turbo).
- Doom support (likely needs Phase F + extra debug instrumentation reinstated).
- Asterix-SCPU support.
- CMD-DOS commands.
- UART debug overlay (only reinstate if a debug session demands it).

---

## Validation targets per phase

| Phase | Hardware test | Pass criterion |
|---|---|---|
| A | `supercpu_en=0` boot; `supercpu_en=1` no-crash | BASIC READY in 6510 mode; SuperCPU mode resets cleanly |
| B | `$D0Bx` peek via PRG | Reads return defined values |
| C | Cold boot SuperCPU mode | Kickstart hand-off → READY |
| D | `STA $02:0000` / `LDA $02:0000` PRG | Round-trip works |
| E | OSD toggle + REU PRG | Both modes work; REU unaffected |

---

## Commit hygiene

One commit per phase. Each commit:
- Updates this doc's phase table with hardware test result.
- Cites the master commit(s) cherry-picked, if any.
- Includes the exact `mister_debug.py` invocation that validated the phase.

Phase E commits a tagged release (`v200-minimal-scpu` say) — clean baseline
for any future SuperCPU work.
