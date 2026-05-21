-- p65c816_sr_emu_wrap_tb.vhd
--
-- Verifies emu-mode stack-relative addressing ($A3 LDA sr,S).
--
-- 2026-05-03 PASS/FAIL inverted: SingleStepTests/65816 real-hardware traces
-- show that emu-mode stack-relative addressing does NOT wrap within page 1 —
-- the SPL+operand carry propagates into DH normally. VICE wraps and was
-- previously cited as authoritative; bench was originally written against
-- VICE, then rewritten against silicon when SST results landed.
--
-- Reference: SP = $01F0, LDA $10,S
--   SST/silicon: DX = $0200 (carry propagated into DH) — value at $0200 = $CC
--   VICE wrong:  DX = $0100 (wrap within page 01)         — value at $0100 = $BB
--
-- Test sequence (runs in emulation mode — CPU enters emu on reset):
--   $0800 78         SEI
--   $0801 A2 F0      LDX #$F0
--   $0803 9A         TXS                     ; SP = $01F0 (emu forces hi=$01)
--   $0804 A9 BB      LDA #$BB
--   $0806 8D 00 01   STA $0100               ; byte at $0100 = $BB (VICE trap)
--   $0809 A9 CC      LDA #$CC
--   $080B 8D 00 02   STA $0200               ; byte at $0200 = $CC (silicon target)
--   $080E A3 10      LDA $10,S               ; SP+$10 = $01F0+$10 = cross page
--   $0810 8D 00 30   STA $3000               ; marker: A after sr read
--   $0813 A9 EE      LDA #$EE
--   $0815 8D 30 30   STA $3030               ; end sentinel
--   $0818 4C 18 08   JMP $0818               ; spin
--
-- PASS: $3000 == $CC (carried into DH, address $0200) — SST/silicon semantics
-- FAIL: $3000 == $BB (page-1 wrap to $0100)            — VICE incorrectly

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_sr_emu_wrap_tb is
end entity;

architecture sim of p65c816_sr_emu_wrap_tb is

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
        -- Reset vectors (emu): $FFFC/D → $0800
        m(16#FFFC#) := x"00";  m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";  -- RTI stub

        -- Test program
        m(16#0800#) := x"78";                            -- SEI
        m(16#0801#) := x"A2";  m(16#0802#) := x"F0";     -- LDX #$F0
        m(16#0803#) := x"9A";                            -- TXS
        m(16#0804#) := x"A9";  m(16#0805#) := x"BB";     -- LDA #$BB
        m(16#0806#) := x"8D";  m(16#0807#) := x"00";  m(16#0808#) := x"01";  -- STA $0100
        m(16#0809#) := x"A9";  m(16#080A#) := x"CC";     -- LDA #$CC
        m(16#080B#) := x"8D";  m(16#080C#) := x"00";  m(16#080D#) := x"02";  -- STA $0200
        m(16#080E#) := x"A3";  m(16#080F#) := x"10";     -- LDA $10,S
        m(16#0810#) := x"8D";  m(16#0811#) := x"00";  m(16#0812#) := x"30";  -- STA $3000
        m(16#0813#) := x"A9";  m(16#0814#) := x"EE";     -- LDA #$EE
        m(16#0815#) := x"8D";  m(16#0816#) := x"30";  m(16#0817#) := x"30";  -- STA $3030
        m(16#0818#) := x"4C";  m(16#0819#) := x"18";  m(16#081A#) := x"08";  -- JMP $0818

        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    signal result_seen   : std_logic := '0';
    signal result_value  : std_logic_vector(7 downto 0) := (others => '0');
    signal end_sentinel  : std_logic := '0';
    signal sr_fetched    : std_logic := '0';
    signal sp_at_sr      : std_logic_vector(15 downto 0) := (others => '0');

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
                result_seen  <= '0';
                end_sentinel <= '0';
                sr_fetched   <= '0';
            elsif ce = '1' then
                -- Snapshot SP at the moment $A3 is fetched (IR := $A3).
                if dbg_ir = x"A3" and sr_fetched = '0' then
                    sr_fetched <= '1';
                    sp_at_sr   <= dbg_sp;
                end if;
                if we_n = '0' then
                    case to_integer(unsigned(a_out(15 downto 0))) is
                        when 16#3000# =>
                            result_seen  <= '1';
                            result_value <= d_out;
                        when 16#3030# =>
                            if d_out = x"EE" then
                                end_sentinel <= '1';
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
        -- Enough cycles for reset + test sequence (~60 cycles).
        wait for CLK_PERIOD * 5000;

        report "================ SR-EMU-WRAP RESULT ================";
        report "cycle_count   = " & integer'image(cycle_count);
        report "sr_fetched    = " & std_logic'image(sr_fetched)(2);
        report "SP at $A3     = $" & to_hstring(sp_at_sr);
        report "result_seen   = " & std_logic'image(result_seen)(2);
        report "result_value  = $" & to_hstring(result_value);
        report "end_sentinel  = " & std_logic'image(end_sentinel)(2);

        if result_seen = '0' then
            report "FAIL: $3000 never written -- CPU never reached STA after LDA $10,S"
                severity warning;
        elsif result_value = x"CC" then
            report "PASS: stack-relative read carried into DH ($0200) -- SST/silicon semantics"
                severity note;
        elsif result_value = x"BB" then
            report "FAIL: stack-relative read wrapped to $0100 -- VICE-style page-1 wrap (incorrect)"
                severity warning;
        else
            report "FAIL: $3000 = unexpected value $" & to_hstring(result_value) & " (neither $BB nor $CC)"
                severity warning;
        end if;

        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
