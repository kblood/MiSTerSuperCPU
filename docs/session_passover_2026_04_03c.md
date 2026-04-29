# Session Passover 2026-04-03c: PBR Crash Trap Debug Build

## Goal
Get Doom fully running on MiSTer SuperCPU. Debugging the deterministic ~180s crash.

## Key Discovery: NOT a Microcode Bug

### STA [dp],Y ($97) Microcode is CORRECT
- Analyzed P65C816 microcode field layout via P65816_pkg.vhd record definition
- OUT_BUS="101" maps to SB bus, which is selected by BUS_CTRL(5:3)
- For $97 steps 6-7: BUS_CTRL(5:3)="000" selects **A (accumulator)**, NOT SP
- BYTE_SEL "01"/"10" correctly select low/high bytes for 16-bit store
- BRK ($00) microcode: correct push sequence (PBR, PCH, PCL, P), PBR<=0 at step 5
- RTI ($40) microcode: correct pull sequence (P, PCL, PCH, PBR), 4 SP increments

### No TCS in Doom Bank $2D
- Searched entire 64KB of bank $2D in doom.reu for $1B (TCS) bytes
- Found only ONE $1B at offset $00E6 — but it's the HIGH BYTE of ADC #$1B84 (16-bit immediate)
- The code at $2D:00E2-$2D:00F2 is a 32-bit address computation + STA [$F4],Y
- SP=$FF2D in crash state is NOT from TCS — comes from another mechanism

## Key Evidence: No Interrupts During Normal Execution
- ALL UART frames before crash show K:2D (PBR=$2D) — CPU never enters bank $00
- S:01FD is constant across all frames — no push/pop activity
- P:A0 has I=0 (interrupts ENABLED) but no interrupt sources are active
  (Doom init: SEI, VIC IRQ off, CIA timers off, CIA masks cleared)
- The PBR $2D→$00 transition at the crash is NOT a normal IRQ/NMI cycle

## PBR Crash Trap (Built, Ready to Deploy)

### What It Does
- Self-clearing trap in fpga64_sid_iec.vhd
- Fires when PBR transitions from non-$00 to $00 (interrupt/BRK/crash)
- Clears when PBR returns to non-$00 (RTI recovery)
- The trap STAYS fired only when PBR goes to $00 and NEVER recovers (= crash)
- When fired, freezes debug outputs to show crash-moment CPU state

### Trapped UART Fields (when trap is active)
- **A:** = cpuAddr_pre at PBR transition (should be vector address: $FFE7=BRK, $FFEB=NMI, $FFEF=IRQ)
- **K:** = PBR before transition (expected $2D for game code)
- **B:** = cpuDi at trap moment (data bus value — vector byte being read)
- **S:** = SP at trap moment (should be original-4 for normal interrupt push)
- **P:** = processor status at trap moment
- **I:** = instruction register ($00 for BRK/interrupt, other for JML etc.)

### How to Interpret Results
- If A:FFE7, I:00 → BRK opcode executed (corrupted instruction fetch = $00 byte)
- If A:FFEF, I:00 → IRQ fired (an interrupt source became active)
- If A:FFEB, I:00 → NMI fired (CIA2 or external NMI)
- If I:not-$00 → PBR changed by an instruction (JML, RTL, etc.)

### Build Details
- **Files modified**: fpga64_sid_iec.vhd (trap signals + logic + display override),
  c64.sv (dbg_cpu_addr_disp wire), debug_uart_fmt uses display address
- **dbg_cpu_addr NOT modified** — SDRAM path is safe
- **Build**: 73% ALMs (30,385), 95% RAM blocks (528/553), fitter successful
- **RBF**: C64_MiSTer/output_files/C64.rbf (ready to deploy)

## Crash Analysis Summary

### Deterministic Data (identical across runs)
| Field | Pre-crash (F:15DF) | Post-crash (F:15E0) |
|-------|-------------------|---------------------|
| A     | 00E4              | 1560                |
| K     | 2D                | 00                  |
| B     | 00                | 04                  |
| S     | 01FD              | FF2D                |
| P     | A0                | 15                  |
| I     | 97                | BF                  |

### Likely Crash Mechanism
1. SDRAM timing violation returns wrong byte during SuperRAM instruction fetch
2. Wrong byte happens to be $00 (BRK opcode)
3. BRK pushes PBR/PC/P, sets PBR=$00
4. BRK vector ($FFE6/$FFE7) → $FF00 (RTI stub)
5. RTI pops P/PC/PBR → returns to bank $2D at PC+2 (skipped signature byte)
6. **PC is now misaligned** — reading operand bytes as opcodes
7. Misaligned stream may contain another BRK, a JML, or instructions that corrupt SP
8. Cascade of misaligned execution → crash

### Why Deterministic
- Same SDRAM address always returns the same wrong byte
- The timing violation path consistently corrupts the same bit
- Once the BRK→misalignment cascade starts, the same bytes are always misinterpreted

### Alternative Theory: Interrupt Source Activation
- Doom code might write to a VIC/CIA register deep in the game loop
- This could accidentally enable an interrupt source
- With I=0, IRQ fires → PBR=$00 → IRQ handler at $FF00 = RTI
- RTI returns but PC is +2 from expected (BRK increments PC twice)
- Same misalignment cascade

## MiSTer Status
- **OFFLINE** — not responding to ping/SSH as of end of session
- Needs physical power cycle or network check
- Build is ready in C64_MiSTer/output_files/C64.rbf

## Test Sequence (When MiSTer Back Online)
```bash
# Deploy
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf

# Load REU + skip loader
python tools/mister_debug.py keys "f12 wait:2 down down down down enter wait:1 down enter"
# Wait 55s for REU load
python tools/mister_debug.py keys '10 FORI=0TO6:READA:POKE49152+I,A:NEXT\r20 DATA120,24,251,92,0,0,32\r30 SYS49152\rRUN\r'

# Monitor UART for ~4 minutes until crash (F:~15DF)
python tools/mister_debug.py uart 300
# After crash, ALL frames will show the TRAP values:
# A: = vector address (FFE7/FFEB/FFEF)
# K: = PBR before crash ($2D)
# B: = cpuDi at crash moment
# I: = $00 if interrupt/BRK
# S: = SP at crash moment
```

## Next Steps (Priority Order)
1. **Deploy and test PBR trap** → determine crash mechanism
2. If BRK ($00 opcode): investigate which cache line or SDRAM address returns $00
   - Add debug to log the SDRAM address + expected vs actual data at crash point
3. If IRQ: find which interrupt source activated
   - Add irq_cia1, irq_vic, irq_n, irq_ext_n to trap output
4. If neither: investigate P65C816 state machine for the specific instruction
5. **Long-term fix**: either fix SDRAM timing or make cache fully cover Doom code
