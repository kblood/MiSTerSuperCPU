# Session handoff — 2026-05-14 (post-v340n: IRQ wedge FIXED, new bitmap-render surface)

## Bottom line

**The post-$0EED black-screen wedge is FIXED** (commit `c3fa2b8`).
v340n changes:
1. IRQ stub JML target: $0D40 → $0D3C (Doom's real entry point)
2. Removed v304 DMA-$0706 overload of VW/AC counters
3. UART formatter: VB (BRK vector) → AC (resetraster count)

Doom now boots all the way through `V_Init → M_LoadDefaults → Z_Init →
W_Init → M_Init → R_Init` (text screen visible at t=120s) and into JIT
main code in banks $2C/$3B/$A0/$A5 with SP:01FF clean, VW=AC=9 (VIC
ack chain works 1:1), M ring containing $0D6C (Doom's IRQ handler body).

Black screen remains at t=240s, but the cause has shifted from
"ORA-fetch wedge in JIT" to "bitmap-render not producing visible
output." This is a **new debug surface**.

## v340n verification (RBF md5 `a31d251dd8affbd7ee5be6c9145fade9`)

| Sample | PC | SP | VW | AC | IF | Screen |
|--------|----|----|----|----|----|--------|
| t=30s  | $00:$078C | $01F6 | n/a | n/a | n/a | loader anim |
| t=60s  | $00:$078B | $01F6 | 0001 | 0001 | 001B | loader anim |
| t=120s | $29:$1F9C | $01FF | 0005 | 0005 | 001B | Doom text up to R_Init |
| t=240s | $2C:$30CD | $01FF | 0009 | 0009 | 001C | black |

PC at t=240s drifts across $2C:$2FE6, $2FF2, $3023, $3080, $30C6,
$30CD, $35CA, $35D9, $310F — a wide range, so CPU is genuinely
executing JIT code, not stuck.

VW=AC monotonic and equal → the SCPU $D019 ack writes ARE reaching
the VIC's myWr_a and IRST IS being cleared 1:1. The suspected bug
at `video_vicII_656x.vhd:77` is **not present**. Doom isn't
generating frequent VIC IRQ activity in this state (only 9 ack
writes in 240s), which is consistent with the game having disabled
$D01A (VIC IRQ mask) once its scheduler is up.

## Next debug surface — bitmap-render black screen

CPU runs main code. IF (28 IRQs/240s) is low. Screen is black after
the Doom text-mode startup completes. Hypothesis tree:

```
Black screen at t=240s
├─ VIC config wrong
│   ├─ $D011 DEN bit cleared (display disabled)
│   ├─ $D018 mem pointer to wrong screen/bitmap bank
│   └─ $D016 / $D011 mode bits wrong (text vs bitmap mismatch)
├─ VIC bank wrong
│   ├─ $DD00 lower 2 bits select wrong 16K bank
│   └─ Doom expects bitmap in motherboard RAM that VIC can see;
│      JIT may be writing to SuperRAM bank that VIC cannot read
└─ Doom in renderer state that never completes a frame
    └─ PC drifts across $2C:$3000-$36xx — could be polling loop
      waiting on a flag we never set
```

### Recommended next probes

1. **Read live VIC config**: capture $D011/$D018/$D016/$D020/$D021/$DD00
   values via a peek probe or by adding a VIC-config slot to UART.
2. **Compare to VICE** at the same Doom state (post-R_Init,
   pre-bitmap). VICE's xscpu64 ought to be at the same PC location
   and showing pixels — capture VICE's $D0xx state and diff.
3. **Hook a probe at the bitmap memory** Doom writes to, to confirm
   it's actually computing pixels (vs hung in a wait loop). If
   pixels ARE being written, the wedge is at VIC reading them.

## Uncommitted state

None — v340n is committed (`c3fa2b8`).

## Files

- Commit: `c3fa2b8 fix: v340n — clear post-$0EED IRQ wedge; Doom
  boots through R_Init`
- Memory file: `project_doom_v340n_irq_wedge_fixed.md`
- UART captures: `tools/doom_full/uart_{30,60,120,240}s.txt`
- Screenshots: `tools/doom_full/shot_{30,60,120,240}s.png`
  (120s is the money shot — visible Doom startup text)

## Don't repeat these mistakes

- v340m's JML target $0D40 skipped Doom's $0D3C prologue and leaked
  the stack. Always confirm the *exact* entry address against the
  installed code, not a "nearby" one.
- The "SCPU $D019 ack doesn't clear IRST" suspicion at
  `video_vicII_656x.vhd:77` turned out NOT to be the cause of the
  wedge. The ack chain works; the wedge was simply that we weren't
  routing IRQ to a working handler. Keep that comment as a future
  diagnostic hook but the bug it was hunting is not active.
- AC/VW are now load-bearing diagnostic fields. Don't repurpose them
  without first restoring an alternate display path.
