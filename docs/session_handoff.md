# Session handoff — 2026-05-29: autonomous compat+speed loop (iteration 1)

## STATUS
Self-paced `/loop` driving the north-star: **make the SCPU as compatible and
fast as possible.** Iteration 1 ran OFF-DEVICE — the MiSTer was held by the
CD32 agent (`/tmp/CORENAME = Universe-DCON-CD32MVP`), so per the cooperation
protocol no deploy/Lorenz this iteration; off-device GHDL + analysis + a
proactive build instead.

### Done + GREEN (commit pending asterix-sweep completion)
- **GHDL CPU-correctness baseline tool:** `tools/ghdl_compat_sweep.ps1`. Runs the
  per-scenario runners in `sim/p65c816_tb` (each in a child pwsh so their `exit`
  doesn't leak), classifies FAIL by non-zero exit OR a fired fail-marker
  (`FAIL`/`MISMATCH`/`severity failure`) in the log. Persists a one-line-per-runner
  baseline to `tools/ghdl_compat_sweep_results.txt`.
  **Core sweep = 7/7 PASS** (lda-long, REP, native-switch, xflag, copy-loop,
  jml-indirect-long, jml-long-crossbank, jmp-indirect-pagewrap, long-abs,x-carry,
  sr-emu-wrap, scpumips-copy). Asterix integration sweep = 4/7 PASS, 3 FAIL
  (`phase1`, `overlay`, `full_nmi`) — PRE-EXISTING benches that reproduce the
  asterix demo-dispatcher/NMI bug on the bare CPU (not caused by this iteration;
  none of my edits touch the GHDL datapath). Real compat gap = a future lever.
- **Fixed a tolerated false-alarm in `sim/p65c816_tb/p65c816_rep_tb.vhd`.** The CPU
  is CORRECT: REP #$30 clears M+X (P $35->$05) and `LDA #$EAEA` decodes as a 3-byte
  16-bit immediate — proven by the address bus fetching $0804/$0805/$0806 (cyc
  22-24 in the trace). The bench hard-coded the wrong expected PC ($0807) behind
  `severity warning`; this core's `DBG_PC` points one byte PAST the freshly-latched
  opcode (uniform: REP latches at PC=$0803, LDA at $0805), so BRA-in-IR with
  PC=$0808 is the CORRECT pass value. Fixed the expectation, documented the PC
  convention, added a hard `severity failure` gate so any real regression fails the
  sweep by exit code. -> REP->16-bit-immediate path now VERIFIED CORRECT (heavily
  used by native SCPU code).

### Done + BUILDING (uncommitted — needs HARDWARE validation before commit)
- **SCPU fast-by-default** (`C64_MiSTer/c64.sv:1949-1958`). `turbo_mode`/`turbo_speed`
  now force max turbo (4x) when `supercpu_enable`.
  - **Why:** OSD turbo (`status[46/47]` enable, `status[49:48]` speed) and
    `supercpu_enable` (`status[82]`) were INDEPENDENT. With OSD Turbo off (default)
    `turbo_m="000"` so only `CYCLE_CPUC` fires -> the SuperCPU ran at **~1 MHz**
    regardless of being "enabled". Real SCPU software controls speed via
    $D07A(slow)/$D07B(fast) -> `scpu_force_1mhz`, with NO knowledge of the OSD —
    so software asking to "go fast" still got 1 MHz unless the user also toggled
    OSD Turbo. This is the single biggest compat+speed footgun found.
  - **Shape:** OR'd `supercpu_enable` into the disk-aware "always" turbo term
    (`(status[47] | supercpu_enable) & ~disk_access`) and forced `turbo_speed` to
    `2'b10` (4x) in SCPU mode. Turbo therefore still drops to 1 MHz during IEC
    activity (`disk_access`, c64.sv:2478 — asserts on any IEC-clk edge, holds 0.5s)
    via the SAME path vanilla smart-turbo uses -> LOAD/SAVE serial timing preserved.
    `scpu_force_1mhz` ($D07A/$D072/cia2_throttle) still modulates on top. Vanilla
    (`supercpu_enable=0`) path is bit-identical.
  - **Build:** `b33jz3ihu` running (started ~00:55). Archived to `C64_MiSTer/builds/`,
    staged at `C64.rbf` on success.

## Speed baseline (verified file:line; the loop's "effective-MHz" axis)
- clk32 = 31.53 MHz; 1 sysCycle period = 32 clk32 = 16 CPU slots (CPU0..CPUF).
  CPU advances only on `enableCpu` pulses (`cpu_cyc` -> 2-FF `cpu_cyc_s` ->
  `enableCpu` -> `enableCpu_816`).
- Live bridge `scpu_async_bridge` runs EFF_BRIDGE_ACTIVE='0' (pure passthrough,
  `cpu_di_out<=bus_di_in`, `cpu_rdy_out<='1'`) = ZERO added latency.
- One bank-$00 SDRAM access = ~2 clk32 (busy reservation 3 clk32, fpga64_sid_iec
  :3308) — already shorter than the 4-clk32 CPU0->CPU4 slot spacing.
- **Effective MHz:** turbo off -> 1 slot/period (CYCLE_CPUC only) = ~1 MHz.
  turbo 4x -> CPU0/4/8/C = 4 slots = **~4 MHz = current ceiling** (not 20).
- **Dominant bottleneck = sysCycle slot arbitration, NOT SDRAM latency.** CPU gets
  <=4 of 16 slots. Alt-slots CPU2/6/A/E are HARD-GATED off (fpga64_sid_iec.vhd:3358
  `alt_fire_r<='0'`, :3381 `alt_fire_r2<='0'`); HIT predictor forced off (:3206).

## NEXT — on hardware (when MiSTer frees AND build b33jz3ihu done)
Validation battery for the auto-turbo change (deploy `C64.rbf` to `/media/fat/_Test/`):
1. **Boot:** cold-boot scpu mode (cfg byte10=0x0C) -> READY prompt, SCPU64 banner.
2. **LOAD:** `python tools/iec_wedge_probe.py scpu --secs 90` -> must NOT wedge at
   $ED5A, expect `IE:1F`. (Confirms 4x default didn't re-break the LOAD fix.)
3. **Doom:** `python tools/deploy_and_probe_doom.py` -> must reach $2C main loop +
   title/menu bitmap. (REU-in-turbo already fixed via iof_fall_pulse.)
4. **Speed:** run a timing loop / scpu_speedtest -> expect ~4 MHz (was ~1).
- All green -> **commit `c64.sv`**. LOAD/Doom regress -> disk_access gate or
  cia2_throttle insufficient at 4x; narrow (try `turbo_speed` 2x first) or revert.

## NEXT speed lever (future iteration — GHDL-first, medium risk)
Re-enable alt-slots (CPU2/6/A/E) gated on the real `sdram_ready` rising edge ->
~6-8 MHz. Prior attempts wedged Doom via a `cpu_cyc->ramCE->cart_ce` synthesis
hazard (fpga64_sid_iec.vhd:3217) — PROVE in `sim/sdram_pm_tb` + `sim/arbiter_demand_tb`
BEFORE any Quartus build. Do NOT re-enable the bank-$00 cache (CACHE_ACTIVE='1') —
black screens (v159/v161), files are dead/uncompiled.

## Shared-MiSTer + tooling notes (unchanged)
- Check `/tmp/CORENAME` before disruptive ops (C64=mine; anything else=back off).
- Winsock `getaddrinfo` race worked around via `socket.create_connection`+`sock=`
  in `mister_debug.py` / `iec_wedge_probe.py` / `deploy_and_probe_doom.py`.
- Local commits unpushed beyond origin `747cdea`: 20e0ac5, 9437377, 6df990c,
  5f4f574 (+ this iteration's pending REP/sweep commit). **Pushes stay gated.**
