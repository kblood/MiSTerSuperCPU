# Session handoff — 2026-05-23 end-of-session (REVISED)

## TL;DR — bank-$20 wedge root cause found

1. **Bisect bank-$20 wedge — ROOT CAUSE PINNED** (commit `2407264`).
   `LDA al $200080` (or any long load from bank ≥ $20) immediately
   followed by any memory store (`STA zp/abs/al`, `JMP self`, even a
   back-to-back `LDA al`) wedges the CPU. **A single 2-cycle pad
   (`NOP`, `LDA #imm`, `AND #imm`, `LDY #imm`) between the long load
   and the next op restores correctness.** Always-on: triggers on the
   very first LDA al from a totally fresh cart-boot, with no prior
   SuperRAM state required. This is a real HW pipeline hazard,
   reproducible in 1 PRG + 1 CRT wrap.

2. **Verified workaround**: `tools/test_cart/copyback_fixed_nopped.crt`
   renders `♦5A` at row 0 col 24-27 (raw $5A screen-code + hex "5A")
   plus all GGGG markers. SuperRAM round-trip is functional with NOP
   padding.

3. **Earlier bootstrap fix STILL VALID** (commit `b869136`). The
   prg_to_crt ZP-indirect bootstrap is unrelated to this hazard. CRT
   auto-boot stays production-grade for ≤ 7.9KB PRGs.

4. **Long-mode single ops STILL VALID** (commit `d693ca3`). `STA al`,
   `LDA al` single ops execute correctly. The bench wedge wasn't about
   the instructions themselves — it was about ordering.

5. **Step 7b alt_fire_r2 RTL stays deployed** (commit `09655d8`,
   RBF md5 `108dd072`). Validation against SuperRAM workload now
   blocked only by point 6.

6. **NEXT BLOCKER**: re-validate `superram_bench.crt` with the NOP
   workaround applied to the bank-$20 payload. Existing payload LDA
   al's at CIA1_ICR have `AND #imm` after them (implicit pad → safe),
   so the wedge probably isn't there. But `call_disp`'s `STA [$FB],Y`
   path and the `LDA abs B20_TMP` reads in `display_byte` need
   inspection — DBR=$20 makes those effectively long loads, and they
   may be the hazard site.

## What changed this session

### Toolchain
- `gen_copyback_bisect.py` — 7-variant ladder v0..v6 progressively
  adding copyback features to known-good `build_emu_sta_superram`
  baseline. Pinpoints the wedge to v4's hex display block.
- `gen_copyback_drill.py` — 6-variant drill inside v4's hex block.
  Pinpoints to (LDA al + STA $02) = the minimum repro.
- `gen_copyback_drill2.py` — 7-variant deeper drill. Shows (3rd LDA al
  + STA $02) wedges but (STA $02 alone, no LDA al) renders. Also
  (LDA #$5A + STA $02) renders → confirms SuperRAM read is the cause.
- `gen_copyback_drill3.py` — NOP-pad sweep (0..6 NOPs) + JMP/STA al
  variants. **1 NOP is sufficient.** Also confirms LDA-al-then-JMP-self
  wedges; LDA-al-then-STA-al-bank20 wedges; LDA-imm-then-STA-zp works.
- `gen_copyback_fresh.py` — confirms hazard from totally fresh state
  with no prior SuperRAM ops. (1 LDA al + STA $02 from base() wedges.)
- `gen_copyback_fixed.py` — full readback with NOP-after-LDA-al.
  Renders `♦5A` + GGGG.
- `run_copyback_bisect.py` — parametric multi-variant deploy + screenshot.
  Set `$env:BISECT_MODULE='gen_X'` to run a specific generator's
  variants. PowerShell required (Bash env-var syntax not supported).

### Commits this session
- `2407264` test_cart: bisect pins LDA-al → STA hazard (1 NOP fixes)
- `0903443` docs: end-of-session handoff — full state rewrite (prior)
- `3ae8868` test_cart: copyback probe — wedges even at single STA al
- `b869136` fix(prg_to_crt): bootstrap copy uses ZP-indirect (THE FIX)

## Hazard characterization (verified on RBF md5 108dd072)

Pattern that **WORKS** (1 NOP / imm pad between long load and store):
```
LDA al $200080
NOP           ; or LDA #imm, AND #imm, LDX #imm, LDY #imm
STA $02       ; or STA $0400, STA al $208001, JMP self, LDA al
```

Pattern that **WEDGES** (no pad):
```
LDA al $200080
STA $02       ; CPU freezes here, no marker after this appears
```

Bench code with `AND #imm` after `LDA al CIA1_ICR` is **already safe**
(implicit pad). New code must explicitly insert NOPs.

## Where Step 7b stands

- RTL alt_fire_r2 term in `fpga64_sid_iec.vhd` gated on
  `scpu_fast_path AND cs_ram AND sdram_busy_cnt <= 1` for CPU2/6/A/E
  slots. **Almost certainly the source of the hazard** — likely allows
  a follow-up bus cycle (CPU3/7/B/F slot?) to fire while a SuperRAM
  read is still in its 3-stage pipeline (`superram_enable_delay`).
- RBF: `output_files/C64.rbf` md5 `108dd072`. Deployed at
  `/media/fat/_Test/C64.rbf`.
- Bank-0 bench (`cpu_bound_bench.prg`): off=$0451, smart4x=$044B,
  full4x=$115A → 4.02× scaling. **Empirically capped at 4 MHz.**
- SuperRAM bench: re-validation pending. Either (a) apply NOP fix
  in payload's LDA-abs-after-DBR=$20 paths, OR (b) fix RTL.

## Suggested order of business next session

1. **Apply NOP workaround to `superram_bench` payload**, esp. the
   `call_disp` chain in `gen_superram_bench.py`. Verify COUNT/PASS
   update on-screen.
2. **Capture Step 7b ratio** with alt_fire_r2 ON vs OFF (need a
   second RBF with alt_fire_r2 gated to '0' — ~30 min Quartus). If
   ratio ≥ +20%, commit Step 7b to `master`. If <+10%, revert.
3. **OR investigate RTL fix**: gate `alt_fire_r2` with one extra
   `sdram_busy_cnt` tick after a SuperRAM read (so the follow-up CPU
   slot waits for the read to finish propagating). This would make
   the bench correct without NOP padding and would not regress
   alt-fire's win on pure write streams.
4. **Apply the NOP convention to `gen_stalong_probe.py`**'s
   multi-op SuperRAM probes that previously "corrupted" — they
   probably wedge for the same reason.
5. **Move to Milestone B** per `docs/path_to_20mhz_plan.md`.

## Pointers

- `docs/path_to_20mhz_plan.md` — CANONICAL Milestones A/B/C.
- `tools/test_cart/copyback_fixed_nopped.crt` — verified workaround
  reference. md5 of screenshot: `24f73907`.
- Memory entries:
  - `project_lda_al_sta_hazard_2026_05_23.md` (NEW — root cause)
  - `project_superram_bench_wedge_2026_05_23.md` (prior — now superseded)
  - `project_sta_al_lda_al_crash.md` (long-mode opcode validation)

## How to resume on a fresh shell

```powershell
cd C:\LLM\C64\MiSTerSuperCPU
git log --oneline -5            # confirm commit 2407264 visible
# Resume on the bench fix:
code tools/test_cart/gen_superram_bench.py     # add NOPs after LDA al / LDA abs (DBR=$20)
# Or jump to RTL investigation:
code C64_MiSTer/rtl/fpga64_sid_iec.vhd         # search for alt_fire_r2
```

MiSTer IP `192.168.50.130`, root/1. Current RBF md5 `108dd072` at
`/media/fat/_Test/C64.rbf`. Don't touch `/media/fat/_Computer/` —
vanilla rbfs only.
