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
	b_dout    : out unsigned(7 downto 0)
);
end c64_ram64k;

architecture rtl of c64_ram64k is

	-- 64KB storage: 65536 x 8 bits = 524,288 bits
	-- Quartus infers M10K blocks for this array.
	type ram_t is array(0 to 65535) of std_logic_vector(7 downto 0);
	shared variable ram : ram_t;

	-- v157 attempt to drop "no_rw_check" produced -8.5ns slack on clk64
	-- (Quartus inserts large forwarding muxes that cannot meet 64MHz). Keep
	-- no_rw_check; the cycle-N+1 a_din_d1 bypass below covers the RAW hazard
	-- without forcing M10K read-during-write inference.
	attribute ramstyle : string;
	attribute ramstyle of ram : variable is "M10K, no_rw_check";

	-- 2026-04-27: explicit write-bypass to defeat any M10K read-after-write
	-- hazard. Asterix dispatcher INC $2F writes value V at tick T; the next
	-- LDA ($2F),Y at tick T+N reads the pointer. With `no_rw_check` and
	-- inferred M10K, Quartus does not always insert forwarding logic — the
	-- registered read can return the previous BRAM contents until the
	-- internal write commits. Capture the most recent write addr+data;
	-- when the next read targets that addr, return the captured byte.
	-- 2026-04-27 v157: simpler RAW-hazard bypass.
	-- Capture every write into a 1-deep "last write" register. On the
	-- following cycle, when the combinational read address matches the
	-- captured write address, forward the captured data instead of the
	-- BRAM-registered read output. This is the canonical write-first
	-- emulation pattern that avoids relying on M10K read-during-write
	-- behaviour (which `no_rw_check` explicitly disables).
	signal a_we_d1   : std_logic := '0';
	signal a_addr_d1 : unsigned(15 downto 0) := (others => '0');
	signal a_din_d1  : unsigned(7 downto 0) := (others => '0');
	signal a_dout_raw : unsigned(7 downto 0);

begin

	-- Port A: CPU read/write (1-cycle registered read)
	-- Full 16-bit address used (64KB range)
	process(clk)
	begin
		if rising_edge(clk) then
			if a_we = '1' then
				ram(to_integer(a_addr)) := std_logic_vector(a_din);
			end if;
			a_dout_raw <= unsigned(ram(to_integer(a_addr)));
			-- Capture last write so the next-cycle read can forward.
			a_we_d1   <= a_we;
			a_addr_d1 <= a_addr;
			a_din_d1  <= a_din;
		end if;
	end process;

	-- Bypass: when the registered BRAM read at cycle N comes from address X,
	-- and at cycle N-1 we wrote to that same address X, the registered output
	-- may not yet reflect the write (M10K + no_rw_check). Forward the captured
	-- write data. The address compared is the address sampled at cycle N-1
	-- (a_addr_d1) versus the address sampled at cycle N-1 by the read pipeline,
	-- which is the same a_addr_d1 — so the gating is purely "did we write last
	-- cycle to the address we're now returning?". Both the write capture and
	-- the registered read use a_addr at the same edge, so a_addr_d1 *is* the
	-- address whose contents are being returned this cycle.
	a_dout <= a_din_d1 when a_we_d1 = '1'
	          else a_dout_raw;

	-- Port B: VIC-II read only (1-cycle registered read)
	-- Caller gates b_addr to $0000-$7FFF; upper half unused by VIC.
	process(clk)
	begin
		if rising_edge(clk) then
			b_dout <= unsigned(ram(to_integer(b_addr)));
		end if;
	end process;

end rtl;
