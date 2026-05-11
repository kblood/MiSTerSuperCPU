# Doom debug — 2026-05-11 v298 EPROM port lands, doesn't help Doom

## Bottom line: EPROM at bank $F8 is wrong intervention. Real bug is JML dispatch into empty bank $0F.

v298 RBF md5 `ddb5ce0197cfaf0bd0c1005524caedc6`, ALM 64%, RAM 73%
(was 61% on v297, +64 M10K blocks for the dprom).

## What v298 changed (from v296/v297 baseline)

`C64_MiSTer/rtl/fpga64_buslogic.vhd` adds `scpu_rom` dprom +
selector:

```vhdl
scpu_rom: entity work.dprom
generic map ("rtl/roms/scpu64.mif", 16)
port map ( wrclock => clk, rdclock => clk,
           rdaddress => std_logic_vector(cpuAddr), q => scpuRomData );

scpu_rom_en <= '1' when supercpu_en = '1' and scpu_native_mode = '1'
                         and supercpu_bank = x"F8" and cpuWe = '0' else '0';
```

`dataToCpu` mux: bank $F8 → `scpuRomData` (above the $6B-RTL stub
for banks ≥ $F6).

`scpu64.mif` is byte-identical to VICE SCPU64 V0.07 EPROM by
Wiebo de Wit. Vectors at $FFEE/EF = $AC $FC. Real IRQ handler
entry at $FCAC → JML $0:8025 (NOT in our environment, would
crash).

## Hardware result (continuous 30-s UART windows 30..240s)

| Window | Last PC | J ring | N field | Phase |
|--------|---------|--------|---------|-------|
| 30-60s | $00:$0788 | `078D 078D 078D 078D` | $000000 | Loader REU→SuperRAM |
| 60-90s | $00:$078E | `078D 078D 078D 078D` | $000000 | Loader REU→SuperRAM |
| 90-120s | $00:$0788 | `078D 078D 078D 078D` | $000000 | Loader REU→SuperRAM |
| 120-150s | $20:$039F | `0109 → 03AC` | $20:$039D | Bank-$20 dispatch |
| 150-180s | $00:$FF03 | `21A7 → 2423` | $0F:$1FB9-$24D3 | $0F BRK-march |
| 180-240s | $00:$8B3F | `8AAF 8AAF 8AAF 8AAF` | $0F:$93AD | Same |

F counter monotonic across all windows. No UART silence. No wedge.

## v298 vs v296 — same failure mode, different addresses

```
doom.reu bank $0F:$1FB9 (v298 N field): 00 00 00 00 ...  (32/32 zero)
doom.reu bank $0F:$2247 (v298 N field): 00 00 00 00 ...  (32/32 zero)
doom.reu bank $0F:$24D3 (v298 N field): 00 00 00 00 ...  (32/32 zero)
doom.reu bank $0F:$93AD (v298 N field): 00 00 00 00 ...  (32/32 zero)
doom.reu bank $0F:$A41B (v296 N field): 00 00 00 00 ...  (32/32 zero)
```

**Both builds have main BRK-marching through empty bank $0F.**
v298 didn't change the fundamental Doom failure. EPROM at bank
$F8 is never touched by Doom's runtime path.

(Doom DOES execute SOME real code — `WP:$2C:$8545` shows writes
to legitimate game data — but the sampled "main PC" via
`pc_main_r` is the BRK-march, masking what's actually happening.)

## Final screen — identical to v296 (blank blue bitmap)

Same lighter-blue border, darker-blue inner rect. No sprites,
no text, no game frame.

## Strategic next step

EPROM port is salvageable for FUTURE work (bank-$00 SRAM shadow
from kickstart, kernal-shadow at $E000-$FFFF, $0314/$0315 RAM
vector chain, real native-mode trampolines at $FCxx). But the
**immediate Doom bug** is in the recompiler dispatch math — JML
target computed into empty bank $0F when real Doom code lives in
$20-$2C and $40-$BF.

### Probe options for next session

1. **Wider writer-PC ring on JML target operands** — surface in
   UART the PC of the instruction that EMITTED the bad JML.
   Likely a `JML [zp]` or `JML (abs,X)` with corrupt pointer.

2. **Verify SuperRAM bank $0F contents vs REU bank $0F** — if
   loader's REU→SuperRAM mapping IS 1:1, then bank $0F SuperRAM
   really is all-zero (REU bank $0F IS all-zero in doom.reu).
   If NOT 1:1, then we need to figure out which REU bank
   actually got mapped to SuperRAM $0F. Loader.prg disassembly
   needed.

3. **Capture the LAST real-code PC before bank $0F** — modify
   `pc_main_r` gating to track only PB <> $0F transitions, then
   surface the previous PB+PC. That's the bug site.

### Files for next session

- `tools/doom_v298_wedge_capture.py` — continuous 30-s windows
- `tools/doom_full/v298_wedge_*.txt` — captured frames
- `tools/doom_full/shot_v298_wedge_final.png` — blank screen
- `C64_MiSTer/rtl/fpga64_buslogic.vhd:174-200,251-265` — EPROM
  dprom + bank-$F8 selector
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1573-1650` — ack stub
  (v296 LDA $00DF00, kept in v298)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2604-2625` — PB-based
  pc_main_r gate (kept from v295)

### Build state

- Branch `vanilla-cpu-swap`
- Tip commit (uncommitted v298 buslogic changes + new probe
  script + memory file)
- `tools/doom_full/v298_wedge_*.txt` saved
- ALM 64% (was 64% v297), RAM 61% → 73% (+64 M10K dprom)
