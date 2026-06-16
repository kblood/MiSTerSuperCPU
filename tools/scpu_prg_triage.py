#!/usr/bin/env python3
"""Static SuperCPU-feature triage of PRGs inside .d64 images.

Heuristic, off-device pre-pass for the compat sweep: extracts each PRG and
scans for (a) accesses to SuperCPU control registers (the known MiSTer stubs)
and (b) 65C816 long-addressing / SuperRAM opcodes. The result tells us, BEFORE
running on hardware, which stub each demo is likely to exercise -- so a failure
on the rig maps straight to a register decode instead of a blind probe-walk.

Heuristic: scans operand bytes (little-endian abs / 24-bit long) for the
register addresses; does not track M/X widths, so counts are upper bounds.
Ground truth still comes from the HW sweep -- this just pre-builds the queue.

Usage: python tools/scpu_prg_triage.py <image.d64> [...]
"""
import sys

_SPT = [21]*17 + [19]*7 + [18]*6 + [17]*5

def _soff(track, sector):
    return sum(_SPT[:track-1]) * 256 + sector * 256

def _petscii(b):
    out = []
    for ch in b:
        if ch in (0x00, 0xA0):
            continue
        if 0x41 <= ch <= 0x5A or 0x20 <= ch <= 0x3F:
            out.append(chr(ch))
        elif 0xC1 <= ch <= 0xDA:
            out.append(chr(ch - 0x80))
        else:
            out.append('.')
    return ''.join(out).rstrip()

def _extract(img, t, s):
    data = bytearray()
    seen = set()
    while t != 0 and (t, s) not in seen:
        seen.add((t, s))
        off = _soff(t, s)
        nt, ns = img[off], img[off+1]
        if nt == 0:
            data += img[off+2:off+2+(ns - 1 if ns else 0)]
        else:
            data += img[off+2:off+256]
        t, s = nt, ns
    return bytes(data)

def _files(img):
    out = []
    t, s = 18, 1
    seen = set()
    while t != 0 and (t, s) not in seen:
        seen.add((t, s))
        base = _soff(t, s)
        nt, ns = img[base], img[base+1]
        for e in range(8):
            eb = base + e*32
            ftype = img[eb+2]
            if (ftype & 0x07) != 2 or ftype == 0:
                continue
            name = _petscii(img[eb+5:eb+5+16])
            if not name:
                continue
            st, ss = img[eb+3], img[eb+4]
            out.append((name, st, ss))
        t, s = nt, ns
    return out

# SuperCPU control registers of interest (MiSTer stub status from CLAUDE.md)
REGS = {
    0xD071: "DMA src lo (DMAGIC)",   0xD072: "DMA src mid",  0xD073: "DMA src hi",
    0xD074: "WriteSmart/opt (STUB)", 0xD075: "WriteSmart/opt (STUB)",
    0xD076: "WriteSmart/opt (STUB)", 0xD077: "WriteSmart/opt (STUB)",
    0xD078: "cache flush (repurposed; real=SIMM cfg)",
    0xD07A: "speed: force 1MHz (slow)",  0xD07B: "speed: force 20MHz (turbo)",
    0xD07E: "hw enable",             0xD07F: "hw enable",
    0xD0B0: "version/ID",            0xD0B1: "version/ID",
    0xD0B2: "WriteSmart (STUB?)",    0xD0B3: "WriteSmart (STUB)",
    0xD0BE: "DOS ext (STUB)",        0xD0BF: "DOS ext (STUB)",
}
# 65C816 long-addressing opcodes -> SuperRAM (bank >= $02) usage signal
LONG_OPS = {0x0F:"ORA long",0x2F:"AND long",0x4F:"EOR long",0x6F:"ADC long",
            0x8F:"STA long",0xAF:"LDA long",0xCF:"CMP long",0xEF:"SBC long",
            0x1F:"ORA long,X",0x3F:"AND long,X",0x5F:"EOR long,X",0x7F:"ADC long,X",
            0x9F:"STA long,X",0xBF:"LDA long,X",0xDF:"CMP long,X",0xFF:"SBC long,X",
            0x22:"JSL long",0x5C:"JML long",
            0x07:"ORA [dp]",0x27:"AND [dp]",0x47:"EOR [dp]",0x67:"ADC [dp]",
            0x87:"STA [dp]",0xA7:"LDA [dp]",0xC7:"CMP [dp]",0xE7:"SBC [dp]"}

def scan(code, load):
    reg_hits = {}
    long_banks = {}
    long_count = 0
    n = len(code)
    # pass 1: little-endian abs operand scan for register addresses
    for i in range(n - 1):
        a = code[i] | (code[i+1] << 8)
        if a in REGS:
            reg_hits.setdefault(a, 0)
            reg_hits[a] += 1
    # pass 2: long-opcode bank histogram (operand bank byte is 3rd byte)
    i = 0
    while i < n - 3:
        op = code[i]
        if op in LONG_OPS and op not in (0x07,0x27,0x47,0x67,0x87,0xA7,0xC7,0xE7):
            bank = code[i+3]
            if bank >= 0x02:
                long_banks[bank] = long_banks.get(bank, 0) + 1
                long_count += 1
        i += 1
    return reg_hits, long_banks, long_count

def main(argv):
    if len(argv) < 2:
        print(__doc__); return 1
    for path in argv[1:]:
        with open(path, 'rb') as f:
            img = f.read()
        print(f"\n########## {path} ##########")
        for name, st, ss in _files(img):
            raw = _extract(img, st, ss)
            if len(raw) < 3:
                print(f"  [{name}]  (empty)")
                continue
            load = raw[0] | (raw[1] << 8)
            code = raw[2:]
            reg_hits, long_banks, long_count = scan(code, load)
            print(f"  [{name}]  load=${load:04X}  len={len(code)}")
            if reg_hits:
                for a in sorted(reg_hits):
                    print(f"      ${a:04X} x{reg_hits[a]:<4d} {REGS[a]}")
            else:
                print("      (no SuperCPU control-register operand bytes found)")
            if long_count:
                hi = max(long_banks) if long_banks else 0
                print(f"      long/SuperRAM ops (heuristic): {long_count}, "
                      f"distinct banks={len(long_banks)}, max bank=${hi:02X}")
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
