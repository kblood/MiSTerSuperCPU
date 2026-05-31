-- cpu_cache_fillonhit_tb.vhd — reproduce the iter-7c FILL-ON-HIT self-corruption
--
-- fpga64_sid_iec.vhd:4872 wires the read-path fill enable as:
--   rp_fill_we <= enableCpu_816 and (vda or vpa) and (not cpuWe) and rp_cacheable;
-- i.e. it is NOT gated on rp_cache_hit. So the cache re-fills on EVERY cacheable
-- read, including hits. And fill_data => cpuDi (:4885), while on a hit
-- cpuDi <= rp_cache_di (:1965). So on a hit the cache writes its OWN output back.
--
-- Because line_word is a REGISTERED 1-cycle-late read (cpu_cache.vhd:284-296),
-- on a CROSS-LINE hit cycle cache_di still holds the PREVIOUS line's byte. With
-- fill_we=1 and fill_addr = the NEW line, that stale byte is written into the
-- NEW line's data bank => permanent self-inflicted corruption of cached content.
--
-- This bench faithfully models that feedback: while switching cpu_addr across a
-- line boundary, it drives fill_addr=new-addr, fill_data=current(stale) cache_di,
-- fill_we=1 — exactly the fpga64 wiring — then re-reads the new line settled.
--
-- FAIL (bug present) = the new line reads back the OTHER line's byte.
-- PASS (fixed)       = the new line still reads its own byte (fill suppressed on hit).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_fillonhit_tb is
end entity;

architecture sim of cpu_cache_fillonhit_tb is
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

    -- Set FILL_ON_HIT=false to model the proposed fix (fill gated on not-hit).
    constant FILL_ON_HIT : boolean := false;

    signal test_done : boolean := false;
    signal test_fail : boolean := false;

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
        variable got_di : unsigned(7 downto 0);
        variable fail_v : boolean := false;
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

        -- Two distinct lines: $0100=$AA, $0200=$BB (different line_index, byte 0).
        fill_byte(x"0100", x"AA", fill_addr, fill_bank, fill_data, fill_we, clk);
        fill_byte(x"0200", x"BB", fill_addr, fill_bank, fill_data, fill_we, clk);
        report "=== Filled $0100=$AA $0200=$BB ===";

        -- Settle a READ on line A so line_word holds A's data ($AA).
        cpu_addr <= x"0100"; cpu_we <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        report "SETTLED A: $0100 hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(cache_di));

        -- CROSS-LINE hit cycle to B, modelling fpga64: present B, and on this same
        -- cycle drive fill_addr=B, fill_data=current(stale) cache_di, fill_we=1
        -- (gated on hit only when FILL_ON_HIT — the proposed fix sets it false).
        cpu_addr <= x"0200";
        wait for CLK_PER/4;            -- comb settle: cache_hit=1, cache_di still $AA (stale)
        report "CROSS-LINE B presented: hit=" & std_logic'image(cache_hit)
             & " stale di=" & integer'image(to_integer(cache_di))
             & " same_line=" & std_logic'image(same_line);
        if FILL_ON_HIT then
            -- fpga64 wiring: fill fires on the hit, writing stale cache_di back to B.
            fill_addr <= x"0200"; fill_bank <= x"00";
            fill_data <= cache_di;     -- = $AA stale (this is cpuDi on the hit)
            fill_we   <= '1';
        end if;
        wait until rising_edge(clk);   -- write latches here
        fill_we <= '0';
        wait until rising_edge(clk);

        -- Now re-read line B, fully settled. If fill-on-hit corrupted it, we read $AA.
        cpu_addr <= x"0200"; cpu_we <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        wait for CLK_PER/4;
        got_di := cache_di;
        report "RE-READ B ($0200): hit=" & std_logic'image(cache_hit)
             & " di=" & integer'image(to_integer(got_di));
        if got_di = x"BB" then
            report "  OK: line B intact ($BB) -- no fill-on-hit corruption";
        else
            report "FAIL: line B corrupted -> di=" & integer'image(to_integer(got_di))
                 & " (expected $BB=187; $AA=170 means stale A leaked via fill-on-hit)"
                 severity warning;
            fail_v := true;
        end if;
        test_fail <= fail_v;

        if fail_v then
            report "=== FILL-ON-HIT BENCH: BUG REPRODUCED ===" severity failure;
        else
            report "=== FILL-ON-HIT BENCH: clean (fill suppressed on hit) ===";
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
