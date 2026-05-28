# SuperCPU patched KERNAL/BASIC in emulation mode (VICE-faithful ROM)

**Status:** plan / scoping. No RTL changed yet. Written 2026-05-28.
**Goal:** make the SuperCPU's *patched* KERNAL and BASIC (from the `scpu64` EPROM)
active during normal C64 operation (emulation mode), the way VICE's `xscpu64`
does — instead of only in 65816 native mode as we do today.

---

## 1. Why bother — the payoff

The SuperCPU's patched KERNAL is a **compatibility layer**, not a capability
enabler. Raw speed (20 MHz), SuperRAM, and native-65816 power are all hardware +
native-mode-software features that work today **without** the patch (Doom is the
proof — it runs from SuperRAM with the stock KERNAL and `bootmap='0'`).

What the stock KERNAL *cannot* do, and the patched KERNAL does, is **throttle the
CPU to 1 MHz around timing-sensitive serial/tape I/O** (and provide the fast
loader). That missing function is exactly what the recent MCP / CIA-throttle
RTL workstream has been *approximating* in hardware. The decisive finding:

> **The speed throttle is real.** A write to `$D07A` sets `scpu_speed_1mhz`
> (`fpga64_sid_iec.vhd:2414`), which feeds `scpu_force_1mhz`
> (`fpga64_sid_iec.vhd:3230`), which **blocks the turbo cycle slots** in
> `cpu_cyc` (`fpga64_sid_iec.vhd:3256-3262`), genuinely dropping the CPU to the
> 1 MHz `CYCLE_CPUC` slot. `$D07B` clears it.

So a patched KERNAL running in emulation mode would write `$D07A` before an IEC
byte transfer and `$D07B` after — and our hardware would honor it. This is the
**authentic mechanism** for making `LOAD` work at high speed, and could replace
the RTL `cia2_throttle_active` hack with the real thing (they compose safely —
both OR into `scpu_force_1mhz`).

---

## 2. Why it's native-mode-only today

`fpga64_buslogic.vhd:386-393` serves the bank-`$00` ROM windows
(`$E000` KERNAL / `$A000` BASIC) from the **SDRAM shadow** (`ramData`) only when
`scpu_native_mode='1'`; in emulation mode it falls through to stock `romData`
(line 392).

The native-mode gate exists for **one reason** (comment at `:374-378`): at cold
boot the SDRAM shadow is uninitialized (`$00`), so an emulation-mode read of the
`$FFFC` RESET vector would return `$0000` and the machine would never boot. So
the shadow is only trusted once the CPU is in native mode (i.e. after the
kickstart has switched modes and, in principle, populated the shadow).

Consequence: every observation of "stock banner / stock vectors" (e.g. the v347/
v348 `dump_vectors` probe) was taken **from BASIC = emulation mode**, the one
path that is stock *by design*. It was never evidence the EPROM patch was absent.

---

## 3. Verification — the kickstart block copies (CONFIRMED)

Disassembly of `tools/scpu64.bin` (md5 `006862e9a52d987970435988e3803c71`, 64 KB)
at the kickstart entry `$F8:$80C1` via `tools/disasm_kickstart.py`:

```
$80CE: LDA #$1FFF      ; count = $1FFF+1 = $2000 = 8192 bytes
$80D1: LDX #$0100      ; src addr
$80D4: LDY #$A000      ; dst addr
$80D7: MVN #$01,#$F8   ; dst bank $01, src bank $F8  → BASIC

$80DA: LDA #$1FFF
$80DD: LDX #$2100      ; src addr
$80E0: LDY #$E000      ; dst addr
$80E3: MVN #$01,#$F8   ; → KERNAL

$80E6: LDA #$1FFF
$80E9: LDX #$4100      ; src addr
$80EC: LDY #$6000      ; dst addr
$80EF: MVN #$01,#$F8   ; → CMD/OS code (RAM, not a ROM window)
```

| # | Source (EPROM offset) | Dest | 8 KB region |
|---|---|---|---|
| 1 | `$0100..$20FF` | `$01:$A000` | **BASIC** |
| 2 | `$2100..$40FF` | `$01:$E000` | **KERNAL** |
| 3 | `$4100..$60FF` | `$01:$6000` | CMD/OS code (not a ROM window) |

`MVN` is a **pure block move** — no per-byte fixup. Therefore the final shadow
content for KERNAL/BASIC is **byte-identical to slices of `scpu64.bin`** we
already have resident in the `scpu_rom` dprom.

**One caveat:** immediately after the copies (`$812E-$8139`) the kickstart
patches **3 bytes** of the KERNAL shadow at `$01:$E49B-$E49D` with a computed
memory-size banner string (depends on the `$D27D/$D27F` SIMM-size detect). A pure
byte copy from the EPROM would show the static placeholder bytes there instead.
**Cosmetic only** (the size text in the boot message); see §6 for options.

### 3.1 Confirmed test-prep facts (2026-05-28)

- **VICE fidelity is guaranteed at the ROM level.** The installed `xscpu64`
  (VICE 3.10) ships `SCPU64/scpu64` with md5 `006862e9a52d987970435988e3803c71`
  — **byte-identical** to our `tools/scpu64.bin` (= `rtl/roms/scpu64.mif`). So the
  KERNAL/BASIC the C64 will run in emulation mode after this change is bit-for-bit
  the same image VICE's `xscpu64` runs.
- **This swaps JiffyDOS → SCPU KERNAL in emulation mode.** Our current
  `dol_C64.mif` is actually a **JiffyDOS** KERNAL (reset does `JSR $FE72`); the
  SCPU patched KERNAL does the standard `JSR $FD02`. 3138 of 8192 KERNAL bytes
  differ. We're not losing fast-load — the SCPU KERNAL has its own fast loader —
  and we gain the `$D07A` speed throttle. This is the correct VICE-faithful state.
- **Differential PEEK target: `$E0F9` (decimal 57593).** Current JiffyDOS ROM
  returns `$AA`=**170**; the patched SCPU KERNAL returns `$C9`=**201** (and VICE,
  same ROM, also returns `$C9`). So after deploy, `PRINT PEEK(57593)` → **201**
  confirms the patched KERNAL is live; **170** means the change didn't take effect.

---

## 4. Two strategies

### Strategy A — run the real kickstart, cold-boot only
Restore `bootmap='1'`, but gate it on the **hardware `RESET` input** (true
power-on) and explicitly *not* on the PRG-load `reset_wait` window (`c64.sv:429-447`;
`reset_wait` is set on the ioctl edge, cleared at `$FFCF`). Kickstart runs once at
power-on, MVN populates the shadow, set a sticky `scpu_shadow_valid`; then serve
emu-mode ROM reads from the shadow. SDRAM survives soft reset, so Doom's PRG-load
no longer re-runs the kickstart — fixes the original "Bug B" at the source.

- **Pro:** exercises the authentic firmware; most faithful.
- **Con:** high risk. v347/v348 reached BASIC READY but the MVN was never verified
  to populate the shadow correctly on our memory map; the kickstart has been a
  serial regression source; it leans on the partly-dead SCPU register-read path.

### Strategy B — serve patched KERNAL/BASIC straight from the EPROM (RECOMMENDED)
Skip the kickstart. Because the patched ROMs are plain slices of `scpu64.bin`
(§3), expose those slices as a normal ROM and mux them into `romData` when
`supercpu_en='1'`, in **both** modes. No kickstart, no shadow-valid timing, no
SDRAM, `bootmap='0'` stays → **Doom autoload untouched.**

- **Pro:** low risk, decoupled, byte-faithful, immediately testable, ~1 day.
- **Con:** doesn't run the real boot firmware (cosmetic — VICE's end state is the
  same patched ROM); still depends on the runtime register-read path being good
  enough for the patched KERNAL's needs (§6).

**Recommendation: Strategy B.** Cheapest way to prove the patched KERNAL is viable
on our hardware and to unlock the self-throttling-LOAD payoff. Fall back to A only
if byte-faithful slices prove insufficient.

---

## 5. Strategy B — concrete diff sketch (for review, NOT yet applied)

### 5.1 Generate the patched-ROM image (tooling, no RTL)
New `tools/make_scpu_rompatch.py`: read `tools/scpu64.bin`, take
`basic = [$0100:$2100]` and `kernal = [$2100:$4100]`, concatenate
`basic ++ kernal` (16 KB) to match the existing `dol_C64.mif` layout
(BASIC at `$0000-$1FFF`, KERNAL at `$2000-$3FFF`), emit
`C64_MiSTer/rtl/roms/scpu_rompatch.mif`.

### 5.2 Option B-clean — separate 16 KB dprom (simplest)
In `fpga64_buslogic.vhd`:

```vhdl
signal romData_patched : std_logic_vector(7 downto 0);   -- new declaration

scpu_rompatch: entity work.dprom                          -- new instance, mirrors kernel_c64
generic map ("rtl/roms/scpu_rompatch.mif", 14)
port map (
    wrclock => clk, rdclock => clk,
    rdaddress => std_logic_vector(cpuAddr(14) & cpuAddr(12 downto 0)),
    q => romData_patched
);

-- was:  romData <= romData_c64;
romData <= romData_patched when supercpu_en = '1' else romData_c64;
```

That single mux line is the whole behavioral change. Cost: +1 16 KB dprom
(~13 M10K blocks). **Budget risk** — CLAUDE.md notes ~72% ALM and the existing
`scpu_rom` already pushed RAM usage to ~71%. Confirm fit before committing.

### 5.3 Option B-lean — reuse the existing `scpu_rom` dprom (no new M10K)
The emu-mode patched-ROM read and the native/bootmap `scpuRomData` read are
**mutually exclusive in time** (emu mode never emits a bank-`$F8`/bootmap EPROM
read in the same cycle it reads `$E000`/`$A000`). So mux the existing
`scpu_rom` dprom's `rdaddress` to the patched offset when serving emu-mode ROM:

```vhdl
-- KERNAL: EPROM addr = cpuAddr - $E000 + $2100 = cpuAddr - $BF00
-- BASIC : EPROM addr = cpuAddr - $A000 + $0100 = cpuAddr - $9F00
scpu_rom_rdaddr <= std_logic_vector(cpuAddr - x"BF00") when (emu KERNAL read)
              else std_logic_vector(cpuAddr - x"9F00") when (emu BASIC read)
              else std_logic_vector(cpuAddr);
```

Then route `scpuRomData` into `romData` for the emu-mode KERNAL/BASIC clauses.
Zero new ROM blocks. Slightly more timing-sensitive (an adder before a registered
ROM read), but the existing `kernel_c64` path has the same 1-cycle ROM latency and
works, and `cpuAddr` is stable across the access. **Preferred if M10K is tight.**

### 5.4 Cold-boot reset-vector decision (the key open question)
With `bootmap='0'` (current default) and `romData` = patched, a cold-boot
emulation-mode read of `$FFFC` returns the **patched KERNAL's** RESET vector and
the machine boots the patched KERNAL directly (most VICE-like). This is fine
**iff** the patched KERNAL's reset routine self-initializes the SuperCPU hardware
(enables registers / sets turbo) rather than assuming the kickstart already did.

- The throttle path needs **no** enable: `$D07A/$D07B` writes are ungated
  (`fpga64_sid_iec.vhd:2414-2417`), so LOAD throttling works regardless.
- If the patched KERNAL hangs at cold boot, the minimal nudge is to set
  `scpu_regs_enabled <= '1'` (and keep `bootmap='0'`, `optim="11"`) at reset in
  `fpga64_sid_iec.vhd` — replicating the few register writes the kickstart did at
  `$80F7-$810B`, without running the kickstart.

---

## 6. Risks / follow-ons

1. **Patched-KERNAL self-init at cold boot** — the main unknown; see §5.4. Test
   first. If it hangs, apply the reset-time `scpu_regs_enabled` nudge.
2. **Runtime SCPU register reads** — the patched KERNAL will read registers the
   stock KERNAL never touches (`$D0B0` mode-detect, `$D0B5` JiffyDOS/speed switch,
   optimization flags). Memory documents several `cs_vic`-gated SCPU register
   *reads* returning `$FF`. Running the patched KERNAL in emu mode is the first
   time those reads matter at runtime; expect to fix them with the 16-bit-`cpuAddr`
   compare pattern already used for the writable registers.
3. **Cosmetic banner bytes** — the 3-byte memory-size string (`$01:$E49B-$E49D`)
   won't be patched. Options: (a) ignore; (b) bake the right bytes into
   `scpu_rompatch.mif` since `$D27D/$D27F` are effectively fixed in our impl;
   (c) replicate the patch in RTL.
4. **M10K / ALM budget** — Option B-clean adds ~13 M10K. Use B-lean if it doesn't
   fit. Check `build_c64.ps1` fitter report.
5. **Interaction with the RTL CIA throttle** — `cia2_throttle_active` and
   `scpu_speed_1mhz` both OR into `scpu_force_1mhz`, so they compose safely. The
   RTL hack may become redundant once the patched KERNAL drives `$D07A` itself —
   evaluate removing it after this lands.

---

## 7. Test plan

1. Generate `scpu_rompatch.mif`; apply Option B (lean preferred).
2. `.\build_c64.ps1` (~30 min). Watch the fitter RAM/ALM report.
3. Deploy; confirm cold boot reaches READY (patched KERNAL booting standalone).
4. **Differential vs VICE** — `xscpu64` is the oracle (CLAUDE.md methodology):
   compare boot banner and a distinguishing KERNAL byte (e.g. PEEK a byte known to
   differ between stock and SCPU KERNAL) in emulation mode.
5. The real test: `LOAD"*",8,1` from a mounted disk in emulation mode at turbo —
   should now succeed via the patched KERNAL's `$D07A` self-throttle, **without**
   the RTL CIA-throttle hack.
6. Regression: re-run `python tools/deploy_and_probe_doom.py` — Doom autoload must
   still reach the bitmap (it should be untouched; `bootmap='0'` unchanged).

---

## 8. References

- Throttle: `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2414` (set), `:3230` (combine),
  `:3256-3262` (gate `cpu_cyc`).
- ROM routing: `C64_MiSTer/rtl/fpga64_buslogic.vhd:169-214` (dproms + `romData`),
  `:386-393` (mode-gated mux).
- Kickstart: `tools/disasm_kickstart.py`, `tools/scpu64.bin`.
- Reset sources: `C64_MiSTer/c64.sv:415-453`.
- Bank-$01 shadow mirror: `C64_MiSTer/c64.sv:1100-1127`.
- VICE memory model: `docs/supercpu_architecture_reference.md` §2 / §6.
