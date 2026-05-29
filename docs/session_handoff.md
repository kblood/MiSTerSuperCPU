# Session handoff — 2026-05-29: autonomous compat+speed loop

## STATUS
Self-paced `/loop` driving the north-star: **make the SCPU as compatible and
fast as possible.** Iteration 2 SHIPPED a validated speed win.

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

## NEXT lever — emulation-mode turbo (the SuperCPU's PRIMARY use case)
Native-only turbo MISSES the main SCPU use case: accelerating EMULATION-mode 6502
code (GEOS+SCPU, productivity sw, accelerated BASIC) — those run at 1 MHz today.
Fix shape: run emulation mode fast too, but **force 1 MHz only while PC is in the
KERNAL IEC serial routine range** (~$ED00-$EF00), since that's the only
timing-fragile emulation code. A PC-range throttle into `scpu_force_1mhz` would do
it. Validate: LOAD (must stay IE:1F) + a fast emulation-mode compute loop + Doom.
GHDL-prove the PC-range decode if feasible; otherwise small RTL + careful HW test.

## NEXT speed lever (later — GHDL-first, medium risk)
Re-enable alt-slots (CPU2/6/A/E) gated on real `sdram_ready` rising edge -> ~6-8
MHz. Prior attempts wedged Doom via a `cpu_cyc->ramCE->cart_ce` synthesis hazard
(:3217). PROVE in `sim/sdram_pm_tb`+`sim/arbiter_demand_tb` BEFORE any build. Do
NOT re-enable the bank-$00 cache (CACHE_ACTIVE='1') — black screens, dead files.

## CPU-correctness baseline (off-device, iteration 1)
`tools/ghdl_compat_sweep.ps1` — core sweep 7/7 PASS. Asterix integration sweep
4/7 (phase1/overlay/full_nmi FAIL = pre-existing demo-dispatcher/NMI compat gaps,
a future lever; not caused by turbo changes). Fixed a tolerated false-alarm in
`p65c816_rep_tb.vhd` (PC convention; REP->16-bit-immediate VERIFIED correct).

## Shared-MiSTer + tooling notes
- Check `/tmp/CORENAME` before disruptive ops (C64=mine; else back off).
- Winsock `getaddrinfo` race worked around via `socket.create_connection`+`sock=`.
- Local commits unpushed beyond origin `747cdea`: 20e0ac5, 9437377, 6df990c,
  5f4f574, c258e29 (+ this iteration's native-turbo commit). **Pushes stay gated.**
- Uncommitted-by-design: c64.sv / debug_pkg.svh / debug_uart_pool_fmt.sv / C64.qpf
  carry local IE:## UART instrumentation — NOT fixes, leave uncommitted.
