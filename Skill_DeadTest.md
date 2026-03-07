# Dead Test Cartridge Skill

Build and deploy the C64 Dead Test diagnostic cartridge (with SuperCPU tests).

## What It Is

The dead test (`tools/kick-c64-dead-test/`) is a comprehensive C64 hardware
diagnostic that runs as an Ultimax cartridge. It tests RAM, ROM, SID, color RAM,
and (with our additions) SuperCPU 65C816 functionality. Based on
[stid/kick-c64-dead-test](https://github.com/stid/kick-c64-dead-test).

## Prerequisites

- **Java**: Eclipse Temurin JRE 21 at `C:\Program Files\Eclipse Adoptium\jre-21.0.10.7-hotspot\`
  - Install: `winget install EclipseAdoptium.Temurin.21.JRE`
- **KickAssembler**: v5.25 at `C:\LLM\C64\tools\KickAssembler\KickAss.jar`
  - Download: http://theweb.dk/KickAssembler/KickAssembler.zip
- **Python 3**: For CRT packaging (replaces VICE `cartconv`)

## Build

```powershell
# Assemble
& "C:\Program Files\Eclipse Adoptium\jre-21.0.10.7-hotspot\bin\java.exe" `
  -jar "C:\LLM\C64\tools\KickAssembler\KickAss.jar" `
  -odir "../bin" -showmem main.asm

# Convert PRG to CRT (from tools/kick-c64-dead-test/src/)
python ..\prg_to_crt.py
```

Or as a single bash command:

```bash
JAVA="/c/Program Files/Eclipse Adoptium/jre-21.0.10.7-hotspot/bin/java.exe"
KICKASS="/c/LLM/C64/tools/KickAssembler/KickAss.jar"
cd tools/kick-c64-dead-test/src
"$JAVA" -jar "$KICKASS" -odir "../bin" -showmem main.asm
python ../prg_to_crt.py
```

## Output Files

| File | Description |
|------|-------------|
| `bin/main.prg` | KickAssembler output (PRG with $E000 load address) |
| `bin/dead-test.crt` | Ultimax CRT file (load via MiSTer OSD) |
| `bin/dead-test.bin` | Raw 8KB ROM (for EPROM burning) |
| `bin/main.sym` | Symbol table for debugging |

## Deploy to MiSTer

```powershell
scp .\tools\kick-c64-dead-test\bin\dead-test.crt root@192.168.50.130:/media/fat/
```

Then on MiSTer: OSD (F12) > Load cartridge > `dead-test.crt`

## Test Sequence

The cartridge runs these tests in order:

1. **Memory Bank Test** — black screen ~10s (initial RAM verification)
2. **Layout Drawing** — screen appears after RAM passes
3. **Zero Page Test** — $00-$FF
4. **Stack Page Test** — $0100-$01FF (enables JSR/RTS from here on)
5. **Screen RAM Test** — $0400-$07FF
6. **Color RAM Test** — $D800-$DBFF
7. **General RAM Test** — $0800-$0FFF
8. **Font Test** — character ROM verification
9. **Sound Test** — SID oscillators
10. **Filter Test** — SID filters
11. **SCPU Test** — SuperCPU diagnostics (see below)

Border color cycles on each iteration. Tests run continuously with an iteration counter.

## SuperCPU Tests (scpu_test.asm)

If SuperCPU is not enabled in OSD, test 1 shows **SKIP** (yellow) and the rest are skipped.
With SuperCPU enabled, 8 sub-tests run on screen row 7:

| # | Test | Pass | Fail |
|---|------|------|------|
| 1 | SuperCPU detect ($D0BC == $C9) | OK | SKIP (exits) |
| 2 | Mode register ($D0B0 == $40) | OK | BAD |
| 3 | Native mode switch (CLC+XCE round-trip) | OK | BAD |
| 4 | 16-bit accumulator (REP #$20, LDA #$5AA5) | OK | BAD |
| 5 | 16-bit index (REP #$10, LDX #$1234) | OK | BAD |
| 6 | SuperRAM write/read (STA/LDA long $01:0800) | OK | BAD |
| 7 | SuperRAM bank isolation ($00 vs $01) | OK | BAD |
| 8 | Speed register ($D07A bit 5 write/read) | OK | BAD |

Results: **OK** = green, **BAD** = red, **SKIP** = yellow.

## Source Structure

```
tools/kick-c64-dead-test/
  src/
    main.asm             — Entry point, vectors
    main_loop.asm        — Test orchestration
    scpu_test.asm        — SuperCPU test module (our addition)
    layout.asm           — Screen layout
    macros.asm           — Delay macros
    mem_map.asm          — Hardware register definitions
    data.asm             — Test patterns, font, strings
    *_test.asm           — Individual hardware tests
  bin/                   — Build output (not committed)
  prg_to_crt.py         — PRG-to-CRT converter
```

## KickAssembler and 65C816

KickAssembler does NOT support 65C816 CPU mode (only up to 65C02).
All 65816 opcodes in `scpu_test.asm` are emitted as raw `.byte` sequences:

```
.byte $fb               // XCE — exchange carry and emulation
.byte $c2, $20          // REP #$20 — 16-bit accumulator
.byte $e2, $20          // SEP #$20 — 8-bit accumulator
.byte $8f, lo, hi, bank // STA long $bank:hilo
.byte $af, lo, hi, bank // LDA long $bank:hilo
```

## ROM Space

The 8KB Ultimax ROM ($E000-$FFFF) is nearly full:
- Original dead test: $E000-$EDCA
- SCPU test module: $EDCB-$FFF9
- Vectors: $FFFA-$FFFF

Adding more tests would require optimizing existing code or splitting into
a separate SCPU-only cartridge.
