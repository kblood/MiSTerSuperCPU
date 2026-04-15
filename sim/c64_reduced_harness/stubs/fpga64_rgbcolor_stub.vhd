-- fpga64_rgbcolor_stub.vhd
--
-- Phase 4b: SHIM entity that replaces the real fpga64_rgbcolor.vhd in
-- C64_MiSTer/rtl/.
--
-- Why: GHDL 5.x in --std=08 mode rejects the real file because its
-- `case index is ... end case` block covers all 16 values of
-- `unsigned(3 downto 0)` but lacks `when others =>`. Strict VHDL-2008
-- considers `unsigned` a std_ulogic-based type whose case expressions
-- must list `when others` to cover 'U','X','Z' etc. The real file uses
--
--     when X"0" => ... when X"F" => ...
--
-- with no `when others`, which Quartus tolerates but GHDL does not. We
-- cannot modify files under C64_MiSTer/, so we provide this shim which
-- has the same entity declaration and a GHDL-legal architecture. It is
-- analyzed INSTEAD of the real file in the Phase 4b runner.
--
-- This stub hard-codes black output on all palette indices. For the
-- harness we never display video so the palette is irrelevant — the VIC
-- driver writes are exercised purely for their side effects on the bus
-- (sysCycle / enableCpu / systemAddr selection).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fpga64_rgbcolor is
    port (
        index : in  unsigned(3 downto 0);
        r     : out unsigned(7 downto 0);
        g     : out unsigned(7 downto 0);
        b     : out unsigned(7 downto 0)
    );
end entity;

architecture stub of fpga64_rgbcolor is
begin
    -- Palette value is immaterial to the harness; any legal default works.
    r <= (others => '0');
    g <= (others => '0');
    b <= (others => '0');
end architecture;
