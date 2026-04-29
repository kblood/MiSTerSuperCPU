#!/usr/bin/env python3
"""Upload evtype.py to MiSTer and test typing."""
import paramiko, time

HOST = '192.168.50.130'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username='root', password='1', timeout=10)

sftp = c.open_sftp()
sftp.put('tools/evtype.py', '/tmp/evtype.py')
sftp.close()
print("[+] Uploaded evtype.py")

# Test typing 'A' via the kbd event device
_, out, err = c.exec_command('python3 /tmp/evtype.py A 2>&1')
time.sleep(3)
print("stdout:", out.read().decode())
print("stderr:", err.read().decode())

# Now type 'B' to double-check
_, out, err = c.exec_command('python3 /tmp/evtype.py B 2>&1')
time.sleep(3)
print("stdout:", out.read().decode())
print("stderr:", err.read().decode())

c.close()
print("[+] Done")
