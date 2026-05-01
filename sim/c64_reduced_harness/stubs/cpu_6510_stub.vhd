-- cpu_6510_stub.vhd
--
-- Phase 4b: SHIM entity that replaces the real cpu_6510.vhd in
-- C64_MiSTer/rtl/ for GHDL analysis.
--
-- Why: The real cpu_6510.vhd line 58 writes
--
--     cpu: work.T65
--
-- which is VHDL-87 "component instantiation by name" syntax. VHDL-93/08
-- requires either
--   - `cpu: entity work.T65`  (direct entity instantiation), or
--   - `cpu: T65` plus a `component T65` declaration in the architecture
-- neither of which the real file has. GHDL 5.x under --std=08 rejects it
-- with "component name expected, found entity". The file cannot be
-- modified per task constraints, so this shim provides a SAME-PORT-LIST
-- cpu_6510 entity that the Phase 4b runner analyzes instead.
--
-- Behavior: the shim CPU holds all outputs quiescent. In the Phase 4b
-- bench we drive `supercpu_en='1'`, which makes fpga64_sid_iec.vhd put
-- cpu_6510 into `reset=1` and mux its outputs out. So this stub's lack
-- of real behavior is irrelevant — the 65C816 is the active CPU.
--
-- If a future bench needs 6510 execution, analyze the real T65 + cpu_6510
-- instead of this stub by dropping the stub from the source list and
-- providing a modified cpu_6510.vhd in the shim directory that uses
-- `entity work.T65` syntax.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_6510 is
    port (
        clk     : in  std_logic;
        enable  : in  std_logic;
        reset   : in  std_logic;
        nmi_n   : in  std_logic;
        nmi_ack : out std_logic;
        irq_n   : in  std_logic;
        rdy     : in  std_logic;

        di      : in  unsigned(7 downto 0);
        do      : out unsigned(7 downto 0);
        addr    : out unsigned(15 downto 0);
        we      : out std_logic;

        diIO    : in  unsigned(7 downto 0);
        doIO    : out unsigned(7 downto 0);
        sync_out: out std_logic;
        regs    : out std_logic_vector(63 downto 0)
    );
end entity;

architecture stub of cpu_6510 is
begin
    nmi_ack <= '0';
    do      <= (others => '0');
    addr    <= (others => '0');
    we      <= '0';
    doIO    <= x"37";   -- matches the kernel default (LORAM|HIRAM|CHAREN)
    sync_out <= '0';
    regs     <= (others => '0');
end architecture;
