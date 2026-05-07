# Doom verification session — 2026-05-07 (continuation)

## Bottom line

**v292 "missing dispatcher overwrite" thesis OVERTURNED.** Probe B with
unfiltered `$00:$00FC` writer ring on the full loader run shows:

- **CY = 23,389 writes** to `$00:$00FC` (v292 only saw 88 because it
  filtered to value `$5C` only). Doom heavily uses `$00FC` as scratch
  zero-page.
- **V ring `E8 E8 F6 0E`** — values vary, NOT all `$5C`.
- **`$0074-$0076` = `$00:$077D`** at trap (loader's `STA $FC` PC, NOT
  `$2C:$A95C`). **JML[$0074] is NOT the path to the trap.**
- **Trap reached via direct error chain** `$2C:$85A1 → $A95C` per v288
  disasm, triggered by `printf("Error: Bad music number -9\n")`.
- Halt screen capture `tools/doom_probe_fc_writer/halt_screen_fullloader.png`
  confirms the actual bug.

Bug is still **`music_num = -9` producer is unknown**. Hardcoded
`LDA #$FFF7; STA $90` sites at `$2C:$5D78`/`$2C:$712C` confirmed dead
code (v291). The `$2B:$245A` latch is a printf arg-walker, not producer.

## What landed this session (continuation)

### v293 RTL — unfiltered `$00:$00FC` writer ring

`C64_MiSTer/rtl/fpga64_sid_iec.vhd:2511-2552` repurposes obsolete
`$00:$6C00..$6C07` BRK-loop tracker (resolved by v286 RTI sink) to
capture **all writes** of `$00:$00FC`. UART fields `WP CY V` carry
writer-PC, total count, ring-of-4 values. Build is current, RBF deployed.

### Probe B harness — `tools/doom_probe_fc_writer.py`

Two-step MGL pattern (per `tools/doom_full_run.py`):
1. `doom.reu` MGL → REU SDRAM (~50 s)
2. `loader.prg` MGL → BASIC autoruns SYS 2061 → covert-bitops loader
   does 16 MB REU FETCH + long-store; auto-jumps to Doom; Doom prints
   "Error: Bad music number -9" and halts at `$2C:$A95C`.

Captures 30 s UART after 240 s wait, parses last well-formed line,
captures halt screenshot. Output `tools/doom_probe_fc_writer/`:
`uart_post_halt_fullloader.txt`, `halt_screen_fullloader.png`.

### Memory updated

- `project_doom_v293_fc_writers_full.md` (NEW) — corrects v292 thesis.
- `MEMORY.md` index updated under VICE oracle entry.

## Cumulative CPU-microcode verification coverage (unchanged)

- Loader prologue: 2499 instr lockstep
- Bank $20 prologue + 5-bank trail: 2405 instr lockstep
- Bank $20 → bank $2C music trap: 15574 instr lockstep
- Mid-gameplay at $2A:$55A3: 5000 instr lockstep
- Loader body 500/5000 + timing-aware DMA stall: 6 lockstep proofs total

P65C816 microcode is correct on every Doom code path sampled. The bug
is hardware-only and not reproducible by functional simulation.

## Open: locating the `music_num = -9` producer

The investigation has narrowed to **one of**:
1. SuperRAM contents diverge hardware-vs-VICE post-loader (REU FETCH or
   long-store path returns/writes wrong byte).
2. A specific code path the lockstep proofs didn't sample — Doom executes
   ~hundreds of millions of instructions before the error; only ~25 K
   are covered.
3. Hardware-only timing edge (DMA-vs-CPU arbitration, RDY semantics,
   IRQ window) that the cocotb DUT bus model doesn't reproduce.

### Next probe (recommended): hardware vs VICE post-loader memory diff

VICE side (already exists): `tools/vice_dump_gameplay_state.py` runs
loader+gameplay under VICE, dumps banks `$00..$8F` to
`tools/vice_oracle/gameplay/bank{XX}.bin`.

Hardware side (NEW work needed): build a peek-PRG that reads each byte
of bank `$20..$8F` SuperRAM via `LDA long $bb:$xxxx` and streams to
UART. Pattern in `tools/peek_bank20_prologue.py` reads 8 bytes;
generalize to ~1 MB total dump time at 115200 baud ≈ 90 s per bank.
Or: hash every 256-byte block, send 16-byte hash + bank/offset, ~60 KB
UART for the full 16-bank gameplay region — minutes instead of hours.

Diff hashes/bytes between hardware dump and VICE dump. The differing
byte(s) is the smallest-possible reproducer; from there, find the
RTL path that wrote/read it.

### Alternative: instrument writes to the music_num zero-page byte

Per memory v290/v291, music_num is at `$0090` (or `$90`/`$91` word).
v290 PBR-unfiltered tracker captured 245 writes from `$2B:$245C` (printf
arg-walker, not producer). v291 PBR=$2C filter found 0 writes — dead-code
literals. The PRODUCER must be in some bank/PC pair we haven't probed.

Build a v294 RTL probe that latches **all writers of `$0090..$0091`**
with PBR:PC + value + ring of last 8 values. Goal: find the specific
PBR:PC pair that writes `$F7` to `$0090` (LO byte of music_num=-9).
That writer-PC is the bug entry point; disasm the surrounding code,
compare hardware vs VICE execution at that point.

### Alternative: long-loader cocotb diff

Extend `test-doom-loader-body` past 5000 instr to traverse the full
loader (~50 K+ instructions). With the timing-aware DMA stall already
landed, this exercises real REU FETCH + long-store under fidelity that
caught no divergence at 5000. If divergence appears at 10 K, 20 K, etc.,
that's a CPU-on-rare-path bug. If MATCH all the way through the full
loader, the bug is purely runtime data-path (option 1 or 3 above).

## Build hygiene reminders (unchanged)

- `/media/fat/_Test/` holds exactly ONE C64.rbf
- Bundle 3+ probes per build
- Don't use `-Release` during UART debug
- Cfg-byte mutation: SFTP `seek+write`, NOT printf-via-paramiko
- VICE `>` pokes via `bank ram00` for bulk SRAM; `bank cpu` triggers I/O

## Files added/modified this session-continuation

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — v293 wr02_* repurpose to $00FC
- `tools/doom_probe_fc_writer.py` — full-loader Probe B
- `tools/doom_probe_fc_writer/uart_post_halt_fullloader.txt` (artifact)
- `tools/doom_probe_fc_writer/halt_screen_fullloader.png` (artifact)
- Memory: `project_doom_v293_fc_writers_full.md` (NEW)
- Memory: `MEMORY.md` (updated VICE oracle entry)

Commit: `80f2427` — "verif/doom: v293 unfiltered $00:$00FC writer ring overturns v292 thesis"
