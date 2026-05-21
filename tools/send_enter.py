import struct, time
f = open("/dev/input/event0", "wb")
ev = struct.pack("llHHi", 0, 0, 1, 28, 1)
syn = struct.pack("llHHi", 0, 0, 0, 0, 0)
f.write(ev); f.write(syn); f.flush()
time.sleep(0.05)
ev = struct.pack("llHHi", 0, 0, 1, 28, 0)
f.write(ev); f.write(syn); f.flush()
f.close()
