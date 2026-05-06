"""Doom-class differential test: run loader.prg on DUT and VICE, compare PC streams.

This is the first real workload pointed at the Layer 3 verification
environment after Layers 1+2+3 went green on synthetic programs. Goal: see
where (if anywhere) the cocotb DUT and VICE xscpu64 disagree on Doom's
launcher.

Scope of this test
------------------
loader.prg loads at $0801. Entry point is $080D (after the BASIC `SYS 2061`
stub). The hot path is:

  $080D  JSR $08DB        ; clear text screen + color RAM (~1280 instr loop)
  $0810  LDX #$00
  $0812  LDA $0820,X      ; copy 187 bytes $0820..$08DA → $0700..$07BA
  $0815  STA $0700,X
  $0818  INX
  $0819  CPX #$BB
  $081B  BNE $0812
  $081D  JMP $0700        ; transfer to relocated code (REU/SCPU territory)

We stop at $0700 — the JMP target — because everything before that is pure
6502/65C816 logic with no I/O dependency that DUT can't reproduce. After
$0700 the relocated code does $DFxx REU register writes, which DUT (no REU
model) and VICE (full REU emulation when -reu is passed) will diverge on
legitimately. So $0700 is the clean boundary for "did the CPU's instruction
stream agree end-to-end on the prologue".

This is exploratory: it does NOT assert MATCH. It emits the LAYER_A_JSON
marker so CI can extract the result, and logs a divergence report if any.
A divergence here would be the first concrete localization of the Doom -9
microcode bug to a specific instruction in the loader.
"""

from __future__ import annotations

import os
import json
import pathlib
import sys
from typing import Optional

import cocotb

# Repo root for finding loader.prg and adding tools/ to sys.path so the
# shared diff helpers can find vice_oracle / vice_diff.
REPO = pathlib.Path(__file__).resolve().parents[3]
TOOLS_DIR = REPO / "tools"
VICE_DIFF_DIR = TOOLS_DIR / "vice_diff"
for p in (str(TOOLS_DIR), str(VICE_DIFF_DIR)):
    if p not in sys.path:
        sys.path.insert(0, p)

# Package-relative imports — cocotb loads this file as
# `tests.test_doom_loader_diff`, so `.dut_fixture` and
# `.test_diff_layer_a` resolve correctly.
from .dut_fixture import DutFixture  # type: ignore  # noqa: E402
from .test_diff_layer_a import (  # type: ignore  # noqa: E402
    _vice_skip_reason,
    _vice_oracle_capture,
    _align_dut_to_oracle,
    _run_scoreboard,
    _emit_layer_a_json,
)


# ---------------------------------------------------------------------------
# loader.prg — read once at module import.
# ---------------------------------------------------------------------------

LOADER_PATH = REPO / "loader.prg"
_data = LOADER_PATH.read_bytes()
LOADER_ADDR = _data[0] | (_data[1] << 8)         # $0801
LOADER_BYTES = _data[2:]                          # 252 bytes of code
LOADER_ENTRY = 0x080D                             # SYS 2061 target
LOADER_END_PC = 0x0700                            # JMP target after copy loop


@cocotb.test()
async def test_doom_loader_prologue(dut):
    """Run loader.prg from SYS entry through JMP $0700 on DUT and VICE."""
    test_name = "test_doom_loader_prologue"

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

    # 1) DUT: plant loader at $0801, jump to $080D via reset vector.
    fix = DutFixture(dut, clk_period_ns=31.25)
    fix.load_bytes(0x00, LOADER_ADDR, LOADER_BYTES)
    fix.patch_reset_vector(LOADER_ENTRY)
    fix.load_bytes(0x00, 0xFF00, bytes([0x40]))
    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))

    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)
    # Need ~2100 instructions for the full prologue (1280 screen-clear + 750
    # copy + JMP). 5000 is safe headroom; we'll truncate to N matched.
    await fix.run_n_instructions(2500)

    dut_trace_full = fix.get_trace()
    # Truncate at the FIRST occurrence of $0700 (post-JMP arrival), inclusive.
    dut_trace = []
    for tl in dut_trace_full:
        dut_trace.append(tl)
        if tl.pbr == 0 and tl.pc == LOADER_END_PC:
            break
    dut._log.info(f"DUT captured {len(dut_trace)} fetches (last={tl.pc:04x})")

    # 2) VICE: same bytes, start at $080D, stop at $0700.
    try:
        oracle_trace = _vice_oracle_capture(
            program=LOADER_BYTES,
            program_addr=LOADER_ADDR,
            start_pc=LOADER_ENTRY,
            end_pc=LOADER_END_PC,
            max_instr=5000,
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

    dut._log.info(f"VICE captured {len(oracle_trace)} fetches")

    # 3) Align DUT to VICE first-PC (drops reset-state junk + VICE's
    #    skipped-first-instruction artifact) and diff.
    dut_trace = _align_dut_to_oracle(dut_trace, oracle_trace)
    n = min(len(dut_trace), len(oracle_trace))

    mem_image = bytes(fix._mem[0]) + b"\x00" * (0x10000 * 0xFF)

    result = _run_scoreboard(
        dut_trace=dut_trace[:n],
        oracle_trace=oracle_trace[:n],
        pc_only=True,
        context=10,
        mem_image=mem_image,
        test_name=test_name,
    )
    dut._log.info(result["report"])
    _emit_layer_a_json(result["json"])

    # NOTE: not asserting MATCH — this is the first Doom-workload probe.
    # If MATCH: prologue is sound, next test target is the relocated $0700
    # code (needs an REU model on the DUT side or a restricted VICE setup).
    # If DIVERGE: divergence_index points at the first instruction where
    # DUT and VICE disagree — that's our microcode bug locus.
