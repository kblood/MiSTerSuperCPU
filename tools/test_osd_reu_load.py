#!/usr/bin/env python3
"""Automate OSD F12 -> Hardware -> REU=16MB -> Load REU -> doom.reu.

All OSD keystrokes in ONE mtype.py invocation to avoid exhausting the
virtual input device. Verify via a follow-up BASIC program that reads
bank $20:$0000 through LDA long and prints PEEK(828).

Main-menu counts (separators skipped, hA/h3 items hidden on fresh boot):
   0: Mount #8
   1: Mount #9
   2: Mount Write Protected
   3: Load PRGCRTREUTAP   (F1)
   4: Load REU             (F2)
   5: Audio & Video        (P1)
   6: Hardware             (P2)

Hardware submenu:
   0: GeoRAM (Disabled/4MB)
   1: REU    (Disabled/512KB/2MB/16MB)

File browser at /media/fat/games/C64/*.reu (alphabetical):
   0: ..
   1: aaa.reu
   2: blu.reu
   3: dl00.reu
   4: doom.reu      <-- target
   5: doom_usb.reu
   6: test.reu

Success criteria:
  - BASIC PEEK(828) = 120 ($78 SEI, first byte of doom.reu)
  - reu_ioctl_cnt > 0 (proves an ioctl transfer actually fired)
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152

VERIFY_CODE = [
    0x78,                        # SEI
    0x18,                        # CLC
    0xFB,                        # XCE
    0xE2, 0x30,                  # SEP #$30
    0xAF, 0x00, 0x00, 0x20,      # LDA long $200000
    0x8D, 0x3C, 0x03,            # STA $033C
    0xFB,                        # XCE
    0x58,                        # CLI
    0x60,                        # RTS
]


def osd_tokens():
    """Generate the argv tokens for one mtype.py invocation that:
       1. Sets REU to 16MB via Hardware submenu
       2. Loads doom.reu via Load REU file browser
    """
    tokens = []
    # Phase 1: set REU 16MB
    tokens.append('esc')             # clear any leftover OSD state
    tokens.append('wait:0.4')
    tokens.append('f12')             # open OSD
    tokens.append('wait:1.0')
    for _ in range(6):               # down 6 -> Hardware
        tokens.append('down')
    tokens.append('wait:0.3')
    tokens.append('enter')           # enter Hardware submenu
    tokens.append('wait:0.4')
    tokens.append('down')            # GeoRAM -> REU
    tokens.append('wait:0.2')
    for _ in range(3):               # Disabled -> 512KB -> 2MB -> 16MB
        tokens.append('right')
        tokens.append('wait:0.15')
    tokens.append('wait:0.3')
    tokens.append('esc')             # back to main menu
    tokens.append('wait:0.3')
    tokens.append('esc')             # close OSD
    tokens.append('wait:0.6')
    # Phase 2: Load REU doom.reu
    tokens.append('f12')             # reopen OSD
    tokens.append('wait:1.0')
    for _ in range(4):               # down 4 -> Load REU
        tokens.append('down')
    tokens.append('wait:0.3')
    tokens.append('enter')           # open file browser
    tokens.append('wait:2.0')
    for _ in range(4):               # .. -> aaa -> blu -> dl00 -> doom
        tokens.append('down')
        tokens.append('wait:0.12')
    tokens.append('wait:0.3')
    tokens.append('enter')           # select doom.reu
    tokens.append('wait:25')         # 16MB transfer
    return tokens


def data_lines(code, start=200):
    chunks = []
    chunk = []
    chunk_len = 9
    for b in code:
        s = str(b)
        if chunk and chunk_len + 1 + len(s) > 70:
            chunks.append(chunk)
            chunk = [s]
            chunk_len = 9 + len(s)
        else:
            chunk.append(s)
            chunk_len += 1 + len(s)
    if chunk:
        chunks.append(chunk)
    return [f'{start + 10*i} data' + ','.join(c) for i, c in enumerate(chunks)]


def verify_lines():
    lines = [
        f'10 fori=0to{len(VERIFY_CODE)-1}:readd:poke{BASE}+i,d:next',
        '20 poke828,0',
        f'30 sys{BASE}',
        '40 ?"bank20[0]:";peek(828);"(exp 120=doom)"',
        '50 cn=peek(57097)+256*peek(57098)+65536*peek(57099)',
        '60 ?"reuioctl_cnt:";cn;"idx:";peek(57100)',
    ]
    return lines + data_lines(VERIFY_CODE)


def main():
    if '--deploy' in sys.argv:
        print('=== deploy core ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)
        md.scp_to('tools/mtype.py', '/tmp/mtype.py')
        time.sleep(6)

    # ONE mtype.py call: OSD navigate + Load REU + verify BASIC + RUN.
    # MiSTer stops servicing new uinput devices after many create/destroy
    # cycles, so we use a single device for the entire sequence.
    print('\n=== unified mtype call (OSD + verify) ===')
    tokens = osd_tokens()
    # Append the BASIC verify program
    for line in verify_lines():
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'cmd len={len(cmd)}  tokens={len(tokens)}')
    t0 = time.time()
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'  rc={rc}  elapsed={time.time()-t0:.1f}s')
    if err.strip():
        print(f'  ERR: {err[:200]}')
    time.sleep(4)
    md.cmd_screen(['osd_reu_verify.png'])

    print()
    print('Interpretation:')
    print('  bank20[0]=120 ($78)  -> OSD LOAD REU WORKED')
    print('  bank20[0]=194 ($C2)  -> stale from previous test, OSD nav failed')
    print('  bank20[0]=0          -> ioctl wiped but no data loaded')
    print('  reuioctl_cnt>0       -> ioctl transfer actually fired')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
