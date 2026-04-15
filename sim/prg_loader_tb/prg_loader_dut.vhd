-- prg_loader_dut.vhd
--
-- Behavioral reimplementation of the MiSTer C64 PRG-load + cache invalidation
-- path — the minimum slice required to reproduce the "bytes loaded then
-- memory seems to reset" class of bug without pulling in fpga64_sid_iec.vhd
-- or the real cpu_cache_scpu.
--
-- What is modeled (faithful to the real RTL semantics, not cycle-accurate):
--
--   1. ioctl download path:
--        first two bytes define load_addr (low, high),
--        remaining bytes increment both ioctl_load_addr and inj_end,
--        each byte produces an io_cycle write into the 64KB BRAM.
--        bank-$00 io writes fire io_bram_we_pulse, identical to c64.sv.
--
--   2. inj_meminit state machine (c64.sv ~lines 1396-1443):
--        on falling edge of ioctl_download, rewind ioctl_load_addr to 0,
--        then walk $00..$FF. $2B/$2C/$2D-$32/$AC-$AF get specific bytes,
--        all other addresses advance silently. Meminit ends at $100.
--
--   3. bram_invalidate / cache_flush:
--        bram_inval_hold = ioctl_download or inj_meminit
--        cache_flush     = rising-edge pulse of bram_inval_hold
--        bram_pgvalid clears while bram_invalidate is high
--        io_bram_we sets the target page valid bit
--
--   4. 64KB BRAM with a page-valid bitmap. A simple "CPU read port"
--        returns bram_do if the page-valid bit is set, else returns
--        the tiny cache model's data (or $00 if the cache is also cold).
--
--   5. Minimal cache stub:
--        - lookup is combinational
--        - fill happens on bus reads, but ONLY when bram_invalidate='0'
--          (this is the exact gate the real fpga64_sid_iec uses)
--        - flush on bram_invalidate rising pulse clears all valid bits
--
-- What is NOT modeled: real T65/P65C816 CPU, SDRAM pipeline, VIC/DMA slot
-- phases, write buffer, SCPU ROM overlay, SuperRAM pipeline. None of that
-- matters for a byte-level PRG-load reproducer.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.prg_loader_pkg.all;

entity prg_loader_dut is
    port (
        clk              : in  std_logic;
        reset            : in  std_logic;

        -- Bench-driven ioctl pseudo-interface (software-visible subset)
        ioctl_download   : in  std_logic;                    -- level, high while streaming
        ioctl_wr         : in  std_logic;                    -- per-byte strobe
        ioctl_addr       : in  unsigned(15 downto 0);        -- sequential byte count
        ioctl_data       : in  std_logic_vector(7 downto 0);
        ioctl_index      : in  std_logic_vector(7 downto 0); -- 'h01 = PRG

        -- Bench-driven "CPU read" port (used by scoreboard)
        cpu_rd_en        : in  std_logic;
        cpu_rd_addr      : in  unsigned(15 downto 0);
        cpu_rd_data      : out std_logic_vector(7 downto 0);
        cpu_rd_valid     : out std_logic;

        -- Status outputs for the scoreboard
        status_inj_busy  : out std_logic;
        status_inj_end   : out unsigned(15 downto 0);
        status_bram_inval : out std_logic
    );
end entity;

architecture beh of prg_loader_dut is

    -- Unified PRG-load state (matches c64.sv's single always @(posedge clk))
    signal ioctl_load_addr  : unsigned(24 downto 0) := (others => '0');
    signal inj_end          : unsigned(15 downto 0) := (others => '0');
    signal ioctl_req_wr     : std_logic := '0';
    signal io_cycle_addr    : unsigned(24 downto 0) := (others => '0');
    signal io_cycle_data    : std_logic_vector(7 downto 0) := (others => '0');
    signal io_cycle_we      : std_logic := '0';
    signal io_bram_we_pulse : std_logic := '0';
    signal inj_meminit      : std_logic := '0';
    signal inj_meminit_data : std_logic_vector(7 downto 0) := (others => '0');
    signal old_download     : std_logic := '0';
    signal old_meminit      : std_logic := '0';

    -- bram_invalidate / cache_flush glue
    signal bram_inval_hold  : std_logic := '0';
    signal bram_inval_d     : std_logic := '0';
    signal bram_inval_pulse : std_logic;
    signal cache_flush      : std_logic;

    -- 64KB BRAM + 256-entry page-valid bitmap
    type bram_array_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    signal bram : bram_array_t := (others => (others => '0'));
    type pgv_array_t is array (0 to 255) of std_logic;
    signal bram_pgvalid : pgv_array_t := (others => '0');

    -- Minimal direct-mapped cache stub
    type cache_array_t is array (0 to 255) of std_logic_vector(7 downto 0);
    type cache_valid_t is array (0 to 255) of std_logic;
    signal cache_data  : cache_array_t := (others => (others => '0'));
    signal cache_tag   : cache_array_t := (others => (others => '0'));
    signal cache_valid : cache_valid_t := (others => '0');

    signal cpu_rd_data_r  : std_logic_vector(7 downto 0) := (others => '0');
    signal cpu_rd_valid_r : std_logic := '0';

begin

    ------------------------------------------------------------------
    -- Unified PRG-load state machine (ioctl_wr handler + io_cycle
    -- consumer + inj_meminit walker). Single process → single driver
    -- for ioctl_load_addr / ioctl_req_wr, matching c64.sv.
    ------------------------------------------------------------------
    prg_load_sm : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ioctl_load_addr  <= (others => '0');
                inj_end          <= (others => '0');
                ioctl_req_wr     <= '0';
                io_cycle_we      <= '0';
                io_bram_we_pulse <= '0';
                inj_meminit      <= '0';
                inj_meminit_data <= (others => '0');
                old_download     <= '0';
                old_meminit      <= '0';
            else
                -- Defaults (pulses clear each clock)
                io_cycle_we      <= '0';
                io_bram_we_pulse <= '0';

                -- Edge trackers (registered one-clock delays)
                old_download <= ioctl_download;
                old_meminit  <= inj_meminit;

                -- ~~ io_cycle consumer ~~
                -- Collapse io_cycle onto every clock: as soon as ioctl_req_wr
                -- is set, the next rising edge performs the write and
                -- advances the load address. This matches the software-
                -- visible effect of the real io_cycle slot; the scheduling
                -- detail (DMA0..VIC3 etc) is irrelevant to the meminit/cache
                -- race we're reproducing here.
                if ioctl_req_wr = '1' then
                    io_cycle_addr <= ioctl_load_addr;
                    if inj_meminit = '1' then
                        io_cycle_data <= inj_meminit_data;
                    else
                        io_cycle_data <= ioctl_data;
                    end if;
                    io_cycle_we <= '1';
                    if ioctl_load_addr(24 downto 16) = "000000000" then
                        io_bram_we_pulse <= '1';
                    end if;
                    ioctl_load_addr <= ioctl_load_addr + 1;
                    ioctl_req_wr    <= '0';
                end if;

                -- ~~ host ioctl_wr handler (payload path) ~~
                if ioctl_wr = '1' and ioctl_index = x"01" and ioctl_download = '1' then
                    if ioctl_addr = 0 then
                        ioctl_load_addr(7 downto 0)  <= unsigned(ioctl_data);
                        inj_end(7 downto 0)          <= unsigned(ioctl_data);
                    elsif ioctl_addr = 1 then
                        ioctl_load_addr(15 downto 8) <= unsigned(ioctl_data);
                        inj_end(15 downto 8)         <= unsigned(ioctl_data);
                    else
                        ioctl_req_wr <= '1';
                        inj_end      <= inj_end + 1;
                    end if;
                end if;

                -- ~~ inj_meminit trigger (falling edge of ioctl_download) ~~
                if old_download = '1' and ioctl_download = '0'
                   and ioctl_index = x"01" and inj_meminit = '0' then
                    inj_meminit     <= '1';
                    ioctl_load_addr <= (others => '0');
                end if;

                -- ~~ inj_meminit walker ~~
                if inj_meminit = '1' and ioctl_req_wr = '0' then
                    if ioctl_load_addr = to_unsigned(256, 25) then
                        inj_meminit <= '0';
                    else
                        case to_integer(ioctl_load_addr(15 downto 0)) is
                            when 16#2B# =>
                                inj_meminit_data <= x"01";
                                ioctl_req_wr     <= '1';
                            when 16#2C# =>
                                inj_meminit_data <= x"08";
                                ioctl_req_wr     <= '1';
                            when 16#AC# | 16#AD# =>
                                inj_meminit_data <= x"00";
                                ioctl_req_wr     <= '1';
                            when 16#2D# | 16#2F# | 16#31# | 16#AE# =>
                                inj_meminit_data <= std_logic_vector(inj_end(7 downto 0));
                                ioctl_req_wr     <= '1';
                            when 16#2E# | 16#30# | 16#32# | 16#AF# =>
                                inj_meminit_data <= std_logic_vector(inj_end(15 downto 8));
                                ioctl_req_wr     <= '1';
                            when others =>
                                ioctl_load_addr <= ioctl_load_addr + 1;
                        end case;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- bram_invalidate + cache_flush glue (fpga64_sid_iec.vhd semantics)
    ------------------------------------------------------------------
    inval_sm : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                bram_inval_hold <= '0';
                bram_inval_d    <= '0';
            else
                bram_inval_hold <= ioctl_download or inj_meminit;
                bram_inval_d    <= bram_inval_hold;
            end if;
        end if;
    end process;

    bram_inval_pulse <= bram_inval_hold and not bram_inval_d;
    cache_flush      <= reset or bram_inval_pulse;

    ------------------------------------------------------------------
    -- Unified memory process: BRAM data array + per-page valid bitmap
    -- + cache fill + CPU read port. Combined into one process so every
    -- signal has exactly one driver (VHDL does not allow multi-driver
    -- resolution for std_logic without a resolver function).
    --
    -- Semantics faithful to fpga64_sid_iec.vhd:
    --
    --   1. BRAM data: io_bram_we_pulse writes are ACCEPTED even during
    --      bram_invalidate (matches the real bram_port_a_we = io_bram_we
    --      OR bram_we equation which is not gated by the invalidate).
    --
    --   2. bram_pgvalid priority chain:
    --        bram_invalidate  -> clear all
    --        else io_bram_we  -> set single page
    --      This mirrors the real if/elsif priority in the page-valid
    --      process. So during the invalidation window, pgvalid stays 0.
    --
    --   3. Cache fill: on a CPU read outside the invalidation window,
    --      capture the BRAM byte into the cache (the `not bram_invalidate`
    --      gate is the exact bug this bench was built to verify). If the
    --      bug is ever reintroduced, a cold read fired during the load
    --      window would latch a pre-load byte (stale $00) into the cache,
    --      and the rising-edge cache_flush pulse at the start of the
    --      NEXT download would need to catch it. Scenario S3 exercises
    --      this path.
    --
    --   4. CPU read mux: cache hit (tag match) wins; else the BRAM byte
    --      is returned. The real system's BRAM-hit vs SDRAM-fill split
    --      does not matter here because the BRAM cells already hold the
    --      correct data (io_bram_we wrote them unconditionally).
    --      Outside the invalidate window, a BRAM-path read retroactively
    --      sets pgvalid to mimic the SDRAM fill path also marking the
    --      page live.
    ------------------------------------------------------------------
    mem_sm : process(clk)
        variable pg  : integer range 0 to 255;
        variable idx : integer range 0 to 255;
        variable tag : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                bram_pgvalid   <= (others => '0');
                cache_valid    <= (others => '0');
                cpu_rd_valid_r <= '0';
            else
                -- bram_pgvalid priority chain
                if bram_inval_hold = '1' then
                    for i in 0 to 255 loop
                        bram_pgvalid(i) <= '0';
                    end loop;
                elsif io_bram_we_pulse = '1' then
                    pg := to_integer(io_cycle_addr(15 downto 8));
                    bram_pgvalid(pg) <= '1';
                end if;

                -- BRAM data array: unconditional write on io_bram_we
                if io_bram_we_pulse = '1' then
                    bram(to_integer(io_cycle_addr(15 downto 0))) <= io_cycle_data;
                end if;

                -- Cache flush
                if cache_flush = '1' then
                    for i in 0 to 255 loop
                        cache_valid(i) <= '0';
                    end loop;
                end if;

                -- CPU read port + cache fill
                cpu_rd_valid_r <= '0';
                if cpu_rd_en = '1' then
                    idx := to_integer(cpu_rd_addr(7 downto 0));
                    tag := std_logic_vector(cpu_rd_addr(15 downto 8));

                    -- Cache hit: tag match + valid
                    if cache_valid(idx) = '1' and cache_tag(idx) = tag then
                        cpu_rd_data_r <= cache_data(idx);
                    else
                        -- BRAM (always holds the correct bytes)
                        cpu_rd_data_r <= bram(to_integer(cpu_rd_addr(15 downto 0)));
                        -- Retro-fill pgvalid outside the invalidate window
                        -- (proxies the SDRAM fill path bram_we update).
                        pg := to_integer(cpu_rd_addr(15 downto 8));
                        if bram_inval_hold = '0' and bram_pgvalid(pg) = '0' then
                            bram_pgvalid(pg) <= '1';
                        end if;

                        -- Fill cache on miss, but ONLY outside the
                        -- invalidate window. This is the exact gate the
                        -- real cache_fill_we uses.
                        if bram_inval_hold = '0' then
                            cache_data(idx)  <= bram(to_integer(cpu_rd_addr(15 downto 0)));
                            cache_tag(idx)   <= tag;
                            cache_valid(idx) <= '1';
                        end if;
                    end if;
                    cpu_rd_valid_r <= '1';
                end if;
            end if;
        end if;
    end process;

    cpu_rd_data       <= cpu_rd_data_r;
    cpu_rd_valid      <= cpu_rd_valid_r;
    status_inj_busy   <= inj_meminit;
    status_inj_end    <= inj_end;
    status_bram_inval <= bram_inval_hold;

end architecture;
