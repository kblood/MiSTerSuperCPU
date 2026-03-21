-- reu_sdram_tb.vhd — Testbench for REU DMA SDRAM path
--
-- Simulates the exact signal chain that fails on hardware:
-- reu_ram_ce (clk_sys 32MHz) → SDRAM ce (clk64 64MHz) → write/read cycle
--
-- Tests:
-- 1. Single SDRAM write via cart_ce (CPU path) — should work
-- 2. Single SDRAM write via reu_ram_ce (ext_cycle path) — may fail
-- 3. Compare timing of both paths

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity reu_sdram_tb is
end reu_sdram_tb;

architecture sim of reu_sdram_tb is
    -- Clocks
    signal clk32 : std_logic := '0';
    signal clk64 : std_logic := '0';

    -- SDRAM interface (simplified)
    signal sdram_ce   : std_logic := '0';
    signal sdram_addr : std_logic_vector(24 downto 0) := (others => '0');
    signal sdram_we   : std_logic := '0';
    signal sdram_din  : std_logic_vector(7 downto 0) := (others => '0');
    signal sdram_dout : std_logic_vector(7 downto 0) := (others => '0');

    -- Bus cycle simulation
    signal cycle_count : integer := 0;
    signal sys_cycle   : integer range 0 to 31 := 0;

    -- ext_cycle (DMA0-DMA3 = cycles 4-7)
    signal ext_cycle : std_logic := '0';
    signal ext_cycle_d : std_logic := '0';

    -- REU signals
    signal dma_req : std_logic := '0';
    signal reu_ram_ce : std_logic := '0';
    signal reu_ram_addr : std_logic_vector(24 downto 0) := (others => '0');
    signal reu_ram_we : std_logic := '0';
    signal reu_ram_dout : std_logic_vector(7 downto 0) := (others => '0');

    -- CPU/cart signals
    signal cart_ce : std_logic := '0';
    signal cart_addr : std_logic_vector(24 downto 0) := (others => '0');
    signal cart_we : std_logic := '0';
    signal cart_din : std_logic_vector(7 downto 0) := (others => '0');

    -- io_cycle
    signal io_cycle : std_logic := '0';

    -- SDRAM model
    type ram_t is array(0 to 255) of std_logic_vector(7 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    -- SDRAM state machine (simplified from sdram.v)
    signal q : unsigned(2 downto 0) := "000";
    signal last_ce : std_logic := '0';
    signal last_refresh : std_logic := '0';
    signal sd_wr : std_logic := '0';
    signal sd_addr_lat : unsigned(7 downto 0) := (others => '0');
    signal sd_data_lat : std_logic_vector(7 downto 0) := (others => '0');

    -- refresh
    signal refresh : std_logic := '0';

    -- Test results
    signal test1_pass : boolean := false;
    signal test2_pass : boolean := false;

begin
    -- Clock generation: 32MHz and 64MHz (2:1 ratio)
    clk32 <= not clk32 after 15625 ps; -- 32MHz = 31.25ns period
    clk64 <= not clk64 after 7812 ps;  -- 64MHz = 15.625ns period

    -- System cycle counter (0-31, advances on clk32 rising edge)
    process(clk32)
    begin
        if rising_edge(clk32) then
            if sys_cycle = 31 then
                sys_cycle <= 0;
            else
                sys_cycle <= sys_cycle + 1;
            end if;
            cycle_count <= cycle_count + 1;
        end if;
    end process;

    -- ext_cycle: active during DMA slots (cycles 4-7)
    ext_cycle <= '1' when (sys_cycle >= 4 and sys_cycle <= 7) else '0';

    -- io_cycle: active during EXT slots (cycles 0-3, 8-11)
    io_cycle <= '1' when (sys_cycle >= 0 and sys_cycle <= 3) or
                         (sys_cycle >= 8 and sys_cycle <= 11) else '0';

    -- reu_ram_ce: rising edge of ext_cycle when dma_req active
    process(clk32)
    begin
        if rising_edge(clk32) then
            ext_cycle_d <= ext_cycle;
        end if;
    end process;
    reu_ram_ce <= (not ext_cycle_d) and ext_cycle and dma_req;

    -- SDRAM mux (matches c64.sv)
    sdram_ce <= reu_ram_ce when (io_cycle = '0' and ext_cycle = '1') else
                cart_ce    when (io_cycle = '0') else
                '0';
    sdram_addr <= reu_ram_addr when (io_cycle = '0' and ext_cycle = '1') else
                 cart_addr;
    sdram_we <= reu_ram_we when (io_cycle = '0' and ext_cycle = '1') else
               cart_we;
    sdram_din <= reu_ram_dout when (io_cycle = '0' and ext_cycle = '1') else
                cart_din;

    -- Simplified SDRAM model (matches sdram.v behavior)
    process(clk64)
    begin
        if rising_edge(clk64) then
            last_ce <= sdram_ce;
            last_refresh <= refresh;

            -- Start new cycle on CE rising edge
            if sdram_ce = '1' and last_ce = '0' then
                q <= "001";
                sd_wr <= sdram_we;
                sd_addr_lat <= unsigned(sdram_addr(7 downto 0));
                sd_data_lat <= sdram_din;
                report "SDRAM: CE rising edge, addr=" & integer'image(to_integer(unsigned(sdram_addr(7 downto 0)))) &
                       " we=" & std_logic'image(sdram_we) &
                       " din=" & integer'image(to_integer(unsigned(sdram_din))) &
                       " q=" & integer'image(to_integer(q));
            end if;

            -- Refresh
            if refresh = '1' and last_refresh = '0' then
                report "SDRAM: Refresh started, q=" & integer'image(to_integer(q));
            end if;

            -- Advance state machine
            if q /= "000" then
                q <= q + 1;

                -- Write at state 2
                if q = "010" and sd_wr = '1' then
                    ram(to_integer(sd_addr_lat)) <= sd_data_lat;
                    report "SDRAM: WRITE addr=" & integer'image(to_integer(sd_addr_lat)) &
                           " data=" & integer'image(to_integer(unsigned(sd_data_lat)));
                end if;

                -- Read at state 4
                if q = "100" then
                    sdram_dout <= ram(to_integer(sd_addr_lat));
                    report "SDRAM: READ addr=" & integer'image(to_integer(sd_addr_lat)) &
                           " data=" & integer'image(to_integer(unsigned(ram(to_integer(sd_addr_lat)))));
                end if;
            end if;
        end if;
    end process;

    -- Test stimulus
    process
    begin
        -- Wait for initial settling
        wait for 100 ns;

        report "=== TEST 1: CPU path write (cart_ce at CPUC) ===";
        -- Wait for CPUC slot (cycle 28)
        wait until rising_edge(clk32) and sys_cycle = 27;
        cart_addr <= '0' & x"000042";
        cart_din <= x"55";
        cart_we <= '1';
        cart_ce <= '1';
        wait until rising_edge(clk32);
        cart_ce <= '0';
        cart_we <= '0';

        -- Wait for SDRAM to complete
        wait for 500 ns;

        -- Read back via cart path
        wait until rising_edge(clk32) and sys_cycle = 27;
        cart_addr <= '0' & x"000042";
        cart_we <= '0';
        cart_ce <= '1';
        wait until rising_edge(clk32);
        cart_ce <= '0';

        wait for 500 ns;
        report "TEST 1: Read back = " & integer'image(to_integer(unsigned(sdram_dout)));
        if sdram_dout = x"55" then
            test1_pass <= true;
            report "TEST 1: PASS";
        else
            report "TEST 1: FAIL (expected $55, got " & integer'image(to_integer(unsigned(sdram_dout))) & ")";
        end if;

        report "=== TEST 2: REU path write (reu_ram_ce at DMA0) ===";
        -- Set up REU DMA
        reu_ram_addr <= '1' & x"030000";
        reu_ram_dout <= x"AA";
        reu_ram_we <= '1';
        dma_req <= '1';

        -- Wait for DMA0 (ext_cycle rising edge)
        wait until rising_edge(clk32) and ext_cycle = '1' and ext_cycle_d = '0';
        report "REU: reu_ram_ce should fire now, ext_cycle=" & std_logic'image(ext_cycle) &
               " ext_cycle_d=" & std_logic'image(ext_cycle_d) &
               " dma_req=" & std_logic'image(dma_req) &
               " reu_ram_ce=" & std_logic'image(reu_ram_ce);

        wait for 500 ns;
        dma_req <= '0';
        reu_ram_we <= '0';

        -- Read back via cart path
        wait until rising_edge(clk32) and sys_cycle = 27;
        cart_addr <= '1' & x"030000";
        cart_we <= '0';
        cart_ce <= '1';
        wait until rising_edge(clk32);
        cart_ce <= '0';

        wait for 500 ns;
        report "TEST 2: Read back = " & integer'image(to_integer(unsigned(sdram_dout)));
        if sdram_dout = x"AA" then
            test2_pass <= true;
            report "TEST 2: PASS";
        else
            report "TEST 2: FAIL (expected $AA, got " & integer'image(to_integer(unsigned(sdram_dout))) & ")";
        end if;

        report "=== TEST 3: REU path with refresh collision ===";
        -- Fire refresh just before DMA0
        wait until rising_edge(clk32) and sys_cycle = 2;
        refresh <= '1';
        wait until rising_edge(clk32);
        refresh <= '0';

        -- Set up REU DMA
        reu_ram_addr <= '1' & x"030001";
        reu_ram_dout <= x"BB";
        reu_ram_we <= '1';
        dma_req <= '1';

        -- Wait for reu_ram_ce
        wait until rising_edge(clk32) and ext_cycle = '1' and ext_cycle_d = '0';

        wait for 500 ns;
        dma_req <= '0';
        reu_ram_we <= '0';

        -- Read back
        wait until rising_edge(clk32) and sys_cycle = 27;
        cart_addr <= '1' & x"030001";
        cart_we <= '0';
        cart_ce <= '1';
        wait until rising_edge(clk32);
        cart_ce <= '0';

        wait for 500 ns;
        report "TEST 3: Read back = " & integer'image(to_integer(unsigned(sdram_dout)));
        if sdram_dout = x"BB" then
            report "TEST 3: PASS (no refresh collision)";
        else
            report "TEST 3: FAIL - refresh collision! (expected $BB, got " &
                   integer'image(to_integer(unsigned(sdram_dout))) & ")";
        end if;

        report "=== SIMULATION COMPLETE ===";
        report "Test 1 (CPU path): " & boolean'image(test1_pass);
        report "Test 2 (REU path): " & boolean'image(test2_pass);

        wait;
    end process;

end sim;
