-- cpu_cache_filldata_phase_tb.vhd — Bug 2 iter-18 ROOT CAUSE reproduction + fix proof.
--
-- The PRIOR pipe bench (cpu_cache_superram_pipe_tb) modeled the iter-16 theory:
-- fill_ADDR running ahead of fill_data in a sustained pipeline. That was
-- HW-FALSIFIED — SAME_CLOCK_PASSTHROUGH holds cpuAddr STABLE through each access,
-- so the address is NEVER ahead. This bench models the ACTUAL iter-18 root cause
-- (HW divergence-detector: WD=FFFF, $2000C5 cache=$03 vs SDRAM=$40):
--
--   The fill FF (rp_fill_we @ enableCpu_816 = cpu_cyc_s(1) = launch + 2 clk32)
--   latches cpuDi_nocache (= ramDin = sdram_pm dout_r). But dout_r is FRESH only
--   at q=5 (~3 clk32 after the cpu_cyc launch). So at the fill edge dout_r STILL
--   holds the PREVIOUS access's byte → the cache stores byte(prev) under the
--   CURRENT (correct) address/tag → a later re-read HITs and returns the stale
--   previous byte. The CPU itself reads correctly because C64.sdc
--   `set_multicycle_path -setup 2/4 -to *P65C816*` lets ITS capture FF settle
--   ~4 clk32 late (after q=5); the fill FF has no such exception.
--
-- MODEL: a stream of distinct-line bank-$20 read MISSES at a 4-clk32 cadence.
--   dout_model becomes golden(i) at DOUT_LAT clk32 after access i's launch and
--   holds until the next launch. The address presented to the fill is ALWAYS the
--   correct current address (stable passthrough). Only the SAMPLE PHASE of the
--   data differs:
--     MODE_BUGGY (FILL_OFF=2 < DOUT_LAT=3): fill samples dout_model BEFORE it is
--        fresh → captures golden(i-1) = the previous access's byte → STALE.
--     MODE_FIXED (FILL_OFF=3 = DOUT_LAT):  fill samples dout_model AFTER it is
--        fresh → captures golden(i) → COHERENT. (= delay-the-fill fix; the HW
--        variant gates the delayed fire on sdram_data_valid_sync.)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_filldata_phase_tb is
end entity;

architecture sim of cpu_cache_filldata_phase_tb is
    constant CLK_PER  : time := 31.25 ns; -- 32MHz

    -- clk32 from cpu_cyc launch to dout_r fresh (sdram_pm q=5 ~ 5-6 clk64).
    constant DOUT_LAT : integer := 3;
    -- clk32 from launch to the fill edge: BUGGY = enableCpu_816 = cpu_cyc_s(1) = 2.
    constant FILL_OFF_BUGGY : integer := 2;
    -- FIXED = delay the fill one clk32 so it samples the now-fresh dout_r.
    constant FILL_OFF_FIXED : integer := 3;
    -- 4-apart CPU cadence (CPU0/4/8/C).
    constant PERIOD   : integer := 4;

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

    signal test_done   : boolean := false;
    signal buggy_fails : integer := 0;
    signal fixed_fails : integer := 0;

    constant N_LINES : integer := 64;
    type gold_t is array(0 to N_LINES-1) of unsigned(7 downto 0);
    function gold_init return gold_t is
        variable g : gold_t;
    begin
        for i in 0 to N_LINES-1 loop
            g(i) := to_unsigned((i * 7 + 16#11#) mod 256, 8);
        end loop;
        return g;
    end function;
    constant golden : gold_t := gold_init;

    -- distinct line per access: byte offset 0, lines step by 2 (addr = i*16)
    function line_addr(i : integer) return unsigned is
    begin
        return to_unsigned(i * 16, 16);
    end function;
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
        -- dout_model = the SDRAM dout_r as seen by the fill. It becomes golden(i)
        -- DOUT_LAT clk32 after access i launches and holds until the next update.
        variable dout_model : unsigned(7 downto 0) := (others => '0');

        procedure fetch_stream(fill_off : in integer; signal fails : inout integer) is
        begin
            dout_model := (others => '0');
            -- Phase 1: stream N misses at a PERIOD-apart cadence. Within each
            -- access, advance dout_model fresh at DOUT_LAT and fire the fill at
            -- fill_off, sampling dout_model AS IT STANDS at that tick.
            for i in 0 to N_LINES-1 loop
                -- present the (stable) current read address for the whole access
                cpu_addr <= line_addr(i); cpu_bank <= x"20"; cpu_we <= '0';
                for t in 0 to PERIOD-1 loop
                    -- dout_r goes fresh with THIS access's byte at q=5
                    if t = DOUT_LAT then
                        dout_model := golden(i);
                    end if;
                    -- fill edge: sample dout_model NOW (stale if fill_off<DOUT_LAT),
                    -- addr = the correct current address (stable passthrough).
                    if t = fill_off then
                        fill_data <= dout_model;
                        fill_addr <= line_addr(i); fill_bank <= x"20";
                        fill_we   <= '1';
                    else
                        fill_we <= '0';
                    end if;
                    wait until rising_edge(clk);
                end loop;
            end loop;
            fill_we <= '0';

            -- Phase 2: re-read every line (a HIT now) and check vs golden.
            for i in 0 to N_LINES-1 loop
                cpu_addr <= line_addr(i); cpu_bank <= x"20"; cpu_we <= '0';
                wait until rising_edge(clk);
                wait until rising_edge(clk);   -- settle registered line_word
                if cache_hit = '1' and cache_di /= golden(i) then
                    report "  STALE line " & integer'image(i)
                         & " addr=$20:" & to_hstring(line_addr(i))
                         & " got=" & to_hstring(cache_di)
                         & " golden=" & to_hstring(golden(i)) severity warning;
                    fails <= fails + 1;
                end if;
                wait until rising_edge(clk);
            end loop;
        end procedure;
    begin
        reset <= '1'; wait for 5 * CLK_PER; reset <= '0';
        flush <= '1'; wait for 2 * CLK_PER; flush <= '0';
        for i in 0 to 1040 loop wait until rising_edge(clk); end loop;
        report "=== Flush complete (DOUT_LAT=" & integer'image(DOUT_LAT)
             & " clk32) ===";

        report "=== MODE BUGGY: fill samples dout_r at +" & integer'image(FILL_OFF_BUGGY)
             & " clk32 (BEFORE fresh @ +" & integer'image(DOUT_LAT) & ") ===";
        fetch_stream(FILL_OFF_BUGGY, buggy_fails);
        report "BUGGY stale-hit count = " & integer'image(buggy_fails);

        flush <= '1'; wait for 2 * CLK_PER; flush <= '0';
        for i in 0 to 1040 loop wait until rising_edge(clk); end loop;

        report "=== MODE FIXED: fill delayed to +" & integer'image(FILL_OFF_FIXED)
             & " clk32 (>= fresh) ===";
        fetch_stream(FILL_OFF_FIXED, fixed_fails);
        report "FIXED stale-hit count = " & integer'image(fixed_fails);

        report "=== RESULT: BUGGY=" & integer'image(buggy_fails)
             & "  FIXED=" & integer'image(fixed_fails) & " ===";
        if buggy_fails > 0 and fixed_fails = 0 then
            report "=== CONFIRMED: early fill-data sample (dout_r not fresh) is the "
                 & "Bug-2 corruptor; delaying the fill to the fresh-dout edge is coherent. ===";
        elsif buggy_fails = 0 then
            report "=== NO STALENESS at these offsets - hypothesis not reproduced ==="
                 severity warning;
        else
            report "=== FIX INSUFFICIENT (fixed still stale) ===" severity failure;
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
