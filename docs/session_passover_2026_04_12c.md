# Session Passover 2026-04-12c: Doom Progress — K:2D Running, New Crash Pattern

## Headline

**Doom progresses past K:20 init to K:2D game code!** Runs for ~2.5 minutes before crashing.
Previous STP crash (C:4895, N:3FC5) no longer occurs — different build fitter placement may have
resolved marginal clk64 timing. New crash: PBR transitions from $2D→$00, CPU executes BRAM
garbage in BRK loop. Root cause unknown — likely RTL/IRQ bank handling bug.

## 1. Loading Solved — mbc with Custom Core at Stock Location

**Reliable doom.reu loading method:**
1. Copy custom core to stock location: `cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64_20250828.rbf`
2. Load via mbc: `mbc load_rom C64.PRG /media/usb0/C64/doom.reu`
3. mbc loads the (now-custom) stock core + routes doom.reu via `reu_by_ext` to REU SDRAM

**Why this works:** mbc maps `C64.PRG` to `/media/fat/_Computer/C64_20250828.rbf` (dated filename).
By replacing that file with our custom core, mbc uses our `reu_by_ext` to correctly route .reu files.

**Correct Doom launcher (POKE):**
```
POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92
POKE49156,0:POKE49157,0:POKE49158,32
SYS49152
```
= SEI, CLC, XCE, JML $20:0000

**Wrong launcher** (what was accidentally used initially):
```
POKE49152,120:POKE49153,169:POKE49154,32:...
```
= SEI, LDA #$20, STA $D078 (cache flush), STA $D079 (turbo) — NOT the Doom launcher!

## 2. Previous STP Crash Gone

The deterministic STP crash (C:4895, N:3FC5, L:80, I:DB, A:81A1) from the 04-12b session
**no longer occurs**. The new build (different fitter placement, RBF size 4,159,896 vs 4,190,008)
avoids this crash entirely.

This strongly suggests the STP crash WAS a timing-related issue (clk64 marginal path at -0.27ns)
that manifested deterministically due to specific SDRAM access patterns.

## 3. New Crash: K:2D→K:00 BRK Loop

After ~2.5 minutes of K:2D execution (7,861 frames), Doom crashes:

**Last good frame (F:1EB5):**
```
A:00F8 K:2D B:00 S:01FD P:80 I:85 E:0 T:FF C:014F N:0778 W:0411 L:80
```
- K:2D = Doom game code, A:00F8, I:85 (STA dp), S:01FD (normal stack)

**First bad frame (F:1EB6):**
```
A:0111 K:00 B:00 S:FF31 P:15 I:BF E:0 T:FF C:0649 N:0BC9 W:0411 L:80
```
- K:00 = bank $00! CPU executing BRAM, I:BF (LDA long,X), S:FF31 (stack wrapped)
- P:15 = X=1(8-bit X), I=0, C=1 — wrong flags

**After crash: BRK loop**
- CPU bounces between BRK ($00) at random BRAM addresses and vector fetch ($FFE6/$FFE7)
- Stack pointer wanders wildly ($81A1, $5D58, $14C2, etc.)
- I:00 (BRK), P:15 consistent in BRK loop

## 4. Diagnostic Additions

### W: field (replaces V:)
- Shows last CPU address when PBR was $20 or $2D (Doom code banks)
- Value: W:0411 — last K:20 address was $0411 (after JML $80:005C return)

### L: field (updated)
- Changed to capture PBR at the moment of K:00 transition (was: first non-expected PBR)
- L:80 → the PBR was $80 just before K:00 transition? Or first trigger?
- **Needs rebuild** to activate new logic (build in progress)

## 5. Doom Code Analysis

### Entry point ($20:0000) — correct
```
SEI, CLD, CLC, XCE, REP #$30, LDA #$0000, TCD, LDA #$01FF, TCS, ...
```
Sets up native mode, 16-bit, DP=0, SP=$01FF. Standard SuperCPU init.

### Bank $80 subroutines — legitimate
JML $80:005C is a copy routine that copies WAD data to bank $00 RAM:
- Loop 1: $07B8 bytes from $80:05D9 to $00:0800
- Loop 2: $0D06 bytes from $80:0D91 to $00:1000
- Loop 3: $0004 bytes from $80:1A97 to $00:0010
- Returns via JML [$00FC] (return address stored at DP $FC-$FF)

### JML [abs] verification
P65C816 correctly uses bank $00 for JML [abs] indirect fetch (address mode "0110" = `x"00" & AA`).
Confirmed by reading MCode.vhd line 2005-2007 and P65C816.vhd line 595-596.

## 6. Hypotheses for K:2D→K:00 Crash

### A. IRQ handler not installed correctly
Doom should install a native IRQ handler by writing to $FFE4-$FFEF in bank $00. If the
scpu_native_vec write path fails (wrong gating, wrong address), the IRQ handler stays at
$FF00 (RTI stub). When a VIC IRQ fires in K:2D, it vectors to $00:FF00 → RTI → return.
But if RTI itself has a bug...

### B. RTL returning wrong bank
If Doom uses JSL/RTL for bank $2D subroutines, and the RTL reads wrong bank byte from
stack (due to stack corruption or BRAM read bug), PBR goes to $00.

### C. SuperRAM read corruption (timing)
If the SDRAM timing is still marginal (clk64 slack), a specific instruction sequence in
K:2D could read wrong data from SuperRAM, causing a JML to wrong bank.

## 7. Files Modified This Session

- `c64.sv`: Added `last_k20_addr` register, updated crash_bank_latch to capture K:00 transition PBR
- `debug_uart_fmt.sv`: Changed V: to W: label

## 8. Next Steps

### Priority 1: Deploy improved crash diagnostic
Build in progress. New L: shows PBR before K:00 transition, W: shows last K:20/K:2D address.
After deploy, reproduce crash and check:
- W:xxxx — exact address in K:2D code just before crash
- L:xx — which bank PBR was in before transitioning to $00

### Priority 2: Check if Doom installs IRQ handler
Look for writes to $FFEE/$FFEF (native IRQ vector) in UART output. If V:xxxx changes from
$FF00 to a game address, Doom installed its handler. If it stays $FF00, the write path may be broken.

### Priority 3: Narrow down the failing instruction in K:2D
W:FFE6 shows the CPU ran off the end of bank $2D code into the zero-filled area.
The crash is NOT at the vector fetch — it's earlier, where a conditional branch or JML
in the K:2D game loop failed to redirect execution. Disassemble bank $2D to find the
last branch/JMP before $FFE6 that should have been taken.

### Key Architecture Insight
`addr_hi_816` (from P65C816 A_OUT[23:16]) correctly outputs $00 during IRQ/BRK vector
fetches (address mode "1111"), even though PBR register still holds the old bank ($2D).
`scpu_rom_stub_active` checks addr_hi_816, not PBR, so vector routing is correct.
The W: latch shows PBR=$2D at $FFE6 because PBR updates AFTER the vector fetch.

## 9. Build Environment

- Custom core at `/media/fat/_Computer/C64_20250828.rbf` (copied from `_Test/C64.rbf`)
- doom.reu at `/media/usb0/C64/doom.reu` (16MB, md5: b5b3f7f7988b754017f4dcdc9418b21d)
- UART baud: 115200 (set via stty after boot)
