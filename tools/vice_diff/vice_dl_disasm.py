"""Quick VICE disasm-at-stuck-PC inspector for DL.

After confirming xscpu64 hangs at PC=$3095 with VIC at default state,
we want to see what DL is actually doing there. Dumps:
  - disasm $3080-$30B0 around the stuck PC
  - registers
  - $D000-$D02F (VIC), $DD00-$DD0F (CIA2)
  - bank-$F0 byte to confirm CMD SuperCPU kickstart ROM is mapped
  - Memory at $3000-$3100 (the DL code that contains $3095)
"""
import socket, subprocess, sys, time
from pathlib import Path

VICE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
PRG = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
REU = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
OUT = r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_dl_disasm.log"
PORT = 6510


def drain(sock, idle=0.4, max_wait=5.0):
    sock.settimeout(idle)
    buf = b""
    end = time.time() + max_wait
    while time.time() < end:
        try:
            c = sock.recv(65536)
            if not c: break
            buf += c
        except socket.timeout:
            break
    return buf.decode(errors="replace")


def cmd(sock, line, max_wait=4.0):
    drain(sock, 0.05, 0.2)
    sock.sendall((line + "\n").encode())
    return drain(sock, 0.4, max_wait)


def main():
    args = [VICE, "-autostart", PRG, "-remotemonitor",
            "-remotemonitoraddress", f"127.0.0.1:{PORT}",
            "-reu", "-reusize", "16384", "-reuimage", REU,
            "+reuimagerw", "-warp", "-silent"]
    proc = subprocess.Popen(args)
    sock = None
    try:
        end = time.time() + 15
        while time.time() < end:
            try:
                sock = socket.create_connection(("127.0.0.1", PORT), timeout=2)
                break
            except OSError:
                time.sleep(0.5)
        drain(sock, 0.3, 5.0)

        # Resume autostart, settle
        sock.sendall(b"x\n")
        print("[run] settling 60s...")
        time.sleep(60)

        # Break
        sock.sendall(b"\n")
        drain(sock, 0.3, 3.0)

        with open(OUT, "w", encoding="utf-8") as fh:
            for line in [
                "r",                        # registers
                "dis $3080 $30c0",          # disasm around stuck PC
                "m $3000 $30ff",            # raw bytes around stuck region
                "m $d000 $d02f",            # VIC
                "m $dd00 $dd0f",            # CIA2
                # SuperCPU registers - $D07x
                "m $d070 $d07f",
                # Bank $F8 (kickstart ROM) — sample first 64 bytes
                "m $f80000 $f8003f",
                # First few bytes of bank $00 to see if loader copied data
                "m $0801 $0830",
                # Confirm we're in emu mode (E flag) via R
            ]:
                fh.write(f"\n=== {line} ===\n")
                out = cmd(sock, line, max_wait=3.0)
                fh.write(out)
                print(f"  ran: {line!r}")
        print(f"[done] -> {OUT}")
    finally:
        if sock:
            try: sock.sendall(b"quit\n")
            except OSError: pass
            sock.close()
        if proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill()


if __name__ == "__main__":
    main()
