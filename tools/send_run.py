import struct, time

def send_key(fd, code, val):
    ev = struct.pack("llHHi", 0, 0, 1, code, val)
    syn = struct.pack("llHHi", 0, 0, 0, 0, 0)
    fd.write(ev)
    fd.write(syn)
    fd.flush()

def tap_key(fd, code):
    send_key(fd, code, 1)
    time.sleep(0.02)
    send_key(fd, code, 0)
    time.sleep(0.05)

f = open("/dev/input/event5", "wb")
# R=19, U=22, N=49, ENTER=28
tap_key(f, 19)  # R
tap_key(f, 22)  # U
tap_key(f, 49)  # N
tap_key(f, 28)  # Enter
f.close()
print("Done")
