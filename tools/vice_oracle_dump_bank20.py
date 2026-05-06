"""One-shot VICE bank $20 trace dumper.

Runs VICE through the same Doom bank $20 entry as the cocotb diff test,
captures a long stepwise PC+regs trace, and saves it to a JSON file. The
cocotb test can then load this saved trace instead of re-running VICE
on every test invocation — useful when iterating on DUT changes.

Usage:
    python3 tools/vice_oracle_dump_bank20.py --max-instr 20000 \
        --out tools/vice_oracle/bank20_trace.json

The output format is a list of {seq, pbr, pc, p, sp} dicts. Bank-aware
because we use stepwise capture (regs() per step), not the bulk parser.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
TOOLS = REPO / "tools"
VICE_DIFF = TOOLS / "vice_diff"
for p in (str(TOOLS), str(VICE_DIFF)):
    if p not in sys.path:
        sys.path.insert(0, p)

from vice_oracle import ViceOracle, VICE_EXE_DEFAULT  # type: ignore  # noqa: E402

DOOM_REU = REPO / "doom.reu"
BOOT_ADDR = 0x0800
BANK20_ENTRY = 0x20_0000

BOOTSTRAP = bytes([
    0x78, 0x18, 0xFB,           # SEI; CLC; XCE
    0x5C, 0x00, 0x00, 0x20,     # JML $20:$0000
])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-instr", type=int, default=10000,
                    help="upper bound on stepwise captures (~0.21s each)")
    ap.add_argument("--bank20-len", type=lambda s: int(s, 0), default=0x4000,
                    help="bytes of bank $20 to plant (0x4000 = 16KB default)")
    ap.add_argument("--stop-pc", type=lambda s: int(s, 0), default=0x4000,
                    help="stop at this PC inside bank $20 (default $4000)")
    ap.add_argument("--stop-pbr", type=lambda s: int(s, 0), default=0x20,
                    help="stop only when PBR matches (default $20)")
    ap.add_argument("--out", type=pathlib.Path, required=True,
                    help="output JSON path for the trace")
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    args = ap.parse_args()

    if not DOOM_REU.exists():
        print(f"ERROR: doom.reu not found at {DOOM_REU}", file=sys.stderr)
        return 2

    with DOOM_REU.open("rb") as f:
        f.seek(0x20 * 0x10000)
        bank20 = f.read(args.bank20_len)
    print(f"Loaded {len(bank20)} bytes of doom.reu bank $20")

    args.out.parent.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    with ViceOracle(vice_exe=args.vice) as v:
        v._cmd("reset 0", timeout=10.0)
        v.load_bytes_direct(BOOT_ADDR, BOOTSTRAP)
        v.load_bytes_direct(BANK20_ENTRY, bank20)
        load_t = time.time() - t0
        print(f"VICE loaded in {load_t:.1f}s; starting trace capture (max_instr={args.max_instr})")

        cap_t0 = time.time()
        trace = v.capture_trace_stepwise(
            start_pc=BOOT_ADDR,
            stop_pc=args.stop_pc,
            stop_pbr=args.stop_pbr,
            max_instr=args.max_instr,
        )
        cap_t = time.time() - cap_t0

    # Serialize trace.
    payload = {
        "metadata": {
            "tool": "vice_oracle_dump_bank20.py",
            "max_instr": args.max_instr,
            "bank20_len": args.bank20_len,
            "stop_pc": args.stop_pc,
            "stop_pbr": args.stop_pbr,
            "captured_count": len(trace),
            "capture_seconds": round(cap_t, 1),
            "captured_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
        "trace": [
            {"seq": tl.seq, "pbr": tl.pbr, "pc": tl.pc, "p": tl.p, "sp": tl.sp}
            for tl in trace
        ],
    }
    with args.out.open("w") as f:
        json.dump(payload, f)
    print(f"Captured {len(trace)} fetches in {cap_t:.1f}s "
          f"({cap_t / max(1, len(trace)):.3f}s/step)")
    print(f"Last entry: pbr=${trace[-1].pbr:02x} pc=${trace[-1].pc:04x}")
    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
