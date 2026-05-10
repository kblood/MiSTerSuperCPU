# Doom debug — 2026-05-10 OP+R7 probe results

## Bottom line: wait-loop thesis is **fully dead**

The R7+OP build (`dcd14fbca64531a761b843d98c875fa7`, branch tip `38f3dc2`)
deployed and ran. Hardware data definitively refutes the "Doom is in
$0707+X wait loop" thesis. The new framing: **main thread halts at
$41:$DB93 = $00 = BRK opcode, and our P65C816 BRK/RTI handling appears
to keep main pinned at I=1 forever after the trap.**

## Build snapshot

| Field | Value |
|-------|-------|
| RBF md5 | `dcd14fbca64531a761b843d98c875fa7` |
| Branch tip | `38f3dc2` (8 commits this session) |
| Quartus elapsed | 11:44 |
| Resources | 26,805 ALMs / 64% — RAM 61% |
| Cold boot | T65 + SCPU READY ✓ |

## OP field (commit 5e8f85a) — 4 distinct values across 70+ vblanks

Both `uart_120s.txt` (35 lines) and `uart_240s.txt` (35 lines) show
the SAME 4 OP patterns:

| OP value | Decode | Source |
|----------|--------|--------|
| `E248` | SEP imm + PHA | IRQ stub `$FF01` + `$FF03` |
| `AFAF` | LDA long + LDA long | IRQ stub `$FF04`/`$FF08`/`$FF0C`/`$FF10` |
| `2840` | PLP + RTI | IRQ stub `$FF15` + `$FF16` |
| `1D00` | ORA abs,X + BRK | `$00` = BRK fetched at halt PC; `$1D` source unclear |

**Wait-pattern opcodes `$DF`, `$B0`, `$D0` appear in ZERO samples.**
At 73 IRQ acks/sec (normal raster rate), main has ~14 ms between
IRQs. At 20 MHz that's thousands of fetches per gap. If main were
running the CMP/BCS/BNE loop, we'd catch wait-loop opcodes. We don't.

## R7 field (commit 74e9c74) — locked at single value post-halt

| Phase | R7 distinct values |
|-------|--------------------|
| t=30s (loader) | 9 (`7000 704F 88B9 8900 8A05 8B97 8CFB 8FF8 9709`) |
| t=60s (loader) | 8 |
| t=120s (post-halt) | **1 (`B404`)** |
| t=240s (post-halt) | **1 (`B404`)** |

`B404` = LSB `$B4`, data `$04` → `$00:$07B4 = $04`. Last main-thread
read in `$07xx` range was this; no new reads after halt.

## ⭐ NEW: IRQ-thread PC reaches `$41:$FCF4` (25% of samples)

PC distribution across post-halt samples:
- `$00:$FF04` LDA $D019 — 9 hits
- `$00:$FF11` LDA $DD0D — 9 hits
- `$00:$FF17` post-RTI — 9 hits
- **`$41:$FCF4` — 9 hits** (~25%)

I field (`pc_irq_r`) shows `$41:$FCF3` at those moments — IRQ-context fetch in bank $41. Default IRQ trampoline at $00:$FCEE = `5C 00 FF 00` (JML to ack stub), but **J ring captures `FCEE FCEE FCEE FCEE`** — meaning $FCEE byte was $20 or $22 (JSR/JSL) when fetched. **Trampoline overwritten.**

ZERO static REU writers found for $FCEE-$FCF1. Possible cause: native BRK push wrap if SP transited $FCxx, or spurious write tripped `scpu_irq_tramp_installed` latch exposing junk RAM bytes. Bytes at $41:$FCxx are a 16-byte structured data table (record fields $1F $01, $0D $00, etc.) — fetching as code yields BRK chains.

**Two parallel halt modes:**
1. Main-thread pinned at $DB93 (single fetch, then I=1 indefinitely)
2. IRQ-thread wandering through $41:$FCxx data-as-code

## REU bytes confirm halt PC = `$00`

```
$41:$DB80: 00 00 DD 07 07 00 50 06 F0 01 00 00 DE 07 07 00
$41:$DB90: 50 06 10 00 00 00 DF 07 07 00 B0 03 D0 FE 00 00
                    ^DB93 = $00 = BRK opcode
                          ^DB96 = wait-pattern start (CMP $0707,X)
```

The wait pattern bytes `DF 07 07 00 B0 03 D0 FE` (CMP $00:$0707,X /
BCS +3 / BNE -2) **are real disassembly** — not a coincidental data
match. They start at `$DB96`. PC entered the table 3 bytes too early
at `$DB93`, fetching `$00` = BRK.

## ZERO static callers in 16 MB REU

Scanned for `JML/JSL` to `$41:$DB93/94/96/80/90/00` and 24-bit
pointers `93 DB 41`: **all return zero hits**. Only nearby pointer
hit was `00 DB 41` at `$7B:$C9DB` (irrelevant).

PC reaches `$41:$DB93` via runtime-computed dispatch (recompiler
emits target bytes from MIPS register state). No static instrumentation
can find the caller — needs a writer-PC trace OR a JML-target probe.

## pc_main_r gating proves halt is real

`pc_main_r <= cpu_pc_now` only fires when:
- `opcode_fetch_pulse = '1'`
- `cpu_p_now(2) = '0'` (I-flag clear, main thread)

N=`$41:$DB93` frozen across 8759 IRQ acks (120 s → 73/sec, **normal
raster rate, NOT BRK-spam rate**) means: **main thread fetched at
`$DB93` once and never fetched again with I=0.**

The trace ring (trace_op2/op3) is NOT I-flag-gated — it captures all
fetches. We see only IRQ-stub opcodes in trace, never main-thread
bytes. So either:

1. **P65C816 BRK pushes wrong P** (e.g., I=1 instead of I=0) →
   RTI restores P with I=1 → main never re-enters I=0 context.
2. **P65C816 RTI doesn't restore I-flag correctly** in native mode →
   same end-state.
3. **CPU stalls in IRQ handler** somewhere that never fetches RTI.
4. **RTI returns to a non-fetching state** (RDY low, address mux
   wedge in SDRAM/SuperRAM).

Hypothesis (1) and (2) are the most testable.

## Decision tree result

Per pre-deploy plan: **option 2 — "OP shows different non-CMP opcodes"**
— but with critical refinement: N is NOT a stale latch. The CPU
truly halts at `$41:$DB93`. The wait-pattern thesis is dead, and a
new CPU-side bug suspect has emerged.

## Next probes (in order of cheapness)

### Probe 1: GHDL bench reproducing native BRK trap → IRQ → RTI

`sim/p65c816_tb/p65c816_brk_trap_rti_tb.vhd`. Set up:
- Native mode, I=0
- Memory model with bank `$41` byte at `$DB93` = `$00`
- IRQ vectors at `$00:$FFE6/E7` → `$00:$FF00`
- IRQ stub bytes at `$00:$FF00..$FF16` (the actual stub layout)
- JML PC = `$41:$DB93`

Verify after RTI:
- PC restored to `$41:$DB95` (PC+2 of BRK byte)
- P-flag I bit = 0
- Next opcode fetch at `$41:$DB95` fires opcode_fetch_pulse with I=0

If this fails → the bug is reproduced in sim. **Cheap, decisive.**

### Probe 2: Surface trace_pc{0,1,2,3} ring to UART (write-only probe)

The trace ring already exists in `fpga64_sid_iec.vhd:743+`. Currently
only op2/op3 are surfaced. Surfacing pc0/pc1/pc2/pc3 (12 hex digits
each, 48 chars) would tell us where `$1D` and the IRQ-stub fetches
landed in PC-space — distinguishing "main fetched a few times after
$DB93" from "all fetches are IRQ-stub PC range".

Tradeoff: takes UART line space; no cycle count.

### Probe 3: Read $00:$07B4 region after halt via peek PRG

We know R7=`$04` was the last main-read at `$00:$07B4` before halt.
Use peek_d27c-style PRG (loaded post-halt) to dump `$00:$0700-$07FF`
contents — what's there at runtime? Does B4 area contain a JML
pointer to `$41:$DB93`?

Tradeoff: must reset core to load PRG, losing post-halt state.

### Probe 4: Audit P65C816 BRK and RTI opcodes for native I-flag

In `rtl/65C816/MCode.vhd` — search for BRK and RTI handlers. Native
mode behavior:
- BRK should push P with I bit reflecting state BEFORE BRK (typically I=0).
  CPU then sets I=1 internally.
- RTI should pop P including I bit, restoring whatever was on stack.

If our microcode pushes P with I=1 (post-BRK state), or RTI doesn't
fully restore I, we have the bug.

## Files updated this session

- `tools/doom_full/{shot,uart}_*.{png,txt}` — fresh capture artifacts
- New memory entry: `project_doom_db93_op_r7_probe_landed.md`
- MEMORY.md: superseded older wait-loop entries, promoted v294 finding

## Known dead-ends not to revisit

- **"Wait loop polls $0707+X"** — refuted by OP showing zero wait-pattern bytes
- **"$DB93 is mid-instruction operand"** — refuted by REU bytes showing `$00` aligned at `$DB93` and matching legit disasm starting at `$DB96`
- **"$DB93 is a frozen latch"** — partial refutation: it IS the actual last main-thread fetch PC, just frozen because main never fetches again
- **"Doom uses _tick_install"** — refuted in v2 NMI fix (no $FFEA/EB writes detected)
- **"Bank-cross long-abs,X bug"** — refuted via `p65c816_scpumips_copy_tb`

## Open questions

- Why does Doom's runtime dispatch land at `$41:$DB93` (off by 3 from
  `$DB96`)? Computed from runtime data we don't have static visibility into.
- Is P65C816 native BRK/RTI broken? Probe 1 will tell.
- What is `$1D` in OP — main thread fetch or some IRQ-stub byte we missed?
  (No `$1D` in our IRQ stub bytes; might be a transient from main's first
  fetch chain $DB93 → $DB95 → $DB97 → ...)
