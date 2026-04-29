-- p65c816_asterix_postcb00_tb.vhd
--
-- Extends p65c816_asterix_full_tb to run PAST $CB00 and track SP drain,
-- first write of non-$58 to $019E, and PC trail leading into $C003 PEA.
-- If bare CPU + flat RAM drains SP after $CB00 game code, CPU has a bug
-- in some post-CB00 opcode. If SP stays healthy, MiSTer memory pipeline
-- is the culprit (v94/v95/v96 already ruled out turbo/BRAM/IRQ).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

entity p65c816_asterix_postcb00_tb is
end entity;

architecture sim of p65c816_asterix_postcb00_tb is

    signal clk    : std_logic := '0';
    signal rst_n  : std_logic := '0';
    signal ce     : std_logic := '1';

    signal d_in   : std_logic_vector(7 downto 0) := (others => '0');
    signal d_out  : std_logic_vector(7 downto 0);
    signal a_out  : std_logic_vector(23 downto 0);
    signal we_n   : std_logic;
    signal vpa    : std_logic;
    signal vda    : std_logic;
    signal mlb_s  : std_logic;
    signal vpb_s  : std_logic;
    signal ef_out : std_logic;
    signal rdy_out: std_logic;

    signal dbg_pc    : std_logic_vector(15 downto 0);
    signal dbg_sp    : std_logic_vector(15 downto 0);
    signal dbg_p     : std_logic_vector(7 downto 0);
    signal dbg_ir    : std_logic_vector(7 downto 0);
    signal dbg_pbr   : std_logic_vector(7 downto 0);
    signal dbg_dbr   : std_logic_vector(7 downto 0);
    signal dbg_x     : std_logic_vector(15 downto 0);
    signal dbg_y     : std_logic_vector(15 downto 0);
    signal dbg_state : std_logic_vector(3 downto 0);

    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);

    impure function load_asterix return mem_t is
        variable m : mem_t := (others => x"EA");
        file prg_file : text;
        variable L    : line;
        variable byte_val : integer;
        variable addr : integer;
        variable line_count : integer := 0;
    begin
        file_open(prg_file, "asterix.mem", read_mode);
        while not endfile(prg_file) loop
            readline(prg_file, L);
            read(L, addr);
            read(L, byte_val);
            if addr >= 0 and addr <= 65535 then
                m(addr) := std_logic_vector(to_unsigned(byte_val, 8));
            end if;
            line_count := line_count + 1;
        end loop;
        file_close(prg_file);
        report "Loaded " & integer'image(line_count) & " bytes from asterix.mem";

        m(16#FFFC#) := x"20"; m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00"; m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";
        m(16#E5A0#) := x"60";
        m(16#A659#) := x"60";
        return m;
    end function;

    signal mem : mem_t := load_asterix;

    constant CLK_PERIOD : time := 31250 ps;

    -- Observer state
    signal cli_seen          : std_logic := '0';
    signal cb00_seen         : std_logic := '0';
    signal c003_seen         : std_logic := '0';
    signal saw_phase2_entry  : std_logic := '0';
    signal pc_prev           : std_logic_vector(15 downto 0) := (others => '0');
    signal pbr_prev          : std_logic_vector(7 downto 0) := (others => '0');
    signal hit_0100_count    : integer := 0;

    -- SP health tracking past $CB00
    signal sp_min_postcb00   : std_logic_vector(15 downto 0) := x"01FF";
    signal sp_at_c003        : std_logic_vector(15 downto 0) := (others => '0');
    signal stomp_count       : integer := 0;
    signal first_stomp_val   : std_logic_vector(7 downto 0) := (others => '0');
    signal first_stomp_pc    : std_logic_vector(15 downto 0) := (others => '0');
    signal stomp_captured    : std_logic := '0';
    signal cb00_cycles       : integer := 0;

    -- Push/pull balance post-$CB00
    signal push_count        : integer := 0;
    signal pull_count        : integer := 0;
    signal brk_count         : integer := 0;

    -- Fake I/O: $D012 raster counter increments; other $DXXX reads return $EA
    signal fake_rast : unsigned(8 downto 0) := (others => '0');
    signal rast_inc  : unsigned(8 downto 0) := (others => '0');
    signal pc_last   : std_logic_vector(15 downto 0) := (others => '0');
    signal pbr_last  : std_logic_vector(7 downto 0) := (others => '0');

    -- PC range histograms post-CB00
    signal pc_01xx_count : integer := 0;
    signal pc_80xx_count : integer := 0;
    signal pc_CBxx_count : integer := 0;
    signal pc_CCxx_count : integer := 0;
    signal pc_CDxx_count : integer := 0;
    signal pc_CExx_count : integer := 0;
    signal pc_CFxx_count : integer := 0;
    signal pc_C0xx_count : integer := 0;
    signal pc_C1xx_count : integer := 0;
    signal pc_C2xx_count : integer := 0;
    signal pc_Axxx_count : integer := 0;
    signal pc_Bxxx_count : integer := 0;
    signal pc_Dxxx_count : integer := 0;
    signal pc_Exxx_count : integer := 0;
    signal pc_Fxxx_count : integer := 0;
    signal pc_other_count: integer := 0;

begin

    dut: entity work.P65C816
        port map (
            CLK       => clk,
            RST_N     => rst_n,
            CE        => ce,
            RDY_IN    => '1',
            NMI_N     => '1',
            IRQ_N     => '1',
            ABORT_N   => '1',
            D_IN      => d_in,
            D_OUT     => d_out,
            A_OUT     => a_out,
            WE        => we_n,
            RDY_OUT   => rdy_out,
            VPA       => vpa,
            VDA       => vda,
            MLB       => mlb_s,
            VPB       => vpb_s,
            EF_OUT    => ef_out,
            DBG_PC    => dbg_pc,
            DBG_SP    => dbg_sp,
            DBG_P     => dbg_p,
            DBG_IR    => dbg_ir,
            DBG_PBR   => dbg_pbr,
            DBG_DBR   => dbg_dbr,
            DBG_X     => dbg_x,
            DBG_Y     => dbg_y,
            DBG_STATE => dbg_state
        );

    d_in <= x"60" when a_out(15 downto 0) = x"E5A0" or a_out(15 downto 0) = x"A659"
            else std_logic_vector(fake_rast(7 downto 0)) when a_out(15 downto 0) = x"D012"
            else "0000000" & std_logic_vector(fake_rast(8 downto 8)) when a_out(15 downto 0) = x"D011"
            else mem(to_integer(unsigned(a_out(15 downto 0))));

    rast_tick: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                fake_rast <= (others => '0');
                rast_inc  <= (others => '0');
            else
                rast_inc <= rast_inc + 1;
                if rast_inc = to_unsigned(63, 9) then  -- ~2us per raster, PAL-ish
                    rast_inc  <= (others => '0');
                    if fake_rast = to_unsigned(311, 9) then
                        fake_rast <= (others => '0');
                    else
                        fake_rast <= fake_rast + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if ce = '1' and we_n = '0' then
                mem(to_integer(unsigned(a_out(15 downto 0)))) <= d_out;
            end if;
        end if;
    end process;

    clock_proc: process
    begin
        clk <= '0';
        wait for CLK_PERIOD / 2;
        clk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    obs: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                cli_seen         <= '0';
                cb00_seen        <= '0';
                c003_seen        <= '0';
                saw_phase2_entry <= '0';
                hit_0100_count   <= 0;
                sp_min_postcb00  <= x"01FF";
                stomp_count      <= 0;
                stomp_captured   <= '0';
                cb00_cycles      <= 0;
                push_count       <= 0;
                pull_count       <= 0;
                brk_count        <= 0;
            elsif ce = '1' then
                pc_prev  <= dbg_pc;
                pbr_prev <= dbg_pbr;
                pc_last  <= dbg_pc;
                pbr_last <= dbg_pbr;

                if dbg_pbr = x"00" and dbg_pc = x"0852" and saw_phase2_entry = '0' then
                    saw_phase2_entry <= '1';
                end if;

                if dbg_pbr = x"00" and dbg_pc = x"0101" and dbg_ir = x"B1"
                   and pc_prev /= x"0101" then
                    hit_0100_count <= hit_0100_count + 1;
                end if;

                if dbg_pbr = x"00" and dbg_pc = x"019F" and dbg_ir = x"58" then
                    cli_seen <= '1';
                end if;

                if dbg_pbr = x"00" and dbg_pc = x"CB01" and cb00_seen = '0' then
                    cb00_seen <= '1';
                end if;

                if cb00_seen = '1' then
                    cb00_cycles <= cb00_cycles + 1;

                    if dbg_pbr = x"00" and dbg_pc = x"C003" and c003_seen = '0' then
                        c003_seen  <= '1';
                        sp_at_c003 <= dbg_sp;
                    end if;

                    if unsigned(dbg_sp) < unsigned(sp_min_postcb00) then
                        sp_min_postcb00 <= dbg_sp;
                    end if;

                    -- PC histogram — count only at new instruction fetches
                    if vpa = '1' and vda = '1' and dbg_pbr = x"00" and pc_prev /= dbg_pc then
                        case dbg_pc(15 downto 8) is
                            when x"01" => pc_01xx_count <= pc_01xx_count + 1;
                            when x"80"|x"81"|x"82"|x"83"|x"84"|x"85"|x"86"|x"87"|x"88"|x"89"|x"8A"|x"8B"|x"8C"|x"8D"|x"8E"|x"8F" =>
                                pc_80xx_count <= pc_80xx_count + 1;
                            when x"CB" => pc_CBxx_count <= pc_CBxx_count + 1;
                            when x"CC" => pc_CCxx_count <= pc_CCxx_count + 1;
                            when x"CD" => pc_CDxx_count <= pc_CDxx_count + 1;
                            when x"CE" => pc_CExx_count <= pc_CExx_count + 1;
                            when x"CF" => pc_CFxx_count <= pc_CFxx_count + 1;
                            when x"C0" => pc_C0xx_count <= pc_C0xx_count + 1;
                            when x"C1" => pc_C1xx_count <= pc_C1xx_count + 1;
                            when x"C2" => pc_C2xx_count <= pc_C2xx_count + 1;
                            when x"A0"|x"A1"|x"A2"|x"A3"|x"A4"|x"A5"|x"A6"|x"A7"|x"A8"|x"A9"|x"AA"|x"AB"|x"AC"|x"AD"|x"AE"|x"AF" =>
                                pc_Axxx_count <= pc_Axxx_count + 1;
                            when x"B0"|x"B1"|x"B2"|x"B3"|x"B4"|x"B5"|x"B6"|x"B7"|x"B8"|x"B9"|x"BA"|x"BB"|x"BC"|x"BD"|x"BE"|x"BF" =>
                                pc_Bxxx_count <= pc_Bxxx_count + 1;
                            when x"D0"|x"D1"|x"D2"|x"D3"|x"D4"|x"D5"|x"D6"|x"D7"|x"D8"|x"D9"|x"DA"|x"DB"|x"DC"|x"DD"|x"DE"|x"DF" =>
                                pc_Dxxx_count <= pc_Dxxx_count + 1;
                            when x"E0"|x"E1"|x"E2"|x"E3"|x"E4"|x"E5"|x"E6"|x"E7"|x"E8"|x"E9"|x"EA"|x"EB"|x"EC"|x"ED"|x"EE"|x"EF" =>
                                pc_Exxx_count <= pc_Exxx_count + 1;
                            when x"F0"|x"F1"|x"F2"|x"F3"|x"F4"|x"F5"|x"F6"|x"F7"|x"F8"|x"F9"|x"FA"|x"FB"|x"FC"|x"FD"|x"FE"|x"FF" =>
                                pc_Fxxx_count <= pc_Fxxx_count + 1;
                            when others => pc_other_count <= pc_other_count + 1;
                        end case;
                    end if;

                    -- Count push-family ops fetched: PHA 48 PHP 08 PEA F4 PER 62 PHD 0B PHK 4B PHB 8B PHX DA PHY 5A JSR 20 JSL 22
                    if vpa = '1' and vda = '1' then
                        case dbg_ir is
                            when x"48"|x"08"|x"F4"|x"62"|x"0B"|x"4B"|x"8B"|x"DA"|x"5A"|x"20"|x"22" =>
                                push_count <= push_count + 1;
                            when x"68"|x"28"|x"60"|x"40"|x"2B"|x"AB"|x"FA"|x"7A"|x"6B" =>
                                pull_count <= pull_count + 1;
                            when x"00" =>
                                brk_count <= brk_count + 1;
                            when others => null;
                        end case;
                    end if;
                end if;

                if dbg_pbr = x"00" and a_out(15 downto 0) = x"019E"
                   and we_n = '0' and d_out /= x"58" then
                    stomp_count <= stomp_count + 1;
                    if stomp_captured = '0' then
                        stomp_captured  <= '1';
                        first_stomp_val <= d_out;
                        first_stomp_pc  <= dbg_pc;
                    end if;
                end if;
            end if;
        end if;
    end process;

    reset_proc: process
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 8;
        rst_n <= '1';
        wait;
    end process;

    timeout_proc: process
    begin
        wait for CLK_PERIOD * 30000000;
        report "================ ASTERIX POST-CB00 RESULT ================";
        report "$CB00 reached: " & std_logic'image(cb00_seen)(2);
        report "  Cycles after $CB00 entry: " & integer'image(cb00_cycles);
        report "$C003 reached: " & std_logic'image(c003_seen)(2);
        report "  SP at first $C003 entry: $" & to_hstring(sp_at_c003);
        report "Min SP seen post-$CB00: $" & to_hstring(sp_min_postcb00);
        report "Non-$58 writes to $019E: " & integer'image(stomp_count);
        if stomp_captured = '1' then
            report "  First stomp val: $" & to_hstring(first_stomp_val);
            report "  First stomp PC:  $" & to_hstring(first_stomp_pc);
        end if;
        report "Post-$CB00 push ops:  " & integer'image(push_count);
        report "Post-$CB00 pull ops:  " & integer'image(pull_count);
        report "Post-$CB00 BRK ops:   " & integer'image(brk_count);
        report "PC at timeout: $" & to_hstring(pbr_last) & ":" & to_hstring(pc_last);
        report "Fake raster final: " & integer'image(to_integer(fake_rast));
        report "PC histogram post-CB00 (instr fetches):";
        report "  01xx: " & integer'image(pc_01xx_count);
        report "  80xx-8Fxx: " & integer'image(pc_80xx_count);
        report "  Axxx: " & integer'image(pc_Axxx_count);
        report "  Bxxx: " & integer'image(pc_Bxxx_count);
        report "  C0xx: " & integer'image(pc_C0xx_count);
        report "  C1xx: " & integer'image(pc_C1xx_count);
        report "  C2xx: " & integer'image(pc_C2xx_count);
        report "  CBxx: " & integer'image(pc_CBxx_count);
        report "  CCxx: " & integer'image(pc_CCxx_count);
        report "  CDxx: " & integer'image(pc_CDxx_count);
        report "  CExx: " & integer'image(pc_CExx_count);
        report "  CFxx: " & integer'image(pc_CFxx_count);
        report "  Dxxx: " & integer'image(pc_Dxxx_count);
        report "  Exxx: " & integer'image(pc_Exxx_count);
        report "  Fxxx: " & integer'image(pc_Fxxx_count);
        report "  other: " & integer'image(pc_other_count);
        if c003_seen = '1' and unsigned(sp_min_postcb00) < x"0130" then
            report "=> BARE-CPU ALSO DRAINS SP: CPU core has bug in post-CB00 opcode"
                severity note;
        elsif c003_seen = '1' then
            report "=> BARE-CPU SP STAYS HEALTHY: HW memory pipeline is the culprit"
                severity note;
        else
            report "=> BARE-CPU did not reach $C003 in budget"
                severity note;
        end if;
        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
