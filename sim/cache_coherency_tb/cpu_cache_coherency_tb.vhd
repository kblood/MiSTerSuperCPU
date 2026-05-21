-- cpu_cache_coherency_tb.vhd — direct test of cache invalidate-on-write
--
-- Replicates the suspected v88 failure:
--   1. Boot-time read at $019E fills cache byte with $8D (stale pre-load data)
--   2. Phase-2 writes $58 to $019E (CPU write-through)
--   3. CPU reads $019E again — expected $58, bug would return $8D
--
-- Exercises cpu_cache.vhd in isolation with direct stimulus. Passes if
-- cache_hit=0 after write (invalidate fired) OR cache_di=$58 after write.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_coherency_tb is
end entity;

architecture sim of cpu_cache_coherency_tb is
    constant CLK_PER : time := 31.25 ns; -- 32MHz

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal enable   : std_logic := '1';
    signal cpu_addr : unsigned(15 downto 0) := (others => '0');
    signal cpu_bank : unsigned(7 downto 0)  := (others => '0');
    signal cpu_we   : std_logic := '0';
    signal cpu_do   : unsigned(7 downto 0) := (others => '0');
    signal cache_di : unsigned(7 downto 0);
    signal cache_hit: std_logic;
    signal fill_data: unsigned(7 downto 0) := (others => '0');
    signal fill_we  : std_logic := '0';
    signal fill_addr: unsigned(15 downto 0) := (others => '0');
    signal fill_bank: unsigned(7 downto 0)  := (others => '0');
    signal wb_pending : std_logic;
    signal wb_addr    : unsigned(15 downto 0);
    signal wb_data    : unsigned(7 downto 0);
    signal wb_ack     : std_logic := '0';
    signal flush    : std_logic := '0';
    signal cpu_en   : std_logic := '0';
    signal same_line: std_logic;
    signal dbg_flush_active : std_logic;
    signal dbg_tag_match    : std_logic;

    signal test_done : boolean := false;
    signal test_fail : boolean := false;

    -- stimulus helpers
    procedure tick(signal c : inout std_logic) is
    begin
        c <= '0'; wait for CLK_PER/2;
        c <= '1'; wait for CLK_PER/2;
    end procedure;
begin
    -- clock
    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PER/2;
            clk <= '1'; wait for CLK_PER/2;
        end loop;
        wait;
    end process;

    dut: entity work.cpu_cache
    port map (
        clk => clk,
        reset => reset,
        enable => enable,
        cpu_addr => cpu_addr,
        cpu_bank => cpu_bank,
        cpu_we => cpu_we,
        cpu_do => cpu_do,
        cache_di => cache_di,
        cache_hit => cache_hit,
        fill_data => fill_data,
        fill_we => fill_we,
        fill_addr => fill_addr,
        fill_bank => fill_bank,
        wb_pending => wb_pending,
        wb_addr => wb_addr,
        wb_data => wb_data,
        wb_ack => wb_ack,
        flush => flush,
        cpu_en => cpu_en,
        same_line => same_line,
        dbg_flush_active => dbg_flush_active,
        dbg_tag_match => dbg_tag_match
    );

    stim: process
        variable got : unsigned(7 downto 0);
    begin
        -- release reset and flush the cache
        reset <= '1';
        wait for 5 * CLK_PER;
        reset <= '0';
        flush <= '1';
        wait for 2 * CLK_PER;
        flush <= '0';
        -- flush takes 1024 cycles
        for i in 0 to 1040 loop
            wait until rising_edge(clk);
        end loop;
        report "=== Flush complete ===";

        -- STEP 1: simulate boot-time read that fills cache at $019E with $8D.
        -- Present address for read (no CPU stepping required for fill path):
        cpu_addr <= x"019E";
        cpu_bank <= x"00";
        cpu_we   <= '0';
        cpu_do   <= (others => '0');
        cpu_en   <= '0';
        wait until rising_edge(clk);
        -- Fill cycle: SDRAM delivers $8D for $019E
        fill_addr <= x"019E";
        fill_bank <= x"00";
        fill_data <= x"8D";
        fill_we   <= '1';
        wait until rising_edge(clk);
        fill_we   <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- STEP 2: read $019E — expect hit returning $8D
        cpu_addr <= x"019E";
        cpu_we   <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        got := cache_di;
        report "READ1 at $019E: cache_hit=" & std_logic'image(cache_hit)
             & " cache_di=" & integer'image(to_integer(got));
        if cache_hit /= '1' then
            report "FAIL: expected cache_hit=1 after fill" severity warning;
            test_fail <= true;
        end if;
        if got /= x"8D" then
            report "FAIL: expected cache_di=$8D after fill, got " & integer'image(to_integer(got)) severity warning;
            test_fail <= true;
        end if;

        -- STEP 3: CPU write-through $019E = $58 (simulate phase-2 store)
        cpu_addr <= x"019E";
        cpu_we   <= '1';
        cpu_do   <= x"58";
        cpu_en   <= '1';  -- CPU clock enable pulse
        wait until rising_edge(clk);
        cpu_en   <= '0';
        -- hold the write cycle 1 more clock then drop
        wait until rising_edge(clk);
        cpu_we   <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- STEP 4: re-read $019E — CRITICAL: must NOT return stale $8D.
        -- Acceptable outcomes:
        --   (a) cache_hit=0 (invalidate fired, CPU falls to BRAM) — GOOD
        --   (b) cache_hit=1 AND cache_di=$58 (would require write-through)
        -- Bug:
        --   (c) cache_hit=1 AND cache_di=$8D (stale read) — THIS IS v88 symptom
        cpu_addr <= x"019E";
        cpu_we   <= '0';
        cpu_do   <= (others => '0');
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        got := cache_di;
        report "READ2 at $019E (post-write): cache_hit=" & std_logic'image(cache_hit)
             & " cache_di=" & integer'image(to_integer(got))
             & " tag_match=" & std_logic'image(dbg_tag_match);

        if cache_hit = '1' and got = x"8D" then
            report "*** BUG REPRODUCED: cache returned STALE $8D after write of $58 ***"
                severity failure;
            test_fail <= true;
        elsif cache_hit = '0' then
            report "PASS: cache_hit=0 after write (invalidate fired correctly)";
        elsif cache_hit = '1' and got = x"58" then
            report "PASS: cache_hit=1 returning fresh $58 (write-through works)";
        else
            report "UNEXPECTED: cache_hit=" & std_logic'image(cache_hit)
                 & " got=" & integer'image(to_integer(got)) severity warning;
            test_fail <= true;
        end if;

        -- STEP 5: extra sanity — read different byte in same line ($0198)
        -- Line 51 covers $0198-$019F. Byte $0198 was never filled, should miss.
        cpu_addr <= x"0198";
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        report "READ $0198 (unfilled byte in same line 51): cache_hit="
             & std_logic'image(cache_hit)
             & " cache_di=" & integer'image(to_integer(cache_di))
             & " tag_match=" & std_logic'image(dbg_tag_match);

        if test_fail then
            report "=== TEST FAILED ===" severity failure;
        else
            report "=== TEST PASSED ===";
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
