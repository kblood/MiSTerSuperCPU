# C64 MiSTer SuperCPU — Architecture & Signal Flow

This document captures how all the RTL files fit together. It is intended as a
living reference for anyone continuing this project.

---

## 1. File Map

```
C64_MiSTer/
├── c64.sv                        ← MiSTer top-level (OSD, HPS, PLL, video output)
├── rtl/
│   ├── fpga64_sid_iec.vhd        ← C64 system top: bus master, clock gating, all peripherals
│   ├── fpga64_buslogic.vhd       ← PLA / chip-select decode, data-to-CPU mux
│   ├── cpu_6510.vhd              ← T65 wrapper + 6510 I/O port ($0000/$0001)
│   ├── cpu_65c816.vhd            ← P65C816 wrapper + 6510 I/O port emulation
│   ├── 65C816/
│   │   ├── P65C816.vhd           ← Core 65C816 state machine (from SNES MiSTer)
│   │   ├── MCode.vhd             ← Registered microcode ROM (2048 entries × 16 fields)
│   │   ├── AddrGen.vhd           ← Address arithmetic (PC, AA, SP, DX, branch offsets)
│   │   ├── ALU.vhd               ← 8/16-bit ALU with BCD support
│   │   ├── BCDAdder.vhd          ← BCD carry logic
│   │   ├── AddSubBCD.vhd         ← BCD add/subtract
│   │   └── P65816_pkg.vhd        ← MicroInst_r / MCode_r record types
│   ├── mos6526.v                 ← CIA1 / CIA2 (Verilog)
│   ├── video_vicII_656x.vhd      ← VIC-II video chip
│   ├── fpga64_keyboard.vhd       ← PS/2 → C64 keyboard matrix simulator
│   ├── sid/                      ← SID sound chip
│   ├── cartridge.v               ← Expansion/cartridge port logic
│   └── debug_overlay.sv          ← On-screen CPU state display (Phase 2 debug aid)
└── sys/                          ← MiSTer framework (READ ONLY)
```

---

## 2. Top-Level Hierarchy

```
c64.sv  (MiSTer emu module)
  └─ fpga64_sid_iec  (C64 system)
       ├─ fpga64_buslogic        (PLA / address decode)
       ├─ cpu_6510               (T65 + 6510 I/O port)  — active when supercpu_en=0
       ├─ cpu_65c816             (P65C816 + 6510 I/O)   — active when supercpu_en=1
       │    └─ P65C816
       │         ├─ MCode
       │         ├─ AddrGen
       │         └─ ALU (+ BCD helpers)
       ├─ mos6526  (CIA1)
       ├─ mos6526  (CIA2)
       ├─ video_vicII_656x
       ├─ fpga64_keyboard
       ├─ SID × 2
       └─ debug_overlay          (Phase 2 – off by default)
```

---

## 3. Master Clock & Bus Cycle Timing

All logic runs from a single **32 MHz clock** (`clk32`), derived from 50 MHz via PLL.

One 1 MHz C64 cycle = **32 clk32 periods**.  
The `sysCycle` counter counts 0–31 and repeats.

| sysCycle value | Name       | Who acts |
|----------------|------------|----------|
| 0–3            | CYCLE_EXT0–3 | Turbo/DMA ext slot |
| 4–7            | CYCLE_DMA0–3 | DMA controller |
| 8–11           | CYCLE_VIC0–3 | VIC-II bus steal |
| 12–15          | CYCLE_EXT4–7 | More ext/turbo |
| 16–27          | CYCLE_CPU0–CPUB | CPU RAM cycles |
| 28             | CYCLE_CPUC | `enableCia_n` fires — CIA captures wr/rd |
| 29             | CYCLE_CPUD | — |
| 30             | CYCLE_CPUE | `enableCpu_6510` / `enableCpu_816` fires — CPU state advances |
| 31             | CYCLE_CPUF | `enableCia_p` fires — CIA updates pa_out/pb_out; `enableSid` fires |

**Key timing rule:**  
The CPU advances its state machine at **CYCLE_CPUE**.  
CIA1 samples bus signals (`wr`, `rw`) at **CYCLE_CPUD** (one clock after CYCLE_CPUC when phi2_n is high).  
CIA1 updates its output ports (`pa_out`, `pb_out`) at **CYCLE_CPUF**.

Because CYCLE_CPUE is the *previous period's* last clock, the CPU bus outputs
(address, data, WE) have been stable for ~24 clocks by the time CYCLE_CPUC
arrives — plenty of setup time for the CIA.

---

## 4. Dual-CPU Architecture (Phase 2)

Both CPUs are always instantiated. Only one is active at a time.

```vhdl
-- Enable gating:
enableCpu_6510 <= (enableCpu and not dma_active) when supercpu_en = '0' else '0';
enableCpu_816  <= (enableCpu and not dma_active) when supercpu_en = '1' else '0';

-- Reset gating:
cpu_6510: reset => reset or supercpu_en      -- held in reset when 65C816 active
cpu_816:  reset => reset or not supercpu_en  -- held in reset when 6510 active

-- Output MUX:
cpuAddr <= cpuAddr_816  when supercpu_en='1' else cpuAddr_6510;
cpuDo   <= cpuDo_816    when supercpu_en='1' else cpuDo_6510;
cpuWe   <= cpuWe_816    when supercpu_en='1' else cpuWe_6510;
cpuIO   <= cpuIO_816    when supercpu_en='1' else cpuIO_6510;
```

`supercpu_en` comes from OSD status bit [82] in `c64.sv`.

**Important:** `cpuAddr` is always 16 bits. The 65C816's bank byte (`addr_hi_816`) is
available separately for Phase 4 (SuperRAM) but is not currently used for memory decode.

---

## 5. T65 (cpu_6510) Output Model

T65 has **registered** outputs. `A`, `DO`, `R_W_n` are updated at the rising edge
when the T65's internal enable fires. They hold their value until the next enable
pulse. This means they are always stable by CYCLE_CPUC.

The 6510 I/O port at `$0000/$0001` is decoded inside `cpu_6510.vhd` as
`cpuAddr(15 downto 1) = 15 zeros`. The output is `doIO` (the 8-bit I/O value
which controls memory banking bits LORAM/HIRAM/CHAREN plus cassette/motor).

---

## 6. P65C816 (cpu_65c816) Output Model

P65C816 has **combinational** outputs (`ADDR_BUS`, `D_OUT`, `WE`) — they are
combinational functions of the registered `MC` (microcode register, from `MCode.vhd`).

`MCode.vhd` is **registered**. `MI` (the current microcode word) updates at
`rising_edge(CLK)` when `EN='1'`:
```vhdl
if STATE = "0000" then
    MI <= fetch_microcode;   -- opcode fetch cycle
else
    MI <= M_TAB[IR * 8 + (STATE-1)];
end if;
```

`EN = RDY_IN AND CE AND NOT WAIExec AND NOT STPExec` (line 83 of P65C816.vhd).
`CE = enableCpu_816` (fires at CYCLE_CPUE).
`RDY_IN = baLoc` (VIC BA signal — goes low during badlines).

Since `MI` only changes on `EN='1'` pulses, and the CIA samples at CYCLE_CPUC
(~24 clocks after the last CYCLE_CPUE), the combinational `ADDR_BUS`/`WE`
are stable well before the CIA sample point.

**WE polarity:**
- P65C816 `WE` output: `'0'` = write (active low R/W#), `'1'` = read
- `cpu_65c816.vhd` inverts: `we <= not localWe` → system-level `cpuWe='1'` = write ✓

---

## 7. Memory Decode (fpga64_buslogic)

`fpga64_buslogic` acts as the C64 PLA. It takes:
- `cpuAddr(15:0)` — 16-bit address from active CPU
- `cpuWe` — write enable
- `cpuHasBus` — CPU owns bus (not VIC steal)
- `bankSwitch = cpuIO(2:0)` — LORAM / HIRAM / CHAREN bits
- `game`, `exrom` — cartridge signals
- `bios` — ROM source selection

It outputs:
- `systemAddr` — address to SDRAM
- `systemWe` — write enable to SDRAM
- `dataToCpu` (= `cpuDi_raw`) — data mux for CPU reads
- `cs_vic`, `cs_cia1`, `cs_cia2`, `cs_sid`, `cs_ram`, `cs_color`, etc.

**cpuDi** (final data to CPU) adds the SuperCPU ID overlay on top of `cpuDi_raw`:
```
cpuDi <= $C9 when (supercpu_en='1' AND cs_vic='1' AND addr[11:0]=$0BC) -- PEEK(53436)=$C9
cpuDi <= $B1 when (supercpu_en='1' AND cs_vic='1' AND addr[11:0]=$07E) -- firmware version
cpuDi <= cpuDi_raw otherwise
```

Both CPUs receive the same `cpuDi` (the data bus is shared, not split per CPU).

---

## 8. 6510 I/O Port ($0000 / $0001)

Both `cpu_6510.vhd` and `cpu_65c816.vhd` implement the 6510 I/O port with
**identical logic**:

```
accessIO = '1' when address(15:1) = all zeros  (i.e., addr=$0000 or $0001)
```

For P65C816: `accessIO = '1' when localA(23:1) = all zeros` (24-bit check).

On write: captures to `ioDir` (at $0000) or `ioData` (at $0001).
On read: returns `ioDir` or `currentIO`.

```
currentIO = (ioData AND ioDir) OR (diIO AND NOT ioDir)
```

At reset: `ioDir=$00`, `ioData=$FF`, `currentIO="00111111"` = LORAM=1,HIRAM=1,CHAREN=1
(standard ROM banking: KERNAL visible, BASIC visible, I/O at $D000–$DFFF).

After KERNAL IOINIT: `ioDir=$2F`, `ioData=$E7` → same effective banking. ✓

`diIO` feeds back the external pin state (cassette sense on bit 4, forced '1' on bits 2:0).
This is the same for both CPUs.

---

## 9. CIA1 Keyboard Matrix Path

```
CPU writes $FF → $DC00
  → cpuWe='1', cpuAddr=$DC00, cpuDo=$FF
  → cs_cia1='1' (from buslogic)
  → mos6526 CIA1: wr fires at CYCLE_CPUD (phi2_n=enableCia_n was '1' at CYCLE_CPUC)
  → pra <= $FF (stored Port A output register)
  → At CYCLE_CPUF: pa_out <= pra | ~ddra = $FF (all columns deselected)
  
fpga64_keyboard (combinational):
  → pai = cia1_pao = pa_out = $FF (all columns deselected)
  → pbo = $FF (no row active because columns deselected)
  → cia1_pbi = pbo = $FF

CPU reads $DC01 (at next CYCLE_CPUD, ~32 clocks later):
  → pb_in = cia1_pbi = $FF (no key pressed)
  → CIA1 rd fires → db_out = pb_in = $FF → cpuDi = $FF ✓
```

The keyboard matrix (`fpga64_keyboard`) is **combinational**: `pbo` responds
immediately to `pai` changes. With `pa_out` stable for ~32 clocks before the
next CIA read, there is no settling-time issue.

**Key signals:**
| Signal | Direction | Meaning |
|--------|-----------|---------|
| `cia1_pao` | CIA→keyboard | Column drive (PA output from CIA1) |
| `cia1_pai` | keyboard→CIA | Column read-back (PA input to CIA1) |
| `cia1_pbo` | CIA→keyboard | Row drive (PB output, joystick/timer overlap) |
| `cia1_pbi` | keyboard→CIA | Row data (PB input = what CPU reads at $DC01) |

Note the naming: `cia1_pao` is the **output** of CIA1's PA register, fed as **input** (`pai`) to the keyboard module. The wiring is intentionally "crossed" to match real hardware topology.

---

## 10. P65C816 Microcode Architecture

### Microcode table (MCode.vhd)
- 2048 entries (`256 opcodes × 8 states`)
- Each entry is a `MicroInst_r` record with 16 fields
- `MI` is **registered** — updates on every `EN='1'` clock
- Index = `IR(7:0) & STATE(2:0)` where `STATE-1` is used (pipeline: MI holds next step)
- When `STATE=0` (opcode fetch): MI always loads `fetch_mc` (hardcoded)

### Key microcode fields
| Field | Bits | Purpose |
|-------|------|---------|
| `stateCtrl` | 3 | How STATE advances (straight, skip, branch, EF-conditional) |
| `addrBus` | 4 | Which address to put on ADDR_BUS (PC, SP, AA, vector, etc.) |
| `addrInc` | 2 | Address increment (+0 or +1) |
| `outBus` | 3 | What to put on D_OUT: `000`=none(read), `001`=P, `010`=PC, `100`=PBR, etc. |
| `byteSel` | 2 | High/low byte selection for 16-bit operations |
| `loadSP` | 3 | Stack pointer operation (++, --, TXS, etc.) |
| `loadPC` | 3 | PC load operation |
| `va` | 2 | VPA/VDA: `va[0]=VPA`, `va[1]=VDA`; `"00"`=internal, `"01"`=prog fetch, `"10"`=data |

### WE output
```vhdl
WE <= '1';  -- default: read
if MC.OUT_BUS /= "000" and IsResetInterrupt = '0' then
    WE <= '0';  -- write when output bus active (and not in reset)
end if;
```

### State flow for BRK / IRQ (emulation mode, EF='1')
```
STATE=0: Opcode fetch (PC++ or dummy read)
  stateCtrl="111" + EF='1' + IR≠$40 → NextState = STATE+2 = 2 (SKIPS STATE=1 = PBR push)
STATE=2: PCH → [SP--]    (write PCH to stack at $01SP)
STATE=3: PCL → [SP--]    (write PCL to stack)
STATE=4: P   → [SP--]    (write P to stack, with B flag logic)
STATE=5: Fetch vector low  ($FFFE for IRQ/BRK, $FFFA for NMI)
STATE=6: Fetch vector high + load PC
→ Done (7 cycles total, matching 6502)
```

In **native mode** (EF='0'): STATE=1 (PBR push) is NOT skipped → 8 cycles.

### RTI (emulation mode, EF='1')
```
STATE=0: SP++
STATE=1: [SP]→P, SP++
STATE=2: [SP]→DR, SP++
STATE=3: [SP]:DR→PC
  stateCtrl="111" + EF='1' + IR=$40 → NextState=0 (DONE — skips PBR pull)
```
RTI in emulation mode pulls 3 bytes (P, PCL, PCH). ✓ Matches 6502 RTI.

---

## 11. VPA / VDA Signals

P65C816 exports `VPA` (Valid Program Address) and `VDA` (Valid Data Address):
- `VDA = MC.VA(1)`, `VPA = MC.VA(0)`
- `"00"` = internal cycle (CPU doing arithmetic, address bus invalid)
- `"01"` = program fetch (instruction bytes)
- `"10"` = data access (read/write memory)

**Current status:** VPA and VDA are connected to ports in `cpu_65c816.vhd` but
are **not used** anywhere in `fpga64_sid_iec.vhd` for gating. The C64 core treats
every clock cycle as a valid bus access. This is safe because the C64's PLA
decode is purely address-based; "spurious" reads from KERNAL ROM on internal cycles
are harmless (no side effects from ROM reads).

If Phase 4 SuperRAM is added, VDA gating may become important for correct SDRAM
access scheduling.

---

## 12. Stack Pointer Constraints (Emulation Mode)

`ADDR_BUS` for stack accesses uses case `"1000" | "1100"`:
```vhdl
when "1000" | "1100" =>
    if EF = '0' or MC.ADDR_BUS(2) = '0' then
        ADDR_BUS <= x"00" & SP;          -- native: full 16-bit SP
    else
        ADDR_BUS <= x"00" & x"01" & SP(7 downto 0);  -- emulation: $01xx
    end if;
```

`"1100"` (ADDR_BUS bit 2 = 1): emulation mode forces stack to page 1 ($0100–$01FF). ✓
`"1000"` (ADDR_BUS bit 2 = 0): always uses full SP regardless of EF (used by COP,
JSR indirect — but in emulation mode SP high byte is forced to $01 by SP init anyway).

SP resets to `$0100`. In emulation mode, `LOAD_SP` cases `"001"`, `"010"`, `"011"`,
`"100"`, `"101"` all enforce `SP(15:8) <= x"01"` when `EF='1'`. So SP can never
escape page 1 in emulation mode. ✓

---

## 13. SuperCPU ID Register Overlay

Two reads are intercepted in `fpga64_sid_iec.vhd` (lines 545–547):
- `PEEK(53436)` = `$D0BC` → returns `$C9` (201) = "SuperCPU present" identifier
- `PEEK(53374)` = `$D07E` → returns `$B1` (177) = firmware version 1.x

Both fall in the VIC-II mirror space (`cs_vic='1'`). These are standard SuperCPU
detection addresses used by SuperCPU-aware software (e.g., SCPU kernal, speed demos).

**Verified working on hardware:** `PRINT PEEK(53436)` returns 201 in 65C816 mode. ✓

---

## 14. Debug Overlay (Phase 2)

`debug_overlay.sv` renders CPU state in the top video border area.

Enable via OSD: **Debug Overlay → On** (status bit [83]).

**Row 1 displays:** `A:XXXX  D:XX  W:X  B:XX`  
**Row 2 displays:** `S:XXXX  P:XX  I:XX  E:X`

| Field | Signal | Source |
|-------|--------|--------|
| A | cpuAddr (latched on enableCpu_816) | Bus address |
| D | cpuDo | CPU data output |
| W | cpuWe | Write enable |
| B | supercpu_bank | Bank byte (addr_hi_816) |
| S | dbg_cpu_sp | SP from P65C816 |
| P | dbg_cpu_p | P register (low 8 bits) |
| I | dbg_cpu_ir | IR (current opcode) |
| E | supercpu_emul | Emulation mode flag (EF_OUT from P65C816) |

**Observed values during BASIC idle:**  
`A:E5D1 D:00 W:0 B:00 / S:01F3 P:32 I:85 E:1`  
→ CPU at $E5D1 = `STA $0292` inside BASIN keyboard wait loop. Stack, flags, mode all normal.

---

## 15. Known Issues / Open Investigation

### '@' Scrolling Rows in 65C816 Mode

**Symptom:** 4–5 rows of '@' characters scroll upward continuously at BASIC READY prompt,
only when SuperCPU (65C816) is active. T65 mode is clean. BASIC is fully functional.
Games load and run correctly (scrolling shows game content, not a bug).

**Analysis so far (all inconclusive):**
- Bus timing: CIA samples at CYCLE_CPUD; P65C816 outputs stable 24 clocks earlier ✓
- I/O port ($0000/$0001): identical logic in both wrappers ✓
- IRQ stack: correct 3-byte push in emulation mode (PBR push skipped) ✓
- RTI: correct 3-byte pull in emulation mode ✓
- VIC-II timing: unaffected by CPU choice ✓
- SuperCPU ID registers: verified working ($D0BC=$C9) ✓
- All KERNAL $FB bytes confirmed as operand bytes (not XCE) ✓
- EF=1 consistent in debug overlay (no mode switching) ✓

**Most likely cause:** Phantom '@' (PETSCII $40) inserted into keyboard buffer
($0277–$0286, count at $C6) by CIA1 60Hz IRQ keyboard scan. The scan detects
'@' key pressed when it shouldn't.

**Unresolved:** WHY the keyboard scan returns wrong data in 65C816 mode vs T65 mode.

**Critical diagnostic tests needed (run in BASIC in 65C816 mode):**
```
POKE 56333, 127    → disable all CIA1 IRQs; if '@' stops, CIA1 IRQ confirmed
PRINT PEEK(198)    → keyboard buffer count; should be 0 at idle
PRINT PEEK(56321)  → CIA1 Port B direct read; should be 255 ($FF) with no key pressed
```

---

## 16. Phase 3 Plan (upcoming)

**Goal:** Run 65C816 at ~20 MHz for native SuperCPU speed.

The current design gives the CPU one enable pulse per 32-clock period = 1 MHz.
The EXT cycles (8 slots per period) are currently unused by the CPU. Phase 3 assigns
some EXT cycles to the 65C816:

1. In `fpga64_sid_iec.vhd`, when `supercpu_en='1'`, fire `enableCpu_816` also at
   CYCLE_EXT0/4 (adds up to 8 more enables per period → ~24 MHz effective).
2. **I/O throttle:** when `cpuAddr ∈ [$D000–$DFFF]`, only enable on the normal
   CYCLE_CPUE (1 MHz) to preserve VIC/SID/CIA timing.
3. **BA (badline) stall** already works via RDY_IN — no change needed.
4. Confirm VIC-II demo timing integrity before committing.

The real SuperCPU ran at 20 MHz. At 24 MHz (all EXT slots used) we'd be slightly
faster. Can throttle with idle-cycle insertion if needed.

---

## 17. Signal Quick Reference

| Signal | Where defined | Meaning |
|--------|--------------|---------|
| `clk32` | PLL | 32 MHz master clock |
| `sysCycle` | fpga64_sid_iec | 0–31 bus cycle counter |
| `enableCpu` | fpga64_sid_iec | Delayed cpu_cyc; fires at CYCLE_CPUE |
| `enableCpu_6510` | fpga64_sid_iec | enableCpu gated off when 65C816 active |
| `enableCpu_816` | fpga64_sid_iec | enableCpu gated off when 6510 active |
| `enableCia_n` | fpga64_sid_iec | phi2_n to CIA (fires at CYCLE_CPUC) |
| `enableCia_p` | fpga64_sid_iec | phi2_p to CIA (fires at CYCLE_CPUF) |
| `enableSid` | fpga64_sid_iec | SID sample clock (fires at CYCLE_CPUF) |
| `baLoc` | fpga64_sid_iec | BA from VIC-II; '0' = VIC stealing bus |
| `cpuHasBus` | fpga64_sid_iec | CPU owns bus during CPU cycles |
| `supercpu_en` | fpga64_sid_iec | '1' = use 65C816; '0' = use T65/6510 |
| `supercpu_emul` | fpga64_sid_iec | EF_OUT from P65C816: '1'=emulation mode |
| `supercpu_bank` | fpga64_sid_iec | A23:A16 from P65C816 (bank byte) |
| `cpuAddr` | fpga64_sid_iec | Active CPU address (16-bit, post-DMA MUX) |
| `cpuDo` | fpga64_sid_iec | Active CPU data out (post-DMA MUX) |
| `cpuWe` | fpga64_sid_iec | Active CPU write enable (post-DMA MUX) |
| `cpuDi` | fpga64_sid_iec | Data to CPU (includes SuperCPU ID overlay) |
| `cpuIO` | fpga64_sid_iec | I/O port byte → bankSwitch(2:0) |
| `cia1_pao` | fpga64_sid_iec | CIA1 PA output → keyboard column drive |
| `cia1_pbi` | fpga64_sid_iec | CIA1 PB input ← keyboard row data |
| `irq_cia1` | fpga64_sid_iec | CIA1 IRQ line (active low) |
| `EN` | P65C816 | `RDY_IN AND CE AND NOT WAI AND NOT STP` |
| `EF` | P65C816 | Emulation flag: P(8) |
| `MC` | P65C816 | Current microcode word (from registered MI) |
| `ADDR_BUS` | P65C816 | 24-bit address (combinational from MC + regs) |
| `WE` | P65C816 | Active-low write enable (combinational from MC.OUT_BUS) |
| `D_OUT` | P65C816 | Data to write (combinational from MC.OUT_BUS + regs) |
| `localWe` | cpu_65c816 | = P65C816.WE (active low) |
| `we` | cpu_65c816 | = NOT localWe = active-high WE for system |
| `accessIO` | cpu_65c816 | '1' when addr=$0000 or $0001 (I/O port decode) |
