#!/usr/bin/env python3
"""Query existing REU ioctl diagnostic counters ($DF09-$DF12).

These registers track ioctl write activity during REU loads:
  $DF09-$DF0B: reu_ioctl_cnt (24-bit: bytes written to SDRAM via ioctl)
  $DF0C:       reu_ioctl_idx (ioctl index at start of transfer)
  $DF0D-$DF10: reu_ioctl_last_addr (25-bit: last SDRAM address written)
  $DF11:       reu_ioctl_last_data (last byte written)
  $DF12:       reu_ioctl_byte0_data (first byte written)

Workflow:
 1. --deploy: wipe SDRAM and load fresh core
 2. --mgl: also trigger doom.mgl load via MiSTer_cmd pipe
 3. PEEK the diagnostic registers via a BASIC reader
 4. Print the values

Interpretation:
  cnt=0 → ioctl never fired, doom.mgl didn't trigger a load. Problem is
          in MGL pipe or load_reu ioctl routing.
  cnt<16M, last_addr < REU_ADDR+16M → partial load, check where it stopped
  cnt≈16M, last_addr≈$1FFFFFF → full load reached SDRAM; then the issue
          is somewhere in addressing (mismatch REU_ADDR vs SuperRAM addr).
  byte0≠0 → first byte was written, at least some data flowed through
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"


def basic_lines():
    lines = []
    lines.append('10 ?"reu-ioctl-diag v1"')
    lines.append('20 cn=peek(57097)+256*peek(57098)+65536*peek(57099)')
    lines.append('30 ?"cnt:";cn;"(bytes via ioctl)"')
    lines.append('40 ?"idx:";peek(57100)')
    lines.append('50 la=peek(57101)+256*peek(57102)+65536*peek(57103)')
    lines.append('60 ?"la24:";la;"bit24:";peek(57104)')
    lines.append('70 ?"byte0:";peek(57106);"last:";peek(57105)')
    # $DF09=57097, $DF0A=57098, $DF0B=57099, $DF0C=57100
    # $DF0D=57101, $DF0E=57102, $DF0F=57103, $DF10=57104
    # $DF11=57105, $DF12=57106
    return lines


def main():
    deploy = '--deploy' in sys.argv
    do_mgl = '--mgl' in sys.argv

    if deploy:
        print('=== deploy core ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)

    if do_mgl:
        print('\n=== copy RBF to _Computer for MGL ===')
        md.ssh('cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64.rbf')
        md.ssh("cd /media/fat/_Computer && ls C64_*.rbf 2>/dev/null "
               "| while read f; do cp C64.rbf \"$f\"; done")
        print('=== verify doom.reu exists ===')
        out, _, _ = md.ssh('ls -la /media/fat/games/C64/doom.reu')
        print(' ', out)
        print('\n=== trigger doom.mgl load via MiSTer_cmd pipe ===')
        md.ssh("echo 'load_core /media/fat/_Computer/doom.mgl' > /dev/MiSTer_cmd")
        print('\n=== wait 25s for 16MB REU transfer ===')
        time.sleep(25)
        print('waiting 6s for KERNAL READY...')
        time.sleep(6)
    elif deploy:
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
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  OUT: {out[:300]}')
        print(f'  ERR: {err[:300]}')
        return 1

    time.sleep(3)
    out_png = 'reu_ioctl_diag_result.png'
    if '--out' in sys.argv:
        out_png = sys.argv[sys.argv.index('--out') + 1]
    print(f'\n=== screenshot -> {out_png} ===')
    md.cmd_screen([out_png])
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
