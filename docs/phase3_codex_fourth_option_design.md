# Phase 3 design — Codex Fourth Option SIMM-alias mode

## Goal

Let the CMD SuperCPU kickstart's natural SIMM-detection scan complete
without the v347 synthetic-RTL bypass. This installs the CMD library
handlers at `$00:$801A-$8054` and (we expect) restores the patched-KERNAL
banner + JiffyDOS/fast-loader hooks + IEC throttle. Side effect: fixes
the MCP+LOAD wedge documented in
`memory/project_irq_n_stuck_low_hypothesis.md` because the patched
KERNAL will use the CMD IEC throttle instead of the stock-KERNAL
raster-wait at $EAB1.

## The blocking bug we have to work around

Per `memory/project_v346_phase1_3bug_stack.md`, the kickstart's
SIMM-detection alias loop at `$F8:$81A9-$81D5` does the equivalent of:

```
;; outer loop walks [$02] up by $0800 each iteration
$81A9 loop:
        LDA [$02]            ; A := byte at long pointer $00:$02-$04
        XBA
        LDA $F60000          ; load fixed byte from $F6:$0000
        EOR #$FF
        STA $F60000          ; flip $F6:$0000
        XBA
        EOR [$02]            ; XOR with the original [$02] byte
        BNE not_aliased
        ...                  ; alias detected → break, found SIMM size
```

The kickstart EXPECTS `$F6:$0000` and `$02:$0000` to alias (because on
a real CMD SuperCPU bank `$F6` is the same physical SRAM as `$02`).

In our build, `c64.sv:1115` makes the two banks distinct
(`{1'b1, supercpu_bank, c64_addr}`), so the EOR result is never zero,
the alias never registers, and the loop walks `[$02]` until it wraps,
eventually corrupting state and BRK-runs.

We deliberately keep that bank separation because it's load-bearing for
Doom (per `memory/project_v345_music_bug_root_cause`-style history —
"do not revert the music_num=-9 fix"). So we cannot globally merge $F6
into $02.

The Codex Fourth Option is to merge them ONLY while the SIMM-detection
scan is active, gated on a new `simm_detect_active` signal.

## Trigger design

`simm_detect_active` becomes `1` between the kickstart's clear-bootmap
and the kickstart's exit-to-bank-$00:

| PC | Event | `scpu_bootmap` | `simm_detect_active` |
|----|-------|---------------|--------------------|
| `$F8:$80F7` | `STA $D07E` | `1` → `0` | `0` → `1` (set on falling edge) |
| `$F8:$810E` | `JSL $F88148` | `0` | `1` |
| `$F8:$8174` | alias-loop CMP | `0` | `1` (alias mode active) |
| `$F8:$8147` | `RTL` (natural, NOT synthesised) | `0` | `1` |
| `$00:patched_reset` | post-RTL, emu mode | `0` | `1` → `0` (clear on first bank-$00 fetch in emu mode while latch set) |

So: **set on falling edge of `scpu_bootmap` (covers the kickstart
sequence). Clear on first cycle where `supercpu_bank == 8'h00 && emu_mode`
while the latch is set.**

The set-trigger fires exactly once per kickstart run (subsequent
`scpu_bootmap` toggles do not re-fire unless `simm_detect_active` was
cleared first — which only happens after the bank-$00 transition).

## RTL changes

### 1. `c64.sv` — add `simm_detect_active` + bank remap

```verilog
// Phase 3 (2026-05-26): SIMM-detect alias mode (Codex Fourth Option).
// While the kickstart is running its SIMM-detection scan, mirror
// bank $F6/$F7 SDRAM accesses onto bank $02/$03 so the alias-loop CMPs
// at $F8:$81A9-$81D5 observe what the kickstart expects. Cleared after
// the kickstart exits to bank $00 in emu mode, so steady-state Doom
// reads/writes via SCPU long pointers still use the distinct banks.
reg simm_detect_active = 0;
reg scpu_bootmap_prev  = 1'b1;

always @(posedge clk_sys) begin
    if (reset) begin
        simm_detect_active <= 0;
        scpu_bootmap_prev  <= 1'b1;
    end else begin
        scpu_bootmap_prev <= scpu_bootmap_o;  // out from fpga64_sid_iec
        if (scpu_bootmap_prev && !scpu_bootmap_o)
            simm_detect_active <= 1;
        else if (simm_detect_active
                 && supercpu_bank == 8'h00
                 && supercpu_emul)
            simm_detect_active <= 0;
    end
end

// Bank remap during SIMM detect — narrow window, F6/F7 only.
wire [7:0] simm_remap_bank =
    simm_detect_active && supercpu_bank == 8'hF6 ? 8'h02 :
    simm_detect_active && supercpu_bank == 8'hF7 ? 8'h03 :
    supercpu_bank;
```

Then replace the addr concat at c64.sv:1115:

```verilog
// before:
//   ? {1'b1, supercpu_bank, c64_addr}
// after:
    ? {1'b1, simm_remap_bank, c64_addr}
```

Requires a new entity output `scpu_bootmap_o` on `fpga64_sid_iec` that
exposes the internal `scpu_bootmap` signal. Already at signal level
1343; add port + drive.

### 2. `fpga64_sid_iec.vhd` — expose `scpu_bootmap`, REMOVE v347 bypass

```vhdl
-- Entity port additions:
scpu_bootmap_o : out std_logic;
```

```vhdl
-- Drive in architecture body, next to the supercpu_bank assignment:
scpu_bootmap_o <= scpu_bootmap;
```

REMOVE the v347 synthetic-RTL clause at lines 2294-2296 (the
`x"6B" when (... cpuAddr = x"8147" or cpuAddr = x"8148") ...` clause).
The kickstart will now reach $F8:$8148 naturally, the alias mode lets
it terminate, and the original $6B at $8147 executes from EPROM.

KEEP the v346 widen carve-out (lines 2304-2306) — kickstart continuation
still needs EPROM reads in native mode with bootmap='0'.

KEEP `scpu_bootmap <= '1'` at reset (line 2335).

### 3. `fpga64_sid_iec.vhd` — make $D27D/$D27F writable (optional)

Currently hardcoded at lines 1868-1875. The size-display patch
(`$F8:$811B-$813A`) writes "16M" to `$01:$E49B-$E49D` based on
`$D27F - $D27D`, but the kickstart later expects to write computed
values into those registers via STZ at `$F8:$81EB-$81F0`.

If we leave `$D27D/$D27F` hardcoded:
- `$D27F=$F6, $D27D=$02` → `$F4 ≠ 0` → BEQ-not-taken → size-display
  path writes "16M" to RAM that KERNAL never reads. Harmless.
- Phase 2 flow continues to work because the bytes at `$01:$FFFC-FFFD`
  contain the patched RESET vector regardless of $D27D/$D27F.

If we make them writable:
- STZ at `$81EB-$81F0` zeros both → `$00-$00=$00` → BEQ taken → branch
  past the size-display patch directly into the boot continuation.
- More aligned with original CMD intent, but no observable behaviour
  diff for the KERNAL handoff.

**Recommendation:** leave hardcoded for Phase 3. Lower risk, fewer
RTL changes. Revisit only if observed kickstart behaviour requires it.

## Validation strategy

1. **Pre-build static review** — eyeball the c64.sv addr mux to confirm
   `simm_remap_bank` substitutes correctly only inside the SuperRAM
   branch (not the cart_addr fallback).

2. **Codex falsification pass** — per
   `memory/reference_codex_skill_validated_as_falsification_oracle_2026_05_25`,
   run codex on the diff before first hardware build. Flag class:
   "narrow window state machine, may leak across reset edges or
   re-enter on subsequent kickstart resets".

3. **Hardware boot test** — single 12-min Quartus build, deploy, check:
   - Boots to BASIC READY (no regression vs Phase 2).
   - **NEW:** Banner shows `**** C=64 SCPU64 ROM V0.07 ****` (or
     similar patched string) instead of stock `**** COMMODORE 64 BASIC V2 ****`.
     This is the visible smoke-test that the patched KERNAL is alive.
   - CMD library handler bytes present at `$00:$801A-$8054`:
     deploy `tools/test_cart/gen_dump_vectors.py` PRG and confirm
     non-zero bytes in that range.

4. **Doom smoke test** — confirm scpu_sdram_addr remap doesn't break
   Doom. Doom reads bank $20 SuperRAM, never $F6/$F7, so alias mode
   should be inert by the time Doom launches (simm_detect_active=0
   after kickstart exits). If Doom regresses, it suggests
   `simm_detect_active` didn't clear in time.

5. **MCP+LOAD test** — `LOAD"*",8,1` from a mounted disk. If the
   patched KERNAL with CMD library is alive, IEC throttle restored,
   LOAD should complete (no more SEARCHING-FOR-* wedge).

## Risks

- **Falling-edge trigger can fire on a soft-reset path** that clears
  bootmap without re-entering kickstart. Cold reset is safe because
  `scpu_bootmap_prev` reinits to `1` and the latch initialises to `0`.
  Need to audit any code path that writes `$D07E` from non-kickstart
  context (currently none — `$D07E` only appears in kickstart).
- **Latch never clears** if the kickstart hangs in SIMM detect: alias
  mode stays on forever, but since kickstart hung the system is dead
  anyway. Not worse than v347 hang behaviour.
- **VIC bank-$F6 reads**: VIC always runs as 6510 on bank $00, never
  emits bank $F6. So no VIC fetch interference.
- **REU/DMA bank-$F6**: REU only accesses bank-$00 motherboard RAM
  (REU register addresses are 24-bit but reu.v gates them to
  c64-motherboard-RAM space). No SuperRAM bank traffic from REU.

## Estimated effort

- RTL: ~40 lines (declaration + always block + bank remap + port wiring)
- 1 Quartus build (~12 min)
- 1 GHDL bench could test the falling-edge timing but not the SIMM
  scan itself (no 65C816 kickstart bench). Skip bench, go to hardware.
- Total: ~30 min source + ~12 min build + ~10 min validation.

## What this does NOT solve

- $D078 SIMM-config writes (we have it repurposed as cache flush).
  Phase 3 doesn't touch that.
- Optimisation modes (real CMD has these; ours doesn't).
- Bank $00/$01 separation (real CMD has full 128KB SRAM bank-$01;
  ours uses 64KB BRAM + bank01_mirror_to_00 hack).
