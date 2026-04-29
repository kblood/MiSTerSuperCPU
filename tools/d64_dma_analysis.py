#!/usr/bin/env python3
"""
Focused analysis: What is the BEQ loop at $82E0 actually doing?

From UART: A:82E0 D:00 B:00 P:37 I:F0 E:0
- I:F0 = BEQ opcode at PC=$82E0
- D:00 = data bus at sample time
- P:37 = processor flags (M=1, X=1, I=1, Z=1, C=1)
- E:0 = native 65C816 mode
- B:00 = bank 0

P:37 = 0011_0111
  bit 7 N=0  (positive)
  bit 6 V=0  (no overflow)
  bit 5 M=1  (8-bit accumulator)
  bit 4 X=1  (8-bit index)
  bit 3 D=0  (binary mode)
  bit 2 I=1  (IRQs DISABLED)
  bit 1 Z=1  (zero flag SET)
  bit 0 C=1  (carry set)

With Z=1, BEQ always branches. The CPU is in a tight BEQ loop.

Common SuperCPU demo patterns for raster wait loops:
1. LDA $D012; CMP #$xx; BNE *-5  (wait for raster line)
2. LDA $D011; BPL *-3  (wait for bit 7 of control register)
3. BIT $D011; BPL *-3  (wait for VIC bit)
4. LDA zeropage; BEQ *-3  (wait for IRQ handler to set flag)
5. DEC counter; BEQ *-2  (countdown, but Z=1 means stuck)

The pattern at $82E0 with BEQ looping (Z=1) and IRQs disabled (I=1)
is most likely pattern #4 or a custom wait:
  - Load from some address (gets 0 → Z=1)
  - BEQ back to the load instruction

Possible code sequences:
  a) $82DE: LDA $xx; $82E0: BEQ $82DE (wait for ZP location change by DMA/NMI)
  b) $82DD: LDA $xxxx; $82E0: BEQ $82DD (wait for abs memory change)
  c) $82DC: LDA $xxxxxx; $82E0: BEQ $82DC (wait for long address change)
  d) $82DF: LDA ($xx); $82E0: BEQ $82DF (wait via indirect)
  e) $82DF: BIT $xx; $82E0: BEQ $82DF (wait for ZP bit)
  f) Custom patterns with other instructions before BEQ

Key insight: SuperCPU DMA runs independently of the CPU!
The "!/DMA" in the demo name suggests it uses SuperCPU DMA transfers.
The DMA hardware would write to memory, and the CPU polls waiting for
the DMA to complete or for the DMA to write a specific value.

SuperCPU DMA mechanism:
- Write source address to $D071-$D073
- Write dest address to $D074-$D076
- Write length to $D077-$D078
- Write command to $D070 (or $D079?) to start DMA
- DMA status at $D077 (bit 7 = DMA in progress?) or polling a memory location

Since our MiSTer core doesn't implement SuperCPU DMA ($D070-$D078 are mapped
to our debug registers), any write to start DMA does nothing, and the CPU
polls forever waiting for the DMA to complete.

The demo name "SCPU KICKS !/DMA" literally tells us this demo uses DMA.

CONCLUSION: The demo is stuck in a DMA completion wait loop because our
MiSTer SuperCPU implementation does not implement the DMA transfer engine.
The BEQ at $82E0 is polling a memory location or register that the DMA
hardware would have modified upon completion.
"""

print(__doc__)

# Let's also check what SuperCPU DMA looks like
print("="*70)
print("SUPERCPU DMA REGISTER MAP (Real Hardware)")
print("="*70)
print("""
Register  Read           Write
$D070     Error addr     SIMM configuration
$D071     Source[7:0]    Source[7:0]
$D072     Source[15:8]   Source[15:8]
$D073     Source[23:16]  Source[23:16]
$D074     Dest[7:0]     Dest[7:0]
$D075     Dest[15:8]    Dest[15:8]
$D076     Dest[23:16]   Dest[23:16]
$D077     Length[7:0]    Length[7:0]
$D078     DMA Status     DMA Command/Start

DMA Command byte ($D078 write):
  Bit 0: Direction (0=forward, 1=backward)
  Bit 1: Source type (0=RAM, 1=I/O)
  Bit 2: Dest type (0=RAM, 1=I/O)
  Writing to $D078 starts the DMA transfer.

DMA Status byte ($D078 read):
  Bit 7: DMA busy (1=transfer in progress)
  Other bits: version/status info

Typical DMA usage in a SuperCPU demo:
  LDA #src_lo:  STA $D071
  LDA #src_hi:  STA $D072
  LDA #src_bnk: STA $D073
  LDA #dst_lo:  STA $D074
  LDA #dst_hi:  STA $D075
  LDA #dst_bnk: STA $D076
  LDA #len_lo:  STA $D077
  LDA #cmd:     STA $D078   ; starts transfer
wait:
  LDA $D078               ; read status
  BMI wait                 ; bit 7 = busy, loop while negative
  ; or:
  BIT $D078
  BMI wait

OR the demo might poll a dest memory location:
  LDA dest_flag
  BEQ wait                 ; wait for DMA to write non-zero

With I=1 (IRQs disabled) and Z=1, the likely pattern is:
  - The code wrote DMA registers to start a transfer
  - Then entered a poll loop checking either $D078 (DMA status)
    or a destination memory location
  - Since DMA is not implemented, the status/memory never changes
  - Z stays 1, BEQ keeps looping

OUR FIX OPTIONS:
1. Implement DMA engine ($D070-$D078) in the FPGA
2. Fake DMA completion: make $D078 reads return $00 (not busy)
   - This would break the demo differently (it expects data to be moved)
3. Implement a simple DMA that copies RAM to RAM via SDRAM
""")

# Show what our current register map looks like at $D070-$D078
print("="*70)
print("CURRENT MISTER IMPLEMENTATION at $D070-$D078")
print("="*70)
print("""
Our MiSTer SuperCPU core currently uses $D070-$D073 for DEBUG registers:
  $D070: debug counter low byte
  $D071: debug counter high byte
  $D072: debug register 2
  $D073: debug register 3

$D074-$D078 are likely unmapped (return open bus / VIC data).

This CONFLICTS with the real SuperCPU DMA register map!
To run DMA-using demos, we need to either:
  a) Relocate our debug registers elsewhere (e.g., $D040-$D043)
  b) Implement actual DMA at $D070-$D078
  c) At minimum, make $D078 reads return $00 (DMA idle/not busy)
     to let the demo past the wait loop (though DMA data won't be moved)
""")
