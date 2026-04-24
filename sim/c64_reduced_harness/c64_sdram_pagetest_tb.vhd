-- c64_sdram_pagetest_tb.vhd
--
-- Minimal SDRAM correctness test for the $82xx-$8Exx corruption bug.
--
-- Test: write a unique pattern byte to each address in pages $80-$8F of
-- bank $00, then verify the stored byte via probe. If all bytes match,
-- the bug is NOT in this harness's ioctl -> fpga64_sid_iec -> simple_sdram
-- path -- it must be in c64.sv's real io_cycle state machine (not in
-- sim) or in sdram.v's chip-level controller (also not in sim).
--
-- Pattern: data = (addr XOR 0x42) AND 0xFF -- gives unique values,
-- catches bit-flip or stuck-at bugs, and any byte that reads as 0xFF
-- (the observed corruption value) will be flagged unless addr XOR 0x42
-- happens to equal 0xFF (1 in 256 addresses, we skip those).
--
-- Exit code 0 = all 4096 bytes match. Non-zero = mismatch count.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c64_sdram_pagetest_tb is
end entity;

architecture sim of c64_sdram_pagetest_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- ~32 MHz

    constant TEST_START : integer := 16#8000#;
    constant TEST_END   : integer := 16#8FFF#;  -- inclusive

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    signal ioctl_download : std_logic := '0';
    signal ioctl_wr       : std_logic := '0';
    signal ioctl_addr     : unsigned(15 downto 0) := (others => '0');
    signal ioctl_data     : std_logic_vector(7 downto 0) := (others => '0');
    signal ioctl_index    : std_logic_vector(7 downto 0) := x"01";

    signal probe_addr : unsigned(23 downto 0) := (others => '0');
    signal probe_data : std_logic_vector(7 downto 0);
    signal bram_probe_data : std_logic_vector(7 downto 0);

    signal dbg_pc      : unsigned(15 downto 0);
    signal dbg_pbr     : unsigned(7 downto 0);
    signal dbg_p       : unsigned(7 downto 0);
    signal dbg_ir      : unsigned(7 downto 0);
    signal dbg_addr    : unsigned(15 downto 0);
    signal dbg_data_in : std_logic_vector(7 downto 0);
    signal dbg_we      : std_logic;

    signal status_inj_busy   : std_logic;
    signal status_inj_end    : unsigned(15 downto 0);
    signal status_bram_inval : std_logic;
    signal status_rom_found  : std_logic;
    signal status_rom_src    : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;

    function expected_byte(a : integer) return std_logic_vector is
        variable v : unsigned(7 downto 0);
    begin
        v := to_unsigned(a mod 256, 8) xor x"42";
        return std_logic_vector(v);
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

    dut : entity work.c64_reduced_top_v2
        generic map (SDRAM_BYTES => 2 * 1024 * 1024)
        port map (
            clk32            => clk,
            reset            => reset,
            ioctl_download   => ioctl_download,
            ioctl_wr         => ioctl_wr,
            ioctl_addr       => ioctl_addr,
            ioctl_data       => ioctl_data,
            ioctl_index      => ioctl_index,
            probe_addr       => probe_addr,
            probe_data       => probe_data,
            bram_probe_data  => bram_probe_data,
            dbg_pc           => dbg_pc,
            dbg_pbr          => dbg_pbr,
            dbg_p            => dbg_p,
            dbg_ir           => dbg_ir,
            dbg_addr         => dbg_addr,
            dbg_data_in      => dbg_data_in,
            dbg_we           => dbg_we,
            status_inj_busy  => status_inj_busy,
            status_inj_end   => status_inj_end,
            status_bram_inval=> status_bram_inval,
            status_rom_found => status_rom_found,
            status_rom_src   => status_rom_src
        );

    stim : process
        variable mismatches : integer := 0;
        variable bram_mismatches : integer := 0;
        variable expected   : std_logic_vector(7 downto 0);
        variable first_bad  : integer := -1;
        variable first_bad_bram : integer := -1;
    begin
        -- Reset
        reset <= '1';
        wait for 10 * CLK_PERIOD;
        reset <= '0';
        wait for 50 * CLK_PERIOD;

        -- Begin PRG-like ioctl load
        ioctl_download <= '1';
        wait for CLK_PERIOD;

        -- Header: set load addr = TEST_START
        ioctl_addr <= to_unsigned(0, 16);
        ioctl_data <= std_logic_vector(to_unsigned(TEST_START mod 256, 8));
        ioctl_wr   <= '1';
        wait for CLK_PERIOD;
        ioctl_wr   <= '0';
        wait for CLK_PERIOD;

        ioctl_addr <= to_unsigned(1, 16);
        ioctl_data <= std_logic_vector(to_unsigned(TEST_START / 256, 8));
        ioctl_wr   <= '1';
        wait for CLK_PERIOD;
        ioctl_wr   <= '0';
        wait for CLK_PERIOD;

        -- Data bytes: for each addr in [TEST_START..TEST_END], write pattern.
        -- ioctl_addr increments for each byte (matches c64.sv counter).
        for i in 0 to (TEST_END - TEST_START) loop
            ioctl_addr <= to_unsigned(i + 2, 16);
            ioctl_data <= expected_byte(TEST_START + i);
            ioctl_wr   <= '1';
            wait for CLK_PERIOD;
            ioctl_wr   <= '0';
            -- Allow prg_load_sm to drain ioctl_req_wr -> io_cycle_we -> SDRAM write
            wait for 4 * CLK_PERIOD;
        end loop;

        -- End download
        ioctl_download <= '0';
        -- Wait for inj_meminit to complete (256 cycles worst case)
        wait for 2000 * CLK_PERIOD;

        -- Probe: read back every byte from BOTH SDRAM and BRAM Port C
        for a in TEST_START to TEST_END loop
            probe_addr <= to_unsigned(a, 24);
            wait for 2 * CLK_PERIOD;   -- settle (BRAM Port C has 1-clk latency)
            expected := expected_byte(a);
            if probe_data /= expected then
                if first_bad < 0 then
                    first_bad := a;
                end if;
                mismatches := mismatches + 1;
            end if;
            if bram_probe_data /= expected then
                if first_bad_bram < 0 then
                    first_bad_bram := a;
                end if;
                bram_mismatches := bram_mismatches + 1;
            end if;
        end loop;

        report "=== SDRAM + BRAM page test results ===";
        report "Address range: 0x" & integer'image(TEST_START) & " .. 0x" & integer'image(TEST_END);
        report "SDRAM mismatches: " & integer'image(mismatches) & " / " & integer'image(TEST_END - TEST_START + 1);
        report "BRAM  mismatches: " & integer'image(bram_mismatches) & " / " & integer'image(TEST_END - TEST_START + 1);
        if first_bad >= 0 then
            report "First bad SDRAM addr: 0x" & integer'image(first_bad);
        end if;
        if first_bad_bram >= 0 then
            report "First bad BRAM  addr: 0x" & integer'image(first_bad_bram);
        end if;

        if mismatches = 0 and bram_mismatches = 0 then
            report "PASS (both paths)" severity note;
        elsif mismatches = 0 and bram_mismatches > 0 then
            report "FAIL -- BRAM write path is broken. Option D cannot work. Fix io_bram_we -> bram_port_a_we wiring." severity failure;
        elsif mismatches > 0 and bram_mismatches = 0 then
            report "FAIL -- SDRAM write path broken but BRAM is fine." severity failure;
        else
            report "FAIL -- BOTH SDRAM and BRAM paths broken." severity failure;
        end if;

        sim_done <= true;
        wait;
    end process;

end architecture;
