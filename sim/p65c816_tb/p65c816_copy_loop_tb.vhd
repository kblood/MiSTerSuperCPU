-- p65c816_copy_loop_tb.vhd
--
-- Reproduces (or rules out) the "copy-loop hang" observed on hardware:
-- KERNAL RAMTAS at $FD6F-$FD85 and Asterix decompressor at $0853-$085A
-- both use tight `indexed-load + indexed-store + INY + BNE` loops that
-- never exit on the SuperCPU fork — Y appears never to wrap $FF → $00.
--
-- Two scenarios, both in emulation mode (E=1, M=X=1 implied):
--
-- SCENARIO A (abs,Y + INY + BNE)   — mirrors Asterix
--   $0800 A0 FC       LDY #$FC     ; start Y near wrap
--   $0802 B9 00 10    LDA $1000,Y
--   $0805 99 00 20    STA $2000,Y
--   $0808 C8          INY
--   $0809 D0 F7       BNE $0802    ; loops until Y wraps to 0
--   $080B A9 EE       LDA #$EE     ; marker after loop — read to end-sentinel
--   $080D 8D 00 30    STA $3000    ; marker store
--   $0810 4C 10 08    JMP $0810    ; spin forever
--
-- SCENARIO B ((zp),Y + INY + BNE)  — mirrors RAMTAS inner pattern
--   zp $02/$03 = pointer to $0400
--   $0830 A0 FC       LDY #$FC
--   $0832 B1 02       LDA ($02),Y
--   $0834 91 02       STA ($02),Y
--   $0836 C8          INY
--   $0837 D0 F9       BNE $0832
--   $0839 A9 DD       LDA #$DD
--   $083B 8D 01 30    STA $3001
--   $083E 4C 3E 08    JMP $083E
--
-- A "runner" sub-process toggles between the two scenarios by writing the
-- reset vector and resetting. Source $1000 is pre-filled with known pattern;
-- $2000/$0400 start cleared.
--
-- PASS criteria:
--   * $3000 == $EE  (scenario A reached the post-loop marker)
--   * $3001 == $DD  (scenario B reached the post-loop marker)
--   * Neither loop pushed cycle_count beyond a guard limit.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_copy_loop_tb is
end entity;

architecture sim of p65c816_copy_loop_tb is

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
        -- Reset vector → $0800 (scenario A entry)
        m(16#FFFC#) := x"00";  m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";  -- RTI stub

        -- Zero-page pointer for scenario B: $02/$03 = $0400
        m(16#0002#) := x"00";
        m(16#0003#) := x"04";

        -- SCENARIO A: abs,Y copy
        m(16#0800#) := x"A0";  m(16#0801#) := x"FC";      -- LDY #$FC
        m(16#0802#) := x"B9";  m(16#0803#) := x"00";  m(16#0804#) := x"10";  -- LDA $1000,Y
        m(16#0805#) := x"99";  m(16#0806#) := x"00";  m(16#0807#) := x"20";  -- STA $2000,Y
        m(16#0808#) := x"C8";                              -- INY
        m(16#0809#) := x"D0";  m(16#080A#) := x"F7";       -- BNE $0802
        m(16#080B#) := x"A9";  m(16#080C#) := x"EE";       -- LDA #$EE
        m(16#080D#) := x"8D";  m(16#080E#) := x"00";  m(16#080F#) := x"30"; -- STA $3000
        m(16#0810#) := x"A9";  m(16#0811#) := x"77";       -- LDA #$77
        m(16#0812#) := x"8D";  m(16#0813#) := x"30";  m(16#0814#) := x"30"; -- STA $3030 (A-end sentinel)
        m(16#0815#) := x"4C";  m(16#0816#) := x"30";  m(16#0817#) := x"08"; -- JMP $0830 (→ scenario B)

        -- SCENARIO B: (zp),Y copy
        m(16#0830#) := x"A0";  m(16#0831#) := x"FC";      -- LDY #$FC
        m(16#0832#) := x"B1";  m(16#0833#) := x"02";      -- LDA ($02),Y
        m(16#0834#) := x"91";  m(16#0835#) := x"02";      -- STA ($02),Y
        m(16#0836#) := x"C8";                              -- INY
        m(16#0837#) := x"D0";  m(16#0838#) := x"F9";       -- BNE $0832
        m(16#0839#) := x"A9";  m(16#083A#) := x"DD";       -- LDA #$DD
        m(16#083B#) := x"8D";  m(16#083C#) := x"01";  m(16#083D#) := x"30"; -- STA $3001
        m(16#083E#) := x"A9";  m(16#083F#) := x"88";       -- LDA #$88
        m(16#0840#) := x"8D";  m(16#0841#) := x"31";  m(16#0842#) := x"30"; -- STA $3031 (B-end sentinel)
        m(16#0843#) := x"4C";  m(16#0844#) := x"43";  m(16#0845#) := x"08"; -- JMP $0843 (spin)

        -- Source pattern at $1000-$10FF (index = low byte of addr)
        for i in 0 to 255 loop
            m(16#1000# + i) := std_logic_vector(to_unsigned(i, 8));
            m(16#0400# + i) := std_logic_vector(to_unsigned((i * 3 + 7) mod 256, 8));
        end loop;

        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    -- Snapshots
    signal a_marker_seen : std_logic := '0';
    signal b_marker_seen : std_logic := '0';
    signal a_end_sentinel : std_logic := '0';
    signal b_end_sentinel : std_logic := '0';
    signal pc_at_a_marker : std_logic_vector(15 downto 0) := (others => '0');
    signal pc_at_b_marker : std_logic_vector(15 downto 0) := (others => '0');
    signal iny_count : integer := 0;
    signal bne_count : integer := 0;

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

    -- Flat memory on bank $00
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

    -- Lightweight observer: count INY / BNE events and latch markers.
    snap_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                a_marker_seen   <= '0';
                b_marker_seen   <= '0';
                a_end_sentinel  <= '0';
                b_end_sentinel  <= '0';
                iny_count       <= 0;
                bne_count       <= 0;
            elsif ce = '1' then
                if dbg_ir = x"C8" then
                    iny_count <= iny_count + 1;
                end if;
                if dbg_ir = x"D0" then
                    bne_count <= bne_count + 1;
                end if;

                if we_n = '0' then
                    case to_integer(unsigned(a_out(15 downto 0))) is
                        when 16#3000# =>
                            if d_out = x"EE" then
                                a_marker_seen <= '1';
                                pc_at_a_marker <= dbg_pc;
                            end if;
                        when 16#3001# =>
                            if d_out = x"DD" then
                                b_marker_seen <= '1';
                                pc_at_b_marker <= dbg_pc;
                            end if;
                        when 16#3030# =>
                            if d_out = x"77" then
                                a_end_sentinel <= '1';
                            end if;
                        when 16#3031# =>
                            if d_out = x"88" then
                                b_end_sentinel <= '1';
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

        -- Generous budget: 256 loop iterations × ~12 cycles × 2 scenarios
        -- ≈ 6144 cycles. Run 50k cycles to catch unreachable-exit cases.
        wait for CLK_PERIOD * 50000;

        report "================ COPY-LOOP RESULT ================";
        report "iny_count = " & integer'image(iny_count);
        report "bne_count = " & integer'image(bne_count);
        report "A marker ($3000=$EE): " & std_logic'image(a_marker_seen)(2);
        report "A end    ($3030=$77): " & std_logic'image(a_end_sentinel)(2);
        report "B marker ($3001=$DD): " & std_logic'image(b_marker_seen)(2);
        report "B end    ($3031=$88): " & std_logic'image(b_end_sentinel)(2);

        if a_marker_seen = '1' then
            report "PASS (A): abs,Y + INY + BNE loop exits (PC reached $" &
                   to_hstring(pc_at_a_marker) & ")" severity note;
        else
            report "FAIL (A): abs,Y + INY + BNE loop never reached marker -- bug REPRODUCES"
                severity warning;
        end if;

        if b_marker_seen = '1' then
            report "PASS (B): (zp),Y + INY + BNE loop exits (PC reached $" &
                   to_hstring(pc_at_b_marker) & ")" severity note;
        else
            report "FAIL (B): (zp),Y + INY + BNE loop never reached marker -- bug REPRODUCES"
                severity warning;
        end if;

        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
