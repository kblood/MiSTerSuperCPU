-- c64_ram64k.vhd — 64KB dual-port BRAM for C64 bank $00 RAM
--
-- Covers $0000-$FFFF (full bank $00 address space).
-- Port A: CPU read/write (full speed, 1-cycle registered read)
-- Port B: VIC-II read (independent, zero contention with CPU)
--
-- Uses M10K block RAM on Cyclone V (~52 M10K blocks for 64KB).
-- Both ports share the same 64KB storage — true dual-port.
--
-- Address: 16-bit input, full range used ($0000-$FFFF).
-- Caller must gate writes and hit checks for valid address ranges.
-- Port A read latency: 1 clock cycle (M10K registered output)
-- Port B read latency: 1 clock cycle (M10K registered output)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c64_ram64k is
port (
	clk       : in  std_logic;

	-- Port A: CPU (read/write)
	a_addr    : in  unsigned(15 downto 0);
	a_din     : in  unsigned(7 downto 0);
	a_dout    : out unsigned(7 downto 0);
	a_we      : in  std_logic;

	-- Port B: VIC-II (read only)
	b_addr    : in  unsigned(15 downto 0);
	b_dout    : out unsigned(7 downto 0);

	-- Debug probe: asynchronous read for simulation/diagnostics.
	probe_addr : in  unsigned(15 downto 0) := (others => '0');
	probe_dout : out unsigned(7 downto 0)
);
end c64_ram64k;

architecture rtl of c64_ram64k is

	-- 64KB storage: 65536 x 8 bits = 524,288 bits
	-- Quartus infers M10K blocks for this array.
	type ram_t is array(0 to 65535) of std_logic_vector(7 downto 0);
	shared variable ram : ram_t;

	-- Prevent Quartus from using MLAB (force M10K)
	attribute ramstyle : string;
	attribute ramstyle of ram : variable is "M10K, no_rw_check";

begin

	-- Port A: CPU read/write (1-cycle registered read)
	-- Full 16-bit address used (64KB range)
	process(clk)
	begin
		if rising_edge(clk) then
			if a_we = '1' then
				ram(to_integer(a_addr)) := std_logic_vector(a_din);
			end if;
			a_dout <= unsigned(ram(to_integer(a_addr)));
		end if;
	end process;

	-- Port B: VIC-II read only (1-cycle registered read)
	-- Caller gates b_addr to $0000-$7FFF; upper half unused by VIC.
	process(clk)
	begin
		if rising_edge(clk) then
			b_dout <= unsigned(ram(to_integer(b_addr)));
		end if;
	end process;

	-- Simulation/debug-only combinational probe.
	probe_dout <= unsigned(ram(to_integer(probe_addr)));

end rtl;
