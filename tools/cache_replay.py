#!/usr/bin/env python3
"""cache_replay.py — replay a CPU memory-access trace through a configurable
direct-mapped / N-way read cache model and report hit-rate.

Purpose (more-turbo iter-4+): the SLOT3/page-mode levers died because synthetic
access patterns over-promised. This replays a REAL access trace (dumped by
sim/c64_reduced_harness/c64_cache_hitrate_tb.vhd, or — later — a HW {bank,addr,we}
UART capture) through a Python model that EXACTLY mirrors C64_MiSTer/rtl/cpu_cache.vhd
(read-only: write hits disabled; writes invalidate the matching byte). It:
  (1) cross-validates the GHDL/RTL hit-rate (catches observer bugs),
  (2) sweeps cache geometry the fixed 4KB RTL can't, to pick the cheapest
      size that still hits high before committing to a build.

Trace format: lines "<we> <bank_hex2> <addr_hex4>", '#'-comments ignored.
  we   : '0' read, '1' write
  bank : 65C816 bank byte (A23-A16), hex
  addr : 16-bit address within bank, hex

cpu_cache.vhd geometry being mirrored (the shipped 4KB default):
  512 lines x 8 bytes; tag = bank(8) & addr[15:12] (12 bits);
  line_index = addr[11:3]; byte_offset = addr[2:0]; per-byte valid.
  cacheable = (bank==0x00 and addr[15:12]!=0xD) or (0x00 < bank < 0xF0).
  Read: hit = tag_match AND byte_valid. Then opportunistic fill (evict line on
        tag-mismatch: clear all 8 valid, set this byte; same tag: set this byte).
  Write: cacheable_wr is hard '0' (write hits disabled); a write to a matching
         tag invalidates that byte (writes go to SDRAM via the normal path).

Usage:
  python tools/cache_replay.py <trace.txt>           # default 4KB DM + sweep
  python tools/cache_replay.py <trace.txt> --sweep    # geometry sweep table
"""
import sys
import argparse


class Cache:
    """Direct-mapped or N-way set-associative, per-byte valid, read-only fill.

    line_bytes = 2**offbits ; sets = 2**setbits ; ways = associativity.
    Tag = (bank << 4) | addr[15:12]  is the RTL's exact 12-bit tag ONLY for the
    4KB/8-byte/512-line case; for other geometries we use a general tag =
    full_addr >> (offbits+setbits) where full_addr = (bank<<16)|addr, which is
    the natural generalization. For the 4KB case the two coincide.
    """

    def __init__(self, offbits=3, setbits=9, ways=1):
        self.offbits = offbits
        self.setbits = setbits
        self.ways = ways
        self.line_bytes = 1 << offbits
        self.nsets = 1 << setbits
        # per way: tag array + valid bitmap (one bool per byte in the line)
        self.tags = [[None] * self.nsets for _ in range(ways)]
        self.valid = [[[False] * self.line_bytes for _ in range(self.nsets)]
                      for _ in range(ways)]
        # LRU order per set (list of way indices, MRU last); only used if ways>1
        self.lru = [list(range(ways)) for _ in range(self.nsets)]

    def _decode(self, bank, addr):
        full = (bank << 16) | addr
        off = full & (self.line_bytes - 1)
        idx = (full >> self.offbits) & (self.nsets - 1)
        tag = full >> (self.offbits + self.setbits)
        return tag, idx, off

    def _find_way(self, idx, tag):
        for w in range(self.ways):
            if self.tags[w][idx] == tag:
                return w
        return None

    def read(self, bank, addr):
        """Return True on hit; apply opportunistic fill. Mirrors RTL read path."""
        tag, idx, off = self._decode(bank, addr)
        w = self._find_way(idx, tag)
        hit = (w is not None) and self.valid[w][idx][off]
        # opportunistic fill (RTL fills every cacheable read)
        if w is None:
            # allocate a way: free/invalid first, else LRU victim
            w = self.lru[idx][0]
            self.tags[w][idx] = tag
            self.valid[w][idx] = [False] * self.line_bytes
        self.valid[w][idx][off] = True
        if self.ways > 1:
            self.lru[idx].remove(w)
            self.lru[idx].append(w)
        return hit

    def write_invalidate(self, bank, addr):
        """Write hits disabled (cacheable_wr='0'); invalidate matching byte."""
        tag, idx, off = self._decode(bank, addr)
        w = self._find_way(idx, tag)
        if w is not None:
            self.valid[w][idx][off] = False


def cacheable(bank, addr):
    hi = (addr >> 12) & 0xF
    return (bank == 0x00 and hi != 0xD) or (0x00 < bank < 0xF0)


def load_trace(path):
    accs = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            parts = ln.split()
            if len(parts) != 3:
                continue
            we = parts[0] == '1'
            bank = int(parts[1], 16)
            addr = int(parts[2], 16)
            accs.append((we, bank, addr))
    return accs


def run(accs, offbits, setbits, ways, count_zp=False):
    c = Cache(offbits, setbits, ways)
    reads = hits = 0
    zp_reads = zp_hits = 0
    for we, bank, addr in accs:
        if not cacheable(bank, addr):
            continue
        if we:
            c.write_invalidate(bank, addr)
        else:
            h = c.read(bank, addr)
            reads += 1
            if h:
                hits += 1
            if count_zp and bank == 0x00 and addr < 0x0200:
                zp_reads += 1
                if h:
                    zp_hits += 1
    return reads, hits, zp_reads, zp_hits


def pct(h, n):
    return (100.0 * h / n) if n else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace')
    ap.add_argument('--sweep', action='store_true', help='geometry sweep table')
    args = ap.parse_args()

    accs = load_trace(args.trace)
    n_steps = len(accs)
    n_cacheable_reads = sum(1 for we, b, a in accs if not we and cacheable(b, a))
    print(f"trace: {args.trace}  steps={n_steps}  cacheable_reads={n_cacheable_reads}")

    # Reference geometry = shipped cpu_cache.vhd (4KB, 8-byte lines, 512 sets, DM)
    reads, hits, zp_r, zp_h = run(accs, offbits=3, setbits=9, ways=1, count_zp=True)
    print("\n== Reference (matches cpu_cache.vhd: 4KB, 8B lines, 512 sets, direct-mapped) ==")
    print(f"  cacheable_reads={reads}  hits={hits}  HIT={pct(hits, reads):.2f}%")
    print(f"  zp/stack reads={zp_r}  hits={zp_h}  HIT={pct(zp_h, zp_r):.2f}%")
    print("  (cross-check vs GHDL/RTL c64_cache_hitrate_tb: expect ~94.12% overall, 98.63% zp)")

    if args.sweep:
        # (label, total_KB, offbits, setbits, ways)
        geoms = [
            ("1KB  DM  8B", 3, 7, 1),
            ("2KB  DM  8B", 3, 8, 1),
            ("4KB  DM  8B (shipped)", 3, 9, 1),
            ("8KB  DM  8B", 3, 10, 1),
            ("16KB DM  8B", 3, 11, 1),
            ("4KB  2way 8B", 3, 8, 2),
            ("4KB  4way 8B", 3, 7, 4),
            ("4KB  DM  16B", 4, 8, 1),
            ("4KB  DM  4B", 2, 10, 1),
            ("8KB  2way 8B", 3, 9, 2),
        ]
        print("\n== Geometry sweep (overall cacheable-read hit-rate) ==")
        print(f"  {'geometry':<24} {'KB':>4}  {'hit%':>7}")
        for label, off, sett, ways in geoms:
            kb = (1 << (off + sett)) * ways // 1024
            r, h, _, _ = run(accs, off, sett, ways)
            print(f"  {label:<24} {kb:>4}  {pct(h, r):>6.2f}%")


if __name__ == '__main__':
    main()
