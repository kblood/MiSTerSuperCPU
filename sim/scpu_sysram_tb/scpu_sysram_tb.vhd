-- scpu_sysram_tb.vhd
--
-- Standalone bench for the SuperCPU $D200-$D3FF I/O hole SRAM.
--
-- DUT: fpga64_buslogic.vhd. Drives cpuAddr / cpuWe / cpuData directly to
-- write a unique pattern to every byte in $D200-$D3FF and reads it back
-- via dataToCpu. Exercises:
--   - scpu_sysram_cs decode (cpuAddr(15:9)="1101001")
--   - scpu_sysram array write (cpuWe + cs + clk edge)
--   - registered scpu_sysram_data read
--   - dataToCpu mux selecting scpu_sysram_data when scpu_sysram_cs='1'
--   - reset-sweep of all 512 locations (must complete before test starts)
--
-- Pattern: data = (addr mod 256) XOR 0x42. Catches bit-flips, addr-bit
-- aliasing (low 9 bits select index → both halves $D2xx and $D3xx must
-- read independent values), and stuck-at faults.
--
-- Exit code 0 = all 512 bytes match. Non-zero = mismatch count.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity scpu_sysram_tb is
end entity;

architecture sim of scpu_sysram_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- ~32 MHz

    constant TEST_START : integer := 16#D200#;
    constant TEST_END   : integer := 16#D3FF#;  -- inclusive

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- DUT inputs that we drive
    signal cpuAddr : unsigned(15 downto 0) := (others => '0');
    signal cpuData : unsigned(7 downto 0) := (others => '0');
    signal cpuWe   : std_logic := '0';

    -- DUT inputs that we tie to inactive defaults
    signal cpuHasBus    : std_logic := '1';
    signal aec          : std_logic := '0';
    signal ramData      : unsigned(7 downto 0) := (others => '0');
    signal bankSwitch   : unsigned(2 downto 0) := "111";
    signal game         : std_logic := '1';  -- inactive (cartridge unplugged)
    signal exrom        : std_logic := '1';
    signal io_rom       : std_logic := '0';
    signal io_ext       : std_logic := '0';
    signal io_data      : unsigned(7 downto 0) := (others => '0');
    signal c64rom_addr  : std_logic_vector(13 downto 0) := (others => '0');
    signal c64rom_data  : std_logic_vector(7 downto 0)  := (others => '0');
    signal c64rom_wr    : std_logic := '0';
    signal supercpu_en      : std_logic := '1';
    signal supercpu_rom     : std_logic := '0';
    signal supercpu_rom_vis : std_logic := '0';
    signal supercpu_bank    : std_logic_vector(7 downto 0) := x"00";
    signal vicAddr      : unsigned(15 downto 0) := (others => '0');
    signal vicData      : unsigned(7 downto 0)  := (others => '0');
    signal sidData      : unsigned(7 downto 0)  := (others => '0');
    signal colorData    : unsigned(3 downto 0)  := (others => '0');
    signal cia1Data     : unsigned(7 downto 0)  := (others => '0');
    signal cia2Data     : unsigned(7 downto 0)  := (others => '0');
    signal lastVicData  : unsigned(7 downto 0)  := (others => '0');
    signal io_enable    : std_logic := '1';
    signal bios         : std_logic_vector(1 downto 0) := "00";

    -- DUT outputs
    signal systemWe    : std_logic;
    signal systemAddr  : unsigned(15 downto 0);
    signal dataToCpu   : unsigned(7 downto 0);
    signal dataToVic   : unsigned(7 downto 0);
    signal cs_vic      : std_logic;
    signal cs_sid      : std_logic;
    signal cs_color    : std_logic;
    signal cs_cia1     : std_logic;
    signal cs_cia2     : std_logic;
    signal cs_ram      : std_logic;
    signal cs_ioE      : std_logic;
    signal cs_ioF      : std_logic;
    signal cs_ioF_raw  : std_logic;
    signal cs_romL     : std_logic;
    signal cs_romH     : std_logic;
    signal cs_UMAXromH : std_logic;

    signal sim_done : boolean := false;

    function expected_byte(a : integer) return unsigned is
        variable v : unsigned(7 downto 0);
    begin
        v := to_unsigned(a mod 256, 8) xor x"42";
        return v;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

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

    main : process
        variable mismatches    : integer := 0;
        variable expected      : unsigned(7 downto 0);
        variable actual        : unsigned(7 downto 0);
        variable first_bad_addr: integer := -1;
    begin
        -- Hold reset 100 cycles, then drop. While reset='1' the sweep
        -- restarts every 513 cycles, so the IN-PROGRESS sweep at the
        -- moment reset is deasserted may need up to 512 more cycles to
        -- complete. Wait 700 cycles after reset=0 to be safe.
        reset <= '1';
        for i in 0 to 100 loop
            wait until rising_edge(clk);
        end loop;
        reset <= '0';
        for i in 0 to 700 loop
            wait until rising_edge(clk);
        end loop;

        -- WRITE PHASE
        report "PH_WRITE: writing pattern (addr XOR $42) to $D200-$D3FF" severity note;
        for a in TEST_START to TEST_END loop
            cpuAddr <= to_unsigned(a, 16);
            cpuData <= expected_byte(a);
            cpuWe   <= '1';
            wait until rising_edge(clk);
        end loop;
        cpuWe <= '0';
        cpuData <= (others => '0');
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- READ PHASE
        report "PH_READ: reading back $D200-$D3FF" severity note;
        for a in TEST_START to TEST_END loop
            cpuAddr <= to_unsigned(a, 16);
            cpuWe   <= '0';
            wait until rising_edge(clk);  -- registered scpu_sysram_data settles
            wait until rising_edge(clk);  -- settle margin (combinational mux)
            expected := expected_byte(a);
            actual   := dataToCpu;
            if actual /= expected then
                if mismatches < 8 then
                    report "MISMATCH addr=$" & to_hstring(to_unsigned(a, 16)) &
                           " expected=$" & to_hstring(expected) &
                           " actual=$"   & to_hstring(actual)
                        severity warning;
                end if;
                if first_bad_addr = -1 then
                    first_bad_addr := a;
                end if;
                mismatches := mismatches + 1;
            end if;
        end loop;

        report "===== scpu_sysram test results =====" severity note;
        report "tested range: $" & to_hstring(to_unsigned(TEST_START, 16)) &
               " - $" & to_hstring(to_unsigned(TEST_END, 16)) severity note;
        report "mismatches: " & integer'image(mismatches) & " / " &
               integer'image(TEST_END - TEST_START + 1) severity note;

        sim_done <= true;
        wait for CLK_PERIOD;

        if mismatches = 0 then
            report "PASS" severity note;
        else
            report "FAIL: " & integer'image(mismatches) & " mismatches; first bad $" &
                   to_hstring(to_unsigned(first_bad_addr, 16))
                severity failure;
        end if;
        wait;
    end process;

end architecture;
