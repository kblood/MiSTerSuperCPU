# MiSTer C64 REU Register Map

## Critical: $DF00 is Read-Only, Command is at $DF01

The MiSTer C64 core's REU implementation (reu.v) has the command register
at **$DF01**, NOT $DF00. This matches the real 1750 REU hardware where $DF00
is the read-only status register and $DF01 is the write-only command register.

Many online tutorials incorrectly describe $DF00 as "Status/Command" implying
you write the command to $DF00. This is WRONG for both real hardware and MiSTer.

## Register Map

| Address | Decimal | R/W | MiSTer offset | Register |
|---------|---------|-----|---------------|----------|
| $DF00 | 57088 | R | 0 | Status Register (read clears it) |
| $DF01 | 57089 | W | 1 | Command Register (triggers DMA) |
| $DF02 | 57090 | R/W | 2 | C64 Base Address LOW |
| $DF03 | 57091 | R/W | 3 | C64 Base Address HIGH |
| $DF04 | 57092 | R/W | 4 | REU Base Address LOW |
| $DF05 | 57093 | R/W | 5 | REU Base Address MID |
| $DF06 | 57094 | R/W | 6 | REU Base Address HIGH (bank) |
| $DF07 | 57095 | R/W | 7 | Transfer Length LOW |
| $DF08 | 57096 | R/W | 8 | Transfer Length HIGH |
| $DF09 | 57097 | R/W | 9 | Interrupt Mask |
| $DF0A | 57098 | R/W | 10 | Address Control |

## Command Register ($DF01) Bit Layout

| Bit | Name | Description |
|-----|------|-------------|
| 7 | Execute | 1 = DMA armed |
| 6 | Reserved | |
| 5 | Autoload | 1 = reload addr/length after completion |
| 4 | FF00 Disable | **MiSTer: 1 = immediate, 0 = wait for $FF00 write** |
| 3-2 | Reserved | |
| 1-0 | Type | 00=STASH, 01=FETCH, 10=SWAP, 11=VERIFY |

### DMA Trigger Logic (reu.v line 152)

```verilog
if(cmd[7] & (cmd[4] | ff00_wr)) begin
```

- `$90` (144): Execute + bit4 + STASH → **immediate STASH**
- `$91` (145): Execute + bit4 + FETCH → **immediate FETCH**
- `$80` (128): Execute + STASH → deferred (waits for $FF00 write)
- `$81` (129): Execute + FETCH → deferred (waits for $FF00 write)

## Status Register ($DF00) — Read Only

| Bit | Name | Description |
|-----|------|-------------|
| 7 | IRQ Pending | Interrupt pending |
| 6 | End of Block | Transfer completed |
| 5 | Fault | Verify error |
| 4 | Size | 1 = 256KB+ (1764/1750), 0 = 128KB (1700) |
| 3-0 | Version | Always 0 on MiSTer |

After successful transfer: PEEK(57088) = $50 (80 decimal) = End of Block + Size
**Reading status clears it** (reu.v line 134: `status <= 0`)

## BASIC Examples

### STASH 256 bytes from C64 $0400 to REU bank 0 offset $0000

```basic
POKE 57090,0:POKE 57091,4:REM C64 ADDR=$0400
POKE 57092,0:POKE 57093,0:POKE 57094,0:REM REU=$000000
POKE 57095,0:POKE 57096,1:REM LENGTH=256
POKE 57098,0:REM ADDR CTL=BOTH INCREMENT
POKE 57089,144:REM CMD=$90=IMMEDIATE STASH
PRINT PEEK(57088):REM SHOULD=80 (END OF BLOCK)
```

### FETCH 256 bytes from REU bank $20 offset $0000 to C64 $C000

```basic
POKE 57090,0:POKE 57091,192:REM C64 ADDR=$C000
POKE 57092,0:POKE 57093,0:POKE 57094,32:REM REU=$200000
POKE 57095,0:POKE 57096,1:REM LENGTH=256
POKE 57098,0:REM ADDR CTL=BOTH INCREMENT
POKE 57089,145:REM CMD=$91=IMMEDIATE FETCH
PRINT PEEK(57088):REM SHOULD=80 (END OF BLOCK)
```

### One-liner STASH/FETCH roundtrip test

```basic
POKE49152,120:POKE49153,216:REM WRITE TEST DATA
POKE57090,0:POKE57091,192:POKE57092,0:POKE57093,0:POKE57094,0
POKE57095,4:POKE57096,0:POKE57089,144:REM STASH 4B
POKE49152,0:POKE49153,0:REM CLEAR RAM
POKE57090,0:POKE57091,192:POKE57092,0:POKE57093,0:POKE57094,0
POKE57095,4:POKE57096,0:POKE57089,145:REM FETCH 4B
PRINT PEEK(49152);PEEK(49153):REM SHOULD=120 216
```

## What Went Wrong Before

All previous REU tests failed because:
1. Command was POKEd to $DF00 (57088) — **read-only status register, writes ignored**
2. C64 address was POKEd to $DF01 (57089) — **this is actually the command register**
3. All registers were off by 1 position
4. Even when command was correct address, $80 was used instead of $90
   (bit 4=0 means deferred/FF00 trigger in MiSTer, not immediate)

## Source Files

- `C64_MiSTer/rtl/reu.v` — REU implementation (Alexey Melnikov)
- Reset state: `cmd <= 'h10` (bit 4 set = immediate mode ready)
- After DMA completes: `cmd[4] <= 1; cmd[7] <= 0` (clears execute, keeps immediate)
