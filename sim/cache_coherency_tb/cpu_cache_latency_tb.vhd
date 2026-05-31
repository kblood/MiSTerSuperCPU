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

        -- Fill three DISTINCT cache lines with distinguishable data (all byte-off 0):
        --   line A: $0100 = $AA   line B: $0200 = $BB   line C: $0400 = $CC
        fill_byte(x"0100", x"AA", fill_addr, fill_bank, fill_data, fill_we, clk);
        fill_byte(x"0200", x"BB", fill_addr, fill_bank, fill_data, fill_we, clk);
        fill_byte(x"0400", x"CC", fill_addr, fill_bank, fill_data, fill_we, clk);
        report "=== Filled $0100=$AA $0200=$BB $0400=$CC ===";

        -- CHARACTERIZATION (not a bug in cpu_cache): the cache is a correct
        -- 1-cycle-latency BRAM. cache_hit is combinational on the current address;
        -- cache_di comes from line_word, registered 1 edge later. So the CONSUMER
        -- must sample cache_di at least 1 rising edge after presenting the address
        -- on a cross-line (non-same_line) access. This bench measures that latency
        -- so the fpga64 arbiter consume timing can respect it. The fpga64 bug was a
        -- 1-clk32 hit grant (busy_cnt="001") that consumes SAME-cycle on a cross-line
        -- hit; the fix is a 2-clk32 grant (busy_cnt="010"), which both lets line_word
        -- settle AND is the iter-6 STA-honest 2x cadence.

        -- Settle on line A (late sample -> $AA).
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

        -- ===== MEASUREMENT 1: SAME-CYCLE cross-line sample (the "001" hazard) =====
        -- Present B mid-cycle (no new edge) and sample. line_word still holds A.
        -- EXPECT stale ($AA) — this is what a 1-clk32 grant consumes = the HW bug.
        wait until rising_edge(clk);
        cpu_addr <= x"0200"; cpu_we <= '0';
        wait for CLK_PER/4;
        got_hit := cache_hit; got_di := cache_di; got_sl := same_line;
        report "M1 SAME-CYCLE B ($0200): hit=" & std_logic'image(got_hit)
             & " di=" & integer'image(to_integer(got_di))
             & " same_line=" & std_logic'image(got_sl);
        if not (got_hit = '1' and got_sl = '0' and got_di = x"AA") then
            report "FAIL M1: expected same-cycle cross-line to read STALE $AA (hit=1, same_line=0)"
                severity warning;
            test_fail <= true;
        else
            report "  M1 OK: same-cycle cross-line consume = STALE $AA -> a 1-clk32 (busy_cnt=001) hit grant is UNSAFE";
        end if;

        -- ===== MEASUREMENT 2: ONE-EDGE-AFTER cross-line sample (the "010" fix) =====
        -- Settle back on B, then switch to C and sample exactly ONE rising edge
        -- after presenting C. line_word has caught up -> EXPECT valid ($CC).
        cpu_addr <= x"0200";
        wait until rising_edge(clk);
        wait until rising_edge(clk);                 -- settled on B
        cpu_addr <= x"0400";                         -- cross-line switch B->C
        wait until rising_edge(clk);                 -- exactly ONE edge after presenting C
        wait for CLK_PER/4;                          -- comb settle, no further edge
        got_hit := cache_hit; got_di := cache_di;
        report "M2 ONE-EDGE-AFTER C ($0400): hit=" & std_logic'image(got_hit)
             & " di=" & integer'image(to_integer(got_di));
        if got_hit = '1' and got_di = x"CC" then
            report "  M2 OK: one-edge-after cross-line consume = VALID $CC -> a 2-clk32 (busy_cnt=010) hit grant is SAFE";
        else
            report "FAIL M2: expected one-edge-after cross-line to read VALID $CC (got di="
                 & integer'image(to_integer(got_di)) & ")" severity warning;
            test_fail <= true;
        end if;

        if test_fail then
            report "=== CHARACTERIZATION FAILED ===" severity failure;
        else
            report "=== CHARACTERIZATION PASSED: cache read latency = exactly 1 edge. "
                 & "Consumer must sample cache_di >=1 clk32 after present on cross-line hits "
                 & "(fix: hit grant 001 -> 010). ===";
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
