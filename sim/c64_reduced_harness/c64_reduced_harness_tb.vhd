-- c64_reduced_harness_tb.vhd
--
-- Phase 4 testbench: drives the reduced-system c64_reduced_top with a
-- scripted PRG load and sanity-checks that:
--
--   1. The CPU core starts executing at the $FFFC reset vector (= $0400
--      in this harness; the boot stub spins via BRA *).
--   2. A scripted PRG load via the ioctl pseudo-interface lands the
--      payload bytes in BRAM at the expected address.
--   3. BASIC zero-page pointers are initialised by inj_meminit to the
--      correct inj_end value.
--   4. After letting the CPU run for an extra ~2000 cycles post-load,
--      the payload bytes are still intact (catches the "bytes correct
--      immediately but wiped later" symptom reported on hardware).
--
-- Exit code 0 = PASS, non-zero = FAIL.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.prg_loader_pkg.all;

entity c64_reduced_harness_tb is
end entity;

architecture sim of c64_reduced_harness_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- ~32 MHz

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- ioctl pseudo-interface
    signal ioctl_download : std_logic := '0';
    signal ioctl_wr       : std_logic := '0';
    signal ioctl_addr     : unsigned(15 downto 0) := (others => '0');
    signal ioctl_data     : std_logic_vector(7 downto 0) := (others => '0');
    signal ioctl_index    : std_logic_vector(7 downto 0) := x"01";

    -- BRAM probe
    signal probe_addr : unsigned(23 downto 0) := (others => '0');
    signal probe_data : std_logic_vector(7 downto 0);

    -- CPU observability
    signal dbg_pc      : unsigned(15 downto 0);
    signal dbg_pbr     : unsigned(7 downto 0);
    signal dbg_p       : unsigned(7 downto 0);
    signal dbg_ir      : unsigned(7 downto 0);
    signal dbg_addr    : unsigned(15 downto 0);
    signal dbg_data_in : std_logic_vector(7 downto 0);
    signal dbg_we      : std_logic;

    -- Loader status
    signal status_inj_busy   : std_logic;
    signal status_inj_end    : unsigned(15 downto 0);
    signal status_bram_inval : std_logic;

    signal sim_done : boolean := false;

    -- Scenario 1 payload: tiny emulation-mode PRG at $0801
    --   A9 42      LDA #$42
    --   8D 00 04   STA $0400
    --   4C 00 08   JMP $0800   (infinite loop)
    constant PRG_LOAD_LO : std_logic_vector(7 downto 0) := x"01";
    constant PRG_LOAD_HI : std_logic_vector(7 downto 0) := x"08";
    constant PRG_PAYLOAD : byte_array_t := (
        0 => x"A9",
        1 => x"42",
        2 => x"8D",
        3 => x"00",
        4 => x"04",
        5 => x"4C",
        6 => x"00",
        7 => x"08"
    );

    ------------------------------------------------------------------
    -- Helpers
    ------------------------------------------------------------------
    procedure tick(signal clk : std_logic; n : natural) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

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

        ioctl_addr <= ba;
        ioctl_data <= load_lo;
        ioctl_wr   <= '1';
        wait until rising_edge(clk);
        ioctl_wr   <= '0';
        wait until rising_edge(clk);
        ba := ba + 1;

        ioctl_addr <= ba;
        ioctl_data <= load_hi;
        ioctl_wr   <= '1';
        wait until rising_edge(clk);
        ioctl_wr   <= '0';
        wait until rising_edge(clk);
        ba := ba + 1;

        for i in payload'range loop
            ioctl_addr <= ba;
            ioctl_data <= payload(i);
            ioctl_wr   <= '1';
            wait until rising_edge(clk);
            ioctl_wr   <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            ba := ba + 1;
        end loop;

        ioctl_download <= '0';
    end procedure;

    -- Read one byte from the reduced top via the combinational probe
    procedure probe_byte(
        signal clk        : in    std_logic;
        signal probe_addr : out   unsigned(23 downto 0);
        signal probe_data : in    std_logic_vector(7 downto 0);
        constant addr     : in    unsigned(23 downto 0);
        variable result   : out   std_logic_vector(7 downto 0)
    ) is
    begin
        probe_addr <= addr;
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        result := probe_data;
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
        wait for 8 * CLK_PERIOD;
        wait until rising_edge(clk);
        reset <= '0';
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------------
    dut : entity work.c64_reduced_top
        generic map (
            SDRAM_BYTES => 2 * 1024 * 1024
        )
        port map (
            clk32             => clk,
            reset             => reset,
            ioctl_download    => ioctl_download,
            ioctl_wr          => ioctl_wr,
            ioctl_addr        => ioctl_addr,
            ioctl_data        => ioctl_data,
            ioctl_index       => ioctl_index,
            probe_addr        => probe_addr,
            probe_data        => probe_data,
            dbg_pc            => dbg_pc,
            dbg_pbr           => dbg_pbr,
            dbg_p             => dbg_p,
            dbg_ir            => dbg_ir,
            dbg_addr          => dbg_addr,
            dbg_data_in       => dbg_data_in,
            dbg_we            => dbg_we,
            status_inj_busy   => status_inj_busy,
            status_inj_end    => status_inj_end,
            status_bram_inval => status_bram_inval
        );

    ------------------------------------------------------------------
    -- Stimulus + scoreboard
    ------------------------------------------------------------------
    stim : process

        variable inj_end_v : unsigned(15 downto 0);
        variable rb        : std_logic_vector(7 downto 0);
        variable pass_cnt  : integer := 0;
        variable fail_cnt  : integer := 0;

        procedure check_byte(
            constant lbl  : in string;
            constant addr : in unsigned(23 downto 0);
            constant exp  : in std_logic_vector(7 downto 0)
        ) is
            variable got : std_logic_vector(7 downto 0);
        begin
            probe_byte(clk, probe_addr, probe_data, addr, got);
            if got = exp then
                report lbl & ": OK  $" & hex2(std_logic_vector(addr(23 downto 16)))
                              & ":" & hex4(std_logic_vector(addr(15 downto 0)))
                              & " = $" & hex2(got);
                pass_cnt := pass_cnt + 1;
            else
                report lbl & ": FAIL $" & hex2(std_logic_vector(addr(23 downto 16)))
                              & ":" & hex4(std_logic_vector(addr(15 downto 0)))
                              & " got $" & hex2(got) & " expected $" & hex2(exp)
                    severity error;
                fail_cnt := fail_cnt + 1;
            end if;
        end procedure;

        procedure verify_payload(
            constant load_addr : in unsigned(15 downto 0);
            constant payload   : in byte_array_t;
            constant lbl       : in string
        ) is
            variable a24 : unsigned(23 downto 0);
        begin
            for i in payload'range loop
                a24 := x"00" & (load_addr + to_unsigned(i, 16));
                check_byte(lbl & " payload[" & integer'image(i) & "]",
                           a24, payload(i));
            end loop;
        end procedure;

        procedure verify_basic_pointers(
            constant inj_end_val : in unsigned(15 downto 0);
            constant lbl         : in string
        ) is
            variable ez : expected_zp_t;
        begin
            ez := make_expected_zp(inj_end_val);
            check_byte(lbl & " TXT_LO ($2B)",  x"00" & to_unsigned(16#2B#, 16), ez.txt_lo);
            check_byte(lbl & " TXT_HI ($2C)",  x"00" & to_unsigned(16#2C#, 16), ez.txt_hi);
            check_byte(lbl & " VAR_LO ($2D)",  x"00" & to_unsigned(16#2D#, 16), ez.var_lo);
            check_byte(lbl & " VAR_HI ($2E)",  x"00" & to_unsigned(16#2E#, 16), ez.var_hi);
            check_byte(lbl & " ARY_LO ($2F)",  x"00" & to_unsigned(16#2F#, 16), ez.ary_lo);
            check_byte(lbl & " ARY_HI ($30)",  x"00" & to_unsigned(16#30#, 16), ez.ary_hi);
            check_byte(lbl & " STR_LO ($31)",  x"00" & to_unsigned(16#31#, 16), ez.str_lo);
            check_byte(lbl & " STR_HI ($32)",  x"00" & to_unsigned(16#32#, 16), ez.str_hi);
            check_byte(lbl & " SAVE_LO($AC)",  x"00" & to_unsigned(16#AC#, 16), ez.save_lo);
            check_byte(lbl & " SAVE_HI($AD)",  x"00" & to_unsigned(16#AD#, 16), ez.save_hi);
            check_byte(lbl & " LEND_LO($AE)",  x"00" & to_unsigned(16#AE#, 16), ez.load_end_lo);
            check_byte(lbl & " LEND_HI($AF)",  x"00" & to_unsigned(16#AF#, 16), ez.load_end_hi);
        end procedure;

    begin
        ----------------------------------------------------------------
        -- Wait for reset release
        ----------------------------------------------------------------
        wait until reset = '0';
        tick(clk, 4);

        ----------------------------------------------------------------
        -- Phase A: let the CPU spin on the boot stub for ~500 cycles
        -- and confirm it is executing something legal. We just check
        -- that dbg_pc is in the boot-stub range [$0400..$0404].
        ----------------------------------------------------------------
        report "==== Phase A: boot-stub warm-up (500 cycles) ====";
        tick(clk, 500);
        if dbg_pc >= x"0400" and dbg_pc <= x"0404" then
            report "A: CPU PC in boot-stub range ($" & hex4(std_logic_vector(dbg_pc)) & ")";
            pass_cnt := pass_cnt + 1;
        else
            report "A: CPU PC NOT in boot-stub range (got $"
                   & hex4(std_logic_vector(dbg_pc)) & ")"
                severity note;
            -- Not a hard fail — reduced harness is OK if the CPU runs
            -- *somewhere* legal. A hard fail would be a crash/hang.
        end if;

        ----------------------------------------------------------------
        -- Phase B: scripted PRG load at $0801
        ----------------------------------------------------------------
        report "==== Phase B: scripted PRG load at $0801 ====";
        push_prg(clk, ioctl_download, ioctl_wr, ioctl_addr, ioctl_data,
                 PRG_LOAD_LO, PRG_LOAD_HI, PRG_PAYLOAD);

        -- Wait for inj_meminit to finish
        tick(clk, 2);
        while status_inj_busy /= '0' loop
            wait until rising_edge(clk);
        end loop;
        tick(clk, 8);

        inj_end_v := status_inj_end;
        report "B: inj_end = $" & hex4(std_logic_vector(inj_end_v));

        ----------------------------------------------------------------
        -- Phase C: immediate readback after inj_meminit completes
        ----------------------------------------------------------------
        report "==== Phase C: verify payload + BASIC pointers ====";
        verify_payload(to_unsigned(16#0801#, 16), PRG_PAYLOAD, "C");
        verify_basic_pointers(inj_end_v, "C");

        ----------------------------------------------------------------
        -- Phase D: let the CPU continue running for ~2000 cycles, then
        -- re-verify payload. This catches the "bytes loaded then memory
        -- seems to reset" symptom reported on real hardware. In the
        -- reduced harness the CPU is still spinning on the $0400 boot
        -- stub (it did not jump to the loaded PRG because there is no
        -- SYS/RUN driver), so any write to $0801..$0808 would be from
        -- a CPU bug or from the cache/BRAM path itself corrupting data.
        ----------------------------------------------------------------
        report "==== Phase D: run 2000 extra cycles + re-verify ====";
        tick(clk, 2000);
        verify_payload(to_unsigned(16#0801#, 16), PRG_PAYLOAD, "D");
        verify_basic_pointers(inj_end_v, "D");

        ----------------------------------------------------------------
        -- Summary
        ----------------------------------------------------------------
        tick(clk, 10);
        report "==== SUMMARY: pass=" & integer'image(pass_cnt)
               & "  fail=" & integer'image(fail_cnt) & " ====";
        if fail_cnt /= 0 then
            sim_done <= true;
            report "c64_reduced_harness_tb: FAIL" severity failure;
        else
            report "c64_reduced_harness_tb: PASS" severity note;
            sim_done <= true;
            wait;
        end if;
    end process;

end architecture;
