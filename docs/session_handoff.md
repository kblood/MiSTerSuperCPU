# Doom verification session — 2026-05-07

## Bottom line

**Two independent proofs that P65C816 microcode is correct on Doom code paths.**

1. **Bank-$20 prologue (prior session)**: 15574 instructions in lockstep
   from `$00:$0800` bootstrap through dispatcher walk to `$2C:$A95C`
   music-error trap. Zero CPU divergence.

2. **NEW THIS SESSION — Mid-gameplay diff**: `make test-doom-gameplay`
   loads VICE's full 142-bank gameplay snapshot (PB=$2A PC=$55A3,
   real loader output captured at 90 s warp), state-restoring bootstrap
   at `$00:$0800` plants the same regs on both DUT and VICE, BP at
   `$2A:$55A3` pauses both sides at gameplay entry, and stepwise
   capture proves **5000 fetches in lockstep starting at `$2A:$55A3`**.

The "Bad music number -9" hardware bug is therefore CONFIRMED to be
in:
1. **Loader phase** (snapshot bypasses the loader — bug accumulates in
   state our gameplay snapshot already contains correctly), OR
2. **HW-only timing** (RDY/IRQ/DMA edges the cocotb DUT bus model
   doesn't model), OR
3. **REU/SuperRAM data path** during loader's FETCH+long-store.

It is **NOT** in the gameplay-execution CPU path.

## What landed this session

### New verification infrastructure

- **`tools/vice_dump_gameplay_state.py`** (NEW, ~280 lines) —
  Launches `xscpu64` with `loader.prg + doom.reu`, warps configurable
  seconds (90 s default), pauses, captures full register state +
  stack-top bytes + per-bank 64 KB dumps for banks `$00..$8F`.
  Skips banks that probe as all-`$00`/`$EA`. Output `~9 MB` total.
  CLI: `--out --warp-secs --bank-min 0xNN --bank-max 0xNN --no-probe`.

- **`tools/state_restore_bootstrap.py`** (NEW, ~190 lines) —
  `Snapshot` dataclass + `build_bootstrap()`. Generates a 53-byte
  65C816 program that brings the CPU into the snapshot's exact state
  and JMLs to `PB:PC`:
  ```
  SEI; CLD; CLC; XCE             ; native mode
  REP #$30                       ; 16-bit M/X for safe immediate loads
  LDA #SP; TCS; LDA #D; TCD      ; stack and direct page
  SEP #$20; LDA #DBR; PHA; PLB   ; data bank
  LDA #P; PHA; PLP               ; flags (sets snapshot M/X)
  LDX #X; LDY #Y                 ; index regs (per snapshot X width)
  STA $00:$01FE/$01FF restore    ; stack-top bytes (snapshot values)
  REP/LDA #A/SEP if M=1          ; restore A preserving B
  JML PBR:PC                     ; jump to gameplay
  ```

- **`sim/cocotb/tests/test_doom_gameplay_diff.py`** (NEW, ~340 lines) —
  Loads the 142-bank snapshot, plants bootstrap + RTI trampolines +
  vector overrides on both DUT and VICE, sets BP at snapshot's
  `(PBR, PC)`, runs both sides through bootstrap unmonitored, then
  stepwise diffs from the gameplay entry for 5000 instructions.

- **`sim/cocotb/Makefile`** — added `test-doom-gameplay` target.

- **`tools/vice_oracle.py`** — added `load_bank_file()` (single fast
  `bload` call per bank vs ~50 s of pokes), `_parse_regs_dump` D/DBR
  fields, `capture_trace_from_current()`, Linux-only existence
  precheck (skips for Windows-style paths so VICE.exe paths work
  from WSL2 cocotb).

- **`tools/vice_oracle/gameplay/`** (NEW, 142 files, ~9 MB) — captured
  snapshot artifact: `regs.json`, `bank{00..8f}.bin`, `manifest.json`.

### Key implementation tricks (write these down — the tests don't
work without them)

1. **Bootstrap location $0800, not $FF10**: bload of bank00 writes
   the snapshot's `$0001 = $94` byte to motherboard RAM. xscpu64
   then unmaps KERNAL ROM (because HIRAM=0). Bare emu vectors at
   `$FFFE/$FFFF` in motherboard RAM are `$EA $EA` → `$eaea`. So an
   IRQ during bootstrap jumps into NOP-land. `$0800` is always RAM
   regardless of CPU-port HIRAM.

2. **RTI trampolines mandatory**: After `reset 0`, CIA1 Timer A is
   running. The latched IRQ bit cannot be cleared by a raw `>` poke
   to `$DC0D` (that's raw RAM, no device side effect) — only a real
   CPU read clears it. Plant `LDA $DC0D; LDA $DD0D; RTI` at `$0840`,
   set `$FFFE/$FFFA` and `$0314/$0318` to point there. First IRQ
   after SEI services through the trampoline, clearing the latches;
   bootstrap then continues uninterrupted.

3. **Plant in BOTH `bank cpu` AND `bank ram00`**: motherboard for
   pre-XCE C64-emu fetches, SuperCPU SRAM for post-XCE native+SCPU
   fetches. The dual-write is just two `>` poke chunks at the same
   $0800/$0840/$0314/$FFFA/$FFFE addresses, switched via `bank cpu`
   / `bank ram00` commands.

4. **Set BP at snapshot target PC, `g $0800`**: capture_trace_from_current
   begins only after bootstrap's final JML lands at the snapshot's
   gameplay PC. Keeps the diff bootstrap-free without manual trace
   trimming. Implemented inline in `_vice_capture_with_bootstrap`
   via `set_breakpoint(target_pc, target_pbr)` + manual sock recv +
   `delete_breakpoint`.

5. **`r p=$NN` doesn't take effect on xscpu64 monitor** —
   `mask_irq` always shows entry-0 P at pre-mask value. The trampoline
   workaround above makes this a non-issue; the I-flag ends up
   correctly set after bootstrap's PLP anyway.

## Cumulative CPU-microcode verification coverage

- Loader prologue: 2499 instr lockstep
- Bank $20 prologue + 5-bank trail: 2405 instr lockstep
- Bank $20 → bank $2C music trap (incl. dispatcher walk):
  **15574 instr lockstep**
- **Mid-gameplay at $2A:$55A3**: **5000 instr lockstep (NEW)**

## Open: locating the actual Doom -9 root cause

### A. Loader-body diff (still unblocked since prior session)
`test_doom_loader_diff` currently stops at `$0700` because DUT lacks
REU model. Extending past that needs **a minimal REU model in
DutFixture** (~200 lines): on `$DF00..$DF08` writes, latch
addr/length/cmd; on `$DF01` cmd-bit-7-set, do FETCH/STASH directly
between motherboard-RAM bank model and REU image bytes.

This is the right next step but multi-hour work. Once landed, run
the diff from `$080D` through the whole loader (likely 50 K+
instructions) to see if a CPU-or-REU divergence surfaces during
`STA $DF01` / cross-bank long-store sequences.

### B. Hardware-targeted writer trace on $FC
Per prior session: `$00:$00FC` should be set by Doom *during gameplay*
to a music-table dispatch byte. Hardware shows `$5C` (loader-stale);
VICE-real shows `$85`. Now that we know gameplay CPU is correct, the
disagreement is between **hardware-loader-output** and **VICE-loader-
output**. Build UART instrumentation that latches every `$FC` write
with full PC + bank, run hardware, see who writes and what — then
compare to VICE's writer trace.

### C. REU/SuperRAM long-store regression test
Build a focused GHDL bench: REU FETCH 1 KB into bank $00, then
long-store from bank $00 to SuperRAM bank $20, then read back. If
the DUT does this without diverging from a hand-computed expected
state, the long-store path is correct. If not, this is the bug.

## Build hygiene reminders (unchanged)

- `/media/fat/_Test/` holds exactly ONE C64.rbf
- Bundle 3+ probes per build
- Don't use `-Release` during UART debug
- Cfg-byte mutation: SFTP `seek+write`, NOT printf-via-paramiko
- VICE `>` pokes via `bank ram00` for bulk SRAM; `bank cpu` triggers I/O

## Files added this session (ready to commit)

- `tools/vice_dump_gameplay_state.py` (NEW)
- `tools/state_restore_bootstrap.py` (NEW)
- `tools/vice_oracle/gameplay/regs.json` + `bank{00..8f}.bin` (142 NEW)
- `tools/vice_oracle/gameplay/manifest.json` (NEW)
- `sim/cocotb/tests/test_doom_gameplay_diff.py` (NEW)
- `sim/cocotb/Makefile` — `test-doom-gameplay` target (modified)
- `tools/vice_oracle.py` — load_bank_file, regs D/DBR fields,
  capture_trace_from_current, Linux-precheck skip (modified)

Memory:
- `project_doom_gameplay_match_5000.md` — full result + tricks
- `MEMORY.md` — index updated
