# CMD SuperCPU Architecture Reference

Comprehensive technical reference based on original documentation, VICE source code,
and community knowledge. Compiled 2026-04-11 for the MiSTer SuperCPU implementation.

## 1. Hardware Overview

The CMD SuperCPU is a cartridge-based accelerator for the C64/C128 that replaces the
6510 CPU with a WDC W65C816S running at 20 MHz. The 65816 provides a 24-bit address
bus (16 MB address space), 16-bit accumulator/index registers in native mode, and
new addressing modes (long absolute, stack-relative, block move).

**Key components:**
- WDC W65C816S CPU (PLCC44 package, 20 MHz)
- 128 KB fast SRAM (zero-wait-state, banks $00-$01)
- 64-512 KB EPROM (SuperCPU firmware, mapped at $F0-$FF when bootmap active)
- Altera CPLD (EPM7128/EPM7160 class) — central glue logic
- Cartridge pass-through port (for REU, etc.)
- V2 has enhanced CPLD with WriteSmart and extended optimization modes

**How it takes over the bus:**
1. At boot, the 6510 runs briefly to set processor port ($00/$01)
2. The 6510 is then tristated (disconnected from bus)
3. The 65816 takes over, running from its own SRAM at 20 MHz
4. CPLD handles address decoding and drives C64 expansion port as needed
5. For I/O access ($D000-$DFFF), CPLD manipulates EXROM/GAME lines

Sources: [Underneath the Hood (Commodore Hacking #12)](http://mclauchlan.site.net.au/scott/C=Hacking/C-Hacking12/cmdcpu.html), [C64-Wiki: SuperCPU](https://www.c64-wiki.com/wiki/SuperCPU), [SuperCPU FAQ](http://supercpu.cbm8bit.com/faq.htm)

## 2. Memory Map

### Bank $00 ($000000-$00FFFF) — C64 Address Space

The primary 64 KB visible to both the CPU and VIC-II. CPU reads from SRAM at 20 MHz;
writes are mirrored to C64 motherboard DRAM via a 1-byte write buffer.

| Range | Contents |
|-------|----------|
| $0000-$0001 | 6510 processor port (emulated by CPLD) |
| $0002-$00FF | Zero Page (SRAM, V2: excluded from mirroring) |
| $0100-$01FF | Stack (SRAM, V2: excluded from mirroring) |
| $0200-$CFFF | RAM (mirrored to C64 DRAM per optimization mode) |
| $D000-$D07F | I/O: VIC-II, SID, CIA, SuperCPU registers |
| $D080-$D0FF | I/O: SuperCPU status registers |
| $D100-$D1FF | I/O space |
| $D200-$D2FF | SuperCPU system RAM (256 bytes, in I/O hole) |
| $D300-$D3FF | SuperCPU user RAM (256 bytes, in I/O hole) |
| $D400-$DFFF | SID / CIA / I/O area |
| $E000-$FFFF | KERNAL ROM (or SRAM shadow per $00/$01 config) |

### Bank $01 ($010000-$01FFFF) — SRAM Shadow / ROM Copies

Second 64 KB of on-board SRAM. At boot, SuperCPU firmware copies:
- C64 KERNAL ROM to $01:E000-$01:FFFF
- BASIC ROM to $01:A000-$01:BFFF
- CHARGEN ROM where needed
- SuperCPU OS code

These copies are write-protected (appear as ROM). Remaining space is user-available.
Writes to bank $01 are NOT mirrored to C64 motherboard DRAM.

### Banks $02-$EF — SuperRAM

Mapped to SuperRAM card (PS/2 SIMM module). Sizes: 1/4/8/16 MB.
- 1 MB: banks $02-$11
- 16 MB: banks $02-$FF (overlaps $F0-$FF when bootmap off)

CPU can execute code directly from SuperRAM. Access is slightly slower than
on-board SRAM but much faster than C64 DRAM.

### Banks $F0-$FF — ROM / Bootmap

When **bootmap enabled** ($D0B7): maps to SuperCPU EPROM firmware.
When **bootmap disabled** ($D0B6): maps to SuperRAM (or open bus).

Boot sequence: reset → bootmap enabled → ROM code copies ROMs to SRAM →
bootmap disabled → normal operation.

### VICE Memory Sizes (from source)
```
SCPU64_RAM_SIZE      = 0x10000  (64 KB — C64 motherboard RAM)
SCPU64_SRAM_SIZE     = 0x20000  (128 KB — SuperCPU SRAM, banks $00-$01)
SCPU64_ROM_MINSIZE   = 0x10000  (64 KB minimum ROM)
SCPU64_ROM_MAXSIZE   = 0x80000  (512 KB maximum ROM)
SIMM RAM: 1-16 MB (dynamic)
```

Source: [VICE scpu64mem.h](https://github.com/svn2github/vice-emu/blob/master/vice/src/scpu64/scpu64mem.h)

## 3. Register Map

All registers in I/O area. $D07x are write-sensitive switches (any write triggers).
Registers only active when hardware registers enabled ($D07E).

### $D07x — Control Registers

| Address | Function | Notes |
|---------|----------|-------|
| $D072 | System 1 MHz enable | Hardware-level speed lock |
| $D073 | System 1 MHz disable | Clears system 1 MHz flag |
| $D074 | VIC Bank 2 Optimization | Mirror only $8000-$BFFF |
| $D075 | VIC Bank 1 Optimization | Mirror only $4000-$7FFF |
| $D076 | BASIC Optimization | Mirror only $0400-$07FF |
| $D077 | No Optimization (default) | Mirror ALL of bank $00 |
| $D078 | SIMM Configuration | Sets page size for SuperRAM |
| $D079 | Software Turbo (= $D07B) | Clears soft 1 MHz flag |
| $D07A | Software 1 MHz enable | Sets soft 1 MHz flag |
| $D07B | Software Turbo enable | Clears soft 1 MHz flag |
| $D07D | HW Register Disable (= $D07F) | |
| $D07E | HW Register Enable | Activates register set |
| $D07F | HW Register Disable | Deactivates register set |

### $D0Bx — Status/Flag Registers

| Address | R/W | Function |
|---------|-----|----------|
| $D0B0 | R | Mode Detect (b7-6: 00=v2/128, 01=v2/64, 11=v1/none) |
| $D0B2 | R/W | HW Enable + System 1MHz flags |
| $D0B3 | W | Enhanced Optimization (V2 only) |
| $D0B4 | W | Optimization Mode Flags |
| $D0B5 | R | JiffyDOS/CPU Speed Switch |
| $D0B6 | W | Bootmap Disable |
| $D0B7 | W | Bootmap Enable |
| $D0B8 | R/W | Software Speed Flag |
| $D0BC | R/W | DOS Extension Mode |
| $D0BE | W | DOS Extension Enable |
| $D0BF | W | DOS Extension Disable |

#### Authoritative READ semantics (VICE xscpu64 `scpu64_hardware_read`, validated 2026-05-29)

Cross-checked against VICE 3.10 `scpu64mem.c` AND captured live from xscpu64 via
`tools/vice_scpu_regprobe.py` (ground-truth oracle). **Every $D0Bx read ORs in
`(mem_reg_optim & 7)` as the low 3 bits** — i.e. the optimization-mode register's
low nibble bleeds through on *every* status read (this is why a bare probe sees
`$01` even on undecoded addresses like $D0B1/$D0B7; it is the optim value, not
open-bus noise). Detection software MUST mask to the documented high bits.

| Reg | VICE read value | High-bit meaning |
|-----|-----------------|------------------|
| $D0B0 | `0x40` (v2) / `0xC0` (v1) `\| optim&7` | Mode detect: $40 = v2/64 |
| $D0B2 | `hwenable?0x80 \| sys_1mhz?0x40 \| optim&7` | HW-enable + sys-1MHz |
| $D0B3 | (v2) `optim & 0xC0 \| optim&7` | Enhanced-optim readback |
| $D0B4 | `optim & 0xC0 \| optim&7` | Optimization-mode readback |
| $D0B5 | `sw_jiffy?0x80 \| sw_1mhz?0x40 \| optim&7` | Physical Jiffy + 1MHz switch |
| $D0B6 | `emulation?0x80 \| optim&7` | b7 = emulation (6502) mode |
| $D0B8 | `soft_1mhz?0x80 \| eff_1mhz?0x40 \| optim&7` | SW speed flag + effective speed |
| $D0BC | `dosext?0x80 \| ramlink?0x40 \| optim&7` | b7=DOS-ext, b6=RAMLink |
| $D07E/$D078 | `0xFF` | write-only → open bus |

**MiSTer conformance (build `97392a1f`, HW + VICE validated 2026-05-29):** all
**detection-critical** semantic bits match VICE exactly on silicon —
`$D0B0=$40` (v2/64), `$D0B2=$80` (hwenable after $D07E), `$D0B6=$80` (emulation),
`$D0BC=$00` (b7=0 ⇒ SuperCPU present, the canonical §8 Method-1 detect). We do
**not** OR `optim&7` into the low bits and do not drive the $D0B3/$D0B4 high
nibble or the $D0B5 jiffy bit — all confirmed to have **zero firmware/detection
consumers** (iter-5 EPROM scan: optimization regs are 9 writes / 0 reads), so the
divergence is benign. Probes: `tools/build_scpu_regprobe.py` +
`tools/vice_scpu_regprobe.py` (oracle), `tools/d0bx_full_hw_sweep.py` (silicon).

### $D200-$D3FF — SRAM in I/O Space

| Range | Function |
|-------|----------|
| $D200-$D2FF | System RAM (256 bytes, SuperCPU OS) |
| $D300-$D3FF | User RAM (256 bytes, user programs) |

Source: [SuperCPU Tutorial](http://supercpu.cbm8bit.com/scpu/scpu_1.html), [C64-Wiki](https://www.c64-wiki.com/wiki/SuperCPU)

## 4. Write Buffer (CacheWrite)

The SuperCPU does NOT have a traditional CPU cache. Instead, 128 KB SRAM mirrors
the entire bank $00-$01 address space. The "cache byte" is a **1-byte write buffer**:

1. CPU writes to mirrored address → stored in SRAM immediately (0 wait states)
2. Value latched into 1-byte write buffer
3. CPLD drains buffer to C64 motherboard DRAM during next free 1 MHz bus cycle
4. If another mirrored write occurs before drain → CPU stalls

This is the fundamental mechanism enabling 20 MHz execution while keeping VIC-II's
view of memory consistent. Performance depends on mirrored write frequency.

### Optimization Modes (WriteSmart)

Optimization controls WHICH bank $00 writes mirror to C64 DRAM. Less mirroring =
fewer 1 MHz stalls = faster execution.

| Mode | Register | Mirror Range | Use Case |
|------|----------|-------------|----------|
| No Optimization | $D077 | $0000-$FFFF | Default, max compat |
| BASIC | $D076 | $0400-$07FF | Text screen only |
| VIC Bank 1 | $D075 | $4000-$7FFF | Custom graphics |
| VIC Bank 2 | $D074 | $8000-$BFFF | GEOS graphics |

V2 enhanced optimization ($D0B3): additionally excludes ZP ($00-$FF) and stack
($100-$1FF) from mirroring, since VIC never reads these.

Source: [Underneath the Hood (Commodore Hacking #12)](http://mclauchlan.site.net.au/scott/C=Hacking/C-Hacking12/cmdcpu.html)

## 5. SuperRAM vs REU

These are **completely separate and independent** memory systems:

| Feature | REU (1700/1764/1750) | SuperRAM Card |
|---------|---------------------|---------------|
| Access method | DMA via $DF00-$DF0A | Direct CPU via 24-bit bus |
| Max size | 512 KB (16 MB emulated) | 1-16 MB (PS/2 SIMM) |
| Speed | 1 byte/cycle (~1 MB/s) | Full 20 MHz CPU speed |
| Code execution | No (must DMA to bank $00 first) | Yes (JML directly) |
| Bank switching | REU bank registers | None (linear 24-bit) |
| VIC-II access | No | No |
| DMA target | C64 motherboard RAM only | N/A (CPU addressed) |

**REU DMA cannot access SuperRAM.** REU DMA only reads/writes C64 motherboard DRAM
on the C64's expansion port bus. To get data from REU to SuperRAM, software must:
1. REU FETCH → C64 bank $00 RAM
2. CPU long store → SuperRAM bank

Source: [C64-Wiki: SuperRAM-Card](https://www.c64-wiki.com/wiki/SuperRAM-Card), [SuperCPU FAQ](http://supercpu.cbm8bit.com/faq.htm)

## 6. Speed Control

Three independent speed flags, priority hierarchy:

```
turbo_mode = !(sys_1mhz || soft_1mhz || (sw_1mhz && !hwenable))
```

| Flag | Set by | Clear by | Notes |
|------|--------|----------|-------|
| sys_1mhz | $D072 | $D073 | Hardware-level lock |
| soft_1mhz | $D07A | $D07B/$D079 | Software control |
| sw_1mhz | Physical switch | Physical switch | Override by hwenable |

At 1 MHz: full C64 timing compatibility including badline stalls.
At 20 MHz: CPU runs from SRAM, no badline stalls, I/O synced via write buffer.

**IEC auto-slowdown:** CPLD monitors CIA2 ($DD00-$DD03) writes and $DD00 reads.
When IEC bus activity detected, automatically drops to 1 MHz.

Source: [VICE scpu64mem.c](https://github.com/svn2github/vice-emu/blob/master/vice/src/scpu64/scpu64mem.c)

## 7. Doom for SuperCPU

### Loading Flow
1. `io.prg` (loader) runs in bank $00
2. Loader uses REU FETCH DMA ($DF00 registers) to copy chunks from REU to bank $00
3. Loader uses 65816 long stores (`STA [$dp],Y`) to scatter data to SuperRAM banks
4. Drops to 1 MHz ($D07A) during DMA, returns to turbo ($D07B) after
5. After loading: `JML $200000` to jump to game code in SuperRAM

### Runtime
- Game code executes entirely from SuperRAM via 24-bit addressing
- NO REU DMA at runtime — all data already in SuperRAM
- Cross-bank calls via JML/JSL to banks $20, $29-$2D, $80, $BD
- Math tables in banks $10-$19 via `STA [$dp],Y` indirect long
- Return mechanism: `JML ($00FC)` indirect through DP pointer

### doom.reu Format
- 16 MB REU image containing loader, game code, DOOM1.WAD
- Bank $20:0000 = doom.reu offset $200000 = game entry point
- WAD data extractable: `dd skip=4128768 count=4196020 if=doom.reu of=DOOM1.WAD bs=1`

Source: [DoomWiki: Doom (Commodore SuperCPU)](https://doomwiki.org/wiki/Doom_(Commodore_SuperCPU)), [AmiDog SuperCPU Wiki](https://scpu.amidog.se/doku.php?id=scpu:doom)

## 8. Software Detection

**Method 1 (register):** Read $D0BC bit 7. If 0 → SuperCPU present.

**Method 2 (CPU ID):** In decimal mode, `LDA #$99; CLC; ADC #$01` leaves N flag
clear on 65816 but set on 6510. Detects 65816 CPU regardless of SuperCPU hardware.

## 9. Differences: Real Hardware vs MiSTer Implementation

| Feature | Real SuperCPU | MiSTer Implementation |
|---------|--------------|----------------------|
| Fast memory | 128 KB SRAM (banks $00-$01) | 64 KB BRAM + 8 KB cache |
| Write buffer | 1-byte CacheWrite | io_slowdown signal (proven unnecessary) |
| SuperRAM | PS/2 SIMM (1-16 MB) | SDRAM banks $01-$EF |
| ROM | 64-512 KB EPROM ($F0-$FF) | ROM stub (RTI at $FF00) |
| CPLD | Altera EPM7128/7160 | Integrated in VHDL |
| Speed switching | HW flags + physical switch | Software registers only |
| $D078 | SIMM configuration | Cache flush (repurposed) |
| Optimization | WriteSmart (mirror control) | Not implemented (cache excludes I/O) |

### Key architectural differences to address:
1. **Bank $01**: Real hardware has full 64 KB SRAM. MiSTer may not map bank $01 correctly.
2. **ROM banks $F0-$FF**: Real hardware has EPROM with SuperCPU OS. MiSTer has minimal ROM stub.
3. **$D078 repurposed**: Real hardware uses $D078 for SIMM config. MiSTer uses it for cache flush.
4. **Optimization modes**: Real hardware controls which addresses mirror to C64 DRAM. MiSTer's cache
   already excludes I/O, making optimization partially implicit.
5. **SuperRAM starts at bank $02**: Real hardware maps bank $01 to SRAM, not SuperRAM.
   MiSTer maps banks $01-$EF to SDRAM (SuperRAM), which is wrong for bank $01.

## Consolidated Sources

- [C64-Wiki: SuperCPU](https://www.c64-wiki.com/wiki/SuperCPU)
- [C64-Wiki: SuperRAM-Card](https://www.c64-wiki.com/wiki/SuperRAM-Card)
- [SuperCPU FAQ (cbm8bit.com)](http://supercpu.cbm8bit.com/faq.htm)
- [SuperCPU Tutorial Index](http://supercpu.cbm8bit.com/scpu/index.html)
- [Underneath the Hood (Commodore Hacking #12)](http://mclauchlan.site.net.au/scott/C=Hacking/C-Hacking12/cmdcpu.html)
- [Badlines on the SuperCPU](http://the-dreams.de/articles/scpu-badlines.txt)
- [VICE scpu64 source](https://github.com/svn2github/vice-emu/tree/master/vice/src/scpu64)
- [WDC W65C816S Datasheet](https://www.westerndesigncenter.com/wdc/documentation/w65c816s.pdf)
- [DoomWiki: Doom SuperCPU](https://doomwiki.org/wiki/Doom_(Commodore_SuperCPU))
- [AmiDog SuperCPU Wiki](https://scpu.amidog.se/doku.php?id=scpu:doom)
- [CMD SuperCPU 128 V2 User's Guide (archive.org)](https://archive.org/details/CMD_SuperCPU_128_V2_Users_Guide)
