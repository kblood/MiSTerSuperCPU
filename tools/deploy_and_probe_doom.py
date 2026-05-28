"""Post-build deploy + Doom MGL autoload probe.

1. SCP C64_MiSTer/output_files/C64.rbf → /media/fat/_Test/C64.rbf
2. md5sum confirm
3. Invoke tools/doom_autoload_probe.main()

Run after build_c64.ps1 completes.
"""
import hashlib
import os
import socket
import sys
import time
import paramiko

HOST, USER, PASS = "192.168.50.130", "root", "1"
LOCAL_RBF = "C64_MiSTer/output_files/C64.rbf"
REMOTE_RBF = "/media/fat/_Test/C64.rbf"


def md5_local(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if not os.path.isfile(LOCAL_RBF):
        sys.exit(f"missing {LOCAL_RBF}")
    local_md5 = md5_local(LOCAL_RBF)
    print(f"local rbf md5: {local_md5}  size: {os.path.getsize(LOCAL_RBF)}")

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    # Winsock getaddrinfo race workaround: pre-connect a raw socket, retry.
    last = None
    for attempt in range(4):
        try:
            sk = socket.create_connection((HOST, 22), timeout=10)
            c.connect(HOST, username=USER, password=PASS, timeout=10, sock=sk)
            last = None
            break
        except Exception as ex:
            last = ex
            time.sleep(1.5)
    if last is not None:
        raise last
    c.get_transport().set_keepalive(20)

    sftp = c.open_sftp()
    print(f"scp -> {REMOTE_RBF}")
    sftp.put(LOCAL_RBF, REMOTE_RBF)

    _, o, _ = c.exec_command(f"md5sum {REMOTE_RBF}")
    remote_md5_line = o.read().decode().strip()
    print(f"remote: {remote_md5_line}")
    remote_md5 = remote_md5_line.split()[0] if remote_md5_line else ""
    if remote_md5 != local_md5:
        sys.exit(f"md5 mismatch: local={local_md5} remote={remote_md5}")

    sftp.close()
    c.close()
    print("deploy OK")

    # Hand off to the probe
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    import doom_autoload_probe

    doom_autoload_probe.main()


if __name__ == "__main__":
    main()
