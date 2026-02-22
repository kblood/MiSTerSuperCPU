# Phase 2 Debug & Phase 3 Plan

## Current State

Phases 0–2 are complete and deployed. The 65C816 boots to BASIC V2 in emulation mode; keyboard works. There is a cosmetic issue: '@' characters visible on screen during boot before BASIC header text scrolls them away.

**Last deployed commit:** `df16690` — Fix P65C816 IRQ B-flag bug  
**Uncommitted working-tree changes:** debug overlay infrastructure (staged but not committed — another agent may be working on these)

---

## Hardware Confirmation (Latest)

**Key clarification:** '@' rows appear in **65C816 (SuperCPU) mode only**. Plain 6502/T65 mode is clean. This is the correct direction — the T65 works, the P65C816 has an initialization issue.

- **PEEK(53436)** → returns **201** (`$C9`) ✓ SuperCPU ID register at `$D0BC` is working
- **Debug overlay** deployed and functional — shows CPU state in top video border
- **Debug overlay reading** captured from hardware:
  - `A:$E5D1` — CPU executing in KERNAL ROM
  - `D:$00` — CPU last wrote $00 (normal)
  - `W:0` — currently reading
  - `B:$00` — Bank 0, emulation mode
  - `S:$01F3` — Stack pointer healthy
  - `P:$32` — flags: M=1, X=1, I=0, Z=1 — normal emulation mode
  - `I:$85` — current opcode is STA (zero-page) — real instruction, not runaway BRK
  - `E:1` — emulation mode confirmed
- **CPU is healthy** — no stack corruption, no runaway BRK loops, IRQs enabled, BASIC runs
- **'@' rows** — persistent, scrolling; appear during 65C816 boot; T65 mode is clean

### 65C816 Origin and Integration

- **P65C816.vhd** — taken directly from the SNES MiSTer core
- **cpu_65c816.vhd** — wrapper adding: 6510 I/O port ($0000-$0001), NMI acknowledge, bank address output, emulation-mode output
- **fpga64_sid_iec.vhd** — fully integrated: same clock, bus, IRQ, NMI, and SDRAM path as T65; swapped by MUX on `supercpu_en`; inactive CPU held in reset

### Why 20 MHz missing is NOT the cause
The 65C816 currently runs at 1 MHz (same `enableCpu` timing as T65). Speed does not change the boot sequence order. The '@' issue is about what the CPU does during initialization, not how fast it does it.

---

## '@' Character Investigation — Running Log

### Ruled Out

| Candidate | Verdict | Evidence |
|-----------|---------|----------|
| XCE opcode at $FF62 | ❌ Not the cause | $FF62 = $FB = operand of `BNE -5` raster-wait loop, not XCE |
| Opcode $89 incompatibility | ❌ Not the cause | $89 at $E969 confirmed opcode in linear flow, but followed by `BCS` (tests Carry); neither 6502 nor 65C816 $89 affects Carry → identical branch outcome |
| Bus contention (CPU vs VIC-II) | ❌ Not the cause | `ramWE <= systemWe when sysCycle >= CYCLE_CPU0 else '0'` prevents writes outside CPU cycles; VIC-II reads and CPU cycles fully separated |
| WE signal polarity error | ❌ Not the cause | P65C816 WE active-low; `we <= not localWe` in wrapper correctly inverts to active-high for system bus |
| STZ writing $00 to wrong address | ❌ Not the cause | STZ correctly targets the address the CPU intends; OUT_BUS="111" means intended write of $00 |
| Microcode pipeline glitch | ❌ Not the cause | MI is registered; M is combinational from MI — standard one-cycle pipeline, timing correct |
| Debug overlay corrupting RAM | ❌ Not the cause | Overlay only touches video output path, gated by OSD option |

### '@' Investigation — Running Log

#### Ruled Out

| Candidate | Verdict | Evidence |
|-----------|---------|----------|
| XCE opcode at $FF62 | ❌ Not cause | $FF62 = $FB = operand of `BNE -5`, not XCE |
| Opcode $89 incompatibility | ❌ Not cause | At $E969, followed by BCS (tests Carry); $89 doesn't affect Carry on either CPU |
| Bus contention (CPU vs VIC-II) | ❌ Not cause | `ramWE` gated by `sysCycle >= CYCLE_CPU0`; cycles fully separated |
| WE signal polarity error | ❌ Not cause | `we <= not localWe` correctly inverts for system bus |
| STZ writes $00 to wrong addr | ❌ Not cause | STZ targets intended address |
| Microcode pipeline glitch | ❌ Not cause | MI registered, M combinational from MI; standard one-cycle pipeline |
| Debug overlay corrupting RAM | ❌ Not cause | Video-only, OSD-gated |
| 6510 mode also affected | ❌ Not cause | T65 mode is clean; issue is 65C816-specific |
| Wrong $0288 (CLRSCR target) | ❌ Not cause | PEEK(648) = 4 confirmed |
| NMOS undocumented opcodes in data path | ❌ Not cause | The 43 "dangerous" bytes found by linear disassembly are in data tables (follow JMP $E6AE at $EC75), not in executed code |
| SuperRAM absent | ❌ Not cause | KERNAL/BASIC in emulation mode uses bank $00 only; JiffyDOS has no SuperRAM awareness |
| 20 MHz missing | ❌ Not cause | 65C816 runs at 1 MHz now; speed doesn't change init sequence |

#### Active Hypothesis: VIC-II $D018 wrong value

- `$D018` controls where VIC-II reads screen characters from
- `$14` (20 dec) = screen at `$0400` — correct
- `$04` (4 dec) = screen at `$0000` — VIC reads zero page; ZP is mostly `$00` = `@`
- JiffyDOS init table at `$ECB9` has `$14` at offset `$18` — **correct value in table**
- But the init loop at `$FA30` calls `JSR $F2A9` for each byte — if this subroutine runs differently on 65C816, $D018 might get wrong value
- **Two STA $D018 in JiffyDOS**: `$EB5E` (LDA $D018 / EOR #$02 / STA) and `$EC58` (LDA $D018 / AND #$FD / STA) — both only touch bit 1 (charset selection), NOT the screen address bits

#### Critical Next Test

```basic
PRINT PEEK(53272)
```

- **Returns 20** (`$14`): VIC-II correct → actual `$00` bytes ARE in screen RAM at `$0400+`
- **Returns 4** (`$04`): VIC-II screen pointer wrong → reads from `$0000` (ZP) instead of `$0400` → this IS the bug

```basic
PRINT PEEK(1024)
```

- **Returns 32**: screen RAM `$0400` holds space — VIC-II must be misconfigured to show `@`
- **Returns 0**: screen RAM `$0400` holds `$00` — CLRSCR didn't run or didn't finish



## Corrected Root-Cause Analysis

The session checkpoint claimed `$FF62 = $FB = XCE` was the root cause of the '@' rows. **This is incorrect.** The MIF parser missed the range entry `[3F60..3F61] : D0;`, meaning:

- `$FF5E: AD 12 D0` = `LDA $D012` (reads VIC-II raster counter)  
- `$FF61: D0 FB` = `BNE -5` (raster wait loop — waits until raster = 0)  
- `$FF62 = $FB` is the **BNE branch offset**, not an XCE opcode

No mode switch occurs. The '@' issue has a different cause. The current best hypothesis is the screen clear (`CLRSCR`) routine running with `$0288 = $00` (screen base = page 0 instead of page 4), so it fills ZP rather than screen RAM at `$0400`. Screen RAM retains SDRAM content (`$00` = `@`) until BASIC scrolls it off. However: **the user reports the '@' rows scroll continuously and persist**, which is more consistent with something actively writing `$00` to screen RAM rather than a one-time CLRSCR miss.

---

## Uncommitted Changes to Commit

The working tree has debug infrastructure that was built but never committed:

| File | Change |
|------|--------|
| `rtl/fpga64_sid_iec.vhd` | +12 lines: `dbg_cpu_addr/data/we/en` output ports |
| `c64.sv` | +53 lines: OSD debug options, LED probe modes, debug_overlay instantiation |
| `files.qip` | +1 line: `debug_overlay.sv` added to project |
| `C64.qsf` | +3 lines: 65C816 QIP + cpu_65c816.vhd + debug_overlay.sv (some redundant with files.qip) |
| `rtl/debug_overlay.sv` | New file: renders CPU state as hex in top video border |

**Plan:** Commit all of these as `"Phase 2 debug tools: LED probe, bus debug overlay"`. The debug overlay is useful for live hardware debugging and low-risk (it only touches the video output path, gated by an OSD option that defaults to Off).

---

## '@' Boot Artifact — Options

The '@' rows are **persistent and scrolling**, not transient. Something is continuously writing `$00` (screen code `@`) to screen RAM or the display is otherwise corrupted. This is more serious than originally assessed.

### Option 1: Diagnose first (recommended)
Run the tests listed in the investigation table above before attempting any fix. The most important: switch to 6510 mode and check if '@' rows appear. If 6510 mode is clean, the bug is 65C816-specific and the fix should be in the CPU wrapper or bus arbitration. If 6510 mode also shows '@' rows, the issue predates the 65C816 and may be a core regression.

### Option 2: Force `$0288 = $04` from VHDL at reset
After the 65C816's reset is de-asserted, inject a write of `$04` into C64 RAM address `$0288` before the CPU fetches its first instruction. This requires a small state machine in `fpga64_sid_iec.vhd`. Risk: only addresses the CLRSCR hypothesis; won't fix an active-write problem.

### Option 3: Add screen RAM write monitor to debug overlay
Extend the debug overlay to latch any write to `$0400–$07E7` (screen RAM range) and display the write count. This would confirm whether something is actively writing to screen RAM and when.

---

## Immediate Next Steps

### Step 1 — Diagnose '@' rows on hardware
Ask the user to perform these tests **with SuperCPU (65C816) mode enabled**:

1. **6510 mode check:** Switch OSD to 6510 mode — do '@' rows appear? (Key: 65C816-specific vs general)
2. `PRINT PEEK(648)` — should return 4 (screen at $0400). If it returns 0, CLRSCR pointed at wrong page.
3. `PRINT CHR$(147)` — does this clear the '@' rows? (If yes: static uncleared SDRAM; if no: active writes)
4. `POKE 1024,65` — does 'A' appear at top-left and stay there, or get overwritten by '@'?

### Step 2 — Commit debug tools (if not already committed by other agent)
```
git add rtl/fpga64_sid_iec.vhd c64.sv files.qip C64.qsf rtl/debug_overlay.sv
git commit -m "Phase 2 debug tools: LED probe modes, bus debug overlay

Add debug infrastructure to help diagnose emulation-mode issues
on real hardware:
- fpga64_sid_iec: expose dbg_cpu_addr/data/we/en output ports
- c64.sv: OSD options for debug overlay (Off by default) and LED
  probe (emulation flag, CPU-active, CPU-write)
- debug_overlay.sv: renders CPU addr/data/we/emu in top border area
- files.qip / C64.qsf: add debug_overlay.sv to build

All debug features default to Off; no impact on normal operation.
Also adds redundant 65C816 QIP entries to C64.qsf (harmless).

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

### Step 2 — Build and deploy
```powershell
.\build_c64.ps1
wsl scp -o StrictHostKeyChecking=no /mnt/c/LLM/C64/MiSTerSuperCPU/C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf
```

### Step 3 — Verify on hardware
1. 6510 mode: boots cleanly to READY, no regression
2. 65C816 mode: boots to READY, keyboard works
3. Enable debug overlay: confirm CPU address/data appear in top border
4. Enable LED probe: LED should glow steady when CPU-active (emulation mode = 1)
5. Confirm '@' rows are only transient (disappear after BASIC header prints)

### Step 4 — Phase 3 prep
Once the above is confirmed, proceed to Phase 3 (20 MHz clock domain). Key decision needed before starting:

- **Which cycles does the 65C816 get?** Current plan: all EXT slots (8) + existing CPU slots (16) = 24 enable pulses per 32-clock period ≈ 24 MHz effective. Real SuperCPU was 20 MHz — may need to insert idle cycles.
- **I/O throttle:** when 65C816 accesses `$D000–$DFFF`, must slow to 1 MHz to keep SID/VIC/CIA timing correct.

---

## Phase 3 Scope (upcoming)

**Goal:** 65C816 runs at ~20 MHz; VIC-II and I/O timing unaffected.

**Files to modify:**
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — `sysCycleDef` state machine, `enableCpu_816` generation

**Key changes:**
1. In SuperCPU mode, `enableCpu_816` fires on EXT cycles as well as CYCLE_CPUE
2. I/O access detector: when `cpuAddr ∈ [$D000–$DFFF]` AND `supercpu_en='1'`, only enable on the normal CYCLE_CPUE (throttle to 1 MHz)
3. SDRAM access timing: fast RAM accesses (bank ≠ 0, Phase 4) need extra SDRAM latency cycles
4. VIC-II badline BA stall must still work — BA from VIC-II already gates `RDY_IN`

**Risk:** High. Bus arbitration changes can corrupt VIC-II timing and produce visual glitches or black screen. Must verify with video output after each sub-change.

**Checkpoint required:** Before committing Phase 3, run the demo `Comaland` or `Edge of Disgrace` to check VIC-II timing integrity.

---

## Open Questions

1. **Does 6510 mode show '@' rows?** Single most important test. If yes, issue is not 65C816-specific.
2. **Is `$0288` correct at boot?** If `PEEK(648)` returns 0 in 65C816 mode (but 4 in 6510 mode), CLRSCR is pointing to wrong RAM page — explains the '@' rows.
3. **Is something actively writing $00 to screen RAM?** The rows "scroll" which suggests new '@' characters are being written each frame, not just static SDRAM content.
4. Does JiffyDOS (`dol_C64.mif`) have the same `$0288` / CLRSCR behaviour as `std_C64.mif`? The user defaults to JiffyDOS — the analysis above is on `std_C64.mif` only.
5. After the debug overlay is deployed, does the LED probe confirm `supercpu_emul='1'` (emulation mode) throughout normal BASIC operation? If the LED ever drops to 0, that confirms an unexpected mode switch.
6. Resource usage after Phase 3: adding fast-clock enables may require retiming. Monitor ALM count and timing slack.
