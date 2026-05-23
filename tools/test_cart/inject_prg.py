"""Inject a PRG via mbc + run SYS 2061. Use when core is already loaded."""
import paramiko, time, sys
prg_local = sys.argv[1]
prg_remote = "/media/fat/games/C64/" + prg_local.replace("\\", "/").split("/")[-1]
sys_addr = sys.argv[2] if len(sys.argv) > 2 else "2061"

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.50.130", username="root", password="1", timeout=10)
sftp = c.open_sftp()
sftp.put(prg_local, prg_remote)
sftp.close()
print(f"Uploaded -> {prg_remote}")

stdin, stdout, stderr = c.exec_command(f"mbc load_rom C64.PRG {prg_remote}", timeout=10)
out = stdout.read().decode(); err = stderr.read().decode()
rc = stdout.channel.recv_exit_status()
print(f"mbc rc={rc} out={out!r} err={err!r}")
time.sleep(2)

stdin, stdout, stderr = c.exec_command(f"python3 /tmp/mtype.py 'sys {sys_addr}' enter", timeout=20)
mout = stdout.read().decode(); merr = stderr.read().decode()
print(f"mtype rc={stdout.channel.recv_exit_status()} out={mout!r} err={merr!r}")
c.close()
print("Done.")
