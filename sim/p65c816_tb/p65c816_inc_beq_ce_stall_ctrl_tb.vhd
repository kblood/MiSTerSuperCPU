-- p65c816_inc_beq_wolf3d_tb.vhd
--
-- Tests the 21st-pass Wolf3D bank-$28-freeze hypothesis in isolation:
-- does `INC $07B9` (absolute read-modify-write) ever leave a stale/wrong
-- Z flag for the immediately-following `BEQ`, causing a premature branch
-- when the incremented value is nonzero? Reproduces the EXACT byte
-- sequence loader.prg uses around its outer-loop bank-exit check
-- (INC $D020 ; INC $07B7 ; INC $07B9 ; BEQ exit ; JMP loop_top), run for
-- 3 full 8-bit wraps (768 iterations) with no other bus master present.
--
-- This bench has NO REU/VIC-II contention modeled — it is a control test
-- for the "plain CPU flag-computation bug" half of the hypothesis. A
-- clean pass here does NOT rule out the bug; it narrows it toward
-- requiring genuine bus contention (REU DMA / VIC-II badline) to
-- manifest, which would need a fuller harness (c64_reduced_harness) to
-- test. See project_wolf3d_postreu_bank28_freeze_regression.md, 21st
-- pass "Next step".
--
-- PASS criteria: every BEQ-taken event pairs with a $07B9 write of
-- exactly $00, and every wrap (write of $00) is followed by BEQ taken.
-- Any mismatch is reported as a VIOLATION with the iteration index and
-- observed value.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use IEEE.std_logic_textio.all;

-- CE-stall variant (25th pass): tests the concrete hazard found in
-- cpu_65c816.vhd:89-96 -- the wrapper protects RDY_IN against
-- mid-write stalls (`rdy_gated <= rdy or not localWe`) but CE
-- (`CE => enable`, and `enable = enableCpu_816 = enableCpu and not
-- dma_active and supercpu_en`) has NO equivalent protection. If REU
-- DMA (dma_active) asserts mid-RMW, CE can drop with no write-cycle
-- guard. This variant drives CE low for several cycles starting
-- immediately after the dummy-write of the FINAL (wrap) iteration's
-- `INC $07B9`, to test whether a CE stall landing inside the
-- dummy-then-real RMW write pair corrupts the eventual real write
-- value or the flags BEQ reads. See
-- project_wolf3d_postreu_bank28_freeze_regression.md, 24th pass
-- "Next step" (a).
-- CONTROL variant (25th pass, second half): identical harness/code to
-- p65c816_inc_beq_ce_stall_tb.vhd but with STALL_START pushed out of
-- the simulated range so CE never actually drops. Isolates whether the
-- 256->257 write-count discrepancy seen in the stalled runs is caused
-- by the stall itself, or is a harness/accounting artifact shared by
-- any test using this file structure.
entity p65c816_inc_beq_ce_stall_ctrl_tb is
end entity;

architecture sim of p65c816_inc_beq_ce_stall_ctrl_tb is

    signal clk    : std_logic := '0';
    signal rst_n  : std_logic := '0';
    -- Stall CE for STALL_LEN cycles starting STALL_START cycles in --
    -- chosen from the unperturbed reference run, where the dummy write
    -- of the final (wrap) iteration's INC $07B9 lands at cycle 5908
    -- (we_n=0, d_out=$FF) and the real write would naturally follow at
    -- cycle 5909 with no gap. Stalling right after the dummy write
    -- tests whether delaying the real write corrupts it.
    constant STALL_START : integer := 999999999;
    constant STALL_LEN   : integer := 6;
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
        -- Reset vector -> $0800
        m(16#FFFC#) := x"00";  m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";  -- RTI stub

        m(16#0800#) := x"78";                                          -- SEI
        m(16#0801#) := x"A9";  m(16#0802#) := x"00";                    -- LDA #$00
        m(16#0803#) := x"8D";  m(16#0804#) := x"B7";  m(16#0805#) := x"07"; -- STA $07B7
        m(16#0806#) := x"8D";  m(16#0807#) := x"B9";  m(16#0808#) := x"07"; -- STA $07B9

        -- outer_loop ($0809), byte-for-byte identical opcode/addressing
        -- sequence to loader.prg's $08BC-$08C9 (reloc $079C-$07A9):
        m(16#0809#) := x"EE";  m(16#080A#) := x"20";  m(16#080B#) := x"D0"; -- INC $D020
        m(16#080C#) := x"EE";  m(16#080D#) := x"B7";  m(16#080E#) := x"07"; -- INC $07B7
        m(16#080F#) := x"EE";  m(16#0810#) := x"B9";  m(16#0811#) := x"07"; -- INC $07B9
        m(16#0812#) := x"F0";  m(16#0813#) := x"03";                    -- BEQ $0817
        m(16#0814#) := x"4C";  m(16#0815#) := x"09";  m(16#0816#) := x"08"; -- JMP $0809

        -- exit ($0817), mirrors loader.prg's $08CA exit block start:
        m(16#0817#) := x"8D";  m(16#0818#) := x"7B";  m(16#0819#) := x"D0"; -- STA $D07B
        m(16#081A#) := x"EE";  m(16#081B#) := x"00";  m(16#081C#) := x"30"; -- INC $3000 (exit marker)
        m(16#081D#) := x"4C";  m(16#081E#) := x"1D";  m(16#081F#) := x"08"; -- JMP $081D (spin)

        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    signal last_07b9_val   : std_logic_vector(7 downto 0) := (others => '0');
    signal we_n_prev        : std_logic := '1';
    signal write_index      : integer := 0;
    signal exit_seen        : std_logic := '0';
    signal exit_write_index : integer := 0;
    signal exit_val         : std_logic_vector(7 downto 0) := (others => '0');
    signal violation        : std_logic := '0';
    signal violation_count  : integer := 0;

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

    -- During the CE stall, simulate a competing bus master (REU DMA)
    -- putting its own data on the shared bus instead of the CPU's
    -- expected read/write target -- tests whether the CPU latches this
    -- garbage on resume rather than the value it already captured.
    d_in <= x"AA" when ce = '0' else mem(to_integer(unsigned(a_out(15 downto 0))));

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

    -- Synthetic dma_active-style CE stall: mirrors what a REU DMA
    -- request would do to enableCpu_816 if it asserted mid-RMW, with
    -- none of the RDY path's write-cycle protection.
    ce <= '0' when (cycle_count >= STALL_START and cycle_count < STALL_START + STALL_LEN)
          else '1';

    snap_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                write_index      <= 0;
                exit_seen        <= '0';
                exit_write_index <= 0;
                exit_val         <= (others => '0');
                violation        <= '0';
                violation_count  <= 0;
                last_07b9_val    <= (others => '0');
                we_n_prev        <= '1';
            elsif ce = '1' then
                we_n_prev <= we_n;

                if write_index >= 255 and write_index <= 257 and exit_seen = '0' then
                    report "cyc=" & integer'image(cycle_count) &
                           " a_out=$" & to_hstring(a_out(15 downto 0)) &
                           " we_n=" & std_logic'image(we_n)(2) &
                           " d_out=$" & to_hstring(d_out) &
                           " vpa=" & std_logic'image(vpa)(2) &
                           " vda=" & std_logic'image(vda)(2) &
                           " P=$" & to_hstring(dbg_p) &
                           " Z=" & std_logic'image(dbg_p(1))(2);
                end if;

                -- NMOS RMW ops (P65C816.vhd rmw_modify_cycle) do a
                -- dummy(old-value)-then-real(new-value) write pair to the
                -- SAME address with we_n staying low continuously across
                -- both -- only the falling edge is a new logical write
                -- group, but the VALUE that matters (the one BEQ actually
                -- sees reflected in Z) is the LAST one in the group, i.e.
                -- level-track the value on every matching cycle so it
                -- naturally ends up holding the real (second) write.
                if we_n = '0' and to_integer(unsigned(a_out(15 downto 0))) = 16#07B9# then
                    last_07b9_val <= d_out;
                end if;
                if we_n = '0' and we_n_prev = '1' and to_integer(unsigned(a_out(15 downto 0))) = 16#07B9# then
                    write_index   <= write_index + 1;
                    if write_index + 1 <= 3 or
                       (write_index + 1 >= 253 and write_index + 1 <= 260) or
                       (write_index + 1 >= 509 and write_index + 1 <= 516) then
                        report "WR $07B9 idx=" & integer'image(write_index + 1) &
                               " val=$" & to_hstring(d_out);
                    end if;
                end if;

                if vpa = '1' and vda = '1' and a_out(15 downto 0) = x"0814"
                   and ((write_index >= 253 and write_index <= 260) or
                        (write_index >= 509 and write_index <= 516)) then
                    report "PC=$0814 (BEQ NOT taken) at write_index=" & integer'image(write_index);
                end if;

                -- exit ($0817) is reachable ONLY via BEQ-taken in this
                -- program -- first time we see it, pair with whatever
                -- $07B9 write most recently happened.
                if exit_seen = '0' and vpa = '1' and vda = '1'
                   and a_out(15 downto 0) = x"0817" then
                    exit_seen        <= '1';
                    exit_write_index <= write_index;
                    exit_val         <= last_07b9_val;
                    report "PC=$0817 (BEQ TAKEN) at write_index=" & integer'image(write_index) &
                           " last_val=$" & to_hstring(last_07b9_val);
                    if last_07b9_val /= x"00" then
                        violation       <= '1';
                        violation_count <= violation_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    main_proc: process
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 8;
        rst_n <= '1';

        -- 3 full 256-wraps worth of loop body (~20 cycles/iter * 768
        -- iterations =~ 15360 cycles), generous margin to 200k cycles.
        wait for CLK_PERIOD * 200000;

        report "================ INC/BEQ WOLF3D-LOOP RESULT ================";
        report "total $07B9 writes observed = " & integer'image(write_index);
        report "exit_seen = " & std_logic'image(exit_seen)(2);
        report "exit occurred at write #" & integer'image(exit_write_index) &
               " with value $" & to_hstring(exit_val);
        report "violation_count = " & integer'image(violation_count);

        if exit_seen = '0' then
            report "FAIL: loop never exited within budget -- BEQ never taken even at true wrap, or hung"
                severity warning;
        elsif violation = '1' then
            report "FAIL: BEQ taken with $07B9 != $00 -- FLAG-TIMING BUG REPRODUCED in pure-CPU test (no bus contention needed)"
                severity warning;
        elsif exit_write_index /= 256 then
            report "FAIL: exited at wrong write count (expected 256 for first true wrap)"
                severity warning;
        else
            report "PASS: BEQ fired exactly once, at write #256, value $00 -- no flag-timing bug in isolated CPU-only test"
                severity note;
        end if;

        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
