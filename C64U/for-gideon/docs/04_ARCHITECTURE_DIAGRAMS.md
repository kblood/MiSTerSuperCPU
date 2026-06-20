# MiSTer C64 SuperCPU Architecture Diagrams

This document contains Mermaid architecture diagrams covering the original MiSTer C64 core,
the current SuperCPU implementation, the Ultimate 64 reference, and the planned target architecture.

---

## 1. Original MiSTer C64 Core (Before Modifications)

The unmodified MiSTer C64 core uses a single T65 (6510) CPU with all memory access routed
through SDRAM. The 32MHz system clock is divided into a 32-slot bus rotation that allocates
time between external devices, DMA, VIC-II video, and the CPU.

### 1.1 System Block Diagram

```mermaid
flowchart TB
    subgraph MiSTer_Framework["c64.sv (MiSTer Top Level)"]
        HPS["HPS (ARM)"]
        SDRAM["SDRAM\n32MB"]
        PLL["PLL\n50MHz -> 32MHz"]
    end

    subgraph fpga64["fpga64_sid_iec.vhd (C64 System)"]
        subgraph CPU_Block["CPU"]
            T65["T65\n(6510 CPU)"]
        end

        subgraph BusLogic["fpga64_buslogic.vhd"]
            ADDR_DEC["Address Decoder\nBank Switch Logic"]
            ROM_BRAM["ROMs in BRAM\nKERNAL, BASIC, Chargen"]
            DATA_MUX["dataToCpu MUX"]
        end

        subgraph Peripherals["C64 Peripherals"]
            VIC["VIC-II\n(video_vicii_656x)"]
            SID["SID\n(sid_top)"]
            CIA1["CIA1\n(mos6526)"]
            CIA2["CIA2\n(mos6526)"]
            ColorRAM["Color RAM\n1K x 4-bit"]
        end

        BUS_SM["Bus State Machine\n32-slot rotation"]
    end

    PLL -->|clk32| fpga64
    T65 -->|cpuAddr, cpuDo, cpuWe| BusLogic
    BusLogic -->|cpuDi_raw| T65
    BusLogic -->|systemAddr, ramWE| SDRAM
    SDRAM -->|ramDin| BusLogic
    BusLogic -->|cs_vic, cs_sid, cs_cia1, cs_cia2| Peripherals
    VIC -->|vicAddr| BusLogic
    BusLogic -->|vicDi| VIC
    BUS_SM -->|enableCpu, enableVic| fpga64
    HPS -->|ROM loading, OSD config| fpga64
```

### 1.2 Bus Rotation (32 Slots per 1MHz Period)

The system clock is 32MHz. Each 1MHz CPU cycle consists of 32 clock ticks divided into
four groups. SDRAM accesses are multiplexed across these slots.

```mermaid
gantt
    title 32-Slot Bus Rotation (1 MHz Period = 32 clk32 Ticks)
    dateFormat X
    axisFormat %s

    section EXT (I/O)
    EXT0-EXT3 (Cartridge/IO) : 0, 4

    section DMA
    DMA0-DMA3 (REU/DMA)      : 4, 8

    section EXT (Refresh)
    EXT4-EXT7 (SDRAM Refresh) : 8, 12

    section VIC-II
    VIC0-VIC3 (Video Fetch)   : 12, 16

    section CPU
    CPU0-CPUF (CPU Access)    : 16, 32
```

**Slot Details:**

| Slots     | Name  | Count | Purpose                                           |
|-----------|-------|-------|---------------------------------------------------|
| 0-3       | EXT   | 4     | Cartridge/IO memory access                        |
| 4-7       | DMA   | 4     | REU and DMA engine                                |
| 8-11      | EXT   | 4     | SDRAM refresh (every 4th rotation)                |
| 12-15     | VIC   | 4     | VIC-II character/bitmap/sprite fetch              |
| 16-31     | CPU   | 16    | CPU SDRAM access (1 real access at CPUC)          |

### 1.3 CPU Enable Pipeline (SDRAM Path)

The CPU enable signal is derived through a 3-stage pipeline from the bus state machine.
This ensures SDRAM data is stable before the CPU latches it.

```mermaid
sequenceDiagram
    participant SM as Bus State Machine
    participant CPUC as CYCLE_CPUC
    participant S0 as cpu_cyc_s(0)
    participant S1 as cpu_cyc_s(1)
    participant EN as enableCpu
    participant CPU as T65 CPU

    SM->>CPUC: sysCycle = CYCLE_CPUC
    CPUC->>CPUC: cpu_cyc = '1' (SDRAM CE asserted)
    Note over CPUC: SDRAM reads systemAddr
    CPUC->>S0: cpu_cyc_s(0) <= cpu_cyc
    Note over S0: CYCLE_CPUD: SDRAM processing
    S0->>S1: cpu_cyc_s(1) <= cpu_cyc_s(0)
    Note over S1: CYCLE_CPUE: SDRAM data ready
    S1->>EN: enableCpu <= cpu_cyc_s(1)
    EN->>CPU: enable pulse, CPU latches cpuDi
    Note over CPU: CPU advances to next instruction byte
```

### 1.4 Original Turbo Mode

The original core supports 2x/3x/4x turbo by adding extra SDRAM access slots at
CPU0, CPU4, and CPU8. Each extra slot uses the same pipeline (2-cycle delay from
cpu_cyc to enableCpu).

```mermaid
flowchart LR
    subgraph Turbo_Slots["CPU Slot SDRAM Access Points"]
        CPU0["CPU0\nturbo_m(0)"]
        CPU4["CPU4\nturbo_m(1)"]
        CPU8["CPU8\nturbo_m(2)"]
        CPUC["CPUC\nalways active"]
    end

    subgraph Speed["Effective Speed"]
        S1["1MHz: CPUC only"]
        S2["2MHz: CPUC + CPU4"]
        S3["3MHz: CPUC + CPU0 + CPU4"]
        S4["4MHz: CPUC + CPU0 + CPU4 + CPU8"]
    end

    CPUC --> S1
    CPU4 --> S2
    CPU0 --> S3
    CPU8 --> S4
```

**Conditions for turbo slot activation:**
- `turbo_m(n) = '1'` (OSD-configured speed)
- `cs_ram = '1'` (RAM access, not I/O)
- `cpuHasBus = '1'` (CPU owns bus)
- `baLoc = '1'` (no VIC badline)

---

## 2. Current MiSTer C64 SuperCPU Core

The current implementation adds a dual-CPU architecture with an 8KB BRAM cache and
a 32KB dual-port BRAM for VIC zero-contention access. The P65C816 CPU enables
SuperCPU compatibility with 24-bit addressing and up to 16MB of SuperRAM via SDRAM.

### 2.1 System Block Diagram

```mermaid
flowchart TB
    subgraph MiSTer_Top["c64.sv (MiSTer Top Level)"]
        HPS["HPS (ARM)\nOSD Config"]
        SDRAM["SDRAM 32MB\nBank $00: 64K C64 RAM\nBanks $01-$EF: SuperRAM\nBank $F8: SCPU ROM shadow"]
        PLL["PLL\n50MHz -> 32MHz"]
        ADDR_MUX["SDRAM Address MUX\nscpu_sdram_addr"]
    end

    subgraph fpga64["fpga64_sid_iec.vhd (C64 SuperCPU System)"]
        subgraph DualCPU["Dual CPU (OSD Selectable)"]
            T65["T65 (6510)\ncpu_6510_inst"]
            P65["P65C816 (65C816)\ncpu_816_inst\n(cpu_65c816.vhd)"]
            MUX_CPU["CPU MUX\ncpuAddr_pre\ncpuDo_pre\ncpuWe_pre"]
        end

        subgraph Cache["8KB BRAM Cache (cpu_cache.vhd)"]
            TAGS["MLAB Tags\n1024 x 11-bit\n(combinational read)"]
            DATA["M10K Data\n1024 x 8 bytes\n(1-cycle registered read)"]
            VALID["MLAB Valid\n1024 x 8 bits\n(per-byte valid)"]
            WB["Write Buffer\n16-entry FIFO\n(currently disabled)"]
        end

        subgraph BRAM_32K["32KB Dual-Port BRAM (c64_ram64k.vhd)"]
            PORTA["Port A (CPU)\nRead/Write\n$0000-$7FFF"]
            PORTB["Port B (VIC)\nRead Only\n$0000-$7FFF"]
        end

        subgraph BusLogic["fpga64_buslogic.vhd"]
            ADDR_DEC["Address Decoder\n+ SuperCPU bank bypass"]
            ROM_BRAM["ROMs in BRAM\nKERNAL, BASIC, Chargen\n+ SuperCPU ROM (64KB)"]
            SYSRAM["SCPU System RAM\n512B at $D200-$D3FF"]
            DATA_MUX_BL["dataToCpu MUX\n(cpuDi_raw)"]
        end

        subgraph Peripherals["C64 Peripherals"]
            VIC["VIC-II"]
            SID["SID"]
            CIA1["CIA1"]
            CIA2["CIA2"]
        end

        DI_MUX["cpuDi Priority MUX\n1. bram_do (bram_hit_d1)\n2. cache_di (cache_hit_d1)\n3. SCPU registers\n4. cpuDi_raw (SDRAM path)"]
        EN_GATE["Enable Gating\nenableCpu_6510\nenableCpu_816"]
        BUS_SM["Bus State Machine\n32-slot rotation"]
        SCPU_REG["SuperCPU Registers\n$D07A-$D0BC"]
        IEC_SLOW["IEC Auto-Slowdown\nCIA2 write detection\n32ms timeout"]
    end

    PLL -->|clk32| fpga64
    T65 -->|cpuAddr/Do/We_6510| MUX_CPU
    P65 -->|cpuAddr/Do/We_816\naddr_hi_816 (bank)| MUX_CPU
    MUX_CPU -->|cpuAddr_pre| Cache
    MUX_CPU -->|cpuAddr_pre| BRAM_32K
    MUX_CPU -->|cpuAddr_pre| BusLogic
    MUX_CPU -->|cpuWe_pre, cpuDo_pre| BusLogic

    BusLogic -->|cpuDi_raw| DI_MUX
    BusLogic -->|systemAddr| SDRAM
    SDRAM -->|ramDin/sdram_data| BusLogic

    Cache -->|cache_di, cache_hit| DI_MUX
    BRAM_32K -->|bram_do| DI_MUX
    DI_MUX -->|cpuDi| T65
    DI_MUX -->|cpuDi| P65

    Cache -->|cache_hit_d1| EN_GATE
    BRAM_32K -.->|bram_hit_d1\n(DISABLED)| EN_GATE
    BUS_SM -->|enableCpu| EN_GATE
    EN_GATE -->|enableCpu_6510| T65
    EN_GATE -->|enableCpu_816| P65

    PORTB -->|bram_vic_do| BusLogic
    VIC -->|vicAddr| BusLogic
    BusLogic -->|vicDi| VIC

    HPS -->|supercpu_en, turbo_mode| fpga64
    ADDR_MUX -->|scpu_sdram_addr| SDRAM

    IEC_SLOW -->|iec_slow_mode| EN_GATE
    SCPU_REG -->|scpu_speed_1mhz| EN_GATE
```

### 2.2 Cache Architecture Detail

The 8KB direct-mapped cache uses MLAB for tags and valid bits (combinational read) and
M10K for data storage (1-cycle registered read). This asymmetry means the tag check is
immediate, but the data output arrives one cycle later, requiring a suppress cycle after
each hit.

```mermaid
flowchart TB
    subgraph Address_Decomp["24-bit Address Decomposition"]
        BANK["[23:16] Bank (8 bits)"]
        HI["[15:13] Addr High (3 bits)"]
        LINE["[12:3] Line Index (10 bits)"]
        OFF["[2:0] Byte Offset (3 bits)"]
    end

    subgraph Tag_Check["Tag Check (Combinational)"]
        TAG_STORE["MLAB Tag Array\n1024 x 11-bit"]
        TAG_CMP["Tag Compare\nbank(8) & addr_hi(3)\n= expected_tag?"]
        VALID_STORE["MLAB Valid Array\n1024 x 8-bit"]
        BYTE_CHK["Byte Valid Check\nvalid[line][offset]"]
    end

    subgraph Data_Read["Data Read (Registered)"]
        DATA_BRAM["M10K Data Array\n8192 x 8-bit\naddr = line(10) & offset(3)"]
        CACHE_DI["cache_di\n(1 cycle after address)"]
    end

    subgraph Hit_Logic["Hit Generation"]
        CACHEABLE["Cacheable Check\nBank $00: not $D000-$DFFF\nBanks $01-$EF: all\nBanks $F0+: none (ROM)"]
        HIT["cache_hit\n= cacheable_rd AND\ntag_match AND byte_valid"]
    end

    subgraph Fill_Path["Fill Path (SDRAM -> Cache)"]
        FILL["fill_we = enableCpu\nAND not wb_drain\nAND not cpuWe\nAND baLoc"]
        FILL_DATA["fill_data = cpuDi_raw\n(buslogic output)"]
    end

    BANK --> TAG_CMP
    HI --> TAG_CMP
    LINE --> TAG_STORE
    LINE --> VALID_STORE
    OFF --> BYTE_CHK
    LINE --> DATA_BRAM
    OFF --> DATA_BRAM

    TAG_STORE --> TAG_CMP
    VALID_STORE --> BYTE_CHK
    TAG_CMP --> HIT
    BYTE_CHK --> HIT
    CACHEABLE --> HIT

    DATA_BRAM --> CACHE_DI

    FILL --> DATA_BRAM
    FILL_DATA --> DATA_BRAM
```

### 2.3 Cache Hit Pipeline (cache_hit_d1)

The cache hit signal goes through a registered pipeline with a 1-cycle suppress after
each hit. This accounts for M10K data read latency: the CPU gets data from the previous
hit while the cache fetches data for the new address.

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Hit : cache_hit=1 AND\nnot cpuWe_pre AND\nnot dma_active AND baLoc AND\nnot scpu_speed_1mhz AND\nnot iec_slow_mode AND\nnot cpu_cyc_s(0/1) AND\nnot enableCpu AND\n(non-CPU slot OR idle CPU slot)
    Hit --> Suppress : Always (1-cycle M10K latency)
    Suppress --> Hit : cache_hit=1 AND conditions met
    Suppress --> Idle : cache_hit=0 OR conditions not met

    note right of Hit
        cache_hit_d1 = '1'
        CPU enable fires
        CPU reads cache_di from PREVIOUS cycle
        New address presented to cache
    end note

    note right of Suppress
        cache_hit_d1 = '0'
        CPU waits
        M10K reads data for new address
        cache_di becomes valid
    end note
```

**Write suppression:** `cpuWe_pre = '1'` blocks cache_hit_d1. Writes must go through
the SDRAM path (via cpu_cyc and enableCpu) so that both SDRAM and BRAM receive the data.
Without this gate, writes via cache_hit_d1 go nowhere (no cpu_cyc, no bram_we), causing
lost writes and brown-screen corruption after reset.

### 2.4 32KB BRAM Data Flow

The 32KB dual-port BRAM covers $0000-$7FFF in bank $00. Port A serves the CPU with
write-through and SDRAM/cache fill. Port B provides VIC-II with zero-contention reads.

```mermaid
flowchart TB
    subgraph Writes["BRAM Write Sources (Port A)"]
        CPU_WR["CPU Write\ncpuDo_pre\n(cpuWe_pre=1)"]
        SDRAM_FILL["SDRAM Read Fill\ncpuDi_raw\n(enableCpu=1, cpuHasBus=1)"]
        CACHE_FILL["Cache Hit Fill\ncache_di\n(cache_hit_d1=1)"]
    end

    subgraph BRAM["32KB Dual-Port BRAM\nc64_ram64k.vhd\nM10K Block RAM"]
        PA["Port A\nCPU Read/Write\na_addr = cpuAddr_pre(14:0)"]
        PB["Port B\nVIC Read Only\nb_addr = systemAddr(14:0)"]
    end

    subgraph Read_Out["Read Outputs"]
        BRAM_DO["bram_do -> cpuDi MUX\n(gated by bram_hit_d1,\ncurrently DISABLED)"]
        VIC_DO["bram_vic_do -> buslogic_ramData\n(when cpuHasBus=0\nAND systemAddr(15)=0)"]
    end

    subgraph Guards["Write Enable Guards"]
        WE_LOGIC["bram_we conditions:\n- bram64k_en = '1'\n- cache_cpu_bank = $00\n- cpuAddr_pre(15) = '0'\n- One of:\n  a) CPU write + (enableCpu OR bram_hit_d1)\n  b) SDRAM read fill + cpuHasBus\n  c) Cache hit fill"]
    end

    CPU_WR --> WE_LOGIC
    SDRAM_FILL --> WE_LOGIC
    CACHE_FILL --> WE_LOGIC
    WE_LOGIC --> PA
    PA --> BRAM_DO
    PB --> VIC_DO

    subgraph VIC_Path["VIC Read Path"]
        VIC_ADDR["VIC vicAddr\n(during VIC/badline slots)"]
        BL_MUX["buslogic_ramData MUX\nbram_vic_do when BRAM + VIC slot + addr < $8000\nramDin otherwise"]
    end

    VIC_ADDR --> PB
    VIC_DO --> BL_MUX
```

### 2.5 CPU Enable Gating (Combined Paths)

The CPU enable signal combines three possible sources: BRAM hit (disabled), cache hit,
and SDRAM pipeline. The active CPU is determined by the `supercpu_en` OSD setting.

```mermaid
flowchart TB
    subgraph Sources["Enable Sources"]
        BRAM_HIT["bram_hit_d1\n(DISABLED:\nbram_hit_ram='0')"]
        CACHE_HIT["cache_hit_d1\n(turbo_en gated)"]
        SDRAM_EN["enableCpu\n(from cpu_cyc_s pipeline)\n(not dma_active)"]
    end

    subgraph T65_Gate["T65 Enable (supercpu_en = '0')"]
        EN_6510["enableCpu_6510 =\nbram_hit_d1 OR\n(cache_hit_d1 AND turbo_en) OR\n(enableCpu AND NOT dma_active)"]
    end

    subgraph P65_Gate["P65C816 Enable (supercpu_en = '1')"]
        EN_816["enableCpu_816 =\n(bram_hit_d1 AND turbo_en) OR\n(cache_hit_d1 AND turbo_en) OR\n(enableCpu AND NOT dma_active)"]
    end

    BRAM_HIT --> EN_6510
    CACHE_HIT --> EN_6510
    SDRAM_EN --> EN_6510

    BRAM_HIT --> EN_816
    CACHE_HIT --> EN_816
    SDRAM_EN --> EN_816

    EN_6510 -->|"supercpu_en='0'"| T65_CPU["T65 CPU\nenable input"]
    EN_816 -->|"supercpu_en='1'"| P65_CPU["P65C816 CPU\nenable input"]
```

### 2.6 cpuDi Data Priority MUX

The CPU data input is a priority multiplexer. BRAM and cache take precedence over
SDRAM because they are delivering data for cache/BRAM-driven enables.

```mermaid
flowchart TB
    P1["Priority 1: bram_do\nwhen bram_hit_d1 = '1'\n(DISABLED)"]
    P2["Priority 2: cache_di\nwhen cache_hit_d1 = '1'\nAND scpu_rom_overlay = '0'"]
    P3["Priority 3: SuperCPU Registers\n$D0BC -> $C9 (ID)\n$D0B0 -> $40 (mode)\n$D0B2 -> $00 (ROM ctrl)\n$D0B8 -> speed status\netc."]
    P4["Priority 4: cpuDi_raw\n(buslogic dataToCpu output)\nMuxes: ROM BRAM, SDRAM,\nVIC, SID, CIA, Color RAM"]

    P1 --> MUX["cpuDi"]
    P2 --> MUX
    P3 --> MUX
    P4 --> MUX
```

### 2.7 SuperCPU Register Map

SuperCPU control registers are memory-mapped in the VIC-II mirror space ($D07x/$D0Bx),
accessible only in bank $00.

| Address | R/W | Value | Description                                    |
|---------|-----|-------|------------------------------------------------|
| $D074   | W   | -     | Optimization mode: no mirror                   |
| $D075   | W   | -     | Optimization mode: banks $00-$01               |
| $D076   | W   | -     | Optimization mode: banks $00-$7F               |
| $D077   | W   | -     | Optimization mode: no optimization              |
| $D078   | W   | -     | Software cache flush (1024-cycle sweep)         |
| $D07A   | W   | -     | Speed: force 1MHz                              |
| $D07B   | W   | -     | Speed: force 20MHz (turbo)                     |
| $D07E   | W/R | $00   | Register enable / ROM visibility               |
| $D07F   | W   | -     | Register disable                               |
| $D0B0   | R   | $40   | Mode detect: SuperCPU v2 in C64 mode           |
| $D0B2   | R   | $00   | ROM control mirror (SIMM detect requires $00)  |
| $D0B4   | R   | flags | Optimization mode flags                        |
| $D0B8   | R   | flags | Speed status: bit6=1 if 1MHz, 0 if turbo       |
| $D0BC   | R   | $C9   | SuperCPU identification byte                   |

### 2.8 Dual CPU MUX and 65C816 Wrapper

The cpu_65c816.vhd wrapper presents a cpu_6510-compatible interface around the P65C816
core (from the SNES MiSTer core). Both CPUs are always instantiated; the inactive one
is held in reset.

```mermaid
flowchart LR
    subgraph T65_Side["T65 (6510)"]
        T65_I["cpu_6510_inst\nreset = reset OR supercpu_en"]
        T65_O["cpuAddr_6510\ncpuDo_6510\ncpuWe_6510\ncpuIO_6510"]
    end

    subgraph P65_Side["P65C816 (65C816)"]
        P65_I["cpu_816_inst\nreset = reset OR NOT supercpu_en"]
        P65_WRAP["cpu_65c816.vhd wrapper\n- 6510 I/O port ($0000-$0001)\n- Bank byte (addr_hi_816)\n- Emulation mode flag\n- VPA/VDA signals\n- NMI edge detect + ack"]
        P65_O["cpuAddr_816\ncpuDo_816\ncpuWe_816 (baLoc gated)\ncpuIO_816\naddr_hi_816\nemu_mode_816"]
    end

    subgraph MUX["CPU MUX (supercpu_en selects)"]
        SEL{"supercpu_en?"}
        OUT["cpuAddr_pre\ncpuDo_pre\ncpuWe_pre\ncpuIO\nnmi_ack"]
    end

    T65_O --> SEL
    P65_O --> SEL
    SEL -->|"'0' = T65"| OUT
    SEL -->|"'1' = P65"| OUT
```

### 2.9 IEC Auto-Slowdown

CIA2 writes to $DD00-$DD03 (IEC serial bus port) trigger a 32ms slowdown timer.
While active, both cache_hit_d1 and turbo_m are suppressed, forcing 1MHz operation.
This prevents IEC timing violations during disk access.

```mermaid
stateDiagram-v2
    [*] --> Normal_Speed
    Normal_Speed --> IEC_Slow : CIA2 write to $DD00-$DD03\n(cpuWe=1, cs_cia2=1, enableCpu=1)
    IEC_Slow --> IEC_Slow : iec_slow_ctr > 0\n(decrementing each clk32)
    IEC_Slow --> Normal_Speed : iec_slow_ctr = 0\n(~32ms elapsed)

    note right of IEC_Slow
        iec_slow_mode = '1'
        - cache_hit_d1 suppressed
        - turbo_m forced to "000"
        - turbo_en stays '1' but no turbo slots fire
        - Effective speed: 1MHz
    end note
```

### 2.10 SDRAM Address Routing (c64.sv)

The SDRAM address is multiplexed based on the current bus slot and SuperCPU bank.

```mermaid
flowchart TB
    subgraph Slots["Bus Slot Priority"]
        IO["io_cycle = '1'\n(EXT slots)"]
        EXT["ext_cycle = '1'\n(DMA slots)"]
        CPU_SLOT["CPU/VIC slots"]
    end

    subgraph IO_MUX["IO Cycle MUX"]
        CART_REQ{"cart_mem_req?"}
        CART_ADDR["cart_addr"]
        IO_ADDR["io_cycle_addr"]
    end

    subgraph SCPU_MUX["SuperCPU Address MUX"]
        SCPU_CHK{"supercpu_enable\nAND supercpu_cycle\nAND bank != $00?"}
        BANKED["{1'b0, bank, c64_addr}\n= 24-bit SuperRAM addr"]
        NORMAL["cart_addr\n= {9'd0, c64_addr}\n= normal 64K"]
    end

    IO --> CART_REQ
    CART_REQ -->|Yes| CART_ADDR
    CART_REQ -->|No| IO_ADDR

    EXT --> REU_ADDR["reu_ram_addr"]

    CPU_SLOT --> SCPU_CHK
    SCPU_CHK -->|Yes| BANKED
    SCPU_CHK -->|No| NORMAL

    CART_ADDR --> SDRAM["SDRAM"]
    IO_ADDR --> SDRAM
    REU_ADDR --> SDRAM
    BANKED --> SDRAM
    NORMAL --> SDRAM
```

---

## 3. Ultimate 64 SuperCPU (Reference Architecture)

The Ultimate 64 is a commercial FPGA-based C64 replacement board by Gideon Zweijtzer
that includes SuperCPU emulation. This section describes publicly known architectural
characteristics for comparison purposes. The exact internal implementation is proprietary.

### 3.1 High-Level Architecture

```mermaid
flowchart TB
    subgraph U64["Ultimate 64 Board"]
        FPGA["Xilinx Artix-7\nFPGA"]
        SRAM["Fast SRAM\n(low-latency)"]
        SID_HW["Real SID Chips\n(socket or emulated)"]
        SDRAM_U["SDRAM\n(bulk storage)"]
    end

    subgraph Core["C64 + SuperCPU Core"]
        CPU_U["65C816 CPU Core\n(custom implementation)"]
        VIC_U["VIC-II"]
        BUS_U["Bus Arbitration\nwith SRAM fast path"]
        SCPU_U["SuperCPU Logic\n20MHz effective"]
    end

    CPU_U -->|"Fast path"| SRAM
    CPU_U -->|"Bulk access"| SDRAM_U
    VIC_U --> SRAM
    SID_HW --> FPGA
```

**Key differences from our MiSTer implementation:**

| Aspect               | Ultimate 64                    | MiSTer SuperCPU                       |
|-----------------------|--------------------------------|---------------------------------------|
| FPGA                  | Xilinx Artix-7                 | Intel Cyclone V                       |
| Fast memory           | Dedicated SRAM (ns latency)    | M10K BRAM (cache + 32KB dual-port)    |
| Bulk memory           | SDRAM                          | SDRAM (shared with MiSTer framework)  |
| SID                   | Real chip sockets              | FPGA SID emulation                    |
| Bus acceleration      | SRAM gives near-zero latency   | Cache hit/suppress alternation        |
| 20MHz approach        | SRAM bandwidth                 | Cache + SDRAM slot interleaving       |
| Resource constraints  | Artix-7 has more BRAM          | Cyclone V at 90% M10K utilization     |

---

## 4. Planned Target Architecture

Based on the plan at `plans/vast-enchanting-sutherland.md`, the target is 20MHz effective
CPU speed through wider cache windows, lookahead, and write buffer drain.

### 4.1 Speed Scaling Strategy

```mermaid
flowchart TB
    subgraph Current["Current: ~8MHz Effective"]
        C_SDRAM["4 SDRAM enables\n(CPU0/CPU4/CPU8/CPUC\nwith 4x turbo)"]
        C_CACHE["~4 cache enables\n(hit/suppress alternation\nin 16 non-CPU slots)"]
        C_TOTAL["Total: ~8 enables/rotation\n= ~8MHz"]
    end

    subgraph PhaseA["Phase A: Wider Cache Windows"]
        A1["A1: EXT slots (8 slots)\n-> ~4 cache hits"]
        A2["A2: All non-CPU slots (16)\n-> ~8 cache hits"]
        A3["A3: + Idle CPU slots (28)\n-> ~14 cache hits"]
    end

    subgraph PhaseB["Phase B: Write Buffer Drain"]
        B1["Steal SDRAM slots for\nwrite buffer drain"]
        B2["CPU continues via\ncache_hit_d1 during drain"]
        B3["Re-enable cacheable_wr\nfor 1-cycle write absorption"]
    end

    subgraph Target["Target: ~20MHz Effective"]
        T_SDRAM["4 SDRAM enables\n(or stolen for WB drain)"]
        T_CACHE["~16 cache enables\n(hit/suppress over 28+ slots)"]
        T_TOTAL["Total: ~20 enables/rotation\n= ~20MHz"]
    end

    Current --> PhaseA
    PhaseA --> PhaseB
    PhaseB --> Target
```

### 4.2 Planned Implementation Phases

| Phase | Description                           | Status          | Expected Speed |
|-------|---------------------------------------|-----------------|----------------|
| D     | IEC auto-slowdown                     | DONE            | Safety net     |
| A1    | Cache fast path (EXT slots)           | DONE            | ~8MHz          |
| A2    | Widen to all non-CPU slots            | DONE            | ~12-16MHz      |
| A3    | + Idle CPU slots                      | DONE            | ~16-20MHz      |
| B     | Write buffer drain                    | Not started     | Write perf     |
| C     | Targeted cache invalidation           | Deferred        | Flush overhead |

### 4.3 Target Cache Hit Window

The plan achieves higher speeds by allowing cache hits in more of the 32-slot rotation.
Currently A1-A3 are implemented: cache hits fire in all non-CPU slots plus idle CPU slots.

```mermaid
gantt
    title Cache Hit Eligibility per Slot (A3 Implemented)
    dateFormat X
    axisFormat %s

    section EXT 0-3
    Cache eligible : 0, 4

    section DMA 0-3
    Cache eligible : 4, 8

    section EXT 4-7
    Cache eligible : 8, 12

    section VIC 0-3
    Cache eligible : 12, 16

    section CPU0
    Cache if cpu_cyc=0 : 16, 17

    section CPU1
    Cache if cpu_cyc=0 : 17, 18

    section CPU2
    Cache if cpu_cyc=0 : 18, 19

    section CPU3
    Cache if cpu_cyc=0 : 19, 20

    section CPU4
    Cache if cpu_cyc=0 : 20, 21

    section CPU5
    Cache if cpu_cyc=0 : 21, 22

    section CPU6
    Cache if cpu_cyc=0 : 22, 23

    section CPU7
    Cache if cpu_cyc=0 : 23, 24

    section CPU8
    Cache if cpu_cyc=0 : 24, 25

    section CPU9
    Cache if cpu_cyc=0 : 25, 26

    section CPUA
    Cache if cpu_cyc=0 : 26, 27

    section CPUB
    Cache if cpu_cyc=0 : 27, 28

    section CPUC
    SDRAM access (always) : crit, 28, 29

    section CPUD
    Pipeline stage 1 : crit, 29, 30

    section CPUE
    Pipeline stage 2 : crit, 30, 31

    section CPUF
    enableCpu fires : crit, 31, 32
```

**Note:** Slots marked "Cache if cpu_cyc=0" only allow cache hits when no SDRAM access
is in progress. During 4x turbo, CPU0/CPU4/CPU8 have cpu_cyc=1, reducing cache-eligible
slots. The 1-cycle suppress after each hit further halves the effective throughput.

### 4.4 Write Buffer Drain Mechanism (Phase B, Not Yet Implemented)

```mermaid
sequenceDiagram
    participant CPU as CPU
    participant Cache as 8KB Cache
    participant WB as Write Buffer (16)
    participant SDRAM as SDRAM

    Note over CPU,SDRAM: Phase B: Write Absorption + Drain

    CPU->>Cache: Write to cacheable addr
    Cache->>Cache: Update cache data + tag
    Cache->>WB: Push {addr, bank, data}
    Note over CPU: CPU continues (1-cycle write)

    Note over WB,SDRAM: During next cpu_cyc slot:
    WB->>SDRAM: wb_addr, wb_data (steal SDRAM slot)
    Note over CPU: CPU runs from cache_hit_d1
    Note over SDRAM: enableCpu suppressed (write, not read)
    SDRAM-->>WB: wb_ack (entry drained)
```

---

## 5. Current Issues and Next Steps

### 5.1 Known Issues

```mermaid
flowchart TB
    subgraph Active_Issues["Active Issues"]
        BRAM_VALID["bram_hit_d1 DISABLED\nPer-page valid (256 bytes) is too coarse.\nRAMTAS marks 1 byte/page valid,\n255 bytes remain uninitialized.\nCPU reads garbage, crashes.\nFix: per-byte or per-line valid\n(removed due to M10K budget)"]

        SUPPRESS["1-Cycle Suppress Bottleneck\nHit/suppress alternation halves\nmax cache throughput:\n16 eligible slots -> 8 actual hits.\nMax theoretical: 8 cache + 4 SDRAM = 12MHz.\nNeed lookahead to break barrier."]

        M10K["M10K Budget Pressure\n496/553 blocks used (90%).\n64KB BRAM caused fitter failure\nat 95%. Per-byte valid removed\nto save ~7 blocks.\nThreshold: ~90-92%."]
    end

    subgraph Perf["Performance Numbers (Hardware Verified)"]
        CACHE_ONLY["8KB Cache Only (no BRAM):\nCache hits: 2913/frame\nEnables: 7624/frame\n~4x turbo"]
        BRAM_CACHE["32KB BRAM + Cache ($8000+):\nCache hits: 1593/frame\nEnables: 7360/frame\nCache suppressed for $0000-$7FFF"]
    end
```

### 5.2 Architecture Decision Tree

```mermaid
flowchart TB
    START["Current State:\n8MHz effective, bram_hit DISABLED"]

    Q1{"Per-byte valid\nM10K budget available?"}
    Q1 -->|"Yes: ~7 M10K blocks"| PERBYTE["Re-enable bram_valid.vhd\nPer-byte M10K valid tracking\nbram_hit_d1 = bram_hit_addr AND bram_byte_valid"]
    Q1 -->|"No: >90% M10K"| PERLINE["Per-line valid alternative\n1024 valid bits (registers)\n1 bit per 32-byte region\nSmaller than per-byte but coarser"]

    PERBYTE --> BRAM_EN["bram_hit_d1 enabled\n$0000-$7FFF: 100% hit rate\nNo tag check overhead\nNo 1-cycle suppress needed?"]
    PERLINE --> BRAM_EN

    BRAM_EN --> WB["Phase B: Write Buffer Drain\nRe-enable cacheable_wr\nSteal SDRAM slots for drain\nAdd bank byte to WB entries"]

    WB --> LOOKAHEAD["Future: Cache Lookahead\nBreak hit/suppress barrier\nPrefetch next address\nduring suppress cycle"]

    LOOKAHEAD --> GOAL["20MHz Target\n16 cache + 4 SDRAM = 20 enables/rotation"]
```

### 5.3 Cache Coherency Model

Multiple data sources must stay coherent: SDRAM, 8KB cache, and 32KB BRAM. The current
coherency rules prevent stale data from being served to the CPU or VIC.

```mermaid
flowchart TB
    subgraph Write_Path["CPU Write Coherency"]
        W1["CPU writes go through SDRAM path\n(cpuWe_pre blocks cache_hit_d1)"]
        W2["SDRAM receives write data\n(via cpu_cyc -> enableCpu)"]
        W3["BRAM receives write data\n(bram_we on cpuWe_pre + enableCpu)"]
        W4["Cache valid bit cleared\n(invalidate_wr when tag matches)"]

        W1 --> W2
        W1 --> W3
        W1 --> W4
    end

    subgraph Read_Path["CPU Read Coherency"]
        R1["Cache hit: serve cache_di\nFill BRAM from cache_di\n(cache_hit_d1 -> bram_we)"]
        R2["SDRAM read: serve cpuDi_raw\nFill cache from cpuDi_raw\nFill BRAM from cpuDi_raw"]
        R3["BRAM hit: serve bram_do\n(DISABLED currently)"]
    end

    subgraph Flush_Triggers["Cache Flush Triggers"]
        F1["reset"]
        F2["dma_active"]
        F3["Software flush ($D078)"]
        F4["Bank switch change\n(cpuIO(2:0), GAME, EXROM)"]
    end

    subgraph VIC_Path["VIC Read Coherency"]
        V1["VIC reads BRAM Port B\nfor $0000-$7FFF\n(buslogic_ramData mux)"]
        V2["VIC reads SDRAM\nfor $8000-$FFFF"]
        V3["BRAM kept coherent via\nwrite-through + SDRAM fill\n+ cache fill"]
    end

    F1 --> FLUSH["1024-cycle valid sweep"]
    F2 --> FLUSH
    F3 --> FLUSH
    F4 --> FLUSH
```

### 5.4 Resource Utilization

| Resource       | Used     | Available | Utilization |
|----------------|----------|-----------|-------------|
| ALMs           | 30,788   | 41,910    | 73%         |
| M10K RAM blocks| 496      | 553       | 90%         |
| Registers      | -        | -         | -           |

**M10K allocation breakdown (approximate):**

| Component              | M10K Blocks | Notes                          |
|------------------------|-------------|--------------------------------|
| 32KB BRAM (c64_ram64k) | ~26         | 32768 x 8 bits                 |
| 8KB Cache data         | ~8          | 8192 x 8 bits                  |
| ROMs (KERNAL, BASIC, etc.) | ~20    | Multiple dprom instances        |
| SuperCPU ROM           | ~64         | 64KB dprom                     |
| SID, VIC, other        | variable    | Framework and peripheral RAM    |
| MiSTer sys/ framework  | ~300+       | Framebuffer, HDMI, HPS bridge   |
