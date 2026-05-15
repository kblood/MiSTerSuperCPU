# Debugging Methodology

Read this when you're about to debug a "memory corruption" or "wrong-value"
bug on the SuperCPU fork — *before* starting a probe-walk series. It exists
because we burned ~80 builds (v260–v339) on the music_num=-9 wedge using
CPU-state writer-probes when the actual bug was a bus-mux ignoring SCPU bank
bits. The chain was internally consistent at every step but never closed.
Reading the buslogic VHDL would have found it on day 1.

## Step 1 — Classify the bug class before picking a tool

| Class | Symptom signature | Right tool |
|---|---|---|
| **(a) CPU wrote wrong value** | One specific address gets a bad byte after a known instruction | UART writer-probe ring, narrow filter |
| **(b) DMA wrote wrong value** | Address corrupted but no CPU writer captured; correlated with REU/VIC activity | UART writer-probe with DMA gate |
| **(c) Mux returned wrong source** | Multiple addresses across multiple banks fail at the same offset range | **Read the routing code + broad address scan** |
| **(d) Bit-rot in memory** | Write-then-read of arbitrary data fails reproducibly at one address | Write-then-read sweep across address space |

Probe-walking works for (a) and (b). It is **useless** for (c) and (d) — every
probe will find a real "writer" upstream of the corruption that is itself
just propagating bad data the routing layer fed it. The chain extends forever
because the actual bug is *between* the CPU and the memory, not in either.

## Step 2 — The cheapest disambiguator (run this first)

When the symptom is "memory returns wrong byte at address X":

1. **Peek a grid** of nearby addresses, not just X. Use a PRG like
   `tools/code_peek_diff3.prg` — 8 sites across the address range you suspect.
2. **Ask the categorical question:** is the failure
   - **value-specific** (this address holds the wrong byte but neighbours are fine) → class (a)/(b) — probe-walk is appropriate
   - **address-specific** (multiple addresses in the same offset range fail across multiple banks) → class (c) — *stop probing CPU state; read the bus/mux code*
   - **bank-specific** (one bank corrupted across many offsets) → likely a load/DMA path bug — check hps_io and REU FETCH wiring

This is a 10-minute test that often saves weeks.

## Step 3 — For class (c), read the routing code

When you have a custom bus/mux layer on top of a vanilla core (as the SCPU
fork does on top of MiSTer C64), and the symptom is class (c):

1. Read `fpga64_buslogic.vhd` (~600 lines). Specifically the `cs_*Loc`
   decode process and the `cs_ram` / output `cs_*` assignments.
2. Read the `cpuDi` mux in `fpga64_sid_iec.vhd` (the section gathering
   data into the CPU). Note which gates check `addr_hi_816` (SCPU bank)
   and which silently use `cpuAddr` (16-bit) only.
3. Ask: **does every decode gate that fires on $D000-$DFFF know about the
   SCPU bank?** If any gate fires on `cpuAddr[15:12] = $D` without checking
   `addr_hi_816`, SCPU long-mode accesses to `$XX:$Dxxx` (bank != $00)
   will trigger I/O register paths instead of SuperRAM paths.
4. Symmetrically: does `cs_ram` include every condition under which SDRAM
   *should* serve a cycle? For SCPU bank != $00, the answer is "all
   addresses" — but if `cs_ram` is OR'd only from the vanilla `cs_*Loc`
   subset, $XX:$Dxxx access will never assert ramCE.

The music_num=-9 fix is documented in commit `b2d44d1`:
- `fpga64_sid_iec.vhd:1888` — cpuDi mux returns `ramDin` for `addr_hi_816 /= $00`
- `fpga64_buslogic.vhd:534-536` — `cs_ram` includes `scpu_long_access`

## Step 4 — Use VICE as a differential oracle early

For any "Doom is doing the wrong thing" bug, run xscpu64 with the same
inputs and capture the same internal state. If VICE behaves correctly and
hardware doesn't, the bug is in the FPGA infrastructure (memory routing,
DMA, timing), **not** CPU semantics — eliminating an entire class of
hypothesis. Five minutes to set up, definitive answer. See
`tools/vice_doom_5cb546_compare.py` for the existing harness.

This should be **step 2 or 3**, not step 312.

## Anti-patterns to recognize in yourself

If you observe these in your own session, stop and re-read Step 1:

- **"Every probe found something real, but the chain keeps extending."**
  This is the signature of class (c)/(d) being chased with class (a) tools.
  The writers you're capturing are real. They are not the bug.

- **"I've been using the same probe template for >10 builds."**
  Your hammer might not match this nail. Run the broad scan.

- **"The corruption value is internally consistent across the chain
  ($F7 → $F7 → $F7)."**
  Consistent propagation through CPU regs/ZP is exactly what you'd
  expect if the *source* byte is wrong. The bug is at the source, not
  in the propagation. Where does the very first $F7 come from? If
  "from a SuperRAM read," scan SuperRAM directly without running Doom.

- **"VICE matches and HW doesn't, but I'm still probing CPU state."**
  Stop. The bug is not in CPU semantics. Read the bus layer.

## When probe-walking IS right

This doc is not anti-probe. Writer-probe rings are the right tool for:

- IRQ wedges and stack corruption (e.g. v311–v313 IRQ ack stub work)
- BRK chain wedges where one writer puts a bad opcode in a specific
  location (e.g. earlier $0705 BRK loop work)
- Cache coherence bugs (the v158b Asterix fix)
- DMA timing bugs where the writer is a non-CPU agent

These are all class (a)/(b) bugs. The probe ring's value is that it
shows you the exact PC of the writer at fire time, which is conclusive
when the bug is "CPU wrote the wrong thing."

## TL;DR decision tree

```
Symptom: "memory returns wrong byte at X"
│
├── Have you peeked nearby addresses to see if neighbours also fail?
│   ├── NO → run code_peek_diffN.prg with 8+ sites. Re-decide.
│   └── YES, only X fails:
│       └── Probe-walk the writer to X. Class (a)/(b) tools apply.
│
├── Multiple addresses fail at the same offset range across banks?
│   └── Class (c). STOP probing CPU state.
│       Read fpga64_buslogic.vhd + cpuDi mux in fpga64_sid_iec.vhd.
│       Look for cpuAddr[15:12]=$D decodes that ignore addr_hi_816.
│
├── One bank corrupted across many offsets?
│   └── Load/DMA path bug. Check hps_io + REU FETCH wiring.
│
└── Bug only on HW, not in VICE?
    └── FPGA infra bug, not CPU semantics.
        Read bus/memory/DMA RTL. Do not probe-walk CPU state.
```

## Related references

- `project_bug_pinned_io_decode_ignores_bank.md` (memory) — full
  diagnosis + two-part fix for the music_num=-9 root cause.
- `docs/debug_agent.md` — UART format, MiSTer connection, tools.
- `tools/vice_doom_5cb546_compare.py` — VICE oracle harness.
- `tools/build_code_peek_diff3.py` — 8-site grid peek (template
  for class-(c) disambiguation).
