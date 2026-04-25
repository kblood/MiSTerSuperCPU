# UART Peek Register Design Note

Status: 2026-04-25 evening — **IMPLEMENTED**. RTL changes landed in c64.sv;
syntax check passed; full build in progress (~40 min).

## What landed

- `peek_addr[23:0]` 24-bit address latch (3 registers) at $DF1D / $DF1E / $DF1F
- `peek_seq[7:0]` increments on every readback completion (refresh-proof)
- `peek_data[7:0]` mirrors the latest captured SDRAM byte
- `peek_armed` set on $DF1F write, gates auto-rearm (so the byte refreshes
  every io_cycle slot until reset; pre-arm before SCPU launch lets us
  observe contents while the CPU is hung)
- W: UART field repurposed: `W:SSDD` where SS=peek_seq, DD=peek_data
- $DF1B (`reu_rb_data`) and $DF1C (status) are unchanged; existing infra
  carries the byte through the SDRAM CAS-2 read pipe

## Test plan (ready to run after build)

1. Cold boot (SCPU OFF or ON — both modes can be probed).
2. Load asterix via MGL or `mbc load_rom`. Land at BASIC READY (or already
   running if MGL autoboots).
3. **Pre-arm peek for $00:C003** (via mtype to BASIC, well within 30s window):
   ```
   POKE 57117, 3   : REM $DF1D = lo
   POKE 57118, 192 : REM $DF1E = mid ($C0)
   POKE 57119, 0   : REM $DF1F = hi (bank $00) — write triggers arm
   ```
4. SYS or wait for hang trigger (asterix autorun on cold boot).
5. Watch UART. **Expected outcomes**:
   - `W:01EA` → peek_seq=1, byte=$EA → $C003 contains NOP (matches bench)
     and the C003 hang theory shifts to "wrong-jump despite legit content".
   - `W:NNFF` (NN advancing) → byte=$FF (SBC al,X) confirms hardware-side
     garbage. Matches the captured opcode pattern. NN advancing proves the
     readback path is healthy mid-hang.
   - `W:0000` static → peek arm never armed (BASIC POKE didn't run, or
     IOF write detect mis-fired).
   - `W:NN<other>` → byte at $C003 is something specific; record + investigate.
6. Sweep $C003-$C00F by re-arming with hi=0/mid=$C0/lo={3..F} between samples
   (script automation).

## Future extensions (not blocking)

- BRAM peek via Port B mux (currently only SDRAM is reachable). Needed if
  hypothesis becomes "BRAM agrees with SDRAM" or "BRAM diverges from
  SDRAM" — the latter would prove write-through is broken.
- Range walk: increment peek_addr internally and stream successive bytes
  through W: with a wider counter. Lets us dump 256 bytes via UART without
  per-byte BASIC POKEs.
- Address arm via MiSTer linux side (ioctl-driven) so we can peek without
  any C64-side cooperation. Out of scope for now.

## Goal

Make BRAM contents at any 24-bit address readable from outside the C64 via
a small set of $DFxx I/O registers. Primary use: confirm what bytes are
actually at $C003-$C00F in BRAM during the Asterix hang, and detect
BRAM-vs-SDRAM disagreement.

## Why

Hardware locks at PC=$C003 with a tight SBC al,X + BRA loop. The bench's
500K-instruction trace contains zero $C003 visits and reaches $CB00 cleanly
(see `memory/project_asterix_c003_off_path.md`). On bench, $C003 = $EA
(NOP); on hardware it apparently contains $FF (SBC al,X) garbage. Without
a peek mechanism we cannot verify the bytes, so cannot validate the
"NOP-fill the danger zone" hypothesis directly. The memzap-via-BASIC test
attempted this but was inconclusive due to mtype timing and BRAM-write
semantics (`uart_asterix_zap2.uart`).

## Constraints

- $DFxx address space is densely populated already (see `c64.sv`
  `reu_reg_mux` cases — $DF09-$DF1F all occupied with REU/SDRAM
  diagnostic counters; $DF20-$DFA0 is the trace ring page; $DFC0-$DFEF
  is more diag; $DFF0+ is even more diag).
- Cannot afford to deprecate active diagnostic counters that are still
  load-bearing (REU readback, SDRAM-write tests, etc.).
- BRAM is dual-port (`c64_ram64k.vhd` exposes Port A + Port B). Port A
  serves CPU; Port B is currently used for some diagnostic but verify.

## Proposed implementation

### Address registers (writable via POKE)

Repurpose three diagnostic counters that are currently noisy/reset-prone
and reserve them for peek address:

- `$DF1D` — peek_addr_lo  (was: dbg_wr_pending — minimal info, can lose)
- `$DF1E` — peek_addr_mid (was: dbg_iowr_nonzero_bankhi — already
  captured; can repoint to a different diag if still needed)
- `$DF1F` — peek_addr_hi  (was: dbg_iowr_bankhi_val — same)

**Better alternative**: pick a fresh $DFxx range that's currently a hole.
$DFA1-$DFBF (161-191) appears to be the REU-fetch diagnostics' tail —
verify free slots there, e.g. $DFAB/$DFAC/$DFAD.

### Trigger (also a POKE)

POKE to the peek-data address ($DF1B for the result, OR a dedicated
"peek_arm" address) triggers a one-shot SDRAM/BRAM read at the latched
address. Reuse the existing `reu_rb_pending` pipeline:
- Set `reu_rb_addr <= {peek_addr_hi, peek_addr_mid, peek_addr_lo}`
- Set `reu_rb_pending <= 1`
- The existing readback machinery will populate `reu_rb_data` after
  ~5 clk_sys cycles, exposed at `$DF1B`.

### Read

PEEK($DF1B) returns the byte. Software polls `$DF1C` (status reg with
`reu_rb_done`) until done, then reads `$DF1B`.

### From-the-host tooling

A small Python helper:
```python
def peek_bram(c, addr):
    # POKE $DF1D/$DF1E/$DF1F with addr bytes
    # POKE peek_arm to trigger
    # poll $DF1C for done bit
    # read $DF1B
```

Wire this through `tools/mister_debug.py peek <hex_addr>`.

## Test plan

Once implemented + deployed:

1. Cold-reset, load asterix MGL, wait for hang (W:C003 stable).
2. From host: `python tools/mister_debug.py peek C003 C010` → dumps 16
   bytes starting at $C003. Verify they match the captured opcode
   pattern ($FF, ..., $80, ...) deduced from UART per-vblank samples.
3. Compare BRAM[$C003] vs SDRAM[$C003]. Use a separate peek_target
   register bit to select source (or sample both via dual reads).
4. Memzap retry (now reliable): cold reset, load MGL, wait for hang.
   POKE peek-write loop to fill BRAM[$C000-$FEFF] with $EA. POKE again
   to trigger CPU reset/restart-asterix. Capture UART. If hang breaks,
   confirms "wrong-jump into uninitialised RAM" hypothesis.

## Risk notes

- The deployed RBF currently has v115 PC=$C003 trigger + sanity-edit
  hacks (per `docs/session_handoff.md`). A fresh RBF with this peek
  register on top of clean source is the right baseline.
- BRAM Port B may already be used (search for `c64_ram64k` instantiation
  in `fpga64_sid_iec.vhd` to verify port usage). If so, time-multiplex
  Port B between peek reads and existing usage, OR add a third-port
  read mux at the BRAM read path.
- Keep the peek path side-effect-free w.r.t. CPU bus — read should not
  steal cycles from the CPU, otherwise we change the timing being
  diagnosed.

## Why this is the highest-leverage probe

One RTL change unlocks:
- Direct verification of "what's at $C003 in BRAM" — answers the off-path
  hypothesis empirically.
- BRAM-vs-SDRAM mismatch detection at any address.
- Memzap as a reliable test instead of a flaky BASIC POKE.
- General future debugging — "what's actually in memory" is the most
  asked question and we don't have a clean answer mechanism.
