# P65C816 SingleStepTests harness

GHDL bench that runs the [SingleStepTests/65816](https://github.com/SingleStepTests/65816)
JSON suite (10 000 cases per opcode × 256 opcodes × emu/native = ~5 M cases)
against the bare `P65C816` core under `C64_MiSTer/rtl/65C816/`.

## Setup

Clone the test data into `external/65816/` (about 2.7 GB):

```bash
git clone https://github.com/SingleStepTests/65816 external/65816
```

`external/65816/v1/*.json` are gitignored. The harness reads pre-flattened
text records from `external/65816/v1.bin/` (also gitignored) — generate them
with `tools/sst_convert.py`:

```bash
python tools/sst_convert.py 06 e            # one opcode/mode
python tools/sst_convert.py --rmw           # all 28 RMW opcodes, both modes
```

## Run

From `sim/p65c816_singlesteptest/`:

```powershell
.\run_sst.ps1 -InputFile ../../external/65816/v1.bin/06.e.txt -StopTime 30000ms
```

Output ends with one line:

```
SST_RESULT pass=N fail=N skip=N total=N
```

Skipped cases are ones where the test's `initial.ram` or `final.ram` cells
collide with the prelude region at $00:$FE00..$FE28 (40 bytes). On 06.e
this is ~10/10 000.

## How a case runs

1. RAM is wiped (`sst_mem.clear_all`).
2. `case.initial.ram` is loaded.
3. The 40-byte prelude (CLC/XCE/REP/SEP/LDA/PHA/PLB/PLP/JML, see
   `tools/sst_convert.py make_prelude`) is written at $00:$FE00.
   Prelude wins on overlap with init RAM.
4. CPU resets; the reset vector ($00:$FFFC/FFFD = $FE00) sends it through
   the prelude, which leaves all P/A/X/Y/D/DBR/PBR/PC/E identical to the
   case's `initial` regs, then JMLs to (init.pbr:init.pc).
5. The bench arms on the first VPA+VDA opcode fetch at (init.pbr:init.pc),
   then records `len(cycles)` bus cycles of address/data/RWB/MLB/VDA/VPA/VPB.
6. Final regs are snapshotted on the LAST recorded cycle; a "next-instruction
   opcode fetch" tick advances PC, so we capture before that bump.
7. Final-RAM cells are compared. Bus cycles are compared (addr, data on
   active cycles, MLB inverted to active-high to match SST's polarity).

## Files

- `sst_mem_pkg.vhd` — sparse 24-bit memory (lazy bank allocation, $00 default)
- `p65c816_sst_tb.vhd` — bench: parser, prelude loader, recorder, comparator
- `run_sst.ps1` — GHDL analyze/elaborate/run wrapper

## Known native-mode 06.n quirks (4/10 000)

- 158, 9836: 16-bit ASL (M=0) high-byte mismatch
- 1657: P-flag N-bit wrong on 8-bit case
- 194: prelude can't reach (D6:E489) — case uses an unusual PC region

These are pre-existing native-mode bugs unrelated to the v273 emu-mode RMW
fix; they will be triaged in Phase 1/2 of the SST sweep.
