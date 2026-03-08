-- cpu_cache.vhd — 8KB direct-mapped BRAM cache for CPU acceleration
--
-- Sits between the CPU and the SDRAM path. On a hit, provides data in 1 cycle
-- (combinational tag check via MLAB + registered M10K data read). On a miss,
-- the CPU uses the normal SDRAM slow path. Cache fills opportunistically: every
-- SDRAM read for a cacheable address populates the corresponding cache byte.
--
-- Organization:
--   1024 lines x 8 bytes = 8KB data (M10K block RAM)
--   1024 tags x 11 bits  = tag storage (MLAB / distributed RAM)
--   1024 x 8 valid bits  = per-byte valid (separate MLAB array)
--
-- Address mapping (24-bit physical address):
--   [23:16] = bank byte     } together form the 11-bit tag
--   [15:13] = addr high     }
--   [12:3]  = 10-bit line index (1024 lines)
--   [2:0]   = 3-bit byte offset within line
--
-- Flush uses a counter (1024 cycles = 32us) instead of bulk write,
-- allowing Quartus to infer MLAB for tag/valid storage.
--
-- I/O space ($D000-$DFFF in bank $00) is never cached.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache is
port (
	clk       : in  std_logic;
	reset     : in  std_logic;
	enable    : in  std_logic;        -- master enable (SuperCPU / turbo active)

	-- CPU-side interface
	cpu_addr  : in  unsigned(15 downto 0);
	cpu_bank  : in  unsigned(7 downto 0);
	cpu_we    : in  std_logic;        -- CPU write enable (uncacheable in Phase 1)

	-- Cache output (active 1 cycle after address presented)
	cache_di  : out unsigned(7 downto 0);  -- data to CPU from cache
	cache_hit : out std_logic;             -- combinational: tag match + byte valid

	-- Fill interface (from SDRAM read-back)
	fill_data : in  unsigned(7 downto 0);  -- SDRAM data byte
	fill_we   : in  std_logic;             -- write pulse (enableCpu)
	fill_addr : in  unsigned(15 downto 0); -- address of the byte being filled
	fill_bank : in  unsigned(7 downto 0);  -- bank of the byte being filled

	-- Control
	flush     : in  std_logic;             -- invalidate entire cache
	cs_io     : in  std_logic;             -- '1' when address is I/O space
	cs_ram    : in  std_logic              -- '1' when address is RAM
);
end cpu_cache;

architecture rtl of cpu_cache is

	-- ── Tag storage (MLAB — combinational read) ─────────────────────
	-- 11-bit tag: bank(8) & addr(15:13)(3) = 11 bits
	-- Flat array for clean MLAB inference (no records).
	type tag_array_t is array(0 to 1023) of unsigned(10 downto 0);
	signal tag_mem : tag_array_t;
	attribute ramstyle : string;
	attribute ramstyle of tag_mem : signal is "MLAB, no_rw_check";

	-- ── Valid-bit storage (MLAB — combinational read) ───────────────
	-- 8 valid bits per line, stored as std_logic_vector(7 downto 0).
	type valid_array_t is array(0 to 1023) of std_logic_vector(7 downto 0);
	signal valid_mem : valid_array_t;
	attribute ramstyle of valid_mem : signal is "MLAB, no_rw_check";

	-- ── Data storage (M10K — registered read) ───────────────────────
	-- 8192 bytes addressed by {line_index[9:0], byte_offset[2:0]} = 13 bits
	type data_array_t is array(0 to 8191) of unsigned(7 downto 0);
	shared variable data_ram : data_array_t;

	-- ── Internal signals ────────────────────────────────────────────
	signal line_index    : unsigned(9 downto 0);
	signal byte_offset   : unsigned(2 downto 0);
	signal expected_tag  : unsigned(10 downto 0);

	signal data_addr     : unsigned(12 downto 0);
	signal cacheable_i   : std_logic;
	signal tag_match     : std_logic;
	signal byte_valid    : std_logic;

	-- ── Flush state machine ─────────────────────────────────────────
	signal flush_active  : std_logic := '0';
	signal flush_ctr     : unsigned(9 downto 0) := (others => '0');

begin

	-- ── Address decomposition ───────────────────────────────────────
	line_index   <= cpu_addr(12 downto 3);
	byte_offset  <= cpu_addr(2 downto 0);
	expected_tag <= cpu_bank(7 downto 0) & cpu_addr(15 downto 13);

	data_addr    <= line_index & byte_offset;

	-- ── Cacheability (combinational) ────────────────────────────────
	-- Phase 1: bank $00, RAM space, not I/O, reads only
	cacheable_i <= '1' when enable = '1'
	                    and cpu_bank = x"00"
	                    and cs_ram = '1'
	                    and cs_io = '0'
	                    and cpu_we = '0'
	                    and flush_active = '0'
	               else '0';

	-- ── Tag check (combinational — MLAB async read) ─────────────────
	-- Compare stored tag with expected, check per-byte valid bit
	tag_match  <= '1' when tag_mem(to_integer(line_index)) = expected_tag
	              else '0';
	byte_valid <= valid_mem(to_integer(line_index))(to_integer(byte_offset));

	cache_hit  <= cacheable_i and tag_match and byte_valid;

	-- ── Data BRAM read (registered — 1 cycle latency) ───────────────
	-- The read is initiated by the address presented this cycle;
	-- cache_di is valid on the NEXT cycle (aligned with cache_hit_d1
	-- in the parent module).
	process(clk)
	begin
		if rising_edge(clk) then
			cache_di <= data_ram(to_integer(data_addr));
		end if;
	end process;

	-- ── Tag/valid write logic + flush counter ────────────────────────
	-- Single write port per array per clock: either flush OR fill.
	-- Counter-based flush clears one entry per cycle (1024 cycles total),
	-- enabling Quartus to infer MLAB instead of registers.
	process(clk)
	variable fill_line : unsigned(9 downto 0);
	variable fill_off  : unsigned(2 downto 0);
	variable ftag      : unsigned(10 downto 0);
	variable fill_da   : unsigned(12 downto 0);
	variable new_valid : std_logic_vector(7 downto 0);
	begin
		if rising_edge(clk) then
			-- ── Flush state machine ──────────────────────────────
			if flush = '1' and flush_active = '0' then
				-- Start flush: will clear one entry per cycle
				flush_active <= '1';
				flush_ctr    <= (others => '0');
			end if;

			if flush_active = '1' then
				-- Clear valid bits for current flush counter entry
				valid_mem(to_integer(flush_ctr)) <= (others => '0');

				if flush_ctr = 1023 then
					flush_active <= '0';
				else
					flush_ctr <= flush_ctr + 1;
				end if;

			elsif fill_we = '1' then
				-- ── Fill logic: write SDRAM data into cache ──────
				fill_line := fill_addr(12 downto 3);
				fill_off  := fill_addr(2 downto 0);
				ftag      := fill_bank(7 downto 0) & fill_addr(15 downto 13);
				fill_da   := fill_line & fill_off;

				if tag_mem(to_integer(fill_line)) = ftag then
					-- Same tag: just set the valid bit for this byte
					new_valid := valid_mem(to_integer(fill_line));
					new_valid(to_integer(fill_off)) := '1';
					valid_mem(to_integer(fill_line)) <= new_valid;
				else
					-- Different tag: evict line, start fresh with this byte
					tag_mem(to_integer(fill_line)) <= ftag;
					new_valid := (others => '0');
					new_valid(to_integer(fill_off)) := '1';
					valid_mem(to_integer(fill_line)) <= new_valid;
				end if;

				-- Write data byte into BRAM
				data_ram(to_integer(fill_da)) := fill_data;
			end if;
		end if;
	end process;

end rtl;
