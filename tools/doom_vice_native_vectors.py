#!/usr/bin/env python3
"""Dump $00:$FFE0-$FFEF + IRQ handler entry in VICE Doom.

Hypothesis: our v286 RTL intercept maps all native vectors to RTI sink.
If VICE has DIFFERENT bytes at $00:$FFE0-$FFEF (e.g., real handler addrs),
Doom's IRQ handlers run in VICE but not on hardware.

Also: pause VICE at random, follow the IRQ vector, see where it goes.
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_native_vectors"
PORT     = 6510
PROMPT   = b"(C:$"


def expect_prompt(s, timeout=10.0):
    s.settimeout(min(timeout, 2.0))
    buf = b""
    end = time.time() + timeout
    last_t = time.time()
    while time.time() < end:
        try:
            ch = s.recv(65536); last_t = time.time()
        except socket.timeout:
            if PROMPT in buf and (time.time() - last_t) > 0.3:
                return buf
            continue
        if not ch: break
        buf += ch
    return buf


def cmd(s, line, timeout=10.0):
    s.sendall((line.rstrip() + "\r\n").encode())
    return expect_prompt(s, timeout=timeout).decode(errors="replace")


def drain(s, idle_s=0.4, max_s=3.0):
    s.settimeout(idle_s)
    buf = b""
    end = time.time() + max_s
    while time.time() < end:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            break
        if not ch: break
        buf += ch
    return buf


def safe_print(s):
    try:
        print(s)
    except UnicodeEncodeError:
        sys.stdout.buffer.write(s.encode('utf-8', errors='replace'))
        sys.stdout.buffer.write(b'\n')


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    args = [
        VICE_EXE,
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", DOOM_REU,
        "-autostartprgmode", "1",
        "-autostart", DOOM_LDR,
        "-remotemonitor",
        "-remotemonitoraddress", "127.0.0.1:{}".format(PORT),
        "-warp",
        "+sound",
    ]
    print("Launching VICE")
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("waiting 30s for warp boot ...")
    time.sleep(30)

    s = None
    for _ in range(10):
        try:
            s = socket.socket(); s.settimeout(3); s.connect(("127.0.0.1", PORT))
            break
        except (socket.timeout, ConnectionRefusedError):
            s = None; time.sleep(1)
    if not s:
        print("ERROR: monitor never came up"); p.terminate(); return 1
    print("monitor connected")
    drain(s)

    out_log = []

    out_r = cmd(s, "r", timeout=5)
    out_log.append(("regs", out_r))
    print("regs:", out_r[:200])

    # Dump $00:$FFE0-$FFEF (native vectors). Use 16-bit syntax — bank $00 default.
    # If xscpu64 only has bank $00 mapped to "ramN" name, that should still work.
    out1 = cmd(s, "m $ffe0 $ffef", timeout=5)
    out_log.append(("vec_native", out1))
    print("\n$00:$FFE0-$FFEF (native vectors):")
    safe_print(out1)

    out2 = cmd(s, "m $fff0 $ffff", timeout=5)
    out_log.append(("vec_emu", out2))
    print("\n$00:$FFF0-$FFFF (emu vectors):")
    safe_print(out2)

    # Also dump $00:$FF00-$FF10 — our hardware RTI sink area
    out3 = cmd(s, "m $ff00 $ff20", timeout=5)
    out_log.append(("rti_sink", out3))
    print("\n$00:$FF00-$FF20:")
    safe_print(out3)

    # Stop the running CPU (in case it isn't at a break) and disassemble vector targets
    # First, parse vector bytes to find IRQ target
    # Format: "  >C:ffe0 .. .. .. ..  ...."
    def parse_mem(text, start_addr):
        """Parse VICE m output into a dict of addr->byte."""
        result = {}
        for line in text.split("\n"):
            mre = re.match(r"\s*\>?C:([0-9a-fA-F]{4})\s+([0-9a-fA-F\s]+?)(?:\s\s|\s\W|$)", line)
            if mre:
                base = int(mre.group(1), 16)
                hex_bytes = mre.group(2).split()
                for i, hb in enumerate(hex_bytes):
                    try:
                        result[base + i] = int(hb, 16)
                    except ValueError:
                        pass
        return result

    vmem = parse_mem(out1 + "\n" + out2, 0xffe0)
    print(f"\nparsed {len(vmem)} bytes")

    def vec(addr_lo):
        lo = vmem.get(addr_lo, None)
        hi = vmem.get(addr_lo + 1, None)
        if lo is None or hi is None:
            return None
        return (hi << 8) | lo

    cop_v = vec(0xffe4); brk_v = vec(0xffe6); abort_v = vec(0xffe8)
    nmi_v = vec(0xffea); irq_v = vec(0xffee)
    nmi_e = vec(0xfffa); res_e = vec(0xfffc); irq_e = vec(0xfffe)
    print(f"\nvectors:")
    print(f"  COP   $FFE4 = {cop_v:#06x}" if cop_v else "  COP   $FFE4 = ?")
    print(f"  BRK-N $FFE6 = {brk_v:#06x}" if brk_v else "  BRK-N $FFE6 = ?")
    print(f"  ABRT  $FFE8 = {abort_v:#06x}" if abort_v else "  ABRT  $FFE8 = ?")
    print(f"  NMI-N $FFEA = {nmi_v:#06x}" if nmi_v else "  NMI-N $FFEA = ?")
    print(f"  IRQ-N $FFEE = {irq_v:#06x}" if irq_v else "  IRQ-N $FFEE = ?")
    print(f"  NMI-E $FFFA = {nmi_e:#06x}" if nmi_e else "  NMI-E $FFFA = ?")
    print(f"  RES-E $FFFC = {res_e:#06x}" if res_e else "  RES-E $FFFC = ?")
    print(f"  IRQ-E $FFFE = {irq_e:#06x}" if irq_e else "  IRQ-E $FFFE = ?")

    # If we got an IRQ-N target, disassemble that area
    if irq_v and irq_v != 0xff00:
        print(f"\ndisass IRQ-native target ${irq_v:04x} ...")
        out_d = cmd(s, f"disass ${irq_v:04x} ${irq_v+0x40:04x}", timeout=5)
        out_log.append(("irq_target", out_d))
        safe_print(out_d)

    if brk_v and brk_v != 0xff00:
        print(f"\ndisass BRK-native target ${brk_v:04x} ...")
        out_d = cmd(s, f"disass ${brk_v:04x} ${brk_v+0x20:04x}", timeout=5)
        out_log.append(("brk_target", out_d))
        safe_print(out_d)

    # Save full result
    result_path = os.path.join(OUT_DIR, "result.txt")
    with open(result_path, 'w', errors='replace') as f:
        f.write("VICE Doom native + emu vectors at $00:$FFE0-$FFFF\n")
        f.write("=" * 70 + "\n\n")
        for label, text in out_log:
            f.write(f"--- {label} ---\n{text}\n\n")
    print("\nwrote", result_path)

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
