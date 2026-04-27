# Session Handoff — 2026-04-27 — Asterix title screen FIXED

Last updated: 2026-04-27 19:00. This file is overwritten each session.

## One-line status

**Asterix title bug FIXED. `c64_ram64k.vhd` now bypasses the M10K
read-during-write (RAW) hazard with a cycle-N+1 write-data forward,
so the SCPU decompressor's `INC $2D / INC $2F` + `LDA ($2F),Y` /
`STA ($2D),Y` loops in handlers 4 and 7 of the `$0100-$01FF`
dispatcher no longer see stale pointer bytes. Title bitmap renders,
SPACE advances to the "ASTERIX AND THE MAGIC CAULDRON" screen with
sprites animating. Vanilla C64 BASIC still boots clean. Commit
`b267455`.**

## What was broken

Asterix's relocator copies a 256-byte dispatcher from `$0864-$0964`
(in the PRG image) to `$0100-$01FF`, then jumps there. The dispatcher
has 8 handlers selected from low-byte table `$011A-$0121` =
`A8 4A AF 7D 5C 42 46 30`. Two of those handlers tight-loop on zero-page
pointer reads:

* Handler 7 at `$0130` (run-length encoder) — `LDA ($2F),Y` reads the
  source pointer, then `JSR $0122` advances `$2F`.
* Handler 4 at `$015C` (literal copy) — `STA ($2D),Y` then `INC $2D`
  + `BNE` repeats X·`$39` times.

Under SCPU turbo, the read of `$2D` / `$2F` after the immediately
preceding `INC` lands inside the M10K BRAM's read-during-write window.
`c64_ram64k.vhd` had `attribute ramstyle of ram : variable is "M10K, no_rw_check"`,
which on Cyclone V picks `READ_DURING_WRITE_MODE = DONT_CARE`. The
registered read-output may stay at the *previous* contents until the
internal write commits, so the loops kept indexing through the same
address forever. Decompression never reached the exit handler at
`$01A8 → JMP $CB00`, so the title bitmap never rendered.

## What fixed it

`C64_MiSTer/rtl/c64_ram64k.vhd`:

```vhdl
process(clk) begin
  if rising_edge(clk) then
    if a_we = '1' then ram(to_integer(a_addr)) := std_logic_vector(a_din); end if;
    a_dout_raw <= unsigned(ram(to_integer(a_addr)));
    a_we_d1   <= a_we;
    a_din_d1  <= a_din;
  end if;
end process;
a_dout <= a_din_d1 when a_we_d1 = '1' else a_dout_raw;
```

Both the M10K read latch and `a_we_d1`/`a_din_d1` register sample the
same `a_addr` at the same edge, so when `a_we_d1='1'` the byte being
returned this cycle is *exactly* the byte we just wrote — forwarding
`a_din_d1` is correct without an explicit address comparison. Adds a
few flops + an 8-bit mux; clk32 timing is the same as the v155
baseline.

### Do **NOT** drop `no_rw_check`

A v157 attempt to use plain `"M10K"` (let Quartus infer write-first)
blew clk64 worst-case slack to **-8.562 ns** with TNS -49866 ns and
85 % ALMs (was 73 %). The Cyclone V M10K cannot meet 64 MHz with the
forwarding muxes Quartus inserts. The bypass approach above keeps
`no_rw_check` and is timing-safe.

## Verification on hardware (commit `b267455`, rbf md5 `5844c1b8…`)

* Cold-reload `/media/fat/_Test/C64.rbf` → BASIC prompt.
* `python tools/mister_debug.py load_prg ./asterix.prg` (mbc load_rom path).
* Title screen renders: "SCE PRESENTS / ASTERIX. / HIT SPACE TO START"
  with horizontally scrolling cracker credits — `v158b_after_loadprg.png`,
  `v158b_title_60s.png`, `v158b_repro2.png` (after a second cold-reload).
* `mtype space` → "ASTERIX AND THE MAGIC CAULDRON" gameplay screen
  with sprite characters on the ground tiles — `v158b_after_space.png`,
  `v158b_gameplay.png`.
* Cold reload → BASIC boot screen still fine (no regression) —
  `v158b_basic_smoke.png`.
* Stable for 2.5+ minutes; reproducible across reloads.

## Workflow caveat (separate from the RTL fix)

`echo load_core asterix.mgl > /dev/MiSTer_cmd` reloads the rbf but
does **not** trigger the PRG ioctl in current builds. The C64 sits at
the BASIC `READY.` prompt with no autorun, and a manual `RUN` says
`?UNDEF'D STATEMENT` because RAM was never populated. Use `mbc
load_rom C64 …prg` or `python3 tools/mister_debug.py load_prg
<file.prg>` instead. Earlier "v156 colored garbage" captures were
testing with no PRG actually loaded — the RTL fix was already correct
in v156, but the broken load step masked it for several iterations.

This is a separate ioctl-routing bug; not blocking, since `mbc` works.

## Auxiliary instrumentation in the same commit

* `dbg_max_pc_r` — monotonic max-PC at `PBR=$00` latched in
  `fpga64_sid_iec.vhd:413`/`:1456-1469`, exposed through
  `dbg_irq_nmi_count` → UART **W:** field. Reading W>$01FF means
  SCPU code escaped the dispatcher page; W≥$CB00 means decomp
  reached game entry. Useful for any future "decompressor stuck"
  symptom — a single UART line tells you whether the loop is dense
  or actually trapped.
* `DBG_X / DBG_Y / DBG_D` ports plumbed P65C816 → cpu_65c816 (not
  yet routed to UART; reserved for the next probe).
* `bug_frozen_direct` input on `debug_uart_fmt` (v131 direct
  ring-buffer diagnostic — unchanged from prior session, just
  carried in this commit).

## Known timing posture

Worst-case clk32 setup slack on this build is **-4.4 ns** (TNS small);
hold OK; clk64/clk128 OK. Marginal, same posture as the v155 baseline
that's been running for weeks. Functions reliably in practice (PVT
margin) but is the next sensible target if a stability regression
surfaces.

## Open items (not blocking)

* MGL pipe `<file>` PRG ioctl wiring — does not auto-load asterix.prg
  in the current build. mbc load_rom works as a workaround.
* Doom in SuperRAM still needs the Covert Bitops V2.26 loader port
  (separate, pre-existing — `project_doom_needs_full_loader.md`).
* Pending tasks #6 (WriteSmart + write buffer drain), #11 (split
  `status[82]` from `scpu_rom_opt`), #12 (SDRAM upper-half write
  drop) are unrelated to Asterix.

## How to reproduce the fix

```powershell
.\build_c64.ps1                                     # 17–25 min Quartus
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf
python tools/mister_debug.py load_prg .\asterix.prg
python tools/mister_debug.py screen asterix.png     # title should render
```
