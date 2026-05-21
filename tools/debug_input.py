#!/usr/bin/env python3
"""Debug keyboard input and PRG loading on MiSTer."""
import paramiko, time

HOST = '192.168.50.130'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username='root', password='1', timeout=10)

# 1. Check if mtype.py's uinput device gets created properly
print("=== Test 1: mtype.py device creation ===")
_, out, err = c.exec_command('python3 -c "import os; fd=os.open(\'/dev/uinput\', os.O_WRONLY|os.O_NONBLOCK); print(\'uinput fd:\', fd); os.close(fd)"')
time.sleep(2)
print("out:", out.read().decode().strip())
print("err:", err.read().decode().strip())

# 2. Check if writing to event1 works
print("\n=== Test 2: write to event1 ===")
_, out, err = c.exec_command('python3 -c "import os; fd=os.open(\'/dev/input/event1\', os.O_WRONLY); print(\'event1 fd:\', fd); os.close(fd)"')
time.sleep(2)
print("out:", out.read().decode().strip())
print("err:", err.read().decode().strip())

# 3. Check all MiSTer processes that might interfere
print("\n=== Test 3: MiSTer processes ===")
_, out, _ = c.exec_command('ps aux | grep -i mist')
time.sleep(2)
print(out.read().decode().strip())

# 4. Read current PEEK values at $C000 and $0277 via UART diagnostic
# We can't PEEK via BASIC, but we can check UART for CPU state
print("\n=== Test 4: UART check ===")
_, out, _ = c.exec_command('stty -F /dev/ttyS1 115200 raw -echo; timeout 1 cat /dev/ttyS1 2>/dev/null | head -3')
time.sleep(3)
print(out.read().decode().strip())

# 5. Try the mtype approach from the PREVIOUS session that worked
# The difference: create the device, wait longer, then type
print("\n=== Test 5: mtype.py with verbose ===")
sftp = c.open_sftp()
sftp.put('tools/mtype.py', '/tmp/mtype.py')
sftp.close()

# Run mtype with strace to see what happens
_, out, err = c.exec_command('strace -e trace=write,ioctl python3 /tmp/mtype.py A 2>&1 | tail -30')
time.sleep(12)  # 6s device settle + typing time
o = out.read().decode()
print("strace output (last 30 lines):")
print(o[-2000:] if len(o) > 2000 else o)

# 6. Check if the physical keyboard actually works
print("\n=== Test 6: Check keyboard grab ===")
_, out, _ = c.exec_command('cat /proc/bus/input/devices | grep -A5 "8BitDo"')
time.sleep(2)
print(out.read().decode().strip())

# 7. Check if MiSTer has grabbed the event devices exclusively
print("\n=== Test 7: Check EVIOCGRAB on keyboard ===")
_, out, err = c.exec_command('python3 -c "import fcntl, os; fd=os.open(\'/dev/input/event1\', os.O_RDONLY); print(\'open ok\'); os.close(fd)" 2>&1')
time.sleep(2)
print(out.read().decode().strip())
print(err.read().decode().strip())

c.close()
print("\n[+] Done")
