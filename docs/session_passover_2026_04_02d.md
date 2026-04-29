# Session Passover 2026-04-02d: SuperRAM Verified, Doom Crash Analyzed

## Goal
Get Doom C64 (doom.reu) running on the MiSTer SuperCPU core.

## Summary
Committed previous session's fixes (96e9262). Loaded doom.reu via OSD, launched with JML $200000. Doom's init ran partially (green/yellow screen, VIC colors changed) but crashed in a BRK loop. Analyzed doom.reu code structure and identified key issues.

## Key Findings

### 1. SuperRAM STA/LDA Round-Trip: WORKS (re-verified)
- `CLC, XCE, LDA #$42, STA $020100, SEC, XCE, STA $02, RTS` → PEEK(2) = 66 ✓
- The exact same test pattern from previous sessions still works
- SuperRAM write path (STA long to bank $02+) is confirmed functional

### 2. Native Mode Vector ROM Shadow Bug (NEW)
- **Root cause**: Native mode vectors at $FFE4-$FFEF fall inside KERNAL ROM ($E000-$FFFF)
- With default $01=$37, READS from $FFE4-$FFEF go to KERNAL ROM, not RAM
- Writing vectors to RAM is invisible unless KERNAL is mapped out ($01=$35)
- Fixed in test by adding `LDA #$35, STA $01` before native mode entry
- **This affected ALL previous crash tests**: vectors contained KERNAL ROM bytes, not RTI handlers
- The C64 KERNAL ROM bytes at $FFE6-$FFE7 happen to be $046C → handler at $6C04 (garbage)

### 3. STA Long to Bank $00 in Native Mode: SUSPECT
- Test writing result via `STA $000500` (STA long, native mode) → PEEK(1280) = 0
- But writing result via `STA $02` (emulation mode zero page) → PEEK(2) = 66 ✓
- **Possible explanations**:
  - STA long to bank $00 from native mode might route through wrong SDRAM path
  - Or: the SDRAM address mux for bank $00 (cart_addr path) behaves differently in native mode
  - Or: BRAM at $0500 is serving stale data and blocking the SDRAM write
- **Not yet conclusively tested** — need to verify if bank $00 STA long actually fails or if PEEK/readback has issues

### 4. Doom C64 Code Analysis
doom.reu entry at bank $20:$0000:
```
$200000: SEI, CLD, CLC, XCE           ; native mode
$200004: REP #$30                      ; 16-bit A,X
$200006: LDA #$0000, TCD              ; DP = $0000
$20000A: LDA #$01FF, TCS              ; SP = $01FF
$200012: SEP #$20, LDA #$00, PHA, PLB ; DBR = $00
$200018-$20003A: Disable CIA/VIC IRQs, clear pending
$20003D: LDA #$35, STA $01            ; KERNAL out
$200041: STA $D07E                     ; SuperCPU ROM overlay ON
$200044: STA $D07B                     ; Turbo mode ON
$200047: STA $D076                     ; Unknown register
$20004A: STA $D07F                     ; Register disable
$200057-$200121: Build 64K-entry lookup tables in banks $10-$19
$200121: BRL $2002F2
$2002F2-$20030F: Copy rendering code to bank $00 at $0200/$0300
$200310+: More init, clear DP locations, compute values
$2003EA: JML $80005C                   ; Jump to bank $80 for game data loading
```

Bank $80:$0000 starts with "SCPUMIPS" header (runtime library, version 3).
Bank $80:$005C copies 3 blocks to bank $00: $8005D9→$0800 (1976B), $800D91→$1000 (3334B), $801A97→$0010 (4B).
Returns via JML [$00FC] to $20:$03EA for post-init.
Post-init jumps to $2D06A0 (game engine main init).
Software call stack at dp $F4/$F6 in bank $F6 (downward-growing, $28 bytes/frame).
$D076 = "enable optimization" on real SuperCPU.
Bank $FF:$FFFE = $0020 (emulation IRQ vector in REU image).
SuperRAM usage: banks $02-$03 (lookup), $07 (data), $20-$2D (code), $40-$7F (WAD), $80-$87 (runtime), $F6 (stack), $FF (palette).

### 5. SuperCPU ROM Overlay Not Implemented
- Doom writes `STA $D07E` to enable SuperCPU ROM overlay
- On real hardware, this maps a ROM at $00:F800-$00:FFFF with:
  - Native mode interrupt vector handlers
  - BRK system call handler
  - System routines (DMA, serial, etc.)
  - Optimized KERNAL replacements
- Our implementation sets the `scpu_rom_overlay` flag but provides NO ROM content
- **This is a blocker for any software that relies on SuperCPU ROM routines**

## Doom Crash Analysis
1. Doom's init code runs successfully for a significant portion (changes VIC colors)
2. At some point, the CPU enters a BRK loop
3. With vector patching ($FFE6 → RTI at $0400), the crash still occurs but is caught
4. UART shows PBR=$37 or $35 (not $20 or $00), suggesting corrupted PC/PBR
5. Possible causes:
   a. Instruction fetch from SuperRAM returns wrong data (SDRAM contention)
   b. Code reaches a path that expects SuperCPU ROM (BRK system call, or JSR $Fxxx)
   c. $D076 register (unknown) triggers unexpected behavior

## Commits
- `96e9262`: Fix two SuperRAM regressions and crash latch bug (committed this session)

## Build State
- Current build: same as previous session (not rebuilt after commit)
- Deployed and tested on MiSTer

## Next Steps (Priority Order)
1. **Test STA long to bank $00 in native mode**: verify if BRAM interferes with bank $00 writes
2. **Build SuperCPU ROM stub**: provide minimal native mode vectors + RTI handlers at $F800-$FFFF
   - This would let Doom's BRK system calls gracefully return instead of crashing
3. **Test Doom with ROM stub + vector patching**: if BRK is used as a system call, the stub
   needs to handle it (RTI back to caller)
4. **Investigate $D076 register**: Doom writes to it — what does it do on real SuperCPU?
5. **Redesign BRAM 1MHz fix**: the reverted fix needs `not superram_in_pipeline` guard

## Remote Testing State
- MiSTer IP: 192.168.50.130, SSH root/1
- doom.reu at /media/fat/games/C64/doom.reu (SD), /media/usb0/games/C64/doom.reu (USB)
- superram_exec_test.prg uploaded to /media/fat/games/C64/
- OSD "Load REU *.REU" is 5th menu item (DOWN 4x from top)
- OSD loading doom.reu works (verified with OBS capture)

## Key Architecture Rules (updated)
1. **Native mode vectors require $01=$35** — KERNAL ROM shadows $FFE4-$FFEF otherwise
2. **STA long result → use emulation mode store** — STA long to bank $00 in native mode is suspect
3. **SDRAM address mux MUST be combinational** — verified still working
4. **SuperCPU ROM overlay provides NO content** — software expecting ROM handlers will crash
