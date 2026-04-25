# Session Handoff — 2026-04-25 (late evening) — UART peek register implemented; bitstream reload blocked

Last updated: 2026-04-25 late evening. This file is OVERWRITTEN each session.

## One-line status

**UART peek register at $DF1D/$DF1E/$DF1F implemented in c64.sv +
P65C816 bench passes $C0xx-garbage-fill test (CPU is bench-correct
even with $FF in $C000-$FEFF). Hardware validation BLOCKED: deploy +
`/dev/MiSTer_cmd load_core` does not actually reload the FPGA bitstream
on this MiSTer. Need user power-cycle or kill-respawn permission.**

VICE PC-diff harness from prior session is still operational.

## Read me before next session

`memory/project_load_core_does_not_reload_bitstream.md` — confirmed
2026-04-25 via cold-boot marker test (peek_seq=$A5 / peek_data=$5A
distinct values that did NOT appear in UART). The deployed RBF
md5-matches local but the FPGA still runs whatever bitstream MiSTer
was launched with (asterix.mgl auto-load chain). Hardware iteration is
gated on user action.

TR ring buffer chain is severed (4 sanity builds proved
`bug_frozen` flop never reaches c64.sv L: field) — abandoned in favor of
the VICE diff. The per-vblank UART fields (W: live PC, A: bus, S: SP,
P: flags, I: opcode) DO work and were used to characterize the C003 hang.

## What we actually learned this session

### Asterix locked at PC=$C003 (1972 samples, 39.4s, build b428cluy4)

`uart_asterix_c003.log` (151,915 bytes at repo root):

- **W:C003 in 100% of samples** — PC frozen, K:00 PBR, B:00 DBR, E:1 emu
- **I:FF (SBC al,X) 90.6%, I:80 (BRA) 9.4%** — tight 4-byte + 2-byte loop
- **A:bus walks $9400-$BFFF** uniformly (139 distinct addresses)
- **P:B4 / P:B5** — N=1, M=1, X=1, **I=1 always**, D=0
- **VIC IRQ asserted 100%** but I=1 means CPU never takes IRQ
- **SP wraps cleanly within $0100-$01FF** (SR-emu-wrap fix 6edec4c works)
- **C: cache-hit counter = 0000** (no cache hits during loop)

Bare-CPU GHDL bench (`p65c816_asterix_full_tb.vhd`) reaches $CB00 in 312ms
sim on the same asterix.prg. **CPU core is verified correct.** Bug is
system-side: BRAM write-through, cache coherence, or SDRAM read latency
on the $9400-$BFFF range during the decompressor inner loop.

## VICE PC-diff harness — LANDED THIS SESSION

`tools/vice_diff/`:

| Component | State |
|---|---|
| `trace_format.md` | DONE |
| `vice_diff.py` | DONE — `--pc-only` and `--align` flags added |
| `uart_to_trace.py` | DONE (untested but scaffolded) |
| Bare-CPU GHDL trace (`ours_trace.txt`, 500K lines) | DONE |
| `vice_capture_chis.py` | **DONE** — captures via xscpu64 text remote-monitor |

**Run sequence**:
```
python tools/vice_diff/vice_capture_chis.py --max-instr 200000 \
    --start-timeout 30 --trace-timeout 270
python tools/vice_diff/vice_diff.py \
    tools/vice_diff/vice_trace.txt \
    sim/p65c816_tb/work_asterix_full/ours_trace.txt \
    --pc-only --align
```

Critical implementation notes (lessons from 5+ failed attempts):
- DON'T pass `-autostart` — keystroke injection is unreliable under
  monitor pause. Load PRG via `l "<path>" 0` after monitor connects.
- DELETE the start_pc breakpoint after it fires — otherwise it re-fires
  on every loop iteration of the phase-2 inner copy loop.
- Use `trace exec $0000-$ffff` (range tracepoint), parse pairs of
  `#N (Trace exec PCPC)` event + `.C:PCPC bytes` disasm lines.
- VICE under -warp + remote-monitor produces ~1k trace lines/sec via
  TCP text output; for 6M instruction full prelude allocate ~6000s.
- The bench `sim/p65c816_tb/p65c816_asterix_full_tb.vhd` produces
  `ours_trace.txt` automatically; rerun via `run_asterix_full_only.ps1`.

Result: 200K instructions of asterix.prg execution match identically
between bare CPU and VICE → CPU core verified correct.

### TR ring buffer — DO NOT pursue further

See `memory/project_tr_ring_chain_broken.md` for full diagnosis. The 4
builds that failed were:

1. `b428cluy4` — original v115 PC=$C003 trigger, L:00
2. `b7fz4csms` — `bug_frozen <= '1'` unconditional, L:00
3. `bats9p1im` — same + `gen_trace_release` commented out (md5 unchanged
   — block didn't elaborate anyway), L:00
4. (final) — added dedicated `dbg_bug_frozen_out : out std_logic` port,
   wired to L: field, L:00

If the chain ever needs to be revived, route through known-working fields
(W:, N:) first as a unit test, OR build a GHDL bench that instantiates
`fpga64_sid_iec` + `debug_uart_fmt` and verifies the L: byte changes when
the trigger fires.

## Working tree state

`git diff --stat HEAD` shows ~1,347 insertions across 11 files — large
WIP from prior sessions PLUS the v115 PC=$C003 trigger and assorted REU
diagnostic plumbing in c64.sv. The sanity hacks from earlier this session
were already reverted before the summary checkpoint.

The currently-deployed RBF (`/media/fat/_Test/C64.rbf`) is build #4 with
the dedicated 1-bit port AND `bug_frozen <= '1'` unconditional. Source
files no longer match — a clean rebuild is needed before resuming any
hardware capture.

## Crucial new finding: $C003 is OFF the legitimate path

`grep ":c003:" sim/p65c816_tb/work_asterix_full/ours_trace.txt` returns
**zero hits across 500K traced instructions**, yet bench reaches $CB00
(cb00_seen=1). Therefore hardware is in code that should NEVER execute
on a healthy run. PC arrived at $C003 via a wrong JMP/JSR/RTS upstream.

$C003 in bench RAM = $EA (NOP). On hardware, $C003 contains $FF
(SBC al,X) — likely leftover garbage in $BF94-$FFFF range that
asterix.prg's 47KB payload never overwrites. So even a single bad jump
into this range stalls forever on hardware while bench would NOP-slide
to the nearest RTS or KERNAL stub.

## Memzap test attempted (inconclusive)

Cold-reset → load asterix MGL → BASIC `FOR I=49152 TO 65279: POKE I,234:
NEXT` → SYS 2080. Result: W:C003 unchanged (uart_asterix_zap2.uart,
2466 samples). Reasons inconclusive:
- mtype has ~30s BASIC keystroke latency; POKE loop may not have run
  to completion before SYS was issued.
- Even if it ran, cacheable_wr=0 and BRAM write-through semantics mean
  POKE writes go to BRAM only. After bram_invalidate (asterix load)
  invalidate cleared valid bits, reads now come from SDRAM which may
  still hold original $FF garbage.
- Without a UART peek register, can't verify what's actually at $C003
  on hardware.

## Next actions (in priority order)

1. **UART peek register at $DFxx** — add CPU-readable diagnostic:
   software writes 24-bit address, hardware returns BRAM/SDRAM/cache
   bytes. With this we could:
   - Confirm what's at $C003 in BRAM after PRG load
   - Detect BRAM-vs-SDRAM disagreement
   - Validate the memzap hypothesis directly
   This is ONE RTL change unlocking many diagnostic tests.

2. **WriteSmart + write buffer drain** (was Lane B; promote priority).
   Required for memzap-via-BASIC to be a reliable test, and likely
   needed for general C64 software compat anyway.

3. **Extend GHDL bench with hardware memory hierarchy models**: cache
   + BRAM + SDRAM behavioral. If sim repros the C003 hang we get
   5-second debug iterations instead of 30-min Quartus loops. The
   reduced harness (`sim/c64_reduced_harness/`) has the scaffolding.

4. **Optional: full VICE PC-diff run to $CB00** (~6M instructions).
   200K matched is enough to rule out CPU core; full run useful for
   future regressions. Consider VICE binary monitor for throughput.

5. **Rebuild clean** so deployed RBF matches source (currently has
   sanity-hack hacks no longer in source). Routine; not blocking.

## Do NOT

- Add another TR ring buffer probe variant. The chain is severed.
  `memory/project_tr_ring_chain_broken.md` documents this.
- Touch the P65C816 core for the C003 hang. It's verified correct by the
  full-bench reaching $CB00.
- Pursue Option D BRAM probes in $82-$8E (cleared by sim pagetest
  + v110 hardware verification).
- Use `-Release` during UART debug loops (suppresses DBG_UART).

## Exit condition for next session

EITHER:
- (a) VICE -binarymonitor produces a trace file we can diff against
  `ours_trace.txt`, identifying the first PC where bare-CPU and VICE
  diverge — OR proving they agree end-to-end (which would mean the
  hardware's divergence from sim is PURELY in the SDRAM/BRAM/cache
  layer, narrowing the search), OR
- (b) one system-side probe (cache flush trigger, BRAM/SDRAM mismatch
  counter, etc.) lands a runtime observation that discriminates between
  "cache stale", "BRAM write-through dropped", and "SDRAM read mismatch"
  hypotheses for the C003 hang.

## Artifacts

- `uart_asterix_c003.log` — 39.4s capture characterizing the hang
- `tools/analyze_c003_loop.py` — statistical breakdown
- `tools/analyze_c003_addr_pattern.py` — address-bus walk pattern
- `memory/project_asterix_c003_locked_loop.md` — durable summary
- `memory/project_tr_ring_chain_broken.md` — TR ring abandonment record
- `tools/vice_diff/` — VICE PC-diff scaffolding (bare-CPU side wired,
  VICE side waiting on binary monitor wrapper)
- Prior handoff `docs/session_handoff_2026-04-24_option-d.md` retained
