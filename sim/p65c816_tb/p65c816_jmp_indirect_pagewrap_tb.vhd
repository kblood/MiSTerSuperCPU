-- p65c816_jmp_indirect_pagewrap_tb.vhd
--
-- Verifies the NMOS JMP ($xxFF) page-wrap quirk in emu mode (E=1).
--
-- Real NMOS 6502 (and T65 emulating it): JMP ($02FF) reads
--   lo byte from $02FF, hi byte from $0200 (page-wrap, hi byte stays).
-- 65C02/65C816 native semantics: hi byte from $0300 (correct increment).
--
-- For NMOS-targeting C64 software (e.g. Dragon's Lair), P65C816 in emu
-- mode MUST replicate the wrap, otherwise indirect dispatch lands at
-- a different address and downstream behaviour diverges.
--
-- Test program in emu mode (CPU enters emu on reset):
--   $0800 78         SEI
--   $0801 A9 BB      LDA #$BB
--   $0803 8D 00 02   STA $0200            ; NMOS-wrap path hi byte
--   $0806 A9 CC      LDA #$CC
--   $0808 8D 00 03   STA $0300            ; CMOS path hi byte (no-wrap)
--   $080B A9 AA      LDA #$AA
--   $080D 8D FF 02   STA $02FF            ; common low byte
--   $0810 6C FF 02   JMP ($02FF)
--
-- $BBAA handler (NMOS path):
--   A9 EE 8D 00 30   LDA #$EE; STA $3000
--   4C AA BB         JMP $BBAA            ; spin
--
-- $CCAA handler (CMOS path):
--   A9 DD 8D 00 31   LDA #$DD; STA $3100
--   4C AA CC         JMP $CCAA            ; spin
--
-- PASS (NMOS quirk implemented): $3000 = $EE.
-- FAIL (CMOS-only behaviour):    $3100 = $DD.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_jmp_indirect_pagewrap_tb is
end entity;

architecture sim of p65c816_jmp_indirect_pagewrap_tb is

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
    signal dbg_state : std_logic_vector(3 downto 0);

    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);

    function init_mem return mem_t is
        variable m : mem_t := (others => x"EA");
    begin
        -- Reset vectors (emu): $FFFC/D -> $0800
        m(16#FFFC#) := x"00";  m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";  -- RTI stub

        -- Test program at $0800
        m(16#0800#) := x"78";                                                    -- SEI
        m(16#0801#) := x"A9";  m(16#0802#) := x"BB";                             -- LDA #$BB
        m(16#0803#) := x"8D";  m(16#0804#) := x"00";  m(16#0805#) := x"02";      -- STA $0200
        m(16#0806#) := x"A9";  m(16#0807#) := x"CC";                             -- LDA #$CC
        m(16#0808#) := x"8D";  m(16#0809#) := x"00";  m(16#080A#) := x"03";      -- STA $0300
        m(16#080B#) := x"A9";  m(16#080C#) := x"AA";                             -- LDA #$AA
        m(16#080D#) := x"8D";  m(16#080E#) := x"FF";  m(16#080F#) := x"02";      -- STA $02FF
        m(16#0810#) := x"6C";  m(16#0811#) := x"FF";  m(16#0812#) := x"02";      -- JMP ($02FF)

        -- NMOS-path handler at $BBAA
        m(16#BBAA#) := x"A9";  m(16#BBAB#) := x"EE";                             -- LDA #$EE
        m(16#BBAC#) := x"8D";  m(16#BBAD#) := x"00";  m(16#BBAE#) := x"30";      -- STA $3000
        m(16#BBAF#) := x"4C";  m(16#BBB0#) := x"AF";  m(16#BBB1#) := x"BB";      -- JMP $BBAF (spin)

        -- CMOS-path handler at $CCAA
        m(16#CCAA#) := x"A9";  m(16#CCAB#) := x"DD";                             -- LDA #$DD
        m(16#CCAC#) := x"8D";  m(16#CCAD#) := x"00";  m(16#CCAE#) := x"31";      -- STA $3100
        m(16#CCAF#) := x"4C";  m(16#CCB0#) := x"AF";  m(16#CCB1#) := x"CC";      -- JMP $CCAF (spin)

        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    signal nmos_seen  : std_logic := '0';
    signal cmos_seen  : std_logic := '0';
    signal jmp_seen   : std_logic := '0';
    signal jmp_pc     : std_logic_vector(15 downto 0) := (others => '0');

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
            DBG_STATE => dbg_state
        );

    d_in <= mem(to_integer(unsigned(a_out(15 downto 0))));

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

    cycle_proc: process(clk)
    begin
        if rising_edge(clk) then
            cycle_count <= cycle_count + 1;
        end if;
    end process;

    snap_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                nmos_seen <= '0';
                cmos_seen <= '0';
                jmp_seen  <= '0';
            elsif ce = '1' then
                -- Snapshot the moment opcode $6C is fetched.
                if dbg_ir = x"6C" and jmp_seen = '0' then
                    jmp_seen <= '1';
                    jmp_pc   <= dbg_pc;
                end if;
                if we_n = '0' then
                    case to_integer(unsigned(a_out(15 downto 0))) is
                        when 16#3000# =>
                            if d_out = x"EE" then
                                nmos_seen <= '1';
                            end if;
                        when 16#3100# =>
                            if d_out = x"DD" then
                                cmos_seen <= '1';
                            end if;
                        when others => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    main_proc: process
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 8;
        rst_n <= '1';
        wait for CLK_PERIOD * 5000;

        report "================ JMP-IND-PAGEWRAP RESULT ================";
        report "cycle_count = " & integer'image(cycle_count);
        report "jmp_seen    = " & std_logic'image(jmp_seen)(2);
        report "nmos_seen   = " & std_logic'image(nmos_seen)(2) &
               "  ($3000 = $EE means NMOS-wrap path)";
        report "cmos_seen   = " & std_logic'image(cmos_seen)(2) &
               "  ($3100 = $DD means CMOS no-wrap path)";

        if nmos_seen = '1' and cmos_seen = '0' then
            report "PASS: emu-mode JMP ($02FF) wrapped to $0200 hi-byte (NMOS quirk)"
                severity note;
        elsif cmos_seen = '1' and nmos_seen = '0' then
            report "FAIL: emu-mode JMP ($02FF) read $0300 hi-byte -- BUG (no NMOS wrap)"
                severity warning;
        elsif nmos_seen = '0' and cmos_seen = '0' then
            report "FAIL: neither $3000 nor $3100 written -- CPU did not reach handler"
                severity warning;
        else
            report "FAIL: BOTH targets written -- impossible state"
                severity warning;
        end if;

        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
