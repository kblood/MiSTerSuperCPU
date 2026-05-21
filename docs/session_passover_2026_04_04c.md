# Session Passover 2026-04-04c: Doom Display Diagnosis

## Summary
Doom runs in native mode (E:0, K:9B, BRK dispatch loop) but display is blank. Diagnosed the root cause: the native IRQ vector at $FFEE/$FFEF is never updated from the default $FF00 (RTI stub). Confirmed by adding V:xxxx field to UART debug.

## Key Findings

### 1. REU/MGL Loading Works
- SD MGL with `path="doom.reu"` loads correctly via `load_core doom.mgl`
- First 128KB of doom.reu is zeros (matches file), so REU DMA returning zeros was a false alarm
- 24-bit ioctl counter wraps to 0 after 16MB (2^24 exactly) - another false negative
- C64.cfg must be deleted before each MGL load to avoid OSD config corruption
- C64_stock.rbf must be renamed/removed to prevent wrong core loading

### 2. IRQ Vector Never Updated (V:FF00)
- Added V:xxxx field to UART showing native IRQ vector ($FFEE/$FFEF = scpu_native_vec(12..13))
- With normal launcher (SEI CLC XCE JML $200000): V:FF00 (default, never changed)
- With modified launcher that writes vector: V:0D3C (correctly installed!)
- **Root cause**: Doom's init code in bank $80 writes to $FFEE/$FFEF but the writes are lost

### 3. Native Vector Write Condition Bug
The native_vec write condition at fpga64_sid_iec.vhd line 2071:
```vhdl
elsif supercpu_en = '1' and cpuWe = '1' and addr_hi_816 = x"00" then
```
Requires `addr_hi_816 = x"00"` (bank byte = $00). When Doom's bank $80 code does `STA $FFEE`:
- If DBR=$00: addr_hi_816=$00, write succeeds
- If DBR=$80 (or any non-$00): addr_hi_816=$80, write is SILENTLY LOST

The BRK vector at $FFE6/$FFE7 is also still $FF00 — the game's "dispatch to $0202" is actually BRK→RTI→return to caller at $0202, not a vector dispatch.

### 4. Doom's Raster IRQ Setup Code
Located at bank $80, offset $0B80-$0BB6:
```
$80:0B8D: LDA #$3C; STA $FFEE    (IRQ vector low = $3C)
$80:0B92: LDA #$0D; STA $FFEF    (IRQ vector high = $0D → handler at $0D3C)
$80:0B99: LDA $90; STA $D012     (set raster compare line low)
$80:0BA0-0BAB: set $D011 bit 7   (raster compare line high bit)
$80:0BAE: LDA #$01; STA $D01A    (ENABLE raster IRQ)
$80:0BB3: CLI                     (enable interrupts)
$80:0BB6: RTS
```
Called from many places within bank $80 via `JSR $0B5C`.

### 5. Modified Launcher Proof
Added IRQ vector install to the SYS49152 launcher:
```
78 18 FB              SEI; CLC; XCE (native mode)
A9 3C 8D EE FF        LDA #$3C; STA $FFEE
A9 0D 8D EF FF        LDA #$0D; STA $FFEF  
5C 00 00 20           JML $200000
```
Result: V:0D3C confirmed! Vector write works from our launcher (which has DBR=$00).

## Next Steps (in priority order)

### Fix 1: Allow native_vec writes from banks $00-$01 (APPLIED, iteration 3)
**Iteration 1**: Removed bank check entirely → V:2804 (garbage), crash at K:27. Game data writes from banks $20+ corrupt vectors.
**Iteration 2**: Added debug capture → W01! Shows the $FFEE write comes from bank $01 (DBR=$01), NOT bank $80.
**Iteration 3**: Allow writes when `addr_hi_816(7 downto 1) = "0000000"` (bank $00 or $01). Bank $01 is C64's "RAM under ROM" bank, commonly used as DBR for I/O-adjacent code. Game data in banks $20+ won't corrupt vectors.

The vector write block is now a separate `if` statement outside the `elsif ... addr_hi_816 = x"00"` gate for SuperCPU registers.

### Fix 2: Also need $D01A setup
Even with the vector fixed, raster IRQ won't fire without $D01A=1 and proper raster compare. The bank $80 code sets all of these together. Fixing the vector write will likely fix everything since the bank $80 raster setup code writes both the vector AND $D01A.

### Fix 3: Verify $D01A write path
When bank $80 code does `STA $D01A` with DBR=$00, addr_hi_816=$00, the write should reach the VIC. But if DBR is not $00, the $D01A write also goes to SuperRAM instead of VIC. Same root cause as the vector issue.

## Results After Fix
- **V:2804** — IRQ vector DID change (no longer $FF00 default)! Fix confirmed working.
- Screen went BLACK (VIC reconfigured — game init went further than before)
- BUT: game CRASHED at K:27, A:0000, I:DC (JMP abs,X stuck at bank $27:$0000)
- T:00 — turbo OFF, all diag bits 0
- N:04CC — fewer enables (was 0x16F2 = 5874, now 0x04CC = 1228)
- Game took different execution path with vector fix — init progressed further
- Expected vector $0D3C but got $2804 — game may have written a temporary vector during init
- The stuck state suggests another issue (possibly in bank $27 SuperRAM read, or init sequence timing)

## Files Modified This Session
- `C64_MiSTer/rtl/debug_uart_fmt.sv` — Added V:xxxx (IRQ vector) + vic_irq indicator
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — Added dbg_irq_vector output port
- `C64_MiSTer/c64.sv` — Connected dbg_irq_vector to UART formatter

## UART Format (updated)
```
A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx V:xxxx.
```
V = native IRQ vector ($FFEE/$FFEF combined as 16-bit address)
Trailing `!` = VIC IRQ asserted, `.` = not asserted
