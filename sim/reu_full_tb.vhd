-- reu_full_tb.vhd — Full bus rotation simulation for REU DMA diagnosis
--
-- Models ALL SDRAM accesses in a real bus rotation:
-- EXT0-3: io_cycle (refresh/tape), cart_ce may fire
-- DMA0-3: ext_cycle (REU DMA), reu_ram_ce fires
-- EXT4-7: io_cycle (refresh), cart_ce may fire
-- VIC0-3: VIC reads via cart_ce
-- CPU0-CPUF: CPU reads via cart_ce (turbo slots at 0,4,8,C)
--
-- The key question: is the SDRAM q counter at 0 when reu_ram_ce fires?

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity reu_full_tb is
end reu_full_tb;

architecture sim of reu_full_tb is
    signal clk32 : std_logic := '0';
    signal clk64 : std_logic := '0';

    signal sys_cycle : integer range 0 to 31 := 0;
    signal cycle_name : string(1 to 4) := "EXT0";

    -- SDRAM signals
    signal ce_mux    : std_logic := '0';
    signal addr_mux  : unsigned(24 downto 0) := (others => '0');
    signal we_mux    : std_logic := '0';
    signal din_mux   : unsigned(7 downto 0) := (others => '0');
    signal dout      : unsigned(7 downto 0) := (others => '0');

    -- SDRAM state (matching sdram.v exactly)
    signal q         : unsigned(2 downto 0) := "000";
    signal last_ce   : std_logic := '0';
    signal last_refresh : std_logic := '0';
    signal sd_wr     : std_logic := '0';
    signal sd_addr   : unsigned(7 downto 0) := (others => '0');
    signal sd_din    : unsigned(7 downto 0) := (others => '0');

    -- Simple RAM
    type ram_t is array(0 to 255) of unsigned(7 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    -- Bus signals
    signal ext_cycle   : std_logic := '0';
    signal io_cycle    : std_logic := '0';
    signal ext_cycle_d : std_logic := '0';
    signal dma_req     : std_logic := '0';
    signal reu_ram_ce  : std_logic := '0';
    signal refresh     : std_logic := '0';

    -- Cart CE: fires at CPU turbo slots and CPUC
    signal cart_ce     : std_logic := '0';
    signal io_cycle_ce : std_logic := '0';
    signal io_cycle_d  : std_logic := '0';

    -- Test control
    signal test_phase  : integer := 0;
    signal reu_write_data : unsigned(7 downto 0) := x"AA";
    signal reu_addr    : unsigned(7 downto 0) := x"42";

begin
    clk32 <= not clk32 after 15625 ps;
    clk64 <= not clk64 after 7812 ps;

    -- Cycle counter
    process(clk32)
    begin
        if rising_edge(clk32) then
            if sys_cycle = 31 then
                sys_cycle <= 0;
            else
                sys_cycle <= sys_cycle + 1;
            end if;
        end if;
    end process;

    -- Cycle name for debug
    process(sys_cycle)
    begin
        case sys_cycle is
            when 0 => cycle_name <= "EXT0"; when 1 => cycle_name <= "EXT1";
            when 2 => cycle_name <= "EXT2"; when 3 => cycle_name <= "EXT3";
            when 4 => cycle_name <= "DMA0"; when 5 => cycle_name <= "DMA1";
            when 6 => cycle_name <= "DMA2"; when 7 => cycle_name <= "DMA3";
            when 8 => cycle_name <= "EXT4"; when 9 => cycle_name <= "EXT5";
            when 10 => cycle_name <= "XT6 "; when 11 => cycle_name <= "EXT7";
            when 12 => cycle_name <= "VIC0"; when 13 => cycle_name <= "VIC1";
            when 14 => cycle_name <= "VIC2"; when 15 => cycle_name <= "VIC3";
            when 16 => cycle_name <= "CPU0"; when 17 => cycle_name <= "CPU1";
            when 18 => cycle_name <= "CPU2"; when 19 => cycle_name <= "CPU3";
            when 20 => cycle_name <= "CPU4"; when 21 => cycle_name <= "CPU5";
            when 22 => cycle_name <= "CPU6"; when 23 => cycle_name <= "CPU7";
            when 24 => cycle_name <= "CPU8"; when 25 => cycle_name <= "CPU9";
            when 26 => cycle_name <= "CPUA"; when 27 => cycle_name <= "CPUB";
            when 28 => cycle_name <= "CPUC"; when 29 => cycle_name <= "CPUD";
            when 30 => cycle_name <= "CPUE"; when 31 => cycle_name <= "CPUF";
        end case;
    end process;

    -- Bus phase signals
    ext_cycle <= '1' when (sys_cycle >= 4 and sys_cycle <= 7) else '0';
    io_cycle  <= '1' when (sys_cycle >= 0 and sys_cycle <= 3) else '0';
    -- Note: second EXT group (8-11) also has io_cycle for refresh, but simplified here

    -- Refresh: fires at VIC2 (our current setting)
    process(clk32)
    begin
        if rising_edge(clk32) then
            refresh <= '0';
            if sys_cycle = 13 then -- pred(VIC3) = VIC2
                refresh <= '1';
            end if;
        end if;
    end process;

    -- reu_ram_ce
    process(clk32)
    begin
        if rising_edge(clk32) then
            ext_cycle_d <= ext_cycle;
        end if;
    end process;
    reu_ram_ce <= (not ext_cycle_d) and ext_cycle and dma_req;

    -- io_cycle_ce: fires on falling edge of io_cycle
    process(clk32)
    begin
        if rising_edge(clk32) then
            io_cycle_d <= io_cycle;
            if io_cycle = '0' and io_cycle_d = '1' then
                io_cycle_ce <= '1';
            end if;
            if io_cycle = '1' then
                io_cycle_ce <= '0';
            end if;
        end if;
    end process;

    -- cart_ce: fires at turbo SDRAM slots (CPU0, CPU4, CPU8) and CPUC
    -- In turbo mode with cache, these fire for RAM accesses
    process(clk32)
    begin
        if rising_edge(clk32) then
            cart_ce <= '0';
            -- Turbo slots (all 3 active for max speed)
            if sys_cycle = 16 or sys_cycle = 20 or sys_cycle = 24 then
                cart_ce <= '1'; -- RAM access at turbo slots
            end if;
            -- Normal I/O slot
            if sys_cycle = 28 then
                cart_ce <= '1'; -- CPUC I/O/RAM slot
            end if;
            -- VIC read
            if sys_cycle = 12 then
                cart_ce <= '1'; -- VIC0 read
            end if;
        end if;
    end process;

    -- SDRAM CE mux (matches c64.sv exactly)
    ce_mux <= io_cycle_ce when io_cycle = '1' else
              reu_ram_ce  when ext_cycle = '1' else
              cart_ce;

    -- SDRAM state machine (matches sdram.v EXACTLY)
    process(clk64)
    begin
        if rising_edge(clk64) then
            last_ce <= ce_mux;
            last_refresh <= refresh;

            -- Refresh command
            if refresh = '1' and last_refresh = '0' then
                report cycle_name & ": REFRESH started, q=" & integer'image(to_integer(q));
            end if;

            -- New access on CE rising edge
            if ce_mux = '1' and last_ce = '0' then
                if q /= "000" then
                    report cycle_name & ": CE IGNORED! q=" & integer'image(to_integer(q)) & " (SDRAM busy)";
                else
                    report cycle_name & ": CE accepted, q set to 1";
                end if;
                q <= "001"; -- This gets overridden by next line if q != 0
            end if;

            -- State machine advance (OVERRIDES the q<=1 above when q!=0)
            if q /= "000" then
                q <= q + 1;

                if q = "010" and sd_wr = '1' then
                    ram(to_integer(sd_addr)) <= sd_din;
                    report cycle_name & ": SDRAM WRITE [" & integer'image(to_integer(sd_addr)) & "] = " & integer'image(to_integer(sd_din));
                end if;

                if q = "100" then
                    dout <= ram(to_integer(sd_addr));
                end if;
            end if;

            -- Latch address/data on CE (happens regardless of q)
            if ce_mux = '1' and last_ce = '0' then
                sd_wr <= we_mux;
                sd_addr <= addr_mux(7 downto 0);
                sd_din <= din_mux;
            end if;
        end if;
    end process;

    -- Address/data/we mux (matches c64.sv: io_cycle ? ... : ext_cycle ? reu : cart)
    addr_mux <= "0" & x"00" & reu_addr & x"00" when ext_cycle = '1' else
                "0" & x"000055" when true else -- cart_addr default
                (others => '0');
    we_mux   <= '1' when ext_cycle = '1' and dma_req = '1' else '0';
    din_mux  <= reu_write_data when ext_cycle = '1' else x"00";

    -- Debug: monitor ce_mux and ext_cycle timing
    process(clk64)
    begin
        if rising_edge(clk64) then
            if ce_mux = '1' and last_ce = '0' then
                report cycle_name & " @clk64: CE rising, ext_cycle=" & std_logic'image(ext_cycle) &
                       " addr=" & integer'image(to_integer(addr_mux(7 downto 0))) &
                       " we=" & std_logic'image(we_mux) &
                       " din=" & integer'image(to_integer(din_mux));
            end if;
        end if;
    end process;

    -- Test stimulus
    process
        variable q_at_dma0 : integer;
    begin
        wait for 200 ns; -- settle

        report "=== FULL BUS ROTATION TEST ===";
        report "Testing REU DMA with realistic bus traffic";
        report "Cart CE fires at: VIC0, CPU0, CPU4, CPU8, CPUC (5 accesses/rotation)";

        -- Run 2 rotations to see the pattern
        wait until rising_edge(clk32) and sys_cycle = 0;
        report "--- Rotation 1 (no DMA) ---";
        for i in 0 to 31 loop
            wait until rising_edge(clk32);
        end loop;

        report "--- Rotation 2 (DMA active) ---";
        -- Enable DMA before the rotation starts
        dma_req <= '1';
        reu_write_data <= x"42";
        reu_addr <= x"55";

        -- Watch for DMA0
        wait until rising_edge(clk32) and sys_cycle = 4;
        report "DMA0: reu_ram_ce=" & std_logic'image(reu_ram_ce) &
               " ext_cycle=" & std_logic'image(ext_cycle) &
               " ext_cycle_d=" & std_logic'image(ext_cycle_d);

        -- Wait for completion
        wait for 1000 ns;
        dma_req <= '0';

        -- Read back via cart path
        report "--- Reading back REU write ---";
        wait until rising_edge(clk32) and sys_cycle = 28;
        -- (simplified: just check the RAM array)
        report "RAM[85] = " & integer'image(to_integer(ram(85)));
        if ram(85) = x"42" then
            report "=== REU DMA WRITE SUCCEEDED ===";
        else
            report "=== REU DMA WRITE FAILED (expected $42) ===";
        end if;

        report "=== DONE ===";
        wait;
    end process;

end sim;
