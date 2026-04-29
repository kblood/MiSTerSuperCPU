# Session Passover — 2026-03-28

## What Was Done This Session

### 1. SDRAM Address Timing Fix (COMMITTED TO WORKING TREE, NOT GIT)
**File changed**: `C64_MiSTer/c64.sv` line ~1165

**Change**: Replaced `c64_addr` with `dbg_cpu_addr` in SuperRAM address computation:
```verilog
// BEFORE:
wire [24:0] scpu_superram_addr = REU_ADDR + {1'b0, supercpu_bank, c64_addr};
// AFTER:
wire [24:0] scpu_superram_addr = {1'b1, supercpu_bank, dbg_cpu_addr};
```

**Why**: `c64_addr` (= `systemAddr`) is a combinational bus mux between cpuAddr and vicAddr that transitions every cycle boundary. This created a long combinational path through fpga64_sid_iec → cartridge.v → SDRAM controller, violating the clk32→clk64 timing constraint. `dbg_cpu_addr` (= `cpuAddr_pre`) is a direct CPU register output with no bus mux — path is just tCQ + wiring.

Also replaced addition with concatenation: `REU_ADDR + {1'b0, bank, addr}` = `{1'b1, bank, addr}` since REU_ADDR = 25'h1000000 (just bit 24).

**Timing results**:
- clk64 worst slack: -23.976 → -15.146 ns (+8.8ns)
- clk32 worst slack: -13.715 → -6.736 ns (+7.0ns)
- clk32 TNS: -11689 → -767 (93% reduction)

**Hardware verification**:
- STA/LDA round-trip bank $02:$0100 = $22 ✓
- STA/LDA round-trip bank $02:$0200 = $55 ✓ (no aliasing)
- STA/LDA round-trip bank $02:$0000 = $AB, $02:$0001 = $CD ✓

### 2. Diagnostic Registers Added (ALSO IN WORKING TREE)
Added to c64.sv around line 1157, exposed via REU register mux at $DF0D-$DF15:

| Register | Content |
|----------|---------|
| $DF0D | Last ioctl write addr [7:0] |
| $DF0E | Last ioctl write addr [15:8] |
| $DF0F | Last ioctl write addr [23:16] |
| $DF10 | Last ioctl write addr [24] |
| $DF11 | ioctl_data captured at reu_ioctl_cnt == $020000 |
| $DF12-$DF15 | ioctl_load_addr captured at reu_ioctl_cnt == $020000 |

**Diagnostic results after loading test.reu via OSD**:
- Byte count: 262144 ✓, Index: 0x81 ✓
- Last write addr: 25'h103FFFF ✓ (correct: REU_ADDR + 262143)
- Addr at count $020000: 25'h1020000 ✓ (correct)
- **DATA at count $020000: 0** ✗ (expected $DE from test.reu)

## Current Mystery: ioctl Data is 0

The SDRAM address chain is proven correct (ioctl_load_addr reaches the right values). But `ioctl_data` captured at file offset $020000 is 0, not the expected $DE.

**test.reu file**: verified correct on MiSTer filesystem (`dd | xxd` shows $DE $AD at offset $020000). File is 262144 bytes.

**test_de.reu**: also uploaded — 262144 bytes ALL set to $DE. User was asked to load this via OSD but session ended before result.

### Possible causes for ioctl_data being 0:
1. **reu_ioctl_cnt doesn't match ioctl_addr**: The counter increments on every `ioctl_wr && load_reu`, but maybe `ioctl_wr` fires multiple times per byte, or the counter doesn't track file offset correctly.
2. **ioctl_data timing**: `ioctl_data` might not be valid at the exact clk_sys edge when `ioctl_wr` fires. Need to check if the diagnostic captures at the right moment.
3. **The data IS being written correctly but the diagnostic capture is wrong**: The `reu_ioctl_20000_data` captures `ioctl_data` when `reu_ioctl_cnt == $020000`, but maybe the count doesn't correspond to the right file offset due to initialization or edge effects.

### Next Steps
1. **Load test_de.reu** (all $DE bytes) via OSD, then:
   - Check $DF11 — if it shows 222 ($DE), ioctl_data IS correct and the count alignment was wrong
   - Do LDA long from any SuperRAM address — if it returns 222, the FULL ioctl→SDRAM→CPU path works
   - If it still returns 0, the ioctl SDRAM writes aren't reaching SDRAM
2. **If ioctl data still 0**: Add diagnostic to capture `ioctl_data` at count == 0 (first byte) and `ioctl_addr` at same point. Verify alignment between ioctl_addr and reu_ioctl_cnt.
3. **If ioctl data correct but CPU reads 0**: Something in the SDRAM write path (io_cycle CE/WE timing, or SDRAM controller state machine busy) is preventing writes from reaching physical SDRAM.

## Test Programs

### STA/LDA Round-Trip (type in BASIC, SYS 49408)
Writes $AB to $02:$0000 and $CD to $02:$0001, reads back:
```
10 FOR I=0 TO 24:READ A:POKE 49408+I,A:NEXT
20 DATA 24,251,169,171,143,0,0,2,175,0,0,2,141,0,192
30 DATA 169,205,143,1,0,2,175,1,0,2,141,1,192,56,251,96
40 SYS 49408:PRINT PEEK(49152);PEEK(49153)
```
Expected: `171 205` ($AB $CD)

### REU Read Test (type in BASIC after loading .reu)
Reads $02:$0000 and $02:$0001:
```
10 FOR I=0 TO 18:READ A:POKE 49408+I,A:NEXT
20 DATA 24,251,175,0,0,2,141,0,192
30 DATA 175,1,0,2,141,1,192,56,251,96
40 SYS 49408:PRINT PEEK(49152);PEEK(49153)
```
Expected after test.reu: `222 173` ($DE $AD)
Expected after test_de.reu: `222 222`

### Diagnostic Register Read (type in BASIC after loading .reu)
```
PRINT PEEK(57097);PEEK(57098);PEEK(57099);PEEK(57100)
PRINT PEEK(57101);PEEK(57102);PEEK(57103);PEEK(57104)
PRINT PEEK(57105);PEEK(57106);PEEK(57107);PEEK(57108);PEEK(57109)
```

## Test Files on MiSTer
- `/media/fat/games/C64/test.reu` — 256KB, $DE $AD at offset $020000, $CA $FE at $010000
- `/media/fat/games/C64/test_de.reu` — 256KB, all bytes = $DE
- `/tmp/mtype.py` — virtual keyboard tool
- Core: `/media/fat/_Test/C64.rbf` (diagnostic build with $DF0D-$DF15)

## Key Architecture Facts
- `dbg_cpu_addr` = `cpuAddr_pre` = direct CPU address (no bus mux), concurrent assignment in fpga64_sid_iec.vhd
- `c64_addr` = `ramAddr` = systemAddr muxed between cpuAddr/vicAddr (combinational, slow path)
- `supercpu_bank` = addr_hi_816 = CPU bank byte (combinational from CPU registers)
- `cpu_has_bus` = cpuHasBus = registered signal from cycle state machine
- `ioctl_wait <= ioctl_req_wr` — flow control prevents HPS from overrunning io_cycle
- SDRAM pipeline: 5 clk64 cycles from CE to STATE_READ
- Bank $00: 2-stage enableCpu (CPUC+2), SuperRAM: 3-stage (CPUC+3)
- REU_ADDR = 25'h1000000 (bit 24 set, 16MB offset in 32MB SDRAM)
- io_cycle_addr/ce/we set at io_cycle falling edge, consumed at next io_cycle HIGH
- OSD F12 cannot be triggered via mtype.py virtual keyboard — user must press physically
- MGL reload breaks native mode (separate known bug)
- mbc load_rom sends as PRG (wrong ioctl_index for REU)
