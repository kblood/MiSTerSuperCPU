# Session passover 2026-04-09: LDA long Fix A', Fix A''' both ineffective

## TL;DR

- **Fix A' (post-I/O delay via 3-stage pipeline for ALL post-I/O cycles) broke KERNAL boot.**
  Symptom: CPU stuck at PC=$FF48 with IR=$00 (BRK), emulation mode, status=$35.
  Root cause: Conflict with BRAM path — at 20 MHz with BRAM serving, my fix extended
  the SDRAM pipeline such that bram_hit_d1 generation was gated for additional cycles,
  altering BRAM delivery timing in a way that caused KERNAL to hit BRK somewhere in
  init. Detail: line 2126 cancel path uses bram_hit_d1 which is gated by cpu_cyc_s=0
  and superram_enable_delay=0. Fix A' holds these high for 1 extra clk32, delaying
  BRAM delivery. Timing slack was all positive (no STA violations), so it's a logic
  issue not a timing issue.

- **Fix A''' (1 MHz gated version of Fix A') had no effect on sr_slow.prg.**
  The CAS race theory is WRONG: at 1 MHz mode, cpu_cyc only fires at CPUC (no turbo
  slots), so there are ~32 clk32 between CPU cycles — plenty of time for SDRAM CAS
  latency (2.5 clk32) to settle. Adding 1 clk32 of extra delay accomplishes nothing
  because the CPU was already sampling with plenty of margin.

- **Boot works fine with Fix A''' deployed** (verified at 09:07 — BASIC splash, READY,
  overlay showing A:E5AF K:00 E:1). This confirms the 1 MHz gate isolates it from
  20 MHz BRAM operation — no regression.

- **sr_align.prg still crashes with Fix A''' at 20 MHz** — confirming Fix A''' is
  truly a no-op at 20 MHz (scpu_speed_1mhz='0' gate prevents any action).

## Current file state (2026-04-09 09:10)

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` **REVERTED to pre-Fix-A baseline**. All
  post_io_pending / post_io_pending_1mhz signal declarations and consumer logic
  removed. The file is functionally identical to the last known-good working state
  (commit 36c135c + existing uncommitted SuperCPU work, minus Fix A'/A''' experiments).
- Clean baseline build in flight: `build_baseline_revert.log` (background ID bf1qqcc9v).
- Deployed RBF on MiSTer is still the Fix A''' build (no-op at 20 MHz, ineffective
  at 1 MHz). Once the baseline build completes, redeploy to make file/deploy match.

## Investigation details

### Timeline

- Session start: user said "Deploy fix A and keep going, no need to ask me about
  these things. Go with what you think is best." Carried forward from prior session
  which had implemented Fix A' but not tested it.
- 08:41: Deployed Fix A' via `deploy C64_MiSTer/output_files/C64.rbf`. Screenshot
  showed black screen with overlay stuck at A:FF48 K:00 I:00 E:1 P:35. UART output
  `A:FF48 K:00 B:00 S:01xx P:35 I:00 E:1 F:xxxx T:21` loops — CPU pinned at $FF48 in
  KERNAL BRK handler, status P:35 has break flag set, IR=$00.
- 08:45: Diagnosed conflict between Fix A' io_in_pipeline set and BRAM-driven
  enableCpu_816 path.
- 08:47-08:50: Added BRAM-cache guard to Fix A' (cache_hit_d1/bram_hit_d1/phantom_enable
  check), but realized the guard is ineffective because those signals are gated
  against cpu_cyc='1' in their own generation process.
- 08:53: Reverted Fix A' entirely and implemented Fix A''' (1 MHz gated).
- 09:00: Baseline build failed — was still working on Fix A'''.
- 09:06: Fix A''' build succeeded, deployed, booted fine.
- 09:07: sr_slow.prg tested with Fix A''' — **still crashes**. CAS race theory wrong.
- 09:09: Reverted Fix A''' in source file. Rebuild kicked off.

### Structural analysis: why both attempts failed

**Fix A' at 20 MHz:** The BRAM cancel path at line 2126 is:

```vhdl
if (cache_hit_d1 = '1' or bram_hit_d1 = '1' or phantom_enable = '1') and turbo_en = '1' then
    cpu_cyc_s <= "00"; io_in_pipeline <= '0'; enableCpu <= '0'; ...
```

and the BRAM hit generation at line 1605 gates bram_hit_d1 with:

```vhdl
and cpu_cyc = '0'
and cpu_cyc_s(0) = '0'
and cpu_cyc_s(1) = '0'
and superram_enable_delay = '0'
and enableCpu = '0'
```

Fix A' forces io_in_pipeline='1' at the post-I/O cpu_cyc, which cascades into
superram_enable_delay='1' 1 clk later (because `if superram_in_pipeline='1' or
io_in_pipeline='1' then superram_enable_delay <= cpu_cyc_s(1)`). That holds
superram_enable_delay='1' for 1 extra clk32, which gates bram_hit_d1 generation
for 1 extra clk32. BRAM fires later than normal.

Normal 2-stage path:
- cpu_cyc at N, enableCpu at N+3 (3 clk32 delay)

Fix A' 3-stage path:
- cpu_cyc at N, enableCpu at N+4 (4 clk32 delay)

This is one extra clk32 on the SDRAM path. The extra clk32 doesn't directly cause
a crash, but it SHIFTS all subsequent signals (io_enable, BRAM generation, etc.)
by 1 clk32 relative to the sysCycle. During KERNAL boot, some sequence (likely
an I/O → RAM → I/O sequence) hits a state where the shifted timing causes cpuDi
to be sampled with an unexpected byte, leading to BRK.

Whether that byte is stale dout_r or something else is unclear — Fix A' shouldn't
be making data MORE stale, only allowing more settling time. But empirically it
broke boot.

**Fix A''' at 1 MHz:** At 1 MHz, turbo_en='0' (line 2289), so the cancel path
never fires. The cpu_cyc only fires at CPUC of each rotation (no turbo slots,
turbo_m="000"). CPU rotation is 32 clk32 long, so CPU cycles are 32 clk32 apart.

- cpu_cyc at N
- enableCpu at N+3 (2-stage) or N+4 (Fix A''' 3-stage)
- Next cpu_cyc at N+32

There's 29-32 clk32 of idle after enableCpu fires. Plenty of time for ANY SDRAM
read to settle (~2.5 clk32). The post-I/O fetch at N+3/N+4 sees dout_r fully
updated with the new byte.

But the CPU still executes $00 instead of the correct byte. This rules out SDRAM
CAS latency as the cause at 1 MHz. The bug must be in a different mechanism:

1. **cart_addr mux timing**: scpu_sdram_addr for bank $00 uses cart_addr (via
   cartridge.v), which may have a combinational mux or registered stage with a
   stale value from a prior cycle. If cart_addr at the post-$AF cpu_cyc still
   reflects the $D020 I/O cycle's address instead of the $0820 post-$AF address,
   SDRAM reads from the wrong location.
2. **cs_ram or cs_ramLoc latching**: if cs_ramLoc (in buslogic.vhd) is derived
   from a gated version of cpuAddr that lags, dataToCpu might fall through to
   `lastVicData` (default) instead of ramData.
3. **cpuAddr_pre propagation**: between state 4 (I/O at $D020) and state 0
   (fetch at $0820), cpuAddr might transition late, causing the SDRAM to read
   $D020 again (which returns $00 from some default).
4. **dataToCpu default path**: line 330 in buslogic: `dataToCpu <= lastVicData;`
   is the default. If NONE of the cs_* conditions fire (e.g., all address-decode
   signals are low during a brief window), dataToCpu falls through to lastVicData.
   If lastVicData happens to be $00 at that moment, the CPU sees $00. But
   lastVicData is updated by VIC which would usually have non-zero data. Still
   possible as a transition glitch.

### Test results with Fix A''' deployed

| Test | Result | Expected | Notes |
|---|---|---|---|
| KERNAL boot | ✓ BASIC splash + READY | works | Overlay A:E5AF K:00 E:1 |
| sr_align.prg | ✗ wiped READY | crashes (unchanged) | Fix A''' no-op at 20 MHz |
| sr_slow.prg | ✗ wiped READY | fix theory wrong | CAS race was not the bug |

Other tests (sr_brd2, sr_jml, sr_cmp, sr_idl, sr_lday, sr_lram) not run with
Fix A''' since it's a no-op at 20 MHz — results would be identical to baselines
in `fix_a_before_*.png`.

### What I verified

- Post-fix file state has no residual `post_io_pending*` signals (grep clean).
- Timing slack with Fix A' was all positive (slowest clock 0.389 ns setup). Not
  a timing issue.
- bram_hit_d1 generation is gated against cpu_cyc='1', cpu_cyc_s, superram_enable_delay,
  enableCpu. Fix A' delays bram_hit_d1 by 1 clk32 in the post-I/O window.
- cpuDi mux priority: iof_detect > scpu_rom_stub > bram_hit_d1 > cache_hit_d1
  > superram_data_r > scpu regs > cpuDi_raw. Default fall-through is cpuDi_raw
  which is dataToCpu from buslogic.
- sdram.v: STATE_READ = RASCAS(2) + CAS(2) + 1 = 5 clk64 = 2.5 clk32 from CE
  rising to dout_r valid. clocked at clk64 (64 MHz).
- scpu_speed_1mhz is set by STA to $D07A at line 1984, taking effect at the
  NEXT clk32 edge after cpuWe goes high. In sr_slow sequence, this happens
  BEFORE the $AF executes, so scpu_speed_1mhz='1' during $AF state 4 and 0.

## Next investigation steps (not attempted this session)

The bug is NOT a post-I/O CAS race. To find the actual cause:

1. **Add diagnostic: capture cpuAddr, cs_ram, ramData at every cpu_cyc during
   $AF execution.** A simple shift register in fpga64_sid_iec.vhd capturing the
   last 8 cpu_cyc events (addr, data, cs_ram, sysCycle) and routing to UART
   via a debug register read. Then run sr_slow and compare traces.

2. **Check cart_addr timing in cartridge.v.** Verify whether cart_addr is
   combinational from c64_addr or has a registered stage. If registered, the
   1-cycle lag between state 4 (I/O) and state 0 (post-fetch) could read the
   wrong SDRAM address.

3. **Check dataToCpu default path.** If lastVicData is the fall-through, test
   whether VIC is outputting $00 at the moment of the post-$AF fetch. This
   could be a c-access/g-access race.

4. **Try registering cpuDi or cpuDi_raw** (deliberately introducing a 1-clk32
   lag). If the bug changes character, data path timing is implicated.

5. **SignalTap Logic Analyzer** at the SDRAM address and data pins during sr_slow
   execution, triggering on cpuAddr=$0820. This gives definitive ground truth.

6. **Check if SC_CORRUPT_S0_NEXT in the GHDL bare-core bench can be matched to
   a specific system signal**. The bench forces D_IN=$00 when IR=$AF AND STATE=0
   AND PC=$0804. What system-level event could correspond to this? Possibly the
   state-0 fetch races the clock boundary between CPU phase and VIC phase.

## Files modified this session

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — Fix A' added (09:00), reverted (09:09),
  Fix A''' added (09:30 earlier), reverted (09:09 now)
- `docs/session_passover_2026_04_09.md` — this file

## Baselines preserved

All 7 pre-fix baseline screenshots preserved in `fix_a_before_*.png`:
- sr_align, sr_brd2, sr_cmp, sr_idl, sr_jml, sr_lday, sr_lram
- Plus new: `fix_appp_boot.png` (Fix A''' boot — works), `fix_appp_sr_slow.png`
  (Fix A''' sr_slow — still crashes), `fix_appp_sr_align.png` (Fix A''' sr_align —
  crashes same as baseline, confirming 20 MHz no-op).

## Key insight for future work

**The bug is NOT a timing race.** At 1 MHz where cycles are 32 clk32 apart,
there's 29+ clk32 of settling slack after enableCpu. Anything that takes
<10 clk32 to propagate (which is everything in the datapath) is fine. The
bug must be LOGICAL:

- Wrong address being read
- Wrong mux output being selected
- cpuDi sampled at the wrong clk32 edge (but at 1 MHz the edges are widely
  separated, so this would be an off-by-one in the state machine, not timing)
- Some signal being in an unexpected state during $AF execution

The GHDL bare-core bench confirmed $AF execution is correct in isolation. So
the bug is at the SYSTEM level, in how the system interprets the CPU's address
output OR how it delivers data back. The most likely culprits are the
buslogic dataToCpu path and the cart_addr/scpu_sdram_addr mux.

## Post-revert trace (2026-04-09 09:58)

Baseline rebuild (`build_baseline_revert.log`) completed 09:30, deployed to
MiSTer 09:58, KERNAL boots to READY normally (overlay A:E5AF K:00 E:1).
File state and deployed RBF now consistent.

### Signal path trace from cpuAddr to SDRAM (bank $00, LDA long sr_slow case)

Walked the full combinational path. Every hop is concurrent/combinational —
no registered stages hide between the CPU output and the SDRAM input:

1. `cpuAddr_pre <= cpuAddr_816` (fpga64_sid_iec.vhd:1280) — combinational mux
2. `cpuAddr <= cpuAddr_pre when dma_active='0'` (line 2273) — combinational
3. buslogic `currentAddr` process (fpga64_buslogic.vhd:377-500) — combinational,
   selects `cpuAddr` when `cpuHasBus='1'`, otherwise `vicAddr`. This is the
   "long combinational path" that c64.sv:1291-1294 already flagged as
   violating -24ns slack on clk32→clk64 for the SuperRAM path.
4. `systemAddr <= currentAddr` (buslogic:521) — wire
5. `ramAddr <= systemAddr when not wb_drain_active` (fpga64_sid_iec.vhd:2084)
6. `c64_addr = ramAddr` (port, c64.sv:1464)
7. cartridge `addr_in <= c64_addr`, `addr_out = addr_in` (cartridge.v:832) —
   combinational `always begin` (no @)
8. `cart_addr = mem_addr = addr_out` (cartridge.v:797)
9. `scpu_sdram_addr = (bank != $00) ? scpu_superram_addr : cart_addr`
   (c64.sv:1307-1309) — **bank $00 uses the long cart_addr path; SuperRAM
   uses the FAST dbg_cpu_addr shortcut**
10. sdram.v latches at `ce && !last_ce` on clk64 rising edge (line 161)

**Key asymmetry discovered:** `scpu_superram_addr` at c64.sv:1300 uses
`dbg_cpu_addr = cpuAddr_pre` (direct CPU output, 1 hop). But bank $00 and
ROM accesses fall through to `cart_addr`, which traverses the entire
buslogic decode (~9 hops of combinational logic). The comment at
c64.sv:1291-1294 explicitly says this path has -24ns slack on clk32→clk64.

At 1 MHz this shouldn't matter — there's 32 clk32 (≈1 µs) of settling
between cpu_cyc events. But the asymmetry is real and bank $00 LDA long is
exactly the case where cpuAddr changes rapidly from I/O ($D020) to RAM
($0820) across the state-4→state-0 boundary.

### SDRAM read pulse analysis (sr_slow at 1 MHz)

Re-verified the pulse sequence for $AF at 1 MHz (turbo_m=000, cpu_cyc fires
only at CPUC):

- State 0 ($AF opcode at $081C): cs_ram=1, cpu_cyc@CPUC, ramCE fires, SDRAM
  reads $081C, dout_r=$AF.
- State 1 ($1D low operand): same, dout_r=$20.
- State 2 ($1E high operand): same, dout_r=$D0.
- State 3 ($1F bank operand): same, dout_r=**$00** ← the bank byte.
- State 4 ($D020 data fetch): cs_vic=1, cs_ram=0. `ramCE = cs_ram when
  sysCycle=CYCLE_VIC0 or cpu_cyc='1' else '0'` — **ramCE does NOT fire for
  CPU at CPUC because cs_ram=0**. But VIC0 might fire ramCE with vicAddr
  (VIC display reads). During VIC0, cpuHasBus=0, so currentAddr=vicAddr,
  cs_ram=1 typically (VIC needs screen/char data), so ramCE fires for VIC
  display → dout_r updates with VIC display bytes.
- State 0 (post-$AF at $0820): cs_ram=1, cpu_cyc@CPUC, ramCE fires, SDRAM
  reads $0820. dout_r SHOULD update to byte at $0820 = $48 (PHA).

**If this theory holds, there is no stale-dout_r issue** — between state 3
and state 0, several VIC0 cycles refresh dout_r with display bytes, and
state 0 fires a fresh CPU read. dout_r at state-0 enableCpu time must
contain the $0820 byte.

**So the "dout_r stale with $00 from state 3" theory from the GHDL bench is
incomplete.** The bench's SC_CORRUPT_S0_NEXT scenario reproduces the
symptom by forcing $00 at the post-$AF fetch, but the system-level
mechanism that produces that $00 is still unclear.

### New strongest hypothesis

Something in the bank $00 cart_addr path is delivering either:
- a stale c64_addr that reads from the wrong SDRAM location during the
  state-0 cpu_cyc, OR
- a brief glitch where cs_ramLoc drops low and dataToCpu falls through to
  `lastVicData` (buslogic:330 default), which might be $00 during VIC
  blanking or reset.

The GHDL bench cannot reproduce this because the bench has no bus mux,
no VIC, no `lastVicData`, and no combinational path from systemAddr
through buslogic. The bench proves **the CPU core is innocent**, but the
system glue layer is where the bug lives.

### Recommended next step (concrete)

**Add a hardware diagnostic buffer**, not more theorizing:

1. In fpga64_sid_iec.vhd, add an 8-entry circular buffer that captures
   at every `enableCpu='1'`: {cpuAddr_pre(15:0), cpuDi(7:0), dbg_ir_816(7:0),
   sysCycle(4:0)}. That's 37 bits × 8 = 296 bits of state.
2. Freeze the buffer on a trigger: `dbg_ir_816=$AF and cpuDi=$00 and
   cpu_cyc='1'` — catches the moment $AF appears AND its bank operand
   reads as $00 (or freeze on IR=$00 after IR was $AF).
3. Route the captured data to UART via the existing debug_info path
   (c64.sv:1800-1900 area sends the A:/K:/B:/S: overlay fields). Add a
   new trace field or reuse spare bytes after the current trailer.
4. Deploy, run sr_slow, capture UART. The trace will show exactly which
   address and data byte was delivered to the CPU at each cycle of the
   crashing $AF execution.

This is the SignalTap substitute. It's ~30 lines of VHDL and ~10 lines
of UART format changes, and it gives ground truth.

### Alternative cheap diagnostic: try routing bank $00 through dbg_cpu_addr

**One-line experiment** — before building the diagnostic buffer, try:

```verilog
wire [24:0] scpu_sdram_addr = cpu_has_bus
                              ? {1'b1 & (supercpu_bank != 8'h00), supercpu_bank, dbg_cpu_addr}
                              : cart_addr;
```

i.e. use dbg_cpu_addr for ALL CPU reads (not just banks $01+), masking
bit[24] to 0 for bank $00. If the bug disappears, the long cart_addr
path is confirmed as the root cause — and the fix is to bypass buslogic
entirely for SuperCPU bank $00 reads.

This is risky because cart_addr has decoding we might need (ROM banking,
EasyFlash), but as a one-shot experiment it would isolate the path fast.

## Bank-$00 dbg_cpu_addr bypass experiment — NEGATIVE RESULT (2026-04-09 15:00)

**Tried it. The hypothesis is wrong. The cart_addr long path is NOT the root cause.**

### What was changed

`c64.sv:1300-1309` modified to route SuperCPU bank-$00 reads through
`{9'b0, dbg_cpu_addr}` instead of `cart_addr`:

```verilog
wire [24:0] scpu_bank0_addr = {9'b0, dbg_cpu_addr};
wire [24:0] scpu_sdram_addr = (supercpu_enable && cpu_has_bus)
                               ? ((supercpu_bank != 8'h00) ? scpu_superram_addr : scpu_bank0_addr)
                               : cart_addr;
```

This bypassed the entire buslogic→cartridge.v combinational chain for bank
$00 CPU reads, replacing it with the same direct `cpuAddr_pre` shortcut
already used for SuperRAM. cart_addr was preserved as fallback for VIC
reads (cpu_has_bus=0).

### Build results

- Build: clean. 0 errors, 211 warnings (normal). `build_bank0_bypass.log`.
- Worst-case setup slack: 3.249 ns (positive). No new timing violations.
- Resource utilization unchanged.

### Hardware test results

| Test | Result | Screenshot |
|---|---|---|
| KERNAL boot | ✓ BASIC splash + READY normally | scr_bypass_boot.png |
| sr_slow.prg | ✗ wiped READY warm-restart, **identical to baseline** | scr_bypass_sr_slow.png |

The sr_slow screenshot is **pixel-identical** to `fix_appp_sr_slow.png`
(the prior failure baseline). The crash signature is unchanged. The
bypass had no effect on the bug.

### What this proves

1. **The address path to SDRAM is not the bug.** Even when cpuAddr_pre is
   delivered to sdram.addr through a single combinational hop with no
   bus mux, the crash still happens. The address arriving at the SDRAM
   is correct in all cases.
2. **Long combinational path / -24ns slack is irrelevant for this bug.**
   At 1 MHz the bus mux had ~32 clk32 of settling slack already. Removing
   the long path didn't change anything because the long path was never
   the problem.
3. **The bug must be in the data path, not the address path.** Either:
   - SDRAM is reading the correct address but `dout_r` contains wrong data
   - `dout_r` is correct but the cpuDi mux selects a wrong source
   - cpuDi reaches the CPU correctly but the CPU samples it at the wrong
     clock edge (state-machine timing issue)

### Reverted

`c64.sv` reverted to baseline (commit 36c135c equivalent). Need to redeploy
clean baseline RBF before further investigation.

### Next concrete step (re-prioritized)

The bank-$00 address bypass was supposed to be the cheap experiment.
It failed. The diagnostic buffer is now the only path forward. Specific
plan:

1. Add a small capture buffer in `fpga64_sid_iec.vhd` that records
   `(cpuAddr_pre, cpuDi, dbg_ir_816, sysCycle)` at every `enableCpu='1'`.
2. Trigger the freeze on `dbg_ir_816 = $00 AND prev_ir = $AF` (BRK
   immediately after $AF — this is the failure signature).
3. After freeze, dump the capture buffer through 4 spare 8-bit debug
   registers reachable via the existing UART overlay path.
4. Run sr_slow, capture UART, decode the trace.

The captured trace will show definitively:
- What address the CPU presented at the post-$AF state-0 fetch
- What byte cpuDi delivered at that fetch
- Whether the byte changes between the SDRAM dout and the cpu_di final mux

This is the only way to break the deadlock — every other angle has been
ruled out by reasoning or by experiment.
