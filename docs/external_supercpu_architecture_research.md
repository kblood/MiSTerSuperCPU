# Architectural Engineering and Implementation Strategies for Emulating the CMD SuperCPU at 20 MHz and Beyond within the MiSTer C64 Core

*Source: External research document, imported 2026-05-20 from Google Docs (`docs.google.com/document/d/14uxbvFi…`)*

## Historical Evolution of Commodore 64 Coprocessor Acceleration

The quest to overcome the performance constraints of the MOS 6510 processor has driven hardware developers to design diverse external acceleration options since the early 1980s. The Commodore 64 architecture interlocks its central processing unit with the video controller (the VIC-II), forcing both chips to alternate memory access on opposite phases of a shared ~1 MHz system clock. Consequently, traditional synchronous overclocking is impossible; raising the global clock frequency degrades the video sync timings and disrupts the tightly coupled memory-access loop.

To bypass these architectural limitations, developers designed coprocessor-style accelerators that plug directly into the expansion port. These devices execute instructions in an independent, high-speed clock domain while synchronizing with the C64 motherboard solely during input/output operations and shared memory transfers. The first highly successful 16-bit implementation was the Flash 8, released in 1994 by Roßmöller. The Flash 8 utilized a Western Design Center W65C816S processor running at 8 MHz, utilizing specialized, low-latency ZIP RAM to execute operations asynchronously.

However, the Flash 8 suffered from critical display issues because its memory architecture isolated the Zero Page and Stack regions from the VIC-II, causing screen corruption in programs that stored graphical or sprite data in those ranges. Furthermore, its physical footprint occupied the expansion port entirely, making it incompatible with standard disk-interface cartridges.

Creative Micro Devices addressed these vulnerabilities in 1997 by releasing the CMD SuperCPU. Clocked at 20 MHz, the SuperCPU incorporated a highly refined W65C816S core and introduced sophisticated memory optimization modes. Rather than completely isolating the memory space, the SuperCPU used its onboard FPGA to mirror critical memory blocks, allowing the VIC-II and the CPU to coordinate accesses without crashing the system. This architecture enabled the C64 to run complex, computationally heavy programs.

The SuperRAM card expanded the system by allowing users to add 1 MB to 16 MB of directly addressable fast-page mode SIMM memory. However, random non-sequential accesses to the SIMMs introduced minor wait states compared to the fast ZIP RAM used in the Flash 8.

In the modern FPGA era, hardware developers have pursued various acceleration methods. Individual Computers released the Turbo Chameleon 64 in 2011, leveraging an Altera Cyclone III FPGA to implement a flexible 6510-compatible turbo core with full support for illegal opcodes. Although the Chameleon 64 can be configured to execute at elevated clock rates (such as 6 MHz or higher) to run modern demoscene productions, it is not binary compatible with the 16-bit 65C816 architecture of the SuperCPU.

Concurrently, Gideon Zweijtzer developed the 1541 Ultimate and Ultimate 64 platforms using Artix 7 FPGAs. While these platforms implement a high-performance 48 MHz turbo mode, they have faced design hurdles in accurately replicating the physical register behaviors and detection characteristics of the original SuperCPU.

C64 Acceleration Evolution Timeline:
```
+-------------------------------------------------------------+
| 1994: Roßmöller Flash 8 (8 MHz 65C816, ZIP RAM)             |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
| 1997: CMD SuperCPU v2 (20 MHz 65C816, 1-16MB SIMM RAM)      |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
| 2011: Turbo Chameleon 64 (FPGA-based 6510 Turbo, 16MB REU)  |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
| 2026: MiSTer FPGA (Cyclone V Core integration goals)        |
+-------------------------------------------------------------+
```

## Architectural Comparison of Acceleration Technologies

| Metric | Roßmöller Flash 8 | CMD SuperCPU v2 | Turbo Chameleon 64 | Gideon's Ultimate 64 | MicroCore Labs MCL64 |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **CPU Architecture** | 16-bit W65C816S | 16-bit W65C816S | 8-bit MOS 6510 (Turbo) | 8-bit MOS 6510 (Turbo) | 8-bit MOS 6510 Emulation |
| **Max Clock Speed** | 8 MHz | 20 MHz | Variable (6+ MHz) | 48 MHz (Internal Bus) | >600 MHz (ARM offload) |
| **Memory Medium** | ZIP RAM (Up to 1 MB) | SIMM RAM (Up to 16 MB) | 32 MB SRAM | Embedded FPGA RAM | Teensy 4.1 On-Board RAM |
| **Memory Mode** | Dynamic/Linear | Linear via SuperRAM | REU/GeoRAM Emulation | REU Emulation (up to 16M) | External Host Mapped |
| **C64 Compatibility** | Moderate (Locks 1 MHz) | High (On-The-Fly) | Complete (All Opcodes) | Complete (All Opcodes) | High (Non-Cycle-Exact Option) |
| **VGA Support** | None (Native Composite) | None (Pass-Through) | Native VGA Out | HDMI Video Out | Native Composite/RF |
| **Hardware Form** | Expansion Cartridge | Expansion Cartridge | Cartridge / Standalone | Motherboard Replacement | Drop-in Socket Replacement |

## Processor-Level Discrepancies and Soft-Core Selection

Integrating 16-bit acceleration into the standard 8-bit MiSTer C64 core requires replacing the primary execution engine with a soft-core capable of executing the 65C816 instruction set.

### Instruction Set and Register Expansion

The 6510 processor is an 8-bit device operating with an 8-bit accumulator, two 8-bit index registers, a 16-bit program counter, and an 8-bit stack pointer limited to page one ($0100–$01FF). Conversely, the 65C816 expands this model by introducing a 16-bit accumulator, two 16-bit index registers, and a 16-bit stack pointer that can be placed anywhere in Bank 0. Additionally, the 65C816 incorporates a 16-bit Direct Register (DR) to relocate the zero page dynamically and two 8-bit bank registers to extend addressing to 24 bits: the Program Bank Register (PRB) and the Data Bank Register (DRB).

Register Size Comparison:
```
6510:
   Accumulator (A): [ 8-bit ]
   Index X (X)    : [ 8-bit ]
   Index Y (Y)    : [ 8-bit ]
   Stack (SP)     : [ 8-bit ] (Hardwired to Page 1)

65C816:
   Accumulator (C): [     16-bit     ] (Can split into 8-bit A and B)
   Index X (X)    : [     16-bit     ] (Can truncate to 8-bit)
   Index Y (Y)    : [     16-bit     ] (Can truncate to 8-bit)
   Stack (SP)     : [     16-bit     ] (Positionable anywhere in Bank 0)
   Direct Reg (DR): [     16-bit     ] (Relocates zero page/direct page)
```

At power-on or hardware reset, the 65C816 initializes in emulation mode, behaving like a standard 65C02 with 8-bit limitations. Software must execute the exchange instruction `xce` (Exchange Carry with Emulation Flag) to transition into 16-bit native mode, enabling full 24-bit flat memory addressing and 16-bit register capabilities.

Beyond the 65C816, the Western Design Center designed the W65C832, a 32-bit extension of the architecture. While never manufactured commercially, its soft-core Verilog implementation by Mike Kohn demonstrates how the instruction set scales. The 65C832 expands the accumulator and index registers to 32 bits while retaining a 16-bit program counter and stack pointer.

To transition from 16-bit 65C816 mode to 32-bit mode, the processor executes a modified instruction sequence: clearing the carry and overflow flags, then executing the exchange instruction `xce` to swap the carry status with the 8-bit emulation flag and the overflow status with the 16-bit emulation flag.

Transition Sequence to 32-Bit Mode:
```
   clc          ; Clear Carry Flag
   clv          ; Clear Overflow Flag
   xce          ; Swap Carry/Overflow to engage 32-bit registers
```

### Soft-Core Candidate Evaluation

The existing T65 VHDL core used in many older MiSTer cores is incomplete and lacks proper implementation or testing for 65C02 and 65C816 native instructions. Multiple alternative open-source 65816 cores were evaluated:

- **srg320 SNES Core**: Developed by Sergiy Dvodnenko for the MiSTer SNES core, this SystemVerilog implementation is highly optimized, cycle-accurate, and extensively verified. It successfully emulates the highly critical timings and DMA operations of the Super Nintendo. It operates at high frequencies, making it the most stable candidate for C64 core integration.
- **jmstein7 Soft Core**: Written primarily in VHDL, this design is configured as a system-on-a-chip with an embedded serial RAM driver. While functional, it has only been verified up to 7 MHz on low-end Spartan or Artix FPGAs.
- **ProxyPlayerHD 65CE816 Core**: This core is a hybrid design combining 65CE02 instructions with 65C816 architecture. Requires specialized microcode compilation tables and has not been widely verified outside basic Altera DE2 dev boards.

Due to its reliability and proven performance under high-speed synthesis on Cyclone V FPGAs, the srg320 core is the recommended choice.

## Asynchronous Multi-Clock Domain and Wait-State Engineering

Achieving stable execution at 20 MHz or higher within the MiSTer C64 core requires establishing a decoupled, asynchronous multi-clock domain architecture. Simply raising the global clock frequency of the standard core causes timing violations, because the C64's components — such as the VIC-II and the CIA I/O chips — require a fixed, synchronous 1.023 MHz clock (PAL) or 1.022 MHz clock (NTSC).

### The Asynchronous Clock Bridge

The system must run on two independent clock domains generated by the FPGA's internal Phase-Locked Loops (PLLs):

- `clk_sys`: The standard C64 system clock, operating at ~1.023 MHz (PAL).
- `clk_cpu`: An independent, high-frequency clock dedicated to the 65C816 soft-core, running at 20 MHz or higher.

Because these clocks are completely asynchronous, any data or control signal passing between them must traverse a clock-domain crossing (CDC) synchronizer to prevent metastability. For simple static control signals, multi-stage flip-flop synchronizers are sufficient. However, address and data bus transactions require a handshaking protocol or a dual-port FIFO bridge.

Asynchronous Domain Interaction:
```
+-------------------------+                  +---------------------------+
|                         |                  |                           |
|  +-------------------+  |                  |    +-----------------+    |
|  |  srg320 65C816    |  |                  |    |  VIC-II, SIDs,  |    |
|  |  Processor Core   |  |                  |    |  CIAs, IO Ports |    |
|  +-------------------+  |                  |    +-----------------+    |
|           |             |                  |             ^             |
|           v             |                  |             |             |
|  +-------------+        |                  |      +-------------+      |
|  | Wait-State  |        |                  |      | CDC Bridge  |      |
|  | Controller  |        |                  |      | (Sync Regs) |      |
|  +-------------+        |                  |      +-------------+      |
|           |             |                  |             |             |
+-----------|-------------+                  +-------------|-------------+
            |                                              |
            +----------------------------------------------+
                    - Double-buffered control flags
                    - Bidirectional data registers
                    - Wait-State controller (asserts RDY)
```

### The Wait-State Generator

When the 65C816 executes instructions residing in the fast RAM space (simulating the SuperRAM), it runs at the maximum speed of `clk_cpu` without wait states. However, when the processor addresses slower C64 resources — such as the video registers, the SID sound chips, or unoptimized memory regions — it must stall until the slow clock domain completes the transfer.

This stalling is managed by a hardware wait-state generator that asserts the CPU's `RDY` pin low to freeze execution. The timing formula for the minimum duration of the wait state is:

```
wait_cycles = ceiling(clk_cpu / clk_sys) + CDC_overhead
```

where `clk_cpu` is the accelerated clock frequency, `clk_sys` is the 1.023 MHz C64 system clock, and `CDC_overhead` represents the extra cycles required by the CDC synchronization pipeline. At 20 MHz, `CDC_overhead` is approximately 20 to 24 cycles; if the core is overclocked to 40 MHz, the wait state increases to 40 to 44 cycles.

A critical optimization lesson from the Roßmöller Flash 8 must be addressed here: if the processor is executing a write-modify-read instruction on a slow register, the write must write to both the slow bus and the fast local cache simultaneously to ensure the VIC-II can read the updated data immediately without screen tearing.

### Memory Partitioning and High-Speed Cache Allocation

The Intel Cyclone V FPGA on the DE10-Nano contains embedded memory blocks (M10K blocks) and interfaces with high-speed external SDR or DDR3 memory. To achieve stable 20 MHz performance, the memory map must be partitioned based on access speed:

- **Fast RAM (Bank 0 Zero Page & Stack)**: The Zero Page and Stack ($0000–$01FF) are accessed on almost every instruction. These regions should be mapped to fast, dual-port FPGA Block RAM (BRAM) operating on the `clk_cpu` domain. This allows the CPU to perform these accesses with zero wait states.
- **SuperRAM Emulation (Banks 1–255)**: The higher address banks represent the expanded SuperRAM. This area must be mapped to the high-speed external SDRAM of the MiSTer platform, completely decoupled from the C64's 1.023 MHz memory cycles.
- **Main C64 RAM (Bank 0 General)**: The remainder of Bank 0 represents the standard C64 RAM. This area must support mirroring: read operations pull data from the fast local BRAM copy, while write operations update both the local BRAM copy and the slow C64 system RAM across the CDC bridge.

## Memory Mirroring, Caching, and Register-Level Emulation

Replicating the register-level behavior of the SuperCPU is necessary for software-level compatibility. Many C64 programs query specific hardware registers to detect the accelerator and adjust their timing routines.

### Register Precision and Detection Bugs

A prominent issue in early hardware recreation designs (such as the Ultimate 64 running firmware 3.14) was a register visibility bug: the SuperCPU detection registers were only exposed when "turbo control" was set to manual mode and a speed greater than 1 MHz was selected. On a real CMD SuperCPU, the detection and configuration registers are always visible, even when the unit's speed switch is toggled to its 1 MHz normal position.

To ensure absolute compatibility, the MiSTer core must map the registration blocks exactly:

1. **Detection Check**: When a program queries bit 7 of the DOS/RAMLink status register ($D0BC), the core must return a logical 0 to signal that a SuperCPU is present. If disabled, it must return a floating-bus 1.
2. **Physical Switch Emulation**: Register $D0B5 bit 6 represents the physical position of the speed switch. This bit must operate independently of the current execution speed. When the OSD menu sets the speed switch to "Normal," $D0B5 bit 6 reads as 1, locking the CPU at 1 MHz. If the switch is toggled to "Turbo," $D0B5 bit 6 reads as 0, allowing the CPU to transition dynamically between 1 MHz and 20 MHz via software commands.
3. **Speed Override Handlers**: Writing to $D07A must instantly drop the CPU to 1 MHz (normal mode), while writing to $D07B must immediately restore 20 MHz (turbo mode). If the physical switch is set to "Normal," a write to $D07B is accepted and stored in the configuration registers, but the CPU remains locked at 1 MHz until the physical switch is toggled back to "Turbo".

SuperCPU Hardware Speed Control State Machine:
```
                     +---------------------------------------+
                     |             Core Power-On             |
                     |  - Detect Switch Position ($D0B5 b6)  |
                     +---------------------------------------+
                                         |
                                         v
                      /-------------------------------------\
                     <   Physical Speed Switch Position?     >
                      \-------------------------------------/
                        /                                 \
               Normal  /                                   \ Turbo
                      v                                     v
         +--------------------------+          +---------------------------+
         |     Lock at 1 MHz        |          |   Run at 20 MHz (Default) |
         | - Software register writes|         | - Software writes can     |
         |   are stored but ignored |          |   switch between 1-20 MHz |
         | - $D0B5 bit 6 = 1        |          | - $D0B5 bit 6 = 0         |
         +--------------------------+          +---------------------------+
                      |                                     |
                      | Switch toggled                      | Switch toggled
                      +----------------><-------------------+
```

### Write-Through Caching Logic

To support advanced mirroring configurations controlled by register $D0B3, the core must handle write-through caching on the local BRAM:

- **Write Cycle**: When a write instruction target is decoded within an optimized memory block (configured via $D0B3), the core writes the data to the fast local BRAM copy in the `clk_cpu` domain and sends an asynchronous write command to the Slow C64 system bus. The CPU continues running at full speed without waiting for the slow cycle to complete.
- **Read Cycle**: When a read instruction target is decoded within an optimized block, the data is pulled directly from the local high-speed BRAM, completing the cycle with zero wait states.

## Alternative Emulation Paradigms and Reference Software

When designing hardware-level FPGA cores, it is valuable to study how established software emulators and hardware replacements handle acceleration. These implementations provide tested reference models for register timing and bus synchronization.

### Software Emulation: VICE and Kernal64

The Versatile Commodore Emulator (VICE) includes a dedicated program, `xscpu64`, designed specifically to emulate the C64 expanded with the CMD SuperCPU. In the Libretro framework, `vice_xscpu64` loads external BIOS images — such as `scpu-dos-1.4.bin` or `scpu-dos-2.04.bin` — into its virtual memory space, allowing it to accurately model 65C816 instructions and register behaviors.

Another mature software emulator is Kernal64, written in Java. Kernal64 provides a detailed reference implementation of the SuperCPU, simulating up to 16 MB of SIMM memory and partial 1 MHz mode slowdowns during I/O accesses. It includes a virtual LED panel displaying critical processor states:

- **Native Mode**: Active when the 65816 is running in native 16-bit mode rather than 8-bit emulation mode.
- **20 MHz Active**: Indicating whether the turbo mode is currently engaged.
- **JiffyDOS Status**: Displaying JiffyDOS speed routine engagement.
- **SIMM Usage**: A real-time monitor showing the percentage of expanded RAM accessed by the active program.

The register-handling code within these open-source projects serves as a valuable software reference for verifying the correctness of register transitions inside the FPGA core.

### Co-processor Acceleration: The MicroCore Labs MCL64

A different hardware-based approach is demonstrated by MicroCore Labs' MCL64 project. The MCL64 is a physical drop-in socket replacement for the MOS 6510 CPU on a real C64 motherboard. It uses a Teensy 4.1 microcontroller running a dual-issue superscalar ARM processor at 600 MHz to emulate the 6510.

When cycle-accurate mode is disabled and the C64 memory ranges are cached inside the microcontroller's 1 MB of onboard RAM, the MCL64 emulates the CPU at speeds equivalent to a 600 MHz processor. Under this configuration, basic loops run approximately twice as fast as on a 20 MHz SuperCPU.

MCL64 Offloaded Coprocessor Design:
```
+-------------------------------------------------------------+
|               Real C64 Motherboard Socket                   |
|                              ^                              |
|                              | Physical Bus Pins            |
|                              v                              |
|               MCL64 Teensy 4.1 Microcontroller              |
|  +--------------------+             +--------------------+  |
|  |   600 MHz ARM M7   |             |  1 MB Onboard RAM  |  |
|  |  (6510 Emulation)  |<----------->|  (Cached Memory)   |  |
|  +--------------------+             +--------------------+  |
+-------------------------------------------------------------+
Locates memory internally to execute loops 2x faster than SuperCPU.
```

While the MCL64 represents a physical coprocessor that caches memory internally to achieve extreme speeds, the MiSTer platform must achieve a similar result purely within the FPGA fabric.

By using the Cyclone V's high-speed internal fabric to run the srg320 65C816 core, the MiSTer core can easily match or exceed the 20 MHz performance of the original SuperCPU while maintaining complete system integration.

## Detailed Step-by-Step Engineering Roadmap

Implementing 16-bit SuperCPU acceleration within the official MiSTer C64 core requires a structured, phased approach to manage the design complexity.

Engineering Core Integration Pipeline:
```
+------------------------------------------------------------+
| Phase 1: Core Incorporation & Clock Domain Setup           |
| - Import srg320 65C816 SystemVerilog core.                 |
| - Define clk_cpu pll output (20 MHz or 40 MHz).            |
+------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------+
| Phase 2: Asynchronous Bus Bridge & Wait-State Controller   |
| - Connect RDY pin to the wait-state generator.             |
| - Set up address-decoding logic for fast/slow buses.       |
+------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------+
| Phase 3: Hardware Register & Caching Implementation        |
| - Implement register mapping for $D074 to $D0BC block.     |
| - Set up write-through cache for the Zero Page and Stack.  |
+------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------+
| Phase 4: Integration and Regression Testing                |
| - Load SuperCPU BIOS and test with Vision BASIC.           |
| - Validate performance with Doom and Metal Dust.           |
+------------------------------------------------------------+
```

### Phase 1: Core Incorporation and Clock Domain Setup

1. **Repository Setup**: Clone the official C64_MiSTer repository. Copy the srg320 SNES 65C816 core source files into the core's RTL directory.
2. **Clock Generation**: Locate the primary Phase-Locked Loop (PLL) configuration in the top-level entity (typically `c64.vhd` or `fpga_top.v`). Add a new output clock, `clk_cpu`, and configure it to run at a base frequency of 20 MHz. To support overclocking options in the OSD menu, define a second PLL output at 40 MHz.
3. **Core Multiplexing**: Create a conditional instantiation block in the CPU socket area. Use an OSD menu flag to select between the standard 6510 core and the new srg320 65C816 core.

### Phase 2: Asynchronous Bus Bridge and Wait-State Controller

1. **RDY Pin Mapping**: Connect the RDY input pin of the srg320 core to the output of a new wait-state generator module.
2. **Address Decoding**: Implement address-decoding logic in the `clk_cpu` domain. If the CPU accesses the fast local BRAM or the expanded SDRAM space, keep the RDY pin high to execute with zero wait states. If the access falls within slow C64 ranges (such as I/O space at $D000–$DFFF), pull RDY low and assert the synchronization flag.
3. **CDC Synchronization**: Set up double-buffered synchronization registers to pass address, data, and write-enable states securely across the boundary between `clk_cpu` and `clk_sys`. Ensure the wait-state generator holds RDY low until the slow clock domain signals that the bus transaction has completed.

### Phase 3: Hardware Register and Caching Implementation

1. **Register Map**: Implement the SuperCPU register control block, mapping the configuration registers from $D074 through $D0BC. Ensure bit 7 of register $D0BC defaults to 0 when SuperCPU acceleration is active to support standard detection routines.
2. **OSD Control Mapping**: Bind the physical speed switch emulation to an option in the MiSTer On-Screen Display (OSD) menu. Ensure that selecting "Normal" sets $D0B5 bit 6 to 1 and locks the CPU at 1 MHz, while selecting "Turbo" sets $D0B5 bit 6 to 0 and enables high-speed mode.
3. **BRAM Cache Implementation**: Instantiate a dual-port M10K Block RAM module to cache Bank 0's Zero Page and Stack ($0000–$01FF). Implement a write-through cache policy: any write operation updates both the local BRAM copy and the slow C64 system RAM across the CDC bridge, while read operations pull data instantly from the local BRAM copy.

### Phase 4: Integration and Regression Testing

1. **Register Visibility Verification**: Boot the C64 core to the standard BASIC prompt and query bit 7 of register $D0BC. Ensure the bit reads as 0. Verify that writing to $D07A drops the CPU to 1 MHz and writing to $D07B restores 20 MHz execution.
2. **Vision BASIC Validation**: Load the Vision BASIC compiler. Verify that compilation routines run significantly faster on the accelerated core than on a stock 1 MHz system.
3. **Complex Software Testing**: Run high-overhead, SuperCPU-exclusive software. Run the 65C816-optimized port of *Doom* (requiring a 16-bit CPU and 16 MB of RAM) and the shoot-'em-up *Metal Dust*. Monitor the gameplay for screen tearing, sound crackling, or system instability to ensure the clock synchronization bridge is operating reliably.

## Future Outlook: The 32-Bit Paradigm and Enhanced C64 Modes

Adding SuperCPU emulation to the MiSTer C64 core provides a foundation for extending the platform beyond historical limits. With the logic capacity of the Cyclone V FPGA, developers can implement enhanced operating modes that combine the simplicity of 8-bit systems with modern hardware capabilities.

These enhanced modes can be accessed via a specific sequence of hardware register writes. When a program writes a proprietary signature byte to a reserved configuration register, the core transitions into an "Enhanced C64 Mode," unlocking access to:

- A 32-bit address space using the Mike Kohn open-source W65C832 soft-core.
- Expanded linear system RAM (up to 16 MB) mapped directly into Bank 0, bypassing traditional bank-switching bottlenecks.
- High-color video modes and expanded hardware sprite registers.
- An accelerated system clock (up to 50 MHz), providing performance that exceeds physical 1990s hardware.

By combining accurate SuperCPU emulation with forward-looking extensions, developers can preserve retrocomputing history while creating a high-performance environment for modern 8-bit and 16-bit hardware design.
