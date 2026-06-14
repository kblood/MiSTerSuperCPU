#!/usr/bin/env python3
"""List the directory of a .d64 (1541) disk image.

Standalone, no external deps. Used by the SCPU compatibility sweep to
enumerate runnable programs on a disk before driving the MiSTer through them.

Usage: python tools/d64_dir.py <image.d64> [<image2.d64> ...]
Prints, per file: blocks, type, and the PETSCII name decoded to ASCII.
"""
import sys

# sectors-per-track for a 35-track .d64
_SPT = [21]*17 + [19]*7 + [18]*6 + [17]*5  # tracks 1..35

def _track_offset(track):
    return sum(_SPT[:track-1]) * 256

def _sector_offset(track, sector):
    return _track_offset(track) + sector * 256

_FTYPE = {0: 'DEL', 1: 'SEQ', 2: 'PRG', 3: 'USR', 4: 'REL'}

def _petscii(b):
    out = []
    for ch in b:
        if ch == 0xA0 or ch == 0x00:
            continue
        if 0x41 <= ch <= 0x5A:        # PETSCII uppercase
            out.append(chr(ch))
        elif 0xC1 <= ch <= 0xDA:      # PETSCII shifted letters
            out.append(chr(ch - 0x80))
        elif 0x20 <= ch <= 0x3F:      # space, digits, punctuation
            out.append(chr(ch))
        else:
            out.append('.')
    return ''.join(out).rstrip()

def list_dir(path):
    with open(path, 'rb') as f:
        img = f.read()
    # disk name lives in the BAM at track 18 sector 0, offset 0x90
    bam = _sector_offset(18, 0)
    diskname = _petscii(img[bam+0x90:bam+0x90+16])
    entries = []
    t, s = 18, 1                       # first directory sector
    seen = set()
    while t != 0 and (t, s) not in seen:
        seen.add((t, s))
        base = _sector_offset(t, s)
        nt, ns = img[base], img[base+1]
        for e in range(8):
            eb = base + e*32
            ftype = img[eb+2]
            if ftype == 0:             # scratched / empty
                continue
            name = _petscii(img[eb+5:eb+5+16])
            if not name:
                continue
            blocks = img[eb+30] | (img[eb+31] << 8)
            closed = '*' if not (ftype & 0x80) else ' '   # '*' = splat (unclosed)
            tname = _FTYPE.get(ftype & 0x07, '???')
            entries.append((blocks, tname, closed, name))
        t, s = nt, ns
    return diskname, entries

def main(argv):
    if len(argv) < 2:
        print(__doc__); return 1
    for path in argv[1:]:
        try:
            diskname, entries = list_dir(path)
        except Exception as ex:
            print(f'{path}: ERROR {ex}')
            continue
        print(f'\n=== {path}  ["{diskname}"]  {len(entries)} files ===')
        for blocks, tname, closed, name in entries:
            print(f'  {blocks:4d} {tname} {closed} {name}')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
