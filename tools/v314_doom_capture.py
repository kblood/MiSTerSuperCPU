#!/usr/bin/env python3
"""v314: deploy + run full Doom + capture wr02 ring (now tied to $0090).

Expected UART fields:
  V:  ring of last 4 values written to $00:$0090
  YX: Y/X at most recent write
  WP: writer-PC (PBR:PC) of most recent write
  CG: count of writes where new value ≠ previous
  CY: total writes to $00:$0090

If V trail shows $F7 (low byte of $FFF7 = -9 signed) and WP = $2B:$245C,
that confirms v291 finding and the bug is upstream of $2B:$245A. The
next step is to find what computes -9 into A before reaching $245A.

Run after build_c64.ps1 produces an RBF.
"""
import paramiko, time, subprocess, hashlib, os, sys

RBF_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       '..', 'C64_MiSTer', 'output_files', 'C64.rbf')
MISTER = '192.168.50.130'

def md5(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        while True:
            b = f.read(65536)
            if not b: break
            h.update(b)
    return h.hexdigest()

def main():
    if not os.path.exists(RBF_PATH):
        print(f'ERROR: RBF not found at {RBF_PATH}', file=sys.stderr)
        return 1
    rbf_md5 = md5(RBF_PATH)
    rbf_size = os.path.getsize(RBF_PATH)
    print(f'RBF: {RBF_PATH}')
    print(f'  size={rbf_size:,} md5={rbf_md5}')

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(MISTER, username='root', password='1', timeout=5)

    sftp = c.open_sftp()
    sftp.put(RBF_PATH, '/media/fat/_Test/C64.rbf')
    sftp.close()
    print('RBF deployed to /media/fat/_Test/C64.rbf')

    # Run full Doom (loader + reu)
    _, o, _ = c.exec_command(
        'echo load_core /media/fat/_Test/_doom_full_abs.mgl > /dev/MiSTer_cmd')
    o.channel.recv_exit_status()
    print('Loaded _doom_full_abs.mgl, waiting 200s for loader + wedge (trap)')
    time.sleep(200)
    c.close()

    # Screenshot
    print('Capturing screenshot...')
    subprocess.run(['python', 'tools/mister_debug.py', 'screen',
                    'tools/doom_full/v314_wedge.png'], check=False)

    # UART for 5s
    print('Capturing UART for 5s...')
    r = subprocess.run(['python', 'tools/mister_debug.py', 'uart', '5'],
                       capture_output=True, text=True)
    uart = r.stdout
    out_path = 'tools/doom_full/v314_uart.txt'
    with open(out_path, 'w') as f:
        f.write(uart)
    print(f'UART saved to {out_path}, {len(uart.splitlines())} lines')

    # Parse last UART line for wr02 fields
    lines = [l for l in uart.splitlines() if l.startswith('F:')]
    if lines:
        last = lines[-1]
        print('\n=== last UART line ===')
        print(last)
        # Highlight wr02 fields (V/WP/CY/CG)
        import re
        for tag in ['V:', 'YX:', 'WP:', 'CG:', 'CY:']:
            m = re.search(tag + r'[^\s]+(\s+[0-9A-F]+){0,3}', last)
            if m:
                print(f'  {tag} = {m.group(0)}')

if __name__ == '__main__':
    sys.exit(main() or 0)
