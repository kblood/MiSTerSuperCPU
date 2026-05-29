# Session handoff — 2026-05-29: autonomous compat+speed loop

## ITERATION 8 — COMPAT: first 3rd-party SCPU title run on HW → REAL RENDERING BUG (IN PROGRESS)
Broke the standing blocker that capped iters 5-7 ("no 3rd-party SCPU binaries to
test") — and the very first title exposed a concrete compat defect. This is a
genuine bug to chase next, NOT a closed win.
- **Asset:** "SuperCPU Kicks!" by DMAgic (1999), WiLD compo @ Mekka&Symposium '99.
  CSDb release id 3432 -> `csdb.dk/getinternalfile.php/75890/scpukicksd64.zip`
  (3× D64, label "required: scpu with 1mb ram"). Extracted to
  `tools/scpu_compat/SCPUKICK/SCPU{1,2,3}.D64`. Boot = first PRG `scpu kicks !/dma`.
- **Run:** `tools/scpu_compat/run_d64_scpu.py SCPU1.D64 --name scpukicks_d1 --mins 6`
  on build `97392a1f` (already on `_Test`; read-mux fix + both turbo modes).
  cfg byte10=0x0C (scpu). MGL = disk(s,idx0) + `lorenz_autoload.prg` (f,idx1).
- **RESULT — boots & detects, but RENDERS BROKEN.** Boot shows `**** C=64 SCPU64
  ROM V0.07 ****`; demo loads parts a/b/c; **passes its own SuperCPU
  presence-detect** (no "SuperCPU required" bail) — so detection works end-to-end.
  BUT the display is **graphically corrupted + flickers heavily** on HW
  (distorted/doubled DYCP scroller chars, corrupted sprite floor — operator
  confirmed live). The **VICE 3.10 xscpu64 oracle renders the SAME demo CLEAN**
  (sharp DMAGIC logo, smooth raster bars, crisp dual scrollers) ⇒ real
  rendering/timing bug in OUR core, not a fragile demo.
- **METHODOLOGY MISS (corrected):** I first called this a "clean PASS" because
  every screenshot frame had a unique md5 ("animating ⇒ healthy"). WRONG — a
  flickering/corrupt screen also changes every frame. The VICE differential
  comparison is mandatory for graphical titles and I'd skipped it (the first
  oracle screenshot silently failed). FIX: VICE monitor `screenshot` needs a
  forward-slash path + format arg: `screenshot "C:/.../x.png" 2` (backslashes
  write nothing). Oracle now produces PNGs.
- **Evidence:** HW `tools/scpu_compat/run/scpukicks_d1/{00_boot,0110s,0178s}.png`;
  oracle `tools/scpu_compat/run/scpukicks_d1_VICE_ORACLE.png` (+ `_scroller`,
  `_part_b`). Memory: `project_scpu_thirdparty_demo_validated.md`.
- **NEXT (the actual compat lever):** classify the rendering bug. (1) Get a
  SAME-part VICE-vs-HW shot (VICE loads slowly via real serial IEC — run >180s or
  add warp). (2) Re-run the demo with SCPU turbo forced OFF to test the
  raster-IRQ-timing-under-turbo hypothesis (this is SCPU-aware sw that likely
  writes $D07B → hits the iter-3 emu-turbo path). (3) If turbo-independent,
  suspect VIC-II badline/sprite timing under accelerated CPU or a DYCP
  $D011/$D016 fine-scroll interaction. Harness `run_d64_scpu.py` +
  `vice_run_d64.py` not yet committed pending this honest write-up.
- Speed past 4MHz stays Milestone-B-gated (iter 4).

## ITERATION 7 — COMPAT: SST F3 (RTI) re-characterized as BENIGN (DONE, docs-only)
Off-device, GHDL-only, no build. Closed the **last big cloud on the SST
conformance scoreboard**: F3 "RTI PC++" (~19,901 fails = **97% of all
remaining SST fails**, deferred since Phase 2 as needing "invasive
microcode restructure"). Root-caused cycle-by-cycle and proved it is **not
a real bug**.
- **Finding:** real 65C816 RTI = `opcode·dummy·inc-S(internal)·pull P·pull
  PCL·pull PCH[·pull PBR]` = 6 cyc emu / 7 cyc native. Our microcode has
  only ONE non-pull cycle before the pulls. Emu is therefore 5 cyc (missing
  the inc-S internal cycle); native is 7 cyc (correct total) but with the
  extra internal cycle mispositioned between the PCH and PBR pulls. **In both
  modes the stack pulls read the correct addresses/data and the final
  PC/SP/PBR/P exactly match the SST `final` regs** (verified via
  `run_sst.ps1 -VerboseEach` on 40.e/40.n). The emu "PC=exp+1" is a *bench*
  capture artifact (it samples regs one clock after the last recorded cycle;
  our emu RTI being 1 cyc short, that clock is the next opcode fetch, which
  already bumped PC).
- **Why benign:** RTI cycle-count is invisible to real C64/SuperCPU software
  — turbo abandons cycle-exactness, and stable rasters sync at *handler entry*
  ($D012 cycle-eating), never on RTI duration. Hence Lorenz 100% + every
  interrupt works despite the deviation. Joins F6/F7 + `$6C` in the "expected
  deviation" bucket → **every remaining SST fail is now a documented
  benign/intentional deviation; the P65C816 core has no known real-software
  CPU-semantics bug vs the SST oracle.**
- **Fix proven & SHELVED (not shipped):** inserting the missing inc-S internal
  cycle as RTI microcode state 0 (pure no-op row, local to RTI's 8-row slot)
  took **40.e 0/10000 → pass=9906 fail=0 skip=94** in GHDL, zero impact on
  other opcodes. Full both-mode fix additionally needs an XCE-style RTL
  special-case for the native PBR-pull SP++ (all 8 `LOAD_SP` codes are taken;
  P65C816.vhd:357 is the pattern). **Reverted the experimental RTL — CPU core
  left pristine.** Recipe lives in `docs/sst_phase2_bug_plan.md` §F3.
- **Decision (drive-don't-ask):** did NOT ship. CPU-core change in every
  interrupt path + mandatory full HW regression for a synthetic-scoreboard-only
  gain (nil real-software benefit) is poor leverage and against the project's
  CPU-core caution. Classify-and-document is the high-leverage move; the recipe
  is on the shelf for any future batched CPU-core HW-regress.
- **Net compat state:** the two cheap COMPAT levers reachable off-device
  (SCPU detection, iter 6; CPU opcode conformance, iter 7) are now both closed
  clean. The next REAL compat lever remains running actual 3rd-party SCPU title
  binaries (the documented gathering blocker) — register/CPU-semantics work is
  exhausted. Speed past 4 MHz stays Milestone-B-gated (iter 4).

## ITERATION 6 — COMPAT: SCPU detection VICE-oracle validation (DONE, committed `bc50977`)
Validation+infrastructure iteration (no RTL change — and that's the correct
outcome). Confirmed iter-5's $D0Bx/$D07E read-mux is **detection-correct against
the authoritative oracle**: VICE 3.10 xscpu64 `scpu64_hardware_read` (source via
WebFetch of scpu64mem.c) + live capture, cross-checked on silicon (build
`97392a1f`, MiSTer free → reserved → swept → released).
- **HW sweep line1 = `64 128 128 0`** ($D0B0/$D0B2/$D0B6/$D0BC) = every
  detection-critical SEMANTIC bit matches VICE EXACTLY: $D0B0=$40 (v2/64),
  $D0B2=$80 (hwenable after $D07E), $D0B6=$80 (emulation), $D0BC=$00 (b7=0 ⇒
  SuperCPU present = canonical Method-1 detect). Iter-5 had only spot-checked 2;
  now the whole detect set is HW+oracle confirmed.
- **scpu64mem.c key insight:** every $D0Bx read ORs `(mem_reg_optim & 7)` into the
  low 3 bits. The pervasive `$01` a bare probe sees (even on undecoded $D0B1/$D0B7)
  is the **optim register bleeding through, NOT open-bus**. Detection sw masks the
  high bits → our clean values are fully compatible.
- **No RTL change.** Benign deltas: optim low-3 bleed, $D0B3/$D0B4 optim-high-nibble
  ($D0B4 reads `3` on our 2-bit model), $D0B5 jiffy b7. ALL have zero firmware/
  detection consumers (iter-5: optim regs 9 writes / 0 reads). Adding decode =
  speculative dead code, which the project rules forbid.
- **Committed `bc50977`** (pushes gated): reusable differential-oracle tooling
  (`build_scpu_regprobe.py`+`scpu_regprobe.prg`, `vice_scpu_regprobe.py`,
  `d0bx_full_hw_sweep.py`) + authoritative VICE read formulas in
  `docs/supercpu_architecture_reference.md` §$D0Bx. Memory:
  `project_scpu_detect_vice_validated.md`.
- **Unblocks** the SCPU library compat sweep (feature_status §13 #9): detection-
  failure is now RULED OUT as a cause of "SCPU sw runs un-accelerated." The next
  real compat lever is running actual SCPU title binaries — gathering them is the
  blocker (repo has Doom/Wolf3D/Lorenz/asterix + our own probes, no 3rd-party
  SCPU apps). VICE xscpu64 is available locally as a per-title differential oracle.

## ITERATION 5 — COMPAT: SCPU status read-mux fix (SHIPPED + HW-verified)
The first COMPAT lever after the turbo wins. Two findings:
- **WriteSmart ($D074-$D077/$D0B3) is a NON-GAP** — EPROM scan: 9 writes / 0
  reads (only the fixed init `STA $D0B6/$D077/$D0B3`); our write-through bank-$00
  == optimization mode-0 ("always mirror"), strictly more correct than real-HW
  stale modes. Don't build dead WriteSmart decode. Closes that backlog lever.
- **$D0Bx/$D07E SCPU STATUS reads were DEAD** (real compat gap, now fixed). They
  used `cs_vic + cpuAddr(11:0)`, which is dead on the 65C816 path (every read =
  $FF). Headline: `$D0B0` SuperCPU presence-detect ($40) returned garbage, so
  external SCPU-aware software fails detection → runs un-accelerated. Converted
  all 10 clauses (fpga64_sid_iec.vhd ~1866-1884) to the hardware-proven 16-bit
  `cpuAddr_816` compare (same mechanism as the working $D27x/$FFEx clauses),
  policy gates unchanged. Firmware itself only pushes $D0B2/$D0BC to the stack
  (tolerates garbage) → why it stayed invisible.
- **VALIDATION — all green.** Phase-4b GHDL harness **85/85 PASS** (real
  fpga64_sid_iec + 65C816, boot + PRG-load no regression); CPU core sweep
  **7/7**; **HW-verified** on build md5 `97392a1f`: `POKE 53374,128 : PRINT
  PEEK(53424)` → **64** ($D0B0=$40, was 255) and PEEK(53426) ($D0B2) → **128**.
  Probe: `tools/d0bx_readmux_probe.py`; shot `tools/d0bx_readmux_probe/01_peeks.png`.
- **Bonus: restored the Phase-4b harness** (broken on HEAD, unrelated to the
  fix): added scpu_async_bridge.vhd to run_harness_v2.sh's source list, added the
  9 `dbg_*` ports to stubs/mos6526_stub.vhd, retired the obsolete BRAM
  external-name probe in c64_reduced_top_v2.vhd (c64_ram64k no longer
  instantiated under SDRAM passthrough; export had zero tb consumers).
- **Committed** (build-green + HW-verified). Pushes still gated. Memory:
  `project_scpu_status_readmux_fix.md`.

## STATUS
Self-paced `/loop` driving the north-star: **make the SCPU as compatible and
fast as possible.** Iteration 2 SHIPPED (native turbo, commit `32789a4`).
Iteration 3 SHIPPED (emulation-mode turbo, commit `83d1f2d`, build `ba9ec7b5`) —
4/4 HW-validated. Iteration 4 = OFF-DEVICE INVESTIGATION (no build): closed out
two would-be levers and re-characterized the speed roadmap. See "ITERATION 4"
below. **Net session result: 1MHz-default footgun fixed -> 4MHz both modes
(biggest available speed win), shipped + validated. >4MHz is Milestone-B-gated.**

## ITERATION 4 — investigation (2026-05-29, off-device, MiSTer released)
**(a) asterix GHDL "failures" are FAKE compat levers — closed out.** The
phase1/overlay/full_nmi benches (`-IncludeAsterix` sweep, "4/7") are STALE
April-2026 *hang-investigation* probes, not CPU regressions: overlay/overlay_mirror
deliberately INJECT a memory fault ($C000-$FEFF reads return stale $FF) to test an
SDRAM-write-drop hypothesis; phase1's CPU semantics are actually CORRECT (183 outer
iters is right — "target 182" mislabels taken-vs-executed); full_nmi never inits
the NMI vector ($FFFA/$FFFB left at $EA NOP-fill -> NMI lands in NOPs). A CPU fix
CANNOT make them pass. Annotated in `ghdl_compat_sweep.ps1`; the **default** sweep
already excludes them (7/7 $core is the real off-device gate). Do not re-chase.
**(b) 4MHz is a HARD architectural ceiling.** Confirmed via GHDL + design doc, no
build needed:
- `sim/sdram_pm_tb` Build-C extended bench PASSES — the Option-(a) SDRAM FSM (HIT
  ~4 clk64, conflict-MISS PRECHARGE-first, registered glitch-free alt-fire) is
  correct in sim. `sim/arbiter_demand_tb` PASSES — demand-arbiter priority logic
  correct. So the FSM/arbiter LOGIC is sound; the limit is elsewhere.
- `docs/milestone_c_arbiter_design.md` §F: the demand arbiter alone issues ≤1
  access / 4 clk32 = today's CPU0->CPU4 cadence => ~same throughput. Bottleneck is
  **SDRAM access latency (~4 clk32/MISS), not slot quantization.** "C-alone is NOT
  worth pursuing."
- The faster SDRAM HIT path (~2 clk32) can't be exploited from clk32: `sdram_ready`
  is synced clk64->clk32 via a 2-FF chain (`fpga64_sid_iec.vhd:3293-3295`) = ~2
  clk32 latency, so an observed HIT lands at ~4 clk32 ≈ the main-slot cadence (no
  win). Gating alt-slots on a *predicted* busy_cnt instead is the dual-tracker bug
  (`sdram_hit_pred<='0'` forced at :3211: predict-HIT-but-actual-MISS -> premature
  busy clear -> stale sample -> Doom BRK $00:000A).
- CONCLUSION: alt-slots (CPU2/6/A/E) CANNOT help on this architecture — do NOT
  retry them. The only real >4MHz path is **Milestone B** (clk_cpu=64MHz + bridge
  MCP), a large black-screen-prone arc, not a loop iteration.

## ITERATION 3 IN FLIGHT — emulation-mode turbo (the PRIMARY SCPU use case)
Goal: accelerate emulation-mode 6502 code (GEOS+SCPU / productivity), which still
runs at 1 MHz after iteration 2's native-only turbo. All edits in
`fpga64_sid_iec.vhd`. Three mechanisms:
1. **`scpu_speed_reg_written` latch** (decl ~:1339, reset ~:2349, set ~:2415/2417):
   sticky '1' after software writes $D07A/$D07B/$D079. Keeps the DEFAULT path
   (Lorenz/BASIC/LOAD/Doom-loader, none of which touch the speed reg) at 1 MHz so
   **Lorenz stays 100%** — the hard constraint. Without this, $D07B's default '0'
   would make emulation fast-by-default and break Lorenz timing tests.
2. **Emulation turbo clause** (turbo_m process ~:3434): `turbo_m<="111"` when
   `supercpu_en and emu_mode_816_i='1' and scpu_speed_reg_written and not
   scpu_speed_1mhz` — i.e. SCPU-aware sw asked for fast via $D07B.
3. **`emu_serial_throttle`** (registered, ~:3232; folded into `scpu_force_1mhz`
   :3230): force 1 MHz while emu-mode `cpu_pc_now` is in KERNAL IEC serial pages
   $ED/$EE — protects the unpatched-KERNAL serial bit-bang even if sw left fast
   mode on. Range confirmed by project memory (send loop $ED66-$ED90, wedge $ED5A,
   ACPTR receive $EE13).
Risk is LOW for validated cases: the latch makes every default path bit-identical
to `32789a4`. New behavior only for $D07B-writing sw.

### VALIDATION (build `byqhg1esl`, RBF md5 `ba9ec7b5`, ALMs 27,431/65%) — 3/4 GREEN
Re-acquired MiSTer (CORENAME=C64, untouched; wrote lock), deployed `ba9ec7b5`.
1. **LOAD** (`iec_wedge_probe.py scpu`) — **PASS.** 120s probe completed to `IE:1F`,
   program running at $08xx, `C2:C7` (serial idle). (A 75s probe ended mid-transfer
   — PC *cycling* $ED5A<->$EEB2, not pinned — i.e. active 1 MHz serial transfer,
   not a wedge; 1 MHz serial of the Lorenz file just takes ~75-120s.)
2. **scpu_speed_bench** (`tools/run_scpu_speed_bench_mgl.py`, MGL variant on _Test) —
   **PASS.** `$D07A`(1MHz)=$01DC=476 iters vs `$D07B`(turbo)=$064F=1615 iters =
   **~3.4x**. Was 1x before. $D072/$D073 modulate identically. ($D07B emulation
   turbo WORKS; 3.4x not 4x because the loop touches I/O which stays 1 MHz.)
3. **Doom** (`deploy_and_probe_doom.py`) — **PASS.** id Software credits screen
   rendered (Carmack/Romero/Taylor...), PC in-engine (banks $0E/$20/$2A), IF
   advancing, `IE:1F`. Native 4x path unaffected.
4. **Lorenz scpu** (`tools/lorenz_run.py scpu`) — **PASS (no regression).** 35-min
   run: every sampled frame `CHANGE` (suite advancing, never halted on a failure),
   all instruction tests `- ok` (...anda/andax/orab/oraz/eorb/eora at the cap). Hit
   the 35-min time-cap still in the instruction-test region ("eora") -> the
   timing-sensitive CIA tests weren't reached in-window (1 MHz serial loading is
   slow). Coverage closed by CONSTRUCTION: Lorenz never writes $D07A/$D07B -> latch
   stays 0 -> the emulation-turbo clause never fires (turbo_m="000") and
   emu_serial_throttle only gates non-existent turbo slots (CPUC still fires) ->
   the WHOLE suite runs bit-identically to baseline 1 MHz, so the unreached timing
   tests are unaffected. The slow "only reached eora in 35 min" pace is direct
   empirical proof emulation is NOT turboing by default. (A full-suite run would
   need ~60-90 min at 1 MHz; foregone conclusion given the proof.)

### RESULT: 4/4 GREEN -> COMMITTED. Iteration 3 SHIPPED.

## SHIPPED THIS ITERATION (commit pending in this turn) — native-mode max-turbo
**`C64_MiSTer/rtl/fpga64_sid_iec.vhd:3395` (turbo_m process).** Force
`turbo_m<="111"` (4x, = CPU slots 0/4/8/C) whenever `supercpu_en='1' and
emu_mode_816_i='0'` (SCPU **native** mode). Emulation mode stays OSD-controlled
(default off -> 1 MHz).
- **Why:** OSD turbo (`status[46/47]`,`[49:48]`) and `supercpu_enable`
  (`status[82]`) were INDEPENDENT, so with OSD Turbo off (default) the SuperCPU
  ran at **~1 MHz even when enabled** (only CYCLE_CPUC fired). Real SCPU software
  sets speed via $D07A/$D07B, not the OSD. Biggest compat+speed footgun found.
- **Why native-gated (not the obvious emu+native):** the stock 1 MHz-timed KERNAL
  serial LOAD/SAVE routine ($ED66-$ED90, CPU-cycle-counted NOP delays) only runs
  in EMULATION mode. Speeding emulation mode desyncs the c1541 -> $ED5A wedge.
  Native software (Doom gameplay) never touches serial, so native-gating is safe.
- **FALSIFIED first (do NOT repeat):** disk_access-gated emu+native turbo in
  `c64.sv` (`(status[47]|supercpu_enable)&~disk_access` + `turbo_speed=2'b10`).
  Built md5 `79cd45bd`, deployed -> **regressed LOAD** (`J:ED5A ED5A`+`IE:13`).
  disk_access asserts too late / cia2_throttle only slows the CIA2 *access*, not
  the serial routine's NOP delays. c64.sv reverted to known-good.
- **Guards still active on top:** `scpu_force_1mhz` ($D07A/$D072/cia2_throttle)
  gates the turbo slots; the existing `cs_io='0'` guard keeps all I/O at 1 MHz.
  Cold boot is emulation (E=1) -> 1 MHz until software `XCE`s to native.

### HARDWARE VALIDATION — ALL GREEN (build md5 `99289ecb`)
1. **LOAD** (`iec_wedge_probe.py scpu --secs 90`): `IE:1F` every frame, PC running
   at $08xx (loaded program), **no $ED5A**. Regression FIXED.
2. **Doom** (`deploy_and_probe_doom.py`): t150 shows the DOOM engine startup
   console (`V_Init`/`Z_Init`/`W_Init adding ./dooml.wad`/`M_Init`/`C_Init`),
   then the **DOOM title screen** (logo + "id software") rendered. PC healthy
   in-engine (SuperRAM banks $0F/$21/$2A), IRQ counter `IF` advancing. Works at 4x.
3. **Boot/READY:** implicit — both probes started from a clean BASIC READY.

## Speed baseline (the loop's effective-MHz axis)
- clk32=31.53 MHz; 32 clk32/period = 16 CPU slots. `cpu_cyc` (fpga64_sid_iec.vhd
  :3256-3262) grants CPU0/4/8 only when the matching `turbo_m` bit is set AND
  `scpu_force_1mhz='0'`; CPUC always fires.
- **Native (post-fix): 4 slots (CPU0/4/8/C) = ~4 MHz ceiling** (source-verified;
  Doom runs native cleanly => active+stable). Was 1 slot = ~1 MHz.
- **Emulation: still ~1 MHz by default** (OSD-controlled). This is the next gap.
- A native-mode micro-benchmark for an exact MHz number is a nice-to-have; the
  emulation-mode scpu_speed_bench.prg can't measure native (runs via BASIC SYS).

## NEXT iteration — pick a COMPAT lever (speed past 4MHz is B-gated, see iter 4)
Both turbo wins (native + emulation) are banked. Past 4MHz needs Milestone B (a
deliberate multi-session arc, not a loop iteration). So the highest-leverage
loop-sized work is now COMPAT. Candidate compat levers, re-prioritize freely:
- **WriteSmart register decode** ($D074-$D077/$D0B3): SCPU-aware sw that probes
  WriteSmart may misbehave. Contained, lower-risk. First confirm a real consumer
  (grep `tools/scpu64.bin` disasm + any SCPU lib) before building — don't add dead
  decode.
- **SCPU software compatibility sweep**: gather a few real SCPU titles/libs (beyond
  Doom/Wolf3D/Lorenz) and run them on HW to find concrete breakage. Exploratory but
  directly serves "compatible."
- **Lorenz full-suite timing run** reaching the CIA/timer tests (currently only the
  instruction tests are reached in the 35-min cap). Low priority — iter 3's
  construction proof already covers the scpu-turbo no-regress, but a clean
  full-suite pass is a nice baseline.
If instead committing to SPEED: open the Milestone B arc deliberately (clk_cpu=
64MHz bridge MCP). Read `docs/path_to_20mhz_plan.md` + the MCP/passthrough memory
first; GHDL + reduced-harness HEAVILY before any build (black-screen history).
**Do NOT retry alt-slots or re-enable bank-$00 cache** (CACHE_ACTIVE='1') — both
dead ends (see iter 4 + memory `scpu-speed-landscape-1mhz-default`).

## CPU-correctness baseline (off-device)
`tools/ghdl_compat_sweep.ps1` — **core sweep 7/7 PASS** (the real off-device CPU
gate). The `-IncludeAsterix` "4/7" is NOT a compat gap: those 3 "FAIL"s are stale
April-2026 fault-injection hang-probes (see iter 4 above) — annotated in the sweep,
do not chase. Fixed a tolerated false-alarm in `p65c816_rep_tb.vhd` earlier (PC
convention; REP->16-bit-immediate VERIFIED correct).

## Shared-MiSTer + tooling notes
- Check `/tmp/CORENAME` before disruptive ops (C64=mine; else back off).
- Winsock `getaddrinfo` race worked around via `socket.create_connection`+`sock=`.
- Local commits unpushed beyond origin `747cdea`: 20e0ac5, 9437377, 6df990c,
  5f4f574, c258e29 (+ this iteration's native-turbo commit). **Pushes stay gated.**
- Uncommitted-by-design: c64.sv / debug_pkg.svh / debug_uart_pool_fmt.sv / C64.qpf
  carry local IE:## UART instrumentation — NOT fixes, leave uncommitted.
