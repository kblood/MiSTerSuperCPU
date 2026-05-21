#!/usr/bin/env python3
"""Categorize SST sweep failures by kind. Reads sweep_results/*.log."""
import os, re, sys, collections, argparse

LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sweep_results')

PATTERNS = [
    ('RAM',         re.compile(r'EFAIL case (\d+): RAM\[([0-9A-F]{6})\] exp=([0-9A-F]{2}) got=([0-9A-F]{2})')),
    ('P',           re.compile(r'EFAIL case (\d+): P exp=([0-9A-F]{2}) got=([0-9A-F]{2})')),
    ('PC',          re.compile(r'EFAIL case (\d+): PC exp=([0-9A-F]{4}) got=([0-9A-F]{4})')),
    ('S',           re.compile(r'EFAIL case (\d+): S exp=([0-9A-F]{4}) got=([0-9A-F]{4})')),
    ('A',           re.compile(r'EFAIL case (\d+): A exp=([0-9A-F]{4}) got=([0-9A-F]{4})')),
    ('X',           re.compile(r'EFAIL case (\d+): X exp=([0-9A-F]{4}) got=([0-9A-F]{4})')),
    ('Y',           re.compile(r'EFAIL case (\d+): Y exp=([0-9A-F]{4}) got=([0-9A-F]{4})')),
    ('D',           re.compile(r'EFAIL case (\d+): D exp=([0-9A-F]{4}) got=([0-9A-F]{4})')),
    ('DBR',         re.compile(r'EFAIL case (\d+): DBR exp=([0-9A-F]{2}) got=([0-9A-F]{2})')),
    ('PBR',         re.compile(r'EFAIL case (\d+): PBR exp=([0-9A-F]{2}) got=([0-9A-F]{2})')),
    ('EF',          re.compile(r'EFAIL case (\d+): EF exp=(\d) got=(\d)')),
    ('CY_addr',     re.compile(r'EFAIL case (\d+): CY\[(\d+)\] addr exp=([0-9A-F]{6}) got=([0-9A-F]{6})')),
    ('CY_data',     re.compile(r'EFAIL case (\d+): CY\[(\d+)\] data exp=([0-9A-F]{2}|XX) got=([0-9A-F]{2}|XX)')),
    ('CY_valid',    re.compile(r'EFAIL case (\d+): CY\[(\d+)\] valid exp=(\d) got=(\d)')),
    ('CY_MLB',      re.compile(r'EFAIL case (\d+): CY\[(\d+)\] MLB exp=(\d) got=(\d)')),
    ('CY_RWB',      re.compile(r'EFAIL case (\d+): CY\[(\d+)\] RWB exp=(\d) got=(\d)')),
    ('CY_VDA',      re.compile(r'EFAIL case (\d+): CY\[(\d+)\] VDA exp=(\d) got=(\d)')),
    ('CY_VPA',      re.compile(r'EFAIL case (\d+): CY\[(\d+)\] VPA exp=(\d) got=(\d)')),
    ('CY_VPB',      re.compile(r'EFAIL case (\d+): CY\[(\d+)\] VPB exp=(\d) got=(\d)')),
    ('ARM_TIMEOUT', re.compile(r'EFAIL case (\d+): ARM timeout')),
]

RESULT = re.compile(r'^E?SST_RESULT pass=(\d+) fail=(\d+) skip=(\d+) total=(\d+)')


def categorize(log_path):
    cats = collections.Counter()
    cycle_idx = collections.Counter()
    first_fail_idx = {}
    pass_n = fail_n = skip_n = total_n = 0
    with open(log_path) as f:
        for line in f:
            m = RESULT.search(line)
            if m:
                pass_n, fail_n, skip_n, total_n = map(int, m.groups())
            for kind, pat in PATTERNS:
                m = pat.search(line)
                if m:
                    cats[kind] += 1
                    if kind not in first_fail_idx:
                        first_fail_idx[kind] = m.group(1)
                    if kind.startswith('CY_'):
                        cycle_idx[(kind, int(m.group(2)))] += 1
                    break
    return pass_n, fail_n, skip_n, total_n, cats, cycle_idx, first_fail_idx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--min-fail', type=int, default=1, help='only show opcodes with >=N fails')
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(LOG_DIR) if re.match(r'^[0-9a-f]{2}\.[en]\.log$', f))
    print(f"{'op':<8} {'pass':>5} {'fail':>5} {'skip':>4} | top fail kinds")
    print("-" * 80)
    grand_kinds = collections.Counter()
    for f in files:
        path = os.path.join(LOG_DIR, f)
        p, fa, sk, tot, cats, cyc, first = categorize(path)
        if fa < args.min_fail:
            continue
        grand_kinds.update(cats)
        kind_str = ", ".join(f"{k}={v}" for k, v in cats.most_common(4))
        name = f.replace('.log', '')
        print(f"{name:<8} {p:>5} {fa:>5} {sk:>4} | {kind_str}")
        for (kind, idx), count in sorted(cyc.items(), key=lambda x: -x[1])[:3]:
            print(f"           {kind} cycle={idx} count={count}")

    print()
    print("=== Grand totals across all opcodes ===")
    for k, v in grand_kinds.most_common():
        print(f"  {k:12} {v}")


if __name__ == '__main__':
    main()
