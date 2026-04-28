-- cpu_cache.vhd — 8KB direct-mapped BRAM cache for CPU acceleration
--
-- Sits between the CPU and the SDRAM path. On a hit, provides data in 1 cycle
-- (combinational tag check via MLAB + registered M10K data read). On a miss,
-- the CPU uses the normal SDRAM slow path. Cache fills opportunistically: every
-- SDRAM read for a cacheable address populates the corresponding cache byte.
--
-- Phase 2: Write-through with 16-entry write buffer. CPU writes to cacheable
-- addresses are absorbed immediately (1-cycle), updating the cache BRAM and
-- pushing addr+data to the write buffer. The write buffer drains to SDRAM
-- during freed CPU slots when the CPU runs from cache.
--
-- Organization:
--   1024 lines x 8 bytes = 8KB data (M10K block RAM)
--   1024 tags x 11 bits  = tag storage (MLAB / distributed RAM)
--   1024 x 8 valid bits  = per-byte valid (separate MLAB array)
--   16-entry write buffer = register-based FIFO (addr16 + data8)
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
	cpu_we    : in  std_logic;        -- CPU write enable
	cpu_do    : in  unsigned(7 downto 0);  -- CPU data output (for writes)

	-- Cache output (active 1 cycle after address presented)
	cache_di  : out unsigned(7 downto 0);  -- data to CPU from cache
	cache_hit : out std_logic;             -- combinational: tag match + byte valid (read) or WB not full (write)

	-- Fill interface (from SDRAM read-back)
	fill_data : in  unsigned(7 downto 0);  -- SDRAM data byte
	fill_we   : in  std_logic;             -- write pulse (enableCpu)
	fill_addr : in  unsigned(15 downto 0); -- address of the byte being filled
	fill_bank : in  unsigned(7 downto 0);  -- bank of the byte being filled

	-- Write buffer drain interface
	wb_pending : out std_logic;            -- write buffer has entries to drain
	wb_addr    : out unsigned(15 downto 0); -- next write address
	wb_data    : out unsigned(7 downto 0);  -- next write data
	wb_ack     : in  std_logic;            -- SDRAM accepted write, pop entry

	-- Control
	flush     : in  std_logic;             -- invalidate entire cache
	cpu_en    : in  std_logic;             -- CPU clock enable (1-cycle pulse when CPU steps)
	wb_enable : in  std_logic;             -- master enable for write-buffer absorption (cacheable_wr)

	-- Same-line detection (wide cache line optimization)
	same_line : out std_logic;             -- current access is same cache line as previous hit

	-- Debug
	dbg_flush_active : out std_logic;      -- cache is flushing (2048-cycle sweep)
	dbg_tag_match    : out std_logic       -- tag matches current address
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

	-- ── Data storage (M10K — 8 parallel 1024x8 banks) ──────────────
	-- 8 separate 1024x8 RAMs, one per byte lane. All read simultaneously
	-- to produce a 64-bit cache line word. Writes target only the specific
	-- byte lane. This ensures clean M10K inference (no read-modify-write).
	type bank_array_t is array(0 to 1023) of unsigned(7 downto 0);
	shared variable data_bank0 : bank_array_t;
	shared variable data_bank1 : bank_array_t;
	shared variable data_bank2 : bank_array_t;
	shared variable data_bank3 : bank_array_t;
	shared variable data_bank4 : bank_array_t;
	shared variable data_bank5 : bank_array_t;
	shared variable data_bank6 : bank_array_t;
	shared variable data_bank7 : bank_array_t;

	-- ── Write buffer (register-based FIFO) ──────────────────────────
	-- 16 entries × (16-bit addr + 8-bit data) = 384 registers
	type wb_entry_t is record
		addr : unsigned(15 downto 0);
		data : unsigned(7 downto 0);
	end record;
	type wb_array_t is array(0 to 15) of wb_entry_t;
	signal wb_fifo  : wb_array_t;
	signal wb_head  : unsigned(3 downto 0) := (others => '0');  -- write pointer
	signal wb_tail  : unsigned(3 downto 0) := (others => '0');  -- read pointer
	signal wb_count : unsigned(4 downto 0) := (others => '0');  -- entry count
	signal wb_full_i  : std_logic;
	signal wb_empty_i : std_logic;

	-- ── Internal signals ────────────────────────────────────────────
	signal line_index    : unsigned(9 downto 0);
	signal byte_offset   : unsigned(2 downto 0);
	signal expected_tag  : unsigned(10 downto 0);

	signal cacheable_addr : std_logic; -- address is in cacheable space

	-- ── Wide cache line signals ─────────────────────────────────────
	signal line_word     : std_logic_vector(63 downto 0);  -- M10K output (registered)
	signal prev_line     : unsigned(9 downto 0) := (others => '1'); -- previous read line
	signal prev_tag      : unsigned(10 downto 0) := (others => '1'); -- previous read tag
	signal same_line_i   : std_logic;  -- internal same-line flag
	signal cacheable_rd  : std_logic;  -- read cacheability
	signal cacheable_wr  : std_logic;  -- write cacheability
	signal invalidate_wr : std_logic;  -- non-bank-$00 write: invalidate cached line
	signal tag_match     : std_logic;
	signal byte_valid    : std_logic;

	-- ── Flush state machine ─────────────────────────────────────────
	signal flush_active  : std_logic := '0';
	signal flush_ctr     : unsigned(9 downto 0) := (others => '0');

	-- ── CPU write capture (registered for BRAM write port) ──────────
	signal cpu_wr_pending : std_logic := '0';
	signal cpu_wr_addr    : unsigned(12 downto 0) := (others => '0');
	signal cpu_wr_data    : unsigned(7 downto 0) := (others => '0');
	signal cpu_wr_line    : unsigned(9 downto 0) := (others => '0');
	signal cpu_wr_off     : unsigned(2 downto 0) := (others => '0');
	signal cpu_wr_tag     : unsigned(10 downto 0) := (others => '0');

begin

	-- ── Debug output ───────────────────────────────────────────────
	dbg_flush_active <= flush_active;
	dbg_tag_match    <= tag_match;

	-- ── Address decomposition ───────────────────────────────────────
	line_index   <= cpu_addr(12 downto 3);
	byte_offset  <= cpu_addr(2 downto 0);
	expected_tag <= cpu_bank(7 downto 0) & cpu_addr(15 downto 13);

	-- ── Same-line detection (wide cache line optimization) ──────────
	-- When the current access targets the same cache line as the previous
	-- hit, the 64-bit word is already in line_word — no M10K read needed.
	same_line_i <= '1' when line_index = prev_line and expected_tag = prev_tag
	               else '0';
	same_line   <= same_line_i;

	-- ── Write buffer status ─────────────────────────────────────────
	wb_full_i  <= '1' when wb_count = 16 else '0';
	wb_empty_i <= '1' when wb_count = 0  else '0';
	wb_pending <= not wb_empty_i;
	wb_addr    <= wb_fifo(to_integer(wb_tail)).addr;
	wb_data    <= wb_fifo(to_integer(wb_tail)).data;

	-- ── Cacheability (combinational) ────────────────────────────────
	-- Address-based check, independent of buslogic cs_io/cs_ram signals.
	-- buslogic outputs reflect VIC's address during non-CPU slots (cpuHasBus='0'),
	-- which would make I/O accesses appear cacheable when the cache fires
	-- during EXT/DMA/VIC slots.  Use pure address decode instead.
	--
	--   Bank $00: all addresses except I/O space ($D000-$DFFF).
	--     Cache fills from dataToCpu (buslogic output), so the cache stores
	--     whatever the CPU actually reads — RAM, ROM, or cartridge data.
	--     Bank-switch flush (cpuIO(2:0) changes) ensures coherency on
	--     ROM/RAM visibility transitions.
	--   Banks $01-$EF: SuperRAM — all addresses are plain RAM.
	--   Banks $F0-$FF: SuperCPU ROM served from BRAM — no caching needed.
	cacheable_addr <= '1' when (cpu_bank = x"00"
	                            and cpu_addr(15 downto 12) /= x"D")                 -- all except $D000-$DFFF
	                       or  (cpu_bank > x"00" and cpu_bank < x"F0")               -- SuperRAM
	                  else '0';

	-- Read: cacheable address, not writing, not flushing
	cacheable_rd <= '1' when enable = '1'
	                    and cacheable_addr = '1'
	                    and cpu_we = '0'
	                    and flush_active = '0'
	               else '0';

	-- 2026-04-28: Write hits stay DISABLED. Two attempts to flip on:
	--   v159: `cacheable_wr <= '1' when ... wb_full='0'` (no SCPU gate).
	--         Black-screened vanilla BASIC.
	--   v161: same gated on `wb_enable=supercpu_en`. Also black-screened
	--         (default OSD has SCPU on, so the gate didn't change anything
	--         for the failing case).
	-- Both attempts hand `cache_hit=1` to the SDRAM-pipeline cancel logic
	-- in fpga64_sid_iec.vhd, which in turn suppresses `enableCpu` and
	-- `cpu_cyc_s` for one cycle. `enableCpu_816` does include
	-- `cache_hit_d1` as a substitute, but it is gated by `not at_cpucd`,
	-- so the substitute mis-fires during CPUA-CPUD — exactly the slot
	-- where `wb_drain_active` also hijacks `ramAddr/ramDout/ramWE`. Net
	-- effect: the CPU's CPUC SDRAM write slot is consumed by the drain
	-- and the new write neither lands in `c64_ram64k` nor in the FIFO's
	-- intended `wb_addr`. KERNAL boot loses critical RAM init writes.
	-- Next attempt must either: (a) suppress wb_drain_active for one
	-- cycle after a fresh push so the new write goes through systemAddr
	-- normally, or (b) defer cache_hit absorption to CPUE-CPU9 (outside
	-- the at_cpucd window) so the cancel doesn't race the write.
	-- The `wb_enable` port is preserved so this gate stays per-mode-controlled.
	cacheable_wr <= '0';

	-- Write invalidation: when CPU writes to ANY cacheable address, invalidate
	-- the cached byte if the tag matches. This covers both bank-$00 writes
	-- (where ROM/RAM aliasing could cause stale cache data) and SuperRAM
	-- writes (banks $01-$EF). Writes go to SDRAM via the normal path.
	invalidate_wr <= '1' when enable = '1'
	                      and cacheable_addr = '1'
	                      and cpu_we = '1'
	                      and cpu_en = '1'
	                      and flush_active = '0'
	                 else '0';

	-- ── Tag check (combinational — MLAB async read) ─────────────────
	-- Compare stored tag with expected, check per-byte valid bit
	tag_match  <= '1' when tag_mem(to_integer(line_index)) = expected_tag
	              else '0';
	byte_valid <= valid_mem(to_integer(line_index))(to_integer(byte_offset));

	-- ── Cache hit (combinational) ───────────────────────────────────
	-- Read hit: tag match + byte valid (data available from BRAM next cycle)
	-- Write hit: write buffer can absorb (CPU doesn't wait for SDRAM)
	cache_hit  <= (cacheable_rd and tag_match and byte_valid) or cacheable_wr;

	-- ── Data BRAM (8 parallel M10K banks — read + write) ────────────
	-- Read port: all 8 banks read simultaneously, producing 64-bit line word.
	-- Track previous line for same-line detection.
	process(clk)
	begin
		if rising_edge(clk) then
			line_word( 7 downto  0) <= std_logic_vector(data_bank0(to_integer(line_index)));
			line_word(15 downto  8) <= std_logic_vector(data_bank1(to_integer(line_index)));
			line_word(23 downto 16) <= std_logic_vector(data_bank2(to_integer(line_index)));
			line_word(31 downto 24) <= std_logic_vector(data_bank3(to_integer(line_index)));
			line_word(39 downto 32) <= std_logic_vector(data_bank4(to_integer(line_index)));
			line_word(47 downto 40) <= std_logic_vector(data_bank5(to_integer(line_index)));
			line_word(55 downto 48) <= std_logic_vector(data_bank6(to_integer(line_index)));
			line_word(63 downto 56) <= std_logic_vector(data_bank7(to_integer(line_index)));
			-- Track which line we just read for same-line detection
			prev_line <= line_index;
			prev_tag  <= expected_tag;
		end if;
	end process;

	-- Byte-select MUX: pick the requested byte from the 64-bit line word.
	-- For same-line accesses, line_word already holds the correct data.
	process(line_word, byte_offset)
	begin
		case byte_offset is
			when "000" => cache_di <= unsigned(line_word( 7 downto  0));
			when "001" => cache_di <= unsigned(line_word(15 downto  8));
			when "010" => cache_di <= unsigned(line_word(23 downto 16));
			when "011" => cache_di <= unsigned(line_word(31 downto 24));
			when "100" => cache_di <= unsigned(line_word(39 downto 32));
			when "101" => cache_di <= unsigned(line_word(47 downto 40));
			when "110" => cache_di <= unsigned(line_word(55 downto 48));
			when "111" => cache_di <= unsigned(line_word(63 downto 56));
			when others => cache_di <= (others => '0');
		end case;
	end process;

	-- Write port: write to the specific byte bank only (no read-modify-write).
	-- CPU write takes priority over fill when both active.
	process(clk)
	variable wr_line : unsigned(9 downto 0);
	variable wr_off  : unsigned(2 downto 0);
	variable wr_data : unsigned(7 downto 0);
	variable wr_en   : std_logic;
	begin
		if rising_edge(clk) then
			wr_en := '0';
			if cpu_wr_pending = '1' then
				wr_line := cpu_wr_line;
				wr_off  := cpu_wr_off;
				wr_data := cpu_wr_data;
				wr_en   := '1';
			elsif fill_we = '1' and flush_active = '0' then
				wr_line := fill_addr(12 downto 3);
				wr_off  := fill_addr(2 downto 0);
				wr_data := fill_data;
				wr_en   := '1';
			end if;

			if wr_en = '1' then
				case wr_off is
					when "000" => data_bank0(to_integer(wr_line)) := wr_data;
					when "001" => data_bank1(to_integer(wr_line)) := wr_data;
					when "010" => data_bank2(to_integer(wr_line)) := wr_data;
					when "011" => data_bank3(to_integer(wr_line)) := wr_data;
					when "100" => data_bank4(to_integer(wr_line)) := wr_data;
					when "101" => data_bank5(to_integer(wr_line)) := wr_data;
					when "110" => data_bank6(to_integer(wr_line)) := wr_data;
					when "111" => data_bank7(to_integer(wr_line)) := wr_data;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	-- ── Tag/valid write logic + flush counter + write buffer ─────────
	process(clk)
	variable fill_line : unsigned(9 downto 0);
	variable fill_off  : unsigned(2 downto 0);
	variable ftag      : unsigned(10 downto 0);
	variable new_valid : std_logic_vector(7 downto 0);
	begin
		if rising_edge(clk) then
			-- Default: clear CPU write pending (1-cycle pulse)
			cpu_wr_pending <= '0';

			-- ── Flush state machine ──────────────────────────────
			if flush = '1' and flush_active = '0' then
				flush_active <= '1';
				flush_ctr    <= (others => '0');
				-- Also reset write buffer on flush
				wb_head  <= (others => '0');
				wb_tail  <= (others => '0');
				wb_count <= (others => '0');
			end if;

			if flush_active = '1' then
				-- Clear valid bits for current flush counter entry
				valid_mem(to_integer(flush_ctr)) <= (others => '0');

				if flush_ctr = 1023 then
					flush_active <= '0';
				else
					flush_ctr <= flush_ctr + 1;
				end if;

			else
				-- ── CPU write path (write-through + write-allocate) ──
				if cacheable_wr = '1' then
					-- Capture write for BRAM update (1-cycle delayed write)
					cpu_wr_pending <= '1';
					cpu_wr_addr    <= line_index & byte_offset;
					cpu_wr_data    <= cpu_do;
					cpu_wr_line    <= line_index;
					cpu_wr_off     <= byte_offset;
					cpu_wr_tag     <= expected_tag;

					-- Update tag/valid for write-allocate
					if tag_match = '1' then
						-- Same tag: set valid bit for written byte
						new_valid := valid_mem(to_integer(line_index));
						new_valid(to_integer(byte_offset)) := '1';
						valid_mem(to_integer(line_index)) <= new_valid;
					else
						-- Different tag: evict line, allocate with this byte
						tag_mem(to_integer(line_index)) <= expected_tag;
						new_valid := (others => '0');
						new_valid(to_integer(byte_offset)) := '1';
						valid_mem(to_integer(line_index)) <= new_valid;
					end if;

					-- Push to write buffer
					wb_fifo(to_integer(wb_head)).addr <= cpu_addr;
					wb_fifo(to_integer(wb_head)).data <= cpu_do;
					wb_head <= wb_head + 1;

				elsif invalidate_wr = '1' and tag_match = '1' then
					-- ── Write invalidation ──
					-- Invalidate cached byte when a write targets a
					-- matching line. Prevents stale reads after writes.
					new_valid := valid_mem(to_integer(line_index));
					new_valid(to_integer(byte_offset)) := '0';
					valid_mem(to_integer(line_index)) <= new_valid;

				elsif fill_we = '1' then
					-- ── Fill logic: write SDRAM data into cache ──────
					fill_line := fill_addr(12 downto 3);
					fill_off  := fill_addr(2 downto 0);
					ftag      := fill_bank(7 downto 0) & fill_addr(15 downto 13);

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
				end if;

				-- ── Write buffer drain (independent of fill/write) ──
				if wb_ack = '1' and wb_empty_i = '0' then
					wb_tail <= wb_tail + 1;
				end if;
			end if;

			-- ── Write buffer count tracking ─────────────────────
			-- Must handle simultaneous push + drain
			if flush = '1' and flush_active = '0' then
				-- Count reset handled above
				null;
			elsif cacheable_wr = '1' and wb_ack = '1' and wb_empty_i = '0' and flush_active = '0' then
				-- Simultaneous push and drain: count unchanged
				null;
			elsif cacheable_wr = '1' and flush_active = '0' then
				-- Push only
				wb_count <= wb_count + 1;
			elsif wb_ack = '1' and wb_empty_i = '0' and flush_active = '0' then
				-- Drain only
				wb_count <= wb_count - 1;
			end if;
		end if;
	end process;

end rtl;
