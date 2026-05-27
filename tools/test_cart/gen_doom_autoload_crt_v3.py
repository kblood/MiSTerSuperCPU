#!/usr/bin/env python3
"""Generate `doom_autoload.crt` v3 — BASIC-free direct ML entry.

v2 went through BASIC's RUN dispatch via `JMP $A474`. That path needs
$E3BF's CHRGOT install at zero page $0073-$008A, which we never run.
Result: BRK runaway at $00:$2022 within seconds of cart boot.

v3 skips BASIC entirely. The cart bootstrap copies doom_loader's INNER
ML body (the 187 bytes from $0820-$08DA in the original PRG, which the
$080D dispatcher would normally have copied to $0700) directly to $0700
and JMPs there. doom_loader.prg's outer wrapper (BASIC stub, $080D
dispatch, screen-clear sub, copy loop) is all bypassed.

Why this is cleaner than v1 (prg_to_crt direct wrap):
  - v1 loaded doom_loader.prg at $0801 and JMPed to $080D, which is the
    SYS 2061 dispatch target. SYS expects BASIC interpreter state from
    a prior BASIC RUN — A/X/Y restored from $030C-$030E, stack from
    BASIC's PHA chain, etc. Direct JMP bypasses that setup.
  - v3 jumps directly to $0700 where the inner ML starts with SEI;
    LDA #$35; STA $01. No BASIC dependency.

Why this is cleaner than v2 (Lorenz pattern):
  - v2 tried to drive BASIC through the keyboard buffer + JMP $A474.
    BASIC's main loop calls CHRGOT in zero page $0073, which is
    uninitialized RAM at cold cart boot. BRK runaway.
  - v3 doesn't touch BASIC.

Output: crt/doom_autoload.crt (overwrites v2).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from prg_to_crt import make_boot_crt


INNER_LOAD = 0x0700
INNER_LEN = 0xBB  # 187 bytes — matches the CPX #$BB in doom_loader's copy loop


def build_payload_prg() -> bytes:
    """Extract the inner ML from doom_loader.prg and pack as a PRG at $0700.

    Original doom_loader.prg structure (load $0801, body 252 bytes):
      $0801-$080C  BASIC stub `10 SYS 2061`
      $080D-$081F  outer ML: JSR $08DB; copy loop $0820..$08DA -> $0700; JMP $0700
      $0820-$08DA  inner ML (187 bytes) — the real loader
      $08DB-$08FC  screen-clear subroutine
    body offsets: 0x00-0x0B BASIC, 0x0C-0x1E outer, 0x1F-0xD9 inner.
    """
    prg_path = os.path.join(ROOT, 'tools', 'doom_loader.prg')
    if not os.path.isfile(prg_path):
        sys.exit(f"missing: {prg_path}  (fetch from MiSTer with sftp first)")

    with open(prg_path, 'rb') as f:
        prg = f.read()
    body = prg[2:]
    if len(body) < 0x1F + INNER_LEN:
        sys.exit(f"doom_loader.prg body too short: {len(body)} bytes")

    inner = body[0x1F:0x1F + INNER_LEN]
    print(f"extracted {len(inner)} bytes from $0820-$0{0x0820 + INNER_LEN - 1:04X}")
    print(f"first 16 bytes: {inner[:16].hex()}")
    print(f"  decode: SEI; LDA #$35; STA $01; STA $D07A; LDA #$00; STA $DF0A; ...")

    # Pad to a full page so the CRT bootstrap's 256-byte INY loop copies a
    # clean tail (NOPs after the real code, harmless if execution falls off).
    padded = bytearray(inner) + bytes([0xEA] * (256 - INNER_LEN))

    return bytes([INNER_LOAD & 0xFF, (INNER_LOAD >> 8) & 0xFF]) + bytes(padded)


COLOR_RAM_STUB_ADDR = 0x8049  # right after the 64-byte prg_to_crt bootstrap


def build_color_ram_stub() -> bytes:
    """17 bytes: clear $D800-$DBFF to $01 (white), then JMP $0700.

    Replicates the color-RAM half of doom_loader's screen-clear sub at
    $08DB (the original also clears $0400-$07FF to $20 but we skip that
    because (a) $0700 must NOT be clobbered after the cart copy, and (b)
    the inner ML's first REU FETCH overwrites $0400 with bitmap data).
    """
    return bytes([
        0xA9, 0x01,              # LDA #$01
        0xA2, 0x00,              # LDX #$00
        # loop:
        0x9D, 0x00, 0xD8,        # STA $D800,X
        0x9D, 0x00, 0xD9,        # STA $D900,X
        0x9D, 0x00, 0xDA,        # STA $DA00,X
        0x9D, 0x00, 0xDB,        # STA $DB00,X
        0xE8,                    # INX
        0xD0, 0xF1,              # BNE loop (-15)
        0x4C, 0x00, 0x07,        # JMP $0700
    ])


def patch_color_ram_init(crt: bytes, info: dict) -> bytes:
    """Splice the color-RAM-clear stub into the cart's unused ROM area and
    retarget the bootstrap's final JMP at it. The stub ends with JMP $0700
    so the inner ML still runs."""
    crt = bytearray(crt)
    rom_off = 64 + 16  # CRT header + CHIP header = 80
    boot_off = rom_off + 9  # vectors + CBM80 magic = 9 bytes before bootstrap
    bootstrap_size = info['bootstrap_size']
    # Final 3 bytes of bootstrap = `4C lo hi` JMP to entry ($0700).
    jmp_off = boot_off + bootstrap_size - 3
    if crt[jmp_off] != 0x4C:
        raise RuntimeError(f"expected JMP opcode at CRT[{jmp_off:#x}], got {crt[jmp_off]:#x}")
    # Retarget the JMP to the stub address ($8049).
    crt[jmp_off + 1] = COLOR_RAM_STUB_ADDR & 0xFF
    crt[jmp_off + 2] = (COLOR_RAM_STUB_ADDR >> 8) & 0xFF
    # Place stub at $8049 in cart ROM = rom[0x49] = CRT[rom_off + 0x49].
    stub = build_color_ram_stub()
    stub_off_in_rom = COLOR_RAM_STUB_ADDR - 0x8000  # = 0x49
    stub_crt_off = rom_off + stub_off_in_rom
    if boot_off + bootstrap_size > stub_crt_off:
        raise RuntimeError("bootstrap overlaps stub location")
    if stub_crt_off + len(stub) > rom_off + 0x100:
        raise RuntimeError("stub overlaps payload at $8100")
    crt[stub_crt_off:stub_crt_off + len(stub)] = stub
    return bytes(crt)


def main():
    payload_prg = build_payload_prg()
    payload_prg_path = os.path.join(HERE, 'out', 'doom_autoload_inner.prg')
    os.makedirs(os.path.dirname(payload_prg_path), exist_ok=True)
    with open(payload_prg_path, 'wb') as f:
        f.write(payload_prg)
    print(f"inner ML PRG: {payload_prg_path} ({len(payload_prg)} bytes)")

    # entry_offset=0 because inner ML starts directly at $0700.
    crt, info = make_boot_crt(payload_prg, name="DOOM AUTOLOAD V3", entry_offset=0)
    # v3.1: prepend a color-RAM-clear stub so $D800-$DBFF starts at $01 (white).
    # Without this the C64 bitmap mode shows BASIC's leftover color RAM (mostly
    # light blue + brown smear), giving a brown wash instead of the proper
    # green/red palette.
    crt = patch_color_ram_init(crt, info)
    print("v3.1: color-RAM-clear stub spliced at $8049 (17 bytes)")
    crt_path = os.path.join(ROOT, 'crt', 'doom_autoload.crt')
    with open(crt_path, 'wb') as f:
        f.write(crt)
    print(f"CRT: {crt_path} ({len(crt)} bytes)")
    print(f"  load_addr  ${info['load_addr']:04X}")
    print(f"  entry      ${info['entry']:04X}")
    print(f"  payload    {info['payload_size']} bytes")
    print(f"  bootstrap  {info['bootstrap_size']} bytes")


if __name__ == '__main__':
    main()
