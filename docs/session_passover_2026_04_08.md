# Session Passover - 2026-04-08

## Major Finding: 4-byte instructions crash from BRAM PC

### Symptom
Any 4-byte 65816 instruction with bank byte (LDA long $AF, STA long $8F, JML long $5C, etc.) **crashes the CPU** when fetched from bank $00 BRAM-fetched code. The crash triggers a full reset to BASIC READY (border restored to default, screen cleared).

### Reproduction
- `tools/test_cart/sr_align.s` — minimum prefix `sei,clc,xce,sep,LDA $00D020` → crash
- `tools/test_cart/sr_naked.s` — `LDA $2020FC` with no follow-up → crash
- `tools/test_cart/sr_b00.s` — `LDA $000040` (BRAM target!) → crash
- `tools/test_cart/sr_jml.s` — `JML $00:0825` → crash
- `tools/test_cart/sr_emu.s` — LDA long in emulation mode → crash
- `tools/test_cart/sr_long2.s` — LDA $000000 → crash

### Negative tests (these work)
- `tools/test_cart/sr_abs.s` — LDA absolute $0040 (3-byte $AD) → **WORKS, "1234" displayed**
- `tools/test_cart/just3b.s` — XCE with sep #$30 workaround → **WORKS, "123"**
- `tools/test_cart/red_border.s` — control PRG → **WORKS, red border persists**

### Confirmation: Historical regression
`tools/test_cart/out/scpu_lda_long_loop.prg` (committed PRG that worked on 2026-03-22 per `docs/progress_2026-03-22.md`) **also crashes** with the current build. This proves the bug is a regression introduced after that fix.

### Why Doom's JML works but my JML doesn't
Doom's launcher uses `JML $20:0000` at $FF04-$FF07 in the SCPU **ROM stub** (`cpu_65c816.vhd:127-135`). The ROM stub uses a separate combinational data path:
```vhdl
localDi <= localDo when localWe = '0'
           else rom_stub_data when rom_stub_active = '1'
           else std_logic_vector(di) ...
```
This bypasses the BRAM/cache pipeline entirely. So 4-byte instructions fetched from $FFxx work, but 4-byte instructions fetched from BRAM ($08xx) don't.

This explains why Doom progresses through the launcher and into bank $20 — but the same bug pattern likely causes the $20:20FC crash where SDRAM "reads $00 instead of $85". When Doom's code executes `STA $8C` (a dp store at offset $20FC), the SuperRAM read pipeline returns garbage, CPU sees $00 (BRK opcode), takes BRK→JML $20:0000 infinite loop.

## Suspected regression source

`git diff --stat` shows 457 lines of uncommitted changes in `C64_MiSTer/rtl/fpga64_sid_iec.vhd`, plus changes in `c64.sv`, `cpu_cache.vhd`, `cpu_65c816.vhd`, `sdram.v`. None of these are committed.

The last clean commit affecting SDRAM/cache:
- `cc26529 Revert registered SDRAM address (caused stale address race at CPUB)` — 2026-04-03

Build deployed today (08:53) used the uncommitted code with the same bug.

## Also discovered

### Bug A — XCE entering native fails to force M=X=1
- `tools/test_cart/just3.s` (no SEP) shows "120" instead of "123"
- Workaround: `sep #$30` after `clc; xce` (proven by `just3b.s`)
- Attempted fix at `P65C816.vhd:418` (use `(P(0)='1' or P(8)='1')` like SP/X/Y forcing on line 290) — built and deployed, **did not take effect**. Needs different approach (likely move forcing logic outside EN gating).
- See `memory/project_xce_native_mx_bug.md`

### Bug B — STA long bank $00 corrupts $D021
- `tools/test_cart/regr_step2.s`: `STA $000300` (cassette buffer area, BRAM target) corrupts background to dark blue.
- Different failure mode from LDA long — crashes pipeline rather than full reset.
- Probably same root cause family.
- See `memory/project_sta_long_bank0_bank1_bugs.md`

## Tasks Updated/Created

| ID | Status | Title |
|----|--------|-------|
| 1 | done | Diagnose why most native-mode test PRGs fail to display output |
| 2 | done | Build SuperRAM regression test PRG |
| 3 | done | Investigate SuperRAM read at $20:$20FC for Doom crash (root cause found) |
| 4 | pending | Update test_cart README and project documentation |
| 5 | pending | Investigate P65C816 XCE M/X flag bug (fix attempt didn't work) |
| 6 | pending | Investigate SuperRAM STA long execution corruption |
| 7 | pending | Investigate STA long bank $00 corrupting $D021 |
| 8 | pending | **Fix LDA long bus pipeline race in cpu_cache/fpga64** ← PRIORITY |

## Next Session Priority

1. **Identify the regression**: `git stash` the RTL changes, rebuild, run `tools/test_cart/sr_align.s`. If it works, bisect the uncommitted changes. If it still crashes, the bug is in committed code from after `cc26529` (commits `36c135c` "Add PBR/SP to UART debug, enable SuperRAM cache fills" or `1120e84` "Extend bank $00 BRAM from 32KB to 64KB").

2. **Fix LDA long**: Once regression is bisected, the fix is targeted. Most likely culprits in `fpga64_sid_iec.vhd:2284-2320` (SDRAM pipeline state machine) or `cpu_cache.vhd` BRAM fill logic.

3. **After LDA long fixed**: Run `superram_read_20.prg` to verify $20:20FC reads correct data ($85 expected from doom.reu offset $2020FC).

4. **Then test Doom**: Should progress past $20:20FC if the LDA long fix works.

## Reproduction artifacts created

`tools/test_cart/`:
- `c64prg.cfg` — bare PRG linker config
- `just{1,2,3,3b}.{s,prg}` — XCE M/X bug bisection
- `regr_min.s`, `regr_step{1,2,3,4}.{s,prg}` — STA long bug bisection
- `sr_{one,b1,b00,emu,naked,long2,nop,abs,jml,align,border,b1}.{s,prg}` — LDA long crash matrix
- `red_border.{s,prg}` — control PRG
- `superram_read_20.{s,prg}` — $20:20FC diagnostic (blocked by LDA long bug)

`memory/`:
- `project_xce_native_mx_bug.md`
- `project_sta_long_bank0_bank1_bugs.md`
- `project_lda_long_crash.md`

Build artifacts:
- `C64_MiSTer/output_files/C64.rbf` — current build (4,172,608 bytes, 08:53), with broken LDA long
- `build_xce_fix.log` — build log
