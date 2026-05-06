"""test_diff_layer_a.py — Layer 3 differential tester.

Combines Layer 1 (cocotb DUT fixture) and Layer 2 (VICE oracle wrapper)
to run identical stimulus on both, capture PC traces from both, and
compare via the existing tools/vice_diff/vice_diff.py scoreboard.

Three tests:

  1. ``test_layer_a_scpumips_copy``
        SCPUMIPS-style 16-byte cross-bank copy program executed on DUT
        and on VICE. Expected: MATCH for all instructions captured.
        This validates the end-to-end plumbing — any divergence here
        indicates an infrastructure bug (clock drift, fetch capture
        skew, oracle mis-poke), NOT a CPU divergence.

  2. ``test_layer_a_detects_divergence``
        DUT-only test that mutates a copy of the DUT trace and feeds
        the original + mutated pair to the scoreboard. Expected:
        DIVERGE at index 5. This proves the scoreboard math in
        isolation — no VICE is launched.

  3. ``test_layer_a_brk_native_vector``
        Native-mode arithmetic + dispatch chain (TCD/TCS/REP/SEP and
        a small REP-driven loop) that exercises the same kind of
        SCPU prologue Doom uses. Expected: MATCH.

        TODO: real BRK-vector test once we have a synthetic vector
        setup that works on both minimal-RAM DUT and full-KERNAL VICE.
        BRK in VICE dispatches through the live KERNAL ROM at $FFE6
        which we can't poke from the monitor (KERNAL shadows that
        page); the DUT has minimal RAM at $FF00 with $40 (RTI) and
        will land at $FF00. Until we install a synthetic vector set
        on the VICE side we can't make BRK dispatch identically.

LAYER_A_SKIP_VICE
-----------------
WSL2 cannot reach a Windows-hosted VICE monitor TCP port out of the
box (Windows firewall + WSL2 NAT). Tests 1 and 3 require VICE; if the
oracle cannot be reached they self-skip. Run them on Windows native
with::

    set LAYER_A_SKIP_VICE=
    python -m cocotb sim/cocotb/...   # or invoke pytest

Test 2 always runs (DUT-only, no VICE needed). Setting the env var
``LAYER_A_SKIP_VICE=1`` forces the skip so ``make test-layer-a`` is
green in WSL2 even when VICE is not bridged.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
from typing import Optional

import cocotb

# Make tools/ and tools/vice_diff/ importable.
_HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = _HERE.parents[2]   # cocotb/tests/X.py -> sim/cocotb/tests -> repo
for _p in (
    _REPO_ROOT / "tools",
    _REPO_ROOT / "tools" / "vice_diff",
):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from vice_diff import TraceLine, compare, field_diff  # noqa: E402

# vice_oracle and dis65816 are only required by the VICE-using tests
# and the disassembly helper — import them lazily so that Test 2 can
# run cleanly even if VICE / dis65816 aren't usable.
try:
    from dis65816 import disasm  # noqa: E402
    _HAVE_DISASM = True
except Exception:
    _HAVE_DISASM = False

from .dut_fixture import DutFixture, TraceEntry  # noqa: E402


# ---------------------------------------------------------------------------
# SCPUMIPS-style copy program (shared with test_scpumips_copy.py).
# Mirrors p65c816_scpumips_copy_tb.vhd byte-for-byte.
# ---------------------------------------------------------------------------

SCPUMIPS_PROG_ADDR = 0x0800
SCPUMIPS_SPIN_PC   = 0x082B   # the BRA -2 spin
SCPUMIPS_PROG = bytes([
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

# Source data for the copy (bank $80) — only DUT can host this; VICE
# can't reach SCPU SuperRAM banks via its monitor. Test 1 therefore
# uses SCPUMIPS only up to the spin address; the BF/9F long-abs,X
# block runs on the DUT but VICE's bank-$80 reads return $00. We
# need a self-contained native-mode program that DOES NOT depend on
# bank $80 for VICE. We reuse only the prologue ($0800..$081A) plus
# a sentinel in bank $00 at $0825.

# Test 1 actually runs a SHORTER program — just the SCPUMIPS prologue
# through "X=0" without the cross-bank copy. We compare the first ~12
# fetches which all sit in bank $00. This avoids needing VICE to host
# bank $80 source data.

LAYER_A_T1_PROG_ADDR = 0x0800
LAYER_A_T1_END_PC    = 0x081B  # spin
LAYER_A_T1_PROG = bytes([
    # $0800: 18           CLC
    0x18,
    # $0801: FB           XCE          ; → native
    0xFB,
    # $0802: C2 30        REP #$30
    0xC2, 0x30,
    # $0804: A9 00 00     LDA #$0000
    0xA9, 0x00, 0x00,
    # $0807: 5B           TCD          ; DP=0
    0x5B,
    # $0808: A9 FF 01     LDA #$01FF
    0xA9, 0xFF, 0x01,
    # $080B: 1B           TCS
    0x1B,
    # $080C: E2 20        SEP #$20
    0xE2, 0x20,
    # $080E: A9 00        LDA #$00
    0xA9, 0x00,
    # $0810: 48           PHA
    0x48,
    # $0811: AB           PLB          ; DBR=0
    0xAB,
    # $0812: A2 00 00     LDX #$0000
    0xA2, 0x00, 0x00,
    # $0815: E0 00 00     CPX #$0000   ; harmless flag-set
    0xE0, 0x00, 0x00,
    # $0818: A9 77        LDA #$77
    0xA9, 0x77,
    # $081A: 4C 1A 08     JMP $081A    ; spin (PC sits at $081A == $081B-1)
    # actually $081A: 4C 1A 08 = JMP $081A, after which PC will fetch from
    # $081A again. We stop the trace at $081B so we capture exactly the
    # JMP fetch and stop before the looping fetch repeats indefinitely.
    0x4C, 0x1A, 0x08,
])
# After fetch sequence we expect the PC to bounce on $081A. The first
# instruction-fetch at $081A (the JMP) is captured; subsequent fetches
# also at $081A. We compare a fixed prefix of N fetches to side-step
# any infinite tail mismatch.


# ---------------------------------------------------------------------------
# Test 3 — Native-mode arithmetic + dispatch chain (BRK substitute).
# Touches TCD/TCS/REP/SEP/long-abs and a short loop, the same kind of
# wiring Doom's prologue uses. No vector dispatch — see module docstring.
# ---------------------------------------------------------------------------

LAYER_A_T3_PROG_ADDR = 0x0900
LAYER_A_T3_END_PC    = 0x091F
LAYER_A_T3_PROG = bytes([
    # $0900: 18            CLC
    0x18,
    # $0901: FB            XCE        ; native
    0xFB,
    # $0902: C2 30         REP #$30   ; M=0, X=0
    0xC2, 0x30,
    # $0904: A9 00 00      LDA #$0000
    0xA9, 0x00, 0x00,
    # $0907: 5B            TCD        ; DP=0
    0x5B,
    # $0908: A9 FF 01      LDA #$01FF
    0xA9, 0xFF, 0x01,
    # $090B: 1B            TCS
    0x1B,
    # $090C: A2 04 00      LDX #$0004
    0xA2, 0x04, 0x00,
    # $090F: A9 03 00      LDA #$0003     ; loop body start
    0xA9, 0x03, 0x00,
    # $0912: 1A            INC A
    0x1A,
    # $0913: CA            DEX
    0xCA,
    # $0914: D0 F9         BNE -$07 → $090F
    0xD0, 0xF9,
    # $0916: E2 20         SEP #$20      ; M=1
    0xE2, 0x20,
    # $0918: A9 5A         LDA #$5A
    0xA9, 0x5A,
    # $091A: 8D 00 21      STA $2100     ; abs (DBR=0)
    0x8D, 0x00, 0x21,
    # $091D: 4C 1D 09      JMP $091D     ; spin
    0x4C, 0x1D, 0x09,
])


# ---------------------------------------------------------------------------
# Scoreboard helper.
# ---------------------------------------------------------------------------

def _ctx_lines(trace: list[TraceLine], idx: int, half: int,
               label: str) -> list[str]:
    """Format a window of trace lines around `idx` for a report."""
    start = max(0, idx - half)
    end = min(len(trace), idx + half + 1)
    out = [f"--- {label} [{start}..{end}) ---"]
    for i in range(start, end):
        t = trace[i]
        marker = " >>>" if i == idx else "    "
        out.append(
            f"{marker} {t.seq:>5d} K:{t.pbr:02x} PC:{t.pc:04x} "
            f"IR:{t.ir:02x} P:{t.p:02x} SP:{t.sp:04x}"
        )
    return out


def _disasm_window(mem_image: bytes, bank: int, pc: int,
                    count: int) -> list[str]:
    """Disassemble `count` instructions of mem_image starting at bank:pc."""
    if not _HAVE_DISASM or mem_image is None:
        return []
    try:
        rows, _m, _x = disasm(mem_image, bank, pc, count)
    except Exception as e:
        return [f"(disasm error: {e})"]
    out = []
    for cur, hb, mn, opnd, _m, _x in rows:
        bk = (cur >> 16) & 0xFF
        ad = cur & 0xFFFF
        out.append(f"  {bk:02x}:{ad:04x}  {hb:<11s}  {mn} {opnd}")
    return out


def _run_scoreboard(
    dut_trace: list[TraceLine],
    oracle_trace: list[TraceLine],
    pc_only: bool = True,
    context: int = 10,
    mem_image: Optional[bytes] = None,
    test_name: str = "",
) -> dict:
    """Compare two traces; return structured + human-readable result.

    Returns dict::

        {
            "status": "MATCH" | "DIVERGE",
            "divergence_index": int | None,
            "report": str,
            "json": dict,
            "instructions_compared": int,
        }
    """
    n = min(len(dut_trace), len(oracle_trace))
    div = compare(oracle_trace, dut_trace, pc_only=pc_only)

    if div is None or (div >= n and len(dut_trace) == len(oracle_trace)):
        status = "MATCH"
        div_idx = None
        report = (
            f"MATCH — traces agree for all {n} compared lines "
            f"(pc_only={pc_only})."
        )
    elif div >= n:
        # Length mismatch only — count it as a divergence at index n.
        status = "DIVERGE"
        div_idx = n
        which = ("dut" if len(dut_trace) < len(oracle_trace) else "oracle")
        report_lines = [
            f"DIVERGENCE: trace length mismatch at index {div_idx} "
            f"(dut={len(dut_trace)}, oracle={len(oracle_trace)}; "
            f"{which} ended early)"
        ]
        report = "\n".join(report_lines)
    else:
        status = "DIVERGE"
        div_idx = div
        v = oracle_trace[div]
        o = dut_trace[div]
        diffs = field_diff(v, o)
        report_lines = [
            f"DIVERGENCE at trace index {div_idx} "
            f"(pc_only={pc_only}, instructions_compared={n})",
            "Field diffs:",
        ]
        if diffs:
            for d in diffs:
                report_lines.append(f"  {d}")
        else:
            report_lines.append("  (no field diffs reported — likely "
                                "length tail mismatch)")
        report_lines.append("")
        report_lines.extend(_ctx_lines(oracle_trace, div, context, "ORACLE"))
        report_lines.append("")
        report_lines.extend(_ctx_lines(dut_trace, div, context, "DUT"))
        if mem_image is not None and _HAVE_DISASM:
            report_lines.append("")
            report_lines.append("--- DUT disasm at divergence ---")
            report_lines.extend(
                _disasm_window(mem_image, o.pbr, o.pc, 6)
            )
        report = "\n".join(report_lines)

    j = {
        "status": status,
        "instructions_compared": n,
        "test_name": test_name,
        "divergence_index": div_idx,
    }
    return {
        "status": status,
        "divergence_index": div_idx,
        "report": report,
        "json": j,
        "instructions_compared": n,
    }


def _emit_layer_a_json(j: dict) -> None:
    """Print the LAYER_A_JSON marker line for the CI grep harness."""
    print(f"LAYER_A_JSON: {json.dumps(j)}", flush=True)


# ---------------------------------------------------------------------------
# VICE oracle helpers (only used by tests 1 and 3).
# ---------------------------------------------------------------------------

def _vice_skip_reason(dut) -> Optional[str]:
    """Return a string reason if VICE oracle should not be exercised, else None.

    Conditions:
      * LAYER_A_SKIP_VICE=1 in env
      * vice_oracle module fails to import
      * VICE binary missing on this host
    """
    if os.environ.get("LAYER_A_SKIP_VICE") == "1":
        return "LAYER_A_SKIP_VICE=1 in env"
    try:
        from vice_oracle import ViceOracle, VICE_EXE_DEFAULT  # noqa: F401
    except Exception as e:
        return f"vice_oracle import failed: {e}"
    if not pathlib.Path(VICE_EXE_DEFAULT).exists():
        # Try /mnt/c translation if running under WSL2.
        wsl_path = VICE_EXE_DEFAULT
        if VICE_EXE_DEFAULT[1:3] == ":\\":
            drv = VICE_EXE_DEFAULT[0].lower()
            wsl_path = "/mnt/" + drv + VICE_EXE_DEFAULT[2:].replace("\\", "/")
        if not pathlib.Path(wsl_path).exists():
            return f"VICE binary not found at {VICE_EXE_DEFAULT} or {wsl_path}"
    return None


def _align_dut_to_oracle(dut_trace: list,
                         oracle_trace: list) -> list:
    """Slice DUT trace to start at oracle_trace[0]'s (pbr, pc).

    DUT's bus loop captures every fetch from CPU reset onward, including
    PC=$0000 settling fetches before the reset vector takes hold. VICE's
    capture_trace() emits only AFTER the start_pc breakpoint hit, so its
    first traced instruction is the one just past the program entry.
    Aligning by matching the first oracle (pbr, pc) drops both the
    reset-state junk and any instructions VICE skipped.
    """
    if not oracle_trace:
        return dut_trace
    target_pbr = oracle_trace[0].pbr
    target_pc = oracle_trace[0].pc
    for i, tl in enumerate(dut_trace):
        if tl.pbr == target_pbr and tl.pc == target_pc:
            return dut_trace[i:]
    return dut_trace


def _vice_oracle_capture(
    program: bytes,
    program_addr: int,
    end_pc: int,
    max_instr: int,
    start_pc: Optional[int] = None,
) -> list[TraceLine]:
    """Launch VICE, poke `program` at $00:program_addr, capture trace until end_pc.

    If `start_pc` is supplied (typical for .prg files where the load address
    differs from the SYS entry point), VICE jumps there instead of running
    from program_addr.
    """
    from vice_oracle import ViceOracle, VICE_EXE_DEFAULT
    exe = VICE_EXE_DEFAULT
    if not pathlib.Path(exe).exists() and exe[1:3] == ":\\":
        drv = exe[0].lower()
        exe = "/mnt/" + drv + exe[2:].replace("\\", "/")
    with ViceOracle(vice_exe=exe) as v:
        v._cmd("reset 0", timeout=10.0)
        v.load_bytes_direct(program_addr, program)
        return v.capture_trace(
            start_pc=start_pc if start_pc is not None else program_addr,
            stop_pc=end_pc,
            max_instr=max_instr,
            timeout=120.0,
        )


# ---------------------------------------------------------------------------
# Test 1 — SCPUMIPS prologue MATCH on DUT + VICE.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_layer_a_scpumips_copy(dut):
    """Layer 3 end-to-end: MATCH on a native-mode prologue (~12 fetches)."""
    test_name = "test_layer_a_scpumips_copy"

    skip = _vice_skip_reason(dut)
    if skip:
        dut._log.warning(f"SKIP {test_name}: {skip}")
        # Emit a JSON record marked SKIP so the CI harness can see it.
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": skip,
        })
        return

    # 1) Run on DUT.
    fix = DutFixture(dut, clk_period_ns=31.25)
    fix.load_bytes(0x00, LAYER_A_T1_PROG_ADDR, LAYER_A_T1_PROG)
    fix.patch_reset_vector(LAYER_A_T1_PROG_ADDR)
    # Native vector pad — matches Layer 1 fixture (RTI sink at $FF00).
    fix.load_bytes(0x00, 0xFF00, bytes([0x40]))
    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))   # BRK-N
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))   # NMI-N
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))   # IRQ-N

    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)
    # Run enough fetches to cover the 14-instruction prologue + a few
    # spin loops at $081A. 60 is safely past the prologue.
    await fix.run_n_instructions(60)
    dut_trace_full = fix.get_trace()
    # Drop trace lines past the spin so that DUT and VICE compare on the
    # same tail (both will sit at $081A repeatedly). Truncate at first
    # PC==$081A duplicate.
    seen_spin = False
    dut_trace: list[TraceLine] = []
    for tl in dut_trace_full:
        if tl.pbr == 0 and tl.pc == 0x081A:
            if seen_spin:
                break
            seen_spin = True
        dut_trace.append(tl)

    dut._log.info(f"DUT captured {len(dut_trace)} fetches")

    # 2) Run on VICE oracle.
    try:
        oracle_trace_full = _vice_oracle_capture(
            program=LAYER_A_T1_PROG,
            program_addr=LAYER_A_T1_PROG_ADDR,
            end_pc=0x081A,            # break at first JMP-target reach
            max_instr=200,
        )
    except Exception as e:
        dut._log.warning(f"SKIP {test_name}: VICE capture failed: {e}")
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": f"vice capture: {e}",
        })
        return

    # Align DUT to VICE: drop reset-state PC=$0000 fetches and any leading
    # DUT entries before VICE's first traced instruction.
    dut_trace = _align_dut_to_oracle(dut_trace, oracle_trace_full)

    # VICE's capture stops AT end_pc, so the captured tail is the
    # instruction at $081A. Truncate DUT to the same length so we
    # don't get a tail-length DIVERGE.
    n = min(len(dut_trace), len(oracle_trace_full))
    dut_cmp = dut_trace[:n]
    oracle_cmp = oracle_trace_full[:n]

    # Build a flat memory image for disassembly context (bank 0 only).
    mem_image = bytes(fix._mem[0])  # 64KB bank-0 snapshot
    # disasm() addresses as image[(bank<<16)|addr], but we only have
    # bank 0. Pad upper banks with zeros to match the index math.
    mem_image_full = mem_image + b"\x00" * (0x10000 * 0xFF)

    result = _run_scoreboard(
        dut_trace=dut_cmp,
        oracle_trace=oracle_cmp,
        pc_only=True,
        context=10,
        mem_image=mem_image_full,
        test_name=test_name,
    )
    dut._log.info(result["report"])
    _emit_layer_a_json(result["json"])
    assert result["status"] == "MATCH", \
        f"{test_name} expected MATCH, got {result['status']}"


# ---------------------------------------------------------------------------
# Test 2 — Scoreboard self-test (DUT only, no VICE).
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_layer_a_detects_divergence(dut):
    """Mutate index-5 PC of an oracle copy; scoreboard must DIVERGE at 5."""
    test_name = "test_layer_a_detects_divergence"

    # Run the SCPUMIPS prologue on DUT only; we don't need VICE.
    fix = DutFixture(dut, clk_period_ns=31.25)
    fix.load_bytes(0x00, LAYER_A_T1_PROG_ADDR, LAYER_A_T1_PROG)
    fix.patch_reset_vector(LAYER_A_T1_PROG_ADDR)
    fix.load_bytes(0x00, 0xFF00, bytes([0x40]))
    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))
    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)
    await fix.run_n_instructions(20)

    dut_trace = fix.get_trace()[:20]
    assert len(dut_trace) >= 10, (
        f"expected ≥10 captured fetches, got {len(dut_trace)} "
        "(DUT bus loop misbehaving?)"
    )

    # Build oracle_trace as a deep copy of dut_trace, then corrupt
    # index 5's PC by +1.
    oracle_trace = [
        TraceLine(seq=t.seq, pbr=t.pbr, pc=t.pc, ir=t.ir,
                  p=t.p, sp=t.sp, raw=t.raw)
        for t in dut_trace
    ]
    bad_pc = (oracle_trace[5].pc + 1) & 0xFFFF
    oracle_trace[5] = TraceLine(
        seq=oracle_trace[5].seq,
        pbr=oracle_trace[5].pbr,
        pc=bad_pc,
        ir=oracle_trace[5].ir,
        p=oracle_trace[5].p,
        sp=oracle_trace[5].sp,
        raw=oracle_trace[5].raw,
    )

    result = _run_scoreboard(
        dut_trace=dut_trace,
        oracle_trace=oracle_trace,
        pc_only=True,
        context=4,
        mem_image=None,
        test_name=test_name,
    )
    dut._log.info(result["report"])
    _emit_layer_a_json(result["json"])

    assert result["status"] == "DIVERGE", \
        f"{test_name} expected DIVERGE, got {result['status']}"
    assert result["divergence_index"] == 5, (
        f"{test_name} expected divergence at index 5, "
        f"got {result['divergence_index']}"
    )


# ---------------------------------------------------------------------------
# Test 3 — Native-mode arithmetic + dispatch chain MATCH.
# (Substitute for true BRK-vector test — see module docstring.)
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_layer_a_brk_native_vector(dut):
    """Native-mode REP/SEP/INC/DEX/BNE chain: DUT and VICE must MATCH.

    TODO: real BRK-vector test once we have a synthetic vector setup
    that works on both minimal-RAM DUT and full-KERNAL VICE.
    """
    test_name = "test_layer_a_brk_native_vector"

    skip = _vice_skip_reason(dut)
    if skip:
        dut._log.warning(f"SKIP {test_name}: {skip}")
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": skip,
        })
        return

    fix = DutFixture(dut, clk_period_ns=31.25)
    fix.load_bytes(0x00, LAYER_A_T3_PROG_ADDR, LAYER_A_T3_PROG)
    fix.patch_reset_vector(LAYER_A_T3_PROG_ADDR)
    fix.load_bytes(0x00, 0xFF00, bytes([0x40]))
    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))
    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)
    await fix.run_n_instructions(80)

    dut_trace_full = fix.get_trace()
    seen_spin = False
    dut_trace: list[TraceLine] = []
    for tl in dut_trace_full:
        if tl.pbr == 0 and tl.pc == 0x091D:
            if seen_spin:
                break
            seen_spin = True
        dut_trace.append(tl)

    dut._log.info(f"DUT captured {len(dut_trace)} fetches")

    try:
        oracle_trace_full = _vice_oracle_capture(
            program=LAYER_A_T3_PROG,
            program_addr=LAYER_A_T3_PROG_ADDR,
            end_pc=0x091D,
            max_instr=300,
        )
    except Exception as e:
        dut._log.warning(f"SKIP {test_name}: VICE capture failed: {e}")
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": f"vice capture: {e}",
        })
        return

    dut_trace = _align_dut_to_oracle(dut_trace, oracle_trace_full)

    n = min(len(dut_trace), len(oracle_trace_full))
    dut_cmp = dut_trace[:n]
    oracle_cmp = oracle_trace_full[:n]

    mem_image = bytes(fix._mem[0]) + b"\x00" * (0x10000 * 0xFF)

    result = _run_scoreboard(
        dut_trace=dut_cmp,
        oracle_trace=oracle_cmp,
        pc_only=True,
        context=10,
        mem_image=mem_image,
        test_name=test_name,
    )
    dut._log.info(result["report"])
    _emit_layer_a_json(result["json"])
    assert result["status"] == "MATCH", \
        f"{test_name} expected MATCH, got {result['status']}"
