# Boot-minimum subset hypothesis from VICE

This document captures the current working hypothesis for the *smallest* set of
machine behavior our reduced Verilator harness likely needs in order to cold-boot
to BASIC `READY.`.

It is intentionally narrower than “fully simulate the whole C64/MiSTer core”.

## Current hypothesis

To reach a believable cold boot and `READY.` in the reduced harness, we likely need:

### 1. Real-ish memory and ROM visibility
Needed:
- RAM readable/writable in normal C64 locations
- BASIC/KERNAL/CHAR ROM visibility in the expected ranges
- color RAM availability
- correct visibility of I/O pages `$D000-$DFFF`

Why:
- VICE explicitly wires these regions in `c64meminit.c`
- boot cannot progress correctly if ROM/I/O mapping is wrong even when CPU is running

### 2. VIC-II active enough for text-screen boot
Needed:
- current real VIC path retained
- correct screen RAM visibility from bank `$00`
- plausible VIC bank selection inputs from CIA2

Why:
- VICE brings up VIC-II before normal runtime
- our screen RAM staying at all zeroes strongly suggests boot never reaches meaningful display initialization, or display-facing memory/banking is wrong

### 3. CIA1 must be more than a constant-read stub
Needed minimum:
- PRA / PRB registers
- DDRA / DDRB registers
- reads that combine output latch, DDR, and input pins
- stable no-key keyboard matrix semantics

Probably not optional:
- keyboard-scanning-facing behavior compatible with CIA port reads

Why:
- VICE `c64cia1.c` uses real matrix-aware read functions for both ports
- a constant `$FF` stub is almost certainly too weak as a boot model

### 4. CIA2 must at least support banking-relevant port behavior
Needed minimum:
- port A latch / DDR behavior
- enough semantics for VIC bank-related outputs to be believable
- no spurious interrupts

Why:
- CIA2 contributes to VIC banking and other machine-side control signals
- even if full IEC behavior is unnecessary, totally fake CIA2 outputs may break screen setup

### 5. Clean reset / power-up behavior
Needed:
- deterministic reset ordering
- no accidental conflation of reset with power-up
- memory init performed before the ROM relies on it

Why:
- VICE separates `machine_specific_reset()` from `machine_specific_powerup()`
- this is a likely place where reduced harnesses can accidentally under-model the machine

## Things that may *not* be required for first `READY.`

These are currently suspected to be nonessential for the first successful BASIC screen:

- full SID audio fidelity
- full IEC drive behavior
- cartridge behavior beyond “inactive / harmless”
- REU
- tape behavior
- advanced joystick behavior
- most UI/autostart support

These subsystems may matter later, but they are not the first place to spend another 35-minute rebuild.

## Open questions

### Do we need real CIA timers for first `READY.`?
Unknown.

VICE has a sophisticated CIA timer implementation, but that does **not** automatically mean
the ROM needs full timer correctness before the first BASIC prompt appears.

Current working guess:
- port/DDRx semantics are probably first-order
- full timer behavior may be second-order

### Do we need real CIA IRQ behavior for first `READY.`?
Unknown.

Likely minimum:
- no spurious IRQ/NMI
- possibly enough interrupt register behavior to keep ROM code happy

### How much keyboard modeling is required?
Likely minimum:
- stable “no keys pressed”
- no phantom stuck-low lines
- enough matrix interaction that CIA port reads look sane

## Recommended next implementation batch

Instead of more one-register-at-a-time experimentation, the next fidelity jump should likely be:

1. strengthen CIA1/2 behavior as a single coherent step
   - PRA/PRB
   - DDRA/DDRB
   - readback semantics
   - stable keyboard-matrix-facing defaults
2. re-check reset/power-up sequencing in the harness
3. keep VIC real
4. avoid spending time on SID/IEC/REU until vanilla reaches `READY.`

## Success criterion

A good next milestone is not “simulate everything”.
It is:

> vanilla reduced harness reaches a convincing BASIC `READY.` screen with no PRG injection

Once that works, the same minimum subset can be applied more confidently to the SuperCPU harness.
