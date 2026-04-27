-- c64_ram64k_raw_tb.vhd — write-first contract regression for bank-$00 BRAM
--
-- Asserts the BEHAVIORAL contract that c64_ram64k must satisfy after the
-- 2026-04-27 fix (commit b267455): the registered read at cycle N+1 must
-- reflect any cycle-N write to the same address. This is the RAW window
-- that was hanging Asterix's relocated decompressor (handlers 4 and 7 of
-- the $0100-$01FF dispatcher) — INC $2D / INC $2F followed immediately
-- by LDA ($2F),Y / STA ($2D),Y returned stale pointer bytes on hardware.
--
-- IMPORTANT: GHDL simulation of `shared variable ram` + `no_rw_check`
-- gives write-first semantics naturally (the write-then-read in the same
-- process executes in source order), so this bench WILL pass even if the
-- explicit a_din_d1 bypass mux is removed. The bench catches *behavioral*
-- breaks (someone accidentally turns the entity read-first, or removes
-- the registered-read pipeline) — it does NOT catch removal of the bypass
-- on its own. The hardware M10K with no_rw_check actively returns the
-- stale value on RAW, which only the explicit mux fixes.
--
-- The runner script pairs this with a static text check that the bypass
-- line "a_dout <= a_din_d1 when a_we_d1" still exists in c64_ram64k.vhd.
-- Both must pass to claim the regression is held.
--
-- Coverage:
--   T1: write-then-read same addr (the critical RAW case)
--   T2: write-then-read different addr (must NOT corrupt unrelated reads)
--   T3: back-to-back writes followed by a read (verify forward only fires
--       once per write and the surviving read is correct)
--   T4: Asterix-style "INC $2D, then read ($2D)" sequence — write byte
--       to $002D, immediately read $002D, verify it sees the new byte
--   T5: VIC port (port B) read at the same address as a port-A write —
--       Port B does not have the bypass and is registered with 1-cycle
--       latency; we just verify it returns *some* defined value (no X)
--       because VIC and CPU share storage.
--
-- A failure is signalled via std.env.finish(1) and a "FAIL" report.
-- A pass prints "PASS: c64_ram64k RAW bypass" and finishes(0).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity c64_ram64k_raw_tb is
end entity;

architecture sim of c64_ram64k_raw_tb is
    constant CLK_PER : time := 31.25 ns; -- 32 MHz

    signal clk      : std_logic := '0';
    signal a_addr   : unsigned(15 downto 0) := (others => '0');
    signal a_din    : unsigned(7 downto 0)  := (others => '0');
    signal a_dout   : unsigned(7 downto 0);
    signal a_we     : std_logic := '0';
    signal b_addr   : unsigned(15 downto 0) := (others => '0');
    signal b_dout   : unsigned(7 downto 0);

    signal stop_clk : boolean := false;

    procedure expect(tag : string; got, want : unsigned(7 downto 0);
                     fail : inout boolean) is
    begin
        if got = want then
            report tag & ": OK (got x" & to_hstring(got) & ")";
        else
            report tag & ": FAIL (got x" & to_hstring(got)
                         & ", want x" & to_hstring(want) & ")"
                severity error;
            fail := true;
        end if;
    end procedure;

begin

    ----------------------------------------------------------------
    -- Clock
    ----------------------------------------------------------------
    clk_proc : process
    begin
        while not stop_clk loop
            clk <= '0'; wait for CLK_PER/2;
            clk <= '1'; wait for CLK_PER/2;
        end loop;
        wait;
    end process;

    ----------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------
    dut : entity work.c64_ram64k
        port map (
            clk    => clk,
            a_addr => a_addr,
            a_din  => a_din,
            a_dout => a_dout,
            a_we   => a_we,
            b_addr => b_addr,
            b_dout => b_dout
        );

    ----------------------------------------------------------------
    -- Stimulus
    ----------------------------------------------------------------
    stim : process
        variable fail : boolean := false;

        -- Drive a write at the upcoming rising edge.
        procedure write_byte(addr : unsigned(15 downto 0);
                             data : unsigned(7 downto 0)) is
        begin
            wait until falling_edge(clk);
            a_addr <= addr;
            a_din  <= data;
            a_we   <= '1';
        end procedure;

        -- Drive a read at the upcoming rising edge.
        procedure read_byte(addr : unsigned(15 downto 0)) is
        begin
            wait until falling_edge(clk);
            a_addr <= addr;
            a_din  <= (others => '0');
            a_we   <= '0';
        end procedure;

    begin
        -- Idle for a few cycles so initial output is settled.
        a_addr <= (others => '0');
        a_din  <= (others => '0');
        a_we   <= '0';
        wait for 4 * CLK_PER;

        ------------------------------------------------------------
        -- T1: write $5A to $002F at cycle N. Read $002F at cycle N+1.
        --     Bypass must forward $5A on cycle N+2's a_dout.
        ------------------------------------------------------------
        write_byte(x"002F", x"5A");           -- cycle N (write)
        read_byte (x"002F");                  -- cycle N+1 (read same addr)
        wait until rising_edge(clk);          -- complete N+1 edge
        wait for 1 ns;                        -- settle
        -- After rising edge of cycle N+1, a_dout reflects what was sampled
        -- at cycle N+1's edge (a_addr=$2F, registered-read of ram[$2F]).
        -- The bypass fires because a_we_d1 (write at N) is still '1'.
        expect("T1 RAW forward $002F=$5A", a_dout, x"5A", fail);

        ------------------------------------------------------------
        -- T2: write $A1 to $0030 then read a *different* address $0040.
        --     The bypass triggers on the cycle after the write but the
        --     CPU is now reading $0040 — verify no corruption of the
        --     subsequent settled-read of $0040.
        ------------------------------------------------------------
        -- Pre-seed $0040 = $77.
        write_byte(x"0040", x"77");
        wait until rising_edge(clk);          -- write committed
        read_byte (x"0050");                  -- dummy quench cycle
        wait until rising_edge(clk);

        write_byte(x"0030", x"A1");           -- write to $0030
        read_byte (x"0040");                  -- next cycle: read different addr
        wait until rising_edge(clk);          -- bypass would fire (returns A1)
        read_byte (x"0040");                  -- next-next: settled read of $0040
        wait until rising_edge(clk);
        wait for 1 ns;
        -- At this point a_dout is the registered read of $0040 issued in the
        -- prior cycle. a_we_d1 is '0' (no write last cycle), so bypass off,
        -- a_dout = a_dout_raw = ram[$0040] = $77.
        expect("T2 unrelated read after write", a_dout, x"77", fail);

        ------------------------------------------------------------
        -- T3: back-to-back writes ($002D=$11, $002E=$22), then read $002E.
        --     The bypass should fire for the cycle right after each write
        --     but never for an unrelated read. After both writes we issue
        --     a read of $002E; a_dout must reflect $22 once the read
        --     pipeline catches up.
        ------------------------------------------------------------
        write_byte(x"002D", x"11");
        wait until rising_edge(clk);
        write_byte(x"002E", x"22");
        wait until rising_edge(clk);
        read_byte (x"002E");
        wait until rising_edge(clk);          -- read queued; bypass fires (forwards $22)
        wait for 1 ns;
        expect("T3 forward last write $002E=$22", a_dout, x"22", fail);
        -- Issue another read of $002E to confirm the BRAM contents are also $22.
        read_byte (x"002E");
        wait until rising_edge(clk);
        wait for 1 ns;
        expect("T3 settled BRAM $002E=$22", a_dout, x"22", fail);

        ------------------------------------------------------------
        -- T4: Asterix dispatcher pattern. Sequence:
        --       1. write $80 to $002D    (e.g. INC $2D from $7F)
        --       2. read  $002D            (LDA $2D before STA ($2D),Y)
        --     The read at step 2 must observe $80, not the stale $7F.
        ------------------------------------------------------------
        -- Pre-seed $002D = $7F.
        write_byte(x"002D", x"7F");
        wait until rising_edge(clk);
        read_byte (x"0070");                  -- quench
        wait until rising_edge(clk);

        write_byte(x"002D", x"80");           -- "INC $2D" effect
        read_byte (x"002D");                  -- immediate re-read
        wait until rising_edge(clk);          -- bypass forwards $80
        wait for 1 ns;
        expect("T4 Asterix INC+read $002D=$80", a_dout, x"80", fail);

        ------------------------------------------------------------
        -- T5: VIC port-B read of $002D. No bypass on port B (read-only),
        --     but storage is shared, so after sufficient cycles the read
        --     must return whatever was last written.
        ------------------------------------------------------------
        wait until falling_edge(clk);
        b_addr <= x"002D";                    -- ask VIC port for $002D
        a_addr <= (others => '0');
        a_din  <= (others => '0');
        a_we   <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);          -- 1-cycle registered latency
        wait for 1 ns;
        expect("T5 VIC port $002D=$80", b_dout, x"80", fail);

        ------------------------------------------------------------
        -- Result
        ------------------------------------------------------------
        if fail then
            report "FAIL: c64_ram64k RAW bypass regression" severity failure;
            stop_clk <= true;
            wait for CLK_PER;
            finish(1);
        else
            report "PASS: c64_ram64k RAW bypass regression";
            stop_clk <= true;
            wait for CLK_PER;
            finish(0);
        end if;
    end process;

end architecture;
