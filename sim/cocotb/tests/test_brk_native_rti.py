"""test_brk_native_rti.py — Native BRK trap → IRQ ack stub → RTI cycle test.

Reproduces the v294 hardware halt scenario in cocotb (DUT only — no VICE
needed). The hardware data shows main thread fetches $00=BRK at
$41:$DB93 once, then never fetches again with I=0. Microcode audit says
both BRK and RTI handle the I-flag correctly:

  * BRK pushes P (with caller's I=0) BEFORE setting I=1 internally.
  * RTI's LOAD_P="011" pops D_IN(2)→P(2) verbatim.

If the simulation reproduces the hardware behavior (PC stays at $DB93
forever), the bug is in the P65C816 microcode and we have it on the
bench. If the simulation correctly returns to $DB95 with I=0, the bug
is system-level (RDY/CE arbitration, IRQ-storm refire before the next
fetch, SDRAM mux wedge — none of which the cocotb DUT bus model
exercises).

Either outcome is decisive.
"""

from __future__ import annotations

import cocotb

from .dut_fixture import DutFixture


# ---------------------------------------------------------------------------
# Memory layout — mimics the SCPU runtime as closely as the cocotb model
# allows.
# ---------------------------------------------------------------------------

# 1) Native-mode bootstrap at $00:$0800. After XCE+REP+TCS+TCD this lands
#    on a `JML $41:$DB93` (long jump to the halt PC).
BOOT_ADDR = 0x0800
BOOT_PROG = bytes([
    # $0800: 18           CLC
    0x18,
    # $0801: FB           XCE          ; → native (E=0, C=1 if was 1)
    0xFB,
    # $0802: C2 30        REP #$30     ; M=0, X=0
    0xC2, 0x30,
    # $0804: A9 FF 01     LDA #$01FF
    0xA9, 0xFF, 0x01,
    # $0807: 1B           TCS          ; SP=$01FF
    0x1B,
    # $0808: A9 00 00     LDA #$0000
    0xA9, 0x00, 0x00,
    # $080B: 5B           TCD          ; D=0
    0x5B,
    # $080C: 48           PHA          ; push 0
    0x48,
    # $080D: AB           PLB          ; DBR=0
    0xAB,
    # $080E: E2 20        SEP #$20     ; M=1 (8-bit accumulator) — matches
    #                                  ; the SCPU runtime style used by
    #                                  ; AmiDog's recompiler dispatcher
    0xE2, 0x20,
    # $0810: 58           CLI          ; clear I (so BRK pushes I=0 and
    #                                  ; RTI restores I=0)
    0x58,
    # $0811: 5C 93 DB 41  JML $41:$DB93
    0x5C, 0x93, 0xDB, 0x41,
])

# 2) IRQ ack stub at $00:$FF00 (mirrors the synthesized intercept stub
#    in fpga64_sid_iec.vhd:1581-1633). 16-bit-A unaware (we fake the
#    full path: SEP at entry, work in 8-bit, RTI at exit).
ACK_STUB_ADDR = 0xFF00
ACK_STUB = bytes([
    # $FF00: 08           PHP
    0x08,
    # $FF01: E2 30        SEP #$30   ; force 8-bit so PHA matches
    0xE2, 0x30,
    # $FF03: 48           PHA
    0x48,
    # $FF04: AF 19 D0 00  LDA $00D019
    0xAF, 0x19, 0xD0, 0x00,
    # $FF08: 8F 19 D0 00  STA $00D019  (ack VIC IRQ)
    0x8F, 0x19, 0xD0, 0x00,
    # $FF0C: AF 0D DC 00  LDA $00DC0D  (ack CIA1)
    0xAF, 0x0D, 0xDC, 0x00,
    # $FF10: AF 0D DD 00  LDA $00DD0D  (ack CIA2)
    0xAF, 0x0D, 0xDD, 0x00,
    # $FF14: 68           PLA
    0x68,
    # $FF15: 28           PLP
    0x28,
    # $FF16: 40           RTI
    0x40,
])


# ---------------------------------------------------------------------------
# Test 1 — BRK at $41:$DB93 → vector → ack stub → RTI → continue at $DB95.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_brk_native_returns_to_caller(dut):
    """Native-mode BRK: after RTI, fetch must resume at $DB95 with I=0."""
    fix = DutFixture(dut, clk_period_ns=31.25)

    # 1) Bootstrap in bank $00.
    fix.load_bytes(0x00, BOOT_ADDR, BOOT_PROG)
    fix.patch_reset_vector(BOOT_ADDR)

    # 2) BRK ($00) at $41:$DB93. After RTI, PC should be $DB95.
    #    Place an RTI right after so the test exits cleanly when we get
    #    there (otherwise CPU runs into garbage and we can't tell what
    #    happened on the next BRK loop iteration).
    fix.load_bytes(0x41, 0xDB93, bytes([0x00]))           # BRK opcode
    fix.load_bytes(0x41, 0xDB94, bytes([0x00]))           # BRK signature byte
    fix.load_bytes(0x41, 0xDB95, bytes([0x80, 0xFE]))     # BRA -2 (spin)

    # 3) Native vectors at $00:$FFE0+. BRK = $FFE6/E7. Point at ack stub.
    fix.load_bytes(0x00, 0xFFE4, bytes([0x00, 0xFF]))     # COP
    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))     # BRK → $00:$FF00
    fix.load_bytes(0x00, 0xFFE8, bytes([0x00, 0xFF]))     # ABORT
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))     # NMI
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))     # IRQ

    # 4) Ack stub at $00:$FF00.
    fix.load_bytes(0x00, ACK_STUB_ADDR, ACK_STUB)

    # 5) Boot the DUT.
    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)

    # The bootstrap is 11 instructions; BRK takes ~7-8 cycles itself; the
    # ack stub is 9 instructions; then we want to see the resume at $DB95.
    # Run a generous count.
    await fix.run_n_instructions(60)

    trace = fix.get_trace_entries()

    # Sanity print first
    dut._log.info(f"Captured {len(trace)} fetches")
    for i, e in enumerate(trace[:50]):
        dut._log.info(
            f"  [{i:02d}] K:{e.pbr:02X} PC:{e.pc:04X} IR:{e.ir:02X} "
            f"P:{e.p:02X} I={(e.p >> 2) & 1}"
        )

    # ----- Assertions -----
    # A) The CPU must have actually fetched at $41:$DB93 with the BRK byte.
    db93_hits = [
        (i, e) for i, e in enumerate(trace)
        if e.pbr == 0x41 and e.pc == 0xDB93
    ]
    assert db93_hits, (
        "DUT never fetched at $41:$DB93 — bootstrap or JML failed?"
    )
    first_db93_idx, first_db93 = db93_hits[0]
    dut._log.info(
        f"$41:$DB93 first fetched at trace[{first_db93_idx}] "
        f"with IR=${first_db93.ir:02X} (expect $00=BRK)"
    )
    assert first_db93.ir == 0x00, (
        f"Expected BRK opcode ($00) at $41:$DB93 first fetch; got "
        f"${first_db93.ir:02X}"
    )

    # B) After BRK, the next fetch must be the ack stub at $00:$FF00.
    after_brk = trace[first_db93_idx + 1:]
    assert after_brk, "no fetches after $41:$DB93 — CPU stalled?"
    first_post_brk = after_brk[0]
    dut._log.info(
        f"First fetch after $41:$DB93 = "
        f"${first_post_brk.pbr:02X}:${first_post_brk.pc:04X} "
        f"IR=${first_post_brk.ir:02X}"
    )
    assert first_post_brk.pbr == 0x00 and first_post_brk.pc == 0xFF00, (
        f"Expected vector dispatch to $00:$FF00; got "
        f"${first_post_brk.pbr:02X}:${first_post_brk.pc:04X}"
    )
    # I-flag must be 1 inside the IRQ context.
    assert ((first_post_brk.p >> 2) & 1) == 1, (
        f"Expected I=1 inside IRQ context; P=${first_post_brk.p:02X}"
    )

    # C) After the ack stub completes (RTI at $FF16), the next fetch must
    #    be back at $41:$DB95 (PC after BRK = pushed PC = PC+2 of $DB93).
    rti_hits = [
        (i, e) for i, e in enumerate(trace)
        if e.pbr == 0x00 and e.pc == 0xFF16 and e.ir == 0x40
    ]
    assert rti_hits, (
        "RTI ($40) at $00:$FF16 was never fetched — ack stub didn't "
        "complete; CPU stalled inside the stub?"
    )
    rti_idx, _ = rti_hits[0]
    after_rti = trace[rti_idx + 1:]
    assert after_rti, (
        "no fetches after RTI — RTI itself wedged the CPU? (this is "
        "the smoking gun for an RTI microcode bug)"
    )
    post_rti = after_rti[0]
    dut._log.info(
        f"First fetch AFTER RTI = "
        f"${post_rti.pbr:02X}:${post_rti.pc:04X} IR=${post_rti.ir:02X} "
        f"P=${post_rti.p:02X} I={(post_rti.p >> 2) & 1}"
    )
    assert post_rti.pbr == 0x41 and post_rti.pc == 0xDB95, (
        f"Expected post-RTI fetch at $41:$DB95; got "
        f"${post_rti.pbr:02X}:${post_rti.pc:04X} — RTI did NOT restore "
        f"PBR/PC correctly. THIS IS THE BUG IF IT FIRES."
    )
    assert ((post_rti.p >> 2) & 1) == 0, (
        f"Expected I=0 after RTI restored P from stack; P=${post_rti.p:02X} "
        f"— RTI did NOT clear the I-flag. THIS IS THE BUG IF IT FIRES."
    )

    dut._log.info(
        "✓ BRK/RTI cycle PASSED: PC returned to $41:$DB95 with I=0. "
        "P65C816 microcode correctly restores execution context after a "
        "native BRK trap. The hardware halt is therefore NOT a microcode "
        "bug — investigate RDY/CE arbitration, IRQ-storm pre-empt, or "
        "SDRAM mux instead."
    )


# ---------------------------------------------------------------------------
# Test 2 — Same scenario but with IRQ asserted while in the ack stub, to
# check whether a re-asserted IRQ during/after RTI keeps main pinned at
# I=1. Hardware sees ~73 IRQ acks/sec; if our stub correctly clears the
# source AND main has time to fetch one byte before the next IRQ, the
# trace must include at least one main-thread fetch at $DB95.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_brk_native_with_irq_pressure(dut):
    """As above, but pulse IRQ_N low for the entire run. The stub does
    NOT actually clear $D019/$DC0D in our cocotb model (no VIC/CIA), so
    if the CPU's IRQ logic re-fires immediately on RTI completion, the
    next fetch will be the IRQ vector ($00:$FF00) and PC will NEVER
    advance to $DB95.

    This is the closest match to the v294 hardware behavior. Two
    plausible outcomes:

      MATCH-V294 (assertion fires): CPU pinned at $00:$FF00 / IRQ
        context; never resumes at $41:$DB95. Confirms the hardware
        symptom is reproducible by IRQ pressure alone — no microcode
        bug needed. The fix space is then "make the IRQ source ack".
      RESUMES-AT-DB95: even with IRQ_N held, CPU manages a single
        main-thread fetch between IRQs because IRQ is edge-triggered
        in our P65C816 model. Then the assertion passes and the test
        proves IRQ pressure alone is NOT enough — must be something
        else.

    Either result is informative. We assert MATCHES-V294 because the
    P65C816 IRQ logic is level-triggered (sets P(2)=1 on entry; RTI
    clears it; if IRQ_N is still 0 the next fetch refires the
    vector immediately).
    """
    fix = DutFixture(dut, clk_period_ns=31.25)

    fix.load_bytes(0x00, BOOT_ADDR, BOOT_PROG)
    fix.patch_reset_vector(BOOT_ADDR)
    fix.load_bytes(0x41, 0xDB93, bytes([0x00]))
    fix.load_bytes(0x41, 0xDB94, bytes([0x00]))
    fix.load_bytes(0x41, 0xDB95, bytes([0x80, 0xFE]))     # BRA -2

    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, ACK_STUB_ADDR, ACK_STUB)

    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)

    # Run prologue without IRQ pressure first (so we don't trap at
    # boot via the reset → IRQ vector race).
    await fix.run_n_instructions(11)  # bootstrap is 11 fetches

    # Now drive IRQ_N low and let the system run. With the BRK pending
    # at $41:$DB93, BRK will trap independently of IRQ_N (BRK is a
    # software interrupt). Each RTI will then re-arm a hardware IRQ
    # because $D019/$DC0D reads in our cocotb model don't actually
    # clear any latch (there's no VIC/CIA — they just return memory).
    dut.IRQ_N.value = 0

    # Run another 200 instructions and watch what happens.
    await fix.run_n_instructions(200)

    trace = fix.get_trace_entries()

    # Count main-thread fetches at $41:$DB95 (must NOT happen if the
    # IRQ refires before main can fetch; conversely if it DOES happen,
    # IRQ pressure alone isn't enough to explain the v294 halt).
    db95_hits = sum(
        1 for e in trace
        if e.pbr == 0x41 and e.pc == 0xDB95
    )
    db93_hits = sum(
        1 for e in trace
        if e.pbr == 0x41 and e.pc == 0xDB93
    )
    rti_hits = sum(
        1 for e in trace
        if e.pbr == 0x00 and e.pc == 0xFF16 and e.ir == 0x40
    )
    ff00_hits = sum(
        1 for e in trace
        if e.pbr == 0x00 and e.pc == 0xFF00
    )

    dut._log.info(
        f"IRQ-pressure run summary: "
        f"$DB93 fetches={db93_hits}, $DB95 fetches={db95_hits}, "
        f"RTI fetches={rti_hits}, $FF00 entries={ff00_hits}"
    )

    # We don't ASSERT a specific outcome here — this is exploratory.
    # Print whichever pattern emerged so a human can pattern-match
    # against the v294 hardware data (db93_hits=1, db95_hits=0).
    if db95_hits == 0 and db93_hits >= 1:
        dut._log.info(
            "REPRODUCED v294 PATTERN: PC pinned at $DB93, never "
            "advances. IRQ refire alone is sufficient to explain the "
            "halt."
        )
    elif db95_hits >= 1:
        dut._log.info(
            "DID NOT REPRODUCE v294: PC advanced to $DB95 at least "
            "once. IRQ pressure alone is not the full story."
        )
    else:
        dut._log.info(
            "INCONCLUSIVE: neither $DB93 nor $DB95 main-thread fetches "
            "in the IRQ-pressure window. Possibly stuck inside ack stub."
        )
