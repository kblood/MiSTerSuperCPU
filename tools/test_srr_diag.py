#!/usr/bin/env python3
"""Hardware test: SuperRAM read-path diagnostics.

Captures ground-truth of what the FPGA actually delivered on a single
`LDA long $20:$0005` from bank $00 native-mode code. The diagnostic
latches added to fpga64_sid_iec.vhd capture (on every real SuperRAM read
where enableCpu fires, superram_in_pipeline=1, cpuWe_pre=0):

  $DFE9/$DFEA  total SuperRAM read count (lo/hi)
  $DFEB        sdram_superram byte delivered to cpuDi
  $DFEC        addr_hi_816 (bank) at that moment
  $DFED        cache_cpu_bank at that moment
  $DFEE        cpuAddr_pre[7:0]  at that moment
  $DFEF        cpuAddr_pre[15:8] at that moment

Workflow:
 1. Deploy rebuilt core (wipes SDRAM)
 2. Copy RBF to /media/fat/_Computer/C64.rbf (+ versioned twin)
 3. Trigger doom.mgl load via MiSTer_cmd (fills SDRAM bank $20 with doom code)
 4. Wait for REU data transfer
 5. Type a BASIC program that:
       - pokes assembled code to $C000
       - reads `count` via PEEK($DFE9+256*$DFEA) BEFORE the SYS (baseline)
       - SYS 49152 runs:
            SEI; CLC; XCE; SEP #$30
            LDA long $20:$0005
            STA $033C
            XCE; CLI; RTS
       - reads count AFTER the SYS (delta should be exactly 1)
       - PRINTs cpu-observed byte + all diagnostic fields
 6. Screenshot the result for inspection

Interpretation:
  - Known doom.reu byte at $20:$0005: the first 16 bytes of Doom's prologue
    (from prior traces) are 18 FB C2 30 A9 00 00 8D ...  — so $20:$0005 = $00
  - If $DFEB = $00 AND cpu-seen = $00: the read path delivered the correct
    byte. The bug is NOT in the SuperRAM read itself; look at REP decoding.
  - If $DFEB = correct-known-value AND cpu-seen = wrong: clk32/cpu-latch race
  - If $DFEB = wrong AND cpu-seen = wrong: read delivered wrong data; look
    at SDRAM bt/dout_reu latch, 3-stage pipeline timing, or SDRAM load.
  - If count delta = 0: CPU never hit the SuperRAM read path for this LDA
    long — a cache/phantom/bram bypass is swallowing the fetch.

NOTE: because C64 BASIC's PEEK goes through bank $00 (T65 or 816 emu mode),
PEEKs of $DFE9-$DFEF do NOT advance the SuperRAM read count themselves.
The count delta should equal exactly the number of bank-$20 fetches done
by the SYS 49152 native-mode payload (= 1 for a single LDA long).
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
# $C000 payload — bank-$00 native-mode code that does one LDA long from
# bank $20 and stores the 8-bit result to $033C (= 828).
#   78        SEI
#   18        CLC
#   FB        XCE          ; emu → native (C was 0 → C=1, E=0)
#   E2 30     SEP #$30     ; force M=X=1 (XCE native M/X workaround)
#   AF 05 00 20  LDA $200005 ; LDA long bank=$20 addr=$0005
#   8D 3C 03  STA $033C    ; store result (M=1 ⇒ 8-bit store)
#   FB        XCE          ; native → emu (C still 1 from initial XCE)
#   58        CLI
#   60        RTS
CODE = [
    0x78,                     # SEI
    0x18,                     # CLC
    0xFB,                     # XCE
    0xE2, 0x30,               # SEP #$30
    0xAF, 0x05, 0x00, 0x20,   # LDA $200005  (LDA long $20:$0005)
    0x8D, 0x3C, 0x03,         # STA $033C
    0xFB,                     # XCE
    0x58,                     # CLI
    0x60,                     # RTS
]
BASE = 49152  # $C000

# Diagnostic register decimal addresses (for PEEK)
D_CNT_LO = 0xDFE9  # 57321
D_CNT_HI = 0xDFEA  # 57322
D_DAT    = 0xDFEB  # 57323
D_AHI    = 0xDFEC  # 57324
D_CBK    = 0xDFED  # 57325
D_ALO    = 0xDFEE  # 57326
D_AMI    = 0xDFEF  # 57327


def basic_lines():
    lines = []
    # Poke the machine code
    lines.append(f'10 fori=0to{len(CODE)-1}:readd:poke{BASE}+i,d:next')
    # Record count BEFORE the SYS
    lines.append(f'20 cb=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    # Run the LDA long
    lines.append(f'30 sys{BASE}')
    # Record count AFTER the SYS
    lines.append(f'40 ca=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    # Print human-readable output
    lines.append('50 ?"srr-diag v1"')
    lines.append('60 ?"cnt-before:";cb;"cnt-after:";ca;"delta:";ca-cb')
    lines.append('70 ?"cpu-seen:";peek(828)')
    lines.append(f'80 ?"sdram-sr:";peek({D_DAT})')
    lines.append(f'90 ?"addr-hi:";peek({D_AHI});"cache-bk:";peek({D_CBK})')
    lines.append(f'100 ?"addr16:";peek({D_ALO})+256*peek({D_AMI})')
    # DATA split across multiple lines (C64 BASIC line limit ~80 chars)
    data_chunks = []
    chunk = []
    chunk_len = 8  # "110 data"
    for b in CODE:
        s = str(b)
        if chunk and chunk_len + 1 + len(s) > 70:
            data_chunks.append(chunk)
            chunk = [s]
            chunk_len = 8 + len(s)
        else:
            chunk.append(s)
            chunk_len += 1 + len(s)
    if chunk:
        data_chunks.append(chunk)
    ln = 110
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

        print('\n=== Step 2: copy RBF to _Computer path for MGL ===')
        md.ssh('cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64.rbf')
        # MGL gotcha: overwrite any versioned C64_YYYYMMDD.rbf so stale
        # bitstreams don't load from the <rbf>_Computer/C64</rbf> resolver.
        md.ssh("cd /media/fat/_Computer && ls C64_*.rbf 2>/dev/null "
               "| while read f; do cp C64.rbf \"$f\"; done")

        print('\n=== Step 3: trigger doom.mgl load (fills bank $20+ via REU) ===')
        md.ssh("echo 'load_core /media/fat/_Computer/doom.mgl' > /dev/MiSTer_cmd")

        print('\n=== Step 4: wait 20s for 16MB REU transfer ===')
        time.sleep(20)

        print('\nwaiting 6s for KERNAL READY...')
        time.sleep(6)

    lines = basic_lines()
    print(f'\n=== Step 5: type {len(lines)} BASIC lines + RUN ===')
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

    print('\nwaiting 4s for BASIC execution + PRINT...')
    time.sleep(4)

    out_png = 'srr_diag_result.png'
    if '--out' in sys.argv:
        out_png = sys.argv[sys.argv.index('--out') + 1]
    print(f'\n=== Step 6: screenshot -> {out_png} ===')
    md.cmd_screen([out_png])

    print()
    print('Interpretation guide:')
    print('  delta = 1  -> exactly one SuperRAM read fired (expected for LDA long)')
    print('  delta = 0  -> read path bypassed by cache/phantom/bram hit')
    print('  delta > 1  -> multiple reads (REP-style re-fetch)')
    print('  cpu-seen == sdram-sr -> FPGA-consistent; bug is elsewhere')
    print('  cpu-seen != sdram-sr -> clk32/cpu-latch race inside cpuDi mux')
    print('  addr16=$0005, addr-hi=$20, cache-bk=$20 -> correct addressing')
    print('  otherwise -> latch/bank-mux bug')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
