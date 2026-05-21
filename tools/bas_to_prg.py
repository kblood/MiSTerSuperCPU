#!/usr/bin/env python3
"""Tokenize a C64 BASIC v2 source file into a PRG that loads at $0801.

Usage:
    python bas_to_prg.py <input.bas> <output.prg>

The tokenizer does a greedy longest-match on BASIC v2 keywords (case
insensitive). Literals inside double-quoted strings are passed through
verbatim. Spaces are preserved as 0x20.
"""

import sys

# BASIC v2 keyword table. Order matters only in the sense that we sort by
# descending length so longer keywords win (e.g. GOTO before GO, CHR$ before
# CHR). The token value is fixed regardless of ordering.
TOKENS = {
    "END":    0x80,
    "FOR":    0x81,
    "NEXT":   0x82,
    "DATA":   0x83,
    "INPUT#": 0x84,
    "INPUT":  0x85,
    "DIM":    0x86,
    "READ":   0x87,
    "LET":    0x88,
    "GOTO":   0x89,
    "RUN":    0x8A,
    "IF":     0x8B,
    "RESTORE":0x8C,
    "GOSUB":  0x8D,
    "RETURN": 0x8E,
    "REM":    0x8F,
    "STOP":   0x90,
    "ON":     0x91,
    "WAIT":   0x92,
    "LOAD":   0x93,
    "SAVE":   0x94,
    "VERIFY": 0x95,
    "DEF":    0x96,
    "POKE":   0x97,
    "PRINT#": 0x98,
    "PRINT":  0x99,
    "CONT":   0x9A,
    "LIST":   0x9B,
    "CLR":    0x9C,
    "CMD":    0x9D,
    "SYS":    0x9E,
    "OPEN":   0x9F,
    "CLOSE":  0xA0,
    "GET":    0xA1,
    "NEW":    0xA2,
    "TAB(":   0xA3,
    "TO":     0xA4,
    "FN":     0xA5,
    "SPC(":   0xA6,
    "THEN":   0xA7,
    "NOT":    0xA8,
    "STEP":   0xA9,
    "+":      0xAA,
    "-":      0xAB,
    "*":      0xAC,
    "/":      0xAD,
    "^":      0xAE,
    "AND":    0xAF,
    "OR":     0xB0,
    ">":      0xB1,
    "=":      0xB2,
    "<":      0xB3,
    "SGN":    0xB4,
    "INT":    0xB5,
    "ABS":    0xB6,
    "USR":    0xB7,
    "FRE":    0xB8,
    "POS":    0xB9,
    "SQR":    0xBA,
    "RND":    0xBB,
    "LOG":    0xBC,
    "EXP":    0xBD,
    "COS":    0xBE,
    "SIN":    0xBF,
    "TAN":    0xC0,
    "ATN":    0xC1,
    "PEEK":   0xC2,
    "LEN":    0xC3,
    "STR$":   0xC4,
    "VAL":    0xC5,
    "ASC":    0xC6,
    "CHR$":   0xC7,
    "LEFT$":  0xC8,
    "RIGHT$": 0xC9,
    "MID$":   0xCA,
    "GO":     0xCB,
}

# Sort keywords longest first so greedy match picks GOTO over GO, CHR$ over
# any shorter prefix, etc.
SORTED_KEYWORDS = sorted(TOKENS.keys(), key=len, reverse=True)

LOAD_ADDR = 0x0801


def tokenize_body(text: str) -> bytes:
    """Tokenize the body of a single BASIC line (no line number)."""
    out = bytearray()
    i = 0
    upper = text.upper()
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ord(ch) & 0xFF)
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            out.append(ord('"'))
            in_string = True
            i += 1
            continue
        # Try to match a keyword at this position.
        matched = None
        for kw in SORTED_KEYWORDS:
            if upper.startswith(kw, i):
                matched = kw
                break
        if matched is not None:
            out.append(TOKENS[matched])
            i += len(matched)
            continue
        # Fallback: literal byte, upper-cased.
        out.append(ord(upper[i]) & 0xFF)
        i += 1
    return bytes(out)


def tokenize_program(source: str) -> bytes:
    """Tokenize a full BASIC source into PRG bytes (including $0801 header)."""
    prg = bytearray()
    prg.append(LOAD_ADDR & 0xFF)
    prg.append((LOAD_ADDR >> 8) & 0xFF)

    current_addr = LOAD_ADDR  # address of the pointer field of the next line

    for raw_line in source.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        # Extract line number.
        num_end = 0
        while num_end < len(line) and line[num_end].isdigit():
            num_end += 1
        if num_end == 0:
            raise ValueError(f"line has no line number: {raw_line!r}")
        line_num = int(line[:num_end])
        body_text = line[num_end:]
        # C64 BASIC generally strips a single leading space after the line
        # number (the LIST display puts it back). Matches most tokenizers.
        if body_text.startswith(" "):
            body_text = body_text[1:]

        body = tokenize_body(body_text)
        # Each line record: 2 bytes next-line pointer, 2 bytes line number,
        # N bytes body, 1 byte terminator 0x00.
        line_len = 2 + 2 + len(body) + 1
        next_addr = current_addr + line_len

        prg.append(next_addr & 0xFF)
        prg.append((next_addr >> 8) & 0xFF)
        prg.append(line_num & 0xFF)
        prg.append((line_num >> 8) & 0xFF)
        prg.extend(body)
        prg.append(0x00)

        current_addr = next_addr

    # End-of-program marker: two zero bytes where the next-line pointer of a
    # would-be following line would live.
    prg.append(0x00)
    prg.append(0x00)
    return bytes(prg)


def main(argv):
    if len(argv) != 3:
        print("usage: bas_to_prg.py <input.bas> <output.prg>", file=sys.stderr)
        return 1
    with open(argv[1], "r", encoding="ascii") as f:
        source = f.read()
    prg = tokenize_program(source)
    with open(argv[2], "wb") as f:
        f.write(prg)
    print(f"wrote {len(prg)} bytes to {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
