"""Continuous UART capture across the Doom MGL launch->crash window.

Stock doom_autoload_probe.py grabs only the final 5 s of UART; that misses the
launch->crash transition. This reloads the core, fires the MGL, and streams
/dev/ttyS1 continuously to a file for the whole window so we can see exactly
where/how the fix build crashes (wild JML from a stale operand = residual
staleness, vs a clean error/halt = different class).
"""
import paramiko, time, os, sys, socket

HOST, USER, PASS = '192.168.50.130', 'root', '1'
MGL_REMOTE = '/media/fat/_Computer/_SuperCPU/_doom_autoload.mgl'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'doom_autoload', 'fix_trace.txt')
SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 130


def connect():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    last = None
    for _ in range(4):
        try:
            sk = socket.create_connection((HOST, 22), timeout=10)
            c.connect(HOST, username=USER, password=PASS, timeout=10, sock=sk)
            c.get_transport().set_keepalive(20)
            return c
        except Exception as ex:
            last = ex; time.sleep(1.5)
    raise last


def run(c, cmd, t=15):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    c = connect()
    print('rbf:', run(c, 'md5sum %s' % RBF_REMOTE).strip())
    print('CORENAME:', run(c, 'cat /tmp/CORENAME 2>/dev/null').strip())

    # Fresh core so REU SDRAM starts clean, then fire the MGL.
    run(c, 'echo load_core %s > /dev/MiSTer_cmd' % RBF_REMOTE)
    time.sleep(12)
    run(c, 'stty -F /dev/ttyS1 115200 raw -echo')
    print('firing MGL, streaming %d s of UART ...' % SECS)
    run(c, 'echo load_core %s > /dev/MiSTer_cmd' % MGL_REMOTE)

    # Stream UART continuously to a remote file, then pull it.
    run(c, 'timeout %d cat /dev/ttyS1 > /tmp/fix_trace.txt 2>&1 &' % SECS, t=10)
    time.sleep(SECS + 4)
    sftp = c.open_sftp()
    sftp.get('/tmp/fix_trace.txt', OUT)
    sftp.close()
    n = sum(1 for _ in open(OUT, 'r', errors='replace'))
    print('captured %d lines -> %s' % (n, OUT))
    c.close()


if __name__ == '__main__':
    main()
