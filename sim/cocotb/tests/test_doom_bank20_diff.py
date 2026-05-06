"""Doom game-code diff: run bank $20 entry on DUT and VICE, compare PC streams.

After the loader prologue MATCHED for 2499 instructions
(test_doom_loader_diff.py), this test pushes the comparison into Doom's
*game code* — bank $20 of doom.reu, which the loader copies into SuperRAM
bank $20 via REU FETCH + long-store. The bootstrap matches the real Doom
launcher (`SEI; CLC; XCE; JML $20:$0000`) but skips the REU phase entirely
by pre-populating bank $20 with the raw doom.reu image bytes.

Bank $20 entry (`$20:$0000`) is Doom's native-mode setup:
    SEI; CLD; CLC; XCE; REP #$30
    LDA #$0000; TCD; LDA #$01FF; TCS
    STZ $80; STZ $82; SEP #$20
    LDA #$00; PHA; PLB
    STA $DC0E; STA $DC0F; STA $DC0E; STA $DC0F
    STA $D015; STA $D01A
    LDA #$7F; STA $DC0D; STA $DD0D
    LDA $DC0D; LDA $DD0D
    LDA #$FF; STA $D019
    LDA #$35; STA $01
    ...

Pure deterministic instruction stream — STAs/LDAs to I/O have well-defined
PC semantics regardless of what the I/O returns. Any PC divergence between
DUT and VICE here is a real P65C816 microcode bug.

Memory layout
-------------
DUT:   bank $00 has bootstrap at $0800 + reset vector → $0800
       bank $20 has first 512 bytes of doom.reu image starting at $0000
VICE:  same, plus full xscpu64 KERNAL/BASIC/CIA/VIC/REU emulation behind
       it. We just plant bytes at the same locations.

Stop point: $20:$0030 — well past the I/O register writes but before any
branches that might depend on REU/I/O state. Bumped per result.
"""

from __future__ import annotations

import os
import pathlib
import socket
import sys
import time
from typing import Optional

import cocotb

# Repo root + sys.path setup for tools/ imports.
REPO = pathlib.Path(__file__).resolve().parents[3]
TOOLS_DIR = REPO / "tools"
VICE_DIFF_DIR = TOOLS_DIR / "vice_diff"
for p in (str(TOOLS_DIR), str(VICE_DIFF_DIR)):
    if p not in sys.path:
        sys.path.insert(0, p)

from .dut_fixture import DutFixture  # type: ignore  # noqa: E402
from .test_diff_layer_a import (  # type: ignore  # noqa: E402
    _vice_skip_reason,
    _align_dut_to_oracle,
    _run_scoreboard,
    _emit_layer_a_json,
)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DOOM_REU_PATH = REPO / "doom.reu"
BANK20_LEN    = 0x1000              # 4 KB — covers $20:$0000..$0FFF
BOOT_ADDR     = 0x0800
BANK20_ENTRY  = 0x20_0000           # 24-bit: PB=$20, PC=$0000
# Optional bank $00 snapshot (post-loader motherboard RAM image captured
# from VICE running loader.prg + REU). If present, both DUT and VICE
# preload it before bootstrap, lifting the JML $00:$0E0C ceiling.
# Capture via: tools/vice_dump_postloader_bank00.py
BANK00_SNAPSHOT_PATH = REPO / "tools" / "vice_oracle" / "postloader_bank00.bin"

# When the bank $00 snapshot is loaded, the diff can push past the
# previous architectural ceiling at $2C:$A792 → $00:$0E0C. Stop after a
# handful of instructions inside the JML target to confirm the diff
# survives the cross-bank entry into populated motherboard RAM.
# Without the snapshot, fall back to the old ceiling at $2C:$A792.
if BANK00_SNAPSHOT_PATH.exists():
    STOP_PC   = 0x0E18              # 4 instructions past $0E0C
    STOP_PBR  = 0x00
else:
    STOP_PC   = 0xA792               # architectural ceiling without snapshot
    STOP_PBR  = 0x2C

# Bootstrap in bank $00: SEI; CLC; XCE; JML $20:$0000
BOOTSTRAP = bytes([
    0x78,                           # SEI
    0x18,                           # CLC
    0xFB,                           # XCE   (E=0 → native)
    0x5C, 0x00, 0x00, 0x20,         # JML $20:0000
])


# ---------------------------------------------------------------------------
# Loop short-circuit patches.
#
# Doom's bank $20 prologue contains long init loops (e.g. an X-counted
# 65536-iteration table-clear at $20:$00AD..$00F8). Stepwise diff cannot
# afford to traverse those — at ~0.21 s per VICE step, a 2M-instruction
# clear loop would take days. The fix: patch the looping branch on BOTH
# DUT and VICE so the loop falls through after one iteration. Both sides
# see the SAME patched code, so any divergence after the patch is real
# CPU-microcode disagreement, not a side effect of the patch.
#
# Trade-off: skipping the loop means downstream code reads uninitialized
# memory. With both DUT and VICE seeing zeros there (banks $80+), this is
# consistent — the diff stays semantically meaningful even if Doom would
# never take this path with real REU-loaded data.
#
# Each patch is (bank, addr, replacement_bytes, description).
# ---------------------------------------------------------------------------

LOOP_PATCHES: list[tuple[int, int, bytes, str]] = [
    # All four iteration-back loops `tools/bank20_loop_scan.py` finds in the
    # first 4 KB of bank $20. Patch each `BNE $rel`/`BEQ $rel` (opcode + neg
    # offset, 2 bytes) to `BRA $+2` (`80 00`) so the loop runs exactly once.
    #
    # Found via: `python3 tools/bank20_loop_scan.py` — heuristic locates
    # INX/DEX/INY/DEY immediately before BNE/BEQ with negative offset.
    # If new patches are needed (e.g. extending past $0FFF), re-run that
    # scanner and append entries below.
    (0x20, 0x00F6, bytes([0x80, 0x00]),
     "BNE $00AD -> BRA $+2  (clear loop, body=73, INX-driven, 65536 iters)"),
    (0x20, 0x011F, bytes([0x80, 0x00]),
     "BNE $00F8 -> BRA $+2  (clear loop, body=39, INX-driven)"),
    (0x20, 0x096A, bytes([0x80, 0x00]),
     "BNE $095A -> BRA $+2  (loop body=16, DEX-driven)"),
    (0x20, 0x099C, bytes([0x80, 0x00]),
     "BNE $097E -> BRA $+2  (loop body=30, DEX-driven)"),
    # The JML-back loop at $0384..$03B2 increments a 32-bit counter at $88..$8B
    # toward a limit at $90..$93 and exits via `BEQ $03B6` at $03B0 when X=0.
    # Without this patch the loop iterates many times — diff burns 10000 steps
    # cycling through 15 unique instructions. Force-exit via BEQ→BRA so both
    # sides traverse the loop body once, then continue into $03B6..$03E6.
    (0x20, 0x03B0, bytes([0x80, 0x04]),
     "BEQ $03B6 -> BRA $03B6  (JML-back iteration loop $0384..$03B2 short-circuit)"),
    # Bank $80 holds 3 sequential BRA-back copy loops invoked by the JML at
    # $20:$03E6. Each loop iterates ~7 instructions × {1976, 3334, 4} times
    # (~37000 instructions total) — too slow for stepwise. Patch each
    # `BRA -16` (op `80 F0`) to `BRA $+0` (op `80 00`) so each runs once,
    # then control falls through to JMP [$00:$00FC] at $80:$0099 → $20:$03EA.
    # Side effect: bank $00 destination ranges $0800.., $1000.., $0010.. are
    # NOT populated with copied data. We stop at $03EA before any code reads
    # them, so this is OK for the harness but not for end-to-end Doom.
    (0x80, 0x006F, bytes([0x80, 0x00]),
     "BRA $0061 -> BRA $+0  (bank-80 copy loop 1 @ $80:$006F-$0070, 1976 iters)"),
    (0x80, 0x0082, bytes([0x80, 0x00]),
     "BRA $0074 -> BRA $+0  (bank-80 copy loop 2 @ $80:$0082-$0083, 3334 iters)"),
    (0x80, 0x0095, bytes([0x80, 0x00]),
     "BRA $0087 -> BRA $+0  (bank-80 copy loop 3 @ $80:$0095-$0096, 4 iters)"),
]


def _apply_dut_patches(fix) -> None:
    for bank, addr, repl, desc in LOOP_PATCHES:
        fix.load_bytes(bank, addr, repl)


def _apply_vice_patches(v) -> None:
    for bank, addr, repl, desc in LOOP_PATCHES:
        addr24 = (bank << 16) | addr
        v.load_bytes_direct(addr24, repl)


def _extract_bank20() -> bytes:
    """Read first BANK20_LEN bytes of bank $20 from doom.reu."""
    with DOOM_REU_PATH.open("rb") as f:
        f.seek(0x20 * 0x10000)
        return f.read(BANK20_LEN)


# Extra banks to populate identically on DUT and VICE so cross-bank JMLs in
# bank $20 (e.g. JML $80:$005C at $20:$03E6) execute consistent code on both
# sides. Each entry is (bank, length). A length > 0x10000 is clamped to 64K.
# Empty list = pure-CPU regime (banks $80+ are $EA on DUT, whatever VICE has
# elsewhere; cross-bank JMLs will diverge because of byte mismatches).
EXTRA_BANKS: list[tuple[int, int]] = [
    # Bank $80 — first 16 KB covers code at $005C..$0099 plus the data
    # source ranges $05D9..$1A9B used by the copy loops at $80:$0061..$0096.
    (0x80, 0x4000),
    # Bank $2D — load enough to cover the JML target at $06A0 plus a few
    # instructions of code before the next cross-bank JML at $2D:$06C4
    # (which targets $2C:$A719). 8 KB is overkill for the stopping point
    # but lets the harness see context and decide where to halt next.
    (0x2D, 0x2000),
    # Bank $2C — full 64 KB. The JML target $A719 is 43 KB into the bank,
    # and bank $2C also holds many more code paths Doom reaches later.
    # Poke time ~51 s; acceptable next to the ~8 min stepwise capture.
    (0x2C, 0x10000),
    # Bank $87 — data bank, mostly zero in doom.reu. Bank $2C code at
    # $A733-$A75A reads/writes $87:$E954-$E957 (state flags). With zero
    # content on both sides the BEQ at $A743 is taken identically so the
    # diff stays consistent. 64KB load to be safe — pokes ~51 s of zeros.
    (0x87, 0x10000),
]


def _extract_bank(bank: int, length: int) -> bytes:
    """Read first `length` bytes of arbitrary bank from doom.reu."""
    length = min(length, 0x10000)
    with DOOM_REU_PATH.open("rb") as f:
        f.seek(bank * 0x10000)
        return f.read(length)


def _vice_oracle_capture_doom(bank20_bytes: bytes,
                                extra_banks: list[tuple[int, bytes]],
                                bank00_snapshot: Optional[bytes] = None):
    """Launch VICE, plant bootstrap + bank $20 + extras, capture trace."""
    from vice_oracle import ViceOracle, VICE_EXE_DEFAULT
    exe = VICE_EXE_DEFAULT
    if not pathlib.Path(exe).exists() and exe[1:3] == ":\\":
        drv = exe[0].lower()
        exe = "/mnt/" + drv + exe[2:].replace("\\", "/")
    with ViceOracle(vice_exe=exe) as v:
        v._cmd("reset 0", timeout=10.0)
        # 0) optional bank $00 post-loader snapshot. Split around the
        #    bootstrap region AND the IO area at $D000-$DFFF AND the
        #    6510 port registers $0000-$0001. CRITICAL: VICE's `>`
        #    command writes through the CPU bus, so pokes to $D000-$DFFF
        #    fire device-register writes (CIA/VIC/SID, AND the SuperCPU
        #    registers at $D070-$D07F). Snapshot data at $D078/$D07E
        #    silently enabled SuperCPU mode mid-load, switching the CPU
        #    to read from empty SRAM at $00:$0801 (= BRK), even though
        #    motherboard RAM correctly held the bootstrap byte $18.
        #    Confirmed via tools/vice_diagnostic_full_seq.py — `m`
        #    consistently showed $0800..$0806 = 78 18 fb 5c 00 00 20
        #    while the CPU still executed $00 (BRK) at $0801.
        if bank00_snapshot is not None:
            boot_start = BOOT_ADDR
            boot_end = BOOT_ADDR + len(BOOTSTRAP)
            # Three skips: zp port pair, bootstrap region, IO range.
            v.load_bytes_direct(0x0002, bank00_snapshot[0x0002:boot_start])
            v.load_bytes_direct(boot_end, bank00_snapshot[boot_end:0xD000])
            v.load_bytes_direct(0xE000, bank00_snapshot[0xE000:])
        # 1) bootstrap in bank 0 + reset vector — guaranteed last write
        #    to $0800-$0806, so VICE executes our SEI/CLC/XCE/JML, not
        #    snapshot bytes.
        v.load_bytes_direct(BOOT_ADDR, BOOTSTRAP)

        # 1b) sanity-check the bootstrap landed (defense vs VICE silently
        #     dropping a poke chunk; saw this once in a 64KB snapshot run).
        for retry in range(3):
            check = v.mem(BOOT_ADDR, len(BOOTSTRAP))
            if check == BOOTSTRAP:
                break
            v.load_bytes_direct(BOOT_ADDR, BOOTSTRAP)
        else:
            raise RuntimeError(
                f"VICE bootstrap failed to land at ${BOOT_ADDR:04x}: "
                f"expected {BOOTSTRAP.hex()} got {check.hex()}"
            )
        # 2) bank $20 prologue
        v.load_bytes_direct(BANK20_ENTRY, bank20_bytes)
        # 3) extra banks (data-faithful regime)
        for bank, data in extra_banks:
            v.load_bytes_direct((bank << 16), data)
        # 4) loop short-circuit patches (must match DUT exactly)
        _apply_vice_patches(v)
        # 5) capture: start at bootstrap, stop at STOP_PC
        return v.capture_trace_stepwise(
            start_pc=BOOT_ADDR,
            stop_pc=STOP_PC,
            stop_pbr=STOP_PBR,
            max_instr=12000,
        )


@cocotb.test()
async def test_doom_bank20_prologue(dut):
    """Run Doom bank $20 entry on DUT and VICE; compare PC streams."""
    test_name = "test_doom_bank20_prologue"

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

    if not DOOM_REU_PATH.exists():
        dut._log.warning(f"SKIP {test_name}: doom.reu not found at {DOOM_REU_PATH}")
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": f"doom.reu missing at {DOOM_REU_PATH}",
        })
        return

    bank20_bytes = _extract_bank20()
    dut._log.info(f"Loaded {len(bank20_bytes)} bytes of doom.reu bank $20")

    extra_banks_data: list[tuple[int, bytes]] = []
    for bank, length in EXTRA_BANKS:
        data = _extract_bank(bank, length)
        extra_banks_data.append((bank, data))
        dut._log.info(f"Loaded {len(data)} bytes of doom.reu bank ${bank:02x}")

    bank00_snapshot: Optional[bytes] = None
    if BANK00_SNAPSHOT_PATH.exists():
        bank00_snapshot = BANK00_SNAPSHOT_PATH.read_bytes()
        dut._log.info(f"Loaded {len(bank00_snapshot)}-byte bank $00 "
                      f"snapshot from {BANK00_SNAPSHOT_PATH.name}")

    # 1) DUT
    fix = DutFixture(dut, clk_period_ns=31.25)
    if bank00_snapshot is not None:
        fix.load_bytes(0x00, 0x0000, bank00_snapshot)
    fix.load_bytes(0x00, BOOT_ADDR, BOOTSTRAP)
    fix.load_bytes(0x20, 0x0000, bank20_bytes)
    for bank, data in extra_banks_data:
        fix.load_bytes(bank, 0x0000, data)
    fix.patch_reset_vector(BOOT_ADDR)
    # Native-mode vector pad — RTI sink at $FF00.
    fix.load_bytes(0x00, 0xFF00, bytes([0x40]))
    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))
    # Apply loop short-circuit patches (must match VICE side).
    _apply_dut_patches(fix)
    for _b, _a, _r, _desc in LOOP_PATCHES:
        dut._log.info(f"PATCH ${_b:02x}:${_a:04x} {_r.hex()} — {_desc}")

    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)
    # Allow up to ~14000 instructions to reach STOP_PC. Headroom for
    # the new bank $00 entry path past the JML at $2C:$A792 → $00:$0E0C.
    await fix.run_n_instructions(14000)

    dut_trace_full = fix.get_trace()
    # Truncate at first arrival at PB=$20 PC=$0030 (the stop).
    dut_trace = []
    for tl in dut_trace_full:
        dut_trace.append(tl)
        if tl.pbr == STOP_PBR and tl.pc == STOP_PC:
            break
    last_dut = dut_trace[-1] if dut_trace else None
    if last_dut is not None:
        dut._log.info(
            f"DUT captured {len(dut_trace)} fetches; last="
            f"${last_dut.pbr:02x}:${last_dut.pc:04x}"
        )
    else:
        dut._log.info(f"DUT captured {len(dut_trace)} fetches")

    # 2) VICE
    try:
        oracle_trace = _vice_oracle_capture_doom(
            bank20_bytes, extra_banks_data, bank00_snapshot=bank00_snapshot)
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

    last_vice = oracle_trace[-1] if oracle_trace else None
    if last_vice is not None:
        dut._log.info(
            f"VICE captured {len(oracle_trace)} fetches; last="
            f"${last_vice.pbr:02x}:${last_vice.pc:04x}"
        )
    else:
        dut._log.info(f"VICE captured {len(oracle_trace)} fetches")

    # 3) Align + diff
    dut_trace = _align_dut_to_oracle(dut_trace, oracle_trace)
    n = min(len(dut_trace), len(oracle_trace))

    # Mem image: bank $00 + bank $20, padded for 24-bit addressing.
    mem_image = bytes(fix._mem[0])
    for b in range(1, 0x100):
        mem_image += bytes(fix._mem[b]) if b == 0x20 else b"\x00" * 0x10000

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

    # Exploratory — do not fail the test on DIVERGE. The divergence_index
    # in the JSON marker is the actionable result.
