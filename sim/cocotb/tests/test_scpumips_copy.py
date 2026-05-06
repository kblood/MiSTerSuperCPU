"""test_scpumips_copy.py — Layer 1 validation.

Direct port of sim/p65c816_tb/p65c816_scpumips_copy_tb.vhd.

Same SCPUMIPS-style copy program: native-mode 16-byte copy from
$80:$1234 → $00:$2000 using long-abs,X opcodes ($BF / $9F), then a
sentinel $77 stored at $00:$3000 via long-abs ($8F).

Pass criteria:
  * mem[$00:$3000] == 0x77
  * mem[$00:$2000..$200F] == 0xC0..0xCF

If this fails, the cocotb toolchain (GHDL gcc backend, VPI loading,
DutFixture clock/bus loop) is broken — fix Layer 1 before doing anything
else.
"""

from __future__ import annotations

import cocotb

from .dut_fixture import DutFixture


# ---------------------------------------------------------------------------
# Program assembly — mirrors the VHDL bench byte-for-byte.
# ---------------------------------------------------------------------------

def _assemble_program() -> dict:
    """Returns dict of {(bank, offset): bytes} chunks to load."""
    chunks: dict[tuple[int, int], bytes] = {}

    # ----- Bank $00 vectors -----
    # Reset vector → $0800
    chunks[(0x00, 0xFFFC)] = bytes([0x00, 0x08])
    # Native vectors → $FF00 (RTI sink)
    chunks[(0x00, 0xFFE6)] = bytes([0x00, 0xFF])  # BRK-N
    chunks[(0x00, 0xFFEE)] = bytes([0x00, 0xFF])  # IRQ-N
    chunks[(0x00, 0xFFEA)] = bytes([0x00, 0xFF])  # NMI-N
    chunks[(0x00, 0xFFFE)] = bytes([0x00, 0xFF])  # IRQ-emu
    chunks[(0x00, 0xFF00)] = bytes([0x40])         # RTI

    # ----- Test program at $00:$0800 -----
    prog = bytes([
        # $0800: 18           CLC
        0x18,
        # $0801: FB           XCE          ; → native (E=0, C=1)
        0xFB,
        # $0802: C2 30        REP #$30     ; M=0, X=0
        0xC2, 0x30,
        # $0804: A9 00 00     LDA #$0000
        0xA9, 0x00, 0x00,
        # $0807: 5B           TCD          ; DP=0
        0x5B,
        # $0808: A9 FF 01     LDA #$01FF
        0xA9, 0xFF, 0x01,
        # $080B: 1B           TCS          ; SP=$01FF
        0x1B,
        # $080C: E2 20        SEP #$20     ; M=1
        0xE2, 0x20,
        # $080E: A9 00        LDA #$00
        0xA9, 0x00,
        # $0810: 48           PHA
        0x48,
        # $0811: AB           PLB          ; DBR=0
        0xAB,
        # $0812: A2 00 00     LDX #$0000   (X is 16-bit due to REP)
        0xA2, 0x00, 0x00,
        # $0815: E0 10 00     CPX #$0010
        0xE0, 0x10, 0x00,
        # $0818: F0 0B        BEQ +$0B → $0825 (done)
        0xF0, 0x0B,
        # $081A: BF 34 12 80  LDA $801234,X (long-abs,X)
        0xBF, 0x34, 0x12, 0x80,
        # $081E: 9F 00 20 00  STA $002000,X (long-abs,X)
        0x9F, 0x00, 0x20, 0x00,
        # $0822: E8           INX
        0xE8,
        # $0823: 80 F0        BRA -$10 → $0815 (loop)
        0x80, 0xF0,
        # $0825: A9 77        LDA #$77    (M=1)
        0xA9, 0x77,
        # $0827: 8F 00 30 00  STA $003000  (long-abs sentinel)
        0x8F, 0x00, 0x30, 0x00,
        # $082B: 80 FE        BRA -2 (spin)
        0x80, 0xFE,
    ])
    chunks[(0x00, 0x0800)] = prog

    # ----- Bank $80 source data: $1234..$1243 = $C0..$CF -----
    chunks[(0x80, 0x1234)] = bytes(range(0xC0, 0xD0))

    return chunks


@cocotb.test()
async def test_scpumips_copy(dut):
    """SCPUMIPS-style 16-byte cross-bank copy via long-abs,X opcodes."""

    # Build the fixture and load the program.
    fix = DutFixture(dut, clk_period_ns=31.25)
    for (bank, off), data in _assemble_program().items():
        fix.load_bytes(bank, off, data)

    # Patch the reset vector explicitly (already in chunks, but make
    # the dependency on patch_reset_vector visible for downstream tests).
    fix.patch_reset_vector(0x0800)

    # Start the bus driver before reset so the very first read is served.
    cocotb.start_soon(fix.clock_and_bus_loop())

    # Reset the DUT.
    await fix.reset(cycles=8)

    # The original bench runs for 5000 cycles. At ~5 cycles/instruction
    # that is ~1000 fetches; the copy loop is 7 instr × 16 iters + ~12
    # bootstrap + 4 sentinel ≈ 130 fetches. 400 is a safe ceiling that
    # lets a few BRA-spin iterations happen at the end.
    await fix.run_n_instructions(400)

    # ----- Pass / fail checks -----
    sentinel = fix.get_mem_byte(0x00, 0x3000)
    dut._log.info(f"sentinel $00:$3000 = ${sentinel:02X}")
    for i in range(16):
        b = fix.get_mem_byte(0x00, 0x2000 + i)
        dut._log.info(f"  $00:$200{i:X} = ${b:02X}")

    assert sentinel == 0x77, (
        f"sentinel $00:$3000 expected $77, got ${sentinel:02X}. "
        "Test program never reached the LDA #$77 / STA $003000 block."
    )

    expected = list(range(0xC0, 0xD0))
    actual = [fix.get_mem_byte(0x00, 0x2000 + i) for i in range(16)]
    assert actual == expected, (
        f"copy mismatch at $00:$2000..$200F\n"
        f"  expected: {[f'{x:02X}' for x in expected]}\n"
        f"  actual:   {[f'{x:02X}' for x in actual]}"
    )

    dut._log.info(
        f"PASS: SCPUMIPS copy completed. "
        f"{len(fix.get_trace_entries())} fetches captured."
    )
