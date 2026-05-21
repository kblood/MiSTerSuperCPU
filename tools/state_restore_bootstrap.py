"""state_restore_bootstrap.py — generate a 65C816 bootstrap that puts the
CPU into a snapshotted state, then JMLs to the snapshot PC.

Used by `sim/cocotb/tests/test_doom_gameplay_diff.py` to bring both DUT
and VICE into VICE's mid-gameplay state via identical opcode-level
bootstrap. Both sides execute the bootstrap from the SAME bank-$00
location (default: $FF10), so the diff measures CPU divergence only,
not setup divergence.

Sequencing (carefully ordered so each step doesn't clobber later state):
    1. SEI; CLD                ; safe init
    2. CLC; XCE                ; native mode (E=0)
    3. REP #$30                ; 16-bit M and X (lets us LDA/X/Y 16-bit
                                  immediates regardless of snapshot M/X)
    4. LDA #SP_VAL; TCS        ; SP via 16-bit C
    5. LDA #D_VAL;  TCD        ; D  via 16-bit C
    6. SEP #$20                ; A->8-bit so PHA pushes 1 byte
    7. LDA #DBR_VAL; PHA; PLB  ; DBR set
    8. LDA #P_VAL;  PHA; PLP   ; P set (M and X bits now snapshot values)
    9. (A is now snapshot M-width; X/Y now snapshot X-width)
       LDA #A_VAL              ; snapshot M decides operand width
       LDX #X_VAL              ; snapshot X decides operand width
       LDY #Y_VAL              ; snapshot X decides operand width
   10. JML PBR:PC               ; jump to snapshot's PC

Note re. registers WIDTH after PLP:
- PLP sets P to the snapshot value, including bit 5 (M) and bit 4 (X).
- Hardware behaviour: when SEP/PLP transitions M from 0->1, the high
  byte of A (the "B" register) is preserved (hidden). Our snapshot's A
  is the full 16-bit C; if M=1 in snapshot, only A_low is "live" but B
  also matters and we cannot easily restore B without 16-bit LDA before
  SEP. So step 9 in 16-bit mode (M=0) is straightforward; in 8-bit mode
  (M=1) we accept that B = $00 unless the test snapshot has B == 0.
  TODO: handle non-zero B for snapshots where M=1 by doing a brief
  REP #$20; LDA #B_HIGH:A_LOW; SEP #$20 sequence inside step 9 if needed.

For the music_num=-9 snapshot (PC=$2A:$55A9), regs are:
    pbr=$2A pc=$55A9 a=$2C71 (B=$2C, A_low=$71) x=$0001 y=$FFFF
    sp=$01FF p=$20 (M=1, X=0) e=0
B is $2C — non-zero. So step 9 handles M=1 specially, restoring 16-bit
C first then SEP'ing.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Snapshot:
    pbr: int
    pc: int
    a: int       # full 16-bit C; high byte = B (preserved across M=1 mode)
    x: int       # full 16-bit X
    y: int       # full 16-bit Y
    sp: int      # full 16-bit S
    d: int       # full 16-bit Direct Page
    dbr: int     # 8-bit Data Bank
    p: int       # processor flags byte
    e: int       # E flag (1 = emulation, 0 = native)
    # Saved bytes from $00:$01FE and $00:$01FF (the two stack-top bytes
    # that the bootstrap will push DBR/P onto, then pop). Bootstrap
    # restores these as the LAST step before JML so Doom sees the
    # snapshot's original stack-top contents, not our bootstrap pushes.
    stack_1fe: int = 0x00
    stack_1ff: int = 0x00

    @classmethod
    def from_regs_dict(cls, r: dict) -> "Snapshot":
        return cls(
            pbr=r["pbr"], pc=r["pc"],
            a=r["a"], x=r["x"], y=r["y"],
            sp=r["sp"],
            d=r.get("d", 0x0000),       # ViceOracle.regs() doesn't return D
            dbr=r.get("db", r.get("dbr", 0x00)),
            p=r["p"],
            e=r["e"],
            stack_1fe=r.get("stack_1fe", 0x00),
            stack_1ff=r.get("stack_1ff", 0x00),
        )


def build_bootstrap(snap: Snapshot) -> bytes:
    """Return the bootstrap byte stream that restores `snap` and JMLs to PC.

    The output length is variable (~30-40 bytes depending on snapshot M/X
    bits). Caller plants this at a chosen address (default $00:$FF10) and
    points the reset vector ($00:$FFFC) there.

    We do NOT support snapshots with E=1 (emulation mode) since the diff
    targets gameplay which is always native. Raises if snap.e != 0.
    """
    if snap.e != 0:
        raise ValueError(
            f"snapshot is in emulation mode (e=1); only native-mode "
            f"snapshots are supported"
        )

    m_8bit = bool(snap.p & 0x20)   # M=1 -> 8-bit A
    x_8bit = bool(snap.p & 0x10)   # X=1 -> 8-bit X/Y

    code = bytearray()

    # 1) SEI; CLD
    code += bytes([0x78, 0xD8])

    # 2) CLC; XCE -> native
    code += bytes([0x18, 0xFB])

    # 3) REP #$30  -> 16-bit M and X
    code += bytes([0xC2, 0x30])

    # 4) LDA #$XXXX; TCS  (16-bit immediate; A = sp_val; TCS opcode = $1B)
    code += bytes([0xA9, snap.sp & 0xFF, (snap.sp >> 8) & 0xFF, 0x1B])

    # 5) LDA #$XXXX; TCD  (TCD opcode = $5B)
    code += bytes([0xA9, snap.d & 0xFF, (snap.d >> 8) & 0xFF, 0x5B])

    # 6) SEP #$20  -> A is 8-bit
    code += bytes([0xE2, 0x20])

    # 7) LDA #DBR; PHA; PLB
    code += bytes([0xA9, snap.dbr & 0xFF, 0x48, 0xAB])

    # 8) LDA #P_VAL; PHA; PLP   (P now matches snapshot, including M, X)
    code += bytes([0xA9, snap.p & 0xFF, 0x48, 0x28])

    # 9a) Restore X, Y
    if x_8bit:
        # X is 8-bit per snapshot; LDX # is 2 bytes
        code += bytes([0xA2, snap.x & 0xFF])
        code += bytes([0xA0, snap.y & 0xFF])
    else:
        # 16-bit X; LDX # is 3 bytes
        code += bytes([0xA2, snap.x & 0xFF, (snap.x >> 8) & 0xFF])
        code += bytes([0xA0, snap.y & 0xFF, (snap.y >> 8) & 0xFF])

    # 9b) Restore stack-top bytes $00:$01FE and $00:$01FF. The bootstrap's
    #     PHA pushed DBR_VAL to $01FF and PHA pushed P_VAL to $01FF (after
    #     PLB popped, so $01FE then $01FF). Use long absolute STA to bypass
    #     DBR (which is now snap.dbr, not necessarily $00). A is currently
    #     8-bit (still in M=1 mode from the SEP at step 6 — PLP just set it
    #     to snapshot M, but we want 8-bit for these single-byte stores).
    #
    #     If snapshot M=0, force SEP #$20 first; if snapshot M=1, A is
    #     already 8-bit. We re-REP to 16-bit later for the A restore.
    if not m_8bit:
        code += bytes([0xE2, 0x20])    # SEP #$20 -> 8-bit A for stack stores
    code += bytes([0xA9, snap.stack_1ff & 0xFF])
    code += bytes([0x8F, 0xFF, 0x01, 0x00])    # STA $00:$01FF (long abs)
    code += bytes([0xA9, snap.stack_1fe & 0xFF])
    code += bytes([0x8F, 0xFE, 0x01, 0x00])    # STA $00:$01FE (long abs)

    # 9c) Restore A. If M=0 (16-bit), REP back to 16-bit then LDA full.
    #     If M=1 (8-bit), just LDA #A_low. (B = A_high stays $00 unless we
    #     also did REP+LDA full+SEP. We do that for M=1 too so B is set.)
    if m_8bit:
        # REP #$20; LDA #$XXXX; SEP #$20  (preserves B)
        code += bytes([0xC2, 0x20])
        code += bytes([0xA9, snap.a & 0xFF, (snap.a >> 8) & 0xFF])
        code += bytes([0xE2, 0x20])
    else:
        # We previously SEP'd for stack stores; REP back to 16-bit.
        code += bytes([0xC2, 0x20])
        code += bytes([0xA9, snap.a & 0xFF, (snap.a >> 8) & 0xFF])

    # 10) JML PB:PC  (opcode $5C, then 24-bit operand low/mid/high)
    code += bytes([
        0x5C,
        snap.pc & 0xFF, (snap.pc >> 8) & 0xFF,
        snap.pbr & 0xFF,
    ])

    return bytes(code)


# ----------------------------------------------------------------------
# Self-test
# ----------------------------------------------------------------------
def _self_test() -> None:
    snap = Snapshot(
        pbr=0x2A, pc=0x55A9,
        a=0x2C71, x=0x0001, y=0xFFFF,
        sp=0x01FF, d=0x0000, dbr=0x00,
        p=0x20, e=0,
        stack_1fe=0x96, stack_1ff=0xA9,
    )
    bs = build_bootstrap(snap)
    print(f"bootstrap: {len(bs)} bytes")
    print(f"  hex: {bs.hex()}")
    # Expected JML target at end: 5C A9 55 2A
    assert bs[-4:] == bytes([0x5C, 0xA9, 0x55, 0x2A]), "JML tail mismatch"
    print("  JML tail OK")
    # Sanity: stack restore opcodes present
    assert bytes([0x8F, 0xFF, 0x01, 0x00]) in bs, "missing STA $01FF long"
    assert bytes([0x8F, 0xFE, 0x01, 0x00]) in bs, "missing STA $01FE long"
    print("  stack restore OK")
    assert len(bs) <= 64, f"bootstrap too long: {len(bs)} > 64 bytes"
    print(f"  fits in 64-byte budget ({len(bs)} bytes)")


if __name__ == "__main__":
    _self_test()
