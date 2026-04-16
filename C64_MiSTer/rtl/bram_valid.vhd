-- bram_valid.vhd — 64K×1 per-byte valid-bit RAM for BRAM cache
--
-- Simple dual-port: Port A (write), Port B (read).
-- Uses M10K block RAM on Cyclone V (~8 M10K blocks for 64Kbit).
-- Port B read latency: 1 clock cycle (M10K registered output).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_valid is
port (
	clk     : in  std_logic;

	-- Port A: write (set/clear valid bits)
	a_addr  : in  unsigned(15 downto 0);
	a_din   : in  std_logic;
	a_we    : in  std_logic;

	-- Port B: read (check validity)
	b_addr  : in  unsigned(15 downto 0);
	b_dout  : out std_logic
);
end bram_valid;

architecture rtl of bram_valid is

	type ram_t is array(0 to 65535) of std_logic_vector(0 downto 0);
	shared variable ram : ram_t;

	attribute ramstyle : string;
	attribute ramstyle of ram : variable is "M10K, no_rw_check";

begin

	-- Port A: write only
	process(clk)
	begin
		if rising_edge(clk) then
			if a_we = '1' then
				ram(to_integer(a_addr)) := (0 => a_din);
			end if;
		end if;
	end process;

	-- Port B: read only (1-cycle registered output)
	process(clk)
	begin
		if rising_edge(clk) then
			b_dout <= ram(to_integer(b_addr))(0);
		end if;
	end process;

end rtl;
