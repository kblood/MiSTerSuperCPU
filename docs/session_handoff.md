# Session handoff — 2026-05-16 (v346 B6 probe build cycle)

## Bottom line

**v346 (in-flight build) adds a UART field B6:## that is the per-frame
sticky OR of `vicDi` — the byte VIC reads from RAM at each fetch slot.**
This answers a binary question: is the VIC's view of RAM all-zero (true
empty screen) or has data (then black screen has a non-memory cause)?

Build kicked off as PowerShell background job `v346_build`; log at
`v346_build.log`. ~30-40 min Quartus compile. RBF will land at
`C64_MiSTer/output_files/C64.rbf`.

## Why the probe was needed — reframing v345g→v342 comparison

The prior session ended believing v345g was a regression from v342's
"renders Doom title". Cross-comparison of UART data on 2026-05-16
showed otherwise:

- `tools/doom_full/v342_uart.txt` (5754 lines, May 14 successful run)
  game-runtime samples (F:$52EE-$55AC, 352 lines) are byte-identical
  to `tools/doom_full/uart_240s.txt` (v345g, 33 lines):
  `1D=0000 D11=3B D18=80 DD00=02 D16=D8`. **All Doom-runtime UART
  fields match v342 success bit-for-bit.**
- The DOOM_RENDERS screenshot (May 14 17:17, just 2 min before v342
  commit e5ff820) shows the id Software credits art screen.
- The same binary's May 15 10:51 run (`v342_t240s.png`) goes black at
  240s. So **v342's "render" is intermittent**, and v345g's "black" is
  just the same intermittent failure — not a regression.

Previously-suspected mechanisms (page-flip dead, DD00 stuck at $02,
$1D04 never toggles) are NOT discriminators: they hold during v342's
success runs too.

## v346 probe spec

`fpga64_sid_iec.vhd`:
- New entity port `dbg_vic_di_or : out std_logic_vector(7 downto 0)`
- New signals `vic_di_or_r` (in-frame accumulator), `vic_di_or_lat`
  (per-frame snapshot), `vSync_sig` (internal copy of VIC vsync),
  `vSync_prev_r` (edge detect)
- VIC instantiation: `vsync => vSync_sig` (was `vsync => vSync` → entity
  port directly; now goes through internal signal so we can read it).
- New `process(clk32)`: on vSync rising edge, latches `vic_di_or_lat <=
  vic_di_or_r` and resets the accumulator; otherwise (sysCycle=VIC3)
  ORs `vicDi` into `vic_di_or_r`.
- Output assignments: `dbg_vic_di_or <= vic_di_or_lat` and
  `vsync <= vSync_sig`.

`c64.sv`: wires `scpu_dbg_vic_di_or` and pipes to `dbg_pool.vic_di_or`.

`debug_pkg.svh`: adds `logic [7:0] vic_di_or` to `dbg_pool_t`.

`debug_uart_pool_fmt.sv`: `LINE_LEN 230→236`; latches `lat_vic_di_or`
from pool on vblank_rise; emits " B6:##" at byte positions 226-231.

## Hypothesis check (decision tree on B6 result)

After deploy + 240s Doom run with B6 field visible:

| B6 across 240s | Interpretation | Next probe |
|---|---|---|
| $00 always | VIC reads all-zero RAM → bitmap empty. CPU writes aren't reaching SDRAM region VIC reads. **Most likely** given the Tier-3 mirror routes bank-$01 to bank-$00 SDRAM but VIC reads through the cart_addr path which may not see the mirrored region. | Audit which SDRAM region Doom long-mode writes ACTUALLY land in (instrument cart_we + cart_addr during $01:* writes). |
| $FF or near-$FF | VIC sees data but screen is still black → cause is VIC config (DEN, color RAM, $D020/$D021, sprite occlusion) or a sync issue. | Add probe for color-RAM region + $D020/$D021. |
| $XX varying with frame | Bitmap is partially populated; rendering is in progress but incomplete. | Combine with v342 success comparison if such a run is captured. |

## v345g→v346 source state diff

```
M C64_MiSTer/c64.sv
M C64_MiSTer/rtl/fpga64_sid_iec.vhd
M C64_MiSTer/rtl/debug/debug_pkg.svh
M C64_MiSTer/rtl/debug/debug_uart_pool_fmt.sv
```

`grep -n vic_di_or` across these files lists 14 hits (all expected).

## Next-session entry

1. `Get-Job -Name v346_build | Receive-Job` to see build log tail.
2. Verify RBF md5 changed (`md5sum C64_MiSTer/output_files/C64.rbf`).
3. Check MiSTer ownership (`/tmp/CORENAME`, `/tmp/mister_session.lock`).
4. If free: deploy to `/media/fat/_Test/C64.rbf`, run
   `tools/doom_v342_test.py`, then `python3 -c 'import re; ...'` extract
   B6 column from `tools/doom_full/v342_uart_240s.txt`.
5. Commit v346 source whether or not the result is conclusive — the
   probe is a generally-useful addition that doesn't depend on the
   answer.

## Files touched

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — entity port + signals + latch
  process + output assignments + vsync routing.
- `C64_MiSTer/c64.sv` — wire + dbg_pool assign + fpga64 port hookup.
- `C64_MiSTer/rtl/debug/debug_pkg.svh` — pool field.
- `C64_MiSTer/rtl/debug/debug_uart_pool_fmt.sv` — latch + format bytes
  + LINE_LEN bump.
- `docs/session_handoff.md` — this file (overwritten per project
  convention).
