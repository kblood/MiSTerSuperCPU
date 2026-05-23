# Session handoff — 2026-05-23 (CRT auto-boot wrapper + long-opcode unblocking)

## TL;DR
1. **CRT auto-boot wrapper landed** (`tools/test_cart/prg_to_crt.py` +
   `load_crt.py`, commit 4173954). Wraps any standard PRG as 8K CBM80
   cart, deploys via MGL + `load_core`. Eliminates mtype `SYS 2061`
   dependency for one-shot benches. Verified end-to-end with
   `min_loader.crt` rendering "MIN LOADER OK".
2. **Long-mode opcodes ARE NOT broken** (commit d693ca3). Earlier
   "every variant crashes" finding was wrong. All 7 single-op variants
   (emu/native, $00xxxx ZP / $00xxxx RAM / $200080 SuperRAM,
   STA al / LDA al) execute correctly from cart-boot. Memory entry
   `project_sta_al_lda_al_crash.md` updated to supersede.
3. **Step 7b alt_fire_r2 RTL** (commit 09655d8, RBF md5 `108dd072`)
   stays deployed. Bank-0 4 MHz cap confirmed pre/post. SuperRAM
   throughput **now bench-able** thanks to the CRT path + working
   long-mode ops.
4. **One remaining bug class**: native-mode `STA al $200080` +
   marker writes + `LDA al $200080` + `STA $040C` (round-trip with
   readback into screen) causes chaotic vertical-stripe screen
   corruption. PHK/PLB to set DBR does NOT fix it (changes the
   corruption pattern). Root cause TBD; NOT a blocker for Step 7b
   bench design (just structure the bench as "write sweep then
   separate read sweep" rather than interleaved).

## What changed in this session
- `tools/test_cart/prg_to_crt.py` — new. Bootstrap inits
  `$01=$37`, `$D011=$1B`, `$D018=$14` (cart-boot bypasses KERNAL VIC
  init), copies payload from cart ROM $8100 to load_addr via
  self-mod page-loop, JMPs to `load_addr + entry_offset` (default
  12 = skip BASIC SYS stub).
- `tools/test_cart/load_crt.py` — new. SCP + MGL `<file
  type="f" index="1">` + `load_core`. `mbc load_rom` does NOT work
  for .crt — no `C64.CRT` alias.
- `tools/test_cart/gen_cart_smoke.py` — new. 18-byte raw-cart sanity
  test that runs straight from $8009 without any copy bootstrap. Use
  this first when CRT auto-boot isn't taking effect.
- `tools/test_cart/gen_stalong_probe.py` — new. 9 PRG variants for
  bisecting long-mode opcode behaviour. All single-op variants pass.
- `.claude/skills/mtype/SKILL.md` — extended with `prg_to_crt.py`
  section. Documents "wrap as CRT to skip mtype" as the preferred
  path for one-shot benches.

## Step 7b status (unchanged from prior session)
- RTL alt_fire_r2 term in `fpga64_sid_iec.vhd` gated on
  `scpu_fast_path AND cs_ram AND sdram_busy_cnt <= 1` for CPU2/6/A/E
  slots. Bank-0 unaffected.
- RBF: `output_files/C64.rbf` md5 `108dd072`. Deployed at
  `/media/fat/_Test/C64.rbf`.
- Bank-0 bench (`cpu_bound_bench.prg`): off=$0451, smart4x=$044B,
  full4x=$115A → 4.02× scaling. **Empirically capped at 4 MHz.**
- SuperRAM bench: NOT YET RUN. The next sensible step is a bench
  that writes 1KB sweep into bank-$20 SuperRAM via STA al loop,
  then times a separate read-back sweep via LDA al loop, displayed
  via screen counters. Wrap as CRT to avoid SYS-launch issues.

## Path to 10x — current state and concrete next steps

Current ceiling = 4 MHz (bank 0 confirmed). Target = 20 MHz (5×) or
interim 10 MHz (2.5×). Three paths, in increasing effort order:

### (A) Validate Step 7b SuperRAM gain first (~1 hour)
Build cpu_bound_bench analogue that runs entirely from bank-$20
via STA al pre-fill + LDA al timed loop. Wrap as CRT, run, compare
COUNT vs bank-0 baseline. Expected gain = +25% (4 MHz → 5 MHz on
SuperRAM accesses only). Validates the Step 7b RTL on real
SuperRAM workload before deciding whether to commit it or revert.

### (B) Phase F MCP rewrite (multi-day)
`docs/async_bridge_mcp_handshake_plan.md` (commit e1147a6). Goal:
clk_cpu=64 MHz with proper toggle-FF request/ack handshake.
Theoretical ceiling 8 MHz. F.0 confirmation already done (Appendix
A added 2026-05-21). F.1 is the bridge entity rewrite at clk_cpu=
clk_sys with MCP toggle handshake.

### (C) EXT slot reclaim (~1-2 days)
Per CLAUDE.md the sysCycleDef has EXT(8) + DMA(4) + VIC(4) +
CPU(16) = 32 slots. Reclaiming all 8 EXT slots for CPU → 16+8 = 24
CPU slots → +50% beyond current 4 MHz = 6 MHz. Simple RTL change.

## Outstanding long-mode round-trip corruption

The bench that DID corrupt the screen:
```asm
SEI; CLD; TXS  (in base)
clear screen + color RAM
A marker (white)
CLC; XCE; SEP #$30      ; native mode, 8-bit A/X/Y
LDA #$5A
STA al $200080          ; write to SuperRAM
B marker (green)        ; 4 STA $0404..$0407, 4 STA $D804..$D807
LDA #$00
LDA al $200080          ; read back from SuperRAM
STA $040C               ; write readback as char to screen pos 12
LDA #$07; STA $D80C     ; color readback yellow
D marker (orange) at pos 13
halt
```

Adding `PHK; PLB` after XCE to set DBR=$00 did NOT fix it (different
corruption pattern though — pattern changed from green/violet stripes
to "BVD" chars repeating).

Hypotheses (in priority order):
1. **NMI fires from CIA2 stale state** — cart-boot doesn't init CIA2
   ICR/timers. If any prior session left CIA2 Timer A latched with
   ICR enabling NMI, the NMI vector at $FFEA (KERNAL JMP $0318)
   jumps to uninitialized $0318 → garbage. But CIA2 ICR resets to
   $00 on hardware reset, so this needs verification.
2. **Bus-mux race on supercpu_bank** during the LDA al following
   the STA al — the bank byte change from $20 (during STA write
   cycle) back to $00 (during subsequent fetch) may have a 1-cycle
   window where supercpu_bank lingers and corrupts a fetch.
3. **DBR not actually $00** when STA $040C executes despite PHK/PLB
   — but the changed corruption pattern suggests PHK/PLB IS doing
   something.

Next probes (if pursuing this bug):
- Mask NMI explicitly: write $7F to $DD0D (CIA2 ICR) at start of
  bench. If corruption stops, NMI hypothesis confirmed.
- Use a non-screen target for the readback (e.g., a ZP byte) and
  display its value via a separate screen-write sequence done with
  REGULAR STA abs (not following long-mode). Bisects whether the
  corruption is from the STA $040C following LDA al, or from the
  LDA al itself returning corrupt data.
- Try writing/reading from $20:$0500 instead of $20:$0080 (non-ZP
  target). Rules out a SuperRAM-side ZP shadow path.

## Suggested order of business next session
1. **Build SuperRAM cpu_bound_bench analogue** (option A above) and
   measure Step 7b vs OSD-turbo-off baseline. Decide whether to
   commit Step 7b on the master branch or revert.
2. If Step 7b shows the expected ~+25% gain, move to **option C**
   (EXT slot reclaim) for an immediate +50% on top of that. Combined
   path to ~7.5 MHz with mostly mechanical RTL.
3. Phase F MCP is still the canonical multi-day path to 8 MHz.
   Tackle after A+C exhaust the easy gains.

## State on disk
- Branch: `milestone-a-build-c-revival` (NOT `async-cpu-bridge` —
  current branch differs from session-start git status; check
  `git branch --show-current`).
- Working tree changes: rebuild artefacts in `tools/test_cart/out/`
  (gitignored), screenshots ditto.
- Recent commits this session:
  - `d693ca3` STA al/LDA al cart-boot probe + corrected findings
  - `4173954` CRT auto-boot wrapper tooling
  - `0e8ae0a` bench bisect harness + SuperRAM bench generator
    (carry-over from prior session)
  - `09655d8` Step 7b alt_fire_r2 + mister_debug.py wrapper fix
    (carry-over)

## Pointer to existing plans
- `docs/async_bridge_mcp_handshake_plan.md` — Phase F.0–F.5 (F.0
  Appendix A added; F.1 next when revived).
- `docs/supercpu_feature_status.md` — feature-completion checklist.
- `.claude/skills/mtype/SKILL.md` — keyboard injection + CRT
  auto-boot reference.
