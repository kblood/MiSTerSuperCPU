"""Send SYS 2061 + enter via mtype, wait, then return."""
import paramiko, time, sys
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.50.130", username="root", password="1", timeout=10)
sys_addr = sys.argv[1] if len(sys.argv) > 1 else "2061"
stdin, stdout, stderr = c.exec_command(f"python3 /tmp/mtype.py 'sys {sys_addr}' enter", timeout=20)
out = stdout.read().decode()
err = stderr.read().decode()
print("rc=", stdout.channel.recv_exit_status())
print("out=", out)
print("err=", err)
c.close()
time.sleep(3)
print("Done.")
