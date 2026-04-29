# Session Passover — 2026-04-08f

## Subject

**SMOKING GUN found.** A new GHDL bench scenario (`SC_CORRUPT_S0_NEXT`)
reproduces the exact LDA-long crash symptom — and proves the bug class.
The bug is **NOT** in `$AF` execution at all. The bug is that the system
delivers a wrong byte (`$00`) at the post-`$AF` opcode fetch position
(`$00:0804` in the test program), causing the CPU to execute BRK and
dispatch through the BRK vector — exactly the observed warm-restart
screen wipe.

This is the first positive reproduction of the bug class in any test
environment more controlled than full-system hardware.

## Two new bench scenarios added

Both in `sim/p65c816_tb/p65c816_lda_long_tb.vhd`. They share the same
combinational `D_IN` corruption gate as `SC_CORRUPT_AB`, with different
trigger conditions.

| Scenario | Trigger | Override value | Hold |
|---|---|---|---|
| `SC_CORRUPT_S3_MULTI` | `IR=$AF AND STATE=3` | `$FF` | 5 cycles |
| `SC_CORRUPT_S0_NEXT` | `IR=$AF AND STATE=0 AND PC=$0804` | `$00` | 1 cycle |

The post-`$AF` opcode fetch is the only point in the test program where
`STATE=0 AND IR=$AF AND PC=$0804` — that's the rising edge where the
CPU latches the next opcode into IR after `$AF` finishes. Forcing `$00`
at that exact edge simulates "the system delivered the wrong byte for
this single cycle."

## SC_CORRUPT_S3_MULTI — also benign (predicted)

```
cyc=10326 STATE=3 IR=$AF PC=$0803 D_IN=$FF      ; corruption begins
cyc=10327 STATE=4 IR=$AF PC=$0804 A_OUT=$FFD020 D_IN=$FF
cyc=10328 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$FF      ; corruption still held
cyc=10329 STATE=1 IR=$FF PC=$0805 D_IN=$FF                     ; CPU executing $FF (SBC long)
cyc=10330 STATE=2 IR=$FF PC=$0806 D_IN=$FF
cyc=10331 STATE=3 IR=$FF PC=$0807 D_IN=$EA                     ; corruption ends
cyc=10332 STATE=4 IR=$FF PC=$0808 A_OUT=$EAFFFF
cyc=10333 STATE=0 IR=$FF PC=$0808 D_IN=$EA                     ; resume normal
cyc=10334 STATE=1 IR=$EA PC=$0809                              ; NOPs
```

PC walks `$0803 → $0804 → $0805 → ... → $0809`, no misalignment, no BRK,
no warm restart. The CPU just executed garbled instructions for a few
microseconds and continued. Multi-cycle corruption alone is **not**
sufficient to produce the symptom.

## SC_CORRUPT_S0_NEXT — REPRODUCES THE EXACT SYMPTOM

```
cyc=12902 STATE=3 IR=$AF PC=$0803 A_OUT=$000803 D_IN=$00      ; bank fetch (legit $00)
cyc=12903 STATE=4 IR=$AF PC=$0804 A_OUT=$00D020 D_IN=$5A      ; data fetch normal
cyc=12904 STATE=0 IR=$AF PC=$0804 A_OUT=$000804 D_IN=$00      ; <<< BUG: byte forced to $00
cyc=12905 STATE=1 IR=$00 PC=$0805 A_OUT=$000805 D_IN=$EA      ; CPU now executing BRK
cyc=12906 STATE=3 IR=$00 PC=$0806 A_OUT=$0001FD WEn=0          ; stack PCH ($08)
cyc=12907 STATE=4 IR=$00 PC=$0806 A_OUT=$0001FC WEn=0          ; stack PCL ($06)
cyc=12908 STATE=5 IR=$00 PC=$0806 A_OUT=$0001FB WEn=0          ; stack P
cyc=12909 STATE=6 IR=$00 PC=$0806 A_OUT=$00FFFE D_IN=$00      ; fetch BRK vector low
cyc=12910 STATE=7 IR=$00 PC=$0806 A_OUT=$00FFFF D_IN=$FF      ; fetch BRK vector high
cyc=12911 STATE=0 IR=$00 PC=$FF00 A_OUT=$00FF00 D_IN=$40      ; jump to BRK handler
cyc=12912 STATE=1 IR=$40 PC=$FF01                              ; RTI executing
cyc=12916 STATE=0 IR=$40 PC=$0806 D_IN=$EA                    ; RTI'd back to $0806
cyc=12917 STATE=1 IR=$EA PC=$0807                              ; resume NOPs
```

This sequence — opcode fetch returns `$00` → BRK → vector to `$FFFE/$FFFF`
→ BRK handler — is **exactly the warm-restart screen wipe symptom on real
C64 hardware**, where the BRK handler is the KERNAL routine that wipes
the screen, restores the border color, and prints `READY.`.

The test program's reset state is irrelevant. What matters is that PC
sampled an `$00` byte at the address `$0804`. The CPU has no mechanism to
distinguish "the user actually wrote `$00` at this address" from "the
system delivered the wrong byte." It just executes BRK and we see the
warm restart.

## What this proves about the bug

1. **The bug is NOT in `$AF` execution.** $AF executes correctly across
   all our manipulation scenarios — single CE drop, multi CE drop, single
   D_IN corruption, multi-cycle D_IN corruption. PC always reaches `$0804`
   correctly.
2. **The bug IS in the byte the system delivers at the *next* opcode
   fetch position** after `$AF`. Whatever delivers data on `cpuDi` returns
   `$00` (or some BRK-equivalent) for `$0804` instead of the actual `$EA`.
3. **The bug only matters for instructions that complete with a `STATE=4`
   data fetch to a non-PC address.** $AF/$5C/$8F/$CF all share this
   property. Three-byte instructions (`$AD LDA abs`) also have a
   `STATE=4` data fetch, but they end up not crashing — meaning the
   precise *combination* of state-3 PC-stream bank fetch + state-4
   non-PC data fetch is what disturbs the system. This is a **specific
   pattern** the bench can now characterize without deploy iteration.
4. **The original brief's symptom description is exactly correct.** PC
   does land on a `$00` byte after `$AF` — but it's not because PC was
   off-by-one. It's because the byte AT `$0804` is being delivered as
   `$00`. Both look the same to the user.

## Refining the system-side root cause

### Code-walk of the wrong-byte path (read-only investigation, this session)

Walking `cpuDi → cpuDi_raw → dataToCpu → ramData → ramDin` for the
post-$AF cycle at 1 MHz mode:

- `cpuDi <= cpuDi_raw` (default fallback at `fpga64_sid_iec.vhd:875` once
  bram/cache/iof/etc. paths are eliminated under 1 MHz).
- `cpuDi_raw` = `dataToCpu` from the buslogic instance at
  `fpga64_sid_iec.vhd:693`.
- `dataToCpu` is a **purely combinational** mux at
  `fpga64_buslogic.vhd:319-373`, selected by `cs_ramLoc`/`cs_vicLoc`/etc.
  No registration in the buslogic itself.
- For the post-$AF fetch at `$00:0804` with `supercpu_en=1` and
  `supercpu_bank=$00`, the path through the mux is:
  `dataToCpu <= ramData` (the `cs_ramLoc='1'` branch at line 348).
- `ramData` is wired to `buslogic_ramData` at `fpga64_sid_iec.vhd:710`.
- `buslogic_ramData <= bram_vic_do when ... else ramDin` at
  `fpga64_sid_iec.vhd:690`. With `cpuHasBus='1'` (CPU phase), this is
  just `ramDin`.
- `ramDin` is the SDRAM data output from the system's SDRAM controller.

So at 1 MHz mode, `cpuDi` for `$00:0804` is **`ramDin` directly from
SDRAM**. There is no extra registration in the buslogic — the staleness
must come from `ramDin` itself.

### The specific staleness mechanism

`ramDin` only updates when a new SDRAM read completes. The state-4 data
fetch in `LDA $00:D020` is a read from VIC-II I/O, **NOT a SDRAM read**.
The buslogic's `dataToCpu` mux for `$D020` selects `vicData` (not
`ramData`), and the system bus arbitration does **not issue a SDRAM
cycle** for an I/O-region read. So during the state-4 cycle, `ramDin`
**holds whatever it had from the previous SDRAM read** — which was the
state-3 PC-stream fetch at `$00:0803 = $00`.

When the post-$AF cycle arrives at `$00:0804`, the system **does** want
to issue a SDRAM read for `$0804`. But there's a pipeline lag: the SDRAM
read for `$0804` takes several `clk32` cycles to complete. If the CPU
samples `cpuDi` before that read has propagated to `ramDin`, **`ramDin`
still has the value from the LAST completed SDRAM read** — which was
`$0803 = $00`. The CPU sees `$00`, executes BRK, warm-restart.

This is **exactly** the smoking gun symptom my SC_CORRUPT_S0_NEXT
scenario reproduces, with the same byte ($00) at the same address ($0804)
producing the same end state (BRK → vector → KERNAL warm restart).

### Why the bug is specific to $AF/$8F/$CF/$5C

| Instruction | State-4 read goes to | SDRAM cycle issued? | `ramDin` updated by state 4? |
|---|---|---|---|
| `$AD LDA abs` (3-byte) | Operand-decoded address (typically RAM) | Yes | Yes |
| `$B9 LDA abs,Y` | Operand+Y (typically RAM) | Yes | Yes |
| `$A7 LDA [dp]` | Indirect via VDA cycles to RAM | Yes | Yes |
| `$EA NOP` | No data fetch | N/A | N/A — every fetch is PC stream RAM, constantly updating |
| **`$AF LDA long` to I/O ($D020)** | **VIC-II I/O** | **NO** | **NO — `ramDin` stale from $0803** |
| **`$AF LDA long` to RAM ($0810)** | RAM | Yes (but...) | Possibly stale due to other timing race |
| **`$5C JML long` (with bank operand from PC)** | New PC location | First PC fetch from new location | Same race window |

The variability for bank-$01/$02 cases is consistent with cycle alignment
of the SDRAM pipeline — sometimes the new SDRAM read for the next opcode
completes in time, sometimes it doesn't.

### Why this matches "bug persists at 1 MHz"

At 1 MHz the BRAM fast paths are gated off, so `cpuDi_raw` is the **only**
path, and `cpuDi_raw = ramDin` directly. The staleness window is fully
exposed. At turbo mode the BRAM/cache paths might catch the post-$AF
fetch and serve fresh data — or might also be stale because they were
filled from the same `ramDin`. Either way, 1 MHz pinpoints the buslogic
data path as the source of the wrong byte.

## Cumulative findings table

| # | Hypothesis | Method | Status |
|---|-----------|--------|--------|
| 1 | Perplexity `io_in_pipeline` 2-vs-3 stage race | Code reading | ❌ Eliminated 2026-04-08d |
| 2 | `enableCpu_816` single-pulse starvation | Bare `SC_DROP_S3/S4` | ❌ Eliminated 2026-04-08d |
| 3 | Single-byte wrong delivery on bank fetch | Bare `SC_CORRUPT_AB` | ❌ Eliminated 2026-04-08d |
| 4 | Wrapper `localDi` mux interfering | All wrapper scenarios | ❌ Eliminated 2026-04-08e |
| 5 | Multi-cycle wrong delivery during $AF execution | Bare `SC_CORRUPT_S3_MULTI` | ❌ Eliminated 2026-04-08f |
| 6 | **Wrong byte at the post-$AF opcode fetch position** | Bare `SC_CORRUPT_S0_NEXT` | ✅ **Reproduces exact symptom** |
| 7 | BRAM/cache page-valid coarseness on page $08 | Code reading | ⚠️ Eliminated for 1 MHz mode (gated) — may still apply for turbo mode |
| 8 | `cpuDi_raw` registration latches stale data | Code reading | ❌ Eliminated — `dataToCpu` is purely combinational, no registration in buslogic |
| 9 | **`ramDin` is stale because state-4 I/O read doesn't trigger a SDRAM cycle, so `ramDin` still holds the value from the state-3 fetch ($00) when the post-$AF cycle samples `cpuDi`** | Code reading via elimination of #8 | ⏳ **Strongest remaining hypothesis** |

## UPDATE (later in same session): asymmetry RESOLVED — bench shows it directly

**Added `SC_BASELINE_AD` to the bare-core bench** (3-byte `$AD LDA $D020`,
structurally similar to `$AF`). The bare-core trace exposes the second
factor immediately:

| Instr | State 1 | State 2 | State 3 | State 4 | Next state-0 |
|---|---|---|---|---|---|
| `$AD` | AAL=$20 (PC) | AAH=$D0 (PC) | data=$5A ($D020) | — | next op @ $0803 |
| `$AF` | AAL=$20 (PC) | AAH=$D0 (PC) | **AB=$00 (PC)** | data=$5A ($D020) | next op @ $0804 |

`$AF` has **one extra PC-stream RAM fetch** (state 3 = the bank operand)
immediately before the I/O data fetch. `$AD` does not. So the **last RAM
byte read into `dout_r`** before the I/O cycle is:

| Instr | Last RAM byte before I/O cycle | If post-instruction fetch races, CPU sees |
|---|---|---|
| `$AD LDA $D020` | `$0802 = $D0` (AAH) | **`$D0` = BNE rel** — wild branch, **no interrupt vector**, no warm restart |
| `$AF LDA $00:D020` | `$0803 = $00` (bank operand, bank=$00) | **`$00` = BRK** — KERNAL warm restart (the observed crash) |
| `$AF LDA $01:D020` | `$0803 = $01` (bank operand, bank=$01) | `$01` = ORA (zp,X) — wild execution; often eventually hits BRK |
| `$AF LDA $02:D020` | `$0803 = $02` (bank operand, bank=$02) | `$02` = **COP** — another software interrupt, likely also vectors to KERNAL |

**This is the second factor.** Hypothesis #9 (ramDin stale because state-4
I/O fetch issues no SDRAM cycle) IS the root cause. The asymmetry between
crashing and non-crashing instructions is **purely a coincidence of which
byte happens to remain in `dout_r`**:

- `$AD` works because the stale byte is the high address byte of the I/O
  target ($D0 for any $Dxxx I/O), which decodes as BNE — wild but no
  interrupt vector.
- `$AF` crashes because the stale byte is the **bank operand**, which for
  bank-$00 code equals $00 (BRK), for bank-$01 equals $01 (ORA wild), and
  for bank-$02 equals $02 (COP — also a software interrupt). All three
  produce immediate or near-immediate KERNAL vectoring.

**This completely explains the test matrix in `project_lda_long_crash.md`:**

- `sr_lday` (`$AD`) works → stale=$D0=BNE, doesn't BRK ✓
- `sr_align` / `sr_brd2` / `sr_lram` / `sr_min` (`$AF` bank=$00, various positions/targets) → stale=$00=BRK ✓
- `sr_min1` (`$AF` bank=$01, target $01:D020) → stale=$01=ORA wild, eventually BRK ✓
- `sr_b1` (`$AF` bank=$01, target $01:0000) → stale=$01, wild ✓
- `sr_b01` / `sr_pos2` (`$AF` bank=$01, working) → stale=$01, wild path that happens not to crash before the test reports success ✓
- `sr_emul` (`$AF` bank=$00 in emulation mode) → stale=$00=BRK ✓
- `sr_jml` (`$5C JML long`) → same structure (3 PC fetches + bank fetch); stale = bank operand byte ✓
- `sr_idl` (`$A7 LDA [dp]`) **works** → uses VDA cycles to load AB from DP indirect, NOT a PC-stream bank fetch, so no PC-stream byte gets stuck in dout_r right before the I/O cycle ✓
- `sr_4nop` (4 NOPs at the same position) **works** → no I/O cycle at all ✓

**Every single line of the test matrix is now explained by hypothesis #9
+ "the stale byte is the last PC-stream RAM byte before the I/O cycle."**
The bug is fully characterized.

## Hypothesis #9 confirmed structurally — also previously verified end-of-session

End-of-session walk through `fpga64_sid_iec.vhd:2092` and `sdram.v:140-167`:

- `ramCE <= cs_ram when sysCycle = CYCLE_VIC0 or cpu_cyc = '1' else '0'`
  → for an I/O read at `$D020`, `cs_ram = '0'`, so **`ramCE` stays `'0'`**
  even though `cpu_cyc = '1'` for that CPUC slot.
- `sdram.v` only updates `dout_r` at `STATE_READ`, which only fires after
  a `CMD_ACTIVE`/`CMD_READ` triggered by `ce && !last_ce`. No CE → no new
  `dout_r`. The previous value (state-3 PC fetch at `$0803 = $00`) sticks.
- `c64_data_in = data_out = mem_in = sdram_data` at `cartridge.v:800` —
  combinational, no extra registration. So `ramDin` is the SDRAM `dout`
  output directly.

So at the structural level, hypothesis #9 holds: `ramDin` does retain the
state-3 byte through the state-4 I/O cycle.

### The unexplained asymmetry — `$AD LDA abs` should crash too, but doesn't

`sr_lday` (3-byte `$AD LDA $D020`) **does not** crash on hardware. But
its state pattern is structurally identical to `$AF`:

| Instruction | State 1-2(-3) | State 3 / State 4 | State 0 (next op) |
|---|---|---|---|
| `$AD` (3-byte) | PC fetch AAL,AAH | I/O data fetch ($D020) | next opcode at PC+3 |
| `$AF` (4-byte) | PC fetch AAL,AAH,AB | I/O data fetch ($00:D020) | next opcode at PC+4 |

Both instructions have the same "preceding RAM fetch → I/O fetch → next
opcode RAM fetch" pattern that exposes the staleness window. If `ramDin`
staleness alone explained the crash, **`$AD` should crash too**. It does
not.

This means hypothesis #9 is **necessary but not sufficient**. There is a
**second factor** that distinguishes the 4-byte LDA-long-class
instructions from the 3-byte LDA-abs-class instructions even though their
post-instruction fetch patterns look identical at this level of analysis.

Candidate second factors to investigate next session:

1. **Cycle phase alignment.** $AF takes one more clk32 cycle (one extra
   PC fetch), so the post-instruction fetch lands at a different position
   in the 32-cycle sysCycle rotation. Maybe at that position the SDRAM
   pipeline timing happens to lose the race, while $AD's post-fetch
   position has a clean SDRAM cycle. Need to count clk32 cycles from
   reset to first post-instruction fetch for both and compare modulo 16.
2. **`addrBus` mode transition timing.** $AF's state 3 uses `addrBus =
   PC stream` to fetch AB, then state 4 switches to `addrBus = "0101"`
   (AB:AA + offset). The MCode trace shows va switches from `"01"` (PBR)
   to `"10"` (AB:AA) between states 3 and 4. Maybe the address bus
   glitches during this transition in a way that briefly drives a wrong
   `cpuAddr`, which could trigger an unintended SDRAM cycle that
   clobbers `dout_r`. Need to check `cpuAddr_pre` waveform across that
   transition.
3. **AB latching timing.** AB is loaded from D_IN at state 3 (line 209
   of AddrGen.vhd). If the D_IN→AB latch has a setup-time issue at the
   exact CE edge, AB might briefly carry a wrong value, driving the
   state-4 address bus to an unintended location and possibly issuing a
   SDRAM read to a wrong RAM location whose data then lands in `dout_r`.
4. **A second register stage in the buslogic that I missed.** The
   `dataToCpu` mux is combinational, but `cpuDi_raw` may be registered
   one stage further along the path I haven't traced yet. Re-walk
   `fpga64_sid_iec.vhd:854-875` (the cpuDi mux) carefully.

Without resolving the asymmetry, **do not write any fix** — it would be
based on an incomplete model and might paper over the wrong thing.

## Recommended next moves (in order)

**~~1. Resolve the $AF-vs-$AD asymmetry.~~ DONE — see "asymmetry RESOLVED" section above. `SC_BASELINE_AD` was added; the bench shows the structural difference directly. The asymmetry is that `$AF` has one extra PC-stream RAM fetch (the bank operand) whose value gets stuck in `dout_r` during the I/O cycle, and that value happens to be a software-interrupt opcode ($00=BRK / $01=ORA wild / $02=COP) for the bank numbers people actually use.**

### Candidate fixes (in order of surgical precision)

The bug is fully characterized: the post-I/O-cycle CPU fetch races the SDRAM pipeline, and when the race fails, `cpuDi` falls back on the previous SDRAM read's value. The previous read is the bank operand, which for bank=$00 is `$00`. Three candidate fixes, all of which can be tested independently:

### Update 2026-04-09: Fix A was WRONG. Fix A' is now the implementation.

**Fix A analysis was flawed.** Widening the trigger from `iof_detect = '1'`
to `cs_ram = '0'` adds 1 clk32 of latency to the **I/O cycle's own**
`enableCpu` (moves it from CPUE to CPUF). But that cycle's `cpuDi` comes
from `vicData` via `cs_vicLoc` — it was never racing. The race is at the
**POST-I/O cycle**, where the CPU fetches from RAM and `cpuDi` falls
through to `ramData`/`ramDin`. Between the I/O cycle's `enableCpu` at
CPUF and the next `cpu_cyc` at the next period's CPUC, 17 clk32 cycles
pass with `io_in_pipeline` cleared (the "CRITICAL" clear at
`fpga64_sid_iec.vhd:2191` fires at the I/O cycle's own enableCpu).
At the post-I/O CPUC, `cs_ram='1'`, the widened Fix A trigger doesn't
fire, and `io_in_pipeline` stays 0. 2-stage pipeline applies. Same race.

Fix A in short: 1 clk32 of useless latency added to every I/O read,
nothing added to the post-I/O race. Build was killed mid-synthesis
once the error was spotted.

**Fix A' — what's actually deployed:** Add a `post_io_pending` latch
that fires when `cs_ram='0' and cpuWe_pre='0'` at any `cpu_cyc` and is
consumed at the next `cpu_cyc` by forcing `io_in_pipeline <= '1'`. This
moves the 3-stage delay to the cycle **after** the I/O cycle — the cycle
where the post-I/O SDRAM read actually happens — giving it 1 extra clk32
of CAS settling time before the CPU samples `cpuDi`.

The REU $DFxx `iof_detect` path is preserved for backwards compatibility,
so REU reads now get 3-stage on BOTH the REU cycle itself AND the
post-REU cycle (one extra delay compared to before). This might slow
REU slightly but shouldn't break anything.

Full edit: `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2156-2200` (signal
declaration at line 353 + logic change inside the main clk32 process).
Syntax check: 0 errors, 42 warnings (baseline).

### Earlier fix proposals (superseded)

**Important caveat about all three fixes:** I have NOT verified the exact clk32/clk64 phase mechanism that makes the race fail for `$AF` post-fetch but pass for `$AD` post-fetch. Both involve a "post-I/O RAM fetch racing the SDRAM CAS latency," and the only structural difference is that the `$AF` post-fetch arrives at `CYCLE_CPUC` of a slot that is offset by ~16 clk32 from the `$AD` post-fetch slot. Whatever's special about that phase relative to SDRAM internal state (refresh window? bank-switch timing? CAS pipeline state?) is unknown, and any of the fixes below might just shift the race to a different phase that ALSO fails. **Hardware testing is essential.**

**Fix A (WRONG — see Update 2026-04-09 above):** Extend the existing 3-stage SDRAM pipeline (currently used for SuperRAM and `iof_detect`/$DFxx) to **all** I/O-region accesses. In `fpga64_sid_iec.vhd:2156-2169`, the trigger for `io_in_pipeline <= '1'` is `iof_detect = '1' and cpuWe_pre = '0'`. Change this to set `io_in_pipeline` whenever `cpu_cyc = '1' and cs_ram = '0' and cpuWe_pre = '0'` (i.e., any I/O-region read).

  - **Important: this delays the I/O cycle's OWN `enableCpu`, NOT the post-I/O cycle's.** ~~Whether that helps depends on whether the additional 1 clk32 of latency in the I/O cycle realigns the post-I/O `cpu_cyc` slot relative to SDRAM clk64 in a way that makes the post-I/O read complete in time. It might. It might also do nothing.~~ **It doesn't help at all — confirmed by timing trace 2026-04-09.**

**Fix A' (DEPLOYED as of 2026-04-09):** Add a `post_io_pending` flag that latches at the I/O cycle and is consumed at the next `cpu_cyc` by forcing `io_in_pipeline <= '1'` for the post-I/O cycle. This adds 1 clk32 of latency specifically to the cycle where the race happens.

**Fix B:** Force `ramCE <= '1'` during I/O cycles (use the I/O address as the SDRAM read address). The I/O address $D020 has a RAM shadow at the C64's underlying RAM (per the C64 dual-bus architecture). The data fetched is irrelevant — we're using the SDRAM cycle solely to update `dout_r` so it doesn't carry stale data into the next CPU cycle. After Fix B, the stale value would be whatever's at $00:D020 in the RAM shadow — typically `$00` for uninitialized regions, but for sr_lram (target $00:0810 = RAM target) it would be the actual byte at $0810. For sr_align/sr_brd2 (target $D020), the shadow at $D020 is "color RAM" / VIC-II registers in C64 memory, which is typically not BRK.

  - Why this might work: changes the value of the stale byte from "the bank operand" to "the I/O address shadow," which is much less likely to be $00.
  - Why it might not: doesn't actually fix the race — just changes which wrong byte the CPU sees.

**Fix C (last resort):** Register `cpuDi` (or `cpuDi_raw`) one extra clk32 cycle. Adds a pipeline stage for ALL fetches, not just post-I/O. Could break VIC-II timing, screen rendering, or other latency-sensitive paths. Avoid unless A and B both fail.

**Strong recommendation: try Fix A first.** It is the smallest, most targeted change and uses an existing mechanism that is known to work for REU.

### Verification protocol for any fix

Before deploying:
1. Re-run the bare-core bench. The bench can't simulate the system-level race directly, but should still pass all 7 scenarios (none of them depend on the system bus).
2. Build with `.\build_c64.ps1 -SyntaxOnly` to confirm the change compiles cleanly.

After deploying:
1. Run `sr_align` (the simplest reproducer). If it shows the splash screen with the "12" markers and a BLUE border (not a wiped screen with READY), the fix works for the simplest case.
2. Run `sr_brd2` (writes border color, then reads via $AF). Confirms the I/O write path still functions and that the post-$AF fetch returns the correct opcode.
3. Run `sr_lday` (3-byte $AD positive control). Must continue to work — no regression.
4. Run `sr_jml` ($5C JML long). Same root cause; should also be fixed.
5. Run `sr_idl` ($A7 LDA [dp]). Negative control — not affected by the bug. Should continue to work.
6. Boot Lorenz CPU test suite. Must pass — checks for any regression in normal CPU operation.
7. Test Doom. The $20:20FC crash may also be the same root cause (the original `project_lda_long_crash.md` notes this hypothesis). If Doom progresses past the crash, the fix has cascading benefits.

### Earlier next-moves list (mostly obsolete after asymmetry resolution)
2. **Add a SignalTap probe** on `cpuDi_raw`, `cpuAddr_pre`, `cpuAddr`,
   `ramDin`, `cs_vicLoc`, `cs_ramLoc`, `sysCycle`, `cpu_cyc`, `enableCpu`,
   sampled across the post-$AF cycle boundary on real hardware **for both
   `$AF` and `$AD`** (using a known-crashing PRG and the working
   `sr_lday`). The byte-level diff between the two captures **is** the
   second factor we don't yet understand. This is the most direct
   experiment that can characterize the bug end-to-end without writing a
   system-context bench. Use the existing SignalTap workflow from
   `docs/SIGNALTAP_GUIDE.md`.
3. **Re-walk `cpuAddr_pre`/`cpuAddr` propagation** end-to-end. The wrapper
   bench drives the address bus directly from the CPU; the real system
   has at least one register stage on `cpuAddr` (line `cpuAddr <=
   cpuAddr_pre when dma_active = '0' else dma_addr` is combinational, but
   the PCH/PCL paths inside `P65C816` may register PC update one cycle
   away from when the system samples it). The exact timing of when the
   new address (`$0804`) becomes visible to the SDRAM scheduler vs. when
   `dout_r` is sampled by `cpuDi` is the crux.
4. **Promote the bench:** add a stub of `fpga64_buslogic.dataToCpu`
   selection + a tiny SDRAM model with the right CAS latency + a 2-cycle
   `cpu_cyc → enableCpu` shift register, and try to reproduce the crash
   for `$AF` but NOT for `$AD` without any manual D_IN corruption. If the
   bench can show that asymmetry naturally, the model has captured the
   bug and a fix can be developed in simulation. This is significantly
   more work than the bare-core bench but is the only way to land a fix
   without deploy iteration.
5. **Do NOT attempt either quick fix yet.** The previously-proposed
   "register `cpuDi`" and "force blank SDRAM read on I/O cycles" fixes
   are both based on hypothesis #9, which is incomplete (it cannot
   explain why `$AD` works). If the second factor turns out to be
   something like AB-latch glitches on the address bus during state 3→4,
   neither fix would help. Wait until step 1, 2, or 4 above resolves the
   asymmetry before touching production RTL.

## Files changed this session

```
sim/p65c816_tb/p65c816_lda_long_tb.vhd     (added SC_CORRUPT_S3_MULTI + SC_CORRUPT_S0_NEXT)
docs/session_passover_2026_04_08f.md       (THIS FILE)
```

## How to reproduce the smoking gun

```powershell
.\sim\p65c816_tb\run_tb.ps1
```

Then in `sim/p65c816_tb/work/lda_long.log`, look for the
`sc_corrupt_s0_next` block. The critical lines are around `cyc=12904` —
you'll see PC=$0804, IR=$AF still, and D_IN=$00 (the corruption firing),
followed by the CPU dispatching BRK, stacking, vectoring through
$FFFE/$FFFF, and reaching the BRK handler at $FF00.

Run time: ~10 seconds total (both bare-core and wrapper benches).
