# Session Passover 2026-04-14: Doom REP Bug Isolated to SuperRAM Read Path

## Headline

**Triangulation complete.** Three tests now pinpoint the Doom crash bug to the
SuperRAM read pipeline specifically — NOT the CPU core, NOT general EN-gating,
NOT bank $00 BRAM fetch. Bonus: discovered a second, cleaner repro where
`LDA long $bbaaaa` from bank $00 to any SuperRAM bank returns $00 for all
bytes, which is likely the same root cause.

## 1. The Three Tests That Isolate the Bug

### Test 1 — GHDL bare-core bench (2026-04-13, PASS)
`sim/p65c816_tb/p65c816_rep_tb.vhd` runs Doom's prologue against the bare
`P65C816` entity with a flat 64KB memory model:

```
$0800 18        CLC
$0801 FB        XCE         → native
$0802 C2 30     REP #$30    clear M and X
$0804 A9 EA EA  LDA #$EAEA  16-bit immediate
$0807 80 FE     BRA $0807   spin
```

Cycle-by-cycle trace around the REP retirement:

```
cyc=20 ST=1 IR=$C2 PC=$0803 P=$35  REP just fetched
cyc=21 ST=2 IR=$C2 PC=$0804 P=$35  REP imm fetch (DR<=$30)
cyc=22 ST=0 IR=$C2 PC=$0804 P=$05  Flags cycle — M and X cleared
cyc=23 ST=1 IR=$A9 PC=$0805 P=$05  LDA fetched
```

**Result: PASS.** The bare CPU correctly computes `$35 AND NOT($30) = $05`.
Rules out the REP microcode, DR latch ordering, LOAD_P timing, and any
internal P65C816 race.

### Test 2 — Hardware BRAM regression (2026-04-14, PASS)
`tools/test_rep_bram.py` (+ `gen_test_rep_bram.py` + `test_rep_bram.prg`) runs
the same native-mode prologue from `$C000` in motherboard RAM / BRAM:

```
$080D 78         SEI
$080E 18         CLC
$080F FB         XCE         → native
$0810 E2 30      SEP #$30    force M=X=1 (work around XCE native M/X force bug)
$0812 A9 00      LDA #$00    (emu 8-bit)
$0814 8D 3C 03   STA $033C   pre-clear result lo
$0817 8D 3D 03   STA $033D   pre-clear result hi
$081A C2 30      REP #$30    ← instruction under test
$081C A9 BB AA   LDA #$AABB  16-bit immediate if M=0
$081F 8D 3C 03   STA $033C   16-bit store if M=0
$0822 E2 30      SEP #$30
$0824 FB         XCE
$0825 58         CLI
$0826 60         RTS
```

Discrimination: PASS = 187/170 at $033C/$033D; FAIL = 187/0.

**Result: PASS (187 170).** Rules out bank $00 BRAM fetch path, general
EN-gating, XCE interaction, and the 2-stage bank-$00 pipeline. Also confirms
that with the SEP #$30 XCE-bug workaround, REP correctly clears M from a
known-$34 starting state.

Key wrangling: $0500 was a bad choice (screen RAM row 8 — gets overwritten
by BASIC scroll). Moved to $033C (cassette buffer, free). `mbc load_rom`
corrupts the BASIC auto-run so the `.prg` path via `SYS 2061` didn't work;
the reliable path is `mtype` a BASIC `DATA/POKE/SYS` loader and `RUN`.

### Test 3 — Hardware Doom (pre-existing, FAIL)
Doom from bank $20 with launcher `SEI; CLC; XCE; JML $20:0000` — REP at
$20:$0004 clears X but leaves M=1 (verified via 128-entry crash trace ring
buffer with BRK-in-game-bank trigger). The CPU then fetches the LDA #$0000
low byte as a 2-byte instruction, lands on the `$00` high byte as a BRK in
native mode, and enters the BRK loop seen in memory.

## 2. Bonus Finding — LDA Long Cross-Bank Also Broken

While trying to peek `$20:$0005` to verify its SDRAM content, I built
`tools/peek_superram_scan.py` which reads one byte from each of banks $01,
$02, $10, $20, $20:$0005, $40, $80, $F0 via:

```
SEP #$30                   ; M=X=1 (8-bit)
LDA long $bbaaaa           ; AF aaaa bb
STA $033C+i
```

**All SuperRAM banks ($01-$80) return $00.** Bank $F0 returns $FF (the ROM
stub), and a sanity read of `LDA long $00:$FFFC` correctly returns $E2
(reset vector low). Meanwhile Doom successfully fetches code from $20:$0000
onwards (instruction fetch from SuperRAM *works*), and the `SYS 49152 → JML
$20:$0000` launcher runs the prologue all the way to the REP instruction
(UART shows `K:20 B:20 E:0` with trace ring capturing bank $20 execution).

**So SDRAM is populated**, yet LDA long cross-bank data reads from bank $00
code all return 0. This isolates a second bug in the same area:

- Instruction fetch from bank $20 — WORKS (Doom runs)
- LDA long $bbaaaa from bank $00 (fetch-bank=$00, data-bank=$bb) — BROKEN (returns 0)
- REP operand fetch from bank $20 when executing bank $20 code — PARTIALLY BROKEN (returns $10 instead of $30, only bit 5 dropped)

Common thread: every failing case is a memory read that goes through the
3-stage SuperRAM pipeline + `sdram_superram`/`dout_reu_r` latch. The LDA
long case is full-byte corruption ($30→$00), the REP case is bit-level
corruption ($30→$10). Likely mechanism candidates:

1. `superram_in_pipeline` / `cache_cpu_bank` latches the wrong bank byte
   when the fetch-bank and data-bank differ within a single instruction.
2. `bt` select race in `sdram.v:166` (`bt <= addr[24]`) — captured at
   `ce && !last_ce` but the SDRAM 16-bit word contains TWO byte addresses
   and the wrong one is selected under some timing conditions.
3. `dout_reu_r` latch at `sdram.v:142` — only updated at `STATE_READ` when
   `bt && !wr`. If a previous write with `bt=0` invalidates the latch and
   no subsequent `bt=1` read has re-filled it, `sdram_superram` returns
   stale / zero data.
4. SDRAM CAS latency timing vs 3-stage pipeline capture at `superram_enable_delay`.

## 3. Testing Infrastructure Added (committed as 404f75d)

- `tools/gen_test_rep_bram.py` — builds `tools/test_rep_bram.prg` (38 bytes,
  BASIC stub + SYS 2061 + ML)
- `tools/test_rep_bram.prg` — binary, checked in for reproducibility
- `tools/test_rep_bram.py` — wrapper: deploys, types BASIC DATA+POKE+RUN
  loader, screenshots, reports PASS/FAIL criteria
- `tools/peek_bank20_prologue.py` — reads `$20:$0000..$0007` via LDA long
  + sanity read + signature write (all returned 0 on hardware)
- `tools/peek_superram_scan.py` — multi-bank LDA long probe (discovered
  the zero-return pattern)

## 4. Gotchas and Wrong Turns

1. **$0500 is screen RAM.** My first BRAM test stored `$BB, $AA` to
   `$0500, $0501` which got overwritten by BASIC's `READY.` scroll,
   masquerading as an M-stuck failure. Moved targets to `$033C/$033D`
   (cassette buffer, free).

2. **`mbc load_rom` corrupts the BASIC auto-run.** A `.prg` with a BASIC
   stub that does `10 SYS 2061` won't auto-RUN after mbc injection —
   the BASIC pointers aren't set up correctly. SYS 2061 directly from
   a typed BASIC prompt works, but only if the ML code wasn't wiped by
   the inject. The reliable path is to `mtype` a BASIC program that
   `POKE`s the ML bytes from `DATA` lines, then `SYS`.

3. **XCE native M/X force bug still present.** Entering native mode via
   XCE in our core does not force M=X=1 per spec (see
   `project_xce_native_mx_bug.md`). Any BRAM test for REP must start
   with `SEP #$30` after XCE to establish a known state — otherwise
   the very first 8-bit store gets interpreted as 16-bit and corrupts
   the test setup.

4. **Em-dash `—` breaks GHDL report strings.** The GHDL lexer rejects
   non-ASCII characters in report literals. Replaced all `—` with `--`.

5. **MiSTer at 192.168.50.130 went offline** mid-session — the Doom
   BRK-loop from a failed test run apparently locked up more than just
   the C64 (possibly the MiSTer Main), needing a physical power cycle.

## 5. Memory Updates

- `memory/project_doom_rep_m_flag_bug.md` — header renamed from
  "system-level" to "SuperRAM read path"; added 2026-04-14 triangulation
  section; added LDA long cross-bank finding.
- `memory/MEMORY.md` Doom Status block — updated from
  "2026-04-13 symptom isolated" to "2026-04-14 bug isolated to SuperRAM
  read path"; updated next-step list.

## 6. Open Questions / Next Steps

Priority order for the next session:

1. **Drive a GHDL bench against `cpu_65c816.vhd` (the wrapper) with a
   mocked SDRAM that returns distinct patterns per bank** and run
   `LDA long $200000` — does the wrapper ever put $20 on `addr_hi` for
   the data-read cycle? If not, the bug is in how we derive `addr_hi`;
   if yes, the bug is downstream in the pipeline/mux.

2. **Instrument `superram_in_pipeline` / `cache_cpu_bank` via UART** —
   sample their values at the exact cycle `LDA long` does its data
   read, then again at the REP operand-fetch cycle. If `cache_cpu_bank`
   is $00 instead of $20 at the data-read cycle, we've found the race.

3. **Check the `bt` select path in `sdram.v` for cross-clock-domain
   races.** `bt` is latched at `ce && !last_ce` in clk domain; if a
   previous write with `bt=0` is still in the SDRAM command queue when
   a new read with `bt=1` arrives, `bt` might flip too late and the
   wrong half of the 16-bit word gets returned.

4. **Add a `DBG_` port that exposes the raw SDRAM response byte and
   `addr_hi_816` at `enableCpu` time** so we can see exactly what the
   CPU receives vs what's on the SDRAM bus.

## 7. Commit History (this session)

- `f5d24d7` — Add BRK-in-game-bank trigger + GHDL REP testbench (from
  previous session, verified ready at start)
- `404f75d` — Add SuperRAM read-path regression tools
  (`test_rep_bram.{py,prg}` + `gen_test_rep_bram.py` +
  `peek_bank20_prologue.py` + `peek_superram_scan.py`)
