# Improvement Ideas for Latest Changes

## Scope

Reviewed:

- Latest commit: `148fff8` (`Add Phase 6 dual-port BRAM for VIC zero-contention reads`)
- Current tracked edits in:
  - `C64_MiSTer/c64.sv`
  - `C64_MiSTer/rtl/debug_uart_fmt.sv`
  - `C64_MiSTer/rtl/fpga64_buslogic.vhd`
  - `C64_MiSTer/rtl/fpga64_sid_iec.vhd`
  - `tools/mister_debug.py`
- Current new helper/module:
  - `C64_MiSTer/rtl/bram_valid.vhd`
- Validation workflow notes from:
  - `docs/ultimate64_agent.md`

This file is intentionally ideas-only. No code changes are proposed here.

## Improvement Ideas

### 1. Re-enable BRAM CPU reads with line-valid granularity

Why:

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` currently has `bram_hit_ram <= '0'`.
- The comments explain why page-valid tracking is too coarse: one touched byte marks an entire 256-byte page valid, which breaks RAMTAS and boot.
- In the current state, BRAM is helping VIC/coherency, but not actually providing the intended CPU fast-read path.

Idea:

- Track validity per 16-byte or 32-byte line instead of per 256-byte page.
- Keep the valid store in LUT/MLAB if possible, and reserve full per-byte tracking only for ranges that truly need it.
- Keep the `bram_valid_cycle` guard for all fill/write paths.

Expected upside:

- Restores real bank-`$00` CPU acceleration without paying the full M10K cost of 64K per-byte valid bits.

### 2. Either finish wiring `bram_valid.vhd` or remove the half-enabled scaffolding for now

Why:

- `C64_MiSTer/rtl/bram_valid.vhd` exists, but the active design stubs `bram_byte_valid` to `'0'`.
- `bram_hit_rom_pre <= '0'`, yet `bram_valid_clearing` still sweeps 64K entries.
- That leaves active logic and comments describing a path that is not actually participating in behavior.

Idea:

- Short term: strip dead BRAM-valid clearing/ROM-hit logic from the live path until it is really needed.
- Long term: reintroduce `bram_valid.vhd` only where byte precision is required.

Expected upside:

- Smaller reasoning surface, less debug ambiguity, fewer "this signal exists but does nothing" cases.

### 3. Make BRAM mode selectable instead of hard-coded

Why:

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` still has `bram64k_en <= '1';  -- TEMP: enabled for isolation testing`.
- For this kind of bring-up, runtime A/B switching is more useful than rebuilding for every comparison.

Idea:

- Add an OSD/debug bit or a synthesis generic with at least:
  - SDRAM only
  - BRAM for VIC only
  - Full BRAM assist
- Expose the current mode in UART/overlay/debug docs.

Expected upside:

- Faster bisects on hardware and clearer evidence when a regression is BRAM-related vs cache-related.

### 4. Consolidate BRAM coherence and invalidation into one explicit mechanism

Why:

- Invalidation is currently triggered from multiple places:
  - reset
  - meminit end via `bram_inval_pulse` in `C64_MiSTer/c64.sv`
  - `cache_flush_bank`
- Coherency now depends on CPU writes, SDRAM fills, cache-hit fills, ROM visibility, and PRG injection behavior.

Idea:

- Define a single invalidation/coherency controller or at least a single invalidation source bus.
- Include explicit causes such as reset, PRG inject/meminit, map change, ROM visibility transition, DMA/cart download, and software flush.
- Count and expose invalidations in debug output.

Expected upside:

- Less chance of rare brown-screen failures after unusual load/reset sequences.

### 5. Version the UART format and align diag semantics with the signals users actually care about

Why:

- `C64_MiSTer/rtl/debug_uart_fmt.sv` changed the line format from `T:x` to `T:xx`.
- `dbg_diag` in `C64_MiSTer/rtl/fpga64_sid_iec.vhd` uses raw `cache_hit` and raw `enableCpu`, while `dbg_cache_hit_d1` and overlay counters report post-gated activity.
- That makes it easy for tools and humans to compare mismatched meanings.

Idea:

- Add a version/header field to the UART stream.
- Decide whether the diag byte should represent raw eligibility or actual granted fast-path events.
- Make the docs and parsers reject unknown format versions rather than silently misreading them.

Expected upside:

- More reliable debug automation and fewer false conclusions from UART captures.

### 6. Make `tools/mister_debug.py load_prg` verify success instead of failing soft

Why:

- `tools/mister_debug.py` uses `mbc load_all_as`.
- If that call fails, the current fallback only does `load_core`, which can look like success even though the PRG was never injected.

Idea:

- Default to a hard failure when `mbc` fails.
- Or add verification immediately after launch:
  - check `/tmp/ACTIVE_CORE`
  - read a UART line
  - take a screenshot
  - read back expected screen RAM or state if available
- Also consider adding `load_crt` and `readmem` commands so the tool can validate tests, not just launch them.

Expected upside:

- Fewer false-positive test runs during rapid iteration.

### 7. Build a real MiSTer-vs-U64 golden-reference loop

Why:

- `docs/ultimate64_agent.md` already gives enough API surface:
  - `run_prg`
  - `run_crt`
  - `machine:readmem`
  - config control for `CPU Speed`
- That is enough to automate comparisons instead of depending on screenshots and manual observation.

Idea:

- For each regression PRG/CRT, run the same case on MiSTer and Ultimate 64.
- Read screen RAM (`$0400-$07E7`) and compare PETSCII or expected counters.
- For speed tests on U64, use REST API CPU-speed control instead of SuperCPU registers like `$D07A/$D07B`.

Expected upside:

- Better regression coverage and a hardware reference for tricky cache/BRAM behavior.

### 8. Add a directed regression for the new `$F8`-only SuperCPU ROM mapping

Why:

- `C64_MiSTer/rtl/fpga64_buslogic.vhd` now maps SuperCPU ROM only at bank `$F8`, fixing the SIMM-detection failure caused by over-decoding `$F0-$FF`.
- That behavior is important enough to deserve explicit protection.

Idea:

- Add a tiny PRG/CRT that verifies:
  - bank `$F6` behaves like RAM
  - bank `$F8` serves ROM
  - bank `00:$8000-$9FFF` serves kickstart only while visible
- Run it after any buslogic or ROM-overlay change.

Expected upside:

- Prevents regressions in kickstart boot and ROM/SuperRAM decode.

### 9. Add resource guardrails for BRAM experiments

Why:

- The BRAM comments repeatedly mention M10K pressure and fitter instability.
- That risk is currently documented, but not enforced.

Idea:

- Parse Quartus reports after build and fail when M10K/ALM usage crosses agreed thresholds.
- Track per-phase resource deltas in a small markdown summary.

Expected upside:

- Fewer wasted debug cycles on builds that are already beyond the practical fit margin.

## Recommended Order

If only a few of these are pursued first, I would do them in this order:

1. Re-enable BRAM CPU reads with sane valid granularity.
2. Consolidate invalidation/coherency handling.
3. Build the MiSTer-vs-U64 automated comparison loop.
4. Tighten UART/tooling versioning so the debug data stays trustworthy.
