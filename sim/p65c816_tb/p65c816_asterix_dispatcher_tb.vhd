-- p65c816_asterix_dispatcher_tb.vhd
--
-- Runs the Asterix dispatcher code at $0100-$01FF against a synthetic
-- compressed stream that terminates with $00 (handler 0 = exit). Verifies
-- that the bare P65C816 can drive the dispatcher to completion (CLI + JMP
-- $CB00) in emulation mode.
--
-- Entry: CPU starts at $1000 which sets up state and JMPs to $0100:
--   $1000 SEI
--   $1001 LDA #$34 / STA $01          (match Asterix memory map)
--   $1005 LDA #$00 / STA $00           (DDR = 0; we don't care about 6510 port)
--   $1009 LDX #$FF / TXS               (SP = $01FF)
--   $100C LDY #$00
--   $100E LDA #$C5 / STA $2F
--   $1012 LDA #$49 / STA $30           (src ptr = $49C5)
--   $1016 LDA #$01 / STA $2D
--   $101A LDA #$08 / STA $2E           (dst ptr = $0801)
--   $101E JMP $0100
--
-- Synthetic src at $49C5 onwards (tiny compressed-style stream):
--   byte 0: $E1 = handler 7 (copy 1 byte) - top 3 bits = 111, bot 5 = 00001
--   byte 1: $AA = payload to copy to $0801
--   byte 2: $A2 = handler 5 (fill $00) X=2 - top 3 = 101, bot 5 = 00010
--   byte 3: $42 = handler 2 (run) X=2 - top 3 = 010, bot 5 = 00010 -- wait that's different
--   actually let me simplify:
--   byte 0: $E1 - handler 7, X=1: copy 1 byte
--   byte 1: $AA - the 1 byte copied
--   byte 2: $00 - handler 0, X=0: TERMINATE via BEQ to $0197 → CLI / JMP $CB00
--
-- $01A8 (handler 0) body:
--   $01A8 E0 00       CPX #$00
--   $01AA F0 EB       BEQ $0197
-- $0197:
--   $0197 2C DE 01    BIT $01DE
--   $019A A9 37       LDA #$37
--   $019C 85 01       STA $01
--   $019E 58          CLI
--   $019F 20 A0 E5    JSR $E5A0  <- we'll replace with RTS stub at $E5A0
--   $01A2 20 59 A6    JSR $A659  <- replace with RTS stub at $A659
--   $01A5 4C 00 CB    JMP $CB00
-- Game entry at $CB00: LDA #$EE / STA $3000 / JMP $CB05
--
-- PASS: CLI executed AND game entry reached ($3000 = $EE).
-- FAIL: CPU loops without reaching $CB00.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_asterix_dispatcher_tb is
end entity;

architecture sim of p65c816_asterix_dispatcher_tb is

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

    function init_mem return mem_t is
        variable m : mem_t := (others => x"EA");
    begin
        m(16#FFFC#) := x"00"; m(16#FFFD#) := x"10";   -- reset → $1000
        m(16#FFFE#) := x"00"; m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";

        -- Bootstrap at $1000 to set up state then JMP $0100
        m(16#1000#) := x"78";                                                   -- SEI
        m(16#1001#) := x"A9"; m(16#1002#) := x"34";                             -- LDA #$34
        m(16#1003#) := x"85"; m(16#1004#) := x"01";                             -- STA $01
        m(16#1005#) := x"A9"; m(16#1006#) := x"00";                             -- LDA #$00
        m(16#1007#) := x"85"; m(16#1008#) := x"00";                             -- STA $00
        m(16#1009#) := x"A2"; m(16#100A#) := x"FF";                             -- LDX #$FF
        m(16#100B#) := x"9A";                                                   -- TXS
        m(16#100C#) := x"A0"; m(16#100D#) := x"00";                             -- LDY #$00
        m(16#100E#) := x"A9"; m(16#100F#) := x"C5";                             -- LDA #$C5
        m(16#1010#) := x"85"; m(16#1011#) := x"2F";                             -- STA $2F
        m(16#1012#) := x"A9"; m(16#1013#) := x"49";                             -- LDA #$49
        m(16#1014#) := x"85"; m(16#1015#) := x"30";                             -- STA $30
        m(16#1016#) := x"A9"; m(16#1017#) := x"01";                             -- LDA #$01
        m(16#1018#) := x"85"; m(16#1019#) := x"2D";                             -- STA $2D
        m(16#101A#) := x"A9"; m(16#101B#) := x"08";                             -- LDA #$08
        m(16#101C#) := x"85"; m(16#101D#) := x"2E";                             -- STA $2E
        m(16#101E#) := x"4C"; m(16#101F#) := x"00"; m(16#1020#) := x"01";       -- JMP $0100

        -- Dispatcher at $0100-$01FF (from asterix.prg $0864-$0963)
        m(16#0100#) := x"B1"; m(16#0101#) := x"2F";
        m(16#0102#) := x"2A"; m(16#0103#) := x"2A"; m(16#0104#) := x"2A"; m(16#0105#) := x"2A";
        m(16#0106#) := x"29"; m(16#0107#) := x"07";
        m(16#0108#) := x"AA";
        m(16#0109#) := x"BD"; m(16#010A#) := x"1A"; m(16#010B#) := x"01";
        m(16#010C#) := x"8D"; m(16#010D#) := x"18"; m(16#010E#) := x"01";
        m(16#010F#) := x"B1"; m(16#0110#) := x"2F";
        m(16#0111#) := x"29"; m(16#0112#) := x"1F";
        m(16#0113#) := x"AA";
        m(16#0114#) := x"20"; m(16#0115#) := x"22"; m(16#0116#) := x"01";
        m(16#0117#) := x"4C"; m(16#0118#) := x"FF"; m(16#0119#) := x"01";
        -- jump table
        m(16#011A#) := x"A8"; m(16#011B#) := x"4A"; m(16#011C#) := x"AF"; m(16#011D#) := x"7D";
        m(16#011E#) := x"5C"; m(16#011F#) := x"42"; m(16#0120#) := x"46"; m(16#0121#) := x"30";
        -- $0122 advance src
        m(16#0122#) := x"E6"; m(16#0123#) := x"01";
        m(16#0124#) := x"8D"; m(16#0125#) := x"20"; m(16#0126#) := x"D0";
        m(16#0127#) := x"C6"; m(16#0128#) := x"01";
        m(16#0129#) := x"E6"; m(16#012A#) := x"2F";
        m(16#012B#) := x"D0"; m(16#012C#) := x"02";
        m(16#012D#) := x"E6"; m(16#012E#) := x"30";
        m(16#012F#) := x"60";
        -- $0130 handler 7 body
        m(16#0130#) := x"B1"; m(16#0131#) := x"2F";
        m(16#0132#) := x"20"; m(16#0133#) := x"22"; m(16#0134#) := x"01";
        m(16#0135#) := x"91"; m(16#0136#) := x"2D";
        m(16#0137#) := x"E6"; m(16#0138#) := x"2D";
        m(16#0139#) := x"D0"; m(16#013A#) := x"02";
        m(16#013B#) := x"E6"; m(16#013C#) := x"2E";
        m(16#013D#) := x"CA";
        m(16#013E#) := x"D0"; m(16#013F#) := x"F5";
        m(16#0140#) := x"F0"; m(16#0141#) := x"BE";
        -- $0142 handler 5 (fill $00)
        m(16#0142#) := x"A9"; m(16#0143#) := x"00";
        m(16#0144#) := x"F0"; m(16#0145#) := x"EF";
        -- $0146 handler 6 (fill $FF)
        m(16#0146#) := x"A9"; m(16#0147#) := x"FF";
        m(16#0148#) := x"D0"; m(16#0149#) := x"EB";
        -- $014A handler 1
        m(16#014A#) := x"B1"; m(16#014B#) := x"2F";
        m(16#014C#) := x"91"; m(16#014D#) := x"2D";
        m(16#014E#) := x"20"; m(16#014F#) := x"22"; m(16#0150#) := x"01";
        m(16#0151#) := x"E6"; m(16#0152#) := x"2D";
        m(16#0153#) := x"D0"; m(16#0154#) := x"02";
        m(16#0155#) := x"E6"; m(16#0156#) := x"2E";
        m(16#0157#) := x"CA";
        m(16#0158#) := x"D0"; m(16#0159#) := x"F0";
        m(16#015A#) := x"F0"; m(16#015B#) := x"A4";
        -- $015C handler 4
        m(16#015C#) := x"20"; m(16#015D#) := x"75"; m(16#015E#) := x"01";
        m(16#015F#) := x"B1"; m(16#0160#) := x"2F";
        m(16#0161#) := x"20"; m(16#0162#) := x"22"; m(16#0163#) := x"01";
        m(16#0164#) := x"91"; m(16#0165#) := x"2D";
        m(16#0166#) := x"E6"; m(16#0167#) := x"2D";
        m(16#0168#) := x"D0"; m(16#0169#) := x"02";
        m(16#016A#) := x"E6"; m(16#016B#) := x"2E";
        m(16#016C#) := x"CA";
        m(16#016D#) := x"D0"; m(16#016E#) := x"F5";
        m(16#016F#) := x"C6"; m(16#0170#) := x"39";
        m(16#0171#) := x"10"; m(16#0172#) := x"F1";
        m(16#0173#) := x"30"; m(16#0174#) := x"8B";
        -- $0175 helper
        m(16#0175#) := x"86"; m(16#0176#) := x"39";
        m(16#0177#) := x"B1"; m(16#0178#) := x"2F";
        m(16#0179#) := x"AA";
        m(16#017A#) := x"4C"; m(16#017B#) := x"22"; m(16#017C#) := x"01";
        -- $017D handler 3
        m(16#017D#) := x"20"; m(16#017E#) := x"75"; m(16#017F#) := x"01";
        m(16#0180#) := x"B1"; m(16#0181#) := x"2F";
        m(16#0182#) := x"91"; m(16#0183#) := x"2D";
        m(16#0184#) := x"20"; m(16#0185#) := x"22"; m(16#0186#) := x"01";
        m(16#0187#) := x"E6"; m(16#0188#) := x"2D";
        m(16#0189#) := x"D0"; m(16#018A#) := x"02";
        m(16#018B#) := x"E6"; m(16#018C#) := x"2E";
        m(16#018D#) := x"CA";
        m(16#018E#) := x"D0"; m(16#018F#) := x"F0";
        m(16#0190#) := x"C6"; m(16#0191#) := x"39";
        m(16#0192#) := x"10"; m(16#0193#) := x"EC";
        m(16#0194#) := x"4C"; m(16#0195#) := x"00"; m(16#0196#) := x"01";
        -- $0197 exit path
        m(16#0197#) := x"2C"; m(16#0198#) := x"DE"; m(16#0199#) := x"01";
        m(16#019A#) := x"A9"; m(16#019B#) := x"37";
        m(16#019C#) := x"85"; m(16#019D#) := x"01";
        m(16#019E#) := x"58";
        m(16#019F#) := x"20"; m(16#01A0#) := x"A0"; m(16#01A1#) := x"E5";
        m(16#01A2#) := x"20"; m(16#01A3#) := x"59"; m(16#01A4#) := x"A6";
        m(16#01A5#) := x"4C"; m(16#01A6#) := x"00"; m(16#01A7#) := x"CB";
        -- $01A8 handler 0
        m(16#01A8#) := x"E0"; m(16#01A9#) := x"00";
        m(16#01AA#) := x"F0"; m(16#01AB#) := x"EB";
        m(16#01AC#) := x"A9"; m(16#01AD#) := x"03";
        m(16#01AE#) := x"2C"; m(16#01AF#) := x"A9"; m(16#01B0#) := x"08";

        -- KERNAL/BASIC stubs: RTS
        m(16#E5A0#) := x"60";  -- RTS
        m(16#A659#) := x"60";  -- RTS

        -- Game entry at $CB00: marker write then spin
        m(16#CB00#) := x"A9"; m(16#CB01#) := x"EE";                             -- LDA #$EE
        m(16#CB02#) := x"8D"; m(16#CB03#) := x"00"; m(16#CB04#) := x"30";       -- STA $3000
        m(16#CB05#) := x"4C"; m(16#CB06#) := x"05"; m(16#CB07#) := x"CB";       -- JMP $CB05

        -- Synthetic src stream at $49C5: handler 7 w/X=1 + 1 payload byte + handler 0 term
        -- byte $49C5 = $E1: top 3 = 111 -> handler 7, bot 5 = 00001 -> X=1 -> copy 1 byte
        m(16#49C5#) := x"E1";
        m(16#49C6#) := x"AA";  -- payload
        m(16#49C7#) := x"00";  -- handler 0 terminator

        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;

    signal cli_seen    : std_logic := '0';
    signal cb00_seen   : std_logic := '0';
    signal game_marker : std_logic := '0';
    signal pc_prev     : std_logic_vector(15 downto 0) := (others => '0');

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

    obs: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                cli_seen    <= '0';
                cb00_seen   <= '0';
                game_marker <= '0';
            elsif ce = '1' then
                pc_prev <= dbg_pc;
                -- CLI ($58) executed at $019E
                if dbg_pbr = x"00" and dbg_pc = x"019F" and dbg_ir = x"58" then
                    cli_seen <= '1';
                end if;
                -- Game entry at $CB00
                if dbg_pbr = x"00" and dbg_pc = x"CB01" then
                    cb00_seen <= '1';
                end if;
                -- Marker write at $3000
                if we_n = '0' and a_out(15 downto 0) = x"3000"
                   and d_out = x"EE" then
                    game_marker <= '1';
                end if;
            end if;
        end if;
    end process;

    main_proc: process
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 8;
        rst_n <= '1';
        wait for CLK_PERIOD * 100000;   -- ~3 ms

        report "================ DISPATCHER RESULT ================";
        report "CLI seen (PC=$019E, IR=$58): " & std_logic'image(cli_seen)(2);
        report "$CB00 reached: " & std_logic'image(cb00_seen)(2);
        report "Game marker $3000=$EE written: " & std_logic'image(game_marker)(2);

        if game_marker = '1' then
            report "PASS: dispatcher terminates correctly, game entry reached";
        else
            report "FAIL: dispatcher did NOT exit, bug REPRODUCES on bare CPU"
                severity warning;
        end if;

        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
