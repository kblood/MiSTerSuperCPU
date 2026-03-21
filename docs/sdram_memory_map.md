# SDRAM Memory Map — Complete Analysis

## 25-bit Address Space (32MB total)

```
Address Range           Size    Used By          Source
────────────────────────────────────────────────────────────────
0x0000000 - 0x000FFFF   64KB    C64 RAM          cart_addr (bank $00)
0x0100000 - 0x01FFFFF   1MB     CRT ROMs         ioctl → CRT_ADDR
0x0200000 - 0x02FFFFF   1MB     TAP images       ioctl → TAP_ADDR
0x0300000 - 0x0FFFFFF   13MB    (UNUSED)
0x1000000 - 0x1FFFFFF   16MB    REU + SuperRAM   ioctl → REU_ADDR
                                                  reu.v → {1, addr_ram[23:0]}
                                                  scpu → REU_ADDR + {bank, addr}
```

## How Each Region is Accessed

### Bank $00 C64 RAM (0x0000000 - 0x000FFFF)
- **CPU reads**: via cart_addr (buslogic resolves RAM/ROM/cartridge)
- **CPU writes**: via cart_addr → SDRAM write
- **VIC reads**: via systemAddr (separate SDRAM access during VIC slots)
- **Cache fills**: from cpuDi_raw (buslogic output) on enableCpu
- **BRAM fills**: from cpuDi_raw or cpuDo_pre on enableCpu/cache_hit_d1

### CRT ROMs (0x0100000 - 0x01FFFFF)
- **Loading**: ioctl_load_addr starts at CRT_ADDR, increments per byte
- **Reading**: cart_addr from cartridge.v (maps ROM banks)
- **No conflict** with SuperRAM (different SDRAM region)

### TAP Images (0x0200000 - 0x02FFFFF)
- **Loading**: ioctl_load_addr starts at TAP_ADDR
- **Reading**: io_cycle_addr = tap_play_addr + TAP_ADDR
- **No conflict** with SuperRAM

### REU Memory (0x1000000 - 0x1FFFFFF)
- **Loading (.reu file)**: ioctl_load_addr starts at REU_ADDR (0x1000000)
  - Byte 0 of .reu file → SDRAM 0x1000000
  - Byte N → SDRAM 0x1000000 + N
- **REU DMA access**: reu.v generates ram_addr = {1'b1, addr_ram[23:0]}
  - Register $DF04 = addr_ram[7:0], $DF05 = addr_ram[15:8], $DF06 = addr_ram[23:16]
  - When addr_ram = 0x000000 → SDRAM 0x1000000
  - When addr_ram = 0x020000 → SDRAM 0x1020000
  - Masked by addr_mask (cfg=3/16MB: 0xFFFFFF, all 24 bits)

### SuperRAM via 65816 (0x1000000 - 0x1FFFFFF)
- **CPU access**: scpu_superram_addr = REU_ADDR + {1'b0, bank[7:0], addr[15:0]}
  - Bank $01 addr $0000 → 0x1000000 + 0x010000 = 0x1010000
  - Bank $02 addr $0000 → 0x1000000 + 0x020000 = 0x1020000
  - Bank $FF addr $FFFF → 0x1000000 + 0xFF_FFFF = 0x1FFFFFF

## REU ↔ SuperRAM Alignment Check

The .reu file is loaded starting at REU_ADDR (0x1000000). The REU DMA uses
addr_ram (24-bit) with bit[24] forced to 1, giving SDRAM addresses
0x1000000 + addr_ram.

SuperRAM uses REU_ADDR + {bank, addr} = 0x1000000 + (bank << 16) + addr.

### Mapping comparison:

| Access | addr_ram / bank:addr | SDRAM Address | .reu file offset |
|--------|---------------------|---------------|-----------------|
| REU DMA addr_ram=$000000 | $00:$0000 | 0x1000000 | 0x000000 |
| REU DMA addr_ram=$020000 | $02:$0000 | 0x1020000 | 0x020000 |
| SCPU bank $01 addr $0000 | $01:$0000 | 0x1010000 | 0x010000 |
| SCPU bank $02 addr $0000 | $02:$0000 | 0x1020000 | 0x020000 |

**REU DMA and SuperCPU access the SAME SDRAM addresses for the same
bank:addr pair.** ✓ No misalignment.

### doom.reu file layout:

| File Offset | Content | REU addr_ram | SCPU bank:addr | SDRAM |
|------------|---------|-------------|----------------|-------|
| 0x000000 | Zeros (SRAM shadow bank $00) | $000000 | bank $00 (C64 RAM, not SuperRAM) | 0x1000000 |
| 0x010000 | Zeros (SRAM shadow bank $01) | $010000 | bank $01:$0000 | 0x1010000 |
| 0x020000 | Game data starts | $020000 | bank $02:$0000 | 0x1020000 |
| 0x080000 | "SCPU" header | $080000 | bank $08:$0000 | 0x1080000 |
| 0x3FC4DC | DOOM1.WAD embedded | $3FC4DC | bank $3F:$C4DC | 0x13FC4DC |

## Potential Issues Found

### Issue 1: Bank $00 SuperRAM Overlap
SuperRAM bank $01 maps to SDRAM 0x1010000 (REU offset $010000). The .reu
file has zeros at this offset (SRAM shadow). Bank $00 is excluded from
SuperRAM (`supercpu_bank != 8'h00` guard). This is correct — bank $00
goes through cart_addr (C64 RAM at 0x0000000).

**However**: if the Doom game code accesses bank $00 via long addressing
(e.g., `LDA $000400`), the `supercpu_bank != 8'h00` guard routes it to
`cart_addr` — which is the C64's bank $00 RAM at 0x0000000, NOT the REU
region at 0x1000000. This is CORRECT behavior (bank $00 = C64 RAM).

### Issue 2: REU DMA vs SuperCPU Conflict
REU DMA uses ext_cycle slots. SuperCPU uses non-ext-cycle slots. They
share the SDRAM via the address mux:
```verilog
.addr(io_cycle ? ... : ext_cycle ? reu_ram_addr : scpu_sdram_addr)
```
ext_cycle has priority over scpu_sdram_addr. No conflict — they use
different time slots. ✓

### Issue 3: Doom Loader's JML Target
The loader does DMA transfers, then `JML [$04FC]`. Address $04FC is in
bank $00 C64 RAM (0x0000000 region). The DMA copies data from REU to
C64 RAM, which should populate $04FC with the game entry point address.

**The entry point at $04FC is a 3-byte long address** (bank + addr16).
If the DMA correctly transferred the right data, $04FC-$04FE should
contain a valid 24-bit address pointing into SuperRAM (e.g., $020000+).

**Potential problem**: the loader's DMA source address might reference
data in the first 128KB of the .reu file (bank $00/$01 shadow area),
which is all zeros. If the entry point data is at REU offset $000000-
$01FFFF, the JML target would be $000000 — which jumps to C64 zeropage
and crashes.

### Issue 4: The Loader's DMA Addresses
From the disassembly, the loader reads its DMA parameters from a table
at $07B5-$07BA (which was copied from the loader's own code). These
addresses determine what REU regions get transferred to C64 RAM.

If the table contains wrong offsets for our REU mapping, the DMA would
transfer wrong data (or zeros from the shadow area).
