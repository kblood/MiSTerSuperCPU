# Doom debug — 2026-05-11 v299 partial + root cause found

## Bottom line: v299's $DF00 ack DOESN'T actually ack on this branch

The vanilla-cpu-swap branch's `c64.sv:661` drives `reu.v cpu_cs = IOF`
directly without the `iof_falling_edge` pulse fix that exists in
master. In turbo/SCPU mode the `LDA $00DF00` access cycle is too
short for REU to register the read. So the ack stub's REU ack is
a no-op on this branch.

v296/v297/v298/v299 all hit the SAME $2B:$2292 SP-leak wedge:

```
F:1934 PC:$2C:$851B SP:$01ED    (error chain entry)
F:1935 PC:$2B:$2292 SP:$01DB    (call into arg-walker)
F:1936 PC:$2B:$2292 SP:$01C5    (SP -$16)
...
F:194A PC:$2B:$2292 SP:$000D    (SP -$16 each frame)
F:194B PC:$00:$FF15 SP:$FFF9    (16-bit native wrap)
F:194C PC:$00:$FF19 SP:$FFF9    N field PB=$0F (RTI popped garbage)
F:194F PC:$0F:$2C27 SP:$FFFE    (BRK-march continuing in bank $0F)
```

The earlier "Bad music number -9" screen capture (17:04) was
almost certainly residual framebuffer from a prior v286-era
boot — multi-shot captures at t=130s-160s on fresh deploys
show all blank blue rect, no error text ever rendered.

## What v294→v299 actually fixed

- v286: $00:$FFE4..$FFEF native vector intercept → $FF00 stub.
  Doom progresses past KERNAL-ROM-confusion BRK loop.
- v296 (vs v294): +5 stub cycles unstuck $41:$DB93 BRK loop.
  The "REU ack" was incidental — the timing improvement is what
  worked. v297's experimental swap to $DC0E (no REU ack) also
  worked, confirming timing-only.
- v298: EPROM dprom at bank $F8. No Doom benefit (Doom doesn't
  read $F8 in the wedge path).
- v299: revert to $DF00. Same as v296. No additional Doom benefit
  because the stub's $DF00 read doesn't reach REU on this branch.

## Real fix needed

Port iof_falling_edge infrastructure from master:

1. Generate `iof_fall_pulse_r` in `fpga64_sid_iec.vhd` as a
   1-cycle pulse at the falling edge of registered IOF
2. Latch `cpu_we_latched`, `cpu_addr_latched`, `cpu_dout_latched`
   during the $DFxx access window
3. Drive `reu.v cpu_cs` from `iof_fall_pulse_r` instead of `IOF`
   raw; drive `cpu_we/addr/dout` from the latched signals

Reference: `project_reu_iof_falling_edge_fix.md` (master branch
description). Also fixes turbo-mode REU writes that are
currently misdetected as reads on this branch — would unblock
multiple SCPU titles, not just Doom.

After port: v299's stub LDA $00DF00 should actually clear REU
status[7:5] and break the IRQ-refire chain. Doom should then
progress past $2B:$2292 to actual music-number error printing
(in text mode on screen, visible to user).

## Files for next session

- `c64.sv:661` — `cpu_cs(IOF)` to be replaced with falling-edge
  pulse
- `project_reu_iof_falling_edge_fix.md` — master fix description
- `project_doom_v299_correction.md` — corrected v299 understanding
- `tools/doom_v298_transition_zoom.py` — diagnostic that
  reproducibly catches the wedge
- `tools/doom_full/v298_transition_zoom.txt` — current capture
  (1339 frames, wedge at idx 248)

## Build state

- Branch `vanilla-cpu-swap`, tip commit `18068b8`
- RBF md5 `94b6c3c0d4f8d1585e7a1b269073b965`
- ALM 64%, RAM 73%, build 11:40
- 2 commits land this session: v299 stub revert (18068b8) and
  diagnostic captures (f1cac09)
