#!/usr/bin/env python3
"""Test different methods of remotely opening the MiSTer OSD."""
import sys
import time
sys.path.insert(0, 'tools')
from mister_debug import ssh, scp_to

def method_event1_direct():
    """Write F12 keypress directly to /dev/input/event1 (the keyboard device)."""
    print("=== Method 1: Direct write to /dev/input/event1 ===")
    script = (
        'import struct, time\n'
        'f = open("/dev/input/event1", "wb")\n'
        'ev = struct.pack("llHHI", 0, 0, 1, 88, 1)\n'
        'f.write(ev)\n'
        'syn = struct.pack("llHHI", 0, 0, 0, 0, 0)\n'
        'f.write(syn)\n'
        'f.flush()\n'
        'time.sleep(0.1)\n'
        'ev = struct.pack("llHHI", 0, 0, 1, 88, 0)\n'
        'f.write(ev)\n'
        'f.write(syn)\n'
        'f.flush()\n'
        'f.close()\n'
        'print("F12 sent to event1")\n'
    )
    # Write the script to MiSTer and run it
    import tempfile, os
    with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as tf:
        tf.write(script)
        tf.flush()
        local_path = tf.name
    scp_to(local_path, '/tmp/send_f12.py')
    os.unlink(local_path)
    out, err, rc = ssh('python3 /tmp/send_f12.py', timeout=10)
    print(f"  rc={rc} out=[{out}] err=[{err}]")
    return rc == 0

def method_uinput():
    """Create a uinput virtual keyboard and send F12."""
    print("=== Method 2: uinput virtual keyboard ===")
    script = (
        'import struct, time, os, fcntl\n'
        '\n'
        '# uinput constants\n'
        'UI_SET_EVBIT = 0x40045564\n'
        'UI_SET_KEYBIT = 0x40045565\n'
        'UI_DEV_CREATE = 0x5501\n'
        'UI_DEV_DESTROY = 0x5502\n'
        'EV_KEY = 1\n'
        'EV_SYN = 0\n'
        'KEY_F12 = 88\n'
        '\n'
        'fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)\n'
        'fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)\n'
        'fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_F12)\n'
        '\n'
        '# uinput_user_dev struct: name(80) + id(bustype,vendor,product,version=8) + ff_max(4) + absmax(64*4) + absmin(64*4) + absfuzz(64*4) + absflat(64*4)\n'
        'name = b"MiSTer Virtual KB" + b"\\x00" * 63  # 80 bytes\n'
        'dev_struct = name + struct.pack("<HHHHi", 0x03, 0x1234, 0x5678, 1, 0)\n'
        'dev_struct += b"\\x00" * (64 * 4 * 4)  # abs arrays\n'
        'os.write(fd, dev_struct)\n'
        'fcntl.ioctl(fd, UI_DEV_CREATE)\n'
        'time.sleep(0.5)  # let device settle\n'
        '\n'
        '# Send F12 press\n'
        'ev = struct.pack("llHHI", 0, 0, EV_KEY, KEY_F12, 1)\n'
        'os.write(fd, ev)\n'
        'syn = struct.pack("llHHI", 0, 0, EV_SYN, 0, 0)\n'
        'os.write(fd, syn)\n'
        'time.sleep(0.1)\n'
        '\n'
        '# Send F12 release\n'
        'ev = struct.pack("llHHI", 0, 0, EV_KEY, KEY_F12, 0)\n'
        'os.write(fd, ev)\n'
        'os.write(fd, syn)\n'
        'time.sleep(0.3)\n'
        '\n'
        'fcntl.ioctl(fd, UI_DEV_DESTROY)\n'
        'os.close(fd)\n'
        'print("F12 sent via uinput")\n'
    )
    import tempfile, os
    with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as tf:
        tf.write(script)
        tf.flush()
        local_path = tf.name
    scp_to(local_path, '/tmp/send_f12_uinput.py')
    os.unlink(local_path)
    out, err, rc = ssh('python3 /tmp/send_f12_uinput.py', timeout=10)
    print(f"  rc={rc} out=[{out}] err=[{err}]")
    return rc == 0

def method_mtype():
    """Use the existing mtype.py tool to send F12."""
    print("=== Method 3: mtype.py f12 ===")
    scp_to('tools/mtype.py', '/tmp/mtype.py')
    out, err, rc = ssh('python3 /tmp/mtype.py f12', timeout=10)
    print(f"  rc={rc} out=[{out}] err=[{err}]")
    return rc == 0

def method_evemu():
    """Use evemu-event if available."""
    print("=== Method 4: evemu-event ===")
    out, err, rc = ssh('which evemu-event 2>/dev/null', timeout=5)
    if rc != 0:
        print("  evemu-event not available")
        return False
    out, err, rc = ssh(
        'evemu-event /dev/input/event1 --type EV_KEY --code KEY_F12 --value 1 --sync; '
        'sleep 0.1; '
        'evemu-event /dev/input/event1 --type EV_KEY --code KEY_F12 --value 0 --sync',
        timeout=10)
    print(f"  rc={rc} out=[{out}] err=[{err}]")
    return rc == 0

def method_input_event_raw():
    """Write raw input_event bytes using dd to the keyboard device."""
    print("=== Method 5: Raw dd to /dev/input/event1 ===")
    # input_event on ARM32: struct timeval(8 bytes) + type(2) + code(2) + value(4) = 16 bytes
    # F12 press: type=1 code=88(0x58) value=1
    # printf the bytes directly
    out, err, rc = ssh(
        r"printf '\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x58\x00\x01\x00\x00\x00' > /dev/input/event1; "
        r"printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > /dev/input/event1; "
        r"sleep 0.1; "
        r"printf '\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x58\x00\x00\x00\x00\x00' > /dev/input/event1; "
        r"printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > /dev/input/event1",
        timeout=10)
    print(f"  rc={rc} out=[{out}] err=[{err}]")
    return rc == 0

if __name__ == '__main__':
    if len(sys.argv) > 1:
        method = sys.argv[1]
        methods = {
            '1': method_event1_direct,
            '2': method_uinput,
            '3': method_mtype,
            '4': method_evemu,
            '5': method_input_event_raw,
        }
        if method in methods:
            methods[method]()
        else:
            print(f"Unknown method: {method}. Use 1-5.")
    else:
        print("Testing all methods to open MiSTer OSD remotely...")
        print("Check your MiSTer display after each method.\n")
        for i, (name, func) in enumerate([
            ('1', method_event1_direct),
            ('2', method_uinput),
            ('3', method_mtype),
            ('4', method_evemu),
            ('5', method_input_event_raw),
        ], 1):
            func()
            print(f"  >>> Did OSD open? Waiting 5s before next method...")
            # Close OSD if it opened (send F12 again)
            time.sleep(5)
            print()
