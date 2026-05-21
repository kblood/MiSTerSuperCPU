#!/usr/bin/env python3
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
REAL_MOS6526 = REPO_ROOT / "C64_MiSTer" / "rtl" / "mos6526.v"


def strip_block_comments(src: str) -> str:
    return re.sub(r"/\*.*?\*/", "", src, flags=re.S)


def fix_t65_duplicate_alu_q(src: str) -> str:
    old_decl = "  wire [7:0] alu_q;"
    first = src.find(old_decl)
    second = src.find(old_decl, first + 1) if first != -1 else -1
    if first != -1 and second != -1:
        src = src[:second] + src[second:].replace(old_decl, "  wire [7:0] alu_q_int;", 1)
        src = src.replace("  assign alu_q = alu_q; // (signal)",
                          "  assign alu_q = alu_q_int; // (signal)", 1)
        src = src.replace("    .q(alu_q));", "    .q(alu_q_int));", 1)
    return src


def replace_synthesized_mos6526(src: str) -> str:
    real = REAL_MOS6526.read_text()
    pattern = re.compile(r"(?ms)^module mos6526\b.*?^endmodule\s*")
    match = pattern.search(src)
    if not match:
        raise RuntimeError("generated Verilog does not contain synthesized module mos6526")
    replacement = real.rstrip() + "\n\n"
    return src[:match.start()] + replacement + src[match.end():]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: postprocess_generated_verilog.py <generated.v>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    src = path.read_text()
    src = strip_block_comments(src)
    src = fix_t65_duplicate_alu_q(src)
    src = replace_synthesized_mos6526(src)
    path.write_text(src)
    print(f"Post-processed generated Verilog: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
