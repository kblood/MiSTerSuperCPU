"""Quick dump of doom.reu bytes near a target address, to figure out
where bank-$20 JMLs land in bank $80 (and possibly other banks)."""
import pathlib

REU = pathlib.Path(__file__).resolve().parents[1] / "doom.reu"


def dump(bank: int, start: int, length: int = 0x40) -> None:
    data = REU.read_bytes()
    bnk = data[bank * 0x10000:(bank + 1) * 0x10000]
    region = bnk[start:start + length]
    nonzero = sum(1 for b in region if b != 0)
    print(f"--- bank ${bank:02x} ${start:04x}..${start + length:04x} "
          f"({nonzero}/{length} nonzero) ---")
    for i in range(0, length, 16):
        line = bnk[start + i:start + i + 16]
        hexs = " ".join(f"{b:02x}" for b in line)
        print(f"  ${bank:02x}:${start + i:04x}  {hexs}")


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        b = int(sys.argv[1], 0)
        a = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0
        n = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x80
        dump(b, a, n)
    else:
        for bnk, off in [
            (0x80, 0x0050),
            (0x80, 0x0060),
            (0x80, 0x0080),
            (0x80, 0x1000),
            (0x80, 0x2000),
        ]:
            dump(bnk, off)
