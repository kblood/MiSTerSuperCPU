# SCPU VIC Read Test Cartridge

Ultimax-mode diagnostic CRT files that definitively test whether the '@' artifact
is a VIC-II read-side data corruption or a KERNAL/workload-specific issue.

See `HYPOTHESIS_TRACKER.md` in the repo root for full context.

## The Problem

With SuperCPU enabled + standard KERNAL, the screen fills with scrolling '@'
characters (screencode $00). This could be:

- **H23/H27**: SDRAM `dout_r` is clobbered between when the c-access data is
  read at CPUC and when VIC latches it at the next VIC2 cycle
- **H24**: RAM genuinely contains $00 (CPU path initialized it that way)
- **H25**: Workload/timing sensitivity — KERNAL-specific behavior

## How This Test Works

The cartridge (Ultimax mode: EXROM=1, GAME=0) runs entirely from ROM at
`$E000-$FFFF`, bypassing the KERNAL completely. It:

1. Fills screen RAM (`$0400-$07FF`) with `$01` ('A' screencode)
2. Fills color RAM (`$D800-$DBFF`) with white (`$01`)
3. Loops forever: CPU reads back every screen byte and checks for `$01`
   - **Green border**: CPU reads correct data (RAM is fine)
   - **Red border**: CPU reads wrong data (something is corrupting RAM)

## Interpreting Results

| What you see | What it means |
|---|---|
| All 'A' on screen + GREEN border | No '@' without KERNAL → bug is KERNAL/workload-specific (H25) |
| '@' mixed in + GREEN border | VIC reads $00, CPU reads $01 → **H23/H27 CONFIRMED** — SDRAM dout_r clobbered |
| '@' mixed in + RED border | CPU also reads $00 → write-side or RAM init bug |

## Build

Requires Python 3 only — no assembler needed.

```powershell
cd C:\LLM\C64\MiSTerSuperCPU

# Test 1: Fill & Verify (definitive H23 vs H24 test)
python tools\test_cart\gen_scpu_test.py

# Test 2: Bus Stress variant (CIA1 I/O hammering during verify loop)
python tools\test_cart\gen_scpu_test.py --stress
```

Output files are placed in `tools/test_cart/out/`.

## Deploy to MiSTer

```powershell
# Deploy basic test
wsl scp -o StrictHostKeyChecking=no \
  /mnt/c/LLM/C64/MiSTerSuperCPU/tools/test_cart/out/scpu_vic_test.crt \
  root@192.168.50.130:/media/fat/

# Deploy stress test
wsl scp -o StrictHostKeyChecking=no \
  /mnt/c/LLM/C64/MiSTerSuperCPU/tools/test_cart/out/scpu_vic_stress.crt \
  root@192.168.50.130:/media/fat/
```

Then on MiSTer:
- F12 (OSD) → Load Cartridge → `scpu_vic_test.crt`
- Ensure SuperCPU is **ENABLED** in OSD to reproduce the artifact condition
- Toggle SuperCPU ON/OFF to compare behavior

## Test Sequence

1. Load `scpu_vic_test.crt` with **SuperCPU OFF** — establish baseline
2. Load `scpu_vic_test.crt` with **SuperCPU ON** — check for '@' + observe border
3. Load `scpu_vic_stress.crt` with **SuperCPU ON** — extra I/O bus stress
4. Load `scpu_vic_test.crt` with **SuperCPU OFF** — confirm baseline unchanged

## Source Files

| File | Description |
|---|---|
| `gen_scpu_test.py` | Generator: assembles 6502 machine code + wraps in Ultimax CRT |
| `out/scpu_vic_test.crt` | Basic Fill & Verify test |
| `out/scpu_vic_test.bin` | Same, as raw 8KB ROM |
| `out/scpu_vic_stress.crt` | Bus Stress variant (CIA1 hammering) |
| `out/scpu_vic_stress.bin` | Same, as raw 8KB ROM |

## CRT Format Details

```
Offset  Size  Value       Description
0       16    "C64 CARTRIDGE   "  CRT signature
16      4     64          Header length
20      2     0x0100      Version 1.0
22      2     0           Hardware type (generic)
24      1     1           EXROM = 1 (Ultimax)
25      1     0           GAME  = 0 (Ultimax)
32      32    name        Cartridge name
64      4     "CHIP"      CHIP packet signature
68      4     8208        Packet total length (16 + 8192)
72      2     0           Chip type: ROM
74      2     0           Bank 0
76      2     0xE000      Load address
78      2     0x2000      ROM size (8192 bytes)
80      8192  code+$AA    ROM data; unused bytes = $AA
```
