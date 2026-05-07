# Doom verification session — 2026-05-07 (continuation 2)

## Bottom line

**Two more theses overturned this continuation:**

1. **`$00:$0074-$0076` is NOT a static dispatcher install** — it's a hot
   indirect-JML scratchpad. VICE writer trace caught 101,826 hits on
   each byte in 180 s real-time from 100+ distinct bank-$00 writer PCs
   (top: `$00:$641d` n=36,871). The HW final-state `$7D $07 $00` is
   loader-stale because hardware halts at the music-error trap BEFORE
   any of Doom's 100+ JML[$74] dispatch sites runs.

2. **`-9` is a SENTINEL "lookup failed" return code, NOT a music_num
   value.** Disassembled `$2C:$85A1→$A95C` chain. `$2C:$A95C` is
   `5c 5c a9 2c` = `JML $2C:$A95C` (infinite-loop self-trap, no
   printf). `LDA #$FFF7` appears at 21 sites in REU as a printf
   arg-walker emitting "no value supplied" sentinels into output
   buffers. The "Bad music number -9" message must be printed
   earlier than the JML-self halt by some upstream lookup function
   that returned -9.

The format string "Bad music number %d" lives at `$86:$02C4` but
`a9 c4 02` (LDA #$02C4 immediate) has **zero** matches in the 16 MB
REU. Format is loaded via pointer table or error-id indexed array,
not direct immediate.

## Cumulative state of the investigation

CPU microcode has been proven correct across all Doom code paths
sampled (cocotb+VICE lockstep at 6 distinct positions totaling
~28K instructions). With the new findings, the bug must be
**data-layer**:

- **Most likely**: REU→SuperRAM transfer corruption (similar
  evidence already known: `$00:$6C00..$6C03` = `$AB,$AB,$AB,$00`
  on HW vs `$3E,$00,$B7,$F4` on VICE).
- **Possible**: I/O register read divergence (VIC raster $D012,
  CIA timer $DC04-$DD07).
- **Possible**: DMA timing edge the cocotb harness doesn't model.

## What landed this session-continuation

### Tools

- `tools/doom_vice_fc_trace.py` — VICE watch tracer for `$0090-$0091`,
  no-warp (watches don't fire under -warp).
- `tools/doom_vice_74_writers.py` — refuted dispatcher-install thesis.
- `tools/doom_vice_85a1_caller.py` — BP attempt on `$2C:$85A1` (VICE
  never reaches the chain in 240 s; runs straight to gameplay
  `PB=$2A PC=$55B5`).
- `tools/doom_vice_90_writers.py` — VICE watch tracer for `$0090-$0091`.

Critical VICE caveat re-confirmed: monitor watches do not fire under
`-warp + -remotemonitor`. Drop `-warp` and accept 1 MHz wallclock.

### Memory updates

- `project_doom_v293_dispatcher_pointer_smoking_gun.md` — rewritten
  to record the refutation (was the smoking-gun, now the JML
  scratchpad).
- `project_doom_v293_85a1_chain_decoded.md` (NEW) — chain decode +
  sentinel analysis.
- `MEMORY.md` index entries updated.

### Commits

- `2e61e77` — refute dispatcher-install thesis (JML scratchpad data)
- `6d48a42` — decode `$85A1→$A95C` chain, identify -9 as sentinel

## Open: locating the actual divergence

CPU is provably correct. The bug is data or environmental. Three
concrete paths forward:

### Path A: Hardware vs VICE memory diff (RECOMMENDED)

VICE side (already exists): `tools/vice_dump_gameplay_state.py` dumps
banks `$00..$8F` post-loader to `tools/vice_oracle/gameplay/bank{XX}.bin`.

Hardware side: build a peek-PRG that reads each SuperRAM byte via
`LDA long $bb:$xxxx`, streams to UART. Generalize the existing
`tools/peek_bank20_prologue.py` (8-byte read) to a 256-byte-block
hash dump. ~60 KB UART for full 16-bank gameplay region; minutes
not hours.

Diff hashes between HW and VICE. Differing block(s) → smallest-
possible reproducer → trace the RTL read/write path.

### Path B: Extend cocotb diff to full loader

`test-doom-loader-body` currently MATCH at 500 + 5000 instr (with
timing-aware DMA stall). Extend to 50 K+ instructions to traverse
the full loader. If MATCH all the way through, bug is data-path
or HW-only timing. If diverges, that's a CPU-on-rare-path bug.

Wallclock cost: ~30-200 min VICE stepwise. Run via WSL2:
`make test-doom-loader-body LOADER_BODY_INSTR=50000`.

### Path C: New RTL probe — capture LAST $5C (JML) opcode fetch

Repurpose v293's `wr02_*` to latch PBR:PC at every JML opcode fetch
where the operand bytes are `$5C $A9 $2C` (= JML $2C:$A95C). The
final value reveals which trap site actually fires on HW (vs the
$85F6 site we currently suspect).

Wallclock: 30-40 min FPGA build.

## Build hygiene reminders (unchanged)

- `/media/fat/_Test/` holds exactly ONE C64.rbf
- Bundle 3+ probes per build
- Don't use `-Release` during UART debug
- Cfg-byte mutation: SFTP `seek+write`, NOT printf-via-paramiko
- VICE `>` pokes via `bank ram00` for bulk SRAM; `bank cpu` triggers I/O
- VICE remote-monitor watches: NO `-warp` or they silently never fire

## Files added/modified this session-continuation

- `tools/doom_vice_fc_trace.py` — committed earlier (3f88572)
- `tools/doom_vice_74_writers.py` — refutation tool (2e61e77)
- `tools/doom_vice_85a1_caller.py` — BP attempt (6d48a42)
- `tools/doom_vice_90_writers.py` — $90 watch trace (6d48a42)
- Memory: `project_doom_v293_dispatcher_pointer_smoking_gun.md` (rewritten)
- Memory: `project_doom_v293_85a1_chain_decoded.md` (NEW)
- Memory: `MEMORY.md` (index updated)

Commits this continuation: `2e61e77`, `6d48a42`.
