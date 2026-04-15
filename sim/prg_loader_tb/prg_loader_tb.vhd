-- prg_loader_tb.vhd
--
-- GHDL testbench that reproduces the MiSTer SuperCPU PRG-load path end to
-- end without any hardware. It drives a canned byte stream at a behavioral
-- ioctl interface, runs the real inj_meminit state machine (reimplemented
-- behaviorally in prg_loader_dut.vhd), exercises the bram_invalidate /
-- cache-flush gate, and then reads the BRAM back through a CPU-style read
-- port to verify:
--
--   * every payload byte landed at the correct address
--   * the BASIC zero-page pointers ($2B/$2C, $2D/$2E, $AE/$AF, etc) match
--     the expected inj_end value after meminit
--   * no stale pre-load byte survives in the tiny cache stub across the
--     invalidation window
--
-- Three scenarios are run back-to-back in one elaboration:
--   S1: clean PRG load at $0801 (LDA #$42; STA $0400; RTS)
--   S2: same payload at $1000 (checks page-valid bitmap for non-$0801 pages)
--   S3: S1 with a "cold read" burst during the download window so that a
--       missing fill-gate would capture stale $00s and the post-load
--       readback would see garbage instead of the payload.
--
-- Failure path: any assertion mismatch calls `report ... severity failure`
-- which makes GHDL exit with a non-zero status, so the runner can propagate
-- it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.prg_loader_pkg.all;

entity prg_loader_tb is
end entity;

architecture sim of prg_loader_tb is

    -- Clock: 32 MHz-ish; only period matters.
    constant CLK_PERIOD : time := 31250 ps;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- ioctl pseudo-interface
    signal ioctl_download : std_logic := '0';
    signal ioctl_wr       : std_logic := '0';
    signal ioctl_addr     : unsigned(15 downto 0) := (others => '0');
    signal ioctl_data     : std_logic_vector(7 downto 0) := (others => '0');
    signal ioctl_index    : std_logic_vector(7 downto 0) := x"01";

    -- CPU read probe
    signal cpu_rd_en    : std_logic := '0';
    signal cpu_rd_addr  : unsigned(15 downto 0) := (others => '0');
    signal cpu_rd_data  : std_logic_vector(7 downto 0);
    signal cpu_rd_valid : std_logic;

    signal status_inj_busy   : std_logic;
    signal status_inj_end    : unsigned(15 downto 0);
    signal status_bram_inval : std_logic;

    -- End-of-sim flag
    signal sim_done : boolean := false;

    -- Canned test payload: small 6510 snippet starting at $0801
    --   A9 42      LDA #$42
    --   8D 00 04   STA $0400
    --   60         RTS
    constant PRG_S1_LOAD_LO : std_logic_vector(7 downto 0) := x"01";
    constant PRG_S1_LOAD_HI : std_logic_vector(7 downto 0) := x"08";
    constant PRG_S1_PAYLOAD : byte_array_t := (
        0 => x"A9",
        1 => x"42",
        2 => x"8D",
        3 => x"00",
        4 => x"04",
        5 => x"60"
    );

    -- Same payload but loaded at $1000
    constant PRG_S2_LOAD_LO : std_logic_vector(7 downto 0) := x"00";
    constant PRG_S2_LOAD_HI : std_logic_vector(7 downto 0) := x"10";
    constant PRG_S2_PAYLOAD : byte_array_t := PRG_S1_PAYLOAD;

    ------------------------------------------------------------------
    -- Helpers
    ------------------------------------------------------------------
    procedure tick(signal clk : std_logic; n : natural) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

    -- Drive one header+payload PRG byte-stream through the ioctl iface.
    -- Matches the real HPS/ioctl semantics: ioctl_download held high the
    -- whole time, ioctl_addr is a running byte count, ioctl_wr is a
    -- 1-cycle pulse per byte, and we wait for ioctl_req_wr (indirectly by
    -- counting clocks) between bytes so the io_cycle can drain.
    procedure push_prg(
        signal clk            : in    std_logic;
        signal ioctl_download : out   std_logic;
        signal ioctl_wr       : out   std_logic;
        signal ioctl_addr     : out   unsigned(15 downto 0);
        signal ioctl_data     : out   std_logic_vector(7 downto 0);
        constant load_lo      : in    std_logic_vector(7 downto 0);
        constant load_hi      : in    std_logic_vector(7 downto 0);
        constant payload      : in    byte_array_t
    ) is
        variable ba : unsigned(15 downto 0) := (others => '0');
    begin
        ioctl_download <= '1';
        wait until rising_edge(clk);

        -- byte 0: header low
        ioctl_addr <= ba;
        ioctl_data <= load_lo;
        ioctl_wr   <= '1';
        wait until rising_edge(clk);
        ioctl_wr   <= '0';
        wait until rising_edge(clk);
        ba := ba + 1;

        -- byte 1: header high
        ioctl_addr <= ba;
        ioctl_data <= load_hi;
        ioctl_wr   <= '1';
        wait until rising_edge(clk);
        ioctl_wr   <= '0';
        wait until rising_edge(clk);
        ba := ba + 1;

        -- payload bytes
        for i in payload'range loop
            ioctl_addr <= ba;
            ioctl_data <= payload(i);
            ioctl_wr   <= '1';
            wait until rising_edge(clk);
            ioctl_wr   <= '0';
            -- allow io_cycle to consume + advance ioctl_load_addr
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            ba := ba + 1;
        end loop;

        ioctl_download <= '0';
    end procedure;

    -- Read one byte from the DUT via the CPU-style probe
    procedure read_byte(
        signal   clk          : in    std_logic;
        signal   cpu_rd_en    : out   std_logic;
        signal   cpu_rd_addr  : out   unsigned(15 downto 0);
        signal   cpu_rd_valid : in    std_logic;
        signal   cpu_rd_data  : in    std_logic_vector(7 downto 0);
        constant addr         : in    unsigned(15 downto 0);
        variable result       : out   std_logic_vector(7 downto 0)
    ) is
    begin
        cpu_rd_addr <= addr;
        cpu_rd_en   <= '1';
        wait until rising_edge(clk);
        cpu_rd_en   <= '0';
        -- data is ready on the next clock (cpu_rd_valid_r is a 1-cycle latch)
        wait until rising_edge(clk);
        result := cpu_rd_data;
    end procedure;

begin

    ------------------------------------------------------------------
    -- Clock + reset
    ------------------------------------------------------------------
    clkgen : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    rstgen : process
    begin
        reset <= '1';
        wait for 4 * CLK_PERIOD;
        wait until rising_edge(clk);
        reset <= '0';
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------------
    dut : entity work.prg_loader_dut
        port map (
            clk               => clk,
            reset             => reset,
            ioctl_download    => ioctl_download,
            ioctl_wr          => ioctl_wr,
            ioctl_addr        => ioctl_addr,
            ioctl_data        => ioctl_data,
            ioctl_index       => ioctl_index,
            cpu_rd_en         => cpu_rd_en,
            cpu_rd_addr       => cpu_rd_addr,
            cpu_rd_data       => cpu_rd_data,
            cpu_rd_valid      => cpu_rd_valid,
            status_inj_busy   => status_inj_busy,
            status_inj_end    => status_inj_end,
            status_bram_inval => status_bram_inval
        );

    ------------------------------------------------------------------
    -- Stimulus + scoreboard
    ------------------------------------------------------------------
    stim : process

        variable load_start : unsigned(15 downto 0);
        variable inj_end_v  : unsigned(15 downto 0);

        variable pass_cnt : integer := 0;
        variable fail_cnt : integer := 0;

        procedure check_byte(
            constant lbl : in string;
            constant addr  : in unsigned(15 downto 0);
            constant exp   : in std_logic_vector(7 downto 0)
        ) is
            variable rb : std_logic_vector(7 downto 0);
        begin
            read_byte(clk, cpu_rd_en, cpu_rd_addr, cpu_rd_valid, cpu_rd_data,
                      addr, rb);
            if rb = exp then
                report lbl & ": OK  " & hex4(std_logic_vector(addr))
                              & " = $" & hex2(rb);
                pass_cnt := pass_cnt + 1;
            else
                report lbl & ": FAIL " & hex4(std_logic_vector(addr))
                              & " got $" & hex2(rb) & " expected $" & hex2(exp)
                       severity error;
                fail_cnt := fail_cnt + 1;
            end if;
        end procedure;

        procedure verify_payload(
            constant load_addr : in unsigned(15 downto 0);
            constant payload   : in byte_array_t;
            constant lbl     : in string
        ) is
            variable a : unsigned(15 downto 0);
        begin
            for i in payload'range loop
                a := load_addr + to_unsigned(i, 16);
                check_byte(lbl & " payload[" & integer'image(i) & "]",
                           a, payload(i));
            end loop;
        end procedure;

        procedure verify_basic_pointers(
            constant inj_end_val : in unsigned(15 downto 0);
            constant lbl       : in string
        ) is
            variable ez : expected_zp_t;
        begin
            ez := make_expected_zp(inj_end_val);
            check_byte(lbl & " TXT_LO  ($2B)", to_unsigned(16#2B#, 16), ez.txt_lo);
            check_byte(lbl & " TXT_HI  ($2C)", to_unsigned(16#2C#, 16), ez.txt_hi);
            check_byte(lbl & " VAR_LO  ($2D)", to_unsigned(16#2D#, 16), ez.var_lo);
            check_byte(lbl & " VAR_HI  ($2E)", to_unsigned(16#2E#, 16), ez.var_hi);
            check_byte(lbl & " ARY_LO  ($2F)", to_unsigned(16#2F#, 16), ez.ary_lo);
            check_byte(lbl & " ARY_HI  ($30)", to_unsigned(16#30#, 16), ez.ary_hi);
            check_byte(lbl & " STR_LO  ($31)", to_unsigned(16#31#, 16), ez.str_lo);
            check_byte(lbl & " STR_HI  ($32)", to_unsigned(16#32#, 16), ez.str_hi);
            check_byte(lbl & " SAVE_LO ($AC)", to_unsigned(16#AC#, 16), ez.save_lo);
            check_byte(lbl & " SAVE_HI ($AD)", to_unsigned(16#AD#, 16), ez.save_hi);
            check_byte(lbl & " LDEND_LO($AE)", to_unsigned(16#AE#, 16), ez.load_end_lo);
            check_byte(lbl & " LDEND_HI($AF)", to_unsigned(16#AF#, 16), ez.load_end_hi);
        end procedure;

    begin
        -- Wait for reset release
        wait until reset = '0';
        tick(clk, 4);

        ----------------------------------------------------------------
        -- Scenario 1: clean PRG at $0801
        ----------------------------------------------------------------
        report "==== Scenario 1: PRG at $0801 (no cold reads) ====";
        push_prg(clk, ioctl_download, ioctl_wr, ioctl_addr, ioctl_data,
                 PRG_S1_LOAD_LO, PRG_S1_LOAD_HI, PRG_S1_PAYLOAD);

        -- Give the DUT a couple of cycles to detect the falling edge of
        -- ioctl_download and kick inj_meminit high before we wait on its
        -- fall. Without this, the while-loop can read '0' on the very
        -- first iteration and exit before meminit has even started.
        tick(clk, 2);
        while status_inj_busy /= '0' loop
            wait until rising_edge(clk);
        end loop;
        tick(clk, 4);

        inj_end_v := status_inj_end;
        report "S1 inj_end = $" & hex4(std_logic_vector(inj_end_v));
        load_start := to_unsigned(16#0801#, 16);
        verify_payload(load_start, PRG_S1_PAYLOAD, "S1");
        verify_basic_pointers(inj_end_v, "S1");

        ----------------------------------------------------------------
        -- Scenario 2: PRG at $1000
        ----------------------------------------------------------------
        report "==== Scenario 2: PRG at $1000 (non-$0801 page) ====";
        push_prg(clk, ioctl_download, ioctl_wr, ioctl_addr, ioctl_data,
                 PRG_S2_LOAD_LO, PRG_S2_LOAD_HI, PRG_S2_PAYLOAD);

        tick(clk, 2);
        while status_inj_busy /= '0' loop
            wait until rising_edge(clk);
        end loop;
        tick(clk, 4);

        inj_end_v := status_inj_end;
        report "S2 inj_end = $" & hex4(std_logic_vector(inj_end_v));
        load_start := to_unsigned(16#1000#, 16);
        verify_payload(load_start, PRG_S2_PAYLOAD, "S2");
        verify_basic_pointers(inj_end_v, "S2");

        ----------------------------------------------------------------
        -- Scenario 3: PRG at $0801 with cold reads during the download.
        -- If the fill-gate is missing, these reads would latch stale $00s
        -- into the cache. Post-load reads should still see the payload
        -- because the flush pulse on the rising edge of bram_inval_hold
        -- clears the cache; the post-load CPU reads hit the page-valid
        -- BRAM instead.
        ----------------------------------------------------------------
        report "==== Scenario 3: PRG at $0801 + cold reads during load ====";

        -- Start the download manually so we can interleave reads
        ioctl_download <= '1';
        wait until rising_edge(clk);

        -- Fire a "cold read" burst at $0801..$0806 (BEFORE any write).
        -- These see the stale BRAM/cache contents ($00 on reset). A
        -- broken fill-gate would latch those into the cache; the rising
        -- edge pulse of bram_inval_hold fires cache_flush, so the bench
        -- still has to prove that the flush actually clears those lines.
        for burst in 0 to 5 loop
            cpu_rd_addr <= to_unsigned(16#0801# + burst, 16);
            cpu_rd_en   <= '1';
            wait until rising_edge(clk);
            cpu_rd_en   <= '0';
            wait until rising_edge(clk);
        end loop;

        -- Header low
        ioctl_addr <= (others => '0');
        ioctl_data <= PRG_S1_LOAD_LO;
        ioctl_wr   <= '1';
        wait until rising_edge(clk);
        ioctl_wr   <= '0';
        wait until rising_edge(clk);

        -- Header high
        ioctl_addr <= to_unsigned(1, 16);
        ioctl_data <= PRG_S1_LOAD_HI;
        ioctl_wr   <= '1';
        wait until rising_edge(clk);
        ioctl_wr   <= '0';
        wait until rising_edge(clk);

        -- Payload — interleave cold reads between each byte
        for i in PRG_S1_PAYLOAD'range loop
            ioctl_addr <= to_unsigned(2 + i, 16);
            ioctl_data <= PRG_S1_PAYLOAD(i);
            ioctl_wr   <= '1';
            wait until rising_edge(clk);
            ioctl_wr   <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);

            -- Cold read to the next unwritten byte (stale slot)
            cpu_rd_addr <= to_unsigned(16#0810# + i, 16);
            cpu_rd_en   <= '1';
            wait until rising_edge(clk);
            cpu_rd_en   <= '0';
            wait until rising_edge(clk);
        end loop;

        ioctl_download <= '0';

        tick(clk, 2);
        while status_inj_busy /= '0' loop
            wait until rising_edge(clk);
        end loop;
        tick(clk, 4);

        inj_end_v := status_inj_end;
        report "S3 inj_end = $" & hex4(std_logic_vector(inj_end_v));
        load_start := to_unsigned(16#0801#, 16);
        verify_payload(load_start, PRG_S1_PAYLOAD, "S3");
        verify_basic_pointers(inj_end_v, "S3");

        ----------------------------------------------------------------
        -- End of sim
        ----------------------------------------------------------------
        tick(clk, 10);
        report "==== SUMMARY: pass=" & integer'image(pass_cnt)
               & "  fail=" & integer'image(fail_cnt) & " ====";
        if fail_cnt /= 0 then
            sim_done <= true;
            report "prg_loader_tb: FAIL" severity failure;
        else
            report "prg_loader_tb: PASS" severity note;
            sim_done <= true;
            wait;
        end if;
    end process;

end architecture;
