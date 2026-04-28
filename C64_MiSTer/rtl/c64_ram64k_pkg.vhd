-- c64_ram64k_pkg.vhd — shared type definition for c64_ram64k
--
-- Exists so simulation testbenches can reach the c64_ram64k storage via
-- VHDL-2008 external names without forcing the type to be redefined
-- locally (external names require exact type identity).
--
-- Synthesis impact: zero — Quartus sees the same type whether declared
-- in the architecture or in this package.

library ieee;
use ieee.std_logic_1164.all;

package c64_ram64k_pkg is
    type ram_t is array(0 to 65535) of std_logic_vector(7 downto 0);
end package;
