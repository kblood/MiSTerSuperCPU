-- scpu_async_bridge.vhd
--
-- Sits between the P65C816 and the legacy clk_sys bus arbiter. Owns the
-- eventual CDC sync FFs, RDY-stall state machine, and fast/slow address
-- decoder so neither the CPU nor the arbiter has to know about clock
-- domain crossings.
--
-- Current state: pure passthrough. Synthesiser collapses every assignment
-- to a bare wire, so the netlist (and RBF) is identical to the un-bridged
-- build. Later phases populate the internals without changing this port
-- signature.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity scpu_async_bridge is
port (
	clk_cpu       : in  std_logic;
	clk_sys       : in  std_logic;
	reset         : in  std_logic;

	-- CPU side (P65C816, clk_cpu domain)
	cpu_addr_in   : in  unsigned(15 downto 0);
	cpu_do_in     : in  unsigned(7 downto 0);
	cpu_we_in     : in  std_logic;
	cpu_di_out    : out unsigned(7 downto 0);
	cpu_rdy_out   : out std_logic;

	-- Bus side (legacy arbiter, clk_sys domain)
	bus_addr_out  : out unsigned(15 downto 0);
	bus_do_out    : out unsigned(7 downto 0);
	bus_we_out    : out std_logic;
	bus_di_in     : in  unsigned(7 downto 0);
	bus_rdy_in    : in  std_logic
);
end entity;

architecture rtl of scpu_async_bridge is
begin
	bus_addr_out <= cpu_addr_in;
	bus_do_out   <= cpu_do_in;
	bus_we_out   <= cpu_we_in;
	cpu_di_out   <= bus_di_in;
	cpu_rdy_out  <= bus_rdy_in;
end architecture;
