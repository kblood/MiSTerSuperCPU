#!/usr/bin/env python3
"""Deploy no-BRAM build, verify boot, then load Asterix."""
import paramiko, time, os

RBF = 'C64_MiSTer/output_files/C64.rbf'
if not os.path.exists(RBF):
    print("RBF missing!"); exit(1)

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('192.168.50.130', username='root', password='1', look_for_keys=False, allow_agent=False)
sftp = c.open_sftp(); sftp.put(RBF, '/media/fat/_Test/C64.rbf'); sftp.close()
c.exec_command("killall MiSTer; sleep 1; stty -F /dev/ttyS1 115200 raw -echo; nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf > /tmp/mister.log 2>&1 &")
time.sleep(10)

# Screenshot boot
c.exec_command("echo screenshot > /dev/MiSTer_cmd")
time.sleep(1)
stdin, stdout, stderr = c.exec_command("ls -1tr /media/fat/screenshots/C64/*.png 2>&1 | tail -1")
fn = stdout.read().decode().strip()
if fn:
    sftp = c.open_sftp(); sftp.get(fn, 'screenshot_nobram_boot.png'); sftp.close()
    print(f"Boot screenshot: {fn} -> screenshot_nobram_boot.png")
else:
    print("No screenshot captured")

# Load Asterix
print("Loading asterix.mgl...")
c.exec_command("echo load_core /media/fat/_Test/asterix.mgl > /dev/MiSTer_cmd")
time.sleep(30)

# Another screenshot
c.exec_command("echo screenshot > /dev/MiSTer_cmd")
time.sleep(1)
stdin, stdout, stderr = c.exec_command("ls -1tr /media/fat/screenshots/C64/*.png 2>&1 | tail -1")
fn = stdout.read().decode().strip()
sftp = c.open_sftp(); sftp.get(fn, 'screenshot_nobram_asterix.png'); sftp.close()
print(f"Asterix screenshot: {fn} -> screenshot_nobram_asterix.png")

# UART capture
stdin, stdout, stderr = c.exec_command("timeout 5 cat /dev/ttyS1 2>&1")
data = stdout.read().decode(errors='replace')
with open('uart_nobram_asterix.log', 'w') as f: f.write(data)
print(f"UART: {len(data.splitlines())} lines")
c.close()
