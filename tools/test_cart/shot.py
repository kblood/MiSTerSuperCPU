#!/usr/bin/env python3
"""Quick screenshot helper: takes a screenshot and saves to a local path."""
import hashlib
import os
import sys
import time
import paramiko

HOST = '192.168.50.130'

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'shot.png'
    extra_wait = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username='root', password='1', timeout=15)
    if extra_wait > 0:
        time.sleep(extra_wait)
    c.exec_command('rm -f /media/fat/screenshots/C64/*.png; '
                   'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    _, o, _ = c.exec_command('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rem = o.read().decode().strip()
    print(f'remote: {rem!r}')
    if not rem:
        print('NO SCREENSHOT')
        sys.exit(1)
    s = c.open_sftp()
    s.get(rem, out)
    s.close()
    h = hashlib.md5(open(out, 'rb').read()).hexdigest()[:8]
    print(f'saved {out} md5={h} size={os.path.getsize(out)}')
    c.close()


if __name__ == '__main__':
    main()
