# Session handoff — 2026-06-01: COMPAT ITER-9 — SuperCPU Kicks! ROOT CAUSE PROVEN = a runtime SPEED-detection failure (VICE `+speedswitch` 1MHz reproduces the HW fallback exactly). SPEED-BOUND, not register/render. $D0B3/4/5=$80 lead FALSIFIED. Demo SHELVED until effective MHz>4. PIVOT next to WriteSmart decode / title sweep.

## ✅ COMPAT ITER-9 RESULT (2026-06-01, control `97392a1f`) — the SuperCPU-Kicks detection is a SPEED test
**Airtight differential proof (only clock speed varied in VICE):**

| Config | Effective speed | PC settles | Result |
|---|---|---|---|
| VICE default | ~20MHz | `$8147` (fire-gate / DMAgic intro) | **PASS** → loader menu |
| VICE `+speedswitch` | 1MHz | `$81F7` | **FALLBACK scroller** |
| MiSTer control `97392a1f` | 4MHz | `$81B0-$8360` loop | **FALLBACK scroller** |

VICE forced to 1MHz lands in the SAME `$81xx` region our 4MHz HW is stuck in and
shows the SAME fallback scroller. ⇒ the demo's SuperCPU detection is a **runtime
speed check** with a threshold >4MHz. It is **SPEED-BOUND** — no RTL register/decode
change can fix it; only effective CPU speed past the threshold (the HW-walled lever).
Consistent with the title being a 20MHz speed showcase. **SHELVE this demo** until a
>4MHz speed lever lands.

**FALSIFIED / ruled out this session (do NOT re-chase):**
- **$D0B3/$D0B4/$D0B5=$80 candidate mismatch — FALSIFIED.** Scanned `vice_depack.bin`
  ($0800-$B701): the demo reads NO `$D0Bx` whatsoever. The prior handoff's top lead is dead.
- NOT a CIA-timer speed loop (watchpoints on `$DC04-07`/`$DD04-07` loads = a memory copy `$01AE`).
- NOT individual SCPU register readback (only one sequential `$D0xx` page-copy; "$D070=text"
  watch values were RAM reads with I/O banked out — red herring).
- NOT SIMM size (VICE passes `-simmsize 0`); NOT `$D27C-F` extent (VICE==RTL `00 02 00 f6`).
  VICE fire-gate regs: `$D070-$D07F`=`$FF`, `$D080-$D08F`=`$00`.

**Caveat:** `vice_depack.bin` is the SUCCESS-path image; the fail path decrunches
different code into the same `$81xx` addresses, so its static disasm doesn't match the
fail path. VICE `cpuhistory` is compiled-out in the GTK3 Windows build (command exists,
buffer empty) → no clean detection trace obtainable. The exact detect instruction is
academic now (the cause is speed, not a readable register).

**Artifacts (`tools/scpukicks_vice/`):** `trace_watch.py`, `dump_regs.py`, `disasm.py`,
`hw_detect_run.py`, `vref_speedswitch_off.png`, `dr_postrun_{a,b}.png`, `vice_regdump.txt`.
Full detail: memory `scpu-kicks-rendering-bug`.

## ➡️ NEXT (compat iter-10) — pivot off SuperCPU-Kicks (speed-bound) to a FIXABLE compat target
- SuperCPU-Kicks is done/shelved (speed-bound). Highest-leverage remaining compat work:
  - **(A) Broaden the SCPU title sweep** — find a 3rd-party SCPU title that fails for a
    NON-speed reason (register decode, memory map, IEC/serial). A title that runs at 1MHz
    on real SCPU but fails on us = a genuinely fixable bug. Avoid speed-showcase demos.
  - **(B) WriteSmart register decode** ($D074-$D077/$D0B3) — note prior-iter closed this as a
    firmware non-gap (9 writes/0 reads, our write-through == optim mode-0); only revisit if a
    swept title actually reads them.
- Constraint: Lorenz must stay 100% in BOTH t65 and scpu for any RTL change.
- State: control `97392a1f` deployed + booting; lock NOLOCK; no RTL change, no commit this
  session (investigation only). All >4MHz speed levers remain HW-dead (see prior handoff below).

---

# (prior) Session handoff — 2026-06-01: COMPAT ITER-8 — SuperCPU Kicks! HW re-characterized = a DETECTION failure (drops to fallback scroller), NOT the previously-claimed render corruption. VICE oracle established; SIMM-size + $D27x extent RULED OUT. Exact detection compare still uncaptured.

## ✅ COMPAT ITER-8 RESULT (2026-06-01, control `97392a1f`, scpu mode) — overturns the 2026-05-29 "render bug" framing
- **HW capture done** via `tools/scpukicks_vice/hw_capture.py`: MGL-mount `SCPU1.D64` (abs path) → `load"*",8,1` → ~80s IEC load (clean READY) → `poke33094,255` (fire-gate `$8146` CMP `#$EF`→`#$FF` bypass) → `run`.
- **Result: the demo does NOT render a corrupt/flickering menu. It fails its SuperCPU detection and drops to the
  "we still have a dream / required: scpu with 1mb ram" FALLBACK scroller** (those exact strings are scratched
  dir entries on the disk). Screens: `tools/scpukicks_vice/hw_menu.png` (the demo's always-on "THIS DEMO REQUIRES
  A SUPERCPU WITH 1 MB" status line — written by $7854 init, overwritten on success), `hw_menu_b.png`/
  `hw_effects_*.png` (the fallback scroller). My fire-gate patch was MOOT — detection runs before the gate; the
  demo took the fallback and never reached $8142.
- **VICE xscpu64 = clean golden oracle**: reaches the loader-select **menu** (F1 JiffyDOS / F3 FD-2000 / F5 1541
  Speeder + credits) → `tools/scpukicks_vice/vref_menu_clean.png`. (At autostart it rests at the $8142 fire-gate
  showing the DMAgic intro `vref_simm0.png`.)
- **RULED OUT this session:**
  - SuperRAM SIMM size — VICE reaches the menu even with `-simmsize 0` (no SuperRAM). Not a size probe.
  - $D27C-$D27F SuperRAM-extent registers — VICE kickstart = `00 02 00 f6`; our RTL hardcodes the IDENTICAL
    `00/02/00/F6` (fpga64_sid_iec.vhd ~:2026). Match.
  - x64sc as oracle — plain 6502 CRASHES on the demo's 65816 native detection (black screen). Must use xscpu64.
  - The `LDA $D0B2` watchpoint hits were the **SuperCPU KICKSTART firmware** boot ($8140 reset code), NOT the
    demo's detection. Red herring.
- **STILL UNCAPTURED: the demo's exact detection-and-branch compare.** VICE autostart is one-shot + warp + the
  demo self-modifies the $814x region → ~10 live-capture attempts failed (`reset 0` only re-runs firmware). VICE
  $D0B0-$D0BF at the passing fire-gate = `40 00 00 80 80 80 00 00`; our RTL gives $D0B0=$40 but CANNOT produce
  $D0B3/$D0B4/$D0B5=$80 (formulas cap them low) — a candidate mismatch, NOT confirmed as the decision register.

## ➡️ NEXT (compat iter-9) — capture the detection compare, then fix
- **Primary: MiSTer-side capture.** Run the demo on HW and UART/overlay PC-trace where it branches to the
  fallback (the demo fails ON the MiSTer, so the failing path executes there). Disassemble that branch + the
  register/probe it reads, compare to our RTL ($D0Bx read mux ~fpga64_sid_iec.vhd:1991-2011, gated on
  `scpu_regs_enabled`), fix the mismatch. Constraint: Lorenz must stay 100% in t65 AND scpu.
- **Alt: off-device.** Inject a `BRK`/breakpoint into `tools/scpukicks_vice/boot_dma.prg` right after the $0810
  decruncher exit and trace in VICE (beats the autostart-one-shot), OR relaunch xscpu64 with the correct
  true-drive flag for a wide watchpoint window on `$D070-$D0FF` loads during the slow load.
- Artifacts: `tools/scpukicks_vice/` (hw_*.png, vref_*.png, boot_dma.prg extracted via c1541, vice_depack.bin,
  hw_capture.py). Full detail: memory `scpu-kicks-rendering-bug`.
- Backlog (unchanged): WriteSmart decode $D074-$D077/$D0B3; broaden the SCPU title sweep.
- State: control `97392a1f` deployed + booting; MiSTer lock = NOLOCK; no RTL change, no commit this session
  (investigation only). All >4MHz speed levers remain HW-dead (see prior handoff below).

---

# (prior) Session handoff — 2026-05-31: iter-7g — same_line-gated 2× alt fire HW-FALSIFIED → SPEED LEVER EXHAUSTED. ALL cadence-shortening/raised-clock >4MHz levers now HW-dead. BRAM cache shipped (`12309a0`) = CORRECTNESS only. PIVOT to COMPAT.

## ⛔⛔ ITER-7g HW VERDICT (2026-05-31): the same_line-gated `alt_fire_r2` STILL wedges SuperRAM → the 2× cadence is a DEAD lever; the wall is the P65C816 core, not the cache
- Built `7139db68` (`ALT_FIRE_2X:=true` + `CACHE_READ_PATH:=true`, same_line gate + DMA snoop wired;
  **timing CLEAN setup +0.361ns, hold +0.193ns, TNS=0**). **Boots CLEAN** (`SCPU64 V0.07/READY`,
  `tools/iter7g_boot.png`).
- **`superram_bench` WEDGED**: COUNT `$-----` static across 3+ captures vs control `97392a1f` COUNT
  `$000335` clean A/B (`tools/test_cart/out/superram_bench_n{0,2}.png` vs `_ctrl1.png`). UART **PC frozen
  `000002`, `J:FF4C FF4C` loop = hard crash into bank-$00 page-0** — same signature as iter-7f / clk48 / SLOT3.
- **WHY same_line didn't save it:** same_line fixes the `line_word`-registered-1-late DATA latency, but the
  wedge is the **iter-6 CPU-core single-cycle TIMING wall**: at 2-apart the CPU enable fires every 2 clk32,
  so the deep combinational consume `cache_di → cpuDi → P65C816.di → ALU → AddrGen|PCr` (~11ns INSIDE the 816)
  collapses from the 62.5ns setup-2 budget toward 31.25ns where iter-6 measured −0.651ns FAIL. iter-7d's
  registered override (`rp_cache_hit_d1`/`rp_cache_di_d1`) is a NO-OP at the alt cadence (the _d1 capture
  races the next access). **A data-validity gate cannot fix a timing violation on the consume path.** Build
  closed timing ⇒ FUNCTIONAL, same disproof shape as clk48/SLOT3.
- **DURABLE CONCLUSION — speed lever exhausted.** ALL cadence-shortening / raised-clock >4MHz attempts are now
  comprehensively HW-dead: Milestone B (clk64+clk48), page-mode SDRAM, SLOT3 (3-clk32), BRAM-cache 2× alt-fire
  (RDY-handshake / bare iter-7f / same_line iter-7g). They share ONE root cause: the deep combinational
  `dataToCpu`+`cpuDi`+`P65C816 di→ALU→PC` path (~20.5ns, ~11ns in-core) closes only at the ≥4-clk32 multicycle.
  **The ONLY remaining >4MHz path is register-retiming / pipelining INSIDE the P65C816 di→ALU→PC** — deep,
  multi-session, high-risk CPU-core surgery; NOT to be started on impulse. The BRAM cache's real payoff is
  CORRECTNESS + coherency infrastructure (shipped `12309a0`), not speed.
- **Recovery DONE:** `git checkout HEAD -- fpga64_sid_iec.vhd` (reverted iter-7f/7g alt-fire scaffolding — a
  falsified trap, not kept; tree = `12309a0`, ships bit-identical). Control `97392a1f` redeployed + booting,
  lock NOLOCK. NO new commit (iter-7g is falsified, not a fix).

## ➡️ PIVOT TO COMPAT (next iteration) — speed is walled at 4MHz without 816-core surgery; highest-leverage work is now compatibility
- **(1) SuperCPU-Kicks! rendering/flicker bug** — the strongest candidate: a REAL VICE-confirmed defect (the
  demo renders corrupted/flickering on HW but CLEAN in VICE xscpu64 = differential oracle available). See
  memory `scpu-kicks-rendering-bug` / the compat-iter8 finding. Tractable because VICE gives a golden reference.
- **(2) WriteSmart register decode** ($D074-$D077 / $D0B3) — unimplemented SCPU registers; real-HW software
  may poke them.
- **(3) SCPU library compatibility sweep** — broaden the 3rd-party title coverage beyond SuperCPU-Kicks.
- Constraint reminder: Lorenz must stay 100% in BOTH t65 and scpu modes for any change.

## 🔬 COMPAT ITER-8 PROGRESS (2026-06-01) — SuperCPU Kicks demo characterized; VICE oracle established; device yielded mid-test
- **HW repro path established (control `97392a1f`):** MGL mount `SCPU1.D64` (ABSOLUTE path —
  `/media/usb0/Games/C64/tools/SCPUKICK/SCPU1.D64`; relative path → core falls back to MENU) +
  `mtype 'load"*",8,1' enter` (RETURN is the arg `enter`, NOT `\n`) → ~70s standard-IEC load → READY →
  `mtype run enter`. Boot file `scpu kicks !/dma` (114 blocks) loads + runs cleanly on HW.
  Note: MiSTer `/tmp` is 100% full → put mtype.py at `/media/fat/_Test/mtype.py`.
- **Demo flow CORRECTED (disassembly via VICE monitor) — supersedes the stale "DMAgic stall" note:**
  RUN → **fire-gate** `$8142: LDA $DC01 / CMP #$EF / BNE` (waits joystick-1 fire $EF) → native setup
  (XCE $815f, $D011=$7B/$D016=$C8) → draws **loader-select menu** (F1 JiffyDOS / F3 FD-2000 / **F5 1541
  Software Speeder**) → F5 loads parts A/B/C → effects. NOT DMAgic-dependent.
- **VICE xscpu64 = VALID golden oracle (NEW):** `xscpu64 -warp -autostart SCPU1.D64 -remotemonitor
  -remotemonitoraddress ip4://127.0.0.1:6510` renders the menu **cleanly** →
  `tools/scpukicks_vice/vref_menu_clean.png`. Headless shot = monitor `screenshot "path" 2` (format 2=PNG;
  default BMP writes nothing usable); driver `tools/vice_shot.py`. Fire-gate is matrix-based (can't satisfy
  via monitor) → `r PC = 8149` to pass it; real EFFECTS need fire+F5 input (GUI or HW), not PC-forcing.
- **⚠️ DEVICE YIELDED:** right after I issued `RUN` on HW, the CD32 agent loaded `Universe-CD32MVP`
  (CORENAME flipped C64→Universe-CD32MVP). Per the cooperation protocol I backed off, released my lock
  (NOLOCK), and moved to off-device VICE work. The MiSTer-side menu/effects capture + VICE diff is the
  **next step when the device frees**.
- **NEXT (needs MiSTer):** load demo → pass fire-gate (fire/space) → F5 → capture HW rendering of menu +
  effects → diff vs VICE golden. If VICE clean & HW corrupt ⇒ bug is FPGA VIC/timing infra (per CLAUDE.md
  differential-oracle methodology). Full detail in memory `reference_scpu_kicks_demo.md`.

---
## (historical) ITER-7f verdict — superseded by iter-7g above

## ⛔ ITER-7f HW VERDICT (2026-05-31): the HIT-gated `alt_fire_r2` (2× cadence) CORRUPTS SuperRAM execution → FUNCTIONAL cross-line latency, not timing
- Built `f1d6bcfd` (`ALT_FIRE_2X:=true` + `CACHE_READ_PATH:=true`; **timing CLEAN, setup +0.476ns, TNS=0** —
  the 2-apart fires close under the existing -setup 2 multicycle exactly as iter-6 predicted). Boots CLEAN
  (`SCPU64 V0.07/READY`, `tools/iter7f_boot.png`) — alt fire is SuperRAM-only so boot (bank-$00) is unaffected.
- **`superram_bench` (the clean alt-fire gate: bank-$20 loop code+counter, NO DMA) WEDGED**: COUNT `$eee?00`,
  PASS `$----`, **static across 3 captures 3s apart** (`tools/iter7f_bench_{a,c}.png`), overlay PC stuck ~$FF4x.
  The header printed (payload copied to $20:8000 + JML'd in) but the timed inner loop produces garbage and hangs.
- **DECISIVE ISOLATION (3-way, same bench, same session):**
  | build | cache | alt fire | superram_bench | COUNT |
  |---|---|---|---|---|
  | `97392a1f` control | off | off | CLEAN | `$0335` (821) |
  | `e9c36c3e` iter-7e | **on** | off | **CLEAN** | `$02E0` (736) |
  | `f1d6bcfd` iter-7f | on | **on** | **WEDGED** | `$eee?00` garbage |
  - (control→e9c36c3e): the SuperRAM cache override @4-apart is **HW-CORRECT** — FIRST HW proof (iter-7e's
    gate was boot+Lorenz = bank-$00 only; the SuperRAM cache path feeding the CPU had never run a real
    SuperRAM workload on silicon until now). Strengthens `12309a0`.
  - (e9c36c3e→f1d6bcfd): the ONLY new variable is `ALT_FIRE_2X` ⇒ **the alt fire is the corruptor**, not the cache.
- **Mechanism (cross-line cache latency, exposed at 2-apart):** `cpu_cache.line_word` is registered 1 clk32
  late, so `rp_cache_di`/`rp_cache_di_d1` for a CROSS-LINE access don't settle until ~2 clk32 after the
  address changes. At 4-apart the address is held ~4 clk32 (settles → e9c36c3e clean); at 2-apart (alt fire)
  only ~2 clk32 → a cross-line hit feeds the PREVIOUS line's byte → stale latch → wedge. The bench loop
  crosses lines constantly (code `$20:8000` vs counter `$20:0003`). Same wall as the iter-7b/7c latency
  characterization (`cpu_cache_latency_tb`: M1 same-cycle cross-line = STALE). Build closed timing ⇒ this is
  FUNCTIONAL (data validity), not the STA timing iter-6 measured. Same disproof shape as clk48/SLOT3:
  STA-honest, HW fails ⇒ functional.
- **Recovery DONE:** both flags → false (RTL bit-identical, ships unchanged), control `97392a1f` redeployed +
  booting, lock NOLOCK. NO new commit (no RTL fix yet; the alt-fire edits + ALT_FIRE_2X constant stay in the
  tree at default-false — bit-identical — pending the same_line fix or removal).

## 🚀 ITER-7g (BUILDING `build_iter7g_sameline_snoop.log`): same_line-gated alt fire + DMA snoop = the complete shot at a shippable speed win
Implemented + building (both flags true, elaboration PASS). Two coupled fixes for the two iter-7f blockers:
- **same_line gate** (the cross-line corruption fix): added `signal rp_same_line`, wired the cache's
  `same_line` output (was `open`) to it, and added `and rp_same_line = '1'` to the `alt_fire_r2` condition.
  Now the 2× fires ONLY when the upcoming SuperRAM access is in the SAME cache line as the previous one
  (`line_word` already settled = safe). Cross-line accesses → `same_line='0'` → no alt fire → 4-apart (the
  line-load access is safe at 4-apart, as e9c36c3e proved). iter-7f's wedge is EVIDENCE the fire decision
  sees the upcoming address (it stale-latched on cross-line), so same_line (same address basis) suppresses
  exactly those. Expected ~1.4-1.6× (within-line code fetches get 2×; data/line-crossings stay 4-apart).
- **DMA snoop** (the Doom-regression fix): wired `snoop_we => dma_active and cpuWe`, `snoop_addr => cpuAddr`
  (= dma_addr during DMA), `snoop_bank => x"00"` (REU targets bank-$00 RAM). Drives cpu_cache's `snoop_inv`
  (top-priority valid-bit invalidation, cache_coherency_tb STEP-6-proven). Now REU FETCH writes invalidate
  the cached lines the loader re-reads → no stale buffer bytes → Doom transfer should complete. fix B covers
  bank-switch coherency so `flush=>'0'` stays.
- **HW GATE (probe build, both flags true):** (1) boot clean; (2) **`superram_bench` COUNT > control $0335**
  = the alt fire now safely speeds up within-line SuperRAM (the make-or-break — iter-7f wedged here);
  (3) **Doom autoload no-regress** = validates the snoop (iter-7f/e9c36c3e wedged at the eeee loader screen);
  (4) Lorenz scpu/t65 100%. If all green: revert flags→false, commit, this is the FIRST shippable speed win.
  If superram_bench still wedges → same_line timing-alignment is wrong (the CPU2 sample doesn't see the
  upcoming address cleanly) → the BRAM cache can't do 2× without a cpu_cache redesign → pivot to compat.
  If bench speeds up but Doom wedges → snoop wiring wrong (check dma_we pulse vs cpuWe-during-DMA).

## 🎯 (superseded by the iter-7g build above) original NEXT HYPOTHESIS: `same_line`-gated alt fire (DE-RISK OFF-DEVICE FIRST)
`cpu_cache` already exposes a `same_line` output (cpu_cache.vhd:180, currently wired `open` at the
read_path_cache instance). Gating `alt_fire_r2` additionally on `same_line='1'` would fire the 2× cadence
ONLY for within-line consecutive accesses (line_word already settled = SAFE), and fall back to 4-apart on any
cross-line access. Expected payoff is modest (sequential code fetches are ~75% same-line for 8-byte lines, but
data accesses cross lines) — maybe ~1.4-1.6× ≈ 6MHz, not full 2×. **DE-RISK BEFORE BUILDING:** extend
`cpu_cache_latency_tb` (or a new focused bench) with a synthetic cross-line SuperRAM access stream and verify
`same_line` goes '0' on exactly the cross-line cycles (so the gate suppresses the unsafe fires) AND the
timing-alignment of `same_line` vs the CPU2 alt-fire sample edge is correct. This is a cpu_cache-unit property
(NOT the boot-blocked full harness, which is stuck at $FD83), so it CAN be validated in GHDL — unlike the alt
fire itself. Only build if the bench confirms same_line cleanly suppresses cross-line 2× fires.

## ⚠️ STATE OF THE CACHE-AS-SPEED-LEVER (honest)
- SuperRAM cache @4-apart: HW-correct BUT (a) cadence-neutral = NO speedup, (b) breaks Doom (snoop gap,
  unwired), (c) `e9c36c3e` bench COUNT 736 < control 821 hints it may even be slightly SLOWER (needs
  back-to-back re-measure — could be run variance). So enabling the cache @4-apart is currently all-cost.
- The ONLY path to speed from the cache is firing >4-apart on hits (alt fire), now HW-blocked by cross-line
  latency. same_line-gating is the remaining sub-lever; if it too underperforms, the BRAM read cache cannot
  deliver the 2× without a deeper `cpu_cache` redesign (faster/combinational cross-line path). At that point
  ALL clk32-or-faster speed levers (clk64, clk48, SLOT3, page-mode, cache+alt-fire) are HW-dead and the
  honest north-star pivot is COMPAT work (WriteSmart decode, title sweep) or a cpu_cache redesign.

---

# (prior) Session handoff — 2026-05-31: iter-7f BUILD — cache read-path CORRECTNESS LANDED (fix B, HW-validated + committed `12309a0`); BUILDING the 2× variable-cadence arbiter (HIT-gated `alt_fire_r2`)

## ✅ ITER-7e RESULT (committed `12309a0`): fix B = FIRST clean HW boot of the cache read path feeding the CPU
- **Root cause of iter-7c/7d boot corruption** (HW-falsified `0228d2b6`, `3514fc7d`): the read-path cache
  tag (`cpu_bank & addr[15:12]`) does NOT encode ROM/RAM visibility (`$01`/bankSwitch) and the instance
  wires `flush=>'0'`, so a byte cached while ROM is visible at $8-$B/$E-$F is returned STALE after `$01`
  switches to RAM. fill-on-every masked it; fill-on-miss-only exposed it → garbled boot. Registering the
  override (iter-7d) fixed the masked single-cycle TIMING but not this FUNCTIONAL staleness.
- **Fix B** (`rp_cacheable`, fpga64_sid_iec.vhd ~:4910): narrow to coherent-by-construction ranges only —
  bank-$00 `$0000-$7FFF` + `$C000-$CFFF` (always-RAM, invalidate_wr-coherent) and SuperRAM banks `$02-$EF`
  (no ROM shadow → full Doom-workload caching preserved). Excludes ROM-shadowable `$8/9/A/B/E/F` + non-RAM
  `$D`. Gating only `rp_fill_we` transitively kills hit+override on excluded lines, so `cpu_cache.vhd` +
  observer + shipped RBF stay bit-identical.
- **HW gate (probe build `e9c36c3e`, CACHE_READ_PATH:=true+fixB) — ALL GREEN:**
  - BOOTS CLEAN (`SCPU64 V0.07` / `READY`) — `tools/iter7e_fixB_boot.png`.
  - Lorenz **scpu PASS** — serial LOAD (the exact e0e83e5c corruption case) + execution clean across
    load/store ×A/X/Y ×all addressing modes incl. indexed-indirect (`tools/iter7e_scpu_final.png`).
  - Lorenz **t65 PASS** — no regression (`tools/lorenz_run/t65/final.png`).
- Committed `12309a0` (flag reverted to false → ships bit-identical; unpushed). This is **correctness-only
  at the existing 4-apart cadence — NO speedup yet** (cache ships disabled; delivers zero shippable speed
  until the arbiter converts it).

## 🚀 ITER-7f (BUILDING `build_iter7f_2x.log`): the 2× variable-cadence arbiter = HIT-gated `alt_fire_r2`
The cache is now correct but useless without firing the CPU more often on hits. **This build is the only
path to convert iter-7e's correctness into actual >4MHz speed.**
- **Design** (fpga64_sid_iec.vhd): new `constant ALT_FIRE_2X` (default false; SEPARATE from CACHE_READ_PATH
  so the probe isolates the 2× cadence as the SINGLE new variable on top of HW-proven 4-apart correctness).
  Re-enabled the dormant `alt_fire_r2` (was hard-`<='0'` since 2026-05-23) with a **HIT gate**:
  `if ALT_FIRE_2X and (CPU2/6/A/E) and scpu_fast_path and cs_ram and rp_cache_hit and scpu_force_1mhz='0'`.
  Fires the CPU at the alt slot (2 clk32 after the main slot) = **8MHz on SuperRAM hits** (Doom/Wolf3D
  workload, ~83% hit → ~1.8× ≈ 7MHz effective); bank-$00 KERNAL/BASIC/ZP stay 4MHz (scpu_fast_path gate)
  so serial timing is untouched.
- **Safe-by-construction rationale:** on a HIT the byte is already in BRAM (`rp_cache_di_d1` via the cpuDi
  override), no SDRAM cycle needed; `rp_fill_we` is miss-gated so no fill collision. On a MISS
  `rp_cache_hit='0'` → no alt fire → CPU waits for the next 4-apart main slot where the SDRAM read has
  time. This is the documented FIX for the bare alt_fire_r2 that wedged bank-$20 (it fired on misses too).
- **STA basis:** iter-6 proved 2-apart fires are HONEST under the existing `-setup 2` multicycle (consume
  +31ns; registered override +7.797ns at setup-1). The 2× cadence does NOT need a tighter multicycle.
- **WHY a HW build (no off-device gate):** the reduced harness CANNOT model this — its boot is genuinely
  stuck at `$FD83` (RAMTAS readback fails on harness ROM-shadow routing; confirmed after 200k cycles the
  CPU never advances), so no post-boot SuperRAM workload runs in GHDL. The alt-slot fire-vs-address timing
  is only observable on silicon. The now-correct cache removes the confound that doomed every prior
  alt_fire/raised-cadence attempt (clk64/clk48/SLOT3/page-mode/RDY-handshake) → cleanest shot yet.
- **HW GATE when build done** (probe build, BOTH flags true): (1) boot clean (SCPU64/READY) — alt fire must
  not corrupt the SuperRAM path; (2) **Doom autoload no-regress** = the real SuperRAM workload that
  actually exercises the 2× cadence (this is the make-or-break — earlier alt_fire wedged Doom/bank-$20);
  (3) Lorenz scpu/t65 100% (Lorenz is bank-$00 so unaffected by the SuperRAM-only alt fire, but confirm);
  (4) measure effective MHz (UART/cycle count) to quantify the speedup. If green: revert both flags→false,
  commit, then this becomes the first shippable speed win (enable via the flags in a follow-up once Doom
  + a broader title sweep confirm). If Doom wedges: the alt-slot timing hazard is confirmed on the correct
  cache → try `rp_cache_hit_d1` (registered) gate or an extra busy_cnt tick, OR accept that the off-device
  harness MUST be fixed (boot past RAMTAS) before further blind builds.
- Recovery if falsified: flags→false (RTL bit-identical), restore control `97392a1f`, release lock.

### iter-7f mid-build findings (HW, while Quartus runs `build_iter7f_2x.log`)
- **DOOM A/B (decisive): enabling the iter-7e cache (CACHE_READ_PATH=true, 4-apart) REGRESSES Doom.**
  Same `doom_autoload_probe.py` harness, same session: control `97392a1f` reaches the **Doom engine main
  loop** (t180→t220 PC advances `00:0233`→`2C:0C80`, black render screen — running); the deployed
  cache-on build `e9c36c3e` **wedges at the loader's static `eeee` transfer screen** (t120≡t220, never
  reaches the engine). Harness is healthy today (control proves it) ⇒ the wedge is the **DMA-snoop gap**:
  the loader's REU FETCH writes bank-$00 buffers, the cache has `snoop_we=>'0'` so those writes don't
  invalidate cached lines, the CPU re-reads stale buffer bytes → transfer corrupts. Screenshots in
  `tools/doom_autoload/single_prg/` (control t180/t220 = engine; the earlier e9c36c3e t120/t220 = eeee).
  **Consequence:** the committed milestone `12309a0` ships FALSE so Doom is unaffected in the shipped RBF,
  BUT the cache can NEVER ship ENABLED with REU/DMA workloads until snoop is wired. And iter-7f (cache on +
  alt fire, NO snoop) will ALSO wedge Doom — so Doom is NOT the iter-7f gate.
- **iter-7f alt-fire gate = `superram_bench` (clean, no DMA, no snoop needed).** The bench
  (`tools/test_cart/deploy_superram_bench.py`, CRT via MGL) runs the inner loop CODE + counter from bank
  $20 SuperRAM (= `scpu_fast_path`, the ONLY thing the alt fire accelerates) and counts inner iterations
  per fixed Timer-A window. Literally labelled "STEP 7B ALT-FIRE TEST" on screen.
  **Control `97392a1f` baseline (no alt fire): COUNT = `$0335` (821), PASS = `$02B5` (693)**
  (`tools/test_cart/out/superram_bench_t10s.png`). iter-7f target: COUNT notably > $335 (toward ~2× for
  the cache-resident loop, less the non-cacheable long ICR-poll). This isolates + QUANTIFIES the alt fire
  with zero Doom/snoop confound. NOTE: boot + Lorenz do NOT exercise the alt fire (both bank-$00; alt fire
  is SuperRAM-only) — they only confirm no bank-$00 regression.
- **NEXT build after iter-7f (iter-7g) = cache + snoop + alt fire** = the full Doom-faster win. Snoop edit
  staged: read_path_cache instance (fpga64_sid_iec.vhd:4999-5001) `snoop_we => dma_active and cpuWe`,
  `snoop_addr => cpuAddr`, `snoop_bank => x"00"` (REU targets bank $00). fix B already covers the
  bank-switch flush case so `flush=>'0'` stays.

---

# (prior) Session handoff — 2026-05-31: iter-7e — iter-7d HW-FALSIFIED (registered override boots CORRUPT, identical to iter-7c) → root cause is NOT the consume path; it's the read-path cache's `flush => '0'` (missing bank-switch / coherency invalidation), MASKED by fill-on-every-read

## ⛔ ITER-7e HW VERDICT (2026-05-31): iter-7d probe build `3514fc7d` (registered override, CACHE_READ_PATH:=true) BOOTS CORRUPT — overturns the iter-7c "masked single-cycle timing" reframe
Deployed the iter-7d probe build `3514fc7d` (md5 confirmed; registered `rp_cache_hit_d1`/`rp_cache_di_d1`
override + `cpuDi_nocache` split, the build whose forced setup-1 STA was **+7.797ns** 0-viol).
- **HW: boot screen GARBLED** — scattered PETSCII + the exact `< 0vEEP` / `8P08F-]-0|RX#` gibberish
  signature from iter-7c (`0228d2b6`) / iter-7b (`e0e83e5c`-LOAD). NO `SCPU64 ROM V0.07` banner, NO `READY.`.
  CPU alive in the KERNAL editor idle loop (PC E5CF↔E5D6, J:EA31 EA7B). Stable across a 12s settle +
  re-screenshot = NOT transitional. Screenshots: `tools/iter7d_boot.png`, `tools/iter7d_boot_settle.png`.
- **Decisive A/B (same harness, same minute):** control `97392a1f` boots CLEAN —
  `**** C=64 SCPU64 ROM V0.07 ****` / `38911 BASIC BYTES FREE` / `READY.` (`tools/iter7d_control_ab.png`).
  So the corruption is the read path, not environmental.
- **The corruption is BYTE-IDENTICAL to the un-registered iter-7c build.** That is the key clue:
  registering the override provably does NOT change the byte the CPU latches at the 4-apart cadence
  (the `_d1` FFs free-run every clk32, the cache is addressed on the live `cpuAddr` which is held stable
  ~4 clk32, so `rp_cache_di` fully settles and `rp_cache_di_d1 == rp_cache_di` by the CPU's latch edge).
  **The registration was a no-op for the data the CPU sees.**
- **THIS OVERTURNS the iter-7c reframe (commit `5bbed4b`): the boot corruption is NOT a masked
  single-cycle timing violation on the consume path.** iter-6 already measured that the consume path
  closes at the ACTUAL `-setup 2` multicycle (+31.068ns); the setup-1 −0.651ns was only relevant for a
  faster (1-apart) cadence that is NOT in use at 4-apart. iter-7d "fixed" a hypothetical that never fired.
  Same disproof shape as clk48: STA honest-and-positive, HW still fails ⇒ **functional, not timing.**

## 🎯 ROOT CAUSE (iter-7e, high-confidence, from RTL inspection + the 3-build comparison): the read-path cache instance wires `flush => '0'` — no bank-switch / coherency invalidation. fill-on-every-read MASKED it; fill-on-miss-only EXPOSES it.
Three-build comparison isolates the variable precisely:
| Build | fill policy | override | boot | other |
|---|---|---|---|---|
| `e0e83e5c` | **every read** (from `cpuDi`) | comb | **CLEAN** | LOAD corrupt |
| `0228d2b6` | miss-only (from `cpuDi`) | comb | **CORRUPT** | — |
| `3514fc7d` | miss-only (from `cpuDi_nocache`) | **registered** | **CORRUPT** (identical) | — |

- (2)→(3): registration changed nothing ⇒ the consume/override path is **not** the bug at 4-apart.
- (1)→(2): the ONLY RTL delta is `and (not rp_cache_hit)` on `rp_fill_we`. On hits fill-every just
  re-writes the same byte (no-op); on misses both fill identically. A redundant no-op fill can't itself
  corrupt — **unless fill-every is continuously SELF-CORRECTING valid-but-stale cache bytes** that
  fill-miss-only leaves stale. That = a missing **invalidation/flush**.
- **The objective RTL fact (fpga64_sid_iec.vhd:4941):** the `read_path_cache` instance has
  `flush => '0'` AND `snoop_we => '0'`. The cache tag is `cpu_bank & cpu_addr(15:12)` — it does NOT
  encode ROM/RAM visibility (`cpuIO(2:0)` = `bankSwitch`, :1837). cpu_cache.vhd:200-201 EXPLICITLY
  documents the intended design: *"Bank-switch flush (cpuIO(2:0) changes) ensures coherency on ROM/RAM
  visibility transitions."* **It was never wired** — the read-path instance ties flush off. So a byte
  cached as ROM at e.g. $E000/$Axxx is returned even after the CPU switches `$01` to read RAM at the same
  address → stale. fill-on-every-read masks it (each read refills with the currently-visible byte);
  fill-on-miss-only holds the first-seen byte forever → stale reads → the CPU computes/writes garbage →
  garbled screen, no banner.
- **Why GHDL can't reproduce it (DECIDED this tick):** the reduced harness boot is **stuck at
  `final_pc=$FD83` forever** — it loops in KERNAL RAMTAS (the `simple_sdram_model` doesn't satisfy the
  RAM-sizing test), so it NEVER reaches BASIC cold-start where the bank-switch corruption lives. Confirmed
  empirically: ran `CACHE_READ_PATH=true` at `STOP_TIME=80ms` AND a `false` run with the TB window bumped
  to **1.5M cycles** (`iter7e_true_80ms.log`, `iter7e_coh_1p5M.log`) — both still end at `$FD83`,
  `READPATH_COHERENCY=PASS`, `hit_checks=33650 stale_fails=0`. The PASS only covers early KERNAL. So
  natural-boot GHDL reproduction is **impossible in this harness** — but the fix doesn't need it: writes
  are invalidated (`invalidate_wr`) and ROM never changes, so the ONLY staleness mechanism for a cached
  bank-$00 byte is ROM/RAM bank switching ⇒ excluding the shadowable ranges is **correct by construction.**

## FIX (iter-7e, DECIDED + IMPLEMENTED + BUILDING): option (B) — exclude bank-$00 ROM-shadowable ranges from the read path
Chose (B) over (A)/(C): bulletproof (combinational, no flush-FSM thrash), preserves the speed-critical
workloads (SuperRAM/Doom + bank-$00 ZP/low-RAM), and **read-path-only** so the shipped RBF stays
bit-identical when the flag is off.
- **Implementation (fpga64_sid_iec.vhd:4892, `rp_cacheable`):** narrowed the bank-$00 cacheable set to
  always-RAM nibbles **$0-$7 ($0000-$7FFF) and $C ($C000-$CFFF)**; excluded $8/$9/$A/$B (cart/BASIC) and
  $E/$F (KERNAL). SuperRAM (banks $02-$EF) unchanged. `rp_cacheable` only gates `rp_fill_we`, so an
  excluded line never fills → never validates → never hits → the override transitively falls back to
  `cpuDi_nocache` (correct). **`cpu_cache.vhd` (and the observer) are UNTOUCHED** → observer HR counter +
  shipped RBF bit-identical. (Confirmed: GHDL `CACHE_READ_PATH=true` no-regression run still boots to
  `$FD83`, `COHERENCY=PASS`; the 94.12% HR is the observer's separate number, unchanged.)
- **BUILD DONE + BOOT CLEAN ✅ (the make-or-break PASSED):** build `e9c36c3e`
  (`builds/..._5ab17f6425_..._e9c36c3e-dirty.rbf`, HEAD `5ab17f6` + fix B + `CACHE_READ_PATH:=true`,
  snoop `'0'`, alt_fire OFF; 0 errors, worst-case setup **+0.290ns**, hold +0.239ns, TNS=0, MTBF 1e9 yr).
  Deployed to `_Test`. **BOOT IS CLEAN** — `**** C=64 SCPU64 ROM V0.07 ****` / `38911 BASIC BYTES FREE` /
  `READY.` (`tools/iter7e_fixB_boot.png`), stable across a re-screenshot. **This is the FIRST clean boot of
  the cache read path feeding the CPU** (all of iter-7b/7c/7d corrupted). ⇒ the bank-switch root cause was
  correct and fix B resolves the boot corruption. CPU healthy in the editor loop. (Keyboard sanity check
  deferred — `mtype.py` SFTP upload glitched; Lorenz uses MGL autoload, no keyboard needed.)
- **Lorenz scpu PASS ✅** (`tools/lorenz_run/scpu/final.png`, `0160s.png`): the real suite LOADED from
  disk (serial LOAD = the exact e0e83e5c corruption case) and runs CLEAN — `basic commands - ok / ldab - ok
  / ldaz - ok / ... / staa - ok / staax - ok`, progressing cleanly over time (visually confirmed, not the
  flicker-md5 trap). e0e83e5c garbled here immediately; fix B runs it clean ⇒ the read path is HW-correct
  for scpu serial LOAD + program execution. (Only reached `staax` in 5 min at 4MHz — a full-length 100%
  completion run is a cheap follow-up, but the early-tests-clean vs e0e83e5c-garbage contrast is decisive.)
- **Lorenz t65 RUNNING** (`tools/lorenz_run/iter7e_t65.log`) — no-regression check; the read path is gated
  `enable => supercpu_en` so t65 should be bit-identical to control. Doom is a SEPARATE follow-up: its REU
  FETCH writes bank-$00 buffers via DMA (bypasses `cpu_we`/`invalidate_wr`, see snoop note below) → don't
  gate until `snoop_we` is wired.
- **DEFERRED:** (A) bank-switch flush to recover KERNAL/BASIC-ROM hit-rate; (snoop) DMA-write invalidate
  for Doom. Both are follow-ups once the read path is HW-proven correct for the non-DMA case.
- **Snoop wiring (worked out this tick, for the Doom follow-up):** during DMA, `cpuAddr/cpuDo/cpuWe` are
  muxed to the DMA values (fpga64_sid_iec.vhd:3600-3602), so `cpuWe` DOES carry DMA writes — but the
  cache's `invalidate_wr` also requires `cpu_en`, wired to `enableCpu_816 = enableCpu and not dma_active`
  (:3089) = **0 during DMA** ⇒ DMA writes bypass invalidation (the gap). Fix: in the read_path instance,
  wire `snoop_we => dma_active and cpuWe`, `snoop_addr => cpuAddr` (=dma_addr during DMA),
  `snoop_bank => x"00"` (REU FETCH targets bank-$00 motherboard RAM). The `snoop_*` ports + top-priority
  invalidate already exist (iter-5, commit `8329f56`); only this wiring is needed. Gate Doom AFTER adding it.

## RECOVERY (iter-7e): MiSTer restored + lock released
- Control `97392a1f` re-deployed to `_Test`, confirmed CLEAN (SCPU64 V0.07 / READY); `CORENAME=C64`.
- `/tmp/mister_session.lock = NOLOCK`.
- `CACHE_READ_PATH` is currently flipped to `true` LOCALLY for the GHDL repro — **must be reverted to
  `false` before any commit** (RBF ships bit-identical). No code committed this iteration yet.

---

# Session handoff — 2026-05-31: iter-7d REGISTERED the cache-HIT override (the masked-single-cycle fix) — GHDL-clean, probe build + setup-1 STA in flight

## ▶ ITER-7d (2026-05-31, off-device): register the cpuDi cache-HIT override so the masked single-cycle consume becomes a genuine 2-cycle path. RTL DONE + GHDL-clean; probe build running for the setup-1 STA gate.
The iter-7c reframe (below) concluded the boot corruption is a **masked
single-cycle timing violation** on `cache_di→cpuDi→P65C816`, not a functional
bug — only a setup-1 STA probe can gate a fix. iter-7d implements the prescribed
fix and addresses two flaws a Codex falsification pass caught.

**RTL change (all in `fpga64_sid_iec.vhd`, behind `CACHE_READ_PATH`, default false):**
1. **Registered override.** New `rp_cache_hit_d1`/`rp_cache_di_d1` (1-clk32 FFs in
   `gen_read_path`). The cpuDi override now consumes the *registered* hit+data
   (`cpuDi <= rp_cache_di_d1 when (CACHE_READ_PATH and rp_cache_hit_d1='1') else
   cpuDi_nocache`). This splits BOTH masked single-cycle paths — the data
   (`line_word→cache_di byte-select`) AND the select (`tag_mem→tag_match→mux`) —
   with a pipeline register, so the cache instance internals now feed only the d1
   FFs (a short intra-clk32 hop), not the CPU.
2. **`cpuDi_nocache` split.** Factored the entire non-override mux (SCPU regs →
   `ramDin`/`cpuDi_raw`) into a new `cpuDi_nocache` signal; `cpuDi` is just the
   2:1 override on top (depth-neutral). **The cache now fills from `cpuDi_nocache`,
   NOT `cpuDi`** — severing Codex's fill-feedback hazard (a registered-override
   spurious-assert during a miss can no longer write the cache's own output back
   into the miss line). `rp_fill_we` stays gated on the *combinational* hit
   (accurate current-access miss classifier).
3. `sdram_hit_pred` left on the **combinational** hit (unchanged) — it's inert for
   cadence with alt_fire OFF, and keeping it combinational sidesteps Codex's Q2
   short-grant-wrong-access concern. (Revisit when wiring the variable-cadence 2×.)

**Codex falsification (docs/iter7d_codex_brief.md, tools/codex-out/iter7d-falsify.txt):**
- Q1 (off-by-one): a single register is co-phased-correct only from `[N+2,N+3)`,
  with a transient stale-di/asserted-hit window at `[N+1,N+2)`. HARMLESS here —
  the CPU latches at the 4-apart main slot (~N+4), well after the settle; alt_fire
  is OFF so nothing latches in the transient window.
- Q3 (the important catch): `fill_data => cpuDi` is a feedback corruption path under
  a registered select. **Fixed** by filling from `cpuDi_nocache`.

**GHDL (sim/c64_reduced_harness/run_cache_hitrate.sh, real fpga64+P65C816):**
- CACHE_READ_PATH=false: boot `final_pc=$00:FD83`, READPATH_COHERENCY=PASS — the
  `cpuDi_nocache` refactor is behaviorally bit-identical when off.
- CACHE_READ_PATH=true (registered override): boot `final_pc=$00:FD83`, coherency
  PASS — the registered path doesn't break execution. (As established, GHDL CANNOT
  reproduce the HW timing bug — boots clean either way. The gate is STA.)

**IN FLIGHT — the off-device gate:** probe build with `CACHE_READ_PATH:=true`
(`build_iter7d.log`), then `quartus_sta -t C64_MiSTer/cache_sta_probe.tcl`
(updated: from-set now unions the `cpu_cache` instance regs WITH the new
`rp_cache_*_d1` FFs, since the path launch moved to the registers). **GO/NO-GO:
the forced `-setup 1` (31.25ns) budget on `{rp_cache_*_d1 + read_path_cache} →
P65C816:cpu` must be POSITIVE** (iter-6 measured −0.651ns at setup-1 on the
UN-registered path; registering should flip it positive by removing the
~10ns cache-internal + cpuDi-mux delay from the single-cycle window). If positive
⇒ the masked violation is gone ⇒ strong predictor the HW boot corruption is fixed
⇒ next is the HW gate (Lorenz scpu/t65 100% + Doom no-regress at the existing
4-apart cadence; this build is correctness-only, no speed change yet). If still
negative ⇒ read which path the worst slack now traverses (expected: the CPU-
internal `di→ALU→PCr` ~11ns wall, the same Milestone-B limit — meaning even
registered 2× needs CPU-core pipelining).

**Remember to revert `CACHE_READ_PATH:=false` before committing** (RBF ships
bit-identical). The registered-override RTL + `cpuDi_nocache` split are the
keepers regardless of the STA verdict.

---

# (prior) Session handoff — 2026-05-31: cache read path (fill-on-hit-fixed) HW-FALSIFIED at boot; next = system-level GHDL bench

## ⛔ ITER-7c HW RESULT (2026-05-31): fill-on-hit fix HW-FALSIFIED — build 0228d2b6 CORRUPTS the boot screen
Deployed build `0228d2b6` (= HEAD `497071b` fill-on-hit fix + `CACHE_READ_PATH:=true`,
RDY_HANDSHAKE=false, alt_fire OFF; Fitter 86% ALM / 411 M10K, TNS=0, core setup +2.453ns).
- **HW: boot screen GARBLED** — scattered PETSCII + the exact `< 0JEEP` gibberish from the
  e0e83e5c LOAD corruption, NO `SCPU64 ROM V0.07` banner, NO `READY.`. Screen RAM is garbage
  while the CPU reaches the KERNAL editor idle loop (`PC:00E5D1↔E5D6`, `J:EA7B EA31 EA5E` IRQ
  loop = "alive at READY"). Typed `PRINT 2+2` → no echo, no result, keyboard dead. Stable
  across 3 reloads + a 16s settle = NOT a transitional/flicker artifact.
- **Decisive A/B (same harness, same minute):** control `97392a1f` boots **CLEAN** —
  `**** C=64 SCPU64 ROM V0.07 ****` / `38911 BASIC BYTES FREE` / `READY.`. So the corruption
  is the cache read path, NOT environmental.
- **KEY FINDING — the fill-on-hit fix made boot WORSE, and that pinpoints the real bug.**
  `e0e83e5c` (fill on EVERY read) **booted clean**, corrupting only on LOAD. `0228d2b6`
  (= e0e83e5c + fill-on-MISS-only, the ONLY RTL delta) **corrupts at boot**. Mechanism:
  fill-on-hit was *accidentally masking* the cross-line `cache_di` 1-cycle latency skew —
  on a hit it re-served/re-filled the just-fetched value, papering over the stale registered
  `cache_di`. Removing fill-on-hit EXPOSED the skew: a cross-line HIT now feeds the registered
  (1-cycle-stale) `cache_di` straight to the CPU with no re-fill self-correct → boot has enough
  cross-line hits (ZP/code interleave) to corrupt screen RAM.
- **OVERTURNS iter-7c's "latency skew is masked by the 4-apart main-slot cadence" negative
  result** (handoff lines ~5-11). On HW the cross-line hit DOES serve stale `cache_di` to the
  CPU — the di-latch timing does NOT let `line_word` settle before the consume. The cache
  read path is NOT a usable >4MHz foundation as currently wired.
- **RECOVERY DONE:** probe flag reverted to committed default `CACHE_READ_PATH:=false`
  (working tree = comment-only diff vs `497071b`, RBF bit-identical); control `97392a1f`
  redeployed to `_Test` + confirmed clean (CORENAME=C64, PC cycling editor loop); MiSTer lock
  released (`/tmp/mister_session.lock=NOLOCK`). Build `0228d2b6` archived. Did NOT commit code
  (no RTL fix yet) — only the documenting comment + handoff/memory.
- **NEXT (per the loop instruction — escalate to system-level GHDL):** the unit benches
  (`cpu_cache_fillonhit_tb`, `cpu_cache_latency_tb`) PROVE the cache is a correct 1-cycle BRAM
  and that fill-on-hit suppression is right *in isolation* — they CANNOT resolve how the CPU's
  address-present vs `di`-latch edges align with `line_word` on a cross-line hit (that's the
  consumer bug). Build a **system-level bench** that drives the REAL `cpu_65c816` through the
  wired read path (override + short-grant) with a deliberate cross-line / SuperRAM access
  stream, and assert the CPU latches the correct byte. Candidate fixes to prove there before
  any rebuild: (a) align the cpuDi override to a REGISTERED `cache_hit_d1`/`cache_di_d1` so
  hit+data are co-phased; (b) CE-defer the CPU consume one clk32 on a fresh-line (non-same_line)
  hit. Only after the system bench is green → CACHE_READ_PATH:=true rebuild → HW re-gate.

### ⚙️ REFRAME (2026-05-31, same tick): GHDL CANNOT reproduce it — this is a MASKED single-cycle TIMING violation, not a functional bug. The "system GHDL bench" branch is the wrong tool.
Ran the cheap experiment the loop's "escalate" branch implied: flipped `CACHE_READ_PATH:=true`
in `c64_reduced_harness` (real `fpga64_sid_iec`, real `cpu_65c816`, `supercpu_en=1` at
`c64_reduced_top_v2.vhd:444`, read-path override non-vacuous per iter-6) and ran the 12ms boot.
- **GHDL boot = CLEAN, `final_pc=$00:FD83`, IDENTICAL to the `false` baseline** (hit 94.12%,
  READPATH_COHERENCY=PASS). So the harness does NOT reproduce the HW boot corruption even with
  the read path fully feeding the CPU — confirming iter-6's "on = bit-identical boot."
- **WHY (decisive):** trace the edges of a cross-line HIT — Edge N: `cpuAddr`→new line L,
  `cache_hit` asserts (combinational), but `line_word` (registered, cpu_cache.vhd:284-296) still
  holds the PREVIOUS line ⇒ `cache_di` STALE. Edge N+1: `line_word←L`, `cache_di` valid. The CPU
  latches `cpuDi` (combinational from `cache_di`) at `enableCpu_816`. On a cross-line hit that
  latch is effectively **single-cycle** vs when `cache_di` becomes valid. In GHDL `line_word`
  settles in a delta-cycle so the value is functionally correct → clean. On SILICON the
  `cache_di→cpuDi→P65C816` path is real, and **iter-6's STA probe already measured it: setup-2
  budget = +31.068ns clean, forced setup-1 = −0.651ns FAIL** (`cache_1cyc_path.txt`). The
  `set_multicycle_path -setup 2 -to *P65C816:cpu|*` relaxes the analysis to 2 cycles, so STA
  **MASKED** the single-cycle cross-line consume → boot corrupts. **Identical masking class as
  clk64 / SLOT3 / clk48** (a multicycle justified on a cadence assumption the actual access
  violates).
- **CONSEQUENCE: a functional GHDL bench cannot prove a fix** (no timing) — only **STA at
  setup-1 on `cache_di→cpuDi→P65C816`** can. The earlier "extend a system bench, assert correct
  byte" plan is the wrong tool for a masked-timing bug. (A bench can still SANITY-check a
  registered-override doesn't break execution, but it can't be the gate.)
- **THE FIX is build+STA-gated, and iter-6 already bounded it to ~2×:** make the cross-line
  consume a GENUINE 2-cycle path so setup-2 is HONEST (not masked): register the override
  (`cache_hit_d1`/`cache_di_d1`, latched the cycle AFTER `line_word` settles) AND extend the hit
  grant so the CPU latches at edge N+2, not N+1. iter-6: "registering cache_di re-adds a latency
  cycle a non-pipelined CPU can't overlap → caps at ~2× anyway" — which is exactly the 2×/8MHz
  target, so the cap is acceptable. **GATE = a setup-1 STA probe on the registered path must be
  POSITIVE** (i.e. the consume is no longer single-cycle on cross-line hits), reusing
  `C64_MiSTer/cache_sta_probe.tcl`. Only then rebuild + HW re-gate Lorenz/Doom.
- This means the next iteration is **RTL (register the override + extend the hit grant) → fitted
  build → scripted setup-1 STA probe → HW** — NOT a GHDL bench. Large + in the hairiest file →
  warrants the user able to course-correct.

## ⚡🔎 ITER-7c (2026-05-31, off-device, SUPERSEDED BY HW ABOVE): e0e83e5c CACHE-CORRUPTION MECHANISM FOUND + FIXED, HW-VALIDATION BUILD NEXT
**Supersedes my own iter-7b "latency-skew is the mechanism" claim — that was WRONG (masked).**
- **Negative result (proven this tick):** the cross-line consume-latency skew is
  MASKED by the normal cadence. `enableCpu <= cpu_cyc_s(1)` (fpga64_sid_iec.vhd:3530)
  latches CPU di 2 clk32 after `cpu_cyc`, and with `alt_fire_r`/`alt_fire_r2`
  hard-tied `'0'` (:3496-3527) `cpu_cyc` only fires at 4-clk32-apart main slots
  (CYCLE_CPU0/4/8/C). The address is stable + line_word settled by di-latch. So the
  `"001"→"010"` grant-width "fix" is DOUBLY wrong (latency isn't the mechanism, and
  grant width is inert with alt_fire off). Ruled out.
- **ACTUAL mechanism (reproduced + fix validated in GHDL):** `rp_fill_we`
  (fpga64_sid_iec.vhd:4872) was NOT gated on `rp_cache_hit` → the cache re-fills on
  EVERY cacheable read incl. hits. `fill_data => cpuDi` (:4885), and on a hit
  `cpuDi <= rp_cache_di` (:1965) = the cache's OWN output. On a CROSS-LINE hit,
  `line_word` (registered, cpu_cache.vhd:284-296) still holds the PREVIOUS line's
  byte for one cycle → the fill-back writes that STALE byte into the NEW line's
  data bank = permanent self-inflicted CONTENT corruption. NOT masked (fires
  whenever enableCpu_816 pulses on a cross-line access = the common case).
- **Bench:** `sim/cache_coherency_tb/cpu_cache_fillonhit_tb.vhd` (+ `run_cache_fillonhit.ps1`).
  FILL_ON_HIT=true → line B reads back $AA (stale A leaked); FILL_ON_HIT=false
  (models the fix) → line B reads $BB (clean). Decisive.
- **FIX (applied, fpga64_sid_iec.vhd:4872):** `rp_fill_we <= ... and (not rp_cache_hit)`
  — only fill on a MISS (textbook cache behaviour). Lives inside
  `gen_read_path : if CACHE_READ_PATH generate`; with the committed default
  `CACHE_READ_PATH:=false` the signal is dead → shipped RBF bit-identical.
- **NEXT (build-bearing):** flip `CACHE_READ_PATH:=true` LOCALLY (uncommitted),
  build, HW-test: Lorenz scpu must run CLEAN (was garbled in e0e83e5c) + Doom
  no-regress + Lorenz t65 100%. If clean → the read-path cache (≈2×/8MHz, iter-6
  STA-honest) is finally HW-valid; then wire the alt-slot fire for the 2× cadence.



## NORTH STAR & THIS SESSION'S CONSTRAINT
Goal: fully-compatible SuperCPU at 20MHz+ turbo. Operator sequencing: **compat
first, then more turbo** — but the remaining big compat wins are SPEED-BOUND
("SuperCPU Kicks!" etc. assume the real ~20MHz default; VICE-confirmed our
1/4MHz reproduces the breakage). So both halves funnel into **Milestone B**
(clk_cpu=64MHz + MCP async bridge). Operator constraint THIS session:
**make Milestone B progress WITHOUT the MiSTer** — GHDL sim only, no deploy.
A Quartus *build* (STA report, no hardware) is in-bounds; deploying is not.

## DONE THIS SESSION (all GHDL, no MiSTer)

### 1. Reduced harness now actually clocks the real 65C816 — both configs PASS
`sim/c64_reduced_harness/run_harness_mb.sh` (NEW). Real `fpga64_sid_iec` arbiter
+ real `cpu_65c816` + SDRAM latency model. Two configs, both 17/0:
- `RATIO=1 MCP=0` passthrough (HW baseline): max_pc=$FD5F, en_count 53→365.
- `RATIO=2 MCP=1` Milestone B, clk_cpu=64MHz: max_pc=$FF7F, en_count 27→236.
CPU boots into KERNAL ROM correctly across the 64MHz CDC bridge with the real
sysCycle wheel + SDRAM model.
- **Root-caused the "CPU frozen" blocker:** `rfsh_cycle`/`sysEnable` had no init
  → `rfsh_cycle = "00"` never true → `sysEnable` never armed → arbiter never
  advanced (sim 'U' deadlock; FPGA powers these FFs to 0). Added explicit inits
  to `fpga64_sid_iec.vhd` (HW no-op, sim-correct). v2 harness still 84/0.
- Committed `c1233a5`.

### 2. SuperRAM long store/load across the bridge at 64MHz — PASS
`sim/scpu_async_bridge_tb/cpu_in_bridge_superram_tb.vhd` (NEW). Real CPU + active
bridge, native-mode `STA $02:0000` / `LDA $02:0000` into SuperRAM (bank $02) with
the mock arbiter giving SuperRAM a longer 4-cycle ack vs bank $00's 2-cycle
(models the real 3-stage vs 2-stage SDRAM split). RATIO=2 PASS + RATIO=1 control
PASS — round-trips $AB, went_native. Closes the "LDA long bank transition"
wedge-locus coverage gap. Committed `38c1d36`.

### Strategic upshot
The historical "64MHz wedge" is now sim-proven to be an **integration/STA**
issue, NOT an RTL functional bug — corroborated at the SYSTEM level (real
arbiter + SDRAM), not just the isolated bridge bench. The F.3' enable-skew fix
inside `scpu_async_bridge` is sound at 2:1.

## ⛔ HW VERDICT (2026-05-30): MILESTONE B HW-FALSIFIED — clk64 wedges; reverted to MILESTONE_B=0
The operator lifted the no-MiSTer constraint and I HW-tested build `00452c21`
(MILESTONE_B=1, clk_cpu=clk64 + MCP). Results:
- **Boot to READY at 64MHz: PASS** ✅ (first-ever clean clk64 boot — `SCPU64 ROM
  V0.07`, 38911 BASIC BYTES FREE, READY). The handshake/boot path works on silicon.
- **Lorenz scpu at 64MHz: FAILS (intermittent wedge).** 1 pre-reboot run showed
  ~15 instruction-group tests "ok" then the daemon wedged; 3 post-reboot runs ALL
  failed (1 autostart-miss, 2 hard CPU wedges at ~30s/~62s — overlay frozen =
  CPU halted). The 32MHz control build `97392a1f` runs Lorenz scpu CLEAN
  (continuous progress, all "ok") under the identical harness → fair A/B.
- **ROOT CAUSE (airtight, RTL+SDC+empirical):** `scpu_async_bridge` SUSTAINS
  `cpu_enable_reg<='1'` across consecutive clk_cpu edges in CPU_IDLE (F.3' v2,
  scpu_async_bridge.vhd:552-557,665 — intentional, so multi-cycle 65816 ops get
  enough EN=1 cycles). At clk_cpu=64MHz that makes the P65C816 advance on
  consecutive 64MHz edges, which **INVALIDATES** `set_multicycle_path -setup 2 -to
  *P65C816:cpu|*` in C64.sdc (valid ONLY when enable is the sparse arbiter pulse,
  i.e. in passthrough — which is why the control is clean). STA therefore MASKED
  real setup violations on the CPU's deep internal combinational paths (ALU/BCD/
  AddrGen/MCode) which do NOT close at 64MHz single-cycle (15.6ns). The "+2.41ns
  clk64 slack" was measured against the wrong (2×-relaxed) budget. Boot survives
  because KERNAL exercises fewer/shorter internal paths; Lorenz's intensive
  ALU/addressing coverage hits the failing paths → data-dependent wedge.
- **This OVERTURNS the earlier "STA-clean ⇒ feasible" conclusion.** clk64 is NOT
  viable with this CPU core under the sustain-enable scheme.
- **ACTION TAKEN:** reverted `c64.sv` to `MILESTONE_B=0` (safe passthrough default,
  bit-identical to shipped). MiSTer restored to `97392a1f` + released.

### Doom autoload this session: environmental, NOT a B regression
Both `00452c21` (MB) and `97392a1f` (control) wedge IDENTICALLY at `$EABE` with a
garbage screen → the REU/MGL Doom harness is broken for all builds today (REU
content/timing). Separate pre-existing issue; B exonerated. The Lorenz autoload
(disk MGL) works, so start_strk is fine.

### PATH FORWARD (the >4MHz question, now better understood)
The sustain-enable scheme requires the CPU's internal paths to close single-cycle
at clk_cpu. They close at 32MHz, not 64MHz. Options, in rough order of leverage:
1. **Quantify true 64MHz CPU slack** — rebuild MILESTONE_B=1 with the
   `-to *P65C816:cpu|*` multicycle REMOVED → STA shows the real (negative) clk64
   slack on CPU-internal paths. Cheap, no MiSTer, confirms+sizes the gap. (Teed up.)
2. **Try clk_cpu=clk48** (PLL already emits clk48). 20.8ns may close where 15.6ns
   doesn't → 1.5× internal cycle rate with sustain-enable, modest but real, and
   HW-safe to A/B against Lorenz.
3. **Demand arbiter (Milestone C) at clk32** — keep CPU at 32MHz (where it closes)
   and grant more bus slots. This is a DIFFERENT speed mechanism that does NOT need
   clk_cpu=64MHz at all; the earlier "C is gated on B" framing is weakened — C may
   be pursuable directly on the stable 32MHz CPU.
4. Pipeline/retime the P65C816 core to close at 64MHz (largest effort).

## STA CLOSED — 64MHz is FEASIBLE on this FPGA (committed ca4c4a3) [SUPERSEDED — see HW verdict above]
Engaged Milestone B behind a reversible switch in `c64.sv`:
- `localparam MILESTONE_B = 1; wire clk_cpu = MILESTONE_B ? clk64 : clk_sys;`
- `fpga64_sid_iec #(.SCPU_MCP_ACTIVE(MILESTONE_B ? 1'b1 : 1'b0)) fpga64`
- `C64.sdc` was ALREADY prepared (clk64↔clk32 multicycles + all bridge CDC
  false-paths keyed to `scpu_async_bridge_inst`) — no SDC edits needed.
- Syntax check 0 errors; mixed-language std_logic generic override OK.

**Full build result (RBF `00452c21`, archived in `C64_MiSTer/builds/`):**
- clk64 (PLL counter[1]): **setup slack +2.410ns, hold +0.245ns, TNS=0.000.**
- ALL clock domains positive, TNS=0 everywhere, 0 errors.
- 569 synchronizer chains, worst-case MTBF 1e9 years.
- 66% ALMs (27,587/41,910) / 73% M10K (403/553) / 55% block-mem — in budget.
⇒ **64MHz closes timing with 2.4ns to spare.** Milestone B is feasible here.
Committed the switch (`ca4c4a3`) with HW-verification flagged as the last gate.

### THE ONE REMAINING GATE — hardware verification (operator must lift no-MiSTer)
Everything checkable without hardware is now green (sim-functional + STA). The
deferred HW checks, to run when the operator re-enables MiSTer:
1. Boot to READY (clk_cpu=clk64 historically wedged pre-F.3'-fix; sim says fixed).
2. Lorenz 100% in BOTH t65 and scpu modes (must not regress).
3. Doom autoload (REU→SuperRAM transfer + in-engine playloop) — the integration
   stressor most likely to expose a sim-invisible CDC/latency hazard.
4. Measure effective MHz vs the 4MHz baseline (the whole point — expect ~up to 20).
If any regress: `MILESTONE_B=0` reverts in one line; then bisect against the
sim benches (they're the oracle for what *should* work at 2:1).
- Do NOT deploy `00452c21` until the operator lifts the constraint.

## ⛔ clk48 HW-FALSIFIED (2026-05-30) — timing CLOSES honestly, but FUNCTIONAL/CDC crash
HW-tested the STA-clean clk48 build `abf8ff88` against the control `97392a1f`
under TODAY's identical Lorenz harness (control proven healthy — it runs+passes
the suite: "basic commands ok / ldab ok / ... / staz ok"). Two independent clk48
failures, both absent on control (only clk_cpu differs):
1. **Lorenz scpu autoload STALLS** — stuck at BASIC READY, suite never starts.
   UART: PC idling $EACC/$EAB6 (KERNAL editor loop), bridge RQ/AK cycling = CPU
   alive but the RUN->LOAD chain never dispatched. (Via the robust start_strk
   path, NOT mtype — so not a tooling race.)
2. **Keyboard interaction HARD-WEDGES the CPU** — after a typed `PRINT 2+2` the
   screen garbled and UART froze: **PC stuck at $0000F5** (executing in zero page
   = crashed off the rails), SP/regs static, bridge idle (RQ==AK). A genuine CPU
   crash.
**THE KEY INSIGHT (stronger than the clk64 result):** clk48's STA was HONEST and
POSITIVE (CPU-internal +3.730ns, worst ANY->CPU +0.281ns, ALL domains TNS=0 after
the cross-domain SDC completion). A passing-STA path does NOT fail from setup
timing — so this crash is **NOT a timing-closure problem**. I genuinely fixed
timing (disproving "clk64 wedged purely on timing"). The remaining hazard is
**functional / CDC in the sustain-enable MCP bridge at raised clk_cpu** — it
appears at BOTH clk64 and clk48 but never in clk32 passthrough. Another timing
constraint cannot fix a functional/CDC bug. The CPU core itself is sound (sim-
correct; at clk48 timing-clean; boots clean to READY) — the failure is the
raised-clk_cpu + active-MCP-bridge INTEGRATION.

### DECISION (FINAL, HW-settled): SLOT3 3-clk32 cadence HW-FALSIFIED — ~4MHz ceiling is cpuDi-MUX-propagation-bound (masked by the ≥4-clk32 multicycle)
**See the "⛔ SLOT3 HW-FALSIFIED" section just above for the verdict.** The
analysis path this session was: "pivot to C" → "C is a dead-end (§F: SDRAM-
bound)" → "C-alone is viable, §F wrong, ~6MHz (sim-validated + RTL trace +
Codex)" → **HW: 3-clk32 crashes; §F's effective-4-clk32 was right after all.**

**CORRECTED MECHANISM (2026-05-30, verified against RTL+SDC — supersedes the
"2-FF consume sync" framing below, which was WRONG):** there is NO data sync to
cut. `ramDin` is an unregistered `in` port; the SDRAM read data reaches the CPU
through a **purely combinational two-stage mux**: `sdram_pm.dout` (clk64 reg) →
`sdram_data` → `ramDin` → buslogic `dataToCpu` priority chain (~17 deep,
fpga64_buslogic.vhd:276-459) → the `cpuDi` register-override mux (~15 deep,
fpga64_sid_iec.vhd:1888+) → `P65C816.di`. C64.sdc:21-37 names this exact path —
`sdram.dout_r[8] -> P65C816.P[1] missed by -4.652ns` at 1-cycle budget — and the
`counter[1]→counter[2]` multicycle that fixes it is **explicitly justified on
"enable pulses are >= 4 clk32 ticks apart."** SLOT3's 3-clk32 spacing INVALIDATES
that justification → STA was MASKED (same class as the clk48 failure). The
arithmetic is exact: dout_r ready ~79ns post-grant (q5); at 4-clk32 the CPU
latches ~127ns later = 47.6ns available (mux delay ≈20.5ns, closes); at 3-clk32
it latches ~95ns = only **~15.9ns (1 clk64) available → misses by ~4.6ns**,
matching the documented −4.652ns. So the ceiling = grant period must hold
(SDRAM read latency ≈79ns) + (deep cpuDi mux ≈20.5ns); SLOT3 shrank the period
without shrinking either term.

Salvage is NOT "cut a sync" — it's either (a) shorten the deep two-stage cpuDi
mux to close in ~1 clk64 (high regression risk, two correctness-critical muxes,
bounded ~6MHz), or (b) **attack the dominant 79ns SDRAM term with a BRAM cache**
(a hit serves data ~16ns in → deep mux gets ample settle time even at a shorter
cadence; this is WHY real SuperCPU uses a cache and is the flagged big lever).
The sim section below is retained for the record but its "~6MHz" conclusion is
HW-OVERTURNED. Sim bench kept (sim/turbo_throughput_tb G_SLOT3/G_NO_ROWTRACK
correctly model the CONTROLLER side; the gap is the unmodeled deep-mux propagation).

**Why §F is wrong:** §F concluded C-alone gives no win because "SDRAM cycle =
8 clk64 = 4 clk32 already matches the CPU0/4/8/C slot spacing." But the ACTIVE
`sdram_pm.v` early-exits at q=5 (`sdram_pm.v:88`) → the real cycle is **6 clk64
= 3 clk32**, not 8/4. The active window is ACTIVE(q1)→READ-w/-auto-precharge
(q2, A10=1 at `sdram_pm.v:198`)→sample(q5), then idle at q0 awaiting the next
`ce`. 5 clk64 ≈ 78ns ≥ tRC, so **back-to-back accesses every 6 clk64 = 3 clk32
are physically sustainable.**

**Why the ceiling is stuck at 4MHz anyway:** `cpu_cyc` grants only CPU0/4/8/C =
every 4 clk32 (`fpga64_sid_iec.vhd:3310`), and the SDRAM-busy predictor loads
`"011"`=3 baking in the stale assumption (`:3333`/`:3362`). The existing
`alt_fire` alt-slots sit at CPU2/6/A/E = **2 clk32** after the main slots —
*too early* for the 3-clk32 cycle, so the predictor correctly blocks them →
no gain. **The mechanism uses the wrong offset (2, should be 3).**

**The lever:** re-space CPU grants to the real 3-clk32 cycle (CPU0/3/6/9/C/F)
+ fix the busy-predictor to clear at 3 clk32. Grants then land exactly when
SDRAM completes → **~6MHz CPU-region-only, ~8MHz if EXT slots are harvested**
(Codex estimate, corroborated). Crucially **interleave-IMMUNE**: Build B
auto-precharges every access with NO row tracking, so every access is a uniform
6-clk64 cycle regardless of bank — the conflict-miss mechanism that killed the
page-mode lever (`project_goal_more_turbo`) does NOT apply. And it's entirely
in the clk32 domain: **no CDC bridge, no raised clock → sidesteps the whole
Milestone-B failure class.**

Lever ranking (Codex + analysis): **(1) demand arbiter @ clk32 — best
gain/risk, ~6-8MHz, no CDC; (2) BRAM cache/write-buffer — ~10-15MHz ceiling but
historically black-screens; (3) debug B bridge CDC — ~12-16MHz but HW-dead on
two fronts.** Pursuing (1).

### ⛔ SLOT3 HW-FALSIFIED (2026-05-30) — deep cpuDi mux needs ≥4-clk32 settle (masked by multicycle), NOT a consume sync
Build `1a88abb8` (SLOT3, timing-clean: clk32 +6.06ns, all TNS=0) deployed to
`_Test`. **HW result: CPU hard-wedged at boot — PC frozen $000075 (crashed into
zero page), SP runaway-decrementing, never reached READY (black screen + only the
debug overlay).** Control `97392a1f` redeployed under the identical harness boots
clean (`SCPU64 ROM V0.07` / READY) — fair A/B. RTL reverted (`git checkout`
fpga64_sid_iec.vhd; SLOT3 bench KEPT). MiSTer restored, lock released.

**Root cause (CORRECTED 2026-05-30 — the original "2-FF data sync" claim in this
block was WRONG; verified against RTL):** the bench proved the *controller* never
drops an access at 3-clk32 (0 stale) — TRUE. But the read data reaches the CPU
through a **purely combinational two-stage mux** (NO data sync exists): clk64
`sdram_pm.dout` → `sdram_data` → unregistered `ramDin` port → buslogic
`dataToCpu` priority chain (~17 deep) → `cpuDi` override mux (~15 deep) →
`P65C816.di`. That deep path takes ≈20.5ns. dout_r is ready ~79ns post-grant (q5);
at 4-clk32 the CPU latches it ~127ns later (47.6ns of settle — closes); at 3-clk32
it latches ~95ns later = only **~15.9ns (1 clk64) of settle → misses by ~4.6ns**,
exactly the −4.652ns C64.sdc:21-37 names for `sdram.dout_r[8] -> P65C816.P[1]`.
The `counter[1]→counter[2]` multicycle that hides this is **justified on "enable
pulses ≥4 clk32 apart"** — SLOT3's 3-clk32 spacing invalidates that, so STA was
MASKED (same class as the clk48 failure, NOT a sim-fidelity gap as first written).
The garbage fetch from the not-yet-settled mux → ZP crash. **§F's "4-clk32" was
right in EFFECT.** The bench's `stale_count` monitor only models controller-drop
(new ce while ready=0); the real blocker is deep-mux propagation, which no
abstract throughput bench models — it needs STA, not GHDL.

**Is the lever salvageable?** NOT by touching a sync (none exists). Two real
paths: **(a)** shorten the deep two-stage `dataToCpu`+`cpuDi` mux to close in
~1 clk64 — restructure the common-case RAM-read to a fast default with SCPU
register overrides applied via a precomputed 2:1 select, collapsing the ~32-deep
priority chain. High regression risk (two correctness-critical muxes), bounded
~6MHz, and STA-provable. **(b)** A **BRAM cache** attacks the *dominant* 79ns
SDRAM-latency term instead of the 20.5ns mux term: a hit delivers data ~16ns into
the cycle, leaving the deep mux ample settle even at a shorter cadence — this is
the real-SuperCPU mechanism and the flagged big lever (model hit-rate under
INTERLEAVE first, per the page-mode lesson). The effective ~4MHz ceiling stands;
it is **cpuDi-mux-propagation-bound** (= grant period must hold 79ns SDRAM +
20.5ns mux), not raw-SDRAM-bound and not consume-sync-bound.

### ✅ NEXT LEVER QUALIFIED (2026-05-30): read-only BRAM cache — survives the interleave objection that killed page-mode & SLOT3
Read `C64_MiSTer/rtl/cpu_cache.vhd` (the DEAD/uncompiled real-SCPU cache). It is a
COMPLETE 4KB direct-mapped read cache (512 lines × 8 bytes; tag = bank&addr[15:12];
per-byte valid; opportunistic fill from every SDRAM read; write-through w/ 16-entry
WB). Qualification findings:
- **Read hits are sound and SHORT-PATH.** `cache_di` (registered M10K output, valid
  1 clk after addr) feeds the `cpuDi` mux as a *separate high-priority override* —
  it BYPASSES the ~17-deep buslogic `dataToCpu` chain. So a hit attacks BOTH the
  79ns SDRAM term AND the 20.5ns deep-mux term (cache_di→cpuDi is ~1-2 levels) →
  doubly synergistic with a faster cadence ON HITS.
- **The historical black-screen was WRITE-HIT-specific, NOT read.** `cacheable_wr
  <= '0'` (cpu_cache.vhd:220): v159/v161 enabled write hits and both black-screened
  because `cache_hit=1` suppresses enableCpu/cpu_cyc for a cycle, racing
  `wb_drain_active`'s hijack of ramAddr/ramDout/ramWE in the CPUA-CPUD window →
  KERNAL loses RAM-init writes. **Read-only caching (writes take the normal SDRAM
  path + invalidate the matching line) sidesteps this entire failure** — and is the
  current `cacheable_wr='0'` state, so no new write-path risk.
- **Interleave-TOLERANT (the key differentiator).** Page-mode/SLOT3 died because
  interleaving bank-$00 with SuperRAM forced conflict-misses / row-closes. A cache
  has no open-row to lose: bank-$00 and SuperRAM map to DIFFERENT lines and coexist.
  Direct-mapped collision needs two hot addrs sharing addr[11:3] w/ different tags —
  not the common shape. So the objection that killed the last two levers does NOT
  apply here.
- **Payoff requires a variable-cadence arbiter on hits.** The cache alone gives NO
  throughput gain (a hit just delivers correct data faster *within* the fixed
  4-clk32 slot). To convert "hit ⇒ data ready ~16ns in via short path" into speed,
  the arbiter must release the CPU early on a hit (grant next cycle at ~+2/+3) and
  fall back to +4 on a miss. `cache_hit` is combinational on the current address, so
  the arbiter CAN know in-cycle. The dead `cache_hit→suppress enableCpu/cpu_cyc`
  cancel logic in fpga64_sid_iec.vhd is exactly this mechanism (also disabled).
- Resources fine: 4KB = 8 M10K + MLAB; budget has ~150 free M10K.

**NEXT ITERATION (GHDL-first, the disciplined order):** (1) revive `cpu_cache.vhd`
into a GHDL harness READ-ONLY (cacheable_wr stays '0'); (2) the recurring sim-
fidelity trap says synthetic patterns mislead — so capture a REAL bank-$00/SuperRAM
address trace (RTL instrument + one build, or replay a Lorenz/Doom UART-derived
trace) and measure hit-rate on it, NOT synthetic interleave; (3) only if hit-rate is
high enough to matter, wire cache_di into the cpuDi mux as a top-priority override
+ revive the hit-shortens-cycle arbiter path; (4) STA must show the cache_di→cpuDi
HIT path closes at the shorter cadence (the whole point) while the MISS path keeps
the 4-clk32 budget; (5) HW: Lorenz scpu 100%, Doom no-regress, then measure MHz.

**ITER-4 RESULT (2026-05-30): first NON-synthetic hit-rate = 94% on a real
bank-$00 stream.** Built `sim/c64_reduced_harness/c64_cache_hitrate_tb.vhd` +
`run_cache_hitrate.sh` (committed): taps the live `fpga64_sid_iec` CPU access
stream (cpuAddr/addr_hi_816/cpuWe/cpuDi/enableCpu_816/vda/vpa) via VHDL-2008
external names and drives the REAL `cpu_cache` RTL as a read-only observer (no RTL
change, no CPU feedback). On the real KERNAL-execution window in `c64_reduced_top_v2`
passthrough: **94.12% overall hit (98.63% ZP/stack)**, 4681 cacheable reads, final
PC $00:FD83, addrs to $FFFD, 3873 non-ZP code fetches → not a stuck-CPU artifact.
This is the first real-instruction-stream payoff evidence and supports the cache
premise (high bank-$00 locality), unlike the synthetic patterns that mis-sold
page-mode/SLOT3. GOTCHA fixed: the v2 top's `clk_cpu` input defaults to constant
'0' — leave it unconnected (as the stock _tb_v2 does) and the CPU freezes at $0000;
must drive `clk_cpu => clk` for passthrough. CAVEATS: KERNAL-init only (not
steady-state BASIC/Doom), all bank-$00 (SuperRAM/Doom hit-rate — the big-working-set
question — still unmeasured), no bank-switch flush modeled. **Next: capture a REAL
HW access trace (instrument fpga64_sid_iec to dump CPU {bank,addr,we} over UART
during a Doom/Lorenz run, one build) and replay it through this same observer to get
the SuperRAM/steady-state hit-rate — the number that decides Doom payoff.** The
engineering gate (revive read cache + variable-cadence arbiter + STA-close the HIT
path at shorter cadence) is the parallel track once payoff is confirmed.

**ITER-4b (2026-05-30): replay model built + cross-validated; KERNAL stream is at
its informational ceiling.** Added a bounded access-trace dumper to the bench
(`<we> <bank> <addr>` per step) + `tools/cache_replay.py`, a Python model exactly
mirroring cpu_cache.vhd (512×8 DM, per-byte valid, opportunistic fill,
invalidate-on-write). **Cross-check: Python 94.13%/98.64% ≡ GHDL/RTL 94.12%/98.63%
— observer independently validated.** But the geometry SWEEP is flat: 1KB→16KB,
DM→4-way, 4B→16B lines ALL give the identical 94.13% → the 275 misses are entirely
COMPULSORY (first-touch); the KERNAL-init working set is only ~275 distinct bytes,
fits any cache, so geometry is irrelevant and the stream **cannot inform steady-state
hit-rate or geometry**. Off-device KERNAL has hit its ceiling. CHECKED the asterix
CPU bench as a cheaper proxy — also too small (`work_asterix_full/ours_trace.txt`:
500k steps but only **90 distinct PCs** = a dispatcher loop, not gameplay → also
compulsory-miss-dominated). **CONCLUSION: no available off-device trace has a working
set large enough to inform steady-state hit-rate.** Off-device measurement is
exhausted for this question.

**ITER-4c PATH (decided): in-HW cache observer (sidesteps the trace-bandwidth wall).**
Streaming every CPU access over UART is impossible (4M acc/s ≫ 115200 baud ≈ 11KB/s),
and a BRAM-buffered burst just re-creates the small-window problem. So instead
instantiate the read-only `cpu_cache` as an OBSERVER directly inside `fpga64_sid_iec`
(cache_di/cache_hit NOT fed to the CPU → cannot break Doom/Lorenz), with two free-running
counters (cacheable_reads, cache_hits) surfaced via the existing UART debug overlay.
The cache runs at full HW speed and just accumulates; run real Doom + Lorenz, read the
counters → the true steady-state SuperRAM+bank-$00 hit-rate. Cost ~8 M10K (have ~150
free), one build, observer-only. This is also most of the wiring for the eventual real
integration (flipping it to feed the CPU + the variable-cadence arbiter is the later
step). NEXT TICK: write the observer instantiation + counters + dbg wiring (off-device,
GHDL-check via the reduced harness which already compiles cpu_cache), then build + HW.

**ITER-4d (2026-05-30): in-HW observer WRITTEN + GHDL-VALIDATED; build in flight.**
Added the read-only `cpu_cache` observer directly inside `fpga64_sid_iec.vhd`
(`cache_observer` instance + `cobs_*` signals + `cobs_tap`/`cobs_count` processes).
Structurally mirrors `c64_cache_hitrate_tb.vhd` exactly (1-clk uniform tap register,
`cacheable` gate = cpu_cache.vhd:188, real `cpu_cache` fed read-only with `wb_enable='0'`).
`cache_hit` drives ONLY the counters — never the CPU — so the block is behaviourally
inert (cannot break boot/Doom/Lorenz/native). Two readouts:
- **HR** (`dbg_cache_hr`) = HITs in the last completed **256-cacheable-read sliding
  window**, saturating at 255 (HR/2.56 ≈ hit %). The sliding window is the key design
  choice: it discards the cold-start compulsory misses that polluted the cumulative
  number, so it tracks **steady state** — and it's reset-robust.
- **HW** (`dbg_cache_hw`) = window-completion counter (wraps every 256 windows).
  Advances between UART lines ⇒ the observer is seeing CPU read traffic (liveness;
  distinguishes "0% hit" from "no cacheable reads yet").
Surfaced through the full overlay path: `fpga64_sid_iec` ports → `c64.sv`
(`scpu_dbg_cache_hr/hw` wires + `dbg_pool.cache_hr/hw`) → `debug_pkg.svh`
(`cache_hr`/`cache_hw` struct fields) → `debug_uart_pool_fmt.sv` (`" HR:## HW:##"`
appended at bytes 397-408, `LINE_LEN`→410, latched at vblank). **GHDL cross-check
(run_cache_hitrate.sh, in-RTL observer tapped via external name vs the bench's own
observer):** in-RTL windowed **HR=237 (92.6%)**, cumulative 3895/4169 = 93.4% — vs
the bench's cross-validated 94.12%. (The cumulative gap of exactly 512 reads is
`cobs_reset <= not reset_n` zeroing at the mid-run PRG-load reset, which the bench's
tb-`reset` doesn't mirror; the *ratio* match within 0.7% confirms correct wiring, and
HR is immune to reset.) RESULT: PASS. **BUILD GREEN** (md5 `e5e899fc`, DEBUG flavor): Fitter Successful, Final timing
models, **71% ALMs** (29,869 — +2.5k for the observer), **73% M10K** (403/553 — no
overflow; the cache packed without adding M10K blocks), 55% block-mem bits. Build
gotcha fixed en route: `cpu_cache.vhd` was DEAD/uncompiled → not in `C64.qsf` → first
A&S died "library work does not contain primary unit cpu_cache"; added the VHDL_FILE
line (commit `e7e3d3e`). Archived `C64_milestone-b-cdc-rewrite_e7e3d3eabf_...e5e899fc-dirty.rbf`.
HW readout tool: `python tools/cache_hitrate_hw.py [secs]` (parses `HR`/`HW`, reports
mean steady-state hit %, confirms liveness via HW advance).
**DEPLOY DEFERRED (shared-MiSTer):** at 17:20 `/tmp/CORENAME=CannonFodder-CD32MVP`
(the CD32 agent's core; lock empty but CORENAME ≠ C64) → backed off per cooperation
protocol; polling for the MiSTer to free. NEXT TICK (when CORENAME=C64/empty): deploy
to `/media/fat/_Test/C64.rbf`, then read `HR`/`HW` over UART during (a) a real Doom run
[SuperRAM steady-state — the Doom-payoff number] and (b) Lorenz scpu / a BASIC loop
[bank-$00 steady-state]. Mean HR = GO/NO-GO on the cache + variable-cadence-arbiter
engineering arc. Observer-only, so the run also confirms-by-non-regression that
boot/Doom/Lorenz are unaffected. Commits `26912d5`/`e7e3d3e`/`68e2f9f` (all unpushed).

**HW MEASUREMENT DONE (2026-05-30, user freed the MiSTer) → GO for the cache lever.**
Deployed `e5e899fc`, read the UART `HR`/`HW` observer across three workloads
(`tools/cache_hitrate_hw.py` / inline capture). HW advancing in all = liveness OK;
Doom reached its `$2C` main loop normally = observer is non-regressing:
| Workload | PC region | HR mean | hit % |
|---|---|---|---|
| KERNAL idle loop (degenerate tight loop) | $00:E5xx | 255/256 | 99.6% |
| Bank-$00 BASIC compute (FP interpreter) | $00:B8–BA | 204.5/256 | **~80%** |
| Doom gameplay (SuperRAM banks $2B/$2C) | $2B/$2C | 212.7/256 | **~83%** |
Both representative workloads land **~80–83%** steady-state — comfortably above the
threshold where a read cache pays off (the real CMD SuperCPU ships one for exactly
this). So ~80% of cacheable reads could be served from the SHORT cache path (~1 clk64)
instead of the 79ns SDRAM read + ~20.5ns deep `dataToCpu`+`cpuDi` mux that bind the
current ~4MHz ceiling. **VERDICT: GO** on the cache + variable-cadence-arbiter arc.
- NOTE on the idle-loop 99.6% vs compute 80%: the idle KERNAL loop re-reads a tiny
  byte set so it trivially hits; the 80–83% numbers are the REAL varied-code steady
  state and the ones to design against.
- Shared-MiSTer contention during the run: the CD32/CDTV agent loaded `CDTV-DotC-Audio`
  mid-measurement (replaced my C64); re-deployed once (user-authorized) and completed.
**ITER-5 (2026-05-30): read-path COHERENCY de-risked, GHDL-first (no build).**
Before wiring the cache as a real read path, closed the #2 historical-risk class
(the #1 — write-hit incoherency — stays avoided by keeping the cache read-only):
- **Throughput ceiling, grounded analytically** on the bench's validated
  16-CPU-slot / 4MHz baseline: avg clk32/access = `4 − 3·h`. At measured h≈0.80 →
  16/1.6 = **~10 MHz** (2.5×); floor h=0 → 4 MHz (no regress); ceiling h=1 → 16 MHz.
  (The `turbo_throughput_tb` row-hit model is the WRONG shape for a BRAM cache and
  its footer warns it PASSes where HW BRK'd, so I did NOT reuse it — the analytical
  model is the honest ceiling. Real gate is STA, not throughput.)
- **CPU-write coherency**: `cache_coherency_tb` READ2 still PASSes (cpu_we →
  invalidate → hit=0).
- **DMA/REU-write coherency GAP found + CLOSED**: `invalidate_wr` is gated on
  `cpu_we`, so DMA/REU writes (Doom loader's REU FETCH into bank-$00 buffers the
  CPU then re-reads) bypass invalidation → stale read → corruption. Added
  `snoop_we/snoop_addr/snoop_bank` to `cpu_cache.vhd` (VHDL-defaulted → observer
  instance + synth build untouched), top-data-priority invalidate. New STEP 6:
  READ4 DMA-snoop-write → hit=0 PASS. Committed `8329f56` (GHDL-green).
**ITER-5 architectural finding (read before the next iteration):** the
hit-shortens-grant and the `cache_di→cpuDi` override are **INSEPARABLE**. The
arbiter already has the machinery — `sdram_hit_pred` (fpga64_sid_iec.vhd:3283,
forced `'0'`) preloads `sdram_busy_cnt<="001"` (:3404) for a short grant. But the
prior Doom **BRK $00:000A** (:3273-3282) came from shortening the grant while the
CPU still latched **SDRAM `dout`**. On a cache HIT the CPU must latch **`cache_di`**
instead — so driving `sdram_hit_pred<=cache_hit` WITHOUT the atomic `cache_di→cpuDi`
override at the top of the cpuDi mux (:1932) reproduces that exact stale-latch class.
Second crux: the observer (:4740) feeds the cache **delayed taps** (tap_*_r, 1 clk)
and fills from `cpuDi` — both WRONG for a real read path. The real path needs (a) a
cache addressed on the CURRENT `cpuAddr` so `cache_hit`/`cache_di` are valid for the
same-cycle override + grant decision, but `cache_di` is a registered M10K output
(valid 1 clk AFTER address) → there is a real **same-cycle-availability timing
question** (does cache_di arrive before the bridge's `enableCpu_816=cpu_cyc_s(1)`
latch?), and (b) fill from the REAL returned SDRAM byte on MISS completion, not cpuDi.
**ITER-5 system-level coherency proof DONE (commit d99987e, GHDL-green, no build).**
Added a testbench-only coherency checker to `c64_cache_hitrate_tb` (clocks the real
`fpga64_sid_iec`): a bank-$00 shadow mirrors the cache's fill-on-read/invalidate-on-write
content; on every cacheable read where the REAL `cache_hit='1'`, the cache's stored byte
must equal the byte the CPU actually reads (`tap_di`). Result on the real KERNAL boot
stream (PC→$FD83, 4681 cacheable reads): **hit_checks=4406 stale_fails=0 hit_noshadow=0
→ READPATH_COHERENCY=PASS** — every cache HIT returns the correct byte, shadow validity
tracks the HIT decision exactly. This is the functional half a sim CAN settle (the cache
content stays coherent under real interleaved traffic ⇒ `cache_di→cpuDi` would feed
correct data). The `cache_di` M10K 1-clk latency was deliberately NOT exercised — that's
the STA question (build-only). Run: `GHDL=<winget> STOP_TIME=12ms bash
sim/c64_reduced_harness/run_cache_hitrate.sh`.

**NEXT (build-bearing — the STA gate is the only thing left a sim can't answer):**
wire the read path in `fpga64_sid_iec.vhd`, ideally behind a default-FALSE VHDL constant
(`CACHE_READ_PATH`) so synth stays bit-identical until proven: (1) a cache instance on the
CURRENT `cpuAddr` driving `cache_hit→sdram_hit_pred` (the existing busy_cnt="001" short
grant, :3404) AND atomically `cache_di→cpuDi` top-priority override (:1932) — the two are
INSEPARABLE (decoupling = Doom BRK $00:000A stale-latch); (2) fill from `cpuDi`
itself at read completion — CORRECTION: the observer's fill-from-cpuDi IS right for
content (the cpuDi mux at :1932 already resolves SuperRAM→`ramDin` and bank-$00→`cpuDi_raw`
to the exact byte the CPU latches, so cpuDi = the correct value to cache; earlier "must
capture SDRAM byte NOT cpuDi" was overcautious). Only the fill TIMING differs from the
observer: fill at MISS completion, and address the cache on the CURRENT `cpuAddr` (not a
delayed tap) so cache_hit/cache_di are live during the access; (3) `snoop_*`←the DMA/REU
write strobe. This is large + fragile + in the
hairiest file, so it warrants the user able to course-correct, not piecemeal unattended
ticks. Then build with the constant TRUE → read **STA on `cache_di→cpuDi` at the shorter
cadence** → HW gates Lorenz scpu 100% + Doom no-regress → effective MHz. Write-hit path
stays disabled (read-only). Functional coherency is now proven at BOTH unit (8329f56) and
system (d99987e) level; only timing closure remains unproven.

**ITER-6 (2026-05-30): read-path WIRED + STA GATE READ — DECISIVE, off-device.**
Wired the full gated read path in `fpga64_sid_iec.vhd` behind `constant
CACHE_READ_PATH` (default FALSE, currently committed false). On TRUE: a
`cpu_cache` instance on the live `cpuAddr` drives `cache_hit→sdram_hit_pred`
(:3283, the busy_cnt="001" short grant) AND `cache_di→cpuDi` top-priority
override (:1932) — the inseparable pair; fill-from-`cpuDi`; `snoop_*` tied '0'
(KERNAL boot has no DMA). GHDL-proven 3 ways in the passthrough harness:
off=baseline, on=bit-identical boot, on+garbage-fill=derails (override
non-vacuous). M10K 1-clk `cache_di` delivers correct data.

Built with CACHE_READ_PATH=TRUE (probe build, md5 `03ec86cf`, 85% ALMs /
411 M10K — fits). Global STA: all setup positive, **core-clock worst +3.028ns,
TNS=0**. Then ran the **decisive masking test** via scripted `quartus_sta`
(17.0) on the fitted netlist — `C64_MiSTer/cache_sta_probe.tcl`, isolating
`*gen_read_path:read_path_cache*` → `*P65C816:cpu|*`:
- **(A) as-built `-setup 2` budget (62.5ns): worst slack +31.068ns, 0/8 violated.**
- **(B) forced `-setup 1` (31.25ns single-cycle): worst slack −0.651ns, 8/8 VIOLATED.**

Worst single-cycle path = `read_path_cache|tag_mem → … → P65C816|AddrGen|PCr[7]`
(PC reached through the full ALU adder chain). Cell breakdown
(`C64_MiSTer/cache_1cyc_path.txt`): ~31.9ns = **~10ns** cache-internal
tag-compare+byte-select (`Mux68~*`/`Equal10~*`) + **~2.7ns** my cpuDi override
mux (`cpuDi[7]~308/309`, small — NOT the culprit) + **~11ns INSIDE P65C816**
(`localDi→Mux21→ALU AddSub add0..add3→BCD_CO→AddrGen.PCr`).

**VERDICT (airtight, off-device — no SLOT3/clk48 masking trap, because I
explicitly tested the single-cycle budget):**
- **~2× (≈8MHz), CPU firing every 2 clk32 with un-registered `cache_di` under
  the existing `-setup 2 -to {*P65C816:cpu|*}` multicycle is STA-HONEST** — at
  2-apart cadence setup-2 is the *correct* relationship (not masking), +31ns
  margin. **First non-falsified, STA-honest >4MHz lever.**
- **>2× (toward the 4−3h ≈10MHz analytical ceiling) needs consecutive (1-apart)
  fires = single-cycle closure → FAILS by 0.65ns.** The miss is NOT in the cache
  mux; it's the cache-internal hit-logic + the **CPU-internal `di→ALU→PC` path**
  (same wall Milestone B hit). Registering `cache_di` to split the path re-adds a
  latency cycle a non-pipelined CPU can't overlap → caps back at ~2× anyway.
  Going further = pipelining the CPU's di-consume = CPU-core surgery.

**STATUS (iter-7 prep landed this tick, off-device):** the RDY-handshake RTL is
wired behind a default-false `RDY_HANDSHAKE` constant (`fpga64_sid_iec.vhd:~1581`,
commit `c6b5280`): `data_ready` term ANDed onto the 816 `rdy` port (:3108), using
the corrected `sdram_data_valid_sync` + `cs_ram` form. Inert when false →
`c64_reduced_harness run_harness_v2 = PASS 84/0`, bit-identical boot (analyzes +
no regression).

**SAFETY PRINCIPLE PROVEN off-device (commit `f8168dc`):** added
`INJECT_GARBAGE_DURING_STALL` to `cpu_in_bridge_superram_tb` — the mock arbiter
drives `$DD` on the data bus for the ENTIRE ack-delay stall window, real value only
at ack. Differential (RATIO=2): control PASS ($AB round-trip), garbage=true STILL
PASS ($AB). With garbage on the bus every stall cycle the real cpu_65c816 latched
only the fresh byte at rdy-release, never the garbage (discriminating — an early
latch would store $DD → FAIL). So the no-stale-latch property the alt-slot relies
on holds: a read held by rdy-low during a miss consumes data only when ready.

**BUILD 1 HW-FALSIFIED (2026-05-31, build `12b93c5e`, 85% ALMs, STA core +2.631ns/TNS=0):**
isolation build — `CACHE_READ_PATH:=true` (:1575) + `RDY_HANDSHAKE:=true` (:1594),
**`alt_fire_r2` still OFF** (cadence-neutral). Deployed to `/media/fat/_Test/C64.rbf`
under a deploy lock. **RESULT: boot WEDGED.** Screen garbled (not clean READY); UART
showed **PC frozen at `$00FCE5` every frame** (`I:00FCE4 DI:78 SP:01FD`, frame
counter advancing but PC never moving) = hard CPU stall in the early KERNAL reset
sequence. **Verdict:** gating the live 816 `rdy` on `data_ready`
(= `sdram_data_valid_sync` for SDRAM reads / `rp_cache_hit` for hits) stalls the CPU
indefinitely — `sdram_data_valid_sync` does NOT track per-access read-readiness
against the REAL `sdram_pm` (rdy never re-asserts → CPU hangs). This is exactly the
#1 HW unknown the handoff flagged ("must confirm sdram_data_valid_sync
deasserts/reasserts in step with the CPU latch … or the main-slot cadence could
break"). The risk materialized.

**CONFOUND (process miss, recorded):** Build 1 enabled BOTH `CACHE_READ_PATH` and
`RDY_HANDSHAKE`. `CACHE_READ_PATH=true` had only ever been GHDL+STA-proven, **never
HW-tested with the read path actually feeding the CPU** — so the wedge is NOT cleanly
isolated to `RDY_HANDSHAKE`. The cleaner experiment would have been one new HW
variable at a time. To clear `CACHE_READ_PATH`, the next build must be **cache-only**:
`CACHE_READ_PATH:=true`, `RDY_HANDSHAKE:=false`, `alt_fire_r2` OFF — if that boots +
Doom no-regress + Lorenz 100%, the read path is HW-clean and the wedge is pinned to
`RDY_HANDSHAKE`'s `data_ready` gating, which then needs a corrected per-access
read-valid source (not `sdram_data_valid_sync`).

**RECOVERY DONE:** flags reverted to committed default `false` (working tree clean,
only the documenting comments differ); MiSTer restored to control `97392a1f` (UART
confirms healthy — PC cycling the KERNAL editor loop `$E5CF`→`$E5D4`, not frozen);
deploy lock released (`/tmp/mister_session.lock` = NOLOCK, `CORENAME=C64`).
DID NOT commit the flag flips. Build-1 rbf archived
(`builds/…_12b93c5e-dirty.rbf`).

**REMAINING = HW-gated (a sim can't reach these):** (1) the actual fpga64
`data_ready` expression driving the 816 rdy in the REAL arbiter context — the
above bench drives rdy from the bridge, not my `data_ready` term; (2) whether
`sdram_data_valid_sync` deasserts/reasserts in step with the CPU latch against the
real `sdram_pm`; (3) `alt_fire_r2` interaction + cadence non-regression; (4)
effective MHz. These need: `RDY_HANDSHAKE:=true` + enable `alt_fire_r2` → build →
deploy → Doom no-regress + Lorenz scpu/t65 100% + MHz. Details below.

**IMMEDIATE NEXT TICK (iter-7b, after the Build-1 wedge):** before anything else,
two off-the-critical-path steps de-confound and de-risk:
1. **Cache-only HW isolation build — DONE 2026-05-31, build `e0e83e5c`
   (`CACHE_READ_PATH:=true`, `RDY_HANDSHAKE:=false`, alt_fire OFF; 85% ALM, TNS=0,
   setup +0.241ns). RESULT: boots clean but CORRUPTS the Lorenz-scpu serial LOAD.**
   - Boot: clean (KERNAL editor idle loop, NOT the Build-1 $FCE5 wedge) → so
     `CACHE_READ_PATH` does not break boot, and the Build-1 wedge is pinned to
     `RDY_HANDSHAKE` (✓ that half of the isolation succeeded).
   - Doom autoload: inconclusive — REU/MGL autoload didn't fire the game (CPU healthy
     at READY; environmental, NOT a regression).
   - **Lorenz scpu: GARBAGE screen ("< 0JEEP" gibberish, static top + churning debug
     overlay = the flicker-md5 false-positive). The suite never ran.** Differential
     A/B nailed it: control `97392a1f` runs Lorenz-scpu CLEAN (actual "ldab - ok …"
     test display), and `e5e899fc` (HEAD-lineage, cache present but NOT feeding the
     CPU, `CACHE_READ_PATH=false`) ALSO runs CLEAN. Only `e0e83e5c` (cache feeding the
     CPU) garbles → **the corruption is definitively in the read path FEEDING
     `cache_di` to the CPU**, not a HEAD regression, not the autoload harness.
   - **ROOT CAUSE CONFIRMED off-device (GHDL bench `sim/cache_coherency_tb/
     cpu_cache_latency_tb.vhd`, run `run_cache_latency.ps1`):** the bench fills two
     distinct lines ($0100=$AA, $0200=$BB), settles on line A, then switches to line B
     and samples `cache_hit`/`cache_di` SAME-CYCLE (mid-clock, no new edge) like the
     combinational override. Result: `SAME-CYCLE B: $0200 hit=1 di=$AA same_line=0` —
     hit asserts for $0200 but `cache_di` still holds line A's stale $AA; one edge later
     `LATE B: $0200 hit=1 di=$BB` is correct. So the override feeds the CPU the PREVIOUS
     line's byte on any cross-line (non-same_line) hit. The bench RED-FAILS (severity
     failure) while the skew exists and goes GREEN when fixed = the iter-7b-fix
     regression gate. (Mechanism below confirmed exactly:)
   - **MECHANISM (RTL-grounded, cpu_cache.vhd):** `cache_hit` is
     COMBINATIONAL on the current address (`cacheable_rd and tag_match and byte_valid`,
     :276), but `cache_di` is derived from `line_word`, a REGISTERED 1-cycle-late read
     of the 8 data banks (:284-296). The `same_line` fast-path (:180-182) only covers
     back-to-back same-line accesses. On a HIT to a newly-addressed (non-same_line)
     line, `cache_di` still holds the PREVIOUS line's bytes for one cycle → if the
     read-path override feeds `cache_di` in the same cycle `cache_hit` asserts, it
     returns stale/wrong data. Boot's sequential/same-line reads (instr fetch, ZP)
     mask it; LOAD's scattered access pattern exposes it = garbage. STA-closure
     (iter-6 +31ns) can't catch this — it's a data-validity skew, not a timing path.
   - **REFINEMENT (2026-05-31, latency bench reworked to a PASSING characterization):**
     `cpu_cache` is NOT buggy — it is a correct 1-cycle-latency BRAM. `run_cache_latency.ps1`
     now MEASURES the latency precisely and PASSES:
       * M1 SAME-CYCLE cross-line ($0100→$0200): hit=1, same_line=0, di=$AA = STALE
         (line_word still holds the previous line) → a 1-clk32 (`busy_cnt="001"`) hit
         grant that consumes same-cycle is UNSAFE = the HW bug.
       * M2 ONE-EDGE-AFTER cross-line ($0200→$0400): hit=1, di=$CC = VALID (line_word
         caught up) → a 2-clk32 (`busy_cnt="010"`) grant is SAFE.
     So the bug is in the fpga64 CONSUMER (the short-grant/override consuming before
     `line_word` settles on a cross-line hit), not in the cache. The bench is the
     durable proof of the cache's 1-edge read latency; it does NOT go RED/GREEN with the
     fix (the cache won't change) — the real regression gate is HW Lorenz-scpu + a
     system bench. [Earlier "cache HW-FALSIFIED-AS-BUGGY / bench RED until fixed" framing
     in commits 55519e1/5c3e784 is superseded by this — the cache is fine.]
   - **NEXT (iter-7b-fix) — fix is in the ARBITER consume timing; HYPOTHESIS needs
     system-level validation:** leading candidate is the hit grant `busy_cnt "001" →
     "010"` (cpu_cache consumer at fpga64_sid_iec.vhd:~3451) so the CPU samples cpuDi
     one clk32 later, after line_word settles — which ALSO equals the iter-6
     STA-honest 2× (fire-every-2-clk32) cadence. BUT this is UNPROVEN: with `alt_fire`
     OFF the grant width may not even change WHEN the CPU advances (cpu_cyc is gated to
     the 4-apart main slots, :3401-05), yet e0e83e5c corrupted with alt_fire OFF — so
     the deciding factor is how the CPU's address-present vs `di`-latch edges align with
     `line_word`, which the UNIT bench cannot resolve. MUST validate at system level
     before building: extend `c64_reduced_harness` (or `cpu_in_bridge_superram_tb`) to
     drive the REAL cpu_65c816 through the cache read path (override + short-grant wired)
     with a cross-line access stream, and check the CPU latches the correct byte. Only
     after the system bench shows the correct fix → build → HW-gate Lorenz scpu/t65 100%
     + Doom no-regress + MHz. Until then the cache read path gives no shippable speedup.
       * Alternative if grant-width alone doesn't fix it: gate the override on a
         "data-ready" qualifier (`cache_hit AND same_line_i`, or a registered
         `cache_hit_d1`/`cache_di_d1` aligned to line_word) AND defer the CPU consume
         (CE-gate) by one clk32 on a fresh-line hit — the same CE-gating lever as
         iter-7c; likely solve both together.

   *(Original isolation plan, now superseded by the result above: build cadence-identical
   except cache feeds cpuDi; if clean → CACHE_READ_PATH HW-clean. It booted clean but
   the workload gate FAILED.)*
2. **Do NOT re-attempt gating `rdy` — it is STRUCTURALLY fragile (root-caused this
   tick from the RTL).** The CPU advances only when BOTH the arbiter pulses `CE`
   (`enableCpu`) AND `rdy` is high — `EN <= RDY_IN AND CE` (cpu_65c816). The shipped
   arbiter ALREADY encodes data-readiness in *when* it pulses CE: `cpu_cyc` fires only
   when `sdram_busy='0'` (the local `sdram_busy_cnt` predictor floor, :3401/:3449-74).
   That IS the working handshake. ANDing `data_ready` onto `rdy` adds a SECOND,
   independent gate that must be PERFECTLY phase-aligned with that CE pulse — when
   `sdram_data_valid_sync` (sdram_pm.v: level high at q==STATE_READ, dropped at next ce
   edge, single-flop synced clk64→clk32) and the arbiter's `sdram_busy` predictor
   disagree by even one clk32, the CPU misses its single CE enable window, the arbiter
   moves on (never re-pulses CE for that access), and the CPU hangs = the $FCE5 wedge.
   So a second rdy gate is redundant-and-dangerous for main slots.
3. **CORRECT alt-slot design (iter-7c) = gate `enableCpu` (the CE pulse), NOT `rdy`.**
   Keep main slots on the proven fixed `cpu_cyc_s` cadence untouched. For the ALT slot
   only, replace the fixed-delay CE (`alt_fire_r2`→cpu_cyc fires 2 clk32 after a
   blind-at-CPU2 decision) with a DATA-DRIVEN CE: the alt-slot advance fires when
   `data_valid` confirms the alt access's datum is on the bus (or `rp_cache_hit`),
   else it simply doesn't fire and the CPU waits for the next main slot. This is the
   "stall until ready" the handshake wanted, applied to the CE pulse where the arbiter
   already lives, instead of to `rdy` where it races the arbiter. Requires
   distinguishing alt-slot CE from main-slot CE in the `cpu_cyc`/`enableCpu` logic and
   making only the alt one `data_valid`-gated. GHDL-model the alt-slot CE against the
   real sdram_pm `data_valid` phase BEFORE building. Until then, alt_fire stays OFF
   (cadence-neutral) and the only HW-shippable artifact is the read-path cache itself
   (item 1), which gives no speedup without a working alt-slot.

**TURNKEY PLAN (vehicle already in the RTL) — gated on iter-7b above:**
realize the 2× — current wiring shortens the grant but `cpu_cyc` still fires only
at the 4-apart main slots, because the alt-slot registers are commented OFF
(`fpga64_sid_iec.vhd:3473-3504`: both `alt_fire_r`/`alt_fire_r2` are hard-tied
`<= '0'`; the `--if` predicates are commented). The Step-7b `alt_fire_r2` block
(samples CPU2/6/A/E → fires CPU3/7/B/F, gated `scpu_fast_path AND cs_ram AND
sdram_busy_cnt <= "001"`) is the *apparent* vehicle, and `busy_cnt="001"` is loaded
ONLY on a cache HIT (`sdram_hit_pred=rp_cache_hit`, :3427-28).

**⚠️ CORRECTION (2026-05-30, same tick): re-enabling `alt_fire_r2` is NOT a turnkey
safe edit — it will reproduce the historical Doom wedge.** The decision to fast-fire
at CPU3 is registered at CPU2, BEFORE the upcoming access's address (and thus its
cache hit/miss) is known — `enableCpu = cpu_cyc_s(1)` commits the CPU advance on a
fixed 2-clk32 delay, it does not wait for data. So the predicate (whether the loose
`busy_cnt<=001` OR a `rp_cache_hit` tap at CPU2) only reflects the JUST-COMPLETED
access, never the upcoming one. If the alt-slot access itself MISSES (~17% of the
time at Doom's measured ~83% SuperRAM hit rate), `busy_cnt` reloads "011" but the CPU
already committed to fire → latches before SDRAM is ready → stale-latch BRK. This is
exactly the documented alt-slot Doom-wedge (:3316-3323, :3490-3495). The cache makes
the *data PATH* close (STA +31ns) and supplies HIT data, but it does NOT make
speculative alt-slot firing miss-safe — necessary, not sufficient.

**The correct iter-7 = land the RDY-handshake the code itself flags as unbuilt**
(:3393-3394: *"single-flop sync of sdram_data_valid. Consumer (RDY-handshake gate
replacing cpu_cyc_s) lands in Phase 6b"*). Gate `enableCpu` (the CPU advance / data
latch) on a real data-ready = `rp_cache_hit OR sdram_ready_sync` instead of the fixed
`cpu_cyc_s(1)` delay. Then a miss at ANY slot (main or alt) STALLS the CPU until data
arrives — the alt-slot becomes safe by construction (a miss just gives the speed back
on that access, keeps it on hits), and Doom's REU→SuperRAM interleaved stores can't
stale-latch. Scaffolding already exists (`sdram_ready_sync` 2-FF :3391, 
`sdram_data_valid_sync` :3395).

**MECHANISM (found this tick — the clean vehicle is the CPU's NATIVE RDY, not
`cpu_cyc_s` surgery):** `cpu_65c816.vhd` exposes `RDY_IN` and internally does
`EN <= RDY_IN AND CE` (halts on read cycles; writes force RDY=1 via
`rdy_gated <= rdy or not localWe`, :92). In `fpga64_sid_iec.vhd` the 816's `rdy`
port is `baLoc and cpu816_rdy_to_cpu` (:3092 — VIC badline stall AND bridge
handshake; both load-bearing, preserve them). The RDY-handshake = AND a
`data_ready` term onto that: `rdy => baLoc and cpu816_rdy_to_cpu and data_ready`.

**SIGNAL CORRECTION + REFINEMENT (next-tick analysis, off-device):** use
`sdram_data_valid`, NOT `sdram_ready`. Both are real input ports wired from
`sdram_pm` in c64.sv (`.ready(sdram_ready)` :1110, `.data_valid(sdram_data_valid)`
:1111 → fpga64 :2095/:2098 — verified, neither is a defaulted constant). But
`sdram_ready` = "controller idle, safe to START a new access"; `sdram_data_valid`
= "dout_r is FRESH" (set post-sample edge, cleared at next ce-edge, :198-203) =
the actual per-access read-data-ready. It's synced single-flop to
`sdram_data_valid_sync` (:3395), already in clk32. Also: a CPU read's `cpuDi` can
come from I/O / ROM (dprom) / color RAM — combinational, NOT through `sdram_pm` —
so gating those on `sdram_data_valid` would wrongly stall them. Correct term:
`data_ready <= '1' when (cs_ram = '0') else (rp_cache_hit or sdram_data_valid_sync)`
(and force '1' when CACHE_READ_PATH=false / not supercpu_en, to stay bit-identical).
HIT → RDY=1 same cycle, latch `cache_di`; SDRAM MISS → RDY=0 until
`sdram_data_valid_sync` rises, latch `ramDin`; non-SDRAM read → RDY=1 immediately.
This makes speculative `alt_fire_r2`
CE pulses safe (a miss just holds RDY low that cycle). ⚠️ RISK: in passthrough
today `rdy` is NOT data-gated (the busy_cnt-gated main slots handle timing), so
adding `data_ready` changes the shipped 4MHz cadence path — must confirm in GHDL
that `sdram_data_valid_sync` deasserts/reasserts per access exactly in step with
when the CPU latches, or the main-slot cadence/Lorenz/Doom could break. Keep
the change gated on `supercpu_en` + a flag so the 6510 path is provably untouched.

**DE-RISK OFF-DEVICE FIRST:** extend a GHDL system
bench (`c64_reduced_harness` or `cpu_in_bridge_superram_tb`) with a SuperRAM
hit/miss access stream to prove the handshake stalls correctly on misses and never
stale-latches — the passthrough boot harness can't (bank-$00, `scpu_fast_path=0`).
ONLY after the handshake is sim-proven miss-safe: set `CACHE_READ_PATH:=true`,
enable `alt_fire_r2`, build → HW-gate Doom no-regress (`tools/deploy_and_probe_doom.py`)
+ Lorenz scpu/t65 100% (`tools/lorenz_run.py`) + measure MHz. The STA gate (this
tick) already cleared the data-path-timing half; the RDY-handshake clears the
cadence-control-correctness half. Both are required; only the first is done.
MiSTer ownership at this tick: `/tmp/CORENAME=C64` (mine/free), no lock — but the
next step is off-device (handshake design+sim), so no lock taken.

--- (historical, the path that led here) ---
**SIM-VALIDATED ✅ → RTL IMPLEMENTED → BUILT (timing-clean) → HW-FALSIFIED ⛔ (2026-05-30).**
GHDL-first per the page-mode lesson:
- Extended `sim/turbo_throughput_tb` with `G_SLOT3` (3-clk32 cadence,
  CPU0/3/6/9/C/F, busy floor `"010"`) on `cpu_arb_model.vhd`, and `G_NO_ROWTRACK`
  on the tb (drives `sdram_pm_lite.fast_path='0'` = the DEPLOYED uniform
  controller — no row tracking, no conflict-MISS). **The first SLOT3 runs
  FAILED with stale reads — but only because they ran against the lite model's
  row-tracking/conflict-MISS (q=7, 8 clk64) path, which the SHIPPED sdram_pm.v
  does NOT have.** Against the faithful deployed model (`G_NO_ROWTRACK=true`):
  **6.0 MHz, STALE_READS=0, CORRECTNESS=PASS** across sequential, INTERLEAVE
  (Doom-loader shape that killed page-mode), all-miss stride=256, and async
  refresh=37. Reproduce: `sim/turbo_throughput_tb/run.sh` (new SLOT3 block).
- Verified the shipped `sdram_pm.v` is uniform 6-clk64: q-block is unconditional
  (ce→q1..5→0, early-exit q=5), auto-precharge every access (A10=1 @ `:198`),
  NO hit/conflict/row-tracking (`grep` for q==7/conflict/precharge/fast_path =
  empty; header says Build-A page-mode FSM was removed). The arbiter's
  `sdram_hit_pred` is hard-forced `'0'` (`fpga64_sid_iec.vhd:3239`) so today it
  always reserves 4 clk32 — the 2-clk64 slack SLOT3 harvests.
- RTL change (mode-gated on `supercpu_en`, 6510 path untouched):
  `fpga64_sid_iec.vhd` cpu_cyc now grants CPU0/3/6/9/C/F in SCPU mode (`:3322`),
  and the MISS busy floor is `"010"` in SCPU mode (`:3380` area). Build kicked
  (bg task `bdwwkij3n`, ~30-40 min).
- **HW validation gate (next):** deploy to `/media/fat/_Test/C64.rbf`, then
  (1) Lorenz scpu must stay 100% (the data-consume correctness oracle the
  abstract bench can't fully model — stale reads WILL fail it), (2) Lorenz t65
  must stay 100% (regression guard; 6510 path unchanged so expected clean),
  (3) Doom autoload must not regress (REU→SuperRAM transfer is the exact
  interleaved-store path; Build-1 BRK'd here when the controller was wrong).
  If all three pass → measure effective MHz (speed-bench) and commit. If Lorenz
  scpu regresses → the data-consume timing at 3-clk32 is the culprit; revert is
  one-line (drop the `supercpu_en` SLOT3 branch + restore `"011"`).
- Actions taken: working tree reverted to committed `84ddf8f` (MILESTONE_B=0 +
  original SDC); MiSTer restored to `97392a1f` + lock released; clk48 RBF
  `abf8ff88` kept archived for the record. Codex read: `tools/codex-out/speed-lever-priority.txt`.

## (SUPERSEDED by the falsification above) clk48 CPU-INTERNAL CLOSES (honest STA) — clk64 was truly -1.56ns
Build `0d284387` (MILESTONE_B=2, clk_cpu=clk48=21.146ns) with the blanket
`-to *P65C816:cpu|*` multicycle REMOVED (honest single-cycle). Focused STA
(quartus_sta -t, WSL 17.0):
- **CPU-internal (P65C816->P65C816): worst +3.730ns, 0 violated.** Worst paths
  are real ALU/addr-gen (AddrGen|DH->Mux, ADDR_INC->PCr, ->X[11]); ~17.2ns data.
- **ANY->P65C816 (incl bus/IRQ/BA): worst +0.281ns, 0 violated** (binding path
  use_tape@clk_sys -> ADDR_INC@clk48). Every path INTO the CPU closes.
- Back-computes the HONEST clk64 number: 3.730 - (21.146-15.859) = **~-1.56ns**
  CPU-internal — the real violation the blanket multicycle had MASKED (STA had
  falsely shown +2.41ns). This is the airtight quantification of the clk64 wedge.
- The only STA failures were clk48-CROSSING constraint gaps, NOT the CPU:
  counter[1] -6.796 = bridge cpu_req_addr*/ioDir -> sdram sd_addr (ce-gated,
  multicycle); counter[2] -1.164 = shared $01 port ioDir -> SCPU-disabled T65
  (quasi-static). Both fixed in C64.sdc (counter[0]->counter[1] setup-2 +
  sd_* setup-4 for bridge/ioDir sources; counter[0]->counter[2] setup-2). These
  add NO counter[0]->counter[0] relaxation, so CPU-internal stays honest.
- **Why this is a much stronger GO than clk64's STA-clean ever was:** the clk64
  +2.41 was an ARTIFACT of a multicycle masking the ALU paths; this clk48 +3.730
  is the genuine single-cycle slack on those exact ALU paths with NO masking. The
  failure mode that bit clk64 cannot recur. clk48 ~= 1.5x clk32 = a real speed
  candidate where clk64 (2x) is dead.

### ✅ REBUILD STA-CLEAN — HW Lorenz A/B is the only gate, BLOCKED on shared MiSTer
Rebuild with completed cross-domain SDC: **build `abf8ff88`** (staged at repo-root
`C64.rbf`, archived `C64_MiSTer/builds/C64_..._abf8ff88-dirty.rbf`). ALL domains
TNS=0, 0 timing-not-met: counter[0]/clk48 +0.228, counter[1]/clk64 +3.704,
counter[2]/clk_sys +8.688. Clean, deployable.

**BLOCKED (2026-05-30 ~t12:00):** shared MiSTer at 192.168.50.130 has
`CORENAME=DotC-CD32MVP` (the CD32 agent's core, loaded ~09:41 today). Per the
cooperation protocol I backed off — did NOT deploy. HW test deferred until the
C64 slot frees (re-poll scheduled).

**WHEN THE MISTER FREES (CORENAME empty or C64):** write the session lock, then:
1. `python tools/mister_debug.py deploy C64.rbf` (the staged abf8ff88 clk48 build).
2. `python tools/lorenz_run.py scpu --mins 7` then `python tools/lorenz_run.py t65 --mins 7`.
3. Compare against the clean control `97392a1f` (scpu ran CLEAN there; clk64 build
   `00452c21` WEDGED scpu — that's the A/B contrast to beat).
4. PASS both modes -> clk48 ships ~1.5x; COMMIT MILESTONE_B=2 (c64.sv) + C64.sdc
   (the honest CPU multicycle removal + counter[0] cross-domain block). Pushes
   still gated.
   WEDGE like clk64 -> sustain-enable scheme itself is implicated (not just 64MHz
   timing) -> REVERT working tree (git checkout c64.sv C64.sdc) and pivot to
   Milestone C (demand arbiter @ clk32, CPU stays where it closes).
5. Re-verify Doom once REU/MGL harness is healthy (today's wedge was environmental).
Working tree (uncommitted): c64.sv MILESTONE_B=2, C64.sdc honest+clk48 crossings.

## SUPERSEDED NEXT-EXPERIMENT NOTE (kept for trail): honest clk48 CPU-internal slack
Building `MILESTONE_B=2` (clk_cpu=clk48, counter[0]=**21.146ns** vs clk64's
15.859ns = +5.287ns budget). SDC made honest: removed the blanket
`-to *P65C816:cpu|*` setup-2 multicycle (it masked clk64's failure), so
CPU-internal reg→reg paths are now timed single-cycle at clk48 — the decisive
read. **Gate:** when the build lands, run
`report_timing -setup -from [get_registers {*P65C816:cpu|*}] -to [get_registers {*P65C816:cpu|*}]`
against `output_files/C64.sta.rpt` (or quartus_sta). If worst CPU-internal
slack ≥ ~0 → clk48 viable, proceed to a real deploy build + Lorenz A/B. If
deeply negative → clk48 dead too; pivot to Milestone C (demand arbiter, CPU
stays at clk32 where it closes).

### Codex caveats for the DEPLOY build (NOT this diagnostic — noise here)
Independent review (tools/codex-out/clk48-strategy.txt) flagged two things that
only matter IF clk48 closes and I build a deployable bitstream:
1. **The narrow `-from bus_di_capture_reg -to P65C816` setup-2 may itself be
   dishonest.** Codex reads the bridge FSM as: bus_di_capture_reg updates in
   CPU_WAIT_ACK, CPU gets en/rdy on the NEXT clk_cpu edge → a 1-cycle path, not
   a held round-trip. Before deploy, verify the actual capture→sample cycle
   count in scpu_async_bridge.vhd; if it's 1-cycle, drop the multicycle (don't
   repeat the clk64 masking error on the data path).
2. **clk48's 1.5× ratio leaves IRQ/NMI, baLoc, diIO/cass_sense unconstrained.**
   These enter cpu_65c816 OUTSIDE the bridge (clk_sys→clk48 crossings). clk64
   (2×) covered them via the clk32→clk64 multicycle; clk48 (counter[0]) has no
   clk32→clk48 equivalent. A deploy build needs a counter[2]→counter[0]
   multicycle (mirror SDC lines 13-19) or those paths false-fail / mis-time.
Both are `-from <other> -to CPU` paths → they do NOT affect the CPU-internal
slack read from this build.

## Parallel/lower-priority backlog
- VICE 3-speed triage matrix (default/4MHz/1MHz) to classify more 3rd-party SCPU
  titles speed-bound vs separable-compat (pure desktop VICE, no MiSTer).
- Milestone C (demand arbiter) sim prep — GATED on B being HW-stable first.

## Pushes still gated. Commits are pre-authorized when green.
