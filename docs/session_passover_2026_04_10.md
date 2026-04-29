# Session Passover 2026-04-10: CLC/XCE crash isolation — the bug is NOT JML, it's native mode switch via BASIC RUN after mbc

## Headline

The "LDA/JML long crash" bug class is actually a **CLC/XCE native mode switch crash** triggered by a specific execution path: BASIC's `RUN` command executing mbc-injected code. The bug does NOT occur when the same code is POKEd.

## Key Test Results

| # | Scenario | Result |
|---|----------|--------|
| 1 | Fresh deploy → POKE CLC/XCE at $C000 → SYS 49152 | **GREEN border** ✓ |
| 2 | Fresh deploy → POKE CLC/XCE at $0800 → SYS 2048 | **READY returned** ✓ |
| 3 | Deploy → mbc load_prg (RTS-only) → POKE CLC/XCE at $0800 → SYS 2048 | **READY returned** ✓ |
| 4 | Deploy → mbc load_prg test_xce.prg → RUN | **Warm restart** ✗ |
| 5 | Deploy → mbc load_prg test_xce.prg → POKE-back same bytes → RUN | **Warm restart** ✗ |
| 6 | Deploy → mbc load_prg test_noswitch.prg (no CLC/XCE) → RUN | **RED border** ✓ |
| 7 | Deploy → mbc load_prg test_jml_minimal.prg (has CLC/XCE) → RUN | **Warm restart** ✗ |

## What This Proves

1. **CLC/XCE itself works** — Tests 1-3 prove the CPU core handles the emulation→native→emulation switch correctly.
2. **The address ($0800 vs $C000) doesn't matter** — Test 2 proves $0800 works.
3. **mbc load_rom doesn't leave persistent state** — Test 3 proves mbc injection doesn't break native mode.
4. **The bug is in the BASIC RUN → mbc-injected code path** — Only tests 4, 5, 7 crash.
5. **POKE-back doesn't fix it** — Test 5 proves that writing the same bytes via POKE after mbc injection doesn't help. This rules out pure BRAM valid bit issues.
6. **Emulation-mode code from mbc works fine** — Test 6 proves mbc-injected code executes correctly as long as it stays in emulation mode.

## Working Theory: BRAM serves stale data after mbc injection

The mbc ioctl path writes PRG data to C64 RAM (c64_ram64k) and SDRAM, then fires `bram_invalidate` (clears all BRAM page valid bits). During KERNAL boot, any page the CPU reads is re-filled into BRAM via `bram_we` (SDRAM read fill path). But only the specific BYTES the KERNAL reads are updated in BRAM — the rest of the page still has stale M10K data.

When the CPU later executes at $080D:
- If `bram_hit_d1` fires: CPU reads BRAM (potentially stale at unreached bytes)
- If `bram_hit_d1` is blocked (speed gates): CPU reads `cpuDi_raw` from C64 bus (always correct)

The POKE-back test (#5) was expected to fix this by writing every byte back. However, if `bram_hit_d1` was active during the PEEK part of `POKE I,PEEK(I)`, the PEEK returned the stale BRAM value, which was then written back — no net change.

**Counter-evidence**: I verified PEEK(2061)=120 (correct SEI opcode) after mbc injection. If BRAM was serving stale data during PEEK, the value would be wrong. So either bram_hit wasn't active during that PEEK, or BRAM actually had the correct data.

## BRAM Architecture (for reference)

- `bram_hit_addr`: $0000-$7FFF, bank $00, reads only
- `bram_hit_native`: $8000-$FFFF (excl. I/O), bank $00, native mode only
- `bram_hit_d1` gated by speed flags: `scpu_speed_1mhz`, `scpu_sys_1mhz`, `iec_slow_mode`
- `bram_we` triggers on: CPU writes, SDRAM read fills (`enableCpu='1' and cpuHasBus='1'`), cache hit fills
- `bram_pgvalid`: 256 per-page valid flags, cleared by reset/bram_invalidate/dma_active/cache_flush_sw

## Diagnostic Buffer Issues

The $DF20-$DF30 register readback path has a persistent issue: PEEK(57120) always returns 16 regardless of the diagnostic buffer content. Even changing the magic constant from "0000" to "1010" had no effect. This makes the hardware diagnostic capture buffer unusable for this investigation. The issue may be in the `io_data_r_sv` registered capture timing or the `dbg_cpu_addr` mux alignment.

## Files Modified This Session

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — diagnostic buffer: trigger at $080D, PBR capture, "1010" magic
- `C64_MiSTer/c64.sv` — updated register comments for PBR layout
- `tools/test_cart/test_jml_minimal.prg` — JML test (border RED→GREEN)
- `tools/test_cart/test_noswitch.prg` — no-native-switch test (border RED)
- `tools/test_cart/test_xce.prg` — CLC/XCE/SEC/XCE test (border RED→GREEN)
- `tools/test_cart/test_rts.prg` — RTS-only PRG for mbc testing

## Next Steps

### Highest Priority: Fix the $DF20 diagnostic readback
The diagnostic buffer is the right tool for this investigation but the readback path is broken. Fix candidates:
1. Use `c64_addr[5:0]` instead of `dbg_cpu_addr[5:0]` for the reu_reg_mux case
2. Sample the mux output during IOF phase only (not every clock)
3. Add a dedicated test: force dbg_bug_buf to a constant (e.g., $A5) and verify PEEK returns it

### Second Priority: Determine if BRAM stale data is the root cause
Test: after mbc injection, before RUN, execute a BASIC FOR loop that POKEs **known test values** (not PEEK values) to $080D-$081D. For example: `FOR I=2061TO2077:POKEI,169:NEXT` fills everything with $A9 (LDA#). Then RUN. If the program behaves differently (executes LDA# at every address instead of the intended code), BRAM IS serving stale data. If it still crashes normally, BRAM is NOT the issue.

### Third Priority: Reproduce with GHDL testbench
The narrow-scope GHDL bench at `sim/p65c816_tb/` can test what happens to the CPU core during XCE with controlled enable patterns. Add a scenario where CE is deasserted during/after XCE and the data bus holds a stale byte.

## Doom Dependency

The Doom launcher ends with `JML $20:0000`, which requires CLC/XCE to switch to native mode first. The crash class is the same: native mode switch via BASIC/launcher code. Fixing this crash class unblocks Doom.
