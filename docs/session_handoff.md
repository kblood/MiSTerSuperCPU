# Session handoff — 2026-05-26 (overnight): v347 Phase 2 shipped, Phase 3 building

## 0. TL;DR

- **Phase 2 (committed `b95b4fe`)**: BASIC READY via SCPU EPROM kickstart. Done.
- **Banner work**: Build #3 (md5 `c5052bb0`, buslogic shadow extension) BROKE boot. Reverted. Root cause: even with correct ROM shadow, the patched KERNAL/BASIC need the CMD library handlers at `$00:$801A-$8054` which our SIMM-detect bypass never installs. **Blocked on Phase 3.**
- **Lorenz autoload "regression"**: NOT a regression — it's the documented mb-probe-003 stochastic MCP+LOAD wedge inherited by v347. Disk mounts fine, BASIC reaches "SEARCHING FOR *", then IEC transfer wedges (same `irq_n`-stuck path).
- **Doom regression under v347**: NEW — Doom stuck at green init screen for full 8-min smoke test. UART end-state PC at `$00:$0003` (BRK runaway, bank-N last fetch was `$54:$0000` inside Doom SuperRAM, so Doom DID start then crashed). Hypothesis: v347's `scpu_bootmap='1' at reset` triggers kickstart MVN to `$01:$6000-$7FFF` which lands at `$00:$6000-$7FFF` via `bank01_mirror_to_00`, polluting bank-$00 main RAM. Last validated Doom run was May 21 (pre-milestone-b CDC).
- **Phase 3 source**: Codex Fourth Option SIMM-alias mode staged in working tree. Full design: `docs/phase3_codex_fourth_option_design.md`. Build `bu0q5fv04` running (~12 min ETA).

## 1. Where things stand now

- MiSTer at `/media/fat/_Test/C64.rbf` = v347 Phase 2 (md5 `cfcbf617`), idle at READY.
- Working tree DIRTY with Phase 3 source changes (see §3 below). Build running.
- All v347 Phase 2 changes still committed at `b95b4fe`.

## 2. Validation results

### 2.1 Phase 2 boot — PASS

- `tools/v347_restored.png`: clean READY after redeploy. Confirms Phase 2 silicon-stable.

### 2.2 Banner shadow (Build #3, md5 `c5052bb0`) — FAIL

- Extended `fpga64_buslogic.vhd:386` to fire `dataToCpu <= ramData` for `cs_romLoc/cs_CharLoc/cs_romHLoc/cs_romLLoc` when `(scpu_native_mode='1' OR scpu_bootmap='0')`. Idea: after kickstart MVN'd patched KERNAL/BASIC into bank-$00 via bank01_mirror_to_00, expose them via ROM-shadow reads.
- Result: screen filled with `@` chars. KERNAL never cleared screen RAM. Most likely the patched KERNAL ran but jumped to a missing CMD library handler at `$00:$801A` (which contains $00 = BRK in our build).
- Reverted via `git checkout`. Source clean wrt buslogic.

### 2.3 Lorenz autoload — wedges at SEARCHING FOR *

- Manual `LOAD"*",8,1`: BASIC reaches "SEARCHING FOR *" then stalls. Disk drive 8 IS mounted (no DEVICE NOT PRESENT). IEC transfer hangs per `[[mb-probe-003-irq-n-stuck-confirmed-2026-05-26]]` mechanism.
- MGL `<file type="s">` mount works. MGL `<file type="f">` PRG inject works. RUN gets typed. The hang is in the IEC stack inside the wedged stock KERNAL.

### 2.4 Doom v347 smoke — FAIL (8-min stuck-green)

- `tools/doom_v342_test.py` ran cleanly: REU upload, loader.prg inject, loader RUN (60s, back to READY), launcher POKE+SYS49152.
- Screen went black then green within 1s. Stayed green for entire 485s capture window.
- UART final-state: `PC:000003 P:44 V:00 00 44 88 SP:FA3F WP:000003 ... N:540000 B:00`
- Interpretation: native-mode native-stack (SP > $01FF), DBR=$00, last bank-N read was `$54:$0000` (Doom SuperRAM), PC stuck at `$00:$0003`. Classic BRK / vector-indirect runaway after Doom started, hit an exception, and bounced through a corrupted vector.
- See task #8 description for full hypothesis (bank-$00 RAM pollution by kickstart MVN via bank01_mirror_to_00).

## 3. Phase 3 source changes (uncommitted, in this build)

### 3.1 `C64_MiSTer/rtl/fpga64_sid_iec.vhd`

1. Entity port additions (lines ~737-740):
   - NEW: `scpu_bootmap_o : out std_logic`
2. Architecture assignment (next to `scpu_fast_path_o`):
   - NEW: `scpu_bootmap_o <= scpu_bootmap;`
3. Bypass clause narrowed (lines 2298-2300):
   - WAS: `x"6B" when ... cpuAddr = x"8147" or cpuAddr = x"8148"`
   - NOW: `x"6B" when ... cpuAddr = x"8147"`  ← removed $8148 case
   - Effect: kickstart's JSL $F88148 now reaches the real SIMM-detect scan. $8147 RTL still synthesised because XCE-then-RTL puts the fetch in emu mode with bootmap=0, neither carve-out serves EPROM there.

### 3.2 `C64_MiSTer/c64.sv`

1. Port instantiation (around line 2346):
   - NEW: `.scpu_bootmap_o(scpu_bootmap_w)`
2. `simm_detect_active` always-block + bank remap (around line 1117):
   ```verilog
   wire scpu_bootmap_w;
   reg  simm_detect_active = 1'b0;
   reg  scpu_bootmap_prev  = 1'b1;
   always @(posedge clk_sys) begin
       if (reset_n == 1'b0) begin
           simm_detect_active <= 1'b0;
           scpu_bootmap_prev  <= 1'b1;
       end else begin
           scpu_bootmap_prev <= scpu_bootmap_w;
           if (scpu_bootmap_prev && !scpu_bootmap_w)
               simm_detect_active <= 1'b1;
           else if (simm_detect_active && cpu_has_bus
                    && (supercpu_bank == 8'h00) && supercpu_emul)
               simm_detect_active <= 1'b0;
       end
   end
   wire [7:0] simm_remap_bank =
       (simm_detect_active && (supercpu_bank == 8'hF6)) ? 8'h02 :
       (simm_detect_active && (supercpu_bank == 8'hF7)) ? 8'h03 :
       supercpu_bank;
   ```
3. `scpu_sdram_addr` concat at line 1115 uses `simm_remap_bank` in place of `supercpu_bank`.

### 3.3 `docs/phase3_codex_fourth_option_design.md` (NEW)

Full design rationale, RTL listings, validation strategy, risk list.

## 4. Next steps after Phase 3 build lands

### 4.1 If Phase 3 boots to READY

1. **Banner check** — capture screenshot, look for `**** C=64 SCPU64 ROM V0.07 ****` (or similar patched string) instead of stock `**** COMMODORE 64 BASIC V2 ****`. If yes → CMD library install worked, kickstart natural flow restored.
2. **CMD lib bytes** — dump $00:$801A-$8054 via the existing `tools/test_cart/gen_dump_vectors.py` PRG. Expect non-zero bytes if SIMM scan completed.
3. **Doom smoke re-run** — same `doom_v342_test.py`. If Phase 3 installs proper IRQ vectors, BRK-runaway should disappear.
4. **MCP+LOAD probe** — manual `LOAD"*",8,1`. If CMD IEC throttle restored, LOAD should complete.

### 4.2 If Phase 3 wedges in kickstart

UART signature to watch:
- PC stuck inside `$F8:$81A9-$81D5` → alias remap not working
- PC stuck in `$F8:$8112-$813A` → SIMM scan returned but post-scan crashed
- PC stuck in `$00:$801A-$8054` → kickstart handed off, but CMD lib code crashed

In any of these cases the kickstart got further than Phase 2 (which never reached the scan). Document the new failure mode and either:
- Add target-specific bypasses (narrow synthetic stores)
- Pin down what kickstart wants from `$D2xx` registers that we're not providing

### 4.3 Doom regression (separate track)

Independent of Phase 3 result, the Doom failure should be confirmed against a known-good build. Quickest: deploy `C64_milestone-b-cdc-rewrite_b6a02076e9_20260525T163655Z_ef01bea6-dirty.rbf` (mb-probe-003 baseline) and re-run `doom_v342_test.py`. If Doom also wedges there, the regression predates v347 and Phase 3 isn't to blame. If Doom passes on mb-probe-003, v347 is the culprit and the `bootmap='1'` + bank01_mirror_to_00 polluting bank-$00 RAM is the most likely vector.

## 5. References

- `docs/phase3_codex_fourth_option_design.md` — Phase 3 design
- `tools/v346_boot_trace/codex_v346_falsification.txt` — Codex's ranked falsification + Fourth Option proposal
- `memory/project_v347_phase2_shipped.md` — Phase 2 record
- `memory/project_v346_phase1_3bug_stack.md` — three-bug stack analysis
- `memory/project_mb_probe_003_irq_n_stuck_confirmed.md` — MCP+LOAD wedge mechanism
- `tools/scpu64.bin` — raw EPROM image (64KB, contains patched KERNAL/BASIC + kickstart)
- `tools/disasm_kickstart.py` — kickstart disassembler
- `tools/v347_restored.png` — Phase 2 boot evidence
- `tools/doom_full/v342_t485s.png` — green-screen Doom failure
- `tools/doom_full/v342_uart.txt` — 240s capture showing PC stuck at $00:$0003
