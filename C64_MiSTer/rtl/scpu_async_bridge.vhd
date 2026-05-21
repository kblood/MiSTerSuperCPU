-- scpu_async_bridge.vhd
--
-- Sits between the P65C816 and the legacy clk_sys bus arbiter. Owns the
-- eventual CDC sync FFs, RDY-stall state machine, and fast/slow address
-- decoder so neither the CPU nor the arbiter has to know about clock
-- domain crossings.
--
-- Current state: passthrough plus internal address-class decode. The
-- is_slow_access signal classifies bank $00 (C64-compatible space) as
-- needing the slow-path CDC handshake; bank $01+ (SuperRAM / SDRAM) as
-- fast-path. The signal is exposed via the dbg_is_slow output so it
-- survives synthesis. The slow/fast paths themselves are not yet
-- differentiated — both relay unchanged through to the bus.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity scpu_async_bridge is
port (
	clk_cpu       : in  std_logic;
	clk_sys       : in  std_logic;
	reset         : in  std_logic;

	-- CPU side (P65C816, clk_cpu domain)
	cpu_addr_in    : in  unsigned(15 downto 0);
	cpu_addr_hi_in : in  unsigned(7 downto 0);
	cpu_do_in      : in  unsigned(7 downto 0);
	cpu_we_in      : in  std_logic;
	cpu_vpa_in     : in  std_logic;
	cpu_vda_in     : in  std_logic;
	cpu_di_out     : out unsigned(7 downto 0);
	cpu_rdy_out    : out std_logic;

	-- Bus side (legacy arbiter, clk_sys domain)
	bus_addr_out    : out unsigned(15 downto 0);
	bus_addr_hi_out : out unsigned(7 downto 0);
	bus_do_out      : out unsigned(7 downto 0);
	bus_we_out      : out std_logic;
	bus_vpa_out     : out std_logic;
	bus_vda_out     : out std_logic;
	bus_di_in       : in  unsigned(7 downto 0);
	bus_rdy_in      : in  std_logic;

	-- Debug observability: keeps the decoder out of the pruning list
	dbg_is_slow    : out std_logic
);
end entity;

architecture rtl of scpu_async_bridge is
	signal is_slow_access : std_logic;
begin
	-- Bank $00 = C64-compatible space. Reads cross clk_sys for RAM/ROM/I/O
	-- arbitration. Bank $01+ = SuperRAM in SDRAM, reachable directly through
	-- the data_valid handshake plumbing. The classification is the first
	-- gate the eventual RDY-stall state machine will look at.
	is_slow_access <= '1' when cpu_addr_hi_in = x"00" else '0';

	bus_addr_out    <= cpu_addr_in;
	bus_addr_hi_out <= cpu_addr_hi_in;
	bus_do_out      <= cpu_do_in;
	bus_we_out      <= cpu_we_in;
	bus_vpa_out     <= cpu_vpa_in;
	bus_vda_out     <= cpu_vda_in;
	cpu_di_out      <= bus_di_in;
	cpu_rdy_out     <= bus_rdy_in;

	dbg_is_slow <= is_slow_access;
end architecture;
