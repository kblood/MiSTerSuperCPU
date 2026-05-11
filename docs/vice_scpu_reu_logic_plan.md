# VICE SCPU+REU Logic — What's Hidden and What To Do

**Date**: 2026-05-11
**Status**: investigation complete; plan for next session(s)
**Trigger**: v294→v299 wedge debugging exposed that our vanilla-cpu-swap
branch is missing critical SCPU↔REU bus-timing glue that VICE handles
in software emulation.

## TL;DR

VICE's `xscpu64` runs Doom successfully because it does two things our
branch doesn't:

1. **I/O cycle stretching** — when SCPU at 20 MHz accesses `$DFxx`,
   VICE stretches the cycle (~2-3 CPU cycles) via
   `scpu64_clock_read_stretch_io()` / `scpu64_clock_write_stretch_io_start()`
   so the 1 MHz REU device has time to register the access.
2. **EPROM-driven boot** — VICE lets the real SCPU64 EPROM (V0.07)
   run from reset, which copies a small kernel (~53 bytes) into
   `$00:$801A-$8054`. **All IRQ/COP/BRK/NMI/ABORT handlers run from
   that RAM kernel**, not from EPROM or from synthesized mux logic.

We have implemented neither. v299's "fix" (ack stub reads `LDA $00DF00`)
correctly emulates the spec but the read **never reaches REU** in turbo
mode because there's no cycle stretching — REU misses the access window.

## What we already have

- ✓ 27-byte synthesized ack stub at `$00:$FF00..$FF1A` (mux-driven, not RAM)
- ✓ Native-vector intercept at `$00:$FFE4..$FFEF` mapping all to `$FF00`
- ✓ EPROM dprom at bank `$F8` with full VICE SCPU64 V0.07 binary (v298)
- ✓ Bank-`$00` SRAM ROM-shadow for `$E000-$FFFF` reads in native mode
- ✓ Bank-`$01` SRAM mirror, bank-`$F6-$FF` `$6B`-RTL stub for banks ≥ `$F6`
  (except `$F8` which serves the EPROM)
- ✗ I/O cycle stretching during turbo mode (the actual missing piece)
- ✗ EPROM-driven boot — RESET vector goes to BASIC ROM, not EPROM
- ✗ RAM-resident IRQ kernel at `$00:$801A-$8054`

## VICE-side source evidence

### `vice/src/c64/cart/reu.c`

```c
case REU_REG_R_STATUS:
    /* Bits 7-5 are cleared when register is read, and pending IRQs are
       removed. */
    rec.status &= ~(REU_REG_R_STATUS_VERIFY_ERROR |
                    REU_REG_R_STATUS_END_OF_BLOCK |
                    REU_REG_R_STATUS_INTERRUPT_PENDING);
    /* ... */
    maincpu_set_irq(reu_int_num, 0);
```

VICE's REU read-clear semantics are **identical to our `reu.v:174`**:
read of `$DF00` clears status[7:5] and drops IRQ. No special SCPU
handling. This is the spec.

### `vice/src/scpu64/scpu64mem.c`

```c
/* example pattern for any $DFxx I/O routing */
if (!dma_in_progress) {
    scpu64_clock_read_stretch_io();
}
```

**Every** SCPU access to a 1 MHz device (VIC `$D0xx`, SID `$D4xx`,
CIA1 `$DCxx`, CIA2 `$DDxx`, IO2 `$DFxx` incl. REU) goes through a
cycle-stretching wrapper. This is the magic that makes 20 MHz SCPU
coexist with 1 MHz I/O.

### `vice/src/scpu64/scpu64cpu.c`

`scpu64_clock_read_stretch_io()`:
- Steals cycles if BA low
- Increments main CPU clock when accumulator threshold crossed
- Sets `maincpu_accu = 11500000 + SHIFT`
- Total effect: ~2-3 CPU cycles of delay per I/O access

`scpu64_clock_write_stretch_io_start()` / `_long()`:
- Pre-write stretch
- Long-stretch variant for special addresses (`$DF7E/$DF7F` RAMLink)

### Real CMD SuperCPU EPROM (`scpu64.mif`, V0.07, 64 KB)

Vectors at top of EPROM:

| Vector | Address | Reads | Trampoline | RAM kernel entry |
|--------|---------|-------|------------|------------------|
| NMI (emu) | `$FFFA/B` | `$FC8C` | `JML ?` | ? |
| RESET (emu) | `$FFFC/D` | `$FC90` | `JML $F8:$00FC` | EPROM kickstart |
| IRQ/BRK (emu) | `$FFFE/F` | `$FC94` | `JML $00:$8054` | RAM |
| COP (nat) | `$FFE4/5` | `$FC98` | `JML $00:$801A` | RAM |
| BRK (nat) | `$FFE6/7` | `$FC9C` | `JML $00:$801A` | RAM |
| ABORT (nat) | `$FFE8/9` | `$FCA0` | `JML $00:$8051` | RAM |
| NMI (nat) | `$FFEA/B` | `$FCA4` | `JML $00:$8023` | RAM |
| IRQ (nat) | `$FFEE/F` | `$FCAC` | `JML $00:$8025` | **RAM** |

Kickstart at `$F8:$00FC` does `JML $F8:$80C1` (further EPROM init,
which copies kernel bytes into `$00:$801A-$8054`).

So in a **real** boot flow:
1. C64 resets → CPU reads `$FFFC/D` → gets `$FC90` (in EPROM-shadow)
2. JMP `$FC90` → `JML $F8:$00FC` (cross-bank to EPROM body)
3. `$F8:$00FC` → `JML $F8:$80C1` (real boot code)
4. Boot code copies ~53 bytes of kernel to `$00:$801A-$8054` in RAM
5. Boot code sets up DMA registers, ROM-shadows, hardware regs
6. JML to BASIC start
7. When IRQ later fires, vector at `$FFEE/F` returns `$FCAC` → trampoline
   `JML $00:$8025` → **runs the RAM-resident kernel handler**

## Where our environment diverges

**We never run the EPROM boot path.** Our SCPU mode is entered when
something software-side flips `XCE` (e.g., Doom's launcher: `SEI; CLC;
XCE; JML $20:0000`). The RESET path never fires from EPROM. So
`$00:$801A-$8054` stays as garbage RAM, and our synthesized `$FF00`
stub is the only IRQ handler in town.

This works for trivially-handled IRQs but breaks the moment something
nontrivial happens. Specifically:

- REU asserts IRQ after FETCH completes
- IRQ vectors via `$FFE4..$FFEF` (intercepted by us to `$FF00`)
- Our stub reads `$DF00` to clear REU status
- **The read cycle is too fast** — REU's `cpu_cs` is wired to raw `IOF`
  (`c64.sv:661`) which goes high only briefly during the SCPU turbo
  access. REU doesn't latch the access. Status stays set. IRQ refires.

## Two paths forward

### Path A — Cycle stretching only (minimum viable fix)

**Goal**: make our synthesized ack stub actually clear REU IRQ.

**RTL change**: when SCPU is in turbo mode AND `cpuAddr[15:12]=D` AND
`cpuAddr[11:8]=F` (= `$DFxx`), stall the SCPU enable for ~5-10 clk32
cycles so REU has time to see the access. Equivalent to VICE's
`scpu64_clock_read_stretch_io()`. Apply to all 1 MHz device ranges:
`$D000-$DFFF` (VIC, SID, CIA1, CIA2, IO1, IO2).

**Files to touch**:
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — generate `io_stretch` signal,
  feed into `enableCpu_816` gating
- Maybe `c64.sv` — pass through if buslogic needs visibility

**Reference**: there's existing work on master (`iof_fall_pulse_r`)
that takes a different approach (delay cpu_cs to falling edge of IOF
+ latch cpu_we/addr/dout in `fpga64_sid_iec.vhd`). That's an
REU-specific fix; the SCPU-side cycle-stretch is the more general
solution that catches all 1 MHz devices.

**Resource impact**: trivial — a counter + comparator, < 10 ALMs.

**Expected outcome**:
- ack stub's `LDA $00DF00` actually clears REU status
- `$2B:$2292` SP-leak wedge clears
- Doom progresses to actual music-number error printing OR further

### Path B — Run the EPROM boot path (architecturally correct)

**Goal**: drop our synthesized ack stub, let real EPROM kickstart run
and install RAM-resident kernel, then have Doom hit the same IRQ
handlers VICE does.

**Required infrastructure**:
1. RESET vector in EPROM emulation mode: when SCPU enabled and CPU
   reads `$FFFC/D`, return EPROM bytes (`$FC90`), not C64 KERNAL bytes
2. Boot from EPROM: allow code at `$F8:xxxx` to execute and write to
   bank-`$00` RAM (`$00:$801A-$8054`)
3. Remove the `$FF00` ack stub mux (or gate it off when EPROM kernel
   is loaded)
4. Verify EPROM kickstart at `$F8:$80C1` actually runs to completion
   (may need to debug per-instruction in GHDL bench)

**Risk**: HIGH. The kickstart probably depends on:
- C64 KERNAL still being callable from bank `$00`
- Specific DMA setup that we may not support
- ROM-shadow behavior in specific banks
- May require additional buslogic dprom changes

**Resource impact**: ~0 (no new RTL; the EPROM dprom is already in v298)

**Expected outcome**:
- Full SCPU64 behavior, same as VICE/real hardware
- Doom should hit the same code paths VICE hits
- All other SCPU titles (Wolf3D, Doom, etc.) benefit

### Path C — Hybrid (recommended)

Do Path A first (minimum risk, immediate Doom-progress win). If Doom
still fails at the next stage (music-number bug per VICE-vs-our-HW
divergence in cocotb proofs), evaluate Path B.

Path A leaves the door open to Path B later — it doesn't preclude
running the EPROM kickstart.

## Concrete next-session work plan

### Session 1 — Implement cycle stretching (Path A)

1. **Reference reading** (off-device, ~30 min)
   - Read VICE's `scpu64_clock_read_stretch_io` actual C code (need
     to fetch via WebFetch one more time, focused on the variables)
   - Read master's `iof_fall_pulse_r` block in `fpga64_sid_iec.vhd`
     for comparison

2. **Design the stretch signal** (~30 min)
   - Detect: `supercpu_en='1' AND turbo='1' AND cpuAddr[15:12]=x"D"`
   - Hold `enableCpu_816 <= '0'` for N clk32 cycles after detect
     (N=5? N=10? — calibrate to REU read-latch timing)
   - Resume normal enable

3. **Implement + syntax check** (~30 min)
   - Add `signal io_stretch_cnt : unsigned(3 downto 0);` etc.
   - Gate `enableCpu_816 <= enableCpu_816_pre and (io_stretch_cnt=0)`
   - `.\build_c64.ps1 -SyntaxOnly`

4. **Full build + deploy** (~45 min)
   - Run Quartus full
   - Deploy v300 to MiSTer

5. **Validate** (~30 min)
   - `python tools/doom_v298_transition_zoom.py` — wedge should NOT fire
   - Check `tools/doom_full/v300_*.png` for music-number text on screen
   - Sweep regression: `python tools/v272_sweep2.py` — no regressions
     in T65 mode
   - If wedge clears + Doom progresses, commit as v300

### Session 2 — If Path A clears wedge but Doom still fails

Likely scenario: Doom hits music-number error reliably and prints it.
Then we're back at the documented data-layer bug (REU→SuperRAM
transfer divergence). That's a different investigation — see
`project_doom_v293_85a1_chain_decoded.md`.

### Session 3+ — Path B if needed

If music-number error doesn't print even after Path A, the bug may
need full EPROM-driven boot. Plan that session separately.

## Why this isn't "hidden" — it's just spread across files

The user's framing was sharp: "Where is this logic hiding since it's
so hard to follow and recreate?"

Answer: it's not hiding, but it's spread across:

| Component | Where |
|-----------|-------|
| REU status-clear semantics | `vice/src/c64/cart/reu.c:reu_io2_read()` |
| SCPU I/O cycle stretching | `vice/src/scpu64/scpu64mem.c` + `scpu64cpu.c` |
| EPROM boot sequence | the `scpu64` binary itself (V0.07) at `$F8:$00FC` |
| RAM kernel layout | written by EPROM during boot, at `$00:$801A-$8054` |
| IRQ vector chain | EPROM `$FC8C..$FCAC` trampolines + RAM handlers |

We **had** the EPROM binary (used it in v298 dprom). We **didn't**
have its boot path actually run. We **didn't** have VICE's source
files read for the cycle-stretch logic.

The fix is to read and copy the right pieces, not to keep
reverse-engineering by probing.

## Files for next session

- `vice/src/scpu64/scpu64cpu.c` — fetch the stretch function full body
- `vice/src/scpu64/scpu64mem.c` — fetch the I/O routing for $DFxx
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — add io_stretch logic
- `C64_MiSTer/c64.sv:661` — leave alone (Path A doesn't need to touch
  REU wiring; Path B doesn't either, the stretch fixes the timing)
- `project_doom_v299_correction.md` — references this plan
- `project_reu_iof_falling_edge_fix.md` — master's alt fix, for
  comparison

## Decision check

Path C (do Path A first) is the recommendation unless the user has
reason to prefer the architectural overhaul. Path A is ~3 hours of
work for high-confidence wedge fix; Path B is multi-day with unclear
debug surface.
