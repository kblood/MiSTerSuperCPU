#!/usr/bin/env python3
"""Inline helper — run the full bank $20 peek flow using file-based script
to avoid shell-escape issues with backslash-r."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

def build_mtype_cmd():
    """Build a single mtype.py invocation that types the full BASIC program."""
    code = open('tools/bank20_peek.prg', 'rb').read()[14:]
    lines = [f'10 fori=0to{len(code)-1}:readd:poke49152+i,d:next:sys49152']
    per = 16
    ln = 20
    for i in range(0, len(code), per):
        chunk = code[i:i+per]
        lines.append(f'{ln} data' + ','.join(str(b) for b in chunk))
        ln += 10
    lines.append('run')
    # Shell-quote each line, join with ' enter '
    tokens = []
    for line in lines:
        # Escape single quotes (none expected in our lines, but safe)
        escaped = line.replace("'", r"'\''")
        tokens.append("'" + escaped + "'")
        tokens.append('enter')
    return 'python3 /tmp/mtype.py ' + ' '.join(tokens)


def main():
    deploy = '--deploy' in sys.argv
    if deploy:
        print('=== deploy ===')
        if md.cmd_deploy(['C64_MiSTer/output_files/C64.rbf']):
            return 1
        time.sleep(4)
        print('=== copy rbf to _Computer ===')
        md.ssh('cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64.rbf')
        print('=== load doom.mgl ===')
        md.ssh("echo 'load_core /media/fat/_Computer/doom.mgl' > /dev/MiSTer_cmd")
        print('waiting 20s...')
        time.sleep(20)

    print('=== type DATA loader + RUN (batched mtype) ===')
    cmd = build_mtype_cmd()
    print(f'  cmd length: {len(cmd)}')
    out, err, rc = md.ssh(cmd, timeout=180)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  OUT: {out[:300]}')
        print(f'  ERR: {err[:300]}')
        return 1
    time.sleep(3)

    print('=== type PEEK loop (separate mtype) ===')
    # Build PEEK loop command directly
    peek_cmd = "python3 /tmp/mtype.py 'fori=0to19:?peek(828+i);:nexti' enter"
    md.ssh(peek_cmd, timeout=60)
    time.sleep(4)

    print('=== screenshot ===')
    out_png = sys.argv[sys.argv.index('--out')+1] if '--out' in sys.argv else 'bank20_peek_final.png'
    md.cmd_screen([out_png])
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
