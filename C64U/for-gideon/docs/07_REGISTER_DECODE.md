# SuperCPU register decode — exact literal values

This is the **read** decode lifted verbatim from our RTL
(`fpga64_sid_iec.vhd`, the `cpuDi_nocache` mux ~line 2353) and cross-checked
against VICE `xscpu64`'s `scpu64_hardware_read` and against silicon. Use it as a
direct implementation spec.

All status clauses gate on **`supercpu_en='1'`** AND **`addr_hi='$00'`** (the
24-bit bank-high byte) so they never intercept reads in 6510 mode or in non-zero
banks. The `$D0Bx` / `$D07E` clauses additionally gate on `scpu_regs_enabled`
(set by a write to `$D07E`, cleared by `$D07D`/`$D07F`). The `$D27x` SuperRAM
extent bytes are intentionally **not** gated on `scpu_regs_enabled` (real SRAM is
always present).

> **One hard-won lesson (see the comment block at line ~2329):** the address
> compare for these registers **must use the latched 16-bit CPU address**, not a
> `cs_vic + cpuAddr(11:0)` form. On the 65C816 turbo/bridge path `cs_vic`
> deasserts *before* the data-sample edge, so a `cs_vic`-gated decode reads back
> `$FF` / VIC-mirror garbage. Every `$D0Bx` status read silently failed until we
> switched to the latched-address compare. Whatever your bus timing, make sure
> the register decode is valid at the exact edge the CPU latches `D_IN`.

---

## Detection / status — `$D0Bx` (read-mostly)

External SuperCPU-aware software (detect-then-accelerate libraries) probes these
to decide whether a SuperCPU is present and what mode/speed it is in.

| Addr | Returns (bit7..bit0) | Meaning |
|------|----------------------|---------|
| `$D0B0` | `$40` (constant) | **Presence.** "SuperCPU v2 in C64 mode." This is the byte software tests for. |
| `$D0B2` | `{hwenable, sys_1mhz, 0,0,0,0,0,0}` | b7 = hardware-registers enabled; b6 = system forced to 1 MHz. |
| `$D0B3` | `$00` | Open-bus stub (software-compat; VICE returns `$80` here — benign, no consumer found). |
| `$D0B4` | `{0,0,0,0,0,0, optim_mode[1:0]}` | Optimization-mode flags. `optim_mode="11"` = no optimization (write-through). |
| `$D0B5` | `{0, speed_1mhz, 0,0,0,0,0,0}` | b7 = JiffyDOS present (0); b6 = software speed = 1 MHz. |
| `$D0B6` | `{emu_mode, 0,0,0,0,0,0,0}` | **b7 = emulation mode** (1 = 6502 emulation, 0 = native 65C816). |
| `$D0B8` | `{speed_1mhz, (speed_1mhz OR sys_1mhz), 0,0,0,0,0,0}` | b7 = software 1 MHz; b6 = combined 1 MHz. |
| `$D0BC` | `scpu_dos_ext_mode` (R/W flag byte) | DOS-extension mode flag (per VICE `scpu64mem.c`; `$80` typical = enabled). `$D0BE` write sets it, `$D0BF` write clears it. |

## Control — `$D07x` (write-triggered)

> ⚠️ **Real-HW vs our repurposing differs here — note `$D078`.**

| Addr | Action | Notes |
|------|--------|-------|
| `$D072` / `$D073` | system 1 MHz on / off | `scpu_sys_1mhz`. |
| `$D074`–`$D077` | optimization-mode triggers | We implement **write-through only** (== optim mode 0 / "11"). Firmware writes them ~9×, reads 0× — confirmed non-gap for us. WriteSmart proper not implemented. |
| `$D078` | **read `$00`, writes no-op** | **Real HW = SIMM configuration. We repurposed `$D078` as a cache-flush register.** If you implement a real cache + SIMM config, do **not** copy our use. (Reads `$00` so it is CMD-spec-compliant as a read.) |
| `$D079` | speed register write (gates emu turbo) | Sets `scpu_speed_reg_written`. |
| `$D07A` / `$D07B` | set **fast (20 MHz)** / set **slow (1 MHz)** | The software speed switch. Default = 1 MHz until software opts in (this is the CMD contract — see `06_LATEST_FINDINGS.md`). |
| `$D07D` / `$D07F` | disable registers / clear hwenable | Clears `scpu_regs_enabled` / `scpu_hwenable`. |
| `$D07E` | enable SuperCPU hardware registers | ANY write sets `scpu_hwenable`; read returns `{scpu_rom_vis, 0,0,0,0,0,0,0}`. |

## SuperRAM extent — `$D27C`–`$D27F` (writable, always present)

Real CMD firmware writes these into the `$D200-$D3FF` 512-byte SCPU sysram at
boot so software can size the installed RAM. We serve them from the read mux
(we don't instantiate the dprom — it disturbed the fitter). Defaults size a
16 MB SuperRAM (banks $02..$F5):

| Addr | Default | Meaning |
|------|---------|---------|
| `$D27C` | `$00` | first available page, low byte |
| `$D27D` | `$02` | bank of first available page (**SuperRAM starts at bank $02**) |
| `$D27E` | `$00` | last available page + 1, low byte |
| `$D27F` | `$F6` | bank of last available page + 1 (= $F5 + 1) |

These are **writable** — the kickstart's `STZ` sequence updates them; hardcoded
read constants (our earlier bug) ignored those writes.

## Native interrupt vectors — `$00:$FFE4`–`$FFEF` (native mode only)

Gated on `emu_mode='0'` (native mode). All native vectors default to point at
`$00:$FF00`, where the read mux returns **`$40` (RTI)**. So a native
BRK/COP/ABORT/NMI/IRQ pushes 4 bytes, fetches the vector, jumps to `$FF00`,
finds RTI, and silently returns with SP balanced.

- **Why this stub exists:** without it, `$00:$FFE6/E7` reads C64 KERNAL ROM
  (`$03 $6C`), the native BRK vector resolves to `$00:$6C03` (a RAM `$00` = BRK
  opcode), and the CPU enters an unrecoverable BRK→push→fetch→BRK loop. Doom
  triggers a native BRK during init and dies without this.
- Real SuperCPU has `$FCxx` trampolines (JML `$00:$80xx`) reached via the
  `$FFExx` vectors, with the real CMD OS handlers RAM-loaded at `$00:$80xx` by
  the boot ROM. **If you run the real boot ROM (`roms/scpu64.mif`), the
  kickstart writes real handler addresses into these vectors and you don't need
  the RTI sink** — we synthesized it only because we lacked the full boot/OS
  image flow. The vectors are a writable array (`scpu_native_vec`); the EPROM
  overwrites the defaults during cold boot.

---

## Implementation order suggestion

1. `$D0B0 = $40` + `$D0B6` (emu/native bit) → software detects a SuperCPU and
   knows the mode. Minimal viable detection.
2. `$D07A`/`$D07B` speed switch + `$D07E`/`$D07F` hwenable → software can flip
   speed and enable registers.
3. `$D27C`–`$D27F` extent → software can size SuperRAM (Doom/Wolf3D need a
   non-zero extent or they scope allocation to bank $00 and break).
4. Native vectors / boot ROM → native-mode interrupt dispatch.
5. The rest of `$D0Bx` / `$D0BC` DOS-ext → full detect-then-accelerate library
   compatibility.
