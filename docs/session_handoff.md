# Session handoff — 2026-05-12 (XCE bug characterized, v305 wedge unchanged)

## Bottom line

Spent the session characterizing the XCE pipeline-drop bug on hardware,
then proving it is NOT what blocks Doom. v305 RBF deployed and tested
— same wedge as v298/v301 at `$00:$0706`. The XCE EN-guard fix attempt
was reverted in source (commit `5e92372`).

Found a strong new lead: at the wedge, opcode at `$00:$0705` is `$58`
(per B/I fields) but the R7 ring shows the latest `$0705` data read
returned `$00`. Same address, two values — possible BRAM/cache mismatch
or two read contexts.

## Working state

- **HEAD**: `bb4b754` on `vanilla-cpu-swap`
- **Deployed RBF**: `d43c41afe9ad32eecf59d7bb109af105` (3,848,348 bytes,
  v305 build with EN-guard included — but since the EN-guard had zero
  effect, this is functionally equivalent to HEAD for runtime behavior)
- **Source**: clean (EN-guard reverted)
- **Doom test PRG suite**: `tools/build_xce_*.py` (5 builders committed)

## Key findings

### XCE pipeline disrupts ~2 instructions on FPGA

See `project_xce_drops_next_instruction.md`. Hardware-only:
1. First instruction after `XCE` is fully dropped.
2. Second instruction's result is scrambled (`LDA #$AA` → A=`$69`).
3. Third+ instructions recover.
4. `JMP` after `XCE` survives (so Doom launcher works).
5. `SEI` between `XCE` and `LDA` absorbs the drop.

The v305 attempt to gate the XCE special-case at `P65C816.vhd:357`
with `EN='1'` did NOT fix the bug. Reverted.

GHDL `p65c816_native_switch_tb` PASSES — bug is CE-gating-specific.

### Doom v305 wedge byte-identical to v298

See `project_doom_v305_wedge_unchanged.md`. Wedge state:
```
PC:000706 P:05 V:07 07 07 07 SP:varies WP:000707
N:2BDB90 I:000705 B:58 G:7D 07 00 W5:05 J:DC6B
```
- `$2B:$DB90` disassembled = 32-byte context-save routine (`CLC; LDA $F4;
  ADC #$FFE0; STA $F4; ... STA [F4],Y`).
- SP eats ~614 ops/sample = IRQ storm or stack-corrupting loop.
- Only 4 unique UART signatures in 30s = fully deterministic.

### Strong new lead: $0705 read divergence

- B/I fields: opcode at `$00:$0705` = `$58` (CLI)
- R7 ring: last `$0705` data read returned `$00`

Same address, two values. Investigate first thing next session.

## Next-session priorities

1. **Investigate $0705 read divergence (task #32)**. Check `c64_ram64k.vhd`
   BRAM RAW-hazard bypass (v158b commit `b267455`). Could the bypass
   miss for some access paths?
2. **Identify what reads $0705 in DATA context (vs opcode fetch)**.
   Hypothesis: if DP=`$0700` (recompiler set), then `ORA [$05]` at
   `$0706` reads pointer at DP+$05 = `$0705`. Check what DP gets in
   the recompiler bank-$00 entry.
3. **RTL probe** (build cycle): add a 4-deep ring capturing
   `(cpuAddr_pre, dbg_pc_816_i, cpuDi)` at every `$0705` read so we
   can see PC vs BUS address divergence.
4. **Defer XCE**: bug is documented (task #29) but doesn't block Doom.
   A real fix requires a GHDL bench with CE-pulse injection — not yet
   built.

## Test artifacts committed this session

- `tools/build_xce_clean_test.py`
- `tools/build_xce_clean2_test.py`
- `tools/build_xce_chars_test.py`
- `tools/build_xce_a_probe.py`
- `tools/doom_v305_uart_30s.txt`

## Commits

```
bb4b754 verif/doom: v305 wedge byte-identical to v298 — XCE fix had zero impact
5e92372 debug/xce: revert failed v305 EN-guard; bundle XCE characterization PRGs
6aa24d9 verif/doom: VICE oracle refutes $41:$DB93 wait-loop thesis (prior session)
```

## Memory files updated/created

- `project_xce_drops_next_instruction.md` — updated with three-test
  evidence chain, failed v305 fix attempt, and root-cause hypotheses.
- `project_doom_v305_wedge_unchanged.md` — NEW. v305 wedge state +
  `$2B:$DB90` disasm + $0705 divergence lead.
- `MEMORY.md` — top entries updated to reflect v305 and XCE.
