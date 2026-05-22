-- scpu_async_bridge.vhd — F.diag minimal pure-wire passthrough.
--
-- DIAGNOSTIC build: this file deliberately strips everything to bare
-- wires. No FSM. No sync FFs. No cache. No generic-conditional logic.
-- Goal: prove (or disprove) that the entity wrapper itself — port
-- shape and signal directions — preserves baseline behavior.
--
-- If hardware boots cleanly with this version, the F.1 wedge lives
-- in the conditional output muxes or the dead-but-instantiated FSM
-- registers. If it still wedges, the wedge is upstream in
-- fpga64_sid_iec.vhd integration (Phase B/C clk_cpu retarget) and
-- the bridge entity is not the culprit.
--
-- F.1 bridge backed up at tools/scpu_async_bridge_F1_backup.vhd.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity scpu_async_bridge is
generic (
	BRIDGE_ACTIVE : std_logic := '0';
	CACHE_ACTIVE  : std_logic := '0'
);
port (
	clk_cpu       : in  std_logic;
	clk_sys       : in  std_logic;
	reset         : in  std_logic;

	-- CPU side
	cpu_addr_in    : in  unsigned(15 downto 0);
	cpu_addr_hi_in : in  unsigned(7 downto 0);
	cpu_do_in      : in  unsigned(7 downto 0);
	cpu_we_in      : in  std_logic;
	cpu_vpa_in     : in  std_logic;
	cpu_vda_in     : in  std_logic;
	cpu_di_out     : out unsigned(7 downto 0);
	cpu_rdy_out    : out std_logic;

	-- Bus side
	bus_addr_out     : out unsigned(15 downto 0);
	bus_addr_hi_out  : out unsigned(7 downto 0);
	bus_do_out       : out unsigned(7 downto 0);
	bus_we_out       : out std_logic;
	bus_vpa_out      : out std_logic;
	bus_vda_out      : out std_logic;
	bus_di_in        : in  unsigned(7 downto 0);
	bus_ack_pulse_in : in  std_logic;

	dbg_is_slow      : out std_logic
);
end entity;

architecture rtl of scpu_async_bridge is
begin
	bus_addr_out    <= cpu_addr_in;
	bus_addr_hi_out <= cpu_addr_hi_in;
	bus_do_out      <= cpu_do_in;
	bus_we_out      <= cpu_we_in;
	bus_vpa_out     <= cpu_vpa_in;
	bus_vda_out     <= cpu_vda_in;

	cpu_di_out      <= bus_di_in;
	cpu_rdy_out     <= '1';

	dbg_is_slow     <= '0';
end architecture;
