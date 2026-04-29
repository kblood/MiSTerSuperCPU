#!/usr/bin/env python3
"""Isolate SuperRAM read bug to CPU path vs io_cycle path.

Uses the existing POKE $DF1D → io_cycle SDRAM write test infrastructure
(c64.sv:1143). POKE $DF1D,value writes `value` to SDRAM at bank $02:$0000
(= REU_ADDR + $020000) via the io_cycle path, then auto-triggers an
io_cycle read of the same address into `reu_rb_data` ($DF1B).

Then LDA long $02:$0000 reads the same SDRAM location via the CPU's
SuperRAM 3-stage pipeline → `sdram_superram` → cpuDi.

Compare:
  PEEK($DF1B)  = io_cycle read → reu_rb_data (trusted path)
  PEEK($033C)  = CPU LDA long $02:$0000 → sdram_superram (suspect path)

If iocycle=$AB and cpu=$00 → CPU read path is broken, SDRAM has the data.
If iocycle=$00 and cpu=$00 → io_cycle write didn't reach SDRAM (write bug).
If iocycle=$EE           → readback hasn't completed yet (increase wait).
If iocycle=$AB and cpu=$AB → both paths work (run --deploy again).

Also reads the diagnostic registers $DFE9-$DFEF to show what the SRR
latch captured at the moment of the LDA long.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152  # $C000

# Test byte written via POKE $DF1D
TEST_VAL = 0xAB

# Diagnostic regs
D_DF1B   = 0xDF1B  # 57115 - reu_rb_data
D_CNT_LO = 0xDFE9  # 57321
D_CNT_HI = 0xDFEA  # 57322
D_DAT    = 0xDFEB  # 57323
D_AHI    = 0xDFEC  # 57324
D_CBK    = 0xDFED  # 57325
D_ALO    = 0xDFEE  # 57326
D_AMI    = 0xDFEF  # 57327

# Assembly: enter native, SEP #$30, LDA long $02:$0000, store to $033C, exit
CODE = [
    0x78,                     # SEI
    0x18,                     # CLC
    0xFB,                     # XCE      (emu -> native)
    0xE2, 0x30,               # SEP #$30
    0xAF, 0x00, 0x00, 0x02,   # LDA $020000  (LDA long $02:$0000)
    0x8D, 0x3C, 0x03,         # STA $033C
    0xFB,                     # XCE      (native -> emu)
    0x58,                     # CLI
    0x60,                     # RTS
]


def basic_lines():
    lines = []
    # Poke the machine code
    lines.append(f'10 fori=0to{len(CODE)-1}:readd:poke{BASE}+i,d:next')
    # Write test value via POKE $DF1D (triggers io_cycle write + auto readback)
    lines.append(f'20 poke{D_DF1B + (0xDF1D - 0xDF1B)},{TEST_VAL}')  # poke $DF1D
    # Small delay so the io_cycle write + readback can complete
    lines.append('30 fori=1to200:next')
    # Read the io-cycle readback register ($DF1B)
    lines.append(f'40 ib=peek({D_DF1B})')
    # Baseline SRR counter
    lines.append(f'50 cb=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    # Run LDA long $02:$0000 via CPU path
    lines.append(f'60 sys{BASE}')
    # Post SRR counter
    lines.append(f'70 ca=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    # Printed output
    lines.append('80 ?"srr-wrbk v1"')
    lines.append(f'90 ?"wrote:";{TEST_VAL}')
    lines.append('100 ?"iocycle-rb:";ib')
    lines.append('110 ?"cpu-lda-long:";peek(828)')
    lines.append('120 ?"srr-cnt:";cb;"->";ca;"d:";ca-cb')
    lines.append(f'130 ?"srr-dat:";peek({D_DAT});"sr-ahi:";peek({D_AHI});"sr-cbk:";peek({D_CBK})')
    lines.append(f'140 ?"sr-a16:";peek({D_ALO})+256*peek({D_AMI})')
    # DATA lines
    data_chunks = []
    chunk = []
    chunk_len = 10  # "150 data"
    for b in CODE:
        s = str(b)
        if chunk and chunk_len + 1 + len(s) > 70:
            data_chunks.append(chunk)
            chunk = [s]
            chunk_len = 10 + len(s)
        else:
            chunk.append(s)
            chunk_len += 1 + len(s)
    if chunk:
        data_chunks.append(chunk)
    ln = 150
    for c in data_chunks:
        lines.append(f'{ln} data' + ','.join(c))
        ln += 10
    return lines


def main():
    deploy = '--deploy' in sys.argv
    if deploy:
        print('=== Step 1: deploy core (wipes SDRAM) ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)
        print('waiting 6s for KERNAL READY...')
        time.sleep(6)

    lines = basic_lines()
    print(f'\n=== type {len(lines)} BASIC lines + RUN ===')
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'  cmd len={len(cmd)}')
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  OUT: {out[:300]}')
        print(f'  ERR: {err[:300]}')
        return 1

    print('\nwaiting 4s for BASIC execution...')
    time.sleep(4)

    out_png = 'srr_write_readback_result.png'
    if '--out' in sys.argv:
        out_png = sys.argv[sys.argv.index('--out') + 1]
    print(f'\n=== screenshot -> {out_png} ===')
    md.cmd_screen([out_png])
    print()
    print('Expected (if both paths work):')
    print(f'  wrote:          {TEST_VAL}')
    print(f'  iocycle-rb:     {TEST_VAL}  (from $DF1B readback register)')
    print(f'  cpu-lda-long:   {TEST_VAL}  (from CPU-path LDA long $02:$0000)')
    print('  srr-cnt d: 1   (latch fired once)')
    print('  srr-dat:   AB  sr-ahi: 02  sr-cbk: 02  sr-a16: 0')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
