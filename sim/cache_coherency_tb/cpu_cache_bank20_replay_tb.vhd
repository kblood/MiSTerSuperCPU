-- cpu_cache_bank20_replay_tb.vhd — Bug 2 hunt: bank-$20 read staleness.
--
-- CONTEXT (MEMORY.md project_cache_invalidate_cpuen_hole): with CACHE_READ_PATH
-- =true and alt-fire OFF, the Doom loader DOES populate SuperRAM bank $20 and the
-- game launches (PC:2000B6 fetches real code), but the cache then serves STALE
-- bytes on bank-$20 READS -> Doom reads a garbage operand -> JMPs wild. The
-- cache-OFF baseline reaches "Init Playloop" on the SAME image, so SDRAM holds
-- the CORRECT bytes -> the corruptor is the read path, and the stale bytes do
-- NOT match SDRAM. Suspects: (1) cache LOGIC incoherence, or (2) the fpga64 fill
-- WIRING — fill_data (= cpuDi_nocache, through the SuperRAM 3-stage SDRAM
-- pipeline) skewed by one cycle from fill_addr (= live cpuAddr), so a SuperRAM
-- fill stores the right byte under the wrong line (or the wrong byte under the
-- right line). bank $00 uses a 2-stage pipeline, SuperRAM a 3-stage one
-- (superram_enable_delay), so a fill-alignment tuned for bank $00 is off-by-one
-- for SuperRAM.
--
-- This bench separates the two:
--   SCENARIO A — faithful coherence replay. Drives a Doom-like bank-$20 pattern
--     (colliding direct-mapped lines, invalidating CPU writes, same/cross-line
--     reads) through fpga64's REAL consume timing: address held the 4-apart
--     grant, cache_hit/cache_di sampled SETTLED, registered to _d1, consumed;
--     fill on miss with ALIGNED (addr,data). Every consumed read is checked
--     against a golden memory. PASS here => the cache LOGIC is coherent and
--     Bug 2 is NOT in cpu_cache.vhd.
--   SCENARIO B — fill skew injection. Same pattern but the fill drives
--     fill_data = golden(addr-1)  (one access stale) while fill_addr = addr.
--     If this makes a later read return the stale byte with cache_hit=1, it
--     reproduces the Bug-2 signature and pins it to fill addr/data alignment.
--
-- A faithful model of fpga64's consume (fpga64_sid_iec.vhd):
--   rp_cache_hit_d1 <= rp_cache_hit;  rp_cache_di_d1 <= rp_cache_di;   (1 clk)
--   cpuDi <= rp_cache_di_d1 when (CACHE_READ_PATH and rp_cache_hit_d1='1')
--            else cpuDi_nocache;                                       (miss = SDRAM)
--   rp_fill_we <= enableCpu_816 and (vda or vpa) and (not cpuWe)
--                 and rp_cacheable and (not rp_cache_hit);             (miss only)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_bank20_replay_tb is
end entity;

architecture sim of cpu_cache_bank20_replay_tb is
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

    -- _d1 registered override (models fpga64)
    signal hit_d1   : std_logic := '0';
    signal di_d1    : unsigned(7 downto 0) := (others => '0');

    signal test_done : boolean := false;
    signal fail_count : integer := 0;

    -- Golden SDRAM model for bank $20, addresses $0000..$2FFF.
    constant GOLDEN_LO : integer := 0;
    constant GOLDEN_HI : integer := 16#2FFF#;
    type gold_t is array(GOLDEN_LO to GOLDEN_HI) of unsigned(7 downto 0);

    -- Deterministic "code-like" fill so a stale byte is visibly wrong.
    function gold_init return gold_t is
        variable g : gold_t;
    begin
        for a in GOLDEN_LO to GOLDEN_HI loop
            -- byte = low8 of (addr*5 + 0x37), spreads values across lines/tags
            g(a) := to_unsigned((a * 5 + 16#37#) mod 256, 8);
        end loop;
        return g;
    end function;
    signal golden : gold_t := gold_init;

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
        -- One faithful CPU read at bank $20 / addr `a`. `skew` selects the fill
        -- data alignment: 0 = aligned (golden(a)), 1 = stale (golden(a) from the
        -- PREVIOUS read, i.e. the off-by-one SuperRAM-pipeline suspect).
        procedure cpu_read(a : in integer; skew : in integer;
                           prev_a : in integer) is
            variable ua       : unsigned(15 downto 0);
            variable hit_now  : std_logic;
            variable di_now   : unsigned(7 downto 0);
            variable consumed : unsigned(7 downto 0);
            variable filld    : unsigned(7 downto 0);
        begin
            ua := to_unsigned(a, 16);
            cpu_addr <= ua; cpu_bank <= x"20"; cpu_we <= '0';
            -- 4-apart grant: hold address, let line_word + tag settle.
            wait until rising_edge(clk);
            wait until rising_edge(clk);   -- line_word now reflects this line
            hit_now := cache_hit;
            di_now  := cache_di;
            -- Model fpga64's registered override consume on the NEXT enable.
            hit_d1 <= hit_now;
            di_d1  <= di_now;
            if hit_now = '1' then
                consumed := di_now;             -- hit -> from cache (registered)
            else
                consumed := golden(a);          -- miss -> SDRAM (cpuDi_nocache)
                -- Fill on miss (fill_addr live, fill_data = cpuDi_nocache).
                if skew = 0 then
                    filld := golden(a);
                else
                    filld := golden(prev_a);    -- off-by-one stale data
                end if;
                fill_addr <= ua; fill_bank <= x"20"; fill_data <= filld; fill_we <= '1';
                wait until rising_edge(clk);
                fill_we <= '0';
            end if;
            -- settle a cycle between accesses (4-apart)
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            -- Coherency check: consumed must equal golden truth.
            if consumed /= golden(a) then
                report "  *** STALE READ $20:" & to_hstring(ua)
                     & " consumed=" & to_hstring(consumed)
                     & " golden="   & to_hstring(golden(a))
                     & " hit="      & std_logic'image(hit_now) severity warning;
                fail_count <= fail_count + 1;
            end if;
        end procedure;

        -- CPU long-store write to bank $20 (invalidate path); updates golden.
        procedure cpu_write(a : in integer; d : in integer) is
            variable ua : unsigned(15 downto 0);
        begin
            ua := to_unsigned(a, 16);
            golden(a) <= to_unsigned(d, 8);
            cpu_addr <= ua; cpu_bank <= x"20"; cpu_we <= '1'; cpu_do <= to_unsigned(d, 8);
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            cpu_we <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Run the Doom-like pattern at a given skew; return via fail_count delta.
        procedure run_pattern(skew : in integer) is
            variable prev : integer := 0;
        begin
            -- Pass 1: sequential code fetch across 3 colliding tag groups.
            -- $20:0000, $20:1000, $20:2000 all map to line_index 0 (collisions);
            -- interleave bytes within a line and across lines.
            for grp in 0 to 2 loop
                for off in 0 to 7 loop          -- 8 bytes in line 0 of this tag
                    cpu_read(grp*16#1000# + off, skew, prev);
                    prev := grp*16#1000# + off;
                end loop;
            end loop;
            -- Pass 2: re-read group 0 (was evicted by groups 1,2) -> re-miss/refill.
            for off in 0 to 7 loop
                cpu_read(off, skew, prev);
                prev := off;
            end loop;
            -- Pass 3: a write (invalidate) then immediate re-read must see new data.
            cpu_write(16#0004#, 16#5A#);
            cpu_read(16#0004#, skew, prev); prev := 16#0004#;
            -- Pass 4: same-line back-to-back reads (exercise line_word reuse).
            for off in 0 to 7 loop
                cpu_read(16#0010# + off, skew, prev);
                prev := 16#0010# + off;
            end loop;
            -- Pass 5: cross-line ping-pong (line_word thrash + per-byte valid).
            for i in 0 to 5 loop
                cpu_read(16#0020#, skew, prev); prev := 16#0020#;
                cpu_read(16#1020#, skew, prev); prev := 16#1020#;
            end loop;
        end procedure;

        variable a_fails : integer;
        variable b_fails : integer;
    begin
        reset <= '1'; wait for 5 * CLK_PER; reset <= '0';
        flush <= '1'; wait for 2 * CLK_PER; flush <= '0';
        for i in 0 to 1040 loop wait until rising_edge(clk); end loop;
        report "=== Flush complete ===";

        ----------------------------------------------------------------
        report "=== SCENARIO A: aligned fill (faithful coherence) ===";
        run_pattern(0);
        a_fails := fail_count;
        report "SCENARIO A fails = " & integer'image(a_fails);
        if a_fails = 0 then
            report "  A PASS: cache LOGIC is coherent at faithful 4-apart timing"
                 & " -> Bug 2 is NOT in cpu_cache.vhd; look at fpga64 fill wiring.";
        else
            report "  A FAIL: cache LOGIC itself returns stale -> Bug 2 is in cpu_cache.vhd"
                 severity warning;
        end if;

        -- Re-flush + restore golden for a clean scenario B.
        flush <= '1'; wait for 2 * CLK_PER; flush <= '0';
        for i in 0 to 1040 loop wait until rising_edge(clk); end loop;
        for a in GOLDEN_LO to GOLDEN_HI loop
            golden(a) <= to_unsigned((a * 5 + 16#37#) mod 256, 8);
        end loop;
        wait until rising_edge(clk);

        ----------------------------------------------------------------
        -- SCENARIO B: skewed fill, then RE-READ the SAME address as a HIT.
        -- Each address is isolated (no colliding access between fill and re-read)
        -- so the second read hits the line the skewed fill populated. If the
        -- skew is the corruptor, the hit returns golden(a-1) instead of golden(a).
        report "=== SCENARIO B: 1-cycle fill_data skew, read->reread (hit) ===";
        for k in 0 to 7 loop
            -- addresses $0100,$0108,... : distinct lines, no collisions
            cpu_read(16#0100# + k*8, 1, 16#0100# + k*8 - 8);  -- miss -> skewed fill
            cpu_read(16#0100# + k*8, 1, 16#0100# + k*8);      -- HIT -> exposes skew
        end loop;
        b_fails := fail_count - a_fails;
        report "SCENARIO B fails = " & integer'image(b_fails);
        if b_fails > 0 then
            report "  B REPRODUCES: a 1-cycle fill_data/fill_addr skew makes the cache"
                 & " serve stale bytes on the re-read HIT = the Doom Bug-2 signature."
                 & " Fix = align fill_data to fill_addr for the SuperRAM 3-stage pipeline.";
        else
            report "  B clean: even a skewed fill does NOT corrupt a re-read; suspect elsewhere.";
        end if;

        report "=== TOTAL fails (A+B) = " & integer'image(fail_count) & " ===";
        -- Only scenario A failing is a real DUT defect; B is a diagnostic probe.
        if a_fails /= 0 then
            report "=== BUG 2 IS IN CACHE LOGIC (scenario A failed) ===" severity failure;
        else
            report "=== DONE: A clean. See B verdict for the fill-wiring hypothesis. ===";
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
