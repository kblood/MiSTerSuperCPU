#!/usr/bin/env python3
"""SingleStepTests/65816 JSON → text record converter.

Output is a line-oriented text file the VHDL bench reads via std.textio.
Per-case format:

  C <case_idx>
  I <pc:4> <s:4> <p:2> <a:4> <x:4> <y:4> <d:4> <dbr:2> <pbr:2> <e:1>
  IR <n_init_ram>
    <addr24:6> <val:2>      (× n_init_ram lines)
  F <pc:4> <s:4> <p:2> <a:4> <x:4> <y:4> <d:4> <dbr:2> <pbr:2> <e:1>
  FR <n_final_ram>
    <addr24:6> <val:2>      (× n_final_ram lines)
  CY <n_cycles>
    <addr24:6> <data:2|XX> <valid:1> <flagstr:8>    (× n_cycles lines)
  E

All hex values are zero-padded ASCII. `data` field is XX when the JSON
records `null` (no bus transaction). `valid` is 1 if data is meaningful,
0 if cycle is internal (value=null).

Header at top of file:
  H <opcode:2> <mode:1> <n_cases:varies>

Usage:
  python tools/sst_convert.py 06 e [--max N]   ; converts external/65816/v1/06.e.json
  python tools/sst_convert.py --rmw            ; converts the 28 RMW opcodes both modes
"""
import argparse, json, os, sys

RMW_OPCODES = [
    0x06, 0x0E, 0x16, 0x1E,
    0x26, 0x2E, 0x36, 0x3E,
    0x46, 0x4E, 0x56, 0x5E,
    0x66, 0x6E, 0x76, 0x7E,
    0x04, 0x0C, 0x14, 0x1C,
    0xC6, 0xCE, 0xD6, 0xDE,
    0xE6, 0xEE, 0xF6, 0xFE,
]

JSON_DIR = os.path.join('external', '65816', 'v1')
BIN_DIR  = os.path.join('external', '65816', 'v1.bin')


def make_prelude(init):
    """Generate 65C816 bytecode that brings CPU from reset state to
    initial register state, ending with JML to (init.pbr:init.pc).

    Loaded at $00:FE00. Reset vector ($00:FFFC/FFFD) points here.

    After reset: E=1, M=1, X=1, P[I]=1, PBR=0. Native-mode sequence:
      1. CLC; XCE        — enter native
      2. REP #$30        — M=0, X=0 (16-bit A/X/Y)
      3. LDA #d16; TCD   — set D
      4. SEP #$20; LDA #dbr; PHA; PLB; REP #$20 — set DBR via stack
      5. LDX #s16; TXS   — set S (16-bit)
      6. LDA #a16        — set A
      7. LDX #x16        — set X
      8. LDY #y16        — set Y
      9. (if e=1): SEC; XCE — back to emu (forces S high=$01, clobbers C)
     10. SEP #$20; LDA #p; PHA; LDA #a_lo; PLP
                                       set P last so PLP fixes any
                                       C/D/Z/etc. that XCE perturbed
     11. JML pbr:pc

    PLP-last is critical: every other instruction (LDA, PLA, XCE) updates
    N/Z, and XCE-to-emu sets new C = old E = 0. Putting PLP at the end
    forces the case's full P (including N, Z, C, D) to be the last write.

    The mid-step LDA #a_lo restores A_low after LDA #p clobbered it.
    LDA #a16 in step 6 already loaded both bytes; this 8-bit reload only
    fixes A_lo without touching B (high byte of C). Its N/Z side-effect
    is overwritten by the trailing PLP.

    Stack footprint: 1 transient byte at $01:(S_low). If case.initial.ram
    lists that address, the case is skipped by the bench.
    """
    code = []
    s_lo = init['s'] & 0xFF
    s_hi = (init['s'] >> 8) & 0xFF
    a_lo = init['a'] & 0xFF
    a_hi = (init['a'] >> 8) & 0xFF
    x_lo = init['x'] & 0xFF
    x_hi = (init['x'] >> 8) & 0xFF
    y_lo = init['y'] & 0xFF
    y_hi = (init['y'] >> 8) & 0xFF
    d_lo = init['d'] & 0xFF
    d_hi = (init['d'] >> 8) & 0xFF
    pc_lo = init['pc'] & 0xFF
    pc_hi = (init['pc'] >> 8) & 0xFF

    # 1. CLC; XCE -> native
    code += [0x18, 0xFB]
    # 2. REP #$30 -> M=0, X=0
    code += [0xC2, 0x30]
    # 3. LDA #d16; TCD
    code += [0xA9, d_lo, d_hi, 0x5B]
    # 4. SEP #$20; LDA #dbr; PHA; PLB; REP #$20
    code += [0xE2, 0x20]                       # SEP #$20 (M=1)
    code += [0xA9, init['dbr']]                # LDA #dbr
    code += [0x48]                             # PHA
    code += [0xAB]                             # PLB
    code += [0xC2, 0x20]                       # REP #$20 (M=0)
    # 5. LDX #s16; TXS
    code += [0xA2, s_lo, s_hi, 0x9A]
    # 6. LDA #a16
    code += [0xA9, a_lo, a_hi]
    # 7. LDX #x16
    code += [0xA2, x_lo, x_hi]
    # 8. LDY #y16
    code += [0xA0, y_lo, y_hi]
    # 9. (if e=1) SEC; XCE -> back to emu (clobbers C)
    if init['e'] == 1:
        code += [0x38, 0xFB]
    # 10. SEP #$20; LDA #p; PHA; LDA #a_lo; PLP
    #     PLP is the LAST instruction before JML so case.p (including
    #     N and Z) is the final write to P. Earlier prelude form ended
    #     with PLA, which updated N/Z from a_lo and broke ~50% of
    #     TSB/TRB cases (any with a_lo[7]=1 had N flag wrong).
    #     LDA #a_lo re-loads A_low after LDA #p clobbered it; in 8-bit
    #     M mode this preserves B (A_high). One transient stack byte
    #     is touched at $01:(S_low).
    code += [0xE2, 0x20]                       # SEP #$20 (8-bit A)
    code += [0xA9, init['p']]                  # LDA #p
    code += [0x48]                             # PHA (push p)
    code += [0xA9, a_lo]                       # LDA #a_lo (restore A_lo)
    code += [0x28]                             # PLP (final write to P)
    # 11. JML pbr:pc
    code += [0x5C, pc_lo, pc_hi, init['pbr']]
    return code


def write_record(out, case_idx, case):
    init = case['initial']
    final = case['final']
    cycles = case['cycles']

    out.write(f"C {case_idx}\n")
    out.write("I {:04X} {:04X} {:02X} {:04X} {:04X} {:04X} {:04X} {:02X} {:02X} {}\n".format(
        init['pc'], init['s'], init['p'], init['a'], init['x'], init['y'],
        init['d'], init['dbr'], init['pbr'], init['e']))

    pre = make_prelude(init)
    out.write(f"PRE {len(pre)}\n  ")
    out.write(" ".join(f"{b:02X}" for b in pre))
    out.write("\n")

    out.write(f"IR {len(init['ram'])}\n")
    for addr, val in init['ram']:
        out.write(f"  {addr:06X} {val:02X}\n")

    out.write("F {:04X} {:04X} {:02X} {:04X} {:04X} {:04X} {:04X} {:02X} {:02X} {}\n".format(
        final['pc'], final['s'], final['p'], final['a'], final['x'], final['y'],
        final['d'], final['dbr'], final['pbr'], final['e']))

    out.write(f"FR {len(final['ram'])}\n")
    for addr, val in final['ram']:
        out.write(f"  {addr:06X} {val:02X}\n")

    out.write(f"CY {len(cycles)}\n")
    for cyc in cycles:
        addr, val, flags = cyc
        # WAI/STP and similar emit cycles with addr=null (no bus driven).
        # Encode as FFFFFF/XX/0; bench treats valid=0 as "don't compare".
        addr_str = "FFFFFF" if addr is None else f"{addr:06X}"
        if val is None:
            out.write(f"  {addr_str} XX 0 {flags}\n")
        else:
            out.write(f"  {addr_str} {val:02X} 1 {flags}\n")

    out.write("E\n")


def convert_one(opcode, mode, max_cases=None):
    src = os.path.join(JSON_DIR, f"{opcode:02x}.{mode}.json")
    dst = os.path.join(BIN_DIR,  f"{opcode:02x}.{mode}.txt")
    if not os.path.exists(src):
        print(f"  skip {src} — not found")
        return
    with open(src) as f:
        cases = json.load(f)
    if max_cases is not None:
        cases = cases[:max_cases]
    os.makedirs(BIN_DIR, exist_ok=True)
    with open(dst, 'w') as out:
        out.write(f"H {opcode:02X} {mode} {len(cases)}\n")
        for i, c in enumerate(cases):
            write_record(out, i, c)
    sz = os.path.getsize(dst)
    print(f"  {src} -> {dst}  ({len(cases)} cases, {sz/1024:.0f} KB)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('opcode', nargs='?', help="hex opcode (e.g. 06)")
    ap.add_argument('mode',   nargs='?', help="e or n")
    ap.add_argument('--max',  type=int, help="max cases (truncate for testing)")
    ap.add_argument('--rmw',  action='store_true', help="convert all 28 RMW opcodes both modes")
    ap.add_argument('--all',  action='store_true', help="convert all 256 opcodes both modes (Phase 2)")
    args = ap.parse_args()

    if args.all:
        for op in range(256):
            for mode in ('e', 'n'):
                convert_one(op, mode, args.max)
        return

    if args.rmw:
        for op in RMW_OPCODES:
            for mode in ('e', 'n'):
                convert_one(op, mode, args.max)
        return

    if not args.opcode or not args.mode:
        ap.error("specify opcode + mode, or --rmw")

    op = int(args.opcode, 16)
    convert_one(op, args.mode, args.max)


if __name__ == '__main__':
    main()
