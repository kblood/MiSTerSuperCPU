-- p65c816_rep_tb.vhd
--
-- Reproduces (or rules out) the Doom REP-#$30 M-flag bug seen on hardware.
-- Captured trace claimed REP #$30 at $20:$0004 left M=1 (only X cleared).
-- This bench runs the same prologue against the bare P65C816 with a flat
-- memory model -- no SuperRAM pipeline, no cache, no bus arbiter -- so any
-- failure here proves the bug is inside the CPU core itself.
--
-- Test program at $0800:
--   $0800 18        CLC
--   $0801 FB        XCE         ; → native (E=0)
--   $0802 C2 30     REP #$30    ; clear M and X
--   $0804 A9 EA EA  LDA #$EAEA  ; 16-bit immediate (3 bytes)
--   $0807 80 FE     BRA $0807   ; spin
--
-- Pass criteria: after the REP retires, dbg_p has bit 5 (M) AND bit 4 (X)
-- both cleared. LDA must then consume 3 bytes and PC must reach $0807.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_rep_tb is
end entity;

architecture sim of p65c816_rep_tb is

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
        m(16#FFFC#) := x"00";  m(16#FFFD#) := x"08"; -- reset → $0800
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF"; -- IRQ/BRK emu → $FF00
        m(16#FFE6#) := x"00";  m(16#FFE7#) := x"FF"; -- BRK native
        m(16#FFEE#) := x"00";  m(16#FFEF#) := x"FF"; -- IRQ native
        m(16#FFEA#) := x"00";  m(16#FFEB#) := x"FF"; -- NMI native
        m(16#FF00#) := x"40";  -- RTI

        -- Doom-style native-mode prologue
        m(16#0800#) := x"18";  -- CLC
        m(16#0801#) := x"FB";  -- XCE
        m(16#0802#) := x"C2";  -- REP
        m(16#0803#) := x"30";  -- #$30
        m(16#0804#) := x"A9";  -- LDA #
        m(16#0805#) := x"EA";  -- low
        m(16#0806#) := x"EA";  -- high
        m(16#0807#) := x"80";  -- BRA
        m(16#0808#) := x"FE";  -- $-2
        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    -- Snapshots captured by the observer process
    signal saw_rep_fetch  : std_logic := '0';
    signal p_before_rep   : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_post_rep   : std_logic := '0';
    signal p_after_rep    : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_lda_fetch  : std_logic := '0';
    signal pc_at_lda      : std_logic_vector(15 downto 0) := (others => '0');
    signal saw_bra_fetch  : std_logic := '0';
    signal pc_at_bra      : std_logic_vector(15 downto 0) := (others => '0');

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

    -- Flat memory model on bank $00, ignore high bits
    d_in <= mem(to_integer(unsigned(a_out(15 downto 0))));

    process(clk)
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

    -- Per-cycle trace: opcode, PC, P, EF, A_OUT, D_IN. The P value reported
    -- here is the FF output BEFORE this edge commits, i.e. the same value
    -- the LOAD_P process reads when computing the next P.
    trace_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '1' and ce = '1' then
                report
                    "cyc=" & integer'image(cycle_count) &
                    " ST=" & integer'image(to_integer(unsigned(dbg_state))) &
                    " IR=$" & to_hstring(dbg_ir) &
                    " PC=$" & to_hstring(dbg_pc) &
                    " P=$" & to_hstring(dbg_p) &
                    " EF=" & std_logic'image(ef_out)(2) &
                    " A=$" & to_hstring(a_out) &
                    " DI=$" & to_hstring(d_in);
            end if;
        end if;
    end process;

    -- Snapshot observer: latches P at key opcode-fetch transitions.
    snap_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                saw_rep_fetch <= '0';
                saw_post_rep  <= '0';
                saw_lda_fetch <= '0';
                saw_bra_fetch <= '0';
            elsif ce = '1' then
                -- Capture P at the moment IR becomes $C2 (REP just latched)
                if dbg_ir = x"C2" and saw_rep_fetch = '0' then
                    saw_rep_fetch <= '1';
                    p_before_rep  <= dbg_p;
                end if;

                -- Capture P at the moment IR transitions away from $C2
                if saw_rep_fetch = '1' and saw_post_rep = '0'
                   and dbg_ir /= x"C2" then
                    saw_post_rep <= '1';
                    p_after_rep  <= dbg_p;
                end if;

                -- Capture PC when IR becomes $A9 (LDA #) for the first time
                if dbg_ir = x"A9" and saw_lda_fetch = '0' then
                    saw_lda_fetch <= '1';
                    pc_at_lda     <= dbg_pc;
                end if;

                -- Capture PC when IR becomes $80 (BRA) for the first time
                if dbg_ir = x"80" and saw_bra_fetch = '0' then
                    saw_bra_fetch <= '1';
                    pc_at_bra     <= dbg_pc;
                end if;
            end if;
        end if;
    end process;

    main_proc: process
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 8;
        rst_n <= '1';

        -- Run long enough for the prologue + LDA + first BRA to be seen
        wait for 30 us;

        report "================ RESULT ================";
        report "P_before_rep = $" & to_hstring(p_before_rep);
        report "P_after_rep  = $" & to_hstring(p_after_rep);
        report "PC_at_LDA    = $" & to_hstring(pc_at_lda);
        report "PC_at_BRA    = $" & to_hstring(pc_at_bra);

        if p_after_rep(5) = '1' then
            report "FAIL: M flag (bit 5) NOT cleared by REP #$30 -- bug REPRODUCES" severity warning;
        else
            report "PASS: M flag cleared by REP #$30" severity note;
        end if;
        if p_after_rep(4) = '1' then
            report "FAIL: X flag (bit 4) NOT cleared by REP #$30" severity warning;
        else
            report "PASS: X flag cleared by REP #$30" severity note;
        end if;
        if pc_at_bra /= x"0807" then
            report "FAIL: PC reached BRA at $" & to_hstring(pc_at_bra) & " not $0807 -- LDA was wrong width" severity warning;
        else
            report "PASS: BRA reached at $0807 (LDA was 3-byte 16-bit form)" severity note;
        end if;

        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
