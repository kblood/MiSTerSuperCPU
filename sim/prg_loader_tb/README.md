# sim/prg_loader_tb — PRG loader / cache invalidation bench

A GHDL-only bench that reproduces the MiSTer C64 SuperCPU PRG-load path end
to end, without Quartus and without touching any hardware. It runs in a few
seconds and replaces the ~17-minute build-and-deploy cycle for diagnosing
PRG-load bugs (cache invalidation, BASIC pointer meminit, BRAM page-valid
bitmap, stale bytes surviving the load window).

## Why this bench exists

The production symptom is: `load_rom` an asterix.prg / similar, bytes appear
to land in BRAM/SDRAM, then "memory seems to reset" and the PRG runs with
garbage. Previous fix commit `8ef779f` (BRAM write-through for io_cycle +
fold `bram_invalidate` into `cache_flush`) worked for `test_addr1000.prg`
but not for real .prg files. Iterating on hardware is too slow.

This bench narrows the DUT down to the exact slice that can exhibit the bug:

- the `inj_meminit` state machine (reimplemented in VHDL from `c64.sv`
  lines 1396-1443, bit-for-bit faithful to the real case statement)
- the `bram_invalidate` / `cache_flush` glue (from
  `fpga64_sid_iec.vhd` lines ~1481-1489)
- a 64KB BRAM with a 256-entry page-valid bitmap
- a minimal direct-mapped cache stub with the `not bram_invalidate` fill
  gate (same gate as the real `cache_fill_we` on line ~1519)
- a CPU-style read port used only by the scoreboard

CPU, SDRAM controller, VIC, CIA, SID, cartridge, SCPU ROM overlay,
SuperRAM pipeline, write buffer — none of that is modeled. None of it
is relevant to the meminit / cache race.

## Files

| File | Purpose |
|---|---|
| `prg_loader_pkg.vhd` | Shared types + expected BASIC-pointer helper + hex format |
| `prg_loader_dut.vhd` | Behavioral PRG-load DUT (ioctl handler, meminit SM, BRAM, cache stub) |
| `prg_loader_tb.vhd`  | Testbench — drives 3 scenarios, scoreboards BRAM + pointers |
| `run_tb.ps1`         | Windows PowerShell runner — analyze, elaborate, run, FST output |
| `run_tb.sh`          | Bash runner (same flow for WSL / Linux / macOS) |
| `test_payloads/`     | Human-readable reference of the hardcoded byte streams |

## Scenarios

All three run in a single elaboration, back-to-back. Each scenario resets
to the prior BRAM state (no between-scenario reset), so page-valid bits
from earlier scenarios can only help, never hide, a failure.

- **S1** — PRG at `$0801`, 6 bytes (`LDA #$42; STA $0400; RTS`). Clean path.
- **S2** — same payload at `$1000`. Exercises the page-valid bitmap for
  pages other than `$08`, and checks that `inj_end` is updated correctly
  for a non-BASIC load address.
- **S3** — PRG at `$0801` + "cold reads" interleaved into the download
  window. Each cold read attempts to fill the cache with the pre-load
  byte at `$0810+i`. If the `not bram_invalidate` fill-gate is broken,
  the cache captures `$00`s and the post-load readback at `$0801..$0806`
  returns stale data.

After each scenario the bench reads back:

- every payload byte at `load_addr .. load_addr + N - 1`
- the BASIC zero-page pointers: `$2B/$2C` (TXT), `$2D/$2E` (VAR),
  `$2F/$30` (ARY), `$31/$32` (STR), `$AC/$AD` (SAVE), `$AE/$AF` (LOAD_END).

Mismatches call `report ... severity failure`, which makes GHDL exit with a
non-zero status. The runner propagates that as an overall `FAIL`.

## Running

### Windows (PowerShell)

```powershell
cd sim\prg_loader_tb
.\run_tb.ps1
```

### WSL / Linux / macOS

```bash
cd sim/prg_loader_tb
./run_tb.sh
```

Override stop-time with `-StopTime 5ms` (ps1) or `STOP_TIME=5ms ./run_tb.sh`.

Expected output on success:

```
==> Analyze
==> Elaborate
==> Run (stop-time=2ms)
S1 inj_end = $0807
S1 payload[0]: OK  0801 = $A9
...
==== SUMMARY: pass=54  fail=0 ====
prg_loader_tb: PASS
RESULT: PASS
```

End-to-end wall-clock time on a modern laptop: **under 10 seconds**.

## Interpreting failures

The scoreboard prints a line per byte check. A failure looks like:

```
S1 payload[2]: FAIL 0803 got $00 expected $8D
```

That tells you:

- which scenario (`S1`)
- which addr (`$0803`)
- observed byte (`$00`) vs expected (`$8D`)

Typical interpretations:

- **Payload bytes are zero** but BASIC pointers are correct → `io_bram_we_pulse`
  is not firing, the write-through path is broken. Check the
  `ioctl_load_addr(24 downto 16) = "000000000"` guard and the
  `io_bram_we_pulse` generation in `prg_loader_dut.vhd`.
- **Payload bytes OK but pointers wrong** → the `inj_meminit` case statement
  has drifted from `c64.sv`. Re-read `c64.sv` lines 1396-1443 and update.
- **Scenario 3 fails but S1/S2 pass** → the `not bram_invalidate` gate on
  the cache fill path is broken or missing. This is the exact bug class
  the bench was built to catch.
- **Everything fails** → the `bram_pgvalid` clear loop is running forever
  or meminit is not terminating at `$100`. Check `status_inj_busy` in the
  waveform: it should go high on the falling edge of `ioctl_download`
  and low exactly 257 clocks later.

The FST waveform at `work/prg_loader_tb.fst` can be inspected headlessly
with `pywellen` or interactively with Surfer / GTKWave.

## Adding a new PRG payload

1. Define a new `byte_array_t` constant in `prg_loader_tb.vhd` (copy the
   `PRG_S1_PAYLOAD` / `PRG_S1_LOAD_LO/HI` block and rename).
2. Add a new scenario block in the `stim` process — call `push_prg(...)`
   with your new bytes, wait for `status_inj_busy = '0'`, then
   `verify_payload(...)` and `verify_basic_pointers(...)` with the
   expected `inj_end` (= `load_addr + payload_length`).
3. Re-run `.\run_tb.ps1`.

There is no runtime file loader — payloads are compiled into the bench as
VHDL constants. This is intentional: it keeps the bench hermetic and the
elaboration cache small.

## What the bench currently tells us

At the time of first commit: **the bench PASSES**. That means the RTL
semantics we reimplemented (the `inj_meminit` state machine + the
`bram_invalidate` gate on cache fill + the page-valid bitmap clear) are
internally consistent and correctly move payload bytes into BRAM and set
the right BASIC pointers.

If the bench passes but the real hardware still fails on asterix.prg, the
bug must be in a layer **this bench does not model**. The next logical
places to look are:

- the SDRAM pipeline (writes going to SDRAM but not being read back
  correctly by the CPU through the SuperRAM/BRAM selector)
- the turbo-mode CPU enable/schedule interaction during the io_cycle
- BASIC itself corrupting the pointers on auto-RUN (already observed for
  `test_addr0801.prg` per the latest CLAUDE.md note)
- bank-$01 SuperRAM path shadowing bank-$00 BRAM reads
- the real cache's 1024×8 M10K data path, which has 1-cycle latency the
  stub does not model

None of those can be reproduced at this bench's abstraction level. If one
of them is the real culprit, the next step is Phase 3 / 4 of
`docs/c64_simulation_harness_implementation_plan.md` — a
reduced-system harness around `fpga64_sid_iec.vhd`.
