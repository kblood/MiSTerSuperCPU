-- c1351_stub.vhd
--
-- Phase 4b: minimal VHDL stub for the c1351.v Verilog module
-- (Commodore 1351 mouse). Idle stub returns zero on all outputs.
--
-- NOTE: c1351 is instantiated at the c64.sv level (see c64.sv "mouse"
-- instance), NOT inside fpga64_sid_iec.vhd. The Phase 4b harness does
-- not need this stub. It exists only as a placeholder for a future
-- harness that wraps the whole c64.sv.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c1351 is
    port (
        clk_sys   : in  std_logic;
        reset     : in  std_logic;
        ps2_mouse : in  std_logic_vector(24 downto 0);
        potX      : out std_logic_vector(7 downto 0);
        potY      : out std_logic_vector(7 downto 0);
        button    : out std_logic_vector(1 downto 0)
    );
end entity;

architecture stub of c1351 is
begin
    potX   <= (others => '0');
    potY   <= (others => '0');
    button <= (others => '0');
end architecture;
