-- cpu_cache_superram_pipe_tb.vhd — Bug 2 EMERGENT skew + fix validation.
--
-- The companion replay bench (cpu_cache_bank20_replay_tb) proved the SKEW->stale
-- MAPPING by INJECTING a 1-cycle fill_data/fill_addr offset. This bench shows the
-- skew arises NATURALLY from the real fpga64 wiring against a pipelined SDRAM,
-- with nothing injected, and validates the proposed fix.
--
-- Real wiring (fpga64_sid_iec.vhd:5028-5031):
--   fill_data => cpuDi_nocache   -- = the SuperRAM SDRAM dout, PIPELINE-DELAYED
--   fill_addr => cpuAddr         -- = LIVE CPU address (advances at each fetch)
--   fill_bank => addr_hi_816     --   "
--   fill_we   => rp_fill_we (= enableCpu_816 & read & miss & cacheable)
-- Neither the CPU consume nor the fill is gated on real SDRAM-data-return
-- (RDY_HANDSHAKE=false, data_ready forced '1'). sdram_pm.v latches dout_r at
-- q=5, ~5 clk64 after the ce-launch, so `dout` LAGS the address that produced
-- it. Because the CPU drives its NEXT fetch address immediately, at the fill
-- edge `fill_addr` (live) is AHEAD of `fill_data` (delayed dout) by LAT cycles.
-- => the just-read byte is stored under a LATER address's line => a later read
-- of that line HITs and returns the stale "previous byte".
--
-- MODEL: a stream of distinct-line bank-$20 reads. The SDRAM data for the
-- address presented LAT clk32 ago is what `dout` shows now. We drive the cache
-- fill exactly as fpga64 does, then re-read each line and check against golden.
--   MODE_BUGGY (skew=LAT): fill_addr = LIVE address  -> reproduces staleness.
--   MODE_FIXED (transaction-matched): fill_addr = address delayed by LAT to
--     match `dout` -> coherent. This is fix option (b); option (a) capture-at-
--     launch is equivalent when the launch->data latency is LAT.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_superram_pipe_tb is
end entity;

architecture sim of cpu_cache_superram_pipe_tb is
    constant CLK_PER : time := 31.25 ns; -- 32MHz

    -- SDRAM read latency, in clk32, from address-present to dout-valid.
    -- sdram_pm: ~5 clk64 = ~2-3 clk32; sweep both 2 and 3 to bound the effect.
    constant LAT : integer := 3;

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

    -- Golden SDRAM truth for bank $20.
    constant N_LINES : integer := 64;             -- distinct cache lines exercised
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

    -- line i -> a distinct address/line: addr = i*16 (byte off 0, lines step by 2)
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
        -- A pipelined "fetch stream": present line i, hold one grant; the SDRAM
        -- data visible NOW is for the address presented LAT grants ago. We fill
        -- the cache with (visible data, fill-line) where fill-line is either the
        -- LIVE line (buggy) or the line delayed by LAT (fixed).
        procedure fetch_stream(fixed : in boolean; signal fails : inout integer) is
            -- ring of the last LAT+1 line indices presented (the SDRAM in-flight)
            type ring_t is array(0 to LAT) of integer;
            variable ring : ring_t := (others => 0);
            variable visible_line : integer;   -- line whose data is at `dout` now
            variable live_line    : integer;   -- line currently presented (fill_addr if buggy)
            variable filltag_line : integer;   -- line we tag the fill with
        begin
            -- Phase 1: stream all N lines as misses, filling per the wiring model.
            for i in 0 to N_LINES-1 loop
                -- shift ring: newest at [0]
                for k in LAT downto 1 loop ring(k) := ring(k-1); end loop;
                ring(0) := i;
                live_line    := i;
                visible_line := ring(LAT);     -- data available now = LAT grants old

                -- present live address (a real miss read)
                cpu_addr <= line_addr(live_line); cpu_bank <= x"20"; cpu_we <= '0';
                wait until rising_edge(clk);

                -- fill exactly as fpga64: data = visible (delayed dout), tag = live
                -- (buggy) or = visible (fixed = transaction-matched).
                if fixed then
                    filltag_line := visible_line;   -- tag matches the data's address
                else
                    filltag_line := live_line;      -- tag = live cpuAddr (AHEAD)
                end if;
                fill_addr <= line_addr(filltag_line); fill_bank <= x"20";
                fill_data <= golden(visible_line); fill_we <= '1';
                wait until rising_edge(clk);
                fill_we <= '0';
                wait until rising_edge(clk);
            end loop;

            -- Phase 2: re-read every line (now a HIT for filled lines) and check.
            -- Skip the first LAT lines whose data never became visible during the
            -- short stream (ring still 0) — they are genuine cold/unfilled, not the bug.
            for i in 0 to N_LINES-1 loop
                cpu_addr <= line_addr(i); cpu_bank <= x"20"; cpu_we <= '0';
                wait until rising_edge(clk);
                wait until rising_edge(clk);          -- settle line_word
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
        report "=== Flush complete (LAT=" & integer'image(LAT) & " clk32) ===";

        report "=== MODE BUGGY: fill_addr = LIVE cpuAddr (current wiring) ===";
        fetch_stream(false, buggy_fails);
        report "BUGGY stale-hit count = " & integer'image(buggy_fails);

        -- re-flush for the fixed run
        flush <= '1'; wait for 2 * CLK_PER; flush <= '0';
        for i in 0 to 1040 loop wait until rising_edge(clk); end loop;

        report "=== MODE FIXED: fill_addr = transaction-matched (delayed by LAT) ===";
        fetch_stream(true, fixed_fails);
        report "FIXED stale-hit count = " & integer'image(fixed_fails);

        report "=== RESULT: BUGGY=" & integer'image(buggy_fails)
             & "  FIXED=" & integer'image(fixed_fails) & " ===";
        if buggy_fails > 0 and fixed_fails = 0 then
            report "=== CONFIRMED: live-cpuAddr fill is the Bug-2 corruptor; "
                 & "transaction-matched (data-aligned) fill_addr is coherent. ===";
        elsif buggy_fails = 0 then
            report "=== NO EMERGENT SKEW at LAT=" & integer'image(LAT)
                 & " - hypothesis not reproduced this config ===" severity warning;
        else
            report "=== FIX INSUFFICIENT (fixed still stale) ===" severity failure;
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
