-- p65c816_asterix_full_tb.vhd
--
-- Full Asterix prelude bench: loads asterix.prg via VHDL file I/O,
-- runs phase-1 + phase-2 + dispatcher end-to-end, and verifies the
-- game entry at $CB00 is reached.
--
-- Pass if CPU reaches PC=$CB00 (the decompressor's exit JMP).
-- Fail if CPU still in decompressor after a generous cycle budget.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

entity p65c816_asterix_full_nmi_tb is
end entity;

architecture sim of p65c816_asterix_full_nmi_tb is

    signal clk    : std_logic := '0';
    signal rst_n  : std_logic := '0';
    signal ce     : std_logic := '1';
    signal nmi_n  : std_logic := '1';
    signal nmi_ctr : unsigned(19 downto 0) := (others => '0');
    signal nmi_fired : integer := 0;

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

        -- Reset vector -> $0820 (phase-1 entry) + KERNAL stubs
        m(16#FFFC#) := x"20"; m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00"; m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";  -- RTI for interrupts
        m(16#E5A0#) := x"60";  -- RTS stub
        m(16#A659#) := x"60";  -- RTS stub
        return m;
    end function;

    signal mem : mem_t := load_asterix;

    constant CLK_PERIOD : time := 31250 ps;

    -- Observer state
    signal cli_seen          : std_logic := '0';
    signal cb00_seen         : std_logic := '0';
    signal saw_phase2_entry  : std_logic := '0';
    signal saw_jmp_0100      : std_logic := '0';
    signal y_at_phase2       : std_logic_vector(15 downto 0) := (others => '0');
    signal x_at_phase2       : std_logic_vector(15 downto 0) := (others => '0');
    signal z2f_last          : std_logic_vector(7 downto 0) := (others => '0');
    signal z30_last          : std_logic_vector(7 downto 0) := (others => '0');
    signal pc_prev           : std_logic_vector(15 downto 0) := (others => '0');
    signal pbr_prev          : std_logic_vector(7 downto 0) := (others => '0');
    signal hit_0100_count    : integer := 0;
    signal hit_0197_count    : integer := 0;  -- exit path

begin

    dut: entity work.P65C816
        port map (
            CLK       => clk,
            RST_N     => rst_n,
            CE        => ce,
            RDY_IN    => '1',
            NMI_N     => nmi_n,
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

    -- KERNAL stub override: $E5A0 and $A659 always read $60 (RTS) regardless
    -- of what phase-1 wrote there during its relocation sweep.
    d_in <= x"60" when a_out(15 downto 0) = x"E5A0" or a_out(15 downto 0) = x"A659"
            else mem(to_integer(unsigned(a_out(15 downto 0))));

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

    -- NMI injector: pulse NMI_N low periodically AFTER saw_phase2_entry.
    -- Real hardware observed ~107 NMIs/sec. At 32MHz (31250ps period), that's
    -- ~300000 cycles between NMIs. Use shorter period (~8000 cycles) to
    -- accelerate repro in 300ms sim budget.
    nmi_inject: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                nmi_ctr <= (others => '0');
                nmi_n <= '1';
                nmi_fired <= 0;
            elsif saw_phase2_entry = '1' then
                nmi_ctr <= nmi_ctr + 1;
                -- Hold NMI low for 8 cycles, high for 300000 cycles (~107 Hz at 32 MHz)
                if nmi_ctr = x"493E0" then  -- 300000 cycles elapsed since last
                    nmi_n <= '0';
                elsif nmi_ctr = x"493E8" then  -- 8 cycles low
                    nmi_n <= '1';
                    nmi_ctr <= (others => '0');
                    nmi_fired <= nmi_fired + 1;
                end if;
            else
                nmi_n <= '1';
            end if;
        end if;
    end process;

    obs: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                cli_seen         <= '0';
                cb00_seen        <= '0';
                saw_phase2_entry <= '0';
                saw_jmp_0100     <= '0';
                hit_0100_count   <= 0;
                hit_0197_count   <= 0;
            elsif ce = '1' then
                pc_prev  <= dbg_pc;
                pbr_prev <= dbg_pbr;

                -- Phase-2 entry (first time PC=$0852, IR=$B9)
                if dbg_pbr = x"00" and dbg_pc = x"0852" and saw_phase2_entry = '0' then
                    saw_phase2_entry <= '1';
                    y_at_phase2      <= dbg_y;
                    x_at_phase2      <= dbg_x;
                end if;

                -- JMP $0100 reached
                if dbg_pbr = x"00" and dbg_pc = x"085C" then
                    saw_jmp_0100 <= '1';
                end if;

                -- Dispatcher entry at $0100 - count iterations
                if dbg_pbr = x"00" and dbg_pc = x"0101" and dbg_ir = x"B1"
                   and pc_prev /= x"0101" then
                    hit_0100_count <= hit_0100_count + 1;
                end if;

                -- Exit path ($0197 executed means handler 0 exit branch taken)
                if dbg_pbr = x"00" and dbg_pc = x"0198" and dbg_ir = x"2C"
                   and pc_prev /= x"0198" then
                    hit_0197_count <= hit_0197_count + 1;
                end if;

                -- CLI executed at $019E (IR=$58)
                if dbg_pbr = x"00" and dbg_pc = x"019F" and dbg_ir = x"58" then
                    cli_seen <= '1';
                end if;

                -- Game entry at $CB00
                if dbg_pbr = x"00" and dbg_pc = x"CB01" then
                    cb00_seen <= '1';
                end if;

                -- Latch ZP src pointer on each read
                if we_n = '1' and a_out(15 downto 0) = x"002F" then
                    z2f_last <= d_in;
                end if;
                if we_n = '1' and a_out(15 downto 0) = x"0030" then
                    z30_last <= d_in;
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
        wait for CLK_PERIOD * 10000000;  -- 312 ms sim
        report "================ ASTERIX FULL RESULT ================";
        report "Phase-2 entry seen: " & std_logic'image(saw_phase2_entry)(2);
        report "  Y at phase-2: $" & to_hstring(y_at_phase2);
        report "  X at phase-2: $" & to_hstring(x_at_phase2);
        report "JMP $0100 seen: " & std_logic'image(saw_jmp_0100)(2);
        report "Dispatcher iterations ($0100 hits): " & integer'image(hit_0100_count);
        report "Handler-0 exit path ($0197 hits): " & integer'image(hit_0197_count);
        report "CLI executed: " & std_logic'image(cli_seen)(2);
        report "$CB00 reached: " & std_logic'image(cb00_seen)(2);
        report "Last ZP $2F/$30 = $" & to_hstring(z30_last) & to_hstring(z2f_last);
        report "NMI pulses injected: " & integer'image(nmi_fired);

        if cb00_seen = '1' then
            report "PASS: full Asterix prelude completes on bare CPU despite NMI";
        elsif saw_jmp_0100 = '1' and hit_0100_count > 100 then
            report "FAIL: dispatcher loops without terminating -- bug REPRODUCES on bare CPU"
                severity warning;
        elsif saw_jmp_0100 = '1' then
            report "PARTIAL: dispatcher entered but budget insufficient"
                severity warning;
        else
            report "EARLIER FAIL: did not reach dispatcher"
                severity warning;
        end if;
        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
