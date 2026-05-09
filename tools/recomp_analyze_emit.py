"""Analyse recomp.exe emit patterns vs Doom's wait loop.

Reuses the AmiDog SuperCPU MIPS recompiler (`tools/recomp_research/recomp.exe`)
on the supplied `hello/hello.bin` (extracted from `recomp.d81`). Compares
the resulting `.scpu` 65816 byte output against patterns observed in
Doom's wedged main thread at `$41:$DB93` (SuperRAM, post-loader).

Usage:
    python tools/recomp_analyze_emit.py

Findings (run 2026-05-09 vanilla-cpu-swap session):

* hello.bin.scpu = 6424 bytes, 91 JML opcodes (avg 1 cross-bank jump
  per 70 bytes).
* Zero occurrences of `df 07 07 00` (CMP $000707,X) or `b0 03 d0 fe`
  (BCS+3 / BNE-2) wait patterns in the hello recompilation.
* Doom has 9 occurrences of `df 07 07 00` and at least one location
  using the `BCS BNE *` wait-loop pattern at `$41:$DB93`.
* The recompiler does not emit busy-wait loops by default — Doom's
  pattern is Doom-specific game logic (likely a `while (flag != ?)`
  inline C in the original MIPS source) which the recompiler then
  translates literally into `LDA / CMP / BCS skip / BNE *`.

Conclusion: the wedged wait loop is waiting for a Doom-internal flag
(at `$00:$0707+X`) that should be flipped by a separate code path
(probably a Doom IRQ handler installed via `$FCEE`, or a separate
init pass). Identifying the producer requires either:
- a CPU-read-address probe in RTL (preferred — see
  `docs/session_handoff.md` proposal A), OR
- VICE oracle for Doom (currently BLOCKED — xscpu64 hangs DL).
"""
import os
import subprocess
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
RECOMP_DIR = os.path.join(THIS_DIR, 'recomp_research')
RECOMP_EXE = os.path.join(RECOMP_DIR, 'recomp.exe')
HELLO_BIN = os.path.join(RECOMP_DIR, 'hello', 'hello.bin')
HELLO_SCPU = HELLO_BIN + '.scpu'
DOOM_REU = os.path.join(THIS_DIR, '..', 'doom.reu')


def extract_hello_bin():
    """Extract HELLO.BIN raw contents from recomp.d81 if not present."""
    if os.path.exists(HELLO_BIN):
        return
    d81 = os.path.join(RECOMP_DIR, 'recomp.d81')

    def block_addr(track, sector):
        return ((track - 1) * 40 + sector) * 256

    with open(d81, 'rb') as f:
        f.seek(block_addr(40, 3))
        dirblk = f.read(256)
        tr = se = None
        for slot in range(8):
            base = slot * 32
            if dirblk[base + 2] == 0:
                continue
            name = dirblk[base + 5:base + 5 + 16].rstrip(b'\xa0')
            if name == b'HELLO.BIN':
                tr, se = dirblk[base + 3], dirblk[base + 4]
                break
        assert tr is not None
        data = bytearray()
        visited = set()
        while True:
            if (tr, se) in visited:
                break
            visited.add((tr, se))
            f.seek(block_addr(tr, se))
            block = f.read(256)
            nxt_tr, nxt_se = block[0], block[1]
            if nxt_tr == 0:
                data.extend(block[2:2 + nxt_se - 1])
                break
            data.extend(block[2:])
            tr, se = nxt_tr, nxt_se
    with open(HELLO_BIN, 'wb') as wf:
        wf.write(bytes(data))


def run_recomp():
    if os.path.exists(HELLO_SCPU):
        return
    subprocess.run([RECOMP_EXE, '-opt', '-stat', HELLO_BIN],
                   cwd=RECOMP_DIR, check=True,
                   stdout=subprocess.DEVNULL)


def count_pattern(buf: bytes, pat: bytes) -> int:
    n = 0
    pos = 0
    while True:
        i = buf.find(pat, pos)
        if i < 0:
            break
        n += 1
        pos = i + 1
    return n


def main():
    extract_hello_bin()
    run_recomp()
    with open(HELLO_SCPU, 'rb') as f:
        scpu = f.read()
    print(f'hello.bin.scpu: {len(scpu)} bytes')
    print(f'  JML opcodes (5C):     {scpu.count(bytes([0x5c]))}')
    print(f'  JSL opcodes (22):     {scpu.count(bytes([0x22]))}')
    print(f'  RTL opcodes (6B):     {scpu.count(bytes([0x6b]))}')
    print(f'  STA $0002 (85 02):    {count_pattern(scpu, bytes([0x85, 0x02]))}')
    print(f'  CMP $000707,X:        {count_pattern(scpu, bytes([0xdf, 0x07, 0x07, 0x00]))}')
    print(f'  BCS+3 BNE-2 wait:     {count_pattern(scpu, bytes([0xb0, 0x03, 0xd0, 0xfe]))}')
    print()

    if os.path.exists(DOOM_REU):
        with open(DOOM_REU, 'rb') as f:
            reu = f.read()
        print(f'doom.reu: {len(reu):,} bytes')
        print(f'  CMP $000707,X:        {count_pattern(reu, bytes([0xdf, 0x07, 0x07, 0x00]))}')
        print(f'  STA $000707:          {count_pattern(reu, bytes([0x8f, 0x07, 0x07, 0x00]))}')
        print(f'  STA $000707,X:        {count_pattern(reu, bytes([0x9f, 0x07, 0x07, 0x00]))}')
        print(f'  STZ $0707:            {count_pattern(reu, bytes([0x9c, 0x07, 0x07]))}')
        print(f'  BCS+3 BNE-2 wait:     {count_pattern(reu, bytes([0xb0, 0x03, 0xd0, 0xfe]))}')
    else:
        print(f'(doom.reu not found at {DOOM_REU} — skipping comparison)')


if __name__ == '__main__':
    main()
