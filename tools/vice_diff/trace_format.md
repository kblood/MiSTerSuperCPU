# PC Trace Format

Both the VICE side and our sim/hardware side must emit traces in this
format so `vice_diff.py` can compare them line-by-line.

## Format

One instruction-fetch event per line. ASCII text, LF-terminated.

```
<seq>:<pbr>:<pc>:<ir>:<p>:<sp>
```

| Field | Width | Description |
|---|---|---|
| `seq`  | decimal | Monotonically increasing instruction count from boot. Used to align VICE and our trace. |
| `pbr`  | 2 hex   | Program bank register (high byte of 24-bit instruction address) |
| `pc`   | 4 hex   | 16-bit program counter |
| `ir`   | 2 hex   | Instruction register (the opcode byte fetched at this PC) |
| `p`    | 2 hex   | Processor status register (NV-BDIZC for emu, NVMXDIZC for native) |
| `sp`   | 4 hex   | Stack pointer (16-bit native; high byte = 01 in emu mode) |

Example:
```
12:00:080d:a9:24:01ff
13:00:080f:8d:24:01ff
14:00:0812:60:24:01ff
```

## Trigger condition

Emit one line per **fetched instruction**, i.e. once per `VPA && VDA && enable`
edge on our CPU bus, and once per fetched instruction in VICE.

## Emission start

Both sides start emission at the same point — typically `PC = $0801` (BASIC
"RUN" entry point) for a PRG, or `PC = ResetVector` for a cold-boot test.

## Emission end

After N instructions or PC reaches a known goal address. The diff harness
will compare up to `min(len(vice), len(ours))` lines and report the first
divergent one.

## What "divergence" means

Two lines diverge if any field except `seq` differs. The most important
field is `pc` (instruction stream divergence) but `p` divergence on the
SAME pc value indicates a flag-handling bug (e.g. our SR-emu-wrap fix).
SP divergence on the SAME pc indicates a stack-handling bug.

## Why not include data-bus content

Two reasons:
1. VICE's monitor doesn't natively emit per-cycle bus state without heavy
   scripting.
2. Bus content can differ legitimately (e.g. cache-vs-SDRAM hits) without
   indicating a CPU bug.

If we need bus-content diffing later, add a separate side-channel format.

## Known emission quirks (P65C816 side)

- **`dbg_ir` skew**: P65C816's `DBG_IR` port reports the LATEST DECODED
  opcode. At the cycle when a NEW opcode is fetched (VPA=VDA=1, dbg_pc
  matches the fetch address), `dbg_ir` may still hold the PREVIOUS
  instruction's opcode for ~1 cycle. As a result, the IR field in our
  trace lags by one row relative to `pc`. The diff harness should treat
  `pc` as the primary alignment field.
- **Initial register state**: Before reset deasserts (`rst_n=1`), the CPU
  outputs default register values (PC=$0000, SP=$0100, P=$34). Our trace
  starts emission only after `rst_n='1'` to skip these.
- **Trace gating**: For long-running benches (e.g. asterix_full reaches
  $CB00 in ~6M instructions), our dumper arms only at a milestone PC
  (e.g. phase-2 entry at $0852) to keep traces manageable. VICE's
  emission point should be configured to match.
- **Bounded output**: Our trace truncates at TRACE_MAX_ENTRIES (default
  500,000) to avoid filling disk. A `TRACE_TRUNCATED` marker appears at
  the end if this limit was hit.

## VICE side TODO

- Investigate which VICE monitor command produces the closest match.
  Candidates: `trace`, `chis`, `record`, custom Python via `-remotemon`.
- Confirm whether VICE emits one line per opcode fetch or per cycle.
- Match our emission start point (phase-2 entry) by seeding VICE with
  a breakpoint at $0852 then continuing with trace enabled.

## Sim-side dumpers (current)

- **Bare-CPU**: `sim/p65c816_tb/p65c816_asterix_full_tb.vhd:264-316`.
  Armed at PC=$0852 (phase-2 entry). Output:
  `work_asterix_full/ours_trace.txt`. ~500 K entry cap.
- **System-level (reduced harness)**:
  `sim/c64_reduced_harness/c64_reduced_harness_tb_v2.vhd` trailing
  `trace_proc`. Output: `work_v2/ours_system_trace.txt`. ~200 K entry
  cap. Currently emits the boot-phase PC trace (KERNAL/BASIC). To use
  for Asterix-via-system diffing, extend the bench's PRG-load phase
  with the asterix.prg payload bytes plus an autorun trigger at
  $0801, then re-run.
