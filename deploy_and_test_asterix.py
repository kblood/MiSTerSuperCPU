#!/usr/bin/env python3
"""Deploy new RBF, restart MiSTer, load asterix, capture UART."""
import paramiko, time, sys, os

RBF = sys.argv[1] if len(sys.argv) > 1 else 'C64_MiSTer/output_files/C64_release.rbf'
MGL = '/media/fat/_Test/asterix.mgl'

if not os.path.exists(RBF):
    print(f"ERROR: RBF not found: {RBF}")
    sys.exit(1)

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('192.168.50.130', username='root', password='1', look_for_keys=False, allow_agent=False)
sftp = c.open_sftp()
print(f"Uploading {RBF}...")
sftp.put(RBF, '/media/fat/_Test/C64.rbf')
sftp.close()

print("Restarting MiSTer...")
c.exec_command("killall MiSTer; sleep 1; stty -F /dev/ttyS1 115200 raw -echo; nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf > /tmp/mister.log 2>&1 &")
time.sleep(10)

print(f"Loading {MGL}...")
c.exec_command(f"echo load_core {MGL} > /dev/MiSTer_cmd")
time.sleep(5)

# UART capture
print("Capturing 8s UART...")
stdin, stdout, stderr = c.exec_command("timeout 8 cat /dev/ttyS1 2>&1")
data = stdout.read().decode(errors='replace')
with open('uart_asterix_srcptr.log', 'w') as f:
    f.write(data)
print(f"UART: {len(data.splitlines())} lines")

c.close()
