# SuperCPU VIC Scrolling-Lines Test Suite

This test suite adds runtime-selectable VIC data-path experiments plus counters to narrow root cause.

## Runtime Control

- Register: `$D07B` (bank `$00`)
- Bits `[1:0]` = VIC test mode:
  - `0`: baseline (live `vicDi`)
  - `1`: force held CPUF data at `CPUE`
  - `2`: force held CPUF data at `VIC2` (legacy timing experiment)
  - `3`: force held CPUF data at both `CPUE` and `VIC2`
To set these modes use:
POKE 53371,0
POKE 53371,1
POKE 53371,2
POKE 53371,3
Readback:
- `PRINT PEEK(53371)` returns current mode in bits `[1:0]`.

## Overlay Row 4

Row 4 now shows:

- `M:x` mode nibble (`x` = 0..3)
- `F:xx` CPUF live-zero counter (`vicDi == $00` at CPUF)
- `P:xx` CPUE live-zero counter (`vicDi == $00` at CPUE)
- `C:xx` CPUE mismatch counter (`live vicDi != held CPUF data`)

Interpretation:

- `F` high, `P` high, `C` low: SDRAM is often returning zero already at/near return.
- `F` low, `P` high, `C` high: likely clobber/lifetime issue between CPUF and CPUE.
- `M=1` significantly reduces artifact: consume-point alignment issue (CPUE hold helps).
- `M=2` helps but `M=1` does not: previous VIC2 path was influencing debug view, not true consume point.
- No mode changes behavior: likely upstream memory/content issue, not consume mux timing.

## Current Observed Outcome (March 2, 2026)

- In user testing, `M` switched correctly across modes `0..3`.
- Artifact severity did not materially change across modes.
- `C` remained `00` while `F` and `P` increased quickly in artifact cases.
- This currently points away from CPUE-vs-held divergence and toward upstream read-side/workload sensitivity.

## Suggested Hardware Matrix

Use each mode (`M=0..3`) across each ROM profile:

1. Baseline C64 (SCPU off)
2. SCPU on + standard ROM
3. SCPU on + SCPU kick ROM
4. SCPU on + diag ROM

For each run, record:

- Row 3 (`C:...`) capture snapshot
- Row 4 (`M/F/P/C`) after at least 10 seconds
- Visual artifact severity (none / mild / severe)

This matrix lets you rule out:

- data-return zeros vs data-lifetime clobber
- CPUE vs VIC2 consume-phase mismatch
- ROM/workload sensitivity vs fixed timing fault
