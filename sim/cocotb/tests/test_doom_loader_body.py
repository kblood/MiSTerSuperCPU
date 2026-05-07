"""Probe A — diff Doom loader BODY past $0700 (REU FETCH + long-store).

The relocated loader at $0700 does a tight loop:
  * REU FETCH 256 bytes from doom.reu to bank $00:$0400 (header chunk)
  * if first byte zero → skip (chunk unused)
  * REU FETCH 256 bytes to bank $00:$0500 (payload)
  * STA [$FB],Y inner loop copies bank $00:$0500 → SuperRAM bank $XX:$YYxx
  * INC writeback addr, loop ~256 chunks, then JML [$04FC] to game entry

To diff this on DUT + VICE we need:
  * VICE: launched with `-reu -reuimage doom.reu` so $DFxx writes drive
    a real REU FETCH against the same image.
  * DUT: DutFixture.attach_reu(doom.reu) installs a minimal REU model
    intercepting bank $00 offsets $DF00..$DF0A.

A DIVERGE here would localize the Doom -9 microcode bug to a specific
opcode in REU/long-store territory. A MATCH for several thousand
instructions narrows the suspect to either HW-only timing or a region
of the loader the test didn't reach.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb

REPO = pathlib.Path(__file__).resolve().parents[3]
TOOLS_DIR = REPO / "tools"
VICE_DIFF_DIR = TOOLS_DIR / "vice_diff"
for p in (str(TOOLS_DIR), str(VICE_DIFF_DIR)):
    if p not in sys.path:
        sys.path.insert(0, p)

from .dut_fixture import DutFixture  # type: ignore  # noqa: E402
from .test_diff_layer_a import (  # type: ignore  # noqa: E402
    _vice_skip_reason,
    _run_scoreboard,
    _emit_layer_a_json,
)

LOADER_PATH = REPO / "loader.prg"
_data = LOADER_PATH.read_bytes()
LOADER_ADDR = _data[0] | (_data[1] << 8)
LOADER_BYTES = _data[2:]
LOADER_ENTRY = 0x080D
LOADER_BODY_PC = 0x0700
# We diff starting one byte AFTER SEI: $0701. xscpu64's `r p=I` mask
# is a no-op (per gameplay-test memory note), so if VICE breaks at
# $0700 with I=0 and an IRQ pending, the very first `z` step services
# the IRQ instead of executing SEI — diverging from DUT immediately.
# Setting BP at $0701 forces VICE to execute SEI in the unmonitored
# prologue, leaving I=1 before stepwise capture begins.
BODY_DIFF_PC = 0x0701

DOOM_REU_PATH = REPO / "doom.reu"
# Default 500 body instr — at ~0.25 s per stepwise step that's ~2 min
# round-trip on VICE. Bump via env once a baseline run lands.
LOADER_BODY_INSTR = int(os.environ.get("LOADER_BODY_INSTR", "500"))


def _wsl_to_windows_path(p: pathlib.Path) -> str:
    """Convert /mnt/c/... paths to C:/... so a Windows-native VICE.exe
    can resolve the file. No-op if already Windows-style.
    """
    s = str(p)
    if s.startswith("/mnt/") and len(s) > 6 and s[6] == "/":
        return s[5].upper() + ":" + s[6:].replace("/", "/")
    return s


def _vice_oracle_capture_with_reu_stepwise(
    program: bytes,
    program_addr: int,
    prologue_entry_pc: int,
    body_break_pc: int,
    body_max_instr: int,
    reu_image_path: str,
):
    """Launch VICE -reu, plant CIA stops + RTI trampolines, then `g`
    from prologue_entry_pc and break at body_break_pc, then stepwise.

    Prologue must run on VICE to populate the relocated body code at
    $0700; `g $0701` would force PC to $0701 with $0700 page still
    uninitialized. Pattern matches test_doom_gameplay_diff's bootstrap-
    then-BP approach.
    """
    import socket
    import time as _time
    from vice_oracle import ViceOracle, VICE_EXE_DEFAULT, PROMPT
    exe = VICE_EXE_DEFAULT
    if not pathlib.Path(exe).exists() and len(exe) > 2 and exe[1:3] == ":\\":
        drv = exe[0].lower()
        exe = "/mnt/" + drv + exe[2:].replace("\\", "/")

    v = ViceOracle(vice_exe=exe)
    # `-reusize 16384` forces the full 16 MB. Without it VICE 3.10
    # defaults to a smaller size (often 512 KB) regardless of the
    # supplied image, and accesses to high banks (e.g. $FF0000 used
    # by doom.reu's per-outer header tables) wrap to lower banks —
    # producing non-zero header bytes where DUT correctly sees zeros.
    v.launch(extra_args=[
        "-reu",
        "-reusize", "16384",
        "-reuimage", reu_image_path,
    ])
    try:
        v._drain(idle_s=0.5, max_s=3.0)
        v._cmd("reset 0", timeout=10.0)
        v._drain(idle_s=0.3, max_s=2.0)
        v.load_bytes_direct(program_addr, program)

        # CIA timer stops (defense in depth — `>` raw pokes don't clear
        # the latched IRQ bit, but they do stop the timers from cycling
        # further) + RTI trampolines + IRQ/NMI/BRK vector overrides.
        # `r p=I` is ineffective on xscpu64; the trampoline pattern is
        # the only known-working way to keep a stepwise diff from
        # diverting into KERNAL IRQ-handler land.
        for poke in ["> $dc0e 00", "> $dc0f 00", "> $dd0e 00",
                     "> $dd0f 00", "> $dc0d 7f", "> $dd0d 7f"]:
            v._cmd(poke, timeout=5.0, min_idle=0.05)

        # Bare trampoline at $0900: LDA $DC0D; LDA $DD0D; RTI
        v.load_bytes_direct(
            0x0900, bytes([0xAD, 0x0D, 0xDC, 0xAD, 0x0D, 0xDD, 0x40])
        )
        # KERNAL-style trampoline at $0910: clear latches + unwind A/X/Y
        v.load_bytes_direct(
            0x0910, bytes([0xAD, 0x0D, 0xDC, 0xAD, 0x0D, 0xDD,
                           0x68, 0xA8, 0x68, 0xAA, 0x68, 0x40])
        )
        v.load_bytes_direct(0xFFFA, bytes([0x00, 0x09]))   # NMI bare
        v.load_bytes_direct(0xFFFE, bytes([0x00, 0x09]))   # IRQ/BRK bare
        v.load_bytes_direct(0x0314, bytes([0x10, 0x09]))   # KERNAL IRQ
        v.load_bytes_direct(0x0318, bytes([0x10, 0x09]))   # KERNAL NMI

        v._drain(idle_s=0.3, max_s=2.0)

        # Set BP at body_break_pc, run from prologue_entry_pc so the
        # prologue's copy loop populates $0700+ before we break.
        bp_id = v.set_breakpoint(body_break_pc, 0)
        try:
            v._sock.sendall(
                f"g ${prologue_entry_pc:04x}\r\n".encode()
            )
            v._sock.settimeout(0.5)
            buf = b""
            end = _time.time() + 60.0
            seen_break = False
            while _time.time() < end:
                try:
                    chunk = v._sock.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                if PROMPT in buf and (b"BREAK" in buf or b"Stop" in buf):
                    seen_break = True
                    break
            if not seen_break:
                raise RuntimeError(
                    f"prologue → body_break_pc ${body_break_pc:04x} "
                    f"BP did not fire within 60s"
                )
        finally:
            try:
                v.delete_breakpoint(bp_id)
            except Exception:
                pass

        return v.capture_trace_from_current(
            max_instr=body_max_instr, mask_irq=False
        )
    finally:
        v.shutdown()


@cocotb.test()
async def test_doom_loader_body(dut):
    """Diff loader body past $0700 — DUT REU model + VICE -reu."""
    test_name = "test_doom_loader_body"

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
        dut._log.warning(f"SKIP {test_name}: doom.reu missing at {DOOM_REU_PATH}")
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": f"doom.reu missing at {DOOM_REU_PATH}",
        })
        return

    # 1) DUT: plant loader at $0801, attach REU image, run from $080D.
    fix = DutFixture(dut, clk_period_ns=31.25)
    fix.load_bytes(0x00, LOADER_ADDR, LOADER_BYTES)
    fix.patch_reset_vector(LOADER_ENTRY)
    fix.load_bytes(0x00, 0xFF00, bytes([0x40]))
    fix.load_bytes(0x00, 0xFFE6, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEA, bytes([0x00, 0xFF]))
    fix.load_bytes(0x00, 0xFFEE, bytes([0x00, 0xFF]))
    fix.attach_reu(str(DOOM_REU_PATH))

    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)
    # Prologue empirically takes ~4013 instr (screen-clear + copy loops).
    # Use 4500 headroom so we always reach $0700 with full LOADER_BODY_INSTR
    # of body left.
    await fix.run_n_instructions(4500 + LOADER_BODY_INSTR)

    dut_trace_full = fix.get_trace()
    # Find where DUT crosses into the body, then skip ONE instruction
    # (SEI at $0700) so we align with VICE's $0701 body BP. Keep window.
    body_start = None
    for i, tl in enumerate(dut_trace_full):
        if tl.pbr == 0 and tl.pc == BODY_DIFF_PC:
            body_start = i
            break
    if body_start is None:
        dut._log.error(f"{test_name}: DUT never reached ${BODY_DIFF_PC:04x}")
        _emit_layer_a_json({
            "status": "DIVERGE_PRE_BODY",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": f"DUT never reached ${BODY_DIFF_PC:04x}",
        })
        return
    dut_trace = dut_trace_full[body_start : body_start + LOADER_BODY_INSTR]
    dut._log.info(
        f"DUT captured {len(dut_trace_full)} total; body window "
        f"{len(dut_trace)} starting idx={body_start} "
        f"last_pc={dut_trace[-1].pc:04x} last_pbr={dut_trace[-1].pbr:02x}"
    )

    # 2) VICE: launch with -reu -reuimage doom.reu, run prologue
    #    unmonitored, then stepwise-capture body starting at $0700.
    reu_path_for_vice = _wsl_to_windows_path(DOOM_REU_PATH)
    try:
        oracle_trace = _vice_oracle_capture_with_reu_stepwise(
            program=LOADER_BYTES,
            program_addr=LOADER_ADDR,
            prologue_entry_pc=LOADER_ENTRY,
            body_break_pc=BODY_DIFF_PC,
            body_max_instr=LOADER_BODY_INSTR,
            reu_image_path=reu_path_for_vice,
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
    dut._log.info(
        f"VICE captured {len(oracle_trace)} body fetches; "
        f"first={oracle_trace[0].pbr:02x}:{oracle_trace[0].pc:04x} "
        f"last={oracle_trace[-1].pbr:02x}:{oracle_trace[-1].pc:04x}"
    )

    # 3) Both traces are body-only and start at $0700. Diff directly.
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
