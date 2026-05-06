"""Dump VICE xscpu64's full gameplay state for the cocotb diff harness.

Probe 1 of the post-LOCKSTEP investigation. The cocotb+VICE diff has
proven the P65C816 microcode runs Doom's post-loader dispatcher walk
all the way to the music-error trap ($2C:$A95C) in **lockstep** with
VICE — both sides produced by pre-loading raw doom.reu bytes into
SuperRAM and JMLing into bank $20.

But VICE-real running the autostart loader REACHES gameplay
(`PB=$2A PC=$55A1` per memory `project_doom_vice_oracle_runs_doom.md`).
The disconnect between "VICE-with-prepop reaches trap" and "VICE-with-
loader reaches gameplay" implies the LOADER produces some state we are
not capturing — likely modifications during REU FETCH + long-stores
that aren't in the raw doom.reu image.

This tool captures VICE's complete state at gameplay, so a follow-on
cocotb test can:
  1. Pre-populate DUT memory with the EXACT same gameplay state.
  2. Bootstrap into the same PC with the same regs.
  3. Step DUT and VICE side-by-side from gameplay.

If DUT diverges -> P65C816 bug on a gameplay-only opcode path.
If DUT matches  -> bug is upstream in the loader; cocotb needs an
                  REU model (handoff probe A).

Usage:
    python tools/vice_dump_gameplay_state.py \\
        --out tools/vice_oracle/gameplay \\
        --warp-secs 90

Output (overwritten):
    {out}/regs.json     — CPU register dict at capture moment
    {out}/bank00.bin    — 64KB motherboard RAM
    {out}/bank{XX}.bin  — 64KB SuperRAM bank, only if non-empty
    {out}/manifest.json — list of populated banks + warp time + reg sanity
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from vice_oracle import ViceOracle, VICE_EXE_DEFAULT  # type: ignore

LOADER_PRG = REPO / "loader.prg"
DOOM_REU = REPO / "doom.reu"

# VICE monitor `m` output regex. Each line looks like:
#   ">C:0000  18 fb c2 30 ..."   (bank cpu)
#   ">20:0000  ea ea ..."        (bank ram20)
# The 4-hex-digit address starts after the `:`.
MEM_LINE_RE = re.compile(
    r"^\s*[>.]?\s*(?:[CRMcrm]|[0-9A-Fa-f]{2}):"
    r"(?P<addr>[0-9A-Fa-f]{4})\s+"
    r"(?P<bytes>(?:[0-9A-Fa-f]{2}\s+){1,16})"
)


def _dump_bank(v: ViceOracle, bank: int) -> bytes:
    """Dump a full 64KB bank from VICE.

    Bank $00 uses the default cpu memspace (motherboard RAM).
    Bank $01..$FF use SuperCPU SRAM via `bank ramXX` switch.

    Returns bytes(0x10000). Missing addresses are 0x00.
    """
    if bank == 0x00:
        # Bank $00 = motherboard RAM via default cpu memspace.
        out = v._cmd("m $0000 $ffff", timeout=30.0, min_idle=0.5)
    else:
        v._cmd(f"bank ram{bank:02x}", timeout=5.0)
        try:
            out = v._cmd("m $0000 $ffff", timeout=30.0, min_idle=0.5)
        finally:
            v._cmd("bank cpu", timeout=5.0)

    buf = bytearray(0x10000)
    for line in out.split("\n"):
        m = MEM_LINE_RE.match(line)
        if not m:
            continue
        addr = int(m.group("addr"), 16)
        for i, hb in enumerate(m.group("bytes").split()):
            pos = addr + i
            if 0 <= pos < 0x10000:
                try:
                    buf[pos] = int(hb, 16)
                except ValueError:
                    pass
    return bytes(buf)


def _is_empty(buf: bytes) -> bool:
    """True if the bank is uninitialized (all $00 or all $EA)."""
    if not buf:
        return True
    first = buf[0]
    if first not in (0x00, 0xEA):
        return False
    return all(b == first for b in buf)


def _probe_nonempty(v: ViceOracle, bank: int) -> bool:
    """Quick check: does this bank have non-zero/non-$EA content?

    Probes 5 addresses across the bank ($0000, $1000, $5000, $A000, $E000).
    Returns True if ANY probe byte is not in {$00, $EA}. Avoids dumping
    the full 64KB just to discover it's empty.
    """
    if bank == 0x00:
        v._cmd("bank cpu", timeout=5.0)
        memspace = ""
    else:
        v._cmd(f"bank ram{bank:02x}", timeout=5.0)
        memspace = ""
    try:
        for offset in (0x0000, 0x1000, 0x5000, 0xA000, 0xE000):
            out = v._cmd(f"m ${offset:04x} ${offset+15:04x}",
                         timeout=5.0, min_idle=0.1)
            for line in out.split("\n"):
                m = MEM_LINE_RE.match(line)
                if not m:
                    continue
                for hb in m.group("bytes").split():
                    try:
                        b = int(hb, 16)
                        if b not in (0x00, 0xEA):
                            return True
                    except ValueError:
                        pass
        return False
    finally:
        if bank != 0x00:
            v._cmd("bank cpu", timeout=5.0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path, required=True,
                    help="output directory for snapshot (created if missing)")
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    ap.add_argument("--warp-secs", type=float, default=90.0,
                    help="seconds of warp wallclock to wait before pause")
    ap.add_argument("--bank-min", type=lambda s: int(s, 0), default=0x00,
                    help="lowest bank to scan (default 0x00; accepts 0xNN)")
    ap.add_argument("--bank-max", type=lambda s: int(s, 0), default=0x8F,
                    help="highest bank to scan (default 0x8F = end of "
                         "Doom's REU image; raise to see more)")
    ap.add_argument("--no-probe", action="store_true",
                    help="dump every bank in range without probing first")
    ap.add_argument("--save-snapshot", type=pathlib.Path,
                    help="if set, also save VICE snapshot (.vsf) at the "
                         "same paused moment so the cocotb diff test can "
                         "reload VICE state without re-poking every byte. "
                         "Path passed to VICE monitor `save_snapshot`.")
    args = ap.parse_args()

    if not LOADER_PRG.exists():
        print(f"ERROR: {LOADER_PRG} not found", file=sys.stderr)
        return 2
    if not DOOM_REU.exists():
        print(f"ERROR: {DOOM_REU} not found", file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)

    extra = [
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", str(DOOM_REU),
        "-autostartprgmode", "1",
        "-autostart", str(LOADER_PRG),
        "+sound",
    ]

    print(f"Launching xscpu64 with REU={DOOM_REU.name} autostart={LOADER_PRG.name}")
    t_launch = time.time()
    v = ViceOracle(vice_exe=args.vice)
    populated_banks: list[int] = []
    regs: dict = {}
    try:
        v.launch(extra_args=extra)

        # Resume; let warp run until loader+game reach steady state.
        print(f"Resuming execution for {args.warp_secs}s of warp wallclock...")
        v._sock.sendall(b"x\r\n")
        time.sleep(args.warp_secs)

        # Force pause back into monitor.
        v._sock.sendall(b"\r\n")
        time.sleep(0.5)
        v._drain(idle_s=0.5, max_s=3.0)

        wall = time.time() - t_launch
        regs = v.regs()
        print(f"After {wall:.1f}s wall: PBR=${regs['pbr']:02x} "
              f"PC=${regs['pc']:04x} A=${regs['a']:04x} "
              f"X=${regs['x']:04x} Y=${regs['y']:04x} "
              f"SP=${regs['sp']:04x} P=${regs['p']:02x} E={regs['e']}")

        # Sanity: warn if PC suggests we're stuck in error trap or boot.
        if regs["pbr"] == 0x2C and regs["pc"] == 0xA95C:
            print("WARNING: VICE landed in $2C:$A95C music-error trap. "
                  "Snapshot will reflect trap state, not gameplay.",
                  file=sys.stderr)
        elif regs["pbr"] < 0x20:
            print(f"WARNING: PBR=${regs['pbr']:02x} below $20 — VICE may "
                  "still be in loader/KERNAL. Try larger --warp-secs.",
                  file=sys.stderr)

        # Capture stack-top bytes ($01FE/$01FF) for the bootstrap restore.
        stack_top = v.mem(0x01FE, 2)
        regs["stack_1fe"] = stack_top[0]
        regs["stack_1ff"] = stack_top[1]
        print(f"  stack[$01FE,$01FF] = ${stack_top[0]:02x} ${stack_top[1]:02x}")

        # NOTE: VICE 3.10's monitor does NOT have save_snapshot/load_snapshot
        # commands (verified by `help` — only file-based load/save/bload/bsave
        # are available). The diff test instead uses `bload` to push the
        # bank*.bin files into VICE one bank at a time (~0.2s/bank with
        # bank switching, vs ~50s/bank for 64-byte poke chunks).

        # Save regs.
        regs_path = args.out / "regs.json"
        regs_path.write_text(json.dumps({
            **regs,
            "_warp_secs_requested": args.warp_secs,
            "_wall_secs": wall,
        }, indent=2))
        print(f"Wrote {regs_path}")

        # Iterate banks. Bank $00 is always saved; others probed first.
        scan_lo = max(args.bank_min, 0x00)
        scan_hi = min(args.bank_max, 0xFF)
        print(f"Scanning banks ${scan_lo:02x}..${scan_hi:02x}...")

        for bank in range(scan_lo, scan_hi + 1):
            if bank == 0x00:
                interesting = True
            elif args.no_probe:
                interesting = True
            else:
                t0 = time.time()
                interesting = _probe_nonempty(v, bank)
                t = time.time() - t0
                if not interesting:
                    print(f"  bank ${bank:02x}: empty (probe {t:.1f}s) - skip")
                    continue

            t0 = time.time()
            buf = _dump_bank(v, bank)
            t = time.time() - t0

            # Last-chance double check: if probe missed and bank IS empty,
            # don't write a 64KB file of zeros.
            if bank != 0x00 and _is_empty(buf):
                print(f"  bank ${bank:02x}: full dump empty (took {t:.1f}s) "
                      "- skip")
                continue

            out_path = args.out / f"bank{bank:02x}.bin"
            out_path.write_bytes(buf)
            nonzero = sum(1 for b in buf if b != 0)
            populated_banks.append(bank)
            print(f"  bank ${bank:02x}: dumped in {t:.1f}s "
                  f"({nonzero} non-zero bytes) -> {out_path.name}")

    finally:
        v.shutdown()

    manifest = {
        "regs": regs,
        "populated_banks": [f"{b:02x}" for b in populated_banks],
        "n_banks": len(populated_banks),
        "warp_secs_requested": args.warp_secs,
        "loader_prg": str(LOADER_PRG.relative_to(REPO)),
        "doom_reu": str(DOOM_REU.relative_to(REPO)),
    }
    manifest_path = args.out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"Wrote {manifest_path}")
    print(f"Captured {len(populated_banks)} populated banks "
          f"(bank $00 + {len(populated_banks) - 1 if 0 in populated_banks else len(populated_banks)} SuperRAM)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
