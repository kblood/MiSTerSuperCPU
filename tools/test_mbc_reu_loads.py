#!/usr/bin/env python3
"""Does `mbc load_rom C64.REU path.reu` actually populate SDRAM?

NOTE: MGL-via-pipe DOES load <file> tags — that question is settled (see
project_mgl_pipe_loads_files.md). This script targets a different question:
whether `mbc load_rom` — which returns rc=0 silently for C64.REU — moves
bytes to bank $20+ SDRAM or just no-ops. (Spoiler: mbc has no C64.REU alias
and silently no-ops; use a custom MGL via the pipe instead.)

Sequence:
  1. --deploy (wipes SDRAM)
  2. Pre-check: LDA long $20:$0000 -> $033C  (expect 0 = empty)
  3. mbc load_rom C64.REU /media/fat/games/C64/doom.reu (ssh)
  4. Wait 15s for potential 16MB transfer
  5. Post-check: LDA long $20:$0000 -> $033D  (expect $78 SEI = doom loaded)
  6. Read reu_ioctl_cnt / idx regs ($DF09-$DF12)
  7. Read SuperRAM diag count ($DFE9-$DFEF) — if >0 we know a fetch happened

Expected bytes at $20:$0000 if doom loaded: 78 D8 18 FB C2 30 ...
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152
REU_FILE = "/media/fat/games/C64/doom.reu"

# native read bank $20:$0000 into $033C (addr determined by --dst)
CODE_TEMPLATE = [
    0x78,                          # SEI
    0x18,                          # CLC
    0xFB,                          # XCE
    0xE2, 0x30,                    # SEP #$30
    0xAF, 0x00, 0x00, 0x20,        # LDA long $200000
    0x8D, 0x00, 0x00,              # STA abs (patched)
    0xFB,                          # XCE
    0x58,                          # CLI
    0x60,                          # RTS
]


def code_for(dst):
    code = list(CODE_TEMPLATE)
    code[10] = dst & 0xFF
    code[11] = (dst >> 8) & 0xFF
    return code


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


def basic_lines_pre():
    code = code_for(0x033C)
    lines = [
        f'10 fori=0to{len(code)-1}:readd:poke{BASE}+i,d:next',
        '20 poke828,0',
        f'30 sys{BASE}',
        '40 ?"pre-mbc bank20[0]:";peek(828)',
        '50 cn=peek(57097)+256*peek(57098)+65536*peek(57099)',
        '60 ?"reu_ioctl_cnt:";cn;"idx:";peek(57100)',
        '70 ?"ready-to-mbc"',
    ]
    return lines + data_lines(code)


def basic_lines_post():
    code = code_for(0x033D)
    lines = [
        f'10 fori=0to{len(code)-1}:readd:poke{BASE}+i,d:next',
        f'20 sys{BASE}',
        '30 ?"post-mbc bank20[0]:";peek(829);"(exp 120)"',
        '40 cn=peek(57097)+256*peek(57098)+65536*peek(57099)',
        '50 ?"reu_ioctl_cnt:";cn;"idx:";peek(57100)',
        '60 ?"120=doom 0=empty 171=stale"',
    ]
    return lines + data_lines(code)


def type_and_run(lines, label):
    print(f'\n=== {label}: {len(lines)} BASIC lines ===')
    tokens = ["'new'", 'enter']
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  ERR: {err[:200]}')
    time.sleep(3)


def main():
    if '--deploy' in sys.argv:
        print('=== deploy core ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)
        print('re-uploading mtype.py...')
        md.scp_to('tools/mtype.py', '/tmp/mtype.py')
        time.sleep(6)

    # Phase 1: pre-mbc state
    type_and_run(basic_lines_pre(), 'pre-mbc')
    md.cmd_screen(['mbc_reu_pre.png'])

    # Phase 2: mbc load_rom
    print('\n=== mbc load_rom C64.REU doom.reu ===')
    out, err, rc = md.ssh(f'mbc load_rom C64.REU {REU_FILE}; echo rc=$?', timeout=60)
    print(f'  mbc said: {out.strip()}')
    if err.strip():
        print(f'  mbc err: {err.strip()[:200]}')
    print('\n=== wait 15s for potential 16MB transfer ===')
    time.sleep(15)
    print('waiting 6s for KERNAL READY in case mbc reset...')
    time.sleep(6)

    # Phase 3: post-mbc state
    type_and_run(basic_lines_post(), 'post-mbc')
    md.cmd_screen(['mbc_reu_post.png'])

    print()
    print('Interpretation:')
    print('  pre  bank20[0] = 0          -> SDRAM empty after deploy')
    print('  post bank20[0] = 120 (0x78) -> mbc loaded doom.reu, SDRAM populated')
    print('  post bank20[0] = 0          -> mbc silently did nothing')
    print('  post ioctl_cnt > 0          -> ioctl transfer actually fired')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
