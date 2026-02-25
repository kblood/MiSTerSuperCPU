# SuperCPU Kickstart SIMM Detect — Technical Analysis

## Overview

The SuperCPU kickstart ROM (`scpu64.mif`) contains a SIMM (SuperRAM) detection
routine at `$F8:8148`. This document explains exactly how it works in the FPGA
implementation (where there is no real SuperRAM), and why it should exit correctly.

---

## Key address-decode facts

### `scpu_rom_en` (fpga64_buslogic.vhd, line ~248)
```vhdl
scpu_rom_en <= '1' when supercpu_en='1' and supercpu_rom='1' and cpuWe='0' and
                        (unsigned(supercpu_bank) >= x"F0" or
                         (supercpu_bank=x"00" and cpuAddr(15:13)="100"))
               else '0';
```
- **Reads from banks `$F0-$FF`**: `scpu_rom_en='1'` → `dataToCpu = scpuRomData` (kickstart ROM)
- **Writes to banks `$F0-$FF`**: `cpuWe='1'` → `scpu_rom_en='0'` → write goes to SDRAM
- This is **intentional** so the kickstart keeps executing even after `scpu_rom_vis='0'`

### SDRAM bank addressing
The `supercpu_bank` byte (`addr_hi_816`) is currently **not** incorporated into the SDRAM
address (`ramAddr` is 16-bit only). All banks map to the **same 64 KB SDRAM space**.
Therefore `$F6:$0000` and `$02:$0000` are the **same SDRAM cell**.

### `$D0B2` override (fpga64_sid_iec.vhd, line ~573)
```vhdl
x"00" when (supercpu_en='1' and addr_hi_816=x"00" and cs_vic='1'
            and cpuAddr(11:0)=x"0B2") else
```
`$D0B2` returns `$00` (not VIC-II open-bus `$FF`). This is **critical** — see below.

---

## Kickstart execution flow (reset → KERNAL)

```
$FFFC → $FC90 (kickstart reset vector, scpu_rom_vis='1')
$FC90: JML $F8:00FC → JML $F8:80C1  (enter kickstart)

$80C1: SEI; CLC; XCE  → native mode (E=0)
$80C4: REP #$38       → 16-bit A/X/Y
$80C9: TCS            → SP=$01FF
$80CD: TCD            → DP=$0000
$80CE-$80EF: 3x MVN   → copies ROM data to bank $01 SDRAM
$80F2: SEP #$30       → 8-bit mode
$80F4-$80F6: TDC→PHA→PLB → DBR=$00
$80F7: STA $D07E ($00) → scpu_rom_vis='0'  ← hides kickstart from $E000-$FFFF
$810E: JSL $F8:8148   → SIMM detect subroutine
$8112: LDA $D27F; SEC; SBC $D27D; BEQ $813D  ← skip display if SIMM det. cleared both
$813D: PHB; REP #$20
$8140: LDA $FFFC      ← reads C64 KERNAL reset vector (scpu_rom_vis='0', scpu_rom_en='0')
$8143: DEA            → $FCE1
$8144: PHA            → push $FCE1 (16-bit)
$8145: SEC; XCE       → emulation mode
$8147: RTL            → returns to $00:$FCE2 (C64 KERNAL)
```

---

## SIMM detect subroutine ($F8:8148) — step by step

### Entry state
- M=1, X=1 (8-bit mode from SEP #$30 at $80F2)
- DBR=$00, PBR=$F8, SP=$01FC (after JSL)
- `scpu_rom_vis='0'` (set at $80F7)

### Setup ($8148-$8172)
```
$814A: LDA $D0B2  → returns $00 (override; NOT VIC open-bus $FF)
$814D: PHA        → push $00
$814E: STA $D07E  → writes $00 → scpu_rom_vis stays '0' ✓
                    (if $D0B2 returned $FF here, scpu_rom_vis would become '1' → INFINITE LOOP BUG)
$8151: LDA $F6:0000 → scpu_rom_en='1' (bank $F6 ≥ $F0, read) → ROM byte $53
$8155: PHA        → push $53 (to restore later)
$8156: LDA $04 ($00 initially); PHA
$8159: PEI ($02)  → push {ZP$03,$02} = {$00,$00}
$815B: STZ $02
$816A: STA $03=$08, STA $04=$F6, LDX #$00
```

### First size test ($8174-$8180)
```
$8174: JSR $8205  test: [$02]=$F6:$0800 vs $F6:$0000
  In $8205:
    LDA $F6:$0800 → scpu_rom_en='1' → ROM byte (constant)
    XBA; LDA $F6:$0000 → ROM byte $53; EOR #$FF → $AC
    STA $F6:$0000 → cpuWe='1' → SDRAM[$0000]=$AC
    XBA; EOR $F6:$0800 → ROM byte (same) → result=$00, Z=1
$8177: BNE $819D  → Z=1, not branching

$817B: ASL $03 → ZP$03=$10; JSR $8205  test: [$02]=$F6:$1000 vs $F6:$0000 → Z=1
$8180: BEQ $819D  → BRANCHES with X=$04
$819D: STX $D27B=$04, STX $D078=$04
$81A3: ZP$03=$00, ZP$04=$02
```

### Main alias loop ($81A9) — FIRST iteration: ZP$04=$02, ZP$03=$00
```
LDA [$02] = $02:$0000  → scpu_rom_en='0' (bank $02 < $F0) → SDRAM[$0000]
                          = $AC (written by $8205 above) or $53 after restore pass
EOR #$FF → inverted value
STA $F6:$0000 → cpuWe='1' → scpu_rom_en='0' → SDRAM[$0000] = inverted value
EOR #$FF → original
CMP [$02] = read $02:$0000 = SDRAM[$0000] = inverted value  ← DIFFERENT!
BNE $81D7 → EXITS on first iteration ✓
```
**Why it exits**: `$F6:$0000` and `$02:$0000` are the same SDRAM cell (bank byte ignored).
Writing to `$F6:$0000` IS readable back via `$02:$0000`.

### Exit path ($81D7-$8204)
```
$81D7: A=$03=$00 → STA $D27E=$00
$81DC: A=$04=$02 → STA $D27F=$02
$81E1: EOR #$02 → $00; ORA $03 → $00; BNE not taken
$81E7: DEA → $FF; STA $D27B=$FF
$81EB: STZ $D27D; STZ $D27F  ← BOTH cleared to $00
$81F1-$8204: cleanup PLAs, restore ZP$02-$04, restore $F6:$0000, RTL
```

### Return to $8112
```
LDA $D27F = $00 (STZ'd)
SEC; SBC $D27D ($00, STZ'd) → $00, Z=1
BEQ $813D → TAKEN ✓  (skip SIMM size display)
```

### LDA $FFFC at $8140
- `supercpu_bank=$00`, `cpuAddr=$FFFC`, `cpuWe='0'`
- `scpu_rom_en`: bank=$00, addr=$FFFC → bits[15:13]="111" ≠ "100" → `scpu_rom_en='0'`
- `supercpu_rom_vis='0'` → `romData = kernalData` (C64 KERNAL BRAM)
- Returns **`$FCE2`** (DolphinDOS and std_C64 both have `$FFFC=$E2,$FFFD=$FC`)

---

## CONFIRMED BUG: scpu_rom_en active after kickstart completes

**Observed** (from hardware): K=$F8, B=$00, E=1, A shows $8092/$809B  
→ Kickstart completed (reached bank $F8), now in bank $00 emulation mode  
→ CPU hitting $8092/$809B in bank $00 → scpu_rom_en='1' → reads kickstart data instead of BASIC ROM → CRASH

**Root cause**: The `supercpu_bank=$00 and addr $8000-$9FFF` clause in scpu_rom_en was active even after `scpu_rom_vis='0'`. BASIC ROM at $8000-$9FFF was being replaced by kickstart code.

**Fix applied** (fpga64_buslogic.vhd, line ~248):
Added `and supercpu_rom_vis = '1'` to the bank-$00 clause:
```vhdl
scpu_rom_en <= '1' when ... and
                        (unsigned(supercpu_bank) >= x"F0" or
                         (supercpu_bank = x"00" and cpuAddr(15:13)="100"
                          and supercpu_rom_vis = '1'))  -- NEW
               else '0';
```
Banks $F0-$FF still always serve ROM (needed for kickstart execution in bank $F8).
Bank $00/$8000-$9FFF: kickstart ROM only during initial boot (scpu_rom_vis='1').
Once kickstart writes $00 to $D07E (scpu_rom_vis='0'), BASIC ROM visible normally.


| Condition | Effect |
|-----------|--------|
| `$D0B2` read returns `$FF` instead of `$00` | STA `$D07E`(`$FF`) → `scpu_rom_vis='1'` → LDA `$FFFC` reads kickstart `$FC90` → infinite loop |
| `scpu_rom_en='1'` gated on `scpu_rom_vis` | Kickstart stops executing after `$80F7` |
| Bank byte included in SDRAM address | `$F6:$0000` ≠ `$02:$0000` → SIMM detect loop runs ~62K iterations |
| P65C816 bug in long-addressing opcodes | SIMM detect reads/writes wrong addresses → loop never exits |

---

## Debug overlay interpretation

After build with `B:xx` field (current bank) in Row 1:

```
Row 1: A:xxxx B:xx K:xx R:xx
Row 2: S:xxxx P:xx I:xx E:x
```

| K | B | A | Diagnosis |
|---|---|---|-----------|
| $00 | $00 | $FCxx | JML $F8 failed; 6510/emulation mode |
| $F8 | $F8 | $8xxx | Stuck in kickstart (SIMM detect?) |
| $F8 | $00 | $FCxx-$FFxx | Kickstart OK, KERNAL running |
| $F8 | $00 | $0000-$9FFF | Kickstart OK, KERNAL crashed |

---

## KERNAL reset vectors (verified)
- `std_C64.mif`: `$FFFC=$E2`, `$FFFD=$FC` → vector=`$FCE2` ✓
- `dol_C64.mif`: `$FFFC=$E2`, `$FFFD=$FC` → vector=`$FCE2` ✓  
  (MIF uses multi-byte lines; KERNAL is at offset `$2000` in the 16 KB MIF file)
