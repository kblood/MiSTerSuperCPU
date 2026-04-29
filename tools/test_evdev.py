#!/usr/bin/env python3
"""Test keyboard injection via direct evdev write to real keyboard device."""
import paramiko, time

HOST = '192.168.50.130'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username='root', password='1', timeout=10)

# Inject 'A' key event directly to event1 (real keyboard)
script = r"""
import struct, os, time
EV_KEY = 1
EV_SYN = 0
fd = os.open('/dev/input/event1', os.O_WRONLY)
now = int(time.time())
os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 30, 1))
os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
time.sleep(0.05)
os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 30, 0))
os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
os.close(fd)
print('sent A via event1')
"""

_, out, err = c.exec_command(f"python3 -c '{script}'")
time.sleep(3)
print('out:', out.read().decode())
print('err:', err.read().decode())
c.close()
