-- cpu_cache_doom_coherency_tb.vhd — hunt the residual Doom coherency hole.
--
-- The Doom loader copies game code REU -> bank $00 -> SuperRAM (bank $20) via
-- CPU long-stores, then JML $20:0000. With CACHE_READ_PATH=true the cache
-- covers BOTH bank $00 and SuperRAM. iter-15b proved (HW) the DMA snoop fixes
-- the bank-$00/REU staleness (loader completes) but Doom still runs away after
-- launch. Suspected residual hole: the CPU-write `invalidate_wr` is gated on
-- `cpu_en='1'`. If, on HW, the long-store's cpu_we strobe is NOT aligned with
-- the enable pulse that the cache samples, invalidate_wr MISSES the write and
-- the cache keeps stale (pre-transfer garbage) SuperRAM bytes -> the CPU later
-- fetches garbage code -> runaway.
--
-- This bench isolates that: it caches a SuperRAM byte, then overwrites it with
-- cpu_we=1 but cpu_en=0 (the misaligned case), and checks whether the cache
-- still returns the stale value. STEP S2 is the reproduction; STEP S1 is the
-- aligned control (must always pass).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_doom_coherency_tb is
end entity;

architecture sim of cpu_cache_doom_coherency_tb is
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

    -- Fill helper: present a fill of (bank,addr)=data for one clock.
    procedure do_fill(signal fa : out unsigned(15 downto 0);
                      signal fb : out unsigned(7 downto 0);
                      signal fd : out unsigned(7 downto 0);
                      signal fw : out std_logic;
                      addr : unsigned(15 downto 0);
                      bank : unsigned(7 downto 0);
                      data : unsigned(7 downto 0);
                      signal c : std_logic) is
    begin
        fa <= addr; fb <= bank; fd <= data; fw <= '1';
        wait until rising_edge(c);
        fw <= '0';
        wait until rising_edge(c);
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
        cpu_addr => cpu_addr, cpu_bank => cpu_bank, cpu_we => cpu_we, cpu_do => cpu_do,
        cache_di => cache_di, cache_hit => cache_hit,
        fill_data => fill_data, fill_we => fill_we, fill_addr => fill_addr, fill_bank => fill_bank,
        snoop_we => snoop_we, snoop_addr => snoop_addr, snoop_bank => snoop_bank,
        wb_pending => wb_pending, wb_addr => wb_addr, wb_data => wb_data, wb_ack => wb_ack,
        flush => flush, cpu_en => cpu_en, wb_enable => '0', same_line => same_line,
        dbg_flush_active => dbg_flush_active, dbg_tag_match => dbg_tag_match
    );

    stim: process
        variable got : unsigned(7 downto 0);
    begin
        reset <= '1'; wait for 5 * CLK_PER; reset <= '0';
        flush <= '1'; wait for 2 * CLK_PER; flush <= '0';
        for i in 0 to 1040 loop wait until rising_edge(clk); end loop;
        report "=== Flush complete ===";

        ----------------------------------------------------------------
        -- STEP S1: SuperRAM (bank $20) CPU-write-invalidate, ALIGNED.
        -- Cache $20:1000 = $AA, then CPU writes $55 with cpu_en=1.
        -- invalidate_wr must fire -> re-read misses (or returns $55).
        ----------------------------------------------------------------
        cpu_addr <= x"1000"; cpu_bank <= x"20"; cpu_we <= '0'; cpu_en <= '0';
        wait until rising_edge(clk);
        do_fill(fill_addr, fill_bank, fill_data, fill_we, x"1000", x"20", x"AA", clk);
        cpu_addr <= x"1000"; cpu_bank <= x"20"; cpu_we <= '0';
        wait until rising_edge(clk); wait until rising_edge(clk);
        report "S1 READ pre-write $20:1000: hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(cache_di));
        if cache_hit /= '1' or cache_di /= x"AA" then
            report "S1 FAIL: SuperRAM not cached ($AA expected)" severity warning;
            test_fail <= true;
        end if;

        -- aligned write: cpu_we=1 AND cpu_en=1 on the same edge
        cpu_addr <= x"1000"; cpu_bank <= x"20"; cpu_we <= '1'; cpu_do <= x"55"; cpu_en <= '1';
        wait until rising_edge(clk);
        cpu_en <= '0';
        wait until rising_edge(clk);
        cpu_we <= '0';
        wait until rising_edge(clk); wait until rising_edge(clk);

        cpu_addr <= x"1000"; cpu_bank <= x"20"; cpu_we <= '0'; cpu_do <= (others=>'0');
        wait until rising_edge(clk); wait until rising_edge(clk);
        got := cache_di;
        report "S1 READ post-write(aligned) $20:1000: hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(got));
        if cache_hit = '1' and got = x"AA" then
            report "*** S1 BUG: SuperRAM stale $AA after aligned write of $55 ***" severity warning;
            test_fail <= true;
        else
            report "S1 PASS: aligned SuperRAM write invalidated (hit=" & std_logic'image(cache_hit) & ")";
        end if;

        ----------------------------------------------------------------
        -- STEP S2: SuperRAM CPU-write with cpu_en=0 (MISALIGNED).
        -- This models the loader long-store whose enable pulse does not
        -- coincide with the cache's sampled cpu_en. If invalidate_wr is
        -- gated on cpu_en, the write is MISSED and the cache keeps $AA.
        -- Re-cache $20:2000=$AA first.
        ----------------------------------------------------------------
        cpu_addr <= x"2000"; cpu_bank <= x"20"; cpu_we <= '0'; cpu_en <= '0';
        wait until rising_edge(clk);
        do_fill(fill_addr, fill_bank, fill_data, fill_we, x"2000", x"20", x"AA", clk);
        cpu_addr <= x"2000"; cpu_bank <= x"20"; cpu_we <= '0';
        wait until rising_edge(clk); wait until rising_edge(clk);
        report "S2 READ pre-write $20:2000: hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(cache_di));

        -- MISALIGNED write: cpu_we=1 but cpu_en stays 0 throughout
        cpu_addr <= x"2000"; cpu_bank <= x"20"; cpu_we <= '1'; cpu_do <= x"55"; cpu_en <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        cpu_we <= '0';
        wait until rising_edge(clk); wait until rising_edge(clk);

        cpu_addr <= x"2000"; cpu_bank <= x"20"; cpu_we <= '0'; cpu_do <= (others=>'0');
        wait until rising_edge(clk); wait until rising_edge(clk);
        got := cache_di;
        report "S2 READ post-write(cpu_en=0) $20:2000: hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(got)) & " tag_match=" & std_logic'image(dbg_tag_match);
        if cache_hit = '1' and got = x"AA" then
            report "*** S2 HOLE FOUND: cpu_en-gated invalidate MISSES the write -> STALE $AA. "
                 & "This is the Doom runaway class. Fix: drop the cpu_en gate on invalidate_wr. ***"
                 severity warning;
            -- NOT a test_fail: this documents the current (buggy) behaviour so
            -- the fix can be measured against it. The report text is the signal.
        else
            report "S2: cpu_en=0 write still invalidated (hit=" & std_logic'image(cache_hit)
                 & ") -> cpu_en gate is NOT the hole; look elsewhere (alt-fire FAST data path).";
        end if;

        if test_fail then
            report "=== TEST FAILED (a control step regressed) ===" severity failure;
        else
            report "=== TEST DONE (see S2 report for the hole verdict) ===";
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
