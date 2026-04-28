-- bank01_sram_tb.vhd
--
-- Phase D / Task #12: unit-level test for the bank-$01 SRAM shadow added
-- to fpga64_buslogic.vhd. Instantiates the real buslogic entity and drives
-- supercpu_en/supercpu_bank/cpuAddr/cpuData/cpuWe directly to verify:
--
--   Scenario 1: write pattern bytes to bank-$01 addresses, read them back,
--               expect dataToCpu carries the written bytes (proves bank01
--               dprom captures writes and intercepts reads).
--
--   Scenario 2: write a different pattern to bank-$02 (drives ramData
--               input as if SDRAM SuperRAM returned that value), read
--               back, expect dataToCpu carries ramData (proves bank-$02
--               still routes to SuperRAM, NOT to bank01 dprom).
--
--   Scenario 3: cross-bank isolation — write to $01:1234, then drive
--               bank=$02 with ramData=$BB at same cpuAddr=$1234. Expect
--               dataToCpu=$BB (bank-$02 SuperRAM mirror), then switch
--               back to bank=$01 with ramData=$00 and expect the
--               originally-stored bank-$01 byte.
--
-- Exit code 0 = PASS, non-zero = FAIL.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bank01_sram_tb is
end entity;

architecture sim of bank01_sram_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- 32 MHz

    signal clk          : std_logic := '0';
    signal reset        : std_logic := '1';

    -- fpga64_buslogic inputs we care about
    signal cpuHasBus    : std_logic := '1';
    signal aec          : std_logic := '1';
    signal bios         : std_logic_vector(1 downto 0) := "00";
    signal ramData      : unsigned(7 downto 0) := (others => '0');
    signal bankSwitch   : unsigned(2 downto 0) := "111";  -- LORAM/HIRAM/CHAREN all 1
    signal game         : std_logic := '1';
    signal exrom        : std_logic := '1';
    signal io_rom       : std_logic := '0';
    signal io_ext       : std_logic := '0';
    signal io_data      : unsigned(7 downto 0) := (others => '0');
    signal c64rom_addr  : std_logic_vector(13 downto 0) := (others => '0');
    signal c64rom_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal c64rom_wr    : std_logic := '0';
    signal supercpu_en       : std_logic := '1';
    signal supercpu_rom      : std_logic := '0';
    signal supercpu_rom_vis  : std_logic := '0';
    signal supercpu_bank     : std_logic_vector(7 downto 0) := x"00";
    signal cpuWe        : std_logic := '0';
    signal cpuAddr      : unsigned(15 downto 0) := (others => '0');
    signal cpuData      : unsigned(7 downto 0) := (others => '0');
    signal vicAddr      : unsigned(15 downto 0) := (others => '0');
    signal vicData      : unsigned(7 downto 0) := (others => '0');
    signal sidData      : unsigned(7 downto 0) := (others => '0');
    signal colorData    : unsigned(3 downto 0) := (others => '0');
    signal cia1Data     : unsigned(7 downto 0) := (others => '0');
    signal cia2Data     : unsigned(7 downto 0) := (others => '0');
    signal lastVicData  : unsigned(7 downto 0) := (others => '0');
    signal io_enable    : std_logic := '1';

    -- fpga64_buslogic outputs
    signal systemWe     : std_logic;
    signal systemAddr   : unsigned(15 downto 0);
    signal dataToCpu    : unsigned(7 downto 0);
    signal dataToVic    : unsigned(7 downto 0);
    signal cs_vic       : std_logic;
    signal cs_sid       : std_logic;
    signal cs_color     : std_logic;
    signal cs_cia1      : std_logic;
    signal cs_cia2      : std_logic;
    signal cs_ram       : std_logic;
    signal cs_ioE       : std_logic;
    signal cs_ioF       : std_logic;
    signal cs_ioF_raw   : std_logic;
    signal cs_romL      : std_logic;
    signal cs_romH      : std_logic;
    signal cs_UMAXromH  : std_logic;

    signal sim_done : boolean := false;

    -- Test address set: 4 representative addresses across the 64KB range
    type addr_arr_t is array (0 to 3) of integer;
    constant TEST_ADDRS : addr_arr_t := (16#0000#, 16#1234#, 16#8000#, 16#FFFF#);

    -- Pattern: byte = addr_lo XOR addr_hi XOR seed
    function pat(a : integer; seed : integer) return unsigned is
        variable lo : unsigned(7 downto 0);
        variable hi : unsigned(7 downto 0);
        variable sd : unsigned(7 downto 0);
    begin
        lo := to_unsigned(a mod 256, 8);
        hi := to_unsigned((a / 256) mod 256, 8);
        sd := to_unsigned(seed mod 256, 8);
        return lo xor hi xor sd;
    end function;

    procedure tick(signal clk : std_logic; n : natural) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

begin

    -- Clock generator
    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

    -- DUT
    dut : entity work.fpga64_buslogic
        port map (
            clk              => clk,
            reset            => reset,
            bios             => bios,
            cpuHasBus        => cpuHasBus,
            aec              => aec,
            ramData          => ramData,
            bankSwitch       => bankSwitch,
            game             => game,
            exrom            => exrom,
            io_rom           => io_rom,
            io_ext           => io_ext,
            io_data          => io_data,
            c64rom_addr      => c64rom_addr,
            c64rom_data      => c64rom_data,
            c64rom_wr        => c64rom_wr,
            supercpu_en      => supercpu_en,
            supercpu_rom     => supercpu_rom,
            supercpu_rom_vis => supercpu_rom_vis,
            supercpu_bank    => supercpu_bank,
            cpuWe            => cpuWe,
            cpuAddr          => cpuAddr,
            cpuData          => cpuData,
            vicAddr          => vicAddr,
            vicData          => vicData,
            sidData          => sidData,
            colorData        => colorData,
            cia1Data         => cia1Data,
            cia2Data         => cia2Data,
            lastVicData      => lastVicData,
            io_enable        => io_enable,
            systemWe         => systemWe,
            systemAddr       => systemAddr,
            dataToCpu        => dataToCpu,
            dataToVic        => dataToVic,
            cs_vic           => cs_vic,
            cs_sid           => cs_sid,
            cs_color         => cs_color,
            cs_cia1          => cs_cia1,
            cs_cia2          => cs_cia2,
            cs_ram           => cs_ram,
            cs_ioE           => cs_ioE,
            cs_ioF           => cs_ioF,
            cs_ioF_raw       => cs_ioF_raw,
            cs_romL          => cs_romL,
            cs_romH          => cs_romH,
            cs_UMAXromH      => cs_UMAXromH
        );

    stim : process
        variable pass_cnt : integer := 0;
        variable fail_cnt : integer := 0;
        variable expected : unsigned(7 downto 0);

        procedure check(constant lbl : in string; constant got : in unsigned(7 downto 0); constant exp : in unsigned(7 downto 0)) is
        begin
            if got = exp then
                pass_cnt := pass_cnt + 1;
                report "PASS: " & lbl &
                    " got=0x" & to_hstring(got) & " exp=0x" & to_hstring(exp);
            else
                fail_cnt := fail_cnt + 1;
                report "FAIL: " & lbl &
                    " got=0x" & to_hstring(got) & " exp=0x" & to_hstring(exp) severity error;
            end if;
        end procedure;

        procedure write_bank01(constant addr : in integer; constant data : in unsigned(7 downto 0)) is
        begin
            wait until rising_edge(clk);
            supercpu_bank <= x"01";
            cpuAddr       <= to_unsigned(addr, 16);
            cpuData       <= data;
            cpuWe         <= '1';
            wait until rising_edge(clk);
            cpuWe         <= '0';
        end procedure;

        procedure read_bank(constant bank : in integer; constant addr : in integer; constant ramVal : in unsigned(7 downto 0)) is
        begin
            wait until rising_edge(clk);
            supercpu_bank <= std_logic_vector(to_unsigned(bank, 8));
            cpuAddr       <= to_unsigned(addr, 16);
            cpuWe         <= '0';
            ramData       <= ramVal;
            -- dprom read latency = 1 clk; combinational mux samples q_d1
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            -- dataToCpu now reflects bank01_sram_q (if bank=$01) or ramData (if bank>=$02)
        end procedure;

    begin
        -- Reset
        reset <= '1';
        tick(clk, 10);
        reset <= '0';
        tick(clk, 5);

        report "=== Scenario 1: bank-$01 write+read round-trip ===";
        for i in TEST_ADDRS'range loop
            write_bank01(TEST_ADDRS(i), pat(TEST_ADDRS(i), 16#5A#));
        end loop;

        -- Allow dprom write to commit
        tick(clk, 4);

        for i in TEST_ADDRS'range loop
            read_bank(16#01#, TEST_ADDRS(i), x"00");
            expected := pat(TEST_ADDRS(i), 16#5A#);
            check("S1 bank01 read addr=0x" & to_hstring(to_unsigned(TEST_ADDRS(i), 16)),
                  dataToCpu, expected);
        end loop;

        report "=== Scenario 2: bank-$02 still routes to ramData ===";
        for i in TEST_ADDRS'range loop
            -- Drive bank=$02 with a synthetic ramData (as if SDRAM returned it)
            read_bank(16#02#, TEST_ADDRS(i), pat(TEST_ADDRS(i), 16#A5#));
            expected := pat(TEST_ADDRS(i), 16#A5#);
            check("S2 bank02 read addr=0x" & to_hstring(to_unsigned(TEST_ADDRS(i), 16)),
                  dataToCpu, expected);
        end loop;

        report "=== Scenario 3: cross-bank independence ===";
        -- Bank-$01 still has the seed=0x5A pattern from S1.
        -- Read bank-$02 with ramData=0xBB; expect 0xBB (SDRAM mirror), NOT bank01 byte.
        read_bank(16#02#, 16#1234#, x"BB");
        check("S3 bank02 read returns ramData not bank01", dataToCpu, x"BB");

        -- Switch back to bank-$01 with ramData=0x00; expect the original
        -- bank-$01 byte for $1234, NOT 0x00 (proves dprom intercepted read).
        read_bank(16#01#, 16#1234#, x"00");
        expected := pat(16#1234#, 16#5A#);
        check("S3 bank01 read returns dprom value not ramData", dataToCpu, expected);

        report "=== Summary ===";
        report "PASS=" & integer'image(pass_cnt) & " FAIL=" & integer'image(fail_cnt);

        if fail_cnt = 0 then
            report "ALL PASS" severity note;
        else
            report integer'image(fail_cnt) & " checks failed" severity failure;
        end if;

        sim_done <= true;
        wait;
    end process;

end architecture;
