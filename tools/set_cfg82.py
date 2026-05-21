#!/usr/bin/env python3
"""Toggle status[82] in /media/fat/config/C64.cfg."""
import sys
sys.path.insert(0, 'tools')
from mister_debug import ssh, _get_ssh_client

want_82 = int(sys.argv[1]) if len(sys.argv) > 1 else 1

client = _get_ssh_client()
sftp = client.open_sftp()
with sftp.open('/media/fat/config/C64.cfg', 'rb') as f:
    data = bytearray(f.read())

print(f"Before: byte[10] = 0x{data[10]:02X}")
if want_82:
    data[10] |= 0x04
else:
    data[10] &= ~0x04
print(f"After:  byte[10] = 0x{data[10]:02X}")

with sftp.open('/media/fat/config/C64.cfg', 'wb') as f:
    f.write(bytes(data))
sftp.close()
client.close()
print(f"Wrote {len(data)} bytes; status[82]={'1' if want_82 else '0'}")
