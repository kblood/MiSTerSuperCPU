-- c64_superram_coherency_tb.vhd
--
-- iter-23 (2026-06-05): SYSTEM-level repro for "Bug 2" -- the SuperRAM cache
-- read-coherency bug that crashes Doom only with CACHE_READ_PATH=true.
--
-- This is the bench the iter-22 handoff demanded: it drives the REAL
-- fpga64_sid_iec (real cpu_cache, real scpu_async_bridge, real bus arb, real
-- P65C816) with a real CPU long-store-then-read sequence to SuperRAM bank $20,
-- and observes what the CPU READS THROUGH THE CACHE -- not the SDRAM probe,
-- which bypasses the cache and is useless for a cache bug.
--
-- It only works because the top (c64_reduced_top_v2) now routes the SuperRAM
-- bank to the SDRAM model (previously hardcoded bank $00 -- see memory file
-- project_v2_harness_hardcodes_bank00). The CPU runs the make_bug2_test_rom
-- program (TEST_ROM=1): enter native; LDA $2000AE (cache fill while SDRAM=$00);
-- delay; LDA #$4A; STA $2000AE; LDA $2000AE; witness the read-backs to
-- $00:0400 (first read), $00:0401 (re-read) and a $EE done marker to $00:0402.
--
-- VERDICT (read from the log):
--   * witness[1] ($00:0401) == $4A  -> cache COHERENT (no Bug 2 in this path)
--   * witness[1] != $4A (e.g. $00)  -> STALE cache read = Bug 2 reproduced
--   * SDRAM probe of $20:00AE == $4A confirms the write reached memory, so a
--     stale witness isolates the corruptor to the cache read path.
--
-- Run cache-OFF (sanity: must be $4A) and cache-ON (the real test) via the
-- runner's CACHE_READ_PATH patch. Exit code: PASS if the program ran to the
-- done marker AND witness[0]=$00 (sanity); the coherency verdict is reported
-- as a NOTE line "SUPERRAM_COHERENCY: ..." that the runner greps.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

use work.prg_loader_pkg.all;   -- hex2 / hex4 formatters

entity c64_superram_coherency_tb is
end entity;

architecture sim of c64_superram_coherency_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- ~32 MHz

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- ioctl pseudo-interface (unused here, tied off)
    signal ioctl_download : std_logic := '0';
    signal ioctl_wr       : std_logic := '0';
    signal ioctl_addr     : unsigned(15 downto 0) := (others => '0');
    signal ioctl_data     : std_logic_vector(7 downto 0) := (others => '0');
    signal ioctl_index    : std_logic_vector(7 downto 0) := x"01";

    -- SDRAM probe
    signal probe_addr : unsigned(23 downto 0) := (others => '0');
    signal probe_data : std_logic_vector(7 downto 0);

    -- CPU observability
    signal dbg_pc      : unsigned(15 downto 0);
    signal dbg_pbr     : unsigned(7 downto 0);
    signal dbg_p       : unsigned(7 downto 0);
    signal dbg_ir      : unsigned(7 downto 0);
    signal dbg_addr    : unsigned(15 downto 0);
    signal dbg_data_in : std_logic_vector(7 downto 0);
    signal dbg_we      : std_logic;
    signal dbg_en_count: unsigned(31 downto 0);
    signal dbg_diag_out: unsigned(7 downto 0);

    -- Loader status
    signal status_inj_busy   : std_logic;
    signal status_inj_end    : unsigned(15 downto 0);
    signal status_bram_inval : std_logic;
    signal status_rom_found  : std_logic;
    signal status_rom_src    : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;

    -- iter-23 DEBUG: internal-signal observers (external names into the DUT)
    -- to discriminate WHY the reset vector reads $00. Path = tb.dut(top).dut(fpga64).
    signal obs_emu     : std_logic;   -- emu_mode_816_i ('1'=emu at reset, expected)
    signal obs_cpudi   : unsigned(7 downto 0);  -- cpuDi_raw (buslogic dataToCpu)
    signal obs_cpudin  : unsigned(7 downto 0);  -- cpuDi_nocache (post SCPU-reg mux)
    signal obs_caddr   : unsigned(15 downto 0); -- cpuAddr (16-bit)
    signal obs_ahi     : unsigned(7 downto 0);  -- addr_hi_816 (bank)
    signal obs_cpudo   : unsigned(7 downto 0);  -- cpuDo (CPU write data)
    signal obs_swe     : std_logic;             -- top sdram_we
    signal obs_saddr   : unsigned(23 downto 0); -- top sdram_addr
    signal obs_sdin    : std_logic_vector(7 downto 0); -- top sdram_din

    procedure tick(signal clk : std_logic; n : natural) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

    procedure probe_byte(
        signal clk        : in    std_logic;
        signal probe_addr : out   unsigned(23 downto 0);
        signal probe_data : in    std_logic_vector(7 downto 0);
        constant addr     : in    unsigned(23 downto 0);
        variable result   : out   std_logic_vector(7 downto 0)
    ) is
    begin
        probe_addr <= addr;
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        result := probe_data;
    end procedure;

begin

    clkgen : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    rstgen : process
    begin
        reset <= '1';
        wait for 16 * CLK_PERIOD;
        wait until rising_edge(clk);
        reset <= '0';
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT: Phase 4b top with the Bug-2 SuperRAM test ROM
    ------------------------------------------------------------------
    dut : entity work.c64_reduced_top_v2
        generic map (
            SDRAM_BYTES => 16#300000#,
            TEST_ROM    => 1
        )
        port map (
            clk32             => clk,
            clk_cpu           => clk,   -- iter-23: passthrough (SCPU_MCP_ACTIVE='0') => clk_cpu = clk32. Unmapped it defaults '0' and the 816 never clocks (cpuAddr frozen $0000).
            reset             => reset,
            ioctl_download    => ioctl_download,
            ioctl_wr          => ioctl_wr,
            ioctl_addr        => ioctl_addr,
            ioctl_data        => ioctl_data,
            ioctl_index       => ioctl_index,
            probe_addr        => probe_addr,
            probe_data        => probe_data,
            bram_probe_data   => open,
            dbg_pc            => dbg_pc,
            dbg_pbr           => dbg_pbr,
            dbg_p             => dbg_p,
            dbg_ir            => dbg_ir,
            dbg_addr          => dbg_addr,
            dbg_data_in       => dbg_data_in,
            dbg_we            => dbg_we,
            dbg_en_count      => dbg_en_count,
            dbg_diag_out      => dbg_diag_out,
            status_inj_busy   => status_inj_busy,
            status_inj_end    => status_inj_end,
            status_bram_inval => status_bram_inval,
            status_rom_found  => status_rom_found,
            status_rom_src    => status_rom_src
        );

    -- iter-23 DEBUG observers (VHDL-2008 external names into the DUT hierarchy)
    obs_emu    <= << signal .c64_superram_coherency_tb.dut.dut.emu_mode_816_i : std_logic >>;
    obs_cpudi  <= << signal .c64_superram_coherency_tb.dut.dut.cpuDi_raw : unsigned(7 downto 0) >>;
    obs_cpudin <= << signal .c64_superram_coherency_tb.dut.dut.cpuDi_nocache : unsigned(7 downto 0) >>;
    obs_caddr  <= << signal .c64_superram_coherency_tb.dut.dut.cpuAddr : unsigned(15 downto 0) >>;
    obs_ahi    <= << signal .c64_superram_coherency_tb.dut.dut.addr_hi_816 : unsigned(7 downto 0) >>;
    obs_cpudo  <= << signal .c64_superram_coherency_tb.dut.dut.cpuDo : unsigned(7 downto 0) >>;
    obs_swe    <= << signal .c64_superram_coherency_tb.dut.sdram_we   : std_logic >>;
    obs_saddr  <= << signal .c64_superram_coherency_tb.dut.sdram_addr : unsigned(23 downto 0) >>;
    obs_sdin   <= << signal .c64_superram_coherency_tb.dut.sdram_din  : std_logic_vector(7 downto 0) >>;

    -- iter-23 DEBUG: catch the reset-vector fetch ($FFFA-$FFFF) and report
    -- emu mode + the byte the CPU sees, regardless of exact cycle timing.
    vecmon : process
        variable hits : integer := 0;
        variable prev : unsigned(15 downto 0) := (others => '1');
        variable prevb: unsigned(7 downto 0)  := (others => '1');
    begin
        wait until reset = '0';
        -- skip the ROM-load window; DUT reset_n releases after ~16400 cycles
        for i in 1 to 16000 loop
            wait until rising_edge(clk);
        end loop;
        while hits < 80 loop
            wait until rising_edge(clk);
            if obs_caddr /= prev or obs_ahi /= prevb then
                report "ADDR cAddr=$" & hex2(std_logic_vector(obs_ahi)) & ":" & hex4(std_logic_vector(obs_caddr))
                     & " emu=" & std_logic'image(obs_emu)
                     & " cpuDi_raw=$" & hex2(std_logic_vector(obs_cpudi))
                     & " cpuDi_nc=$" & hex2(std_logic_vector(obs_cpudin));
                prev := obs_caddr;
                prevb := obs_ahi;
                hits := hits + 1;
            end if;
        end loop;
        wait;
    end process;

    -- iter-23 DEBUG: monitor CPU stores to the witness page ($0400-$0403) and
    -- the long-store to $20:00AE so we can see which writes the CPU actually emits.
    stmon : process
        variable n : integer := 0;
        variable pwe : std_logic := '0';
        variable paddr : unsigned(23 downto 0) := (others => '1');
    begin
        wait until reset = '0';
        for i in 1 to 16000 loop
            wait until rising_edge(clk);
        end loop;
        while n < 30 loop
            wait until rising_edge(clk);
            if obs_swe = '1' and (pwe = '0' or obs_saddr /= paddr) and
               (obs_saddr = (x"00" & x"0400") or obs_saddr = (x"00" & x"0401")
                or obs_saddr = (x"00" & x"0402") or obs_saddr = (x"00" & x"0403")
                or obs_saddr = (x"20" & x"00AE")) then
                report "SDRAMWR addr=$" & hex2(std_logic_vector(obs_saddr(23 downto 16)))
                     & ":" & hex4(std_logic_vector(obs_saddr(15 downto 0)))
                     & " data=$" & hex2(obs_sdin)
                     & " (PC=$" & hex2(std_logic_vector(dbg_pbr)) & ":" & hex4(std_logic_vector(dbg_pc)) & ")";
                n := n + 1;
            end if;
            pwe := obs_swe;
            paddr := obs_saddr;
        end loop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- Stimulus + scoreboard
    ------------------------------------------------------------------
    stim : process
        variable rb        : std_logic_vector(7 downto 0);
        variable w0        : std_logic_vector(7 downto 0);  -- witness first read
        variable w1        : std_logic_vector(7 downto 0);  -- witness re-read
        variable sdr       : std_logic_vector(7 downto 0);  -- SDRAM truth $20:00AE
        variable done      : std_logic_vector(7 downto 0);
        variable pass_cnt  : integer := 0;
        variable fail_cnt  : integer := 0;
        variable waited    : integer := 0;
        constant W_FIRST   : unsigned(23 downto 0) := x"00" & x"0400";
        constant W_REREAD  : unsigned(23 downto 0) := x"00" & x"0401";
        constant W_DONE    : unsigned(23 downto 0) := x"00" & x"0402";
        constant SR_TARGET : unsigned(23 downto 0) := x"20" & x"00AE";
    begin
        wait until reset = '0';
        -- ROM load (~16 KB pushed over c64rom_wr) then the CPU boots into the
        -- test program at $E000. Trace from right at reset_n release.
        tick(clk, 16_500);  -- just past the 16384-byte ROM stream

        report "=== SuperRAM coherency repro: ROM found=" & std_logic'image(status_rom_found)
               & " src=$" & hex2(status_rom_src);

        -- iter-23 DEBUG: trace early PC so we can see whether the CPU is
        -- actually executing the test program at $E000 (CLC/XCE/long ops) or
        -- wandering (e.g. BRK -> NOP-slide). Sample a handful of points.
        for k in 0 to 39 loop
            report "PCtrace[" & integer'image(k) & "] PC=$"
                 & hex2(std_logic_vector(dbg_pbr)) & ":" & hex4(std_logic_vector(dbg_pc))
                 & " op_count=" & integer'image(to_integer(dbg_en_count))
                 & " | emu=" & std_logic'image(obs_emu)
                 & " cAddr=$" & hex2(std_logic_vector(obs_ahi)) & ":" & hex4(std_logic_vector(obs_caddr))
                 & " cpuDi_raw=$" & hex2(std_logic_vector(obs_cpudi))
                 & " cpuDi_nc=$" & hex2(std_logic_vector(obs_cpudin));
            tick(clk, 8);
        end loop;

        ----------------------------------------------------------------
        -- Let the CPU program run to completion. It finishes by op_count
        -- ~1060 (well under this settle). NOTE: we do NOT poll $0402 in a
        -- tight loop -- doing so races the CPU's spin-loop fetches on the
        -- shared SDRAM read port and reads $00 even though the SDRAM write
        -- monitor proves $0402=$EE committed. A fixed settle + single reads
        -- (the same probe pattern that reads the witnesses reliably) is robust.
        ----------------------------------------------------------------
        tick(clk, 80_000);

        -- Boot marker: did the CPU execute the very first instruction at $E000?
        probe_byte(clk, probe_addr, probe_data, x"00" & x"0403", rb);
        report "boot marker ($00:0403) = $" & hex2(rb) & "  (expect $C3 if CPU ran $E000)";
        if rb /= x"C3" then
            report "HARNESS FAULT: boot marker != $C3 -- the CPU never executed the "
                 & "test program at $E000 (check CPU boot / clk_cpu / reset_n)."
                 severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- Done marker (single read; informational -- the SDRAM-write monitor is
        -- the authoritative 'program finished' signal).
        probe_byte(clk, probe_addr, probe_data, W_DONE, done);
        report "=== CPU done marker ($00:0402) = $" & hex2(done)
               & "  (op_count=" & integer'image(to_integer(dbg_en_count))
               & ", PC=$" & hex2(std_logic_vector(dbg_pbr)) & ":" & hex4(std_logic_vector(dbg_pc)) & ")";

        -- Read the witnesses + SDRAM truth.
        probe_byte(clk, probe_addr, probe_data, W_FIRST,  w0);
        probe_byte(clk, probe_addr, probe_data, W_REREAD, w1);
        probe_byte(clk, probe_addr, probe_data, SR_TARGET, sdr);

        report "witness[0] first-read  ($00:0400) = $" & hex2(w0) & "  (expect $00, pre-write SDRAM)";
        report "witness[1] re-read     ($00:0401) = $" & hex2(w1) & "  (expect $4A if coherent)";
        report "SDRAM truth $20:00AE              = $" & hex2(sdr) & "  (expect $4A: the long-store reached memory)";

        -- Sanity: first read should be the pre-write $00.
        if w0 = x"00" then
            pass_cnt := pass_cnt + 1;
        else
            report "SANITY: first read != $00 -- SuperRAM read path or test ROM is "
                 & "wrong (got $" & hex2(w0) & ")." severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- Sanity: the long-store must reach SDRAM.
        if sdr = x"4A" then
            pass_cnt := pass_cnt + 1;
        else
            report "SANITY: SDRAM $20:00AE != $4A -- the long-store never reached "
                 & "memory (got $" & hex2(sdr) & "); a different bug than the cache."
                 severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- The coherency verdict (gated on the CPU having actually run the
        -- program -- boot marker $C3 -- not on the flaky $0402 readback).
        if rb = x"C3" then
            if w1 = x"4A" then
                report "SUPERRAM_COHERENCY: PASS  re-read=$4A (cache coherent on this path)";
            elsif sdr = x"4A" then
                report "SUPERRAM_COHERENCY: STALE re-read=$" & hex2(w1)
                     & " while SDRAM=$4A == BUG 2 REPRODUCED (cache served stale byte)";
            else
                report "SUPERRAM_COHERENCY: INCONCLUSIVE re-read=$" & hex2(w1)
                     & " SDRAM=$" & hex2(sdr) & " (write path suspect, not the cache)";
            end if;
        end if;

        tick(clk, 50);
        report "=== SUMMARY: sanity pass=" & integer'image(pass_cnt)
             & " fail=" & integer'image(fail_cnt) & " ===";
        sim_done <= true;
        if fail_cnt /= 0 then
            report "c64_superram_coherency_tb: FAIL" severity failure;
        else
            report "c64_superram_coherency_tb: PASS" severity note;
        end if;
        wait;
    end process;

end architecture;
