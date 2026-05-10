# Doom debug — 2026-05-10 v296 IRQ-refire chain BROKEN

## Bottom line: REU IRQ was the unacked source. Main runs freely now.

v296 commit `b655011`, RBF `c8105adfeb91c62e9ebc65cb8e746371`.

Extended the synthesized IRQ ack stub at `$00:$FF00..$FF1A` (was
`..$FF16`) to also `LDA $00DF00` before PLA/PLP/RTI. `reu.v:174`
clears `status<=0` on `$DF00` read; `reu.v:109` recomputes
`irq <= (|(status[6:5] & intr[6:5])) & intr[7]`. So reading $DF00
de-asserts REU's contribution to IRQ_N.

## Hardware result vs v294/v295 baseline (35-sample 240s window)

| Build | N distinct | Top value | Interpretation |
|-------|-----------|-----------|----------------|
| v294  | 1         | `$41:$DB93` (100%) | pinned, BRK loop |
| v295  | 1         | `$41:$FCF3` (100%) | pinned, BRK loop |
| v296  | **35**    | every sample unique, `$0F:$Axxx-$Bxxx` | main fetching freely |

I field exercises new stub bytes ($FF14 LDA / $FF18 PLA / $FF19 PLP /
$FF1A RTI) — extended stub is on the actual hardware path.

## Confirms cocotb Test 2 framing

`test_brk_native_rti.py::test_brk_native_with_irq_pressure` reproduced
v294 pattern with `IRQ_N` held low. Hardware behavior matched — the
"halt" was IRQ pre-empting every RTI before the next main fetch could
complete. With $DF00 added to the ack path, REU `irq` now drops, IRQ_N
goes high, main resumes.

The recompiler runtime (AmiDog SCPUMIPS) arms REU FETCH/STASH with
IRQ-on-end-of-block enabled (`intr=$E0`) but its IRQ handler doesn't
include `LDA $DF00`. Real CMD SuperCPU EPROM probably reads $DF00 in
its full IRQ chain. Our ack stub now works around it.

## What's left — Doom still doesn't render

Screen at 240s = lighter blue border, darker blue inner rect, no
sprites/text. This is bitmap mode but blank. Main runs in bank $0F
(linear progression `$A41B → $BB09` — recompiled JIT code) but
nothing visible appears.

Possible causes (next session):

1. **Renderer in init phase** — game might still be loading assets.
   Try a 60s+ longer capture.
2. **VIC reg writes not landing where game expects** — surface
   `$D011 / $D018 / $DD00` in UART. Bitmap mode + correct bank
   pointer required for any output.
3. **Game waiting on input** — try `python tools/mister_debug.py
   keys ' '` to send space/fire.
4. **Bank $0F disasm** — peek `$0F:$A41B..$BB09` in REU to see
   what recompiled code is actually running.

## Build state

- Branch `vanilla-cpu-swap`, tip commit `b655011`.
- RTL diff lives in `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1573-1650`
  (stub bytes + comment) and `C64_MiSTer/rtl/fpga64_buslogic.vhd:293`
  (range comment update).
- Captures saved at `tools/doom_full/uart_v296_*.txt` and
  `shot_v296_240s.png`.
- ALM 64% (was 63%), build 12:58.

## Files for next session

- `tools/doom_full_run.py` — the full Doom flow
- `tools/analyze_v295.py` — N/I/PC field comparison
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1551-1650` — ack stub
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2604-2625` — pc_main_r/pc_irq_r
  PB-based gate (kept from v295)
- `sim/cocotb/tests/test_brk_native_rti.py` — diagnostic that
  framed the IRQ-refire hypothesis
