"""dut_fixture.py — DutFixture for the P65C816 VHDL core under cocotb.

Layer 1 of the 3-layer verification environment. Provides:
  * Clock + active-low reset driver
  * 256-bank x 64KB combinational read / clocked-write memory model
  * Trace capture: emits a TraceLine per instruction-fetch (compatible
    with tools/vice_diff/vice_diff.py).
  * Helpers to load programs, patch the reset vector, and step instructions.

Critical timing rules
---------------------

The P65C816 expects D_IN to be valid the cycle after A_OUT settles
(combinational read). Cocotb's `await ReadOnly()` is the only safe place
to read the freshly-settled A_OUT in a delta cycle and assign D_IN before
the next rising edge, where the DUT samples it.

Instruction-fetch boundaries are detected on the rising edge where
`VPA=1 AND VDA=1 AND WE=1` (active-LOW WE → high means read). On that
cycle the opcode comes from D_IN (NOT DBG_IR — DBG_IR is the *previous*
opcode due to a one-cycle pipeline skew, see trace_format.md and
vice_diff comments).

WE is active-LOW: 0 = write, 1 = read. Writes are committed on the
rising edge where WE=0.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Optional

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import (
    RisingEdge,
    FallingEdge,
    ReadOnly,
    NextTimeStep,
    Timer,
)

# Re-use the canonical TraceLine from tools/vice_diff/vice_diff.py so
# downstream Layer 3 scoreboard code can compare against VICE without any
# adapter glue.
_HERE = os.path.dirname(os.path.abspath(__file__))
_VICE_DIFF_DIR = os.path.normpath(
    os.path.join(_HERE, "..", "..", "..", "tools", "vice_diff")
)
if _VICE_DIFF_DIR not in sys.path:
    sys.path.insert(0, _VICE_DIFF_DIR)

try:
    from vice_diff import TraceLine  # type: ignore
except Exception:  # pragma: no cover — fallback if vice_diff is missing
    @dataclass
    class TraceLine:  # type: ignore[no-redef]
        seq: int
        pbr: int
        pc: int
        ir: int
        p: int
        sp: int
        raw: str

        @classmethod
        def parse(cls, raw: str):
            return None


@dataclass
class TraceEntry:
    """One captured instruction fetch.

    Mirrors TraceLine plus extra DUT-only fields useful when debugging
    Layer 1 in isolation. Convert to TraceLine via `to_traceline()`.
    """
    seq: int
    pbr: int
    pc: int
    ir: int       # opcode read from D_IN on the fetch cycle
    p: int
    sp: int
    a: int
    x: int
    y: int
    dbr: int
    d: int
    cycle: int

    def to_traceline(self) -> TraceLine:
        raw = (
            f"{self.seq}:{self.pbr:02X}:{self.pc:04X}:"
            f"{self.ir:02X}:{self.p:02X}:{self.sp:04X}"
        )
        return TraceLine(
            seq=self.seq,
            pbr=self.pbr,
            pc=self.pc,
            ir=self.ir,
            p=self.p,
            sp=self.sp,
            raw=raw,
        )


def _to_int(sig) -> int:
    """Robust BinaryValue → int (returns 0 for X/Z bits)."""
    try:
        return int(sig.value)
    except Exception:
        # value contained X/Z; mask them off
        s = sig.value.binstr
        s = "".join("0" if c in ("x", "X", "z", "Z", "u", "U") else c for c in s)
        if not s:
            return 0
        return int(s, 2)


class DutFixture:
    """Cocotb-side host environment for the P65C816 DUT.

    Lifecycle:
        fix = DutFixture(dut)
        fix.load_bytes(0, 0x0800, program)
        fix.patch_reset_vector(0x0800)
        cocotb.start_soon(fix.clock_and_bus_loop())
        await fix.reset()
        await fix.run_n_instructions(80)
        assert fix.get_mem_byte(0, 0x3000) == 0x77
    """

    def __init__(self, dut, clk_period_ns: float = 31.25):
        self.dut = dut
        self.clk_period_ns = clk_period_ns

        # 256 banks * 64KB, default $EA = NOP.
        self._mem: list[bytearray] = [bytearray([0xEA]) * 65536 for _ in range(256)]

        # Trace state.
        self._trace: list[TraceEntry] = []
        self._cycle: int = 0
        self._seq: int = 0

        # Started flag for the bus loop (started by clock_and_bus_loop()).
        self._bus_loop_running = False
        self._stopped = False

        # Clock object (started by reset()).
        self._clock: Optional[Clock] = None

    # ------------------------------------------------------------------
    # Memory helpers
    # ------------------------------------------------------------------

    def load_bytes(self, bank: int, offset: int, data: bytes) -> None:
        """Write `data` into memory at bank:offset (no auto-wrap across bank)."""
        if not (0 <= bank <= 0xFF):
            raise ValueError(f"bank out of range: {bank:#x}")
        if offset + len(data) > 0x10000:
            raise ValueError(
                f"load_bytes overruns bank {bank:02X}: "
                f"offset={offset:#x} len={len(data)}"
            )
        self._mem[bank][offset:offset + len(data)] = data

    def patch_reset_vector(self, addr: int) -> None:
        """Set $00:$FFFC/$FFFD to point at addr (16-bit)."""
        self._mem[0x00][0xFFFC] = addr & 0xFF
        self._mem[0x00][0xFFFD] = (addr >> 8) & 0xFF

    def get_mem_byte(self, bank: int, offset: int) -> int:
        return self._mem[bank][offset & 0xFFFF]

    # ------------------------------------------------------------------
    # Bus + trace background task
    # ------------------------------------------------------------------

    async def clock_and_bus_loop(self) -> None:
        """Background task: drive D_IN combinationally, capture writes,
        emit TraceEntry on every instruction-fetch cycle.

        Must be started with `cocotb.start_soon(...)` BEFORE reset() is
        awaited. The clock itself is started inside reset().
        """
        if self._bus_loop_running:
            raise RuntimeError("clock_and_bus_loop already running")
        self._bus_loop_running = True

        dut = self.dut

        # Initial idle inputs.
        dut.CE.value = 1
        dut.RDY_IN.value = 1
        dut.NMI_N.value = 1
        dut.IRQ_N.value = 1
        dut.ABORT_N.value = 1
        dut.D_IN.value = 0xEA

        while not self._stopped:
            # Wait for the rising edge — the DUT is now updating outputs
            # combinationally based on its FF state.
            await RisingEdge(dut.CLK)
            self._cycle += 1

            # ReadOnly trigger: lets all delta deltas propagate so we see
            # the post-edge A_OUT/VPA/VDA/WE before driving D_IN for the
            # NEXT edge.
            await ReadOnly()

            rst_n = _to_int(dut.RST_N)
            if rst_n == 0:
                # In reset: keep feeding NOPs and skip trace + writes.
                await NextTimeStep()
                dut.D_IN.value = 0xEA
                continue

            we_n = _to_int(dut.WE)
            vpa = _to_int(dut.VPA)
            vda = _to_int(dut.VDA)
            addr = _to_int(dut.A_OUT) & 0xFFFFFF
            bank = (addr >> 16) & 0xFF
            off = addr & 0xFFFF

            if we_n == 0:
                # Write cycle — capture the byte the DUT is putting out.
                d_out = _to_int(dut.D_OUT) & 0xFF
                self._mem[bank][off] = d_out
            else:
                # Read cycle — drive D_IN with our memory contents.
                d_byte = self._mem[bank][off]

                # Instruction-fetch boundary: VPA=1 AND VDA=1 AND WE=1.
                # The opcode is the byte WE are about to feed in.
                if vpa == 1 and vda == 1:
                    self._seq += 1
                    entry = TraceEntry(
                        seq=self._seq,
                        pbr=_to_int(dut.DBG_PBR) & 0xFF,
                        pc=_to_int(dut.DBG_PC) & 0xFFFF,
                        ir=d_byte,
                        p=_to_int(dut.DBG_P) & 0xFF,
                        sp=_to_int(dut.DBG_SP) & 0xFFFF,
                        a=_to_int(dut.DBG_A) & 0xFFFF,
                        x=_to_int(dut.DBG_X) & 0xFFFF,
                        y=_to_int(dut.DBG_Y) & 0xFFFF,
                        dbr=_to_int(dut.DBG_DBR) & 0xFF,
                        d=_to_int(dut.DBG_D) & 0xFFFF,
                        cycle=self._cycle,
                    )
                    self._trace.append(entry)

            # Move out of read-only region, then drive D_IN for next edge.
            await NextTimeStep()
            if we_n != 0:
                dut.D_IN.value = self._mem[bank][off]
            # On write cycles D_IN doesn't matter; leave it whatever it was.

    # ------------------------------------------------------------------
    # Reset + stepping
    # ------------------------------------------------------------------

    async def reset(self, cycles: int = 8) -> None:
        """Drive RST_N low for `cycles` clocks, then release.

        Starts the clock generator on first call.
        """
        dut = self.dut

        # Idle inputs.
        dut.RST_N.value = 0
        dut.CE.value = 1
        dut.RDY_IN.value = 1
        dut.NMI_N.value = 1
        dut.IRQ_N.value = 1
        dut.ABORT_N.value = 1
        dut.D_IN.value = 0xEA

        # Start clock if not already running.
        if self._clock is None:
            # cocotb 2.x renamed `units` to `unit`. Try the new kwarg first;
            # fall back so this works against cocotb 1.9 as well.
            try:
                self._clock = Clock(dut.CLK, self.clk_period_ns, unit="ns")
            except TypeError:
                self._clock = Clock(dut.CLK, self.clk_period_ns, units="ns")
            cocotb.start_soon(self._clock.start())

        # Hold reset for the requested number of clocks.
        for _ in range(cycles):
            await RisingEdge(dut.CLK)

        # Release.
        dut.RST_N.value = 1
        # Give one clock for the DUT to come out of reset cleanly.
        await RisingEdge(dut.CLK)

    async def step_instruction(self) -> TraceEntry:
        """Run until the next instruction-fetch cycle is captured."""
        before = len(self._trace)
        # Cap to a generous instruction-cycle limit (BRK, MVN/MVP need many).
        for _ in range(200):
            await RisingEdge(self.dut.CLK)
            if len(self._trace) > before:
                return self._trace[-1]
        raise TimeoutError("step_instruction: no fetch within 200 cycles")

    async def run_n_instructions(self, n: int) -> list[TraceEntry]:
        """Step `n` instructions and return their TraceEntry list."""
        out: list[TraceEntry] = []
        for _ in range(n):
            out.append(await self.step_instruction())
        return out

    async def run_until_pc(self, bank: int, pc: int,
                          max_cycles: int = 50_000) -> bool:
        """Run until PBR:PC == bank:pc on a fetch cycle. Returns True on hit."""
        for _ in range(max_cycles):
            await RisingEdge(self.dut.CLK)
            if self._trace and (self._trace[-1].pbr == bank
                                and self._trace[-1].pc == pc):
                return True
        return False

    async def run_cycles(self, n: int) -> None:
        """Free-run for n clock cycles (no instruction-step gating)."""
        for _ in range(n):
            await RisingEdge(self.dut.CLK)

    def stop(self) -> None:
        """Signal the bus loop to exit on its next iteration."""
        self._stopped = True

    # ------------------------------------------------------------------
    # Trace accessors
    # ------------------------------------------------------------------

    def get_trace(self) -> list[TraceLine]:
        """Return captured fetches as TraceLine list (vice_diff-compatible)."""
        return [e.to_traceline() for e in self._trace]

    def get_trace_entries(self) -> list[TraceEntry]:
        """Return captured fetches with full DUT context (a/x/y/dbr/d)."""
        return list(self._trace)

    @property
    def cycle(self) -> int:
        return self._cycle
