#!/usr/bin/env python3
"""fpga_analyze.py — Parse Quartus fit report and visualize FPGA resource usage.

Usage:
    python tools/fpga_analyze.py                    # summary + tree
    python tools/fpga_analyze.py --graph            # generate DOT graph
    python tools/fpga_analyze.py --compare A.rpt B.rpt  # compare two builds
    python tools/fpga_analyze.py --budget           # show headroom for changes
    python tools/fpga_analyze.py --signals MODULE   # list I/O signals for a module
"""

import re
import sys
import os
from collections import defaultdict
from pathlib import Path

# Fix Windows console encoding
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# Default fit report path
DEFAULT_RPT = os.path.join(os.path.dirname(__file__), "..",
                           "C64_MiSTer", "output_files", "C64.fit.rpt")


def parse_number(s):
    """Parse a Quartus report number like '30591.0 (793.7)' → (30591.0, 793.7)."""
    s = s.strip().replace(",", "")
    m = re.match(r'([\d.]+)\s*(?:\(([\d.]+)\))?', s)
    if m:
        total = float(m.group(1))
        self_only = float(m.group(2)) if m.group(2) else total
        return total, self_only
    return 0.0, 0.0


def parse_fit_report(rpt_path):
    """Parse Quartus fit report 'Fitter Resource Utilization by Entity' table."""
    modules = {}
    in_table = False
    header_found = False
    separator_count = 0

    with open(rpt_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            # Look for the Fitter Resource Utilization by Entity header
            if "Compilation Hierarchy Node" in line and "ALMs needed" in line:
                header_found = True
                continue

            if header_found and line.startswith("+--"):
                separator_count += 1
                if separator_count == 1:
                    in_table = True
                    continue
                else:
                    # End of table
                    break

            if not in_table:
                continue

            if not line.startswith(";"):
                continue

            # Split by ';' — keep empty fields to preserve column positions
            parts = [p.strip() for p in line.split(";")]
            # Remove leading/trailing empty strings from the ; delimiters
            if parts and parts[0] == '':
                parts = parts[1:]
            if parts and parts[-1] == '':
                parts = parts[:-1]

            # Expected columns (0-indexed):
            #  0: Compilation Hierarchy Node
            #  1: ALMs needed [=A-B+C]       e.g. "30591.0 (793.7)"
            #  2: [A] ALMs used in final placement
            #  3: [B] Estimate of ALMs recoverable
            #  4: [C] Estimate of ALMs unavailable
            #  5: ALMs used for memory
            #  6: Combinational ALUTs         e.g. "45607 (1349)"
            #  7: Dedicated Logic Registers   e.g. "37842 (1444)"
            #  8: I/O Registers
            #  9: Block Memory Bits
            # 10: M10Ks
            # 11: DSP Blocks
            # 12: Pins
            # 13: Virtual Pins
            # 14: Full Hierarchy Name
            # 15: Entity Name
            # 16: Library Name
            if len(parts) < 11:
                continue

            hierarchy_node = parts[0]
            # Determine depth from leading pipe+space indentation
            stripped = hierarchy_node.lstrip()
            depth = (len(hierarchy_node) - len(stripped)) // 3  # ~3 chars per level

            # Extract entity name (cleaner label)
            entity_name = parts[15].strip() if len(parts) > 15 else stripped.split("|")[-1].split(":")[0]

            # Parse key metrics
            alms_total, alms_self = parse_number(parts[1])
            regs_total, regs_self = parse_number(parts[7])

            try:
                m10k = int(parts[10].strip())
            except (ValueError, IndexError):
                m10k = 0

            try:
                dsp = int(parts[11].strip())
            except (ValueError, IndexError):
                dsp = 0

            try:
                mem_bits = int(parts[9].strip())
            except (ValueError, IndexError):
                mem_bits = 0

            aluts_total, aluts_self = parse_number(parts[6])

            modules[entity_name] = {
                "alms": alms_total,
                "alms_self": alms_self,
                "regs": regs_total,
                "regs_self": regs_self,
                "m10k": m10k,
                "dsp": dsp,
                "mem_bits": mem_bits,
                "aluts": aluts_total,
                "depth": depth,
                "hierarchy": hierarchy_node.strip(),
            }

    return modules


def parse_top_summary(rpt_path):
    """Parse the top-level resource summary."""
    summary = {}
    with open(rpt_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r";\s*Logic utilization \(in ALMs\)\s*;\s*([\d,]+)\s*/\s*([\d,]+)", line)
            if m:
                summary["alms_used"] = int(m.group(1).replace(",", ""))
                summary["alms_total"] = int(m.group(2).replace(",", ""))

            m = re.match(r";\s*Total RAM Blocks\s*;\s*(\d+)\s*/\s*(\d+)", line)
            if m:
                summary["m10k_used"] = int(m.group(1))
                summary["m10k_total"] = int(m.group(2))

            m = re.match(r";\s*Total registers\s*;\s*([\d,]+)", line)
            if m:
                summary["regs"] = int(m.group(1).replace(",", ""))

            m = re.match(r";\s*Total DSP Blocks\s*;\s*(\d+)\s*/\s*(\d+)", line)
            if m:
                summary["dsp_used"] = int(m.group(1))
                summary["dsp_total"] = int(m.group(2))

    return summary


def print_summary(rpt_path):
    """Print resource usage summary."""
    summary = parse_top_summary(rpt_path)
    modules = parse_fit_report(rpt_path)

    print("=" * 70)
    print(f"  FPGA Resource Summary: {os.path.basename(rpt_path)}")
    print("=" * 70)

    if summary:
        alms_used = summary.get("alms_used", 0)
        alms_total = summary.get("alms_total", 1)
        m10k_used = summary.get("m10k_used", 0)
        m10k_total = summary.get("m10k_total", 1)
        pct_alm = 100 * alms_used / alms_total
        pct_m10k = 100 * m10k_used / m10k_total

        print(f"  ALMs:       {alms_used:>6,} / {alms_total:,}  ({pct_alm:.1f}%)")
        bar_len = int(pct_alm / 2)
        print(f"              [{'█' * bar_len}{'░' * (50 - bar_len)}]")

        print(f"  M10K:       {m10k_used:>6} / {m10k_total}      ({pct_m10k:.1f}%)")
        bar_len = int(pct_m10k / 2)
        print(f"              [{'█' * bar_len}{'░' * (50 - bar_len)}]")

        if "regs" in summary:
            print(f"  Registers:  {summary['regs']:>6,}")
        if "dsp_used" in summary:
            pct_dsp = 100 * summary["dsp_used"] / summary["dsp_total"]
            print(f"  DSP:        {summary['dsp_used']:>6} / {summary['dsp_total']}      ({pct_dsp:.1f}%)")

    print()

    # Sort modules by ALMs descending, skip tiny ones
    sorted_mods = sorted(modules.items(), key=lambda x: x[1]["alms"], reverse=True)
    sorted_mods = [(n, d) for n, d in sorted_mods if d["alms"] >= 10]

    print("  Top modules by ALM usage:")
    print("  " + "-" * 72)
    print(f"  {'Module':<35} {'ALMs':>8} {'(self)':>8} {'Regs':>7} {'M10K':>5}")
    print("  " + "-" * 72)

    for name, data in sorted_mods[:30]:
        alms = data["alms"]
        bar = "█" * max(1, int(alms / 500))
        self_str = f"({data['alms_self']:.0f})" if data.get("alms_self", 0) != alms else ""
        print(f"  {name:<35} {alms:>8,.0f} {self_str:>8} {data['regs']:>7,.0f} {data['m10k']:>5} {bar}")

    print()
    headroom = summary.get("alms_total", 0) - summary.get("alms_used", 0)
    print(f"  ALM headroom: {headroom:,} ALMs ({100 * headroom / summary.get('alms_total', 1):.1f}%)")
    m10k_headroom = summary.get("m10k_total", 0) - summary.get("m10k_used", 0)
    print(f"  M10K headroom: {m10k_headroom} blocks ({m10k_headroom * 10240 / 1024:.0f} KB)")


def print_budget(rpt_path):
    """Show what-if budget analysis for architectural changes."""
    summary = parse_top_summary(rpt_path)
    modules = parse_fit_report(rpt_path)

    alms_used = summary.get("alms_used", 0)
    alms_total = summary.get("alms_total", 0)
    m10k_used = summary.get("m10k_used", 0)
    m10k_total = summary.get("m10k_total", 0)
    headroom_alm = alms_total - alms_used
    headroom_m10k = m10k_total - m10k_used

    print("=" * 70)
    print("  FPGA Budget Analysis")
    print("=" * 70)
    print(f"  Current: {alms_used:,} ALMs ({100*alms_used/alms_total:.1f}%), "
          f"{m10k_used} M10K ({100*m10k_used/m10k_total:.1f}%)")
    print(f"  Headroom: {headroom_alm:,} ALMs, {headroom_m10k} M10K blocks")
    print()

    # Use actual sizes from report where available, fall back to estimates
    def get_mod(name, default_alm=0, default_m10k=0):
        if name in modules:
            return (int(modules[name]["alms"]), modules[name]["m10k"])
        return (default_alm, default_m10k)

    known = {
        "T65 (6510 CPU)":       get_mod("cpu_6510", 508, 0),
        "P65C816 (65C816 CPU)": get_mod("cpu_65c816", 1363, 0),
        "CPU cache (8KB)":      get_mod("cpu_cache", 4710, 8),
        "Debug overlay":        get_mod("debug_overlay", 184, 0),
        "Debug UART":           (get_mod("debug_uart_fmt", 239, 0)[0] +
                                 get_mod("debug_uart_tx", 17, 0)[0], 0),
        "SuperCPU registers":   (200, 0),   # estimated (part of fpga64_sid_iec self)
    }

    scenarios = [
        {
            "name": "SuperCPU-only core (drop T65, drop cache, add 64KB BRAM)",
            "remove": ["T65 (6510 CPU)", "CPU cache (8KB)"],
            "add": [("64KB dual-port BRAM", 200, 64), ("BRAM controller", 150, 0)],
        },
        {
            "name": "Standard C64 core (drop P65C816, drop cache, drop debug)",
            "remove": ["P65C816 (65C816 CPU)", "CPU cache (8KB)",
                       "Debug overlay", "Debug UART", "SuperCPU registers"],
            "add": [],
        },
        {
            "name": "Current + 64KB BRAM (keep both CPUs, replace cache)",
            "remove": ["CPU cache (8KB)"],
            "add": [("64KB dual-port BRAM", 200, 64), ("BRAM controller", 150, 0)],
            # 64 M10K for 64KB: each M10K stores 1024×8 = 8192 usable bits
            # (confirmed: cache 8KB data_ram = 65536 bits / 8 M10K = 8192 bits/M10K)
        },
        {
            "name": "Current + suppress elimination (+5000 ALMs)",
            "remove": [],
            "add": [("Lookahead logic", 5100, 0)],
        },
    ]

    for scenario in scenarios:
        alm_delta = 0
        m10k_delta = 0

        for rem in scenario["remove"]:
            if rem in known:
                alm_delta -= known[rem][0]
                m10k_delta -= known[rem][1]

        for add_name, add_alm, add_m10k in scenario["add"]:
            alm_delta += add_alm
            m10k_delta += add_m10k

        new_alms = alms_used + alm_delta
        new_m10k = m10k_used + m10k_delta
        pct_alm = 100 * new_alms / alms_total
        pct_m10k = 100 * new_m10k / m10k_total
        fits = pct_alm < 85 and pct_m10k < 95

        status = "✓ FITS" if fits else "✗ WON'T FIT"
        print(f"  Scenario: {scenario['name']}")
        print(f"    ALMs: {alms_used:,} → {new_alms:,} ({alm_delta:+,}) = {pct_alm:.1f}%")
        print(f"    M10K: {m10k_used} → {new_m10k} ({m10k_delta:+}) = {pct_m10k:.1f}%")
        print(f"    Status: {status}")
        print()


def generate_dot_graph(rpt_path, output_path=None):
    """Generate a DOT graph of module hierarchy and resource usage."""
    modules = parse_fit_report(rpt_path)
    summary = parse_top_summary(rpt_path)

    if output_path is None:
        output_path = rpt_path.replace(".fit.rpt", "_hierarchy.dot")

    lines = [
        'digraph fpga_hierarchy {',
        '  rankdir=TB;',
        '  node [shape=box, style=filled, fontname="Consolas"];',
        '  edge [color="#666666"];',
        '',
    ]

    # Color based on ALM usage
    def color_for_alms(alms):
        if alms > 3000:
            return "#ff6b6b"  # red - large
        elif alms > 1000:
            return "#ffa94d"  # orange - medium
        elif alms > 300:
            return "#ffe066"  # yellow - small
        else:
            return "#c3fae8"  # green - tiny

    for name, data in modules.items():
        if data["alms"] < 10:
            continue
        safe_name = re.sub(r'[^a-zA-Z0-9_]', '_', name)
        color = color_for_alms(data["alms"])
        label = f"{name}\\n{data['alms']:,.0f} ALMs"
        if data["m10k"] > 0:
            label += f"\\n{data['m10k']} M10K"
        lines.append(f'  {safe_name} [label="{label}", fillcolor="{color}"];')

    lines.append("}")

    with open(output_path, "w") as f:
        f.write("\n".join(lines))

    print(f"DOT graph written to: {output_path}")
    print(f"Render with: dot -Tpng {output_path} -o hierarchy.png")


def compare_reports(rpt_a, rpt_b):
    """Compare two fit reports side by side."""
    sum_a = parse_top_summary(rpt_a)
    sum_b = parse_top_summary(rpt_b)
    mod_a = parse_fit_report(rpt_a)
    mod_b = parse_fit_report(rpt_b)

    print("=" * 70)
    print(f"  Comparison: {os.path.basename(rpt_a)} vs {os.path.basename(rpt_b)}")
    print("=" * 70)

    for key in ["alms_used", "m10k_used", "regs"]:
        va = sum_a.get(key, 0)
        vb = sum_b.get(key, 0)
        delta = vb - va
        print(f"  {key:<15} {va:>8,} → {vb:>8,}  ({delta:+,})")

    print()
    print(f"  {'Module':<35} {'Build A':>8} {'Build B':>8} {'Delta':>8}")
    print("  " + "-" * 63)

    all_names = sorted(set(list(mod_a.keys()) + list(mod_b.keys())))
    for name in all_names:
        va = mod_a.get(name, {}).get("alms", 0)
        vb = mod_b.get(name, {}).get("alms", 0)
        delta = vb - va
        if abs(delta) >= 1:
            print(f"  {name:<35} {va:>8,.0f} {vb:>8,.0f} {delta:>+8,.0f}")


def parse_vhdl_signals(filepath):
    """Parse entity ports from a VHDL file."""
    signals = []
    in_entity = False
    entity_name = ""

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"\s*entity\s+(\w+)\s+is", line, re.IGNORECASE)
            if m:
                in_entity = True
                entity_name = m.group(1)
                continue

            if in_entity and re.match(r"\s*end\s+", line, re.IGNORECASE):
                in_entity = False
                continue

            if in_entity:
                m = re.match(r"\s*(\w+)\s*:\s*(in|out|inout)\s+(.+?)(?:;|$)", line, re.IGNORECASE)
                if m:
                    signals.append({
                        "entity": entity_name,
                        "name": m.group(1),
                        "direction": m.group(2).lower(),
                        "type": m.group(3).strip().rstrip(";"),
                    })

    return signals


def list_module_signals(module_name):
    """Find and list signals for a given module."""
    rtl_dir = os.path.join(os.path.dirname(__file__), "..", "C64_MiSTer", "rtl")

    for root, dirs, files in os.walk(rtl_dir):
        for fname in files:
            if fname.endswith(".vhd"):
                fpath = os.path.join(root, fname)
                signals = parse_vhdl_signals(fpath)
                for sig in signals:
                    if module_name.lower() in sig["entity"].lower():
                        print(f"  {sig['direction']:<6} {sig['name']:<25} {sig['type']}")


def main():
    args = sys.argv[1:]

    if "--help" in args or "-h" in args:
        print(__doc__)
        return

    if "--compare" in args:
        idx = args.index("--compare")
        if len(args) > idx + 2:
            compare_reports(args[idx + 1], args[idx + 2])
        else:
            print("Usage: --compare <report_a.rpt> <report_b.rpt>")
        return

    if "--graph" in args:
        rpt = args[args.index("--graph") + 1] if len(args) > args.index("--graph") + 1 else DEFAULT_RPT
        generate_dot_graph(rpt)
        return

    if "--signals" in args:
        idx = args.index("--signals")
        if len(args) > idx + 1:
            list_module_signals(args[idx + 1])
        else:
            print("Usage: --signals <module_name>")
        return

    rpt = args[0] if args and not args[0].startswith("-") else DEFAULT_RPT

    if "--budget" in args:
        print_budget(rpt)
    else:
        print_summary(rpt)
        print()
        print_budget(rpt)


if __name__ == "__main__":
    main()
