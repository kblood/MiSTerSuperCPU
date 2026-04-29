# Session Passover - 2026-04-08b (continuation)

## Headline Finding: LDA long bank $00 bug is NOT a regression

The LDA long crash bug discovered in session 2026-04-08 is a **pre-existing latent bug**, not a recent regression. Bisecting back to 9833fce ("Fix SuperRAM LDA long regression") reproduces the crash. Bank $00 LDA long has likely never been tested in isolation — the historical "working" PRG (`scpu_lda_long_loop.prg`) uses **bank $02 SuperRAM**, not bank $00.

## Bisection Results

Tested builds (all crash sr_align.s):
| Build | Date | Result |
|-------|------|--------|
| HEAD (cc26529) | 2026-04-03 | sr_align crashes, sr_abs works |
| HEAD + cache_fill revert of 36c135c | manual revert | sr_align crashes, sr_abs works |
| 9833fce ("LDA long fix") | 2026-04-02 | sr_align crashes, sr_abs works, scpu_lda_long_loop crashes |

**Conclusion**: The bug predates 9833fce. None of the cache fill / SuperRAM commits introduced it.

## Why the historical PRG seemed to work

Inspection of `tools/test_cart/out/scpu_lda_long_loop.prg`:
```
sei; clc; xce
lda #$a5; sta $02:0100   ; STA long bank $02 (SuperRAM)
lda #$5a; sta $02:0200
lda $02:0100             ; LDA long bank $02 (SuperRAM)
sta $0400                ; show readback
...
```

This PRG **only does LDA/STA long with bank $02 (SuperRAM)**. The 9833fce fix restored `superram_data_r` in the `cpuDi` mux, fixing the SuperRAM read pipeline. Bank $00 LDA long was never exercised.

## Failure Mode

The crash is NOT a hardware reset. It's a soft fault path:
1. CPU executes LDA long ($AF $xx $xx $xx) from BRAM-served bank $00 PC
2. Something corrupts execution — most likely the CPU fetches the next opcode from a wrong address, getting $00 (BRK)
3. BRK in emulation mode → KERNAL BRK handler → warm restart → screen cleared, READY shown
4. The C64.sv reset_n is never asserted; it's all CPU-side soft crash

Confirmed by sr_emu.s: bug reproduces in **emulation mode** (no XCE at all). Rules out:
- XCE M/X flag bug interaction
- Native-mode-specific microcode paths
- All workaround testing (sep #$30 doesn't help)

## Suspect: P65C816 microcode for opcode $AF

The bug must be in the CPU itself, not the system pipeline:
- Reproduces with any 4-byte instruction with bank operand ($AF, $5C, $8F)
- Reproduces regardless of target bank (bank $00 RAM, I/O $D020, SuperRAM $01:xx)
- Builds with completely different fpga64/cache pipeline still reproduce

**Microcode location**: `C64_MiSTer/rtl/65C816/MCode.vhd:1597-1602` (LDA LONG / opcode $AF)

```
1598: ('[PBR:PC]->AAL', 'PC++')        - fetch low addr byte
1599: ('[PBR:PC]->AAH', 'PC++')        - fetch high addr byte
1600: ('[PBR:PC]->AB', 'PC++')         - fetch bank byte → AB register
1601: ('ALU([AB:AA+0])->AL', '[AB:AA+0]->DR', 'Flags')  - data fetch low
1602: ('ALU([AB:AA+1]:DR)->A', 'Flags')                  - data fetch high (M=0 only)
```

**AB register load**: `AddrGen.vhd:207-218`
```vhdl
case ABSCtrl is
    when "00" => null;
    when "01" => AB <= D_IN;     -- ← LDA long uses this
    ...
```

**Address bus mux**: `P65C816.vhd:584-585`
```vhdl
when "0101"=>
    ADDR_BUS <= (AB<<16) + AA + ADDR_INC;   -- ← LDA long data fetch
```

**Hypothesis**: The AB register is loaded at end of cycle N (when EN=1, line 1600 micro-op). The next micro-op (line 1601) at cycle N+1 puts (AB:AA) on the bus. The new AB should propagate combinationally through the address bus mux. If there's a 1-cycle latency mismatch or EN gating issue, the bus could present the OLD AB value while the data fetch executes, fetching from the wrong bank.

Alternative hypothesis: the `MC.ADDR_BUS` field in MCode.vhd row 1601 might not be `"0101"` (or wherever in the column structure) — the LDA long microcode might be incorrectly transcribed from the SNES core.

## Current RTL state

Working tree contains:
- Reverted cache_fill change (commit 36c135c's SuperRAM cache fill addition)
- Other dirty changes preserved (debug_uart_fmt, sdram, etc — unrelated)

Key files modified vs HEAD:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1361-1365` — cache_fill_data uses cpuDi_raw, cache_fill_we includes `not superram_in_pipeline`
- All other RTL files match HEAD

## Build Status

- Last successful build: HEAD-with-cf-revert (4,188,116 bytes, 2026-04-08 ~12:22)
- Deployed and verified: sr_abs works, sr_align crashes (reproducing the bug)

## Backed-up state

In `/tmp/`:
- `fpga64_HEAD.vhd`, `cpu_65c816_HEAD.vhd` — original HEAD versions
- `fpga64_HEAD_revert_cf.vhd`, etc — HEAD with cache_fill revert (current state)
- `c64_ram64k_HEAD.vhd` — HEAD c64_ram64k
- `C64_current_broken.rbf` — original "broken" RBF backup

## Tasks Updated

| ID | Status | Title |
|----|--------|-------|
| 1 | done | Diagnose why most native-mode test PRGs fail to display output |
| 2 | done | Build SuperRAM regression test PRG |
| 3 | done | Investigate SuperRAM read at $20:$20FC for Doom crash |
| 4 | pending | Update test_cart README and project documentation |
| 5 | pending | Investigate P65C816 XCE M/X flag bug |
| 6 | pending | Investigate SuperRAM STA long execution corruption |
| 7 | pending | Investigate STA long bank $00 corrupting $D021 |
| 8 | in_progress | **Fix LDA long bug — moved to P65C816 microcode investigation** |

## Next Session Priority

1. **Add UART debug capture for LDA long**: Extend `debug_uart_fmt.sv` to dump A_OUT and AB during native-mode 4-byte instruction execution. Use the existing UART hardware but trigger on `IR=$AF`.

2. **Inspect MCode column meaning**: Find where MCode columns are decoded in `P65C816.vhd` to understand what each field means. Verify that the `ADDR_BUS` field in row 1601 is actually `"0101"` (the AB-based addressing).

3. **Test in simulation**: Build a tiny ModelSim/GHDL testbench that runs `LDA $00:0040` and inspects ADDR_BUS each cycle. This is the fastest way to find the bug.

4. **Compare with SNES upstream**: Find the original P65C816 source we forked from. If the bug is in the original, search for fixes in other 65C816 cores (e.g., SNES core forks).

5. **Workaround consideration**: For Doom, if we can't fix the CPU quickly, can we patch Doom's bank $20 code at load time to use 3-byte instructions only? Probably impractical given the size of Doom's native code.

## Reproduction artifacts

`tools/test_cart/`:
- `sr_align.s/.prg` — minimum reduction (sei,clc,xce,sep,LDA $00D020) → crash
- `sr_abs.s/.prg` — control (sei,...,LDA $40 abs) → works "1234"
- `sr_emu.s/.prg` — LDA long in emulation mode → crash
- `sr_b00.s/.prg` — LDA $00:0040 → crash
- `red_border.s/.prg` — control PRG → works
- `out/scpu_lda_long_loop.prg` — historical "working" PRG (uses bank $02!) → also crashes now

Screenshots:
- `screenshot_head_sr_align.png` — HEAD crash
- `screenshot_rev_cf_sr_align.png` — HEAD+revert crash
- `screenshot_rev_cf_sr_abs.png` — HEAD+revert sr_abs success ("1234")
- `screenshot_9833fce_sr_align.png` — 9833fce crash
- `screenshot_9833fce_sr_abs.png` — 9833fce sr_abs success
- `screenshot_9833fce_loop.png` — 9833fce historical PRG crash
- `screenshot_9833fce_sr_emu.png` — 9833fce emulation mode crash
- `screenshot_9833fce_sr_nop.png` — 9833fce sr_nop crash

Logs:
- `build_head_test2.log` — HEAD build
- `build_revert_cf.log` — HEAD+revert build
- `build_9833fce.log` — 9833fce build
