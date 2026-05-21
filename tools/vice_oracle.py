#!/usr/bin/env python3
"""ViceOracle — clean Python wrapper around VICE xscpu64's text remote-monitor.

Layer 2 of the 3-layer CPU verification environment. Consolidates patterns
from the existing tools/doom_vice_*.py and tools/vice_diff/vice_capture_*.py
scripts into a single reusable class.

Usage:
    from tools.vice_oracle import ViceOracle

    with ViceOracle() as v:
        v.load_bytes_direct(0x000800, b"\\x18\\xfb\\xc2\\x30\\xa9\\x34\\x12...")
        v.patch_word(0xFFFC, 0x00, 0x08)   # reset vector
        v.step_n(20)
        regs = v.regs()
        assert regs["a"] == 0x1234

Communication: TCP socket to 127.0.0.1:<port> (default 6510). Commands
end with "\\r\\n", responses are read until the monitor prompt "(C:$"
re-appears.

Design notes:
- VICE register-dump prefix is ".C:" in emulation mode and ".;" in native
  mode. The REG_RE handles both via an alternation group.
- `load_bytes_direct` uses VICE's `> $addr $b1 $b2 ...` poke syntax. Each
  poke is capped at ~32 bytes per call to keep monitor lines short.
- `capture_trace` uses the streaming `trace exec` pattern from
  vice_capture_chis.py (PC+IR per line, P/SP placeholder $00/$0000).
- Subprocess is spawned with creationflags=DETACHED_PROCESS on Windows so
  Popen.kill() works cleanly on shutdown.

References:
- tools/vice_diff/vice_capture_chis.py — clean monitor I/O patterns
- tools/doom_vice_zp_state.py — _parse_mem_bytes, \\r\\n endings
- tools/doom_vice_oracle.py — launch + connect retry pattern
- tools/doom_vice_state_probe.py — register parsing both modes
"""

from __future__ import annotations

import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Reuse the canonical TraceLine dataclass from vice_diff so traces from
# this oracle can feed straight into the existing diff infrastructure.
_HERE = Path(__file__).resolve().parent
_VICE_DIFF_DIR = _HERE / "vice_diff"
if str(_VICE_DIFF_DIR) not in sys.path:
    sys.path.insert(0, str(_VICE_DIFF_DIR))
from vice_diff import TraceLine  # noqa: E402  (file: tools/vice_diff/vice_diff.py)

VICE_EXE_DEFAULT = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"

PROMPT = b"(C:$"

# Register dump regex — VICE emits register lines with ".C:" prefix in
# emulation mode and ".;" in native mode. Two layout flavours observed:
#
# Wide (older VICE / SCPU 16-bit):
#   ".;  00 e5d4  1234  0056  00f0  01ff  ..."  (A/X/Y/SP as 4-hex)
#
# Narrow (VICE 3.10 xscpu64):
#   ".;00 e5d4 00 fc 00 0a f3 0000 00 00100010 1 ..."
#   format = PB ADDR  AL  AH  XL  YL  SP  DPRE DB FLAGBITS E LIN CYC
#   (A high byte = "B"; X and Y are single byte even with X=0)
#
# We match the narrow format primarily (always present in VICE 3.10);
# the wide format is also supported via a fallback regex below.
REG_RE_NARROW = re.compile(
    r"\.(?:C|;)\s*(?P<pbr>[0-9A-Fa-f]{2})\s+(?P<pc>[0-9A-Fa-f]{4})\s+"
    r"(?P<al>[0-9A-Fa-f]{2})\s+(?P<ah>[0-9A-Fa-f]{2})\s+"
    r"(?P<xl>[0-9A-Fa-f]{2})\s+(?P<yl>[0-9A-Fa-f]{2})\s+"
    r"(?P<sp>[0-9A-Fa-f]{2,4})\s+"
    r"(?P<dpre>[0-9A-Fa-f]{2,4})\s+(?P<db>[0-9A-Fa-f]{2})\s+"
    r"(?P<flags>[01]{8})\s+(?P<e>[01])"
)
# Native-mode dump (post-XCE) — VICE picks one of two layouts based on the
# X-bit (8-bit vs 16-bit X/Y):
#
# X=1 (8-bit X/Y): six byte-fields between A and SP — XH and YH expose the
# (zeroed) high halves separately.
#   ".;00 0803 00 fc 00 00 00 0a 01f3 0000 00 00110111 0 ..."
#   = PB ADDR AL AH XH XL YH YL STCK DPRE DB FLAGS E ...
REG_RE_NATIVE_8 = re.compile(
    r"\.(?:C|;)\s*(?P<pbr>[0-9A-Fa-f]{2})\s+(?P<pc>[0-9A-Fa-f]{4})\s+"
    r"(?P<al>[0-9A-Fa-f]{2})\s+(?P<ah>[0-9A-Fa-f]{2})\s+"
    r"(?P<xh>[0-9A-Fa-f]{2})\s+(?P<xl>[0-9A-Fa-f]{2})\s+"
    r"(?P<yh>[0-9A-Fa-f]{2})\s+(?P<yl>[0-9A-Fa-f]{2})\s+"
    r"(?P<sp>[0-9A-Fa-f]{4})\s+"
    r"(?P<dpre>[0-9A-Fa-f]{4})\s+(?P<db>[0-9A-Fa-f]{2})\s+"
    r"(?P<flags>[01]{8})\s+(?P<e>[01])"
)
# X=0 (16-bit X/Y): X and Y are 4-char fields directly.
#   ".;20 0014 ff 01 0000 000a 01ff 0000 00 00100100 0 ..."
#   = PB ADDR AL AH X Y STCK DPRE DB FLAGS E ...
REG_RE_NATIVE_16 = re.compile(
    r"\.(?:C|;)\s*(?P<pbr>[0-9A-Fa-f]{2})\s+(?P<pc>[0-9A-Fa-f]{4})\s+"
    r"(?P<al>[0-9A-Fa-f]{2})\s+(?P<ah>[0-9A-Fa-f]{2})\s+"
    r"(?P<x>[0-9A-Fa-f]{4})\s+(?P<y>[0-9A-Fa-f]{4})\s+"
    r"(?P<sp>[0-9A-Fa-f]{4})\s+"
    r"(?P<dpre>[0-9A-Fa-f]{4})\s+(?P<db>[0-9A-Fa-f]{2})\s+"
    r"(?P<flags>[01]{8})\s+(?P<e>[01])"
)
REG_RE_WIDE = re.compile(
    r"\.(?:C|;)\s*(?P<pbr>[0-9A-Fa-f]{2})\s+(?P<pc>[0-9A-Fa-f]{4})\s+"
    r"(?P<a>[0-9A-Fa-f]{4})\s+(?P<x>[0-9A-Fa-f]{4})\s+"
    r"(?P<y>[0-9A-Fa-f]{4})\s+(?P<sp>[0-9A-Fa-f]{4})"
)
# Public alias kept for plan compatibility
REG_RE = REG_RE_NARROW

# Memory dump regex. VICE prints lines like:
#   ">C:0800  18 fb c2 30 a9 34 12 ..."
# or sometimes ".C:0800  ..." or banked ">02:0800  ...". We accept any
# 1-2 char prefix (C/R/M/c/r/m or 2 hex digit bank), a colon, then 4 hex
# digits of address.
MEM_RE = re.compile(
    r"^\s*[>.]?\s*(?:[CRMcrm]|[0-9A-Fa-f]{2}):"
    r"(?P<addr>[0-9A-Fa-f]{4})\s+"
    r"(?P<bytes>(?:[0-9A-Fa-f]{2}\s+){1,16})"
)

# Breakpoint installation response: "BREAK: N  C:$0800  (Stop on exec)"
BP_RE = re.compile(r"BREAK:\s*(?P<num>\d+)\b", re.IGNORECASE)

# Disassembly line for trace capture: ".C:0800  18           CLC"
DISASM_RE = re.compile(
    r"^\s*\.[CR]:(?P<pc>[0-9A-Fa-f]{4})\s+(?P<ir>[0-9A-Fa-f]{2})"
)
TRACE_EXEC_RE = re.compile(r"#\d+\s+\(Trace\s+exec\s+(?P<pc>[0-9A-Fa-f]{4})\)")


class ViceOracleError(RuntimeError):
    pass


def _parse_regs_dump(out: str) -> dict:
    """Decode a VICE register dump (`r` command output) into a dict.

    Handles all four observed formats: native 8-bit-X, native 16-bit-X,
    narrow (emulation-mode 8-bit), and the wide fallback. Raises
    ViceOracleError on parse failure.
    """
    m = REG_RE_NATIVE_8.search(out)
    if m:
        return {
            "pbr": int(m["pbr"], 16),
            "pc":  int(m["pc"],  16),
            "a":   (int(m["ah"], 16) << 8) | int(m["al"], 16),
            "x":   (int(m["xh"], 16) << 8) | int(m["xl"], 16),
            "y":   (int(m["yh"], 16) << 8) | int(m["yl"], 16),
            "sp":  int(m["sp"], 16),
            "d":   int(m["dpre"], 16),
            "db":  int(m["db"], 16),
            "p":   int(m["flags"], 2),
            "e":   int(m["e"]),
        }

    m = REG_RE_NATIVE_16.search(out)
    if m:
        return {
            "pbr": int(m["pbr"], 16),
            "pc":  int(m["pc"],  16),
            "a":   (int(m["ah"], 16) << 8) | int(m["al"], 16),
            "x":   int(m["x"], 16),
            "y":   int(m["y"], 16),
            "sp":  int(m["sp"], 16),
            "d":   int(m["dpre"], 16),
            "db":  int(m["db"], 16),
            "p":   int(m["flags"], 2),
            "e":   int(m["e"]),
        }

    m = REG_RE_NARROW.search(out)
    if m:
        return {
            "pbr": int(m["pbr"], 16),
            "pc":  int(m["pc"],  16),
            "a":   (int(m["ah"], 16) << 8) | int(m["al"], 16),
            "x":   int(m["xl"], 16),
            "y":   int(m["yl"], 16),
            "sp":  int(m["sp"], 16),
            "d":   int(m["dpre"], 16),
            "db":  int(m["db"], 16),
            "p":   int(m["flags"], 2),
            "e":   int(m["e"]),
        }

    m = REG_RE_WIDE.search(out)
    if m:
        return {
            "pbr": int(m["pbr"], 16),
            "pc":  int(m["pc"],  16),
            "a":   int(m["a"],   16),
            "x":   int(m["x"],   16),
            "y":   int(m["y"],   16),
            "sp":  int(m["sp"],  16),
            "p":   0,
            "e":   0,
        }

    raise ViceOracleError(f"could not parse register dump:\n{out!r}")


class ViceOracle:
    """Drive an xscpu64 instance via its text remote-monitor."""

    def __init__(
        self,
        vice_exe: str = VICE_EXE_DEFAULT,
        port: int = 6510,
        warp: bool = True,
    ):
        self.vice_exe = vice_exe
        self.port = port
        self.warp = warp
        self._proc: Optional[subprocess.Popen] = None
        self._sock: Optional[socket.socket] = None

    # ------------------------------------------------------------------
    # Context manager
    # ------------------------------------------------------------------
    def __enter__(self) -> "ViceOracle":
        self.launch()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.shutdown()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    def launch(self, extra_args: Optional[list[str]] = None) -> None:
        """Spawn xscpu64 and connect to its remote monitor.

        Retries the TCP connect for ~10s while VICE is binding. Drains the
        initial monitor banner before returning.
        """
        if not Path(self.vice_exe).exists():
            raise ViceOracleError(f"VICE binary not found: {self.vice_exe}")

        args: list[str] = [
            self.vice_exe,
            "-remotemonitor",
            "-remotemonitoraddress", f"127.0.0.1:{self.port}",
            "-silent",
        ]
        if self.warp:
            args.append("-warp")
        if extra_args:
            args.extend(extra_args)

        # On Windows, DETACHED_PROCESS lets Popen.kill() fully terminate
        # VICE without inheriting console handles. On non-Windows we just
        # use default flags.
        creationflags = 0
        if os.name == "nt":
            creationflags = getattr(subprocess, "DETACHED_PROCESS", 0)

        self._proc = subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags,
        )

        # Connect monitor with retry — VICE takes a moment to bind.
        deadline = time.time() + 10.0
        last_err: Optional[Exception] = None
        while time.time() < deadline:
            try:
                self._sock = socket.create_connection(
                    ("127.0.0.1", self.port), timeout=2.0
                )
                break
            except OSError as e:
                last_err = e
                self._sock = None
                time.sleep(0.4)
        if self._sock is None:
            self.shutdown()
            raise ViceOracleError(
                f"could not connect to VICE monitor on 127.0.0.1:{self.port} "
                f"({last_err})"
            )

        # Drain initial banner. The monitor pauses on connect (CPU
        # stopped at whatever PC it was running). VICE 3.10 sends a
        # multi-line banner + final prompt; wait for the prompt then
        # do an extended idle drain to absorb any trailing newlines or
        # extra prompt VICE emits during banner display.
        self._expect_prompt(timeout=10.0)
        self._drain(idle_s=0.4, max_s=2.0)

    def shutdown(self) -> None:
        """Send `quit` to monitor; force-kill VICE if still alive."""
        if self._sock is not None:
            try:
                self._sock.sendall(b"quit\r\n")
            except OSError:
                pass
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._proc is not None:
            if self._proc.poll() is None:
                try:
                    self._proc.terminate()
                    self._proc.wait(timeout=3.0)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
                except OSError:
                    pass
            self._proc = None

    # ------------------------------------------------------------------
    # Low-level monitor I/O
    # ------------------------------------------------------------------
    def _drain(self, idle_s: float = 0.3, max_s: float = 2.0) -> bytes:
        """Read until socket is idle for idle_s or max_s elapses."""
        if self._sock is None:
            raise ViceOracleError("not connected")
        self._sock.settimeout(idle_s)
        buf = b""
        end = time.time() + max_s
        while time.time() < end:
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
        return buf

    def _expect_prompt(self, timeout: float = 10.0) -> bytes:
        """Read until we see the monitor prompt or timeout."""
        if self._sock is None:
            raise ViceOracleError("not connected")
        self._sock.settimeout(timeout)
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                if PROMPT in buf:
                    return buf
                continue
            if not chunk:
                break
            buf += chunk
            if PROMPT in buf:
                return buf
        return buf

    def _cmd(self, line: str, timeout: float = 10.0, min_idle: float = 0.25) -> str:
        """Send a monitor command and return the full response text.

        Drains any pre-existing socket data (stale prompts from prior
        commands or banner) before sending. After sending, reads until
        we see at least one "(C:$" prompt that arrives AFTER our send.

        VICE 3.10's monitor exhibits a timing quirk where the response
        to command N is sometimes delivered just before the prompt for
        command N+1, making it look like one-step lagged. We work
        around this by reading until the buffer contains BOTH the
        command's text echo (or non-prompt content) AND the prompt —
        i.e. don't return until we see a prompt PRECEDED by a newline
        with content on it, or wait at least `min_idle` after the last
        chunk.

        `min_idle` controls the post-prompt idle wait. The default 0.25s
        is conservative for most commands. For high-frequency
        single-step + register-read loops (capture_trace_stepwise),
        pass a smaller value (e.g. 0.05) to halve per-step RTT.
        """
        if self._sock is None:
            raise ViceOracleError("not connected")
        # Drain any stale data
        self._sock.settimeout(0.05)
        stale = b""
        while True:
            try:
                ch = self._sock.recv(65536)
                if not ch:
                    break
                stale += ch
            except socket.timeout:
                break

        self._sock.sendall((line.rstrip() + "\r\n").encode())
        # Read until prompt + idle. Once we see the prompt, wait a
        # short additional idle window to absorb any deferred response
        # text VICE flushes immediately afterwards (then re-emits as
        # the next prompt's preamble — observed in 3.10 SCPU build).
        self._sock.settimeout(min(0.1, min_idle if min_idle > 0 else 0.05))
        buf = b""
        end = time.time() + timeout
        seen_prompt = False
        last_recv_t = time.time()
        while time.time() < end:
            try:
                chunk = self._sock.recv(65536)
                last_recv_t = time.time()
            except socket.timeout:
                if seen_prompt and (time.time() - last_recv_t) > min_idle:
                    break
                continue
            if not chunk:
                break
            buf += chunk
            if PROMPT in buf:
                seen_prompt = True
                # Don't return immediately — wait briefly to see if
                # more data follows (VICE may flush response text after
                # the prompt under certain timing).
        return buf.decode(errors="replace")

    # ------------------------------------------------------------------
    # Memory: pokes + reads
    # ------------------------------------------------------------------
    def load_bytes_direct(self, addr24: int, data: bytes) -> None:
        """Poke `data` directly into VICE memory starting at addr24.

        VICE 3.10 xscpu64's monitor only accepts 16-bit addresses on the
        `>` command — no `> 20:0000`, `> $20:$0000`, or `> $200000` form
        is accepted. Cross-bank pokes use the `bank` command to select a
        SuperRAM bank (`bank ram00` .. `bank ramf7`), then bank-relative
        16-bit pokes; we restore `bank cpu` afterwards so breakpoints,
        registers, and execution use the normal CPU view.

        addr24 may include a bank byte in bits 23..16 (e.g. 0x200000
        targets bank $20:$0000). For pokes inside bank $00, just pass
        the 16-bit address.
        """
        if not data:
            return
        bank = (addr24 >> 16) & 0xFF
        offset = addr24 & 0xFFFF
        # VICE 3.10's `>` command accepts long byte lists; 64 bytes per
        # command keeps each line well within any line-length limit while
        # cutting RTT-bound load time by 4x vs 16. Combined with a short
        # min_idle, this lets us load several KB per second.
        chunk = 64
        if bank:
            # Switch monitor view to the SuperRAM bank, poke, restore cpu.
            self._cmd(f"bank ram{bank:02x}", timeout=5.0)
        try:
            i = 0
            while i < len(data):
                piece = data[i:i + chunk]
                byte_str = " ".join(f"{b:02x}" for b in piece)
                cur_addr = offset + i
                # 16-bit address with `$` prefix (required by VICE 3.10).
                line = f"> ${cur_addr:04x} {byte_str}"
                self._cmd(line, timeout=5.0, min_idle=0.05)
                i += chunk
        finally:
            if bank:
                self._cmd("bank cpu", timeout=5.0)

    def patch_word(self, addr: int, lo: int, hi: int) -> None:
        """Convenience: write two bytes (little-endian word) at addr."""
        self.load_bytes_direct(addr, bytes([lo & 0xFF, hi & 0xFF]))

    def mem(self, addr24: int, length: int) -> bytes:
        """Read `length` bytes starting at addr24 from VICE memory."""
        if length <= 0:
            return b""
        bank = (addr24 >> 16) & 0xFF
        offset = addr24 & 0xFFFF
        end_addr = (offset + length - 1) & 0xFFFF
        if bank:
            cmd_str = f"m {bank:02x}:{offset:04x} {bank:02x}:{end_addr:04x}"
        else:
            # VICE 3.10 requires `$` prefix on addresses — without it
            # `m e000 e00f` is treated as "stream from e000" (no end).
            cmd_str = f"m ${offset:04x} ${end_addr:04x}"
        out = self._cmd(cmd_str, timeout=10.0)
        return self._parse_mem_bytes(out, offset, length)

    @staticmethod
    def _parse_mem_bytes(text: str, base: int, length: int) -> bytes:
        """Parse `m` command output into a contiguous byte buffer.

        The returned buffer is exactly `length` bytes long, padded with
        $00 for any addresses that didn't appear in the dump.
        """
        result = bytearray(length)
        seen = bytearray(length)  # per-byte presence flag
        for line in text.split("\n"):
            m = MEM_RE.match(line)
            if not m:
                continue
            addr = int(m.group("addr"), 16)
            for i, hb in enumerate(m.group("bytes").split()):
                pos = (addr + i) - base
                if 0 <= pos < length:
                    try:
                        result[pos] = int(hb, 16)
                        seen[pos] = 1
                    except ValueError:
                        pass
        return bytes(result)

    # ------------------------------------------------------------------
    # Registers
    # ------------------------------------------------------------------
    def regs(self) -> dict:
        """Return current CPU registers as a dict.

        Keys: pbr, pc, a, x, y, sp, p, e (all int). The accumulator
        and index registers are returned as full 16-bit values (high
        byte from "B" column for A; high byte = $00 for X/Y in narrow
        format, since native-mode 16-bit X/Y aren't separately surfaced
        by VICE 3.10's narrow `r` output).

        p is reconstructed from the binary NV-BDIZC flag string in the
        `r` output; bit 7 = N, bit 6 = V, bit 5 = M, bit 4 = X, bit 3 = D,
        bit 2 = I, bit 1 = Z, bit 0 = C.
        """
        out = self._cmd("r", timeout=5.0)
        return _parse_regs_dump(out)

    # ------------------------------------------------------------------
    # Breakpoints
    # ------------------------------------------------------------------
    def set_breakpoint(self, pc: int, pbr: int = 0) -> int:
        """Install an exec breakpoint and return the breakpoint number.

        LIMITATION: VICE 3.10 xscpu64's `break` command only accepts 16-bit
        addresses. All cross-bank syntaxes are rejected:
            `break $20:$0030`  → Unexpected token (the colon)
            `break $200030`    → Address too large
            `break $0030 if .pb == $20`  → Unexpected token (the `if`)
        The `pbr` argument is therefore IGNORED — the breakpoint fires
        whenever PC matches the 16-bit address regardless of bank.
        Tests with stops in non-zero banks must pick a 16-bit address that
        is unreachable on any intermediate (bank $00) path.
        """
        cmd = f"break ${pc:04x}"
        out = self._cmd(cmd, timeout=5.0)
        m = BP_RE.search(out)
        if not m:
            # VICE versions sometimes print "BREAK: <num>" or
            # "Set checkpoint <num>". Fall back to a numeric scan.
            num_m = re.search(r"checkpoint\s+(\d+)", out, re.IGNORECASE)
            if num_m:
                return int(num_m.group(1))
            raise ViceOracleError(
                f"could not parse breakpoint number from:\n{out!r}"
            )
        return int(m["num"])

    def delete_breakpoint(self, bp_num: int) -> None:
        """Delete a breakpoint by its monitor-assigned number."""
        self._cmd(f"del {bp_num}", timeout=5.0)

    # ------------------------------------------------------------------
    # Stepping / running
    # ------------------------------------------------------------------
    def step_n(self, n: int) -> list[dict]:
        """Step `n` instructions, returning the register dict after each.

        Each step round-trips the monitor (~50ms typical), so this is
        suitable for short sequences (<= ~200 steps). For longer runs
        prefer `run_to` with a breakpoint or `capture_trace`.
        """
        out: list[dict] = []
        for _ in range(n):
            self._cmd("z", timeout=5.0)  # `z` = step into (one instr)
            out.append(self.regs())
        return out

    def capture_trace_stepwise(
        self,
        start_pc: int,
        stop_pc: int,
        stop_pbr: int = 0,
        max_instr: int = 200,
        start_pbr: int = 0,
        mask_irq: bool = True,
    ) -> list[TraceLine]:
        """Single-step trace via `z` + `regs()` — bank-aware (no parser hack).

        Slower than `capture_trace` (~250 ms/step due to monitor RTT) but
        produces correct PBR/PC for cross-bank execution. `capture_trace`'s
        regex assumes 16-bit PCs and hardcodes pbr=0; for any program that
        executes in bank ≠ $00 the parser silently produces garbage.

        Use this for cross-bank Doom-class workloads where each step gets
        a fresh register dump that ViceOracle.regs() decodes correctly.

        If `mask_irq` is True (default), force I-flag=1 after the start
        breakpoint hits. VICE keeps CIA timers running while warping
        through BASIC; by the time the BP fires, an IRQ is typically
        pending. Without masking, the very first `z` step services the
        IRQ instead of executing the program's first instruction —
        diverging from a DUT that holds IRQ_N inactive.
        """
        if self._sock is None:
            raise ViceOracleError("not connected")
        bp_start = self.set_breakpoint(start_pc, start_pbr)
        try:
            self._sock.sendall(f"g ${start_pc:04x}\r\n".encode())
            self._sock.settimeout(0.5)
            buf = b""
            end = time.time() + 30.0
            seen_break = False
            while time.time() < end:
                try:
                    chunk = self._sock.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                if PROMPT in buf and (b"BREAK" in buf or b"Stop" in buf):
                    seen_break = True
                    break
            if not seen_break:
                raise ViceOracleError(
                    f"start_pc ${start_pc:04x} bp did not fire (stepwise)"
                )
        finally:
            try:
                self.delete_breakpoint(bp_start)
            except ViceOracleError:
                pass

        if mask_irq:
            # Set I-flag (bit 2) on current P. VICE syntax: `r p=$NN`.
            cur = self._regs_fast()
            new_p = cur["p"] | 0x04
            self._cmd(f"r p=${new_p:02x}", timeout=5.0, min_idle=0.05)

        out: list[TraceLine] = []
        seq = 0
        # First entry: snapshot regs at the start_pc breakpoint.
        r = self._regs_fast()
        out.append(TraceLine(
            seq=seq, pbr=r["pbr"], pc=r["pc"], ir=0, p=r["p"], sp=r["sp"],
            raw=f"{seq}:{r['pbr']:02x}:{r['pc']:04x}:00:{r['p']:02x}:{r['sp']:04x}",
        ))
        seq += 1
        while seq < max_instr:
            self._cmd("z", timeout=5.0, min_idle=0.05)
            r = self._regs_fast()
            out.append(TraceLine(
                seq=seq, pbr=r["pbr"], pc=r["pc"], ir=0, p=r["p"], sp=r["sp"],
                raw=f"{seq}:{r['pbr']:02x}:{r['pc']:04x}:00:{r['p']:02x}:{r['sp']:04x}",
            ))
            seq += 1
            if r["pbr"] == stop_pbr and r["pc"] == stop_pc:
                break
        return out

    def _regs_fast(self) -> dict:
        """Like regs() but uses min_idle=0.05 for stepwise capture loops."""
        out = self._cmd("r", timeout=5.0, min_idle=0.05)
        return _parse_regs_dump(out)

    def load_bank_file(self, bank: int, host_path: str,
                       addr: int = 0x0000) -> None:
        """bload `host_path` into bank:addr via VICE's monitor `bload`.

        VICE 3.10's monitor lacks save_snapshot/load_snapshot; bulk byte
        transfer goes through `bload "<path>" <device> <addr>` (device 0
        = host filesystem). Each call sends one TCP message and VICE
        does the file read locally — far faster than the 64-byte `>`
        pokes used by load_bytes_direct (~0.2s vs ~50s per 64KB).

        Bank routing:
          * bank == 0: bload twice — once to default cpu memspace
            (motherboard RAM, where the CPU reads in EMULATION mode
            before SCPU is enabled) AND once to `bank ram00` (SCPU SRAM,
            where the CPU reads in NATIVE+SCPU mode). This matches the
            bank20 test's pattern of dual-write so reads are correct
            regardless of which mode the CPU happens to be in.
          * bank > 0: bload via `bank ramXX` switch (SCPU SuperRAM).
            Restore `bank cpu` after.
        """
        # VICE wants forward slashes inside the quoted path. Backslash
        # escaping inside the monitor parser is unreliable.
        path_str = str(host_path).replace("\\", "/")
        # Precheck only for Linux-style paths; a Windows-style "C:/..."
        # path (passed in from WSL2 cocotb when VICE.exe runs natively
        # on Windows) is unreachable via Path() from WSL but IS what
        # VICE needs. Trust VICE's error response in that case.
        if not (len(path_str) >= 2 and path_str[1] == ":"):
            if not Path(path_str).exists():
                raise ViceOracleError(f"bload source missing: {path_str}")
        if bank == 0:
            # 1) motherboard (default cpu memspace)
            self._cmd(f'bload "{path_str}" 0 ${addr:04x}',
                      timeout=15.0, min_idle=0.3)
            # 2) SCPU SRAM bank ram00
            self._cmd("bank ram00", timeout=5.0)
            try:
                self._cmd(f'bload "{path_str}" 0 ${addr:04x}',
                          timeout=15.0, min_idle=0.3)
            finally:
                self._cmd("bank cpu", timeout=5.0)
        else:
            self._cmd(f"bank ram{bank:02x}", timeout=5.0)
            try:
                self._cmd(f'bload "{path_str}" 0 ${addr:04x}',
                          timeout=15.0, min_idle=0.3)
            finally:
                self._cmd("bank cpu", timeout=5.0)

    def capture_trace_from_current(
        self,
        max_instr: int,
        mask_irq: bool = True,
    ) -> list[TraceLine]:
        """Stepwise trace from VICE's current paused state.

        Unlike capture_trace_stepwise(), this does NOT install a start
        breakpoint or `g` to it. VICE is assumed already paused at the
        desired starting PC (e.g. just after load_snapshot()). Captures
        the snapshot regs as the first TraceLine, then `z`-steps for
        max_instr-1 more lines.

        Use for: VICE state restored from .vsf, diff vs a DUT that
        bootstrapped to the same PC.
        """
        if self._sock is None:
            raise ViceOracleError("not connected")

        if mask_irq:
            cur = self._regs_fast()
            new_p = cur["p"] | 0x04
            self._cmd(f"r p=${new_p:02x}", timeout=5.0, min_idle=0.05)

        out: list[TraceLine] = []
        seq = 0
        r = self._regs_fast()
        out.append(TraceLine(
            seq=seq, pbr=r["pbr"], pc=r["pc"], ir=0,
            p=r["p"], sp=r["sp"],
            raw=f"{seq}:{r['pbr']:02x}:{r['pc']:04x}:00:{r['p']:02x}:{r['sp']:04x}",
        ))
        seq += 1
        while seq < max_instr:
            self._cmd("z", timeout=5.0, min_idle=0.05)
            r = self._regs_fast()
            out.append(TraceLine(
                seq=seq, pbr=r["pbr"], pc=r["pc"], ir=0,
                p=r["p"], sp=r["sp"],
                raw=f"{seq}:{r['pbr']:02x}:{r['pc']:04x}:00:{r['p']:02x}:{r['sp']:04x}",
            ))
            seq += 1
        return out

    def run_to(
        self,
        pc: int,
        pbr: int = 0,
        timeout: float = 30.0,
        start_pc: Optional[int] = None,
    ) -> dict:
        """Continue execution until pc[/pbr] is hit, then return regs().

        Installs a temporary breakpoint, issues `g` (or `g $<start_pc>`
        if start_pc is given), waits for the break message, then deletes
        the breakpoint.
        """
        if self._sock is None:
            raise ViceOracleError("not connected")
        bp = self.set_breakpoint(pc, pbr)
        try:
            if start_pc is not None:
                go_cmd = f"g ${start_pc:04x}\r\n".encode()
            else:
                go_cmd = b"g\r\n"
            self._sock.sendall(go_cmd)
            self._sock.settimeout(0.5)
            buf = b""
            end = time.time() + timeout
            while time.time() < end:
                try:
                    chunk = self._sock.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                if PROMPT in buf and (b"BREAK" in buf or b"Stop" in buf):
                    break
            return self.regs()
        finally:
            try:
                self.delete_breakpoint(bp)
            except ViceOracleError:
                pass

    # ------------------------------------------------------------------
    # Bulk trace capture
    # ------------------------------------------------------------------
    def capture_trace(
        self,
        start_pc: int,
        stop_pc: int,
        max_instr: int = 100_000,
        start_pbr: int = 0,
        stop_pbr: int = 0,
        timeout: float = 600.0,
    ) -> list[TraceLine]:
        """Stream a PC+IR trace from start_pc up to (but not including) stop_pc.

        Pattern follows tools/vice_diff/vice_capture_chis.py: install a
        breakpoint at start_pc, `g`, wait for hit, install
        `trace exec $0000-$ffff` and a stop breakpoint, then `g` and
        stream-parse Trace event + disasm pairs.

        Returned TraceLine has p=0, sp=0 (placeholders — VICE's trace
        doesn't emit P/SP per-instruction).
        """
        if self._sock is None:
            raise ViceOracleError("not connected")
        # Arm start. Use `g $<start_pc>` not bare `g` so VICE jumps directly
        # to the test program — bare `g` resumes from wherever the KERNAL
        # boot left PC (typically the BASIC idle loop), which never reaches
        # an injected program in RAM.
        bp_start = self.set_breakpoint(start_pc, start_pbr)
        self._sock.sendall(f"g ${start_pc:04x}\r\n".encode())
        self._sock.settimeout(2.0)
        buf = b""
        end = time.time() + timeout
        seen_break = False
        while time.time() < end:
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            buf += chunk
            if PROMPT in buf and (b"BREAK" in buf or b"Stop" in buf):
                seen_break = True
                break
        if not seen_break:
            raise ViceOracleError(
                f"start_pc ${start_pc:04x} breakpoint did not fire in {timeout}s"
            )
        try:
            self.delete_breakpoint(bp_start)
        except ViceOracleError:
            pass

        # Arm trace + stop
        self._cmd("trace exec $0000 $ffff", timeout=5.0)
        bp_stop = self.set_breakpoint(stop_pc, stop_pbr)

        out: list[TraceLine] = []
        last_pc_evt: Optional[int] = None
        seq = 0
        carry = b""

        self._sock.sendall(b"g\r\n")
        self._sock.settimeout(2.0)
        end = time.time() + timeout
        try:
            while time.time() < end and seq < max_instr:
                try:
                    chunk = self._sock.recv(262144)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf2 = carry + chunk
                lines = buf2.split(b"\n")
                carry = lines[-1]
                for raw in lines[:-1]:
                    line = raw.decode(errors="replace").rstrip()
                    m_evt = TRACE_EXEC_RE.search(line)
                    if m_evt:
                        last_pc_evt = int(m_evt["pc"], 16)
                        continue
                    m_dis = DISASM_RE.match(line)
                    if m_dis and last_pc_evt is not None:
                        pc_v = int(m_dis["pc"], 16)
                        if pc_v == last_pc_evt:
                            ir = int(m_dis["ir"], 16)
                            tl = TraceLine(
                                seq=seq, pbr=0, pc=pc_v, ir=ir, p=0, sp=0,
                                raw=f"{seq}:00:{pc_v:04x}:{ir:02x}:00:0000",
                            )
                            out.append(tl)
                            seq += 1
                            last_pc_evt = None
                            if seq >= max_instr:
                                break
                stop_marker = f"(Stop on  exec {stop_pc:04x})".encode().lower()
                if stop_marker in buf2.lower():
                    break
        finally:
            try:
                self.delete_breakpoint(bp_stop)
            except ViceOracleError:
                pass
        return out


# ----------------------------------------------------------------------
# Smoke entry
# ----------------------------------------------------------------------
if __name__ == "__main__":
    # Minimal self-test: launch and shut down cleanly.
    with ViceOracle() as v:
        r = v.regs()
        print(f"connected; pbr=${r['pbr']:02x} pc=${r['pc']:04x}")
