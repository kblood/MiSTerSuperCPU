#!/usr/bin/env python3
"""Decode v306 N5 field: 16-bit bitmap of $00:$070N writes.

In v306+ N5 is no longer a count — bit N set = $070N was written
at least once by the CPU since boot. Decodes which addresses
were touched, which were skipped.

Usage:  python3 tools/decode_v306_n5.py [path_to_uart.txt]
"""
import re, sys


def decode_n5(value):
    """value is 16-bit unsigned. Returns list of (addr, written?) tuples."""
    addrs = []
    for bit in range(16):
        addr = 0x0700 + bit
        written = bool((value >> bit) & 1)
        addrs.append((addr, written))
    return addrs


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if not path:
        print('usage: python3 decode_v306_n5.py path/to/uart.txt')
        return 1

    n5_values = set()
    last_line = None
    with open(path, 'r', errors='replace') as f:
        for line in f:
            m = re.search(r'N5:([0-9A-F]+)', line)
            if m:
                n5_values.add(int(m.group(1), 16))
                last_line = line.strip()

    if not n5_values:
        print(f'No N5: fields found in {path}')
        return 1

    print(f'Unique N5 values seen: {len(n5_values)}')
    print(f'Latest value:  ${max(n5_values):04X}')
    print(f'OR of all values (every addr ever written across captures):')
    union = 0
    for v in n5_values:
        union |= v
    print(f'  ${union:04X}\n')

    # Decode union
    print('Addr write bitmap (1=written, .=never):')
    print('  $0700 $0701 $0702 $0703 $0704 $0705 $0706 $0707')
    line = '   '
    for bit in range(8):
        line += '   ' + ('1' if (union >> bit) & 1 else '.') + '   '
    print(line)
    print('  $0708 $0709 $070A $070B $070C $070D $070E $070F')
    line = '   '
    for bit in range(8, 16):
        line += '   ' + ('1' if (union >> bit) & 1 else '.') + '   '
    print(line)

    print('\nUnwritten addresses (the suspects for stale BRK or whatever):')
    skipped = []
    for bit in range(16):
        if not ((union >> bit) & 1):
            skipped.append(0x0700 + bit)
    for a in skipped:
        print(f'  ${a:04X}')
    if not skipped:
        print('  (none — all $070X addresses were written)')

    if last_line:
        print(f'\nLatest UART line:\n  {last_line[:200]}')

    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
