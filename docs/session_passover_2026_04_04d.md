# Session Passover 2026-04-04d: Vector Fix Confirmed + New Crash at K:08

## Summary
Completed the `vec_wr_data` debug wiring, built, deployed, loaded doom.reu via OSD, launched Doom. The bank $00-$01 vector fix IS working: V changed from default to $2402. Game gets further (black screen = VIC reconfigured) but crashes at K:08 in a BRK loop.

## Key Findings

### 1. Native Vector Registers Work Correctly
- At C64 BASIC idle: V:E505 (not FF00!) — KERNAL boot populates native vectors
- The kickstart ROM enters native mode, copies KERNAL to SRAM (banks $00-$01)
- This includes $FFEE/$FFEF → native IRQ vector = $E505 (C64 KERNAL IRQ handler)
- W0105 = first $FFEE write was from bank $01, data $05 (low byte of $E505)
- This confirms the bank $00-$01 vector write condition works

### 2. Doom's Crash State
```
A:FFE7 K:08 B:00 S:06CC P:27 I:00 E:0 F:xxxx T:00/80 C:0000 N:04CC V:2402W0105!/.
```
- E:0 — Native mode (good)
- K:08 — Running in bank $08 (not $9B like before, not $27 like iteration 1)
- I:00 — BRK opcode (game dispatch loop)
- V:2402 — IRQ vector updated to $2402 (was $E505 at boot, now game's vector)
- Screen: BLACK (VIC reconfigured by Doom init)
- N:04CC — ~1228 enables/frame (game code is executing)
- VIC IRQ alternates between asserted and not (T:00 vs T:80)

### 3. V:2402 Analysis
- Expected final vector: $0D3C (raster IRQ handler at bank $80:$0B8D)
- Actual vector: $2402 — likely an intermediate init vector
- Doom's init writes to $FFEE multiple times during setup
- Game crashes at K:08 before reaching bank $80's raster setup code
- The raster IRQ enable at $D01A probably never gets written

### 4. Comparison with Previous Iterations
| Iteration | Bank Check | V Value | Crash Bank | Screen |
|-----------|-----------|---------|------------|--------|
| Original  | bank=$00 only | FF00 | - (BRK loop at K:9B) | Unchanged |
| 1 (no check) | any | 2804 | K:27 | Black |
| 3 (bank $00-$01) | $00 or $01 | 2402 | K:08 | Black |

All vector-fix iterations crash (different banks), but the game gets further each time.
The crash bank correlating with the vector value suggests the vector contents affect execution.

### 5. Build/Deploy Notes
- mtype.py: MUST use single call for everything (OSD + wait + POKE/SYS)
- Multiple mtype.py calls break uinput device registration
- REU load via OSD: F12, down×4, enter (Load REU), wait:2, down, enter (doom.reu)
- 40-second wait needed for 16MB REU load
- C64.cfg must be deleted before each deploy

## UART Debug Format (updated)
```
A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxxx N:xxxxx V:xxxxWbbdd!
```
- V:xxxx = native IRQ vector ($FFEE/$FFEF)
- Wbbdd = first $FFEE write: bb=bank byte, dd=data byte
- ! = VIC IRQ asserted, . = not asserted

## Next Steps
1. **Investigate why game crashes at K:08**: Could be SuperRAM read issue in bank $08,
   or the execution path is wrong because the intermediate vector $2402 causes bad IRQ handling.

2. **Consider removing emu_mode_816 check from vector writes**: The KERNAL boot writes
   to $FFEE in emulation mode (it shouldn't, but our vector registers capture it).
   On a real SuperCPU, the SRAM at $FFE4-$FFEF is always writable regardless of mode.
   Our `emu_mode_816 = '0'` check may be too restrictive.

3. **Consider allowing vectors from any bank**: The real SuperCPU SRAM is at physical
   addresses $00:FFE4-$00:FFEF. A write to $FFEE from any bank (as long as it maps to
   physical bank $00) should update the vector. The 65816's DBR only affects data addressing
   — writes to $FFEE with any DBR should map to physical $00:FFEE.

4. **Check $D01A**: Even if the IRQ vector is correct, raster IRQ won't fire unless
   $D01A bit 0 is set. Doom's bank $80 code writes both $FFEE and $D01A together.
   If the game crashes before reaching that code, neither is set up.

## Files Modified This Session
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — Added `dbg_vec_wr_data_o` output port
- `C64_MiSTer/c64.sv` — Added `dbg_vec_wr_data` wire and connections
- `C64_MiSTer/rtl/debug_uart_fmt.sv` — Added data byte display (positions 73-74),
  shifted VIC IRQ indicator to position 75, newline to 76, LINE_LEN=77
