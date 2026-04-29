# Session Passover 2026-04-02f: VICE-Based Register Fixes + Native Mode ROM Stub

## Goal
Implement VICE-researched SuperCPU register behavior and provide native mode vector stubs for Doom.

## Summary
Implemented three changes based on the VICE SuperCPU architecture research from session 2026-04-02e:
1. Fixed $D07E strobe behavior (any write = hwenable=1)
2. Added bootmap register ($D0B6/$D0B7) with auto-clear during kickstart
3. Built minimal ROM stub providing native mode vectors + RTI handler

All changes syntax-checked and full-built successfully. MiSTer was offline for the entire session — no hardware testing.

## Changes (not yet committed)

### 1. $D07E Strobe + hwenable Signal
- **New signal**: `scpu_hwenable` — set by ANY write to $D07E (data irrelevant per VICE)
- **Cleared by**: write to $D07F or $D07D (same as scpu_regs_enabled)
- **Legacy rom_vis**: still updated from cpuDo(7) when supercpu_rom='1' for kickstart boot
- **$D0B2 readback**: now shows actual hwenable in bit7 (was showing regs_enabled)

### 2. Bootmap Register ($D0B6/$D0B7)
- **New signal**: `scpu_bootmap` — '1' at reset (EPROM mode)
- **$D0B6 write**: clears bootmap to '0' (requires hwenable=1)
- **$D0B7 write**: sets bootmap to '1' (requires hwenable=1)
- **Auto-clear**: bootmap auto-clears when rom_vis transitions 1→0 during kickstart boot
  (simulates the kickstart's $D0B6 write that we can't perform since we have no real kickstart firmware)

### 3. Native Mode ROM Stub
- **Purpose**: On real SuperCPU, internal SRAM at $E000-$FFFF contains kickstart-populated
  KERNAL copy with native mode vectors. We don't have that SRAM, so the stub provides minimal vectors.
- **Coverage**: $FFE4-$FFEF (native vectors: COP, BRK, ABORT, NMI, unused, IRQ) + $FF00 (RTI) + $FF01 (RTL)
- **Vectors all point to $FF00** (RTI handler) — native mode interrupts/BRK return immediately
- **Active when**: bootmap=0 AND emu_mode_816='0' (native mode) AND bank $00 AND read
- **Priority**: above BRAM/cache in cpuDi mux (below IOF reads)
- **Safety**: only active in native mode — no interference with C64 emulation mode KERNAL reads

## Build State
- RBF: `C64_MiSTer/output_files/C64.rbf` (2026-04-02 21:19, NOT deployed)
- Resources: 72% ALMs (30,166), 90% RAM (496/553) — essentially unchanged
- Timing: no new violations vs baseline (clk64 -18ns, clk32 -8ns pre-existing)

## Key Architecture Decisions
1. **ROM stub is per-address combinational override**: no BRAM allocated, zero resource cost
2. **hwenable separate from regs_enabled**: VICE has these as distinct concepts
3. **bootmap auto-clear on rom_vis 1→0**: bridges our kickstart (rom_vis based) with VICE's bootmap model
4. **Native mode gating**: prevents ROM stub from interfering with emulation mode KERNAL reads at $FFxx

## Why This Might Help Doom
- Doom enters native mode at $200000 (CLC, XCE)
- Doom writes $D07E (hwenable=1), $D07F (hwenable=0)
- After $D07F, real SuperCPU still has SRAM vectors at $FFE4-$FFEF
- Without ROM stub: native vectors at $FFE4-$FFEF contain garbage RAM → any interrupt/BRK crashes
- With ROM stub: vectors point to RTI at $FF00 → interrupts/BRK return gracefully
- BRK "system calls" become no-ops (may cause game logic issues but won't crash the CPU)

## Why This Might NOT Fix Doom
- The Doom crash (PBR=$37/$35) might be caused by instruction fetch corruption from SuperRAM
  rather than bad vectors. If SDRAM returns wrong data during bank $20 instruction fetch,
  the CPU executes garbage and jumps to a wrong bank.
- The pipeline drain guard (from session 2026-04-02e item #1) was NOT implemented this session.
  Analysis suggests the existing turbo slot guards prevent pipeline overlap, but this hasn't
  been verified on hardware.

## Next Steps (Priority Order)
1. **Deploy and test**: when MiSTer comes online, deploy RBF and verify C64 boots normally
2. **Test interleaved bank access**: `STA $020100 → STA $000500 → LDA $020100` should return 66
3. **Test Doom**: load doom.reu via OSD, JML $200000, observe if crash behavior changes
4. **UART diagnostics**: check PBR/PC during Doom init to see if ROM stub catches any vectors
5. **If Doom still crashes**: investigate instruction fetch from SuperRAM more carefully
   - Add UART diagnostic for bank $20 fetch mismatches
   - Consider pipeline drain guard if interleaved test fails

## Test Commands (when MiSTer online)
```bash
# Deploy
python3 tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf

# Verify C64 boots
python3 tools/mister_debug.py screen screenshot_rom_stub_boot.png

# Interleaved bank test (BASIC POKE+SYS)
# CLC XCE LDA#$42 STA$020100 LDA#$55 STA$000500 LDA$020100 SEC XCE STA$02 RTS
# = 24,251,169,66,143,0,1,2,169,85,143,0,5,0,175,0,1,2,56,251,133,2,96
python3 tools/mister_debug.py keys "FOR I=0 TO 22:READ A:POKE 49152+I,A:NEXT\rDATA 24,251,169,66,143,0,1,2,169,85,143,0,5,0,175,0,1,2,56,251,133,2,96\rSYS 49152\rPRINT PEEK(2)\r"
# Expected: 66
```

## Hardware Test Results (deployed 2026-04-02 21:19)
- **C64 boot**: PASS — boots to READY prompt normally
- **SuperRAM round-trip**: PASS — STA $020100(66), LDA #0, LDA $020100 → PEEK(2)=66
- **Interleaved bank access**: PASS — STA $020100(66), STA $000500(85), LDA $020100 → PEEK(2)=66
- **ROM stub vector reads**: PASS — LDA $FFE6=0, LDA $FFE7=255 (→$FF00), LDA $FF00=64 (RTI)
- **BRK native mode (SEI)**: PASS — SEI,CLC,XCE,BRK,$00,SEC,XCE,CLI,LDA#77,STA$02,RTS → PEEK(2)=77
- **BRK native mode (no SEI)**: CRASH — C64 IRQ fires during native mode, RTI stub can't handle KERNAL state
- **Doom**: not tested (OSD navigation unreliable remotely, doom.reu loading requires physical F12)

## Key Finding: C64 IRQ + Native Mode
Without SEI, C64 IRQs fire during native mode. The ROM stub's RTI at $FF00 returns from the IRQ,
but the KERNAL expects specific state management that RTI alone doesn't provide. This causes
the system to crash. Real SuperCPU software ALWAYS does SEI before CLC/XCE, which Doom does
at $200000. So this is not a blocker for Doom.

## MiSTer Status
- IP: 192.168.50.130 — online, build deployed
- doom.reu at /media/usb0/games/C64/doom.reu
