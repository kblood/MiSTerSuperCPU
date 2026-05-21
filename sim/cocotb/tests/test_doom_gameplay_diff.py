"""Doom gameplay-state diff: VICE-real-loader output vs DUT.

This is Probe 1 from docs/session_handoff.md after the bank-$20
prologue diff MATCHED for 15574 instructions to the music-error trap
($2C:$A95C). That MATCH proved the P65C816 microcode is correct on
Doom's post-loader dispatcher path — but the post-loader snapshot the
test pre-loaded was captured in a state that drives both DUT and VICE
INTO the trap. Real VICE-loader-output (no pre-load shortcut) reaches
healthy gameplay at PB=$2A PC≈$55A9 (memory note
project_doom_vice_oracle_runs_doom.md).

This test:
  1) Loads VICE's full mid-gameplay snapshot
     (tools/vice_oracle/gameplay/{regs.json,bank*.bin,gameplay.vsf}),
     captured AFTER the loader has populated SuperRAM via REU FETCH +
     long-stores. The snapshot represents VICE actually running the
     real Doom loader to completion + a few seconds of game logic.
  2) Pre-populates the cocotb DUT memory with all snapshot bank bytes.
  3) Plants a state-restoring bootstrap at $00:$0800 (always-RAM in
     C64 mode regardless of CPU-port HIRAM bit) and points the reset
     vector at it. The bootstrap puts the DUT CPU into the snapshot's
     exact register state then JMLs to PB:PC.
  4) On the VICE side, bload-s every snapshot bankXX.bin into VICE
     memory (one fast call per bank; VICE 3.10's monitor lacks
     save_snapshot/load_snapshot so we can't shortcut via .vsf).
     Plants the same bootstrap PLUS RTI trampolines at $0840 and $0850
     (cleared CIA latches + RAM IRQ vectors at $0314/$0318 + bare 65816
     vectors at $FFFA/$FFFE) so any pending CIA1 Timer-A IRQ that
     fires after SEI services harmlessly back to the bootstrap.
  5) Sets a VICE breakpoint at PB:$2A PC:$55A3 (snapshot's target PC),
     `g $0800` runs bootstrap unmonitored, BP fires when bootstrap's
     final JML lands at gameplay entry, and stepwise capture begins
     from there — keeps the diff bootstrap-free.
  6) Steps both DUT and VICE side-by-side from PC=$2A:$55XX for
     GAMEPLAY_INSTR instructions. Aligns DUT trace to oracle's first PC.

Outcomes:
  * MATCH for ~5000 gameplay instructions
        -> P65C816 microcode is correct on the gameplay code path too.
        -> The "music_num=-9" bug is in the loader phase. Pivot to
           handoff probe A (REU model in DutFixture).
  * DIVERGE on a specific opcode
        -> A real CPU-microcode bug exercised by gameplay code that the
           prior bank-$20 dispatcher walk didn't trigger.
        -> Read the divergence point + DUT disasm to identify the
           opcode class (likely candidates: MVN/MVP, BRK-in-handler,
           IRQ-stack ops in native mode, undocumented modes).
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
from typing import Optional

import cocotb

# ---------------------------------------------------------------------------
# sys.path: tools/ + tools/vice_diff/
# ---------------------------------------------------------------------------
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
from state_restore_bootstrap import Snapshot, build_bootstrap  # noqa: E402


# ---------------------------------------------------------------------------
# Snapshot inputs
# ---------------------------------------------------------------------------

SNAPSHOT_DIR = REPO / "tools" / "vice_oracle" / "gameplay"
SNAPSHOT_REGS = SNAPSHOT_DIR / "regs.json"

# Bootstrap location in bank $00 stack page. Snapshot SP=$01FF means the
# stack is logically empty: $0100-$01FD is unused storage at the moment
# of capture. Planting a 53-byte bootstrap at $0100..$0134 clobbers
# nothing live, AND the C64 always reads RAM at $0100 (regardless of the
# CPU-port HIRAM bit) so VICE can fetch from there in C64-emulation mode
# before XCE switches to native+SCPU. The bootstrap restores stack-top
# bytes $01FE/$01FF (real snapshot values) before JML, and our pushes
# use $01FE/$01FF only — never down into our own code at $0100-$0134.
# (Earlier attempt at $FF10 failed: CPU fetches at $FF10 hit KERNAL ROM
# even after writing $01=$94, because VICE's raw-RAM `>` poke does not
# update the CPU-port latch.)
BOOTSTRAP_ADDR = 0x0800

# How far past the bootstrap-induced JML to step. Start at 1000 for
# the smoke run (~3.5 min stepping); raise to 5000 if we MATCH at 1000
# to push the comparison further. Each VICE step is ~0.21s due to
# monitor RTT, so 1000 instructions ~= 3.5 min wallclock for the VICE
# side alone (DUT side is faster).
GAMEPLAY_INSTR = 5000


def _load_snapshot() -> Snapshot:
    """Parse regs.json into a Snapshot dataclass."""
    j = json.loads(SNAPSHOT_REGS.read_text())
    return Snapshot.from_regs_dict(j)


def _populated_bank_files() -> list[tuple[int, pathlib.Path]]:
    """Return [(bank_id, host_path_to_bin), ...] for every bank*.bin."""
    out: list[tuple[int, pathlib.Path]] = []
    for f in sorted(SNAPSHOT_DIR.glob("bank*.bin")):
        bank = int(f.stem[4:], 16)
        out.append((bank, f.resolve()))
    return out


def _to_vice_path(p: pathlib.Path) -> str:
    """Translate a host path to one VICE (Windows binary) can read.

    cocotb runs under WSL2 where the snapshot files live at
    /mnt/c/LLM/.../bankXX.bin. VICE is the Windows xscpu64.exe, which
    sees that as C:/LLM/.../bankXX.bin. Translate /mnt/<drive>/X to
    <DRIVE>:/X. Forward-slash everywhere (VICE accepts both, but
    forward slashes don't need escaping inside the monitor's quoted
    string).
    """
    s = str(p).replace("\\", "/")
    if s.startswith("/mnt/") and len(s) > 6 and s[6] == "/":
        # /mnt/c/foo -> C:/foo
        drive = s[5].upper()
        s = f"{drive}:{s[6:]}"
    return s


def _vice_capture_with_bootstrap(
    bank_files: list[tuple[int, pathlib.Path]],
    bootstrap: bytes,
    max_instr: int,
    target_pbr: int,
    target_pc: int,
):
    """Launch VICE, bload all snapshot banks, run bootstrap, capture trace.

    Both DUT and VICE go through the same bootstrap byte sequence so the
    diff measures CPU divergence post-JML, not setup differences.
    """
    from vice_oracle import ViceOracle, VICE_EXE_DEFAULT
    exe = VICE_EXE_DEFAULT
    if not pathlib.Path(exe).exists() and exe[1:3] == ":\\":
        drv = exe[0].lower()
        exe = "/mnt/" + drv + exe[2:].replace("\\", "/")

    with ViceOracle(vice_exe=exe) as v:
        v._cmd("reset 0", timeout=10.0)

        # 1) bload every snapshot bank into VICE memory.
        # Bank $00: VICE's bload writes to motherboard RAM (cpu memspace),
        # which IS what the snapshot represents. Subsequent banks use
        # `bank ramXX` switch built into load_bank_file.
        print(f"  VICE: bload-ing {len(bank_files)} snapshot banks...")
        for bank, host_path in bank_files:
            v.load_bank_file(bank, _to_vice_path(host_path))
        print(f"  VICE: snapshot banks loaded.")

        # 1c) Stop CIA1+CIA2 timers and mask all interrupt sources. After
        #     `reset 0` KERNAL boot leaves CIA1 Timer A running (60 Hz IRQ).
        #     Raw `>` pokes to $DC0E/$DC0D do NOT clear the latched IRQ
        #     bit inside the CIA chip — only a CPU read of $DC0D/$DD0D
        #     does that, and we can't run a real CPU read until after the
        #     bootstrap starts. We disable timers anyway to stop new IRQs
        #     from being raised after the latch is cleared.
        for poke in [
            "> $dc0e 00", "> $dc0f 00",
            "> $dd0e 00", "> $dd0f 00",
            "> $dc0d 7f", "> $dd0d 7f",
        ]:
            v._cmd(poke, timeout=5.0, min_idle=0.05)

        # 1d) Two trampolines for any IRQ/NMI that fires during bootstrap:
        #     - $0840 = "bare" trampoline (IRQ pushed only 3 bytes
        #       directly; KERNAL ROM is unmapped because snapshot's
        #       $01=$94). Reads CIA ICRs to clear latch, then RTI.
        #     - $0850 = "KERNAL" trampoline (KERNAL IRQ entry stacked
        #       A/X/Y before JMP through $0314 — defensive in case
        #       KERNAL ROM is mapped). Pops A/X/Y then RTI.
        BARE_TRAMPOLINE = 0x0840
        bare_trampoline = bytes([
            0xAD, 0x0D, 0xDC,    # LDA $DC0D
            0xAD, 0x0D, 0xDD,    # LDA $DD0D
            0x40,                # RTI
        ])
        KERNAL_TRAMPOLINE = 0x0850
        kernal_trampoline = bytes([
            0xAD, 0x0D, 0xDC,    # LDA $DC0D
            0xAD, 0x0D, 0xDD,    # LDA $DD0D
            0x68, 0xA8,          # PLA; TAY
            0x68, 0xAA,          # PLA; TAX
            0x68,                # PLA
            0x40,                # RTI
        ])
        # Vectors:
        #   Bare 65C816 emu vectors at $FFFA/B (NMI), $FFFE/F (IRQ/BRK)
        #   → BARE_TRAMPOLINE
        #   KERNAL RAM vectors at $0314 (IRQ), $0316 (BRK), $0318 (NMI)
        #   → KERNAL_TRAMPOLINE
        blo = BARE_TRAMPOLINE & 0xFF
        bhi = (BARE_TRAMPOLINE >> 8) & 0xFF
        klo = KERNAL_TRAMPOLINE & 0xFF
        khi = (KERNAL_TRAMPOLINE >> 8) & 0xFF
        kernal_vec_bytes = bytes([
            klo, khi, klo, khi, klo, khi,    # $0314..$0319
        ])

        # 2) Plant bootstrap + both trampolines + both vector sets in
        #    BOTH motherboard RAM (for C64-emu-mode pre-XCE fetches)
        #    AND SuperCPU SRAM ram00 (for native+SCPU post-XCE fetches).
        for memspace in ("cpu", "ram00"):
            if memspace != "cpu":
                v._cmd(f"bank {memspace}", timeout=5.0)
            try:
                v.load_bytes_direct(BOOTSTRAP_ADDR, bootstrap)
                v.load_bytes_direct(BARE_TRAMPOLINE, bare_trampoline)
                v.load_bytes_direct(KERNAL_TRAMPOLINE, kernal_trampoline)
                v.load_bytes_direct(0x0314, kernal_vec_bytes)
                # Bare emu-mode vectors $FFFA-$FFFF (NMI/RESET/IRQ).
                # Snapshot has $EA*6 here; we leave RESET as-is.
                v.load_bytes_direct(0xFFFA, bytes([blo, bhi]))   # NMI
                v.load_bytes_direct(0xFFFE, bytes([blo, bhi]))   # IRQ/BRK
            finally:
                if memspace != "cpu":
                    v._cmd("bank cpu", timeout=5.0)

        # 2b) Sanity: bootstrap landed correctly (motherboard side).
        check = v.mem(BOOTSTRAP_ADDR, len(bootstrap))
        if check != bootstrap:
            for retry in range(2):
                v.load_bytes_direct(BOOTSTRAP_ADDR, bootstrap)
                check = v.mem(BOOTSTRAP_ADDR, len(bootstrap))
                if check == bootstrap:
                    break
            else:
                raise RuntimeError(
                    f"VICE bootstrap failed to land at ${BOOTSTRAP_ADDR:04x}: "
                    f"expected {bootstrap.hex()} got {check.hex()}"
                )

        # 3) Two-phase capture: run bootstrap unmonitored (let any
        #    pending IRQ visit the trampoline; CIA latch is then clear),
        #    then start tracing AT THE SNAPSHOT'S TARGET PC. This keeps
        #    the diff cleanly bootstrap-free — both DUT and oracle land
        #    at the same (PBR, PC) state and step from there.
        import socket as _socket
        bp_id = v.set_breakpoint(target_pc, target_pbr)
        try:
            v._sock.sendall(f"g ${BOOTSTRAP_ADDR:04x}\r\n".encode())
            v._sock.settimeout(0.5)
            buf = b""
            import time as _time
            end = _time.time() + 30.0
            seen_break = False
            while _time.time() < end:
                try:
                    chunk = v._sock.recv(65536)
                except _socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                if b"(C:$" in buf and (b"BREAK" in buf or b"Stop" in buf):
                    seen_break = True
                    break
            if not seen_break:
                raise RuntimeError(
                    f"VICE BP at ${target_pbr:02x}:${target_pc:04x} did not fire "
                    f"after `g ${BOOTSTRAP_ADDR:04x}` — bootstrap stuck or wrong PC?"
                )
        finally:
            try:
                v.delete_breakpoint(bp_id)
            except Exception:
                pass
        return v.capture_trace_from_current(max_instr=max_instr)


@cocotb.test()
async def test_doom_gameplay_diff(dut):
    """Step VICE-real-gameplay vs DUT for ~5000 instructions; report diff."""
    test_name = "test_doom_gameplay_diff"

    # ------------------------------------------------------------------
    # Skip conditions
    # ------------------------------------------------------------------
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

    if not SNAPSHOT_REGS.exists():
        msg = f"snapshot regs.json not found at {SNAPSHOT_REGS}"
        dut._log.warning(f"SKIP {test_name}: {msg}")
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": msg,
        })
        return

    bank_files = _populated_bank_files()
    if not bank_files:
        msg = f"no bank*.bin files found in {SNAPSHOT_DIR}"
        dut._log.warning(f"SKIP {test_name}: {msg}")
        _emit_layer_a_json({
            "status": "SKIP",
            "instructions_compared": 0,
            "test_name": test_name,
            "divergence_index": None,
            "skip_reason": msg,
        })
        return

    # ------------------------------------------------------------------
    # Load snapshot
    # ------------------------------------------------------------------
    snap = _load_snapshot()
    dut._log.info(
        f"snapshot regs: PBR=${snap.pbr:02x} PC=${snap.pc:04x} "
        f"A=${snap.a:04x} X=${snap.x:04x} Y=${snap.y:04x} "
        f"SP=${snap.sp:04x} D=${snap.d:04x} DBR=${snap.dbr:02x} "
        f"P=${snap.p:02x} E={snap.e} "
        f"stack[$01FE,$01FF]=${snap.stack_1fe:02x},${snap.stack_1ff:02x}"
    )

    # Force I-flag=1 in the bootstrap-restored P. Snapshot P likely has
    # I=0 (Doom runs with IRQ enabled for VIC raster). On DUT, IRQ_N is
    # tied high so no IRQ fires. On VICE, CIA timers are live and would
    # fire an IRQ immediately after PLP, diverging from DUT instantly.
    # Masking IRQ on BOTH sides keeps the comparison about CPU microcode,
    # not interrupt timing.
    snap_masked = Snapshot(
        pbr=snap.pbr, pc=snap.pc, a=snap.a, x=snap.x, y=snap.y,
        sp=snap.sp, d=snap.d, dbr=snap.dbr,
        p=snap.p | 0x04,    # set I-flag (bit 2) to mask IRQ
        e=snap.e,
        stack_1fe=snap.stack_1fe, stack_1ff=snap.stack_1ff,
    )
    bootstrap = build_bootstrap(snap_masked)
    dut._log.info(f"bootstrap: {len(bootstrap)} bytes "
                  f"(planted at $00:${BOOTSTRAP_ADDR:04x}; I-flag forced=1)")


    dut._log.info(f"snapshot has {len(bank_files)} populated banks")

    # ------------------------------------------------------------------
    # DUT setup
    # ------------------------------------------------------------------
    fix = DutFixture(dut, clk_period_ns=31.25)

    for bank, host_path in bank_files:
        data = host_path.read_bytes()
        if len(data) != 0x10000:
            raise RuntimeError(
                f"bank ${bank:02x} snapshot wrong length: {len(data)}"
            )
        fix.load_bytes(bank, 0x0000, data)
    dut._log.info(f"DUT memory primed with {len(bank_files)} banks "
                  f"({len(bank_files) * 64}KB)")

    # Plant bootstrap LAST so it overwrites whatever was at $FF10 in the
    # bank $00 snapshot bytes. (Snapshot has $EA at $FF10..$FFFF anyway.)
    fix.load_bytes(0x00, BOOTSTRAP_ADDR, bootstrap)
    fix.patch_reset_vector(BOOTSTRAP_ADDR)

    # Native vector pad — RTI sink at $FF00 so accidental BRK during
    # gameplay doesn't lock up the DUT in a divergent way. (The snapshot
    # has real bytes at $FF00 already; this would clobber them. Skip.)
    # Instead trust the snapshot's vector area as-is.

    cocotb.start_soon(fix.clock_and_bus_loop())
    await fix.reset(cycles=8)

    # Run enough instructions for bootstrap (~30 fetches) + GAMEPLAY_INSTR
    # gameplay fetches. Generous headroom.
    total = GAMEPLAY_INSTR + 100
    dut._log.info(f"DUT: running {total} instructions...")
    await fix.run_n_instructions(total)

    dut_trace_full = fix.get_trace()
    dut._log.info(f"DUT captured {len(dut_trace_full)} fetches; "
                  f"first={dut_trace_full[0].pbr:02x}:"
                  f"{dut_trace_full[0].pc:04x} "
                  f"last={dut_trace_full[-1].pbr:02x}:"
                  f"{dut_trace_full[-1].pc:04x}")

    # ------------------------------------------------------------------
    # VICE side
    # ------------------------------------------------------------------
    try:
        oracle_trace = _vice_capture_with_bootstrap(
            bank_files=bank_files,
            bootstrap=bootstrap,
            max_instr=GAMEPLAY_INSTR,
            target_pbr=snap_masked.pbr & 0xFF,
            target_pc=snap_masked.pc & 0xFFFF,
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

    dut._log.info(f"VICE captured {len(oracle_trace)} fetches; "
                  f"first={oracle_trace[0].pbr:02x}:"
                  f"{oracle_trace[0].pc:04x} "
                  f"last={oracle_trace[-1].pbr:02x}:"
                  f"{oracle_trace[-1].pc:04x}")

    # ------------------------------------------------------------------
    # Align DUT trace at first oracle PC (skips bootstrap), diff
    # ------------------------------------------------------------------
    dut_trace = _align_dut_to_oracle(dut_trace_full, oracle_trace)
    n = min(len(dut_trace), len(oracle_trace))
    dut._log.info(f"After alignment: DUT={len(dut_trace)} VICE={len(oracle_trace)} "
                  f"comparing min={n}")

    # Memory image for disasm: bank $00 + the populated SuperRAM banks.
    mem_image = bytes(fix._mem[0])
    for b in range(1, 0x100):
        mem_image += bytes(fix._mem[b])

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

    # Exploratory test — do not fail. The divergence_index in the JSON
    # marker is the actionable signal.
