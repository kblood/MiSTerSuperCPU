#!/usr/bin/env python3
"""Historical test — kept for diagnostic reference.

NOTE: this script predates the settled finding that MGL-via-pipe DOES
process <file> tags (see project_mgl_pipe_loads_files.md). It was used
during an investigation that compared bank $20 (SuperRAM) contents before
and after an MGL trigger — but MGL loads REU files into the REU SDRAM
region, not into SuperRAM bank $20, so the "= $AB after MGL" outcome is
expected and does NOT mean MGL failed to load. Use a REU FETCH against
REU addresses instead when verifying MGL REU loading.

Sequence:
 1. --deploy (wipes FPGA; SDRAM is volatile but persists across bitstream loads)
 2. STA long $AB → bank $20:$0000 via CPU (known-working write path)
 3. Verify LDA long $20:$0000 = $AB (should work)
 4. Trigger doom.mgl load via MiSTer_cmd pipe
 5. Verify LDA long $20:$0000 again. (Result in bank $20 is unrelated to
    whether the REU was loaded — use REU FETCH diagnostics for that.)
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152

# Two routines:
#  payload 1: write $AB to bank $20:$0000, read back to $033C, read ioctl_cnt to $033D
#  payload 2: just read bank $20:$0000 to $033C (no write)
# We'll combine: a single native-mode routine that does WRITE then READ.

# Pre-MGL: write + read
CODE_WRITE_READ = [
    0x78,                        # SEI
    0x18,                        # CLC
    0xFB,                        # XCE -> native
    0xE2, 0x30,                  # SEP #$30
    0xA9, 0xAB,                  # LDA #$AB
    0x8F, 0x00, 0x00, 0x20,      # STA $200000
    0xAF, 0x00, 0x00, 0x20,      # LDA $200000 (readback)
    0x8D, 0x3C, 0x03,            # STA $033C
    0xFB,                        # XCE -> emu
    0x58,                        # CLI
    0x60,                        # RTS
]

# Post-MGL: just read
CODE_READ_ONLY = [
    0x78,                        # SEI
    0x18,                        # CLC
    0xFB,                        # XCE -> native
    0xE2, 0x30,                  # SEP #$30
    0xAF, 0x00, 0x00, 0x20,      # LDA $200000
    0x8D, 0x3D, 0x03,            # STA $033D
    0xFB,                        # XCE -> emu
    0x58,                        # CLI
    0x60,                        # RTS
]


def mk_data_lines(code, start_line):
    chunks = []
    chunk = []
    chunk_len = 10
    for b in code:
        s = str(b)
        if chunk and chunk_len + 1 + len(s) > 70:
            chunks.append(chunk)
            chunk = [s]
            chunk_len = 10 + len(s)
        else:
            chunk.append(s)
            chunk_len += 1 + len(s)
    if chunk:
        chunks.append(chunk)
    return [f'{start_line + 10*i} data' + ','.join(c) for i, c in enumerate(chunks)]


def poke_lines_pre():
    """Lines that POKE code 1, run it, read ioctl cnt, print"""
    lines = []
    lines.append(f'10 fori=0to{len(CODE_WRITE_READ)-1}:readd:poke{BASE}+i,d:next')
    lines.append(f'20 sys{BASE}')
    lines.append('30 ?"pre-mgl"')
    lines.append('40 ?"rb20_00:";peek(828);"(exp 171)"')
    lines.append('50 cn=peek(57097)+256*peek(57098)+65536*peek(57099)')
    lines.append('60 ?"ioctl_cnt:";cn')
    lines.append('70 ?"ioctl_idx:";peek(57100)')
    lines.append('80 ?"ready-for-mgl"')
    lines += mk_data_lines(CODE_WRITE_READ, 200)
    return lines


def poke_lines_post():
    """Lines that POKE code 2, run it, read ioctl cnt, print"""
    lines = []
    lines.append(f'10 fori=0to{len(CODE_READ_ONLY)-1}:readd:poke{BASE}+i,d:next')
    lines.append(f'20 sys{BASE}')
    lines.append('30 ?"post-mgl"')
    lines.append('40 ?"rb20_00:";peek(829)')
    lines.append('50 cn=peek(57097)+256*peek(57098)+65536*peek(57099)')
    lines.append('60 ?"ioctl_cnt:";cn')
    lines.append('70 ?"ioctl_idx:";peek(57100)')
    lines.append('80 ?"171=stale 120=doom 0=wiped"')
    lines += mk_data_lines(CODE_READ_ONLY, 200)
    return lines


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
        print('waiting 6s for KERNAL READY...')
        time.sleep(6)

    # Phase 1: pre-MGL write & read
    type_and_run(poke_lines_pre(), 'pre-mgl write+read')
    md.cmd_screen(['mgl_test_pre.png'])

    # Phase 2: try to load doom.mgl
    print('\n=== copy RBF to _Computer for MGL resolver ===')
    md.ssh('cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64.rbf')
    md.ssh("cd /media/fat/_Computer && ls C64_*.rbf 2>/dev/null "
           "| while read f; do cp C64.rbf \"$f\"; done")
    print('\n=== trigger doom.mgl load via MiSTer_cmd pipe ===')
    md.ssh("echo 'load_core /media/fat/_Computer/doom.mgl' > /dev/MiSTer_cmd")
    print('\n=== wait 25s for potential load ===')
    time.sleep(25)
    print('\nwaiting 6s for KERNAL READY...')
    time.sleep(6)

    # Phase 3: post-MGL read only
    type_and_run(poke_lines_post(), 'post-mgl read')
    md.cmd_screen(['mgl_test_post.png'])

    print()
    print('Interpretation:')
    print('  pre rb20_00 = 171 (AB)           -> STA long wrote successfully')
    print('  post rb20_00 = 171 (AB)          -> MGL did not touch bank $20')
    print('  post rb20_00 = 120 (78 SEI)      -> MGL populated bank $20 with doom code')
    print('  post rb20_00 = 0                 -> MGL or core wiped SDRAM')
    print('  post ioctl_cnt > 0               -> ioctl fired (check idx)')
    print('  post ioctl_cnt = 0               -> MGL pipe did NOT trigger ioctl at all')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
