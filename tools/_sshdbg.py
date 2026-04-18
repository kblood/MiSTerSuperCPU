#!/usr/bin/env python3
"""Simple ad-hoc SSH-exec helper that I use throughout the Doom debug session."""
import sys, paramiko, os

HOST = "192.168.50.130"
USER = "root"
PASS = "1"

def run(cmd, timeout=30):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=10)
    _, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors='replace')
    err = stderr.read().decode(errors='replace')
    c.close()
    return out, err

if __name__ == '__main__':
    cmd = " ".join(sys.argv[1:])
    to = int(os.environ.get("SSHDBG_TO", "30"))
    out, err = run(cmd, timeout=to)
    sys.stdout.write(out)
    if err.strip():
        sys.stderr.write("STDERR: " + err)
