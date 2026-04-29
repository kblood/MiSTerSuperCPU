# Session Passover 2026-04-08c — LDA Long Crash Investigation Continued

## What this session accomplished

Continued investigation of the LDA long crash bug. Spent the session running additional regression PRGs and narrowing the bug class. Static analysis has been exhausted; next step requires runtime UART instrumentation.

## Confirmed facts (this session)

### Bug is real and reproducible
All builds tested today reproduce the crash. KERNAL warm-restart screen wipe is the consistent signature.

### Bug class characterization
1. **Affects all 4-byte $xF instructions**: $AF (LDA long), $5C (JML long), $8F (STA long), $CF (CMP long).
2. **Does NOT affect** 3-byte instructions ($AD LDA abs, $B9 LDA abs,Y), 4-byte indirect long ($A7 LDA [DP]), 4 NOPs in same position.
3. **Bank operand $00 always crashes** regardless of instruction position ($0812, $0817, $081C, $0820, $0821 all tested).
4. **Bank operand $01/$02 sometimes works**: sr_b01 (bank $01 at $081C), sr_b02 (bank $02 at $081C), sr_pos2 (bank $01 at $0820) all WORK. But sr_b1 (bank $01 at $0821) and sr_min1 (bank $01 at $0817) CRASH. The differentiator is currently unknown.
5. **Bug applies in BOTH emulation and native modes** (sr_emul confirms).
6. **Bug applies regardless of target type** — RAM, I/O, SuperRAM all crash when bank=$00.
7. **Bug persists with software 1MHz mode** — `sr_slow.s` writes $D07A before LDA long. CRASHES anyway. **This rules out the BRAM hit fast path / turbo mode as the cause.** The bug is in something more fundamental — possibly the CPU state machine, microcode load timing, or SDRAM pipeline handling for $AF.

### Microcode encoding verified correct
$AF microcode (MCode.vhd:1597-1602) is correctly encoded:
```
state 1: [PBR:PC]->AAL, PC++   (addrCtrl="01000000", addrBus="0000", va="01")
state 2: [PBR:PC]->AAH, PC++   (addrCtrl="00001000", addrBus="0000", va="01")
state 3: [PBR:PC]->AB,  PC++   (addrCtrl="00000001", addrBus="0000", va="01")
state 4: [AB:AA+0]->AL         (addrCtrl="00000000", addrBus="0101", va="10")
state 5: [AB:AA+1]->AH         (addrCtrl="00000000", addrBus="0101", va="10", LAST_CYCLE)
```

ABSCtrl="01" → AB <= D_IN (AddrGen.vhd:209-210). All correct.

## Test PRGs created this session

| File | Purpose | Result |
|------|---------|--------|
| sr_brd0.s | NOPs positive control (no LDA long) | WORKS — splash + "12" + BLUE border |
| sr_brd2.s | LDA $00:D020 with markers | CRASH |
| sr_lram.s | LDA $00:0810 (RAM target, not I/O) | CRASH |
| sr_emul.s | LDA $00:D020 in emulation mode (no XCE) | CRASH |
| sr_b01.s | LDA $01:0000 at $081C | WORKS |
| sr_b02.s | LDA $02:0000 at $081C | WORKS |
| sr_pos1.s | LDA $00:D020 at $0820 (NOPs to shift) | CRASH |
| sr_pos2.s | LDA $01:D020 at $0820 | WORKS |
| sr_min.s | Minimum LDA $00:D020 + JMP self | CRASH |
| sr_min1.s | Minimum LDA $01:D020 + JMP self | CRASH |
| sr_slow.s | LDA $00:D020 with $D07A 1MHz mode | CRASH |
| sr_cmp.s | CMP $00:D020 ($CF, 4-byte) | CRASH |
| sr_idl.s | LDA [$10] ($A7, 4-byte indirect) | WORKS |
| sr_lday.s | LDA $D020,Y ($B9, 3-byte indexed) | WORKS |
| sr_4nop.s | 4 NOPs at LDA long position | WORKS |

## Theories ruled out

1. ~~"It's the BRAM hit fast path"~~ — sr_slow disables turbo, still crashes
2. ~~"It's specific to native mode"~~ — sr_emul crashes in emu mode
3. ~~"It's I/O register interaction"~~ — sr_lram reads RAM, still crashes
4. ~~"It's the microcode encoding"~~ — Verified static encoding is correct
5. ~~"It's specific to bank-of-target"~~ — Multiple targets crash; bank-of-OPERAND matters more

## Theories still open

1. **PC off-by-one after $AF execution** — would explain why bank=$00 (BRK) crashes but bank=$01 (ORA) doesn't trigger warm-restart. But contradicted by sr_b1/sr_min1 which crash with bank=$01.
2. **Pipeline timing race in state 3→4 transition** — when AB or PBR loads from D_IN during VPA cycle, the next state's address bus combinationally jumps. Some race in the system-side cycle counting may corrupt PC or fetch wrong data.
3. **bram_pgvalid coarseness** — page-valid set on first byte fill, but other bytes return BRAM init $00. But this should affect all programs, not just $AF.
4. **NextIR loading from wrong cycle** — possible interaction with the way MCode is keyed on NextIR/NextState in P65C816.vhd:186-187.

## Critical next step

**Add UART instrumentation** to capture per-instruction state when IR == $AF. The current debug_uart_fmt.sv outputs once per vblank. Need to modify it to:
1. Latch CPU state on the rising edge of "IR == $AF" detection
2. Capture A_OUT, PC, AB (need to expose from P65C816), STATE, and D_IN at the moment of state 3→4 transition
3. Output the captured snapshot via UART instead of (or in addition to) the per-frame state

Without runtime data, this bug cannot be debugged via static analysis.

## Files modified this session
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — only the cache_fill revert from previous session (1361-1369), no new edits
- Created many `tools/test_cart/sr_*.s` test PRGs

## Outstanding tasks
- #4 Update test_cart README and project documentation
- #5 Investigate P65C816 XCE M/X flag bug
- #6 Investigate SuperRAM STA long execution corruption
- #7 Investigate STA long bank $00 corrupting $D021
- #8 (in_progress) Fix LDA long bug — needs runtime UART data
- #9 Add UART trace for LDA long: dump A_OUT/AB during $AF execution **← START HERE NEXT SESSION**

## Build state
- Branch: master
- HEAD: cc26529 + cache_fill revert (uncommitted, in fpga64_sid_iec.vhd:1361-1369)
- Latest RBF: C64.rbf (4,154,024 bytes, 13:24 build)
- All sr_*.prg test files in `tools/test_cart/`
