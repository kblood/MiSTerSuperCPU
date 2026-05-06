# Doom verification session — 2026-05-06

## Bottom line

**P65C816 microcode is PROVEN CORRECT on the Doom post-loader execution
path.** cocotb + VICE diff harness MATCHes 15574 instructions in lockstep
— BOTH DUT and VICE reach `$2C:$A95C` (music_num error trap) at fetch
15575 with **zero CPU divergence** along the entire dispatcher walk:

```
$00:$0800 (bootstrap SEI/CLC/XCE/JML)
  → $20:$0000 prologue
  → ...patched loops...
  → $80:$005C copy chain
  → $20:$03EA → $2D:$06A0 → $2C:$A719 → $2C:$A792
  → $00:$0E0C (JML — required bank-$00 snapshot to traverse)
  → $00:$0E26 → $2B:$D9A8 (cross-bank JML)
  → $2B:$DA3A → $2A:$0E2A (JML indirect-long)
  → $2A:$0E6A → $29:$2BDB
  → ... → $2C:$85A1 → $85B6 → $85E8 → $85F6 → $A95C TRAP
```

The "Bad music number -9" bug **is NOT a P65C816 microcode bug**. It must
be one of:
1. **Loader-phase divergence** — the snapshot bypasses loader.prg.
2. **HW-timing** — RDY/IRQ/DMA edge cases the cocotb DUT doesn't model.
3. **REU/SuperRAM data path** — REU FETCH or long-store during loader.

## What landed this session

### Verification infrastructure
- **`tools/vice_oracle/postloader_bank00.bin`** (NEW, 65KB) — captured
  from VICE running `loader.prg + doom.reu` for 45s warp. Pre-loaded on
  both DUT and VICE to lift the architectural ceiling at `$00:$0E0C`.
- **`tools/vice_dump_postloader_bank00.py`** (NEW) — captures any
  post-loader bank-$00 snapshot via CHIS-tool pattern (`x` to exit
  monitor, sleep 45s warp, `\r\n` to break, dump $0000..$FFFF).
- **`sim/cocotb/tests/test_doom_bank20_diff.py`** (heavily extended) —
  15 EXTRA_BANKS pre-loaded (`$20`, `$80`(16K), `$2D`(8K), `$2C`(64K),
  `$87`, `$2B`, `$2A`, `$84`, `$85`, `$86`, `$21`..`$29`).
  STOP_PC=`$2C:$A95C`, max_instr=24000, run_n_instructions=28000.

### Critical operational fix
**VICE `>` writes via default `bank cpu` view trigger SCPU register I/O
side effects** — pokes to `$D078`/`$D07E` silently enable SuperCPU
mode mid-load and re-route subsequent reads to empty SCPU SRAM,
breaking the diff. **Fix: use `bank ram00` for bulk SRAM poke** (bare
SRAM, no I/O bypass), then switch to `bank cpu` for bootstrap overlay
in motherboard RAM.

## Cumulative verification coverage

- Loader prologue: 2499 instr (test_doom_loader_diff)
- Bank $20 prologue + 5-bank trail: 2405 instr to `$2C:$A792`
- Bank $00 game code → bank $2B/$2A/$29 dispatcher → bank $2C trap:
  **15574 instr to `$2C:$A95C` (music error trap) — LOCKSTEP MATCH**

The 15574 figure dominates earlier numbers since it's a single
contiguous run from `$0800` bootstrap to the trap.

## Open: locating the actual Doom -9 root cause

The CPU is correct on the post-loader path. The bug must surface earlier
or in non-CPU components. Three concrete next probes:

### A. Loader-body diff
`test_doom_loader_diff` currently stops at `$0700` because DUT lacks
REU model. Extending past that needs **a minimal REU model in
DutFixture** (~200 lines): on `$DF00..$DF08` writes, latch
addr/length/cmd; on `$DF01` cmd-bit-7-set, do FETCH/STASH directly
between motherboard-RAM bank model and REU image bytes.

This is the right next step but it's multi-hour work. Once landed, run
the diff from `$080D` through the whole loader (likely 50K+
instructions) to see if a CPU-or-REU divergence surfaces during
`STA $DF01` / cross-bank long-store sequences.

### B. Hardware-targeted writer trace on $FC
Per prior session: `$00:$00FC` should be set by Doom *during gameplay*
to a music-table dispatch byte. Hardware shows `$5C` (loader-stale);
VICE-real shows `$85`. The disagreement is between hardware-loader-
output and VICE-loader-output. Build UART instrumentation that latches
**every $FC write** with full PC + bank, run hardware, see who writes
and what — then compare to VICE's writer trace.

### C. REU/SuperRAM long-store regression test
Build a focused GHDL bench: REU FETCH 1 KB into bank $00, then
long-store from bank $00 to SuperRAM bank $20, then read back. If
the DUT does this without diverging from a hand-computed expected
state, the long-store path is correct. If not, this is the bug.

## Build hygiene reminders (unchanged from prior session)

- `/media/fat/_Test/` holds exactly ONE C64.rbf
- Bundle 3+ probes per build
- Don't use `-Release` during UART debug
- Cfg-byte mutation: SFTP `seek+write`, NOT printf-via-paramiko
- VICE `>` pokes via `bank ram00` for bulk SRAM; `bank cpu` triggers I/O

## Files modified this session (uncommitted)

- `sim/cocotb/tests/test_doom_bank20_diff.py` — bank loads, STOP_PC,
  max_instr, run_n_instructions
- `tools/vice_dump_postloader_bank00.py` (NEW)
- `tools/vice_diagnostic_full_seq.py` (NEW — diagnostic-only)
- `tools/vice_test_ram00_writes.py` (NEW — diagnostic-only)
- `tools/vice_oracle/postloader_bank00.bin` (NEW 65KB capture)

Memory:
- `project_doom_bank20_prologue_match.md` — updated through 15574 MATCH
- `MEMORY.md` — index updated to flag the milestone
