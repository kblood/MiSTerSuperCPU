-- cpu_cache_latency_tb.vhd — reproduce the iter-7b cross-line read-latency skew
--
-- The fpga64 read-path override is COMBINATIONAL and same-cycle:
--   cpuDi <= rp_cache_di when (CACHE_READ_PATH and rp_cache_hit = '1')   (fpga64_sid_iec.vhd:1965)
-- but inside cpu_cache, `cache_hit` is combinational on the CURRENT address
-- (:276) while `cache_di` is derived from `line_word`, a REGISTERED 1-cycle-
-- late read of the 8 data banks (:284-296). The `same_line` fast-path (:180)
-- only covers back-to-back same-line accesses.
--
-- The existing coherency bench never catches this because it waits TWO
-- rising_edge(clk) after presenting each address before sampling cache_di —
-- i.e. it always samples AFTER line_word has caught up.
--
-- This bench samples cache_hit + cache_di in the SAME cycle cache_hit asserts
-- for a freshly-presented (non-same_line) address — exactly what the
-- combinational override does. If cache_di holds the PREVIOUS line's byte
-- while cache_hit=1, the override feeds the CPU stale data = the HW garbage.
--
-- PASS  = on the hit cycle, cache_di already equals the addressed line's byte.
-- FAIL  = cache_hit=1 but cache_di = the previously-read line's byte (skew).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_latency_tb is
end entity;

architecture sim of cpu_cache_latency_tb is
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
    signal snoop_we  : std_logic := '0';
    signal snoop_addr: unsigned(15 downto 0) := (others => '0');
    signal snoop_bank: unsigned(7 downto 0)  := (others => '0');
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

    -- Fill a single byte into the cache via the SDRAM fill port.
    procedure fill_byte(addr : in unsigned(15 downto 0);
                        data : in unsigned(7 downto 0);
                        signal fa : out unsigned(15 downto 0);
                        signal fb : out unsigned(7 downto 0);
                        signal fd : out unsigned(7 downto 0);
                        signal fw : out std_logic;
                        signal c  : in  std_logic) is
    begin
        fa <= addr; fb <= x"00"; fd <= data; fw <= '1';
        wait until rising_edge(c);
        fw <= '0';
        wait until rising_edge(c);
    end procedure;
begin
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
        clk => clk, reset => reset, enable => enable,
        cpu_addr => cpu_addr, cpu_bank => cpu_bank,
        cpu_we => cpu_we, cpu_do => cpu_do,
        cache_di => cache_di, cache_hit => cache_hit,
        fill_data => fill_data, fill_we => fill_we,
        fill_addr => fill_addr, fill_bank => fill_bank,
        snoop_we => snoop_we, snoop_addr => snoop_addr, snoop_bank => snoop_bank,
        wb_pending => wb_pending, wb_addr => wb_addr, wb_data => wb_data,
        wb_ack => wb_ack, flush => flush, cpu_en => cpu_en,
        wb_enable => '0', same_line => same_line,
        dbg_flush_active => dbg_flush_active, dbg_tag_match => dbg_tag_match
    );

    stim: process
        variable got_hit : std_logic;
        variable got_di  : unsigned(7 downto 0);
        variable got_sl  : std_logic;
    begin
        reset <= '1';
        cpu_bank <= x"00";
        wait for 5 * CLK_PER;
        reset <= '0';
        flush <= '1';
        wait for 2 * CLK_PER;
        flush <= '0';
        for i in 0 to 1040 loop
            wait until rising_edge(clk);
        end loop;
        report "=== Flush complete ===";

        -- Fill two DISTINCT cache lines with distinguishable data:
        --   line A: $0100 (line_index = $0100(11:3) = 0x20), byte off 0 = $0100
        --   line B: $0200 (line_index = $0200(11:3) = 0x40), byte off 0 = $0200
        -- Different tags too ($00$01 vs $00$02). Both byte-offset 0.
        fill_byte(x"0100", x"AA", fill_addr, fill_bank, fill_data, fill_we, clk);
        fill_byte(x"0200", x"BB", fill_addr, fill_bank, fill_data, fill_we, clk);
        report "=== Filled $0100=$AA, $0200=$BB ===";

        -- Settle the read pipeline on line A: present $0100 and let line_word
        -- catch up (two edges), confirming the cache hits $AA when sampled late.
        cpu_addr <= x"0100"; cpu_we <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        report "SETTLED A: $0100 hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(cache_di))
             & " same_line=" & std_logic'image(same_line);
        if not (cache_hit = '1' and cache_di = x"AA") then
            report "FAIL setup: expected late-sampled $0100 hit=$AA" severity warning;
            test_fail <= true;
        end if;

        -- ===== THE CRITICAL TEST =====
        -- Cross-line switch A->B. After a rising edge, present $0200, then sample
        -- cache_hit/cache_di SAME CYCLE (a small comb delay, NOT another clk edge)
        -- — exactly what the combinational fpga64 override does at the hit.
        -- line_word still holds line A ($AA) until the NEXT edge, so a skew shows
        -- as hit=1 but di=$AA (stale) instead of $BB.
        wait until rising_edge(clk);
        cpu_addr <= x"0200"; cpu_we <= '0';
        wait for CLK_PER/4;          -- mid-cycle: combinational signals settled, no new edge
        got_hit := cache_hit;
        got_di  := cache_di;
        got_sl  := same_line;
        report "SAME-CYCLE B: $0200 hit=" & std_logic'image(got_hit)
             & " di=" & integer'image(to_integer(got_di))
             & " same_line=" & std_logic'image(got_sl)
             & "   (expect hit=1, di=187/$BB; skew shows di=170/$AA)";

        if got_hit = '1' and got_di = x"AA" then
            report "*** LATENCY-SKEW BUG REPRODUCED: hit=1 for $0200 but cache_di=$AA "
                 & "(stale line A). The combinational override feeds the CPU the "
                 & "PREVIOUS line's byte on a cross-line hit. ***" severity warning;
            test_fail <= true;
        elsif got_hit = '1' and got_di = x"BB" then
            report "NO-SKEW: same-cycle cache_di already = $BB (override is safe)";
        elsif got_hit = '0' then
            report "HIT-DEFERRED: cache_hit=0 on the switch cycle (override would not fire -- also safe, just slower)";
        else
            report "UNEXPECTED: hit=" & std_logic'image(got_hit)
                 & " di=" & integer'image(to_integer(got_di)) severity warning;
            test_fail <= true;
        end if;

        -- Confirm B reads correctly when sampled LATE (sanity: data is in the cache).
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        report "LATE B: $0200 hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(cache_di));
        if not (cache_hit = '1' and cache_di = x"BB") then
            report "FAIL: late-sampled $0200 should be hit=$BB" severity warning;
            test_fail <= true;
        end if;

        if test_fail then
            report "=== TEST FAILED (skew present) ===" severity failure;
        else
            report "=== TEST PASSED (no same-cycle skew) ===";
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
