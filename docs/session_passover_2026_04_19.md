# Session Passover 2026-04-19: ROOT CAUSE FOUND for 90-min fit regression — async probe port broke M10K inference

## Headline

**The 45-80 min map/fit regression since Apr 16 has a single-line cause:**
`C64_MiSTer/rtl/c64_ram64k.vhd:74` contains an asynchronous read
(`probe_dout <= unsigned(ram(to_integer(probe_addr)))`) that prevents
Quartus from inferring M10K block RAM. Instead it synthesizes the entire
64KB × 8 = **524,288 LUT flip-flops**. Design balloons to **469,442 ALMs
(1120% of device capacity)** — unfittable.

- Apr 16 post-fit: ~30,300 ALMs ✓
- Today's release-revision fit: 469,442 ALMs ✗ (15× larger, fails)
- The extra 438,176 ALMs live entirely in `c64_ram64k:ram64k_inst`

## What happened

1. At some point after Apr 16, a `probe_addr`/`probe_dout` port pair was
   added to `c64_ram64k` for simulation/debugging.
2. The async read disables M10K inference because M10K has no async-read
   port — Quartus falls back to distributed LUT RAM, which for 64KB means
   **524,288 flip-flops**.
3. The port is connected through `fpga64_sid_iec` → `c64.sv` but
   `c64.sv` ties `bram_probe_addr` to `16'h0000` and leaves
   `bram_probe_data` unconnected. It's completely unused.
4. No sim harness actually consumes `bram_probe_*`. The
   `sim/c64_reduced_harness/*.vhd` uses a DIFFERENT probe (24-bit
   SCPU-wide address space, not the 16-bit bank $00 probe).

## The exact fit-report evidence

From `output_files/C64_release.fit.rpt`:

```
; |sys_top|emu:emu|fpga64_sid_iec:fpga64|c64_ram64k:ram64k_inst|
;   ALMs: 438,177
;   Combinational ALUTs: 874,208
;   Dedicated Logic Registers: 524,304   ← 65,536 addresses × 8 bits
```

Plus: `Logic utilization (in ALMs) : 469,442 / 41,910 ( 1120 % )`.

## The fix (not yet applied — preserved for review)

Remove the `probe_addr`/`probe_dout` port entirely. It's dead weight that
breaks synthesis. Three files touch it:

1. **`C64_MiSTer/rtl/c64_ram64k.vhd`** — remove `probe_addr`, `probe_dout`
   from entity + remove line 74 (the async read).
2. **`C64_MiSTer/rtl/fpga64_sid_iec.vhd`** — remove `bram_probe_addr`,
   `bram_probe_data` ports (lines 274-275) + the port map in the
   `c64_ram64k` instance (lines 1647-1648).
3. **`C64_MiSTer/c64.sv`** — remove the two `.bram_probe_addr(...)` and
   `.bram_probe_data()` lines in the `fpga64_sid_iec` instance
   (lines 2162-2163).

After the fix, a `-Clean -Release` build should finish in 15-25 min with
~30k ALMs, matching Apr 16's baseline.

### Alternative fix if probe is wanted back later

Register the probe read (1-cycle latency). Inserting a flip-flop at the
output makes it synchronous, which M10K supports.

```vhdl
process(clk)
begin
    if rising_edge(clk) then
        probe_dout <= unsigned(ram(to_integer(probe_addr)));
    end if;
end process;
```

But given `c64.sv` doesn't actually use the probe (tied-to-zero addr,
open data), removal is cleaner.

## Diagnostic timeline (for reference)

| Attempt | What we tried | Result |
|---|---|---|
| Apr 17 agent's 62-min fit | `-Clean` debug build | Killed by usage limit mid-fit |
| Apr 18 22:55 my first `-Clean -Release` | Single QSF + macro patch | Killed at 45min map + early fit |
| Apr 19 01:03 revision-split `-Clean -Release` | C64_release.qsf | Killed mid-fit after ~75 min |
| Apr 19 01:38 bisect — revert 0bcfabe (PRG fix) | `-Clean -Release` | **FAILED** at ~2h with "Can't fit design" error — provided the fit.rpt that identified the culprit |

The passover's hypothesis about "incremental-state corruption" and
"debug RTL bloat" were both wrong. The real cause was a single async-read
port in the bank-$00 RAM that disabled M10K inference. Apr 16's build
somehow didn't hit this (possibly probe was added later, or smart-compile
carried over a valid M10K-inferred netlist from a previous run).

## Current repo state

- `C64_MiSTer/c64.sv` restored to committed state (0bcfabe — with PRG fix).
- `C64_release.qsf` and QPF revision work from 2026-04-18 session preserved.
- `build_c64.ps1` routes `-Release` to `C64_release` revision correctly.
- `build_release_no_prg_fix_2026-04-19.log` contains the failed build output
  that identified the probe issue.

## Recommended next session opening step

Apply the fix, `-Clean -Release` build (expected 15-25 min), validate
the resulting rbf boots on MiSTer hardware, then validate the PRG
auto-RUN classification fix works.

## Bisect confirmation

When did the probe get added? Run:
```
git log --oneline -p -- C64_MiSTer/rtl/c64_ram64k.vhd | grep -A5 "probe_"
```
to find the commit that introduced it. Likely somewhere in the March
BRAM-64k implementation work (see `docs/bram64k_implementation_plan.md`).
