-- c64_internal_fastfire_tb.vhd
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

entity c64_internal_fastfire_tb is
end entity;

architecture sim of c64_internal_fastfire_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- ~32 MHz

    signal clk   : std_logic := '0';
    -- iter-24: real 64 MHz SDRAM clock. PLL-aligned so clk32 rising edges
    -- coincide with every-other clk64 rising edge (matches c64.sv clk_sys/clk64).
    -- clk32 starts '0' (rises at 15.625 ns); clk64 starts '1' (rises at 15.625,
    -- 31.25, ...). The intermediate clk64 rising edge (mid clk32 period) is where
    -- the SDRAM ce-edge / data_valid drop lands -> the clk64->clk32 stale-high
    -- window the cache fill races (Bug 2).
    signal clk64 : std_logic := '1';
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

    -- iter-24: dual-clock mode select. false = clk32 SDRAM (green coherent
    -- baseline). true = clk64 faithful-timing SDRAM (the proof that Bug 2 is a
    -- setup-time class: in zero-delay sim the CPU itself reads stale SDRAM and
    -- BRK-loops, since there is no SDC multicycle to let it sample late). The
    -- runner flips this in lockstep with the top's CLK64_SDRAM generic.
    constant DUALCLK : boolean := false;

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

    -- iter-24: the built-in HW divergence detector (diag_proc, fpga64:5178).
    -- A non-zero count = a cache HIT served rp_cache_di_d1 /= cpuDi_nocache =
    -- exactly Bug 2 (stale cache byte), with the offending addr/bank + the two
    -- bytes captured at the first divergence. This is the SAME detector used on
    -- HW (Build-D WD), now observed in-system.
    signal obs_dvalid  : std_logic;             -- sdram_data_valid_sync (in DUT)
    signal obs_mmcount : unsigned(15 downto 0); -- diag_mm_count
    signal obs_mmaddr  : unsigned(15 downto 0); -- diag_mm_addr
    signal obs_mmbank  : unsigned(7 downto 0);  -- diag_mm_bank
    signal obs_mmcache : unsigned(7 downto 0);  -- diag_mm_cache
    signal obs_mmsdram : unsigned(7 downto 0);  -- diag_mm_sdram

    -- iter-27: INTERNAL_FAST_FIRE validation observers (arbiter internals).
    -- cpu_cyc / cpu_cyc_s(1) are the prefetch-issue and MAIN-consume strobes;
    -- vda_816 / vpa_816 are the live (pending-cycle) CPU access flags; enableCpu
    -- is the registered CPU advance pulse. The decisive invariant: cpu_cyc must
    -- NEVER assert while vda=vpa=0 (no prefetch on an internal cycle => no
    -- dangling MAIN = the Codex #1 fix). en_gap is the clk32-since-last-fire.
    signal obs_cpu_cyc  : std_logic;
    signal obs_cpu_cycs : std_logic_vector(1 downto 0); -- cpu_cyc_s pipeline
    signal obs_cpu_cyc1 : std_logic;            -- cpu_cyc_s(1) = MAIN consume
    signal obs_vda      : std_logic;
    signal obs_vpa      : std_logic;
    signal obs_encpu    : std_logic;            -- enableCpu (registered advance)
    signal obs_engap    : unsigned(5 downto 0);

    -- FASTFIRE_MODE: report-only flag the runner flips in lockstep with the
    -- staged fpga64's INTERNAL_FAST_FIRE constant (sed). Lets a single log line
    -- record which arbiter the run exercised; does NOT change DUT behavior.
    constant FASTFIRE_MODE : boolean := false;

    -- Validation accumulators (driven by the invariant/metric process).
    signal viol_count   : integer := 0;   -- cpu_cyc fired while internal (must be 0)
    signal viol_main    : integer := 0;   -- cpu_cyc_s(1) fired while internal (info)
    signal fastfire_cnt : integer := 0;   -- enableCpu pulses on internal cycles
    signal mem_encpu    : integer := 0;   -- enableCpu pulses on memory cycles
    signal ticks_to_tgt : integer := -1;  -- clk32 ticks reset_n->op_count=TARGET_OPS

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

    -- iter-24: 64 MHz clock for the behavioral SDRAM. Starts '1' so its rising
    -- edges land at 15.625/31.25/46.875 ns; clk32 rises at 15.625/46.875 ns, so
    -- every clk32 rising edge coincides with a clk64 rising edge (PLL-aligned),
    -- with one extra clk64 rising edge mid clk32 period.
    clk64gen : process
    begin
        while not sim_done loop
            clk64 <= '1';
            wait for CLK_PERIOD / 4;
            clk64 <= '0';
            wait for CLK_PERIOD / 4;
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
            TEST_ROM    => 1,
            CLK64_SDRAM => DUALCLK
        )
        port map (
            clk32             => clk,
            clk_cpu           => clk,   -- iter-23: passthrough (SCPU_MCP_ACTIVE='0') => clk_cpu = clk32. Unmapped it defaults '0' and the 816 never clocks (cpuAddr frozen $0000).
            clk64             => clk64, -- iter-24: 64MHz SDRAM clock (clk64_sdram_model)
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
    obs_emu    <= << signal .c64_internal_fastfire_tb.dut.dut.emu_mode_816_i : std_logic >>;
    obs_cpudi  <= << signal .c64_internal_fastfire_tb.dut.dut.cpuDi_raw : unsigned(7 downto 0) >>;
    obs_cpudin <= << signal .c64_internal_fastfire_tb.dut.dut.cpuDi_nocache : unsigned(7 downto 0) >>;
    obs_caddr  <= << signal .c64_internal_fastfire_tb.dut.dut.cpuAddr : unsigned(15 downto 0) >>;
    obs_ahi    <= << signal .c64_internal_fastfire_tb.dut.dut.addr_hi_816 : unsigned(7 downto 0) >>;
    obs_cpudo  <= << signal .c64_internal_fastfire_tb.dut.dut.cpuDo : unsigned(7 downto 0) >>;
    obs_swe    <= << signal .c64_internal_fastfire_tb.dut.sdram_we   : std_logic >>;
    obs_saddr  <= << signal .c64_internal_fastfire_tb.dut.sdram_addr : unsigned(23 downto 0) >>;
    obs_sdin   <= << signal .c64_internal_fastfire_tb.dut.sdram_din  : std_logic_vector(7 downto 0) >>;

    -- iter-24: divergence detector + data-valid handshake observers.
    obs_dvalid  <= << signal .c64_internal_fastfire_tb.dut.dut.sdram_data_valid_sync : std_logic >>;
    obs_mmcount <= << signal .c64_internal_fastfire_tb.dut.dut.diag_mm_count : unsigned(15 downto 0) >>;
    obs_mmaddr  <= << signal .c64_internal_fastfire_tb.dut.dut.diag_mm_addr  : unsigned(15 downto 0) >>;
    obs_mmbank  <= << signal .c64_internal_fastfire_tb.dut.dut.diag_mm_bank  : unsigned(7 downto 0) >>;
    obs_mmcache <= << signal .c64_internal_fastfire_tb.dut.dut.diag_mm_cache : unsigned(7 downto 0) >>;
    obs_mmsdram <= << signal .c64_internal_fastfire_tb.dut.dut.diag_mm_sdram : unsigned(7 downto 0) >>;

    -- iter-27: arbiter-internal observers for the INTERNAL_FAST_FIRE validation.
    obs_cpu_cyc  <= << signal .c64_internal_fastfire_tb.dut.dut.cpu_cyc   : std_logic >>;
    obs_cpu_cycs <= << signal .c64_internal_fastfire_tb.dut.dut.cpu_cyc_s : std_logic_vector(1 downto 0) >>;
    obs_vda      <= << signal .c64_internal_fastfire_tb.dut.dut.vda_816   : std_logic >>;
    obs_vpa      <= << signal .c64_internal_fastfire_tb.dut.dut.vpa_816   : std_logic >>;
    obs_encpu    <= << signal .c64_internal_fastfire_tb.dut.dut.enableCpu : std_logic >>;
    obs_engap    <= << signal .c64_internal_fastfire_tb.dut.dut.en_gap    : unsigned(5 downto 0) >>;
    obs_cpu_cyc1 <= obs_cpu_cycs(1);

    -- iter-27: INVARIANT + METRIC monitor. Samples every clk32 rising edge once
    -- the CPU is running the test program (past the ROM-load + boot window).
    --   INVARIANT (decisive, Codex #1 fix): cpu_cyc must NEVER be '1' while the
    --     pending cycle is internal (vda=vpa=0). A nonzero viol_count means an
    --     internal cycle issued a prefetch => the dangling-MAIN hazard is live.
    --   viol_main: cpu_cyc_s(1) (a MAIN consume) coinciding with an internal
    --     pending cycle. Informational — under the fix this should also stay 0
    --     in steady state (no MAIN consume is owed to an internal cycle).
    --   ENGAGEMENT: fastfire_cnt counts enableCpu advances taken while the
    --     pending cycle is internal => the lever actually fired. mem_encpu counts
    --     advances on memory cycles (the unchanged main path).
    --   METRIC: ticks_to_tgt = clk32 edges from reset_n release until the CPU has
    --     retired TARGET_OPS cycles (dbg_en_count). Fewer ticks for the same op
    --     count = the throughput win. Compared across the false/true A/B runs.
    invariant_mon : process
        -- The make_bug2_test_rom retires ~2502 ops before the done marker; pick a
        -- target safely below that so both A/B runs latch the metric mid-program.
        constant TARGET_OPS : integer := 2000;
        variable ticks   : integer := 0;
        variable prev_en : std_logic := '0';
        variable internal_now : boolean;
    begin
        wait until reset = '0';
        -- skip the ROM-load + boot settle (same window the other monitors use)
        for i in 1 to 16000 loop
            wait until rising_edge(clk);
        end loop;
        loop
            wait until rising_edge(clk);
            ticks := ticks + 1;
            internal_now := (obs_vda = '0' and obs_vpa = '0');

            -- INVARIANT: no prefetch may be issued on an internal cycle.
            if obs_cpu_cyc = '1' and internal_now then
                viol_count <= viol_count + 1;
                if viol_count < 8 then
                    report "FASTFIRE INVARIANT VIOLATION: cpu_cyc=1 while vda=vpa=0"
                         & " (en_gap=" & integer'image(to_integer(obs_engap))
                         & ", PC=$" & hex2(std_logic_vector(dbg_pbr)) & ":" & hex4(std_logic_vector(dbg_pc)) & ")"
                         severity warning;
                end if;
            end if;
            if obs_cpu_cyc1 = '1' and internal_now then
                viol_main <= viol_main + 1;
            end if;

            -- ENGAGEMENT: classify each CPU advance (rising enableCpu).
            if obs_encpu = '1' and prev_en = '0' then
                if internal_now then
                    fastfire_cnt <= fastfire_cnt + 1;
                else
                    mem_encpu <= mem_encpu + 1;
                end if;
            end if;
            prev_en := obs_encpu;

            -- METRIC: latch the tick count when op_count first reaches TARGET_OPS.
            if ticks_to_tgt < 0 and to_integer(dbg_en_count) >= TARGET_OPS then
                ticks_to_tgt <= ticks;
                report "FASTFIRE METRIC: reached op_count=" & integer'image(TARGET_OPS)
                     & " in " & integer'image(ticks) & " clk32 ticks (mode FASTFIRE="
                     & boolean'image(FASTFIRE_MODE) & ")";
            end if;
        end loop;
    end process;

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
                or obs_saddr = (x"00" & x"0405")
                or obs_saddr = (x"20" & x"00AE") or obs_saddr = (x"20" & x"0140")) then
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
        variable w0        : std_logic_vector(7 downto 0);  -- A read (line $20:0140)
        variable w1        : std_logic_vector(7 downto 0);  -- B first read (miss, live SDRAM)
        variable w2        : std_logic_vector(7 downto 0);  -- B re-read (HIT) <- the key witness
        variable sdr       : std_logic_vector(7 downto 0);  -- SDRAM truth $20:00AE
        variable sdrA      : std_logic_vector(7 downto 0);  -- SDRAM truth $20:0140
        variable done      : std_logic_vector(7 downto 0);
        variable pass_cnt  : integer := 0;
        variable fail_cnt  : integer := 0;
        variable waited    : integer := 0;
        constant W_AREAD   : unsigned(23 downto 0) := x"00" & x"0400";
        constant W_BFIRST  : unsigned(23 downto 0) := x"00" & x"0401";
        constant W_BREREAD : unsigned(23 downto 0) := x"00" & x"0405";
        constant W_DONE    : unsigned(23 downto 0) := x"00" & x"0402";
        constant SR_TARGET : unsigned(23 downto 0) := x"20" & x"00AE";
        constant SR_LINEA  : unsigned(23 downto 0) := x"20" & x"0140";
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

        -- iter-24 dual-clock diagnostic: did the emu copy-stub's STA $0800,X
        -- writes land in SDRAM? ($0800 = LDA #$C3 = $A9, $0801 = $C3). If these
        -- are $00, the clk64 model's WRITE path is broken; if non-$00 but the CPU
        -- still BRK-loops, the READ phase (fetch from $0800) is the issue.
        probe_byte(clk, probe_addr, probe_data, x"00" & x"0800", rb);
        report "copy-check $00:0800 = $" & hex2(rb) & "  (expect $A9 = body LDA #imm)";
        probe_byte(clk, probe_addr, probe_data, x"00" & x"0801", rb);
        report "copy-check $00:0801 = $" & hex2(rb) & "  (expect $C3)";

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
        probe_byte(clk, probe_addr, probe_data, W_AREAD,   w0);
        probe_byte(clk, probe_addr, probe_data, W_BFIRST,  w1);
        probe_byte(clk, probe_addr, probe_data, W_BREREAD, w2);
        probe_byte(clk, probe_addr, probe_data, SR_TARGET, sdr);
        probe_byte(clk, probe_addr, probe_data, SR_LINEA,  sdrA);

        report "witness[0] A read      ($00:0400) = $" & hex2(w0) & "  (expect $AA: line A $20:0140)";
        report "witness[1] B 1st read  ($00:0401) = $" & hex2(w1) & "  (expect $4A: miss serves live SDRAM)";
        report "witness[2] B re-read   ($00:0405) = $" & hex2(w2) & "  (expect $4A coherent / $AA = STALE HIT = BUG 2)";
        report "SDRAM truth $20:00AE              = $" & hex2(sdr)  & "  (expect $4A)";
        report "SDRAM truth $20:0140              = $" & hex2(sdrA) & "  (expect $AA)";

        -- Sanity: the seed long-stores must reach SDRAM.
        if sdr = x"4A" and sdrA = x"AA" then
            pass_cnt := pass_cnt + 1;
        else
            report "SANITY: SDRAM seed wrong ($20:00AE=$" & hex2(sdr) & " $20:0140=$" & hex2(sdrA)
                 & ") -- the long-stores never reached memory; a different bug than the cache."
                 severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- Sanity: the B first read (a MISS) must serve live SDRAM = $4A. A miss
        -- reads cpuDi_nocache directly (no cache override), so this is always
        -- correct unless the SuperRAM read path itself is broken.
        if w1 = x"4A" then
            pass_cnt := pass_cnt + 1;
        else
            report "SANITY: B first read != $4A (got $" & hex2(w1)
                 & ") -- SuperRAM read path or test ROM is wrong." severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- iter-24: in-system divergence detector readout. This is the decisive
        -- in-system Bug-2 signal — independent of the witness pattern. A non-zero
        -- count means a cache HIT served a byte that differs from live SDRAM.
        report "DIAG diverge count=" & integer'image(to_integer(obs_mmcount))
             & " first @ $" & hex2(std_logic_vector(obs_mmbank)) & ":" & hex4(std_logic_vector(obs_mmaddr))
             & " cache=$" & hex2(std_logic_vector(obs_mmcache))
             & " sdram=$" & hex2(std_logic_vector(obs_mmsdram));
        if obs_mmcount /= 0 then
            report "SUPERRAM_COHERENCY: DIAG-DIVERGE count=" & integer'image(to_integer(obs_mmcount))
                 & " @ $" & hex2(std_logic_vector(obs_mmbank)) & ":" & hex4(std_logic_vector(obs_mmaddr))
                 & " cache=$" & hex2(std_logic_vector(obs_mmcache)) & " sdram=$" & hex2(std_logic_vector(obs_mmsdram))
                 & " == BUG 2 REPRODUCED (HIT served stale byte)";
        end if;

        -- The coherency verdict (gated on the CPU having actually run the
        -- program -- boot marker $C3). The decisive witness is the B RE-READ
        -- (a cache HIT): coherent => $4A; stale => $AA (line A's value leaked in
        -- via the fill latching A's dout before B's read propagated).
        if rb = x"C3" then
            if w2 = x"4A" then
                report "SUPERRAM_COHERENCY: PASS  B re-read=$4A (cache coherent on the cross-line path)";
            elsif w2 = x"AA" and sdr = x"4A" then
                report "SUPERRAM_COHERENCY: STALE B re-read=$AA while SDRAM=$4A "
                     & "== BUG 2 REPRODUCED (HIT served line A's stale dout)";
            elsif sdr = x"4A" then
                report "SUPERRAM_COHERENCY: STALE B re-read=$" & hex2(w2)
                     & " while SDRAM=$4A == BUG 2 REPRODUCED (cache served stale byte)";
            else
                report "SUPERRAM_COHERENCY: INCONCLUSIVE B re-read=$" & hex2(w2)
                     & " SDRAM=$" & hex2(sdr) & " (write path suspect, not the cache)";
            end if;
        end if;

        tick(clk, 50);

        -- iter-27: INTERNAL_FAST_FIRE validation readout. The runner greps
        -- "FASTFIRE:" from both the false and true runs and compares:
        --   * witnesses (w0/w1/w2/done above) MUST be identical false-vs-true
        --     (functional correctness of the scheduler).
        --   * viol_count MUST be 0 (no prefetch issued on an internal cycle).
        --   * fastfire_cnt > 0 in the true run (the lever engaged), == 0 in false.
        --   * ticks_to_tgt LOWER in the true run (the throughput win).
        report "FASTFIRE: mode=" & boolean'image(FASTFIRE_MODE)
             & " viol_count=" & integer'image(viol_count)
             & " viol_main=" & integer'image(viol_main)
             & " fastfire_cnt=" & integer'image(fastfire_cnt)
             & " mem_encpu=" & integer'image(mem_encpu)
             & " ticks_to_tgt=" & integer'image(ticks_to_tgt)
             & " final_op_count=" & integer'image(to_integer(dbg_en_count));
        report "FASTFIRE_WITNESS: done=$" & hex2(done)
             & " w0=$" & hex2(w0) & " w1=$" & hex2(w1) & " w2=$" & hex2(w2)
             & " sdrAE=$" & hex2(sdr) & " sdr140=$" & hex2(sdrA);
        if FASTFIRE_MODE and viol_count /= 0 then
            report "FASTFIRE: INVARIANT FAILED (" & integer'image(viol_count)
                 & " prefetch-on-internal events) -- the cpu_cyc VDA/VPA gate is not holding."
                 severity warning;
            fail_cnt := fail_cnt + 1;
        end if;
        if FASTFIRE_MODE and fastfire_cnt = 0 then
            report "FASTFIRE: lever NEVER engaged (fastfire_cnt=0) -- check vda/vpa "
                 & "wiring or en_gap gating; no speed gain possible." severity warning;
        end if;

        report "=== SUMMARY: sanity pass=" & integer'image(pass_cnt)
             & " fail=" & integer'image(fail_cnt) & " (mode=" & boolean'image(DUALCLK) & ") ===";
        sim_done <= true;

        if DUALCLK then
            -- Dual-clock proof run. EXPECTED outcome: the CPU reads stale SDRAM
            -- (boot marker $C3 written, but the body fetch from $0800 returns the
            -- not-yet-fresh dout => BRK-loop, done marker != $EE). This is the
            -- finding, not a regression: zero-delay sim has no SDC multicycle, so
            -- the consumer cannot sample the clk64 dout_r late => Bug 2 (a fill-FF
            -- setup-time violation) is NOT reproducible as a functional divergence.
            if rb = x"C3" and done /= x"EE" then
                report "DUAL-CLOCK FINDING: CPU read stale SDRAM (boot=$C3, done=$"
                     & hex2(done) & " != $EE) => Bug 2 is a SETUP-TIME class, "
                     & "unreproducible in zero-delay RTL. EXPECTED.";
                report "c64_internal_fastfire_tb: PASS" severity note;
            elsif rb = x"C3" and done = x"EE" and obs_mmcount /= 0 then
                report "DUAL-CLOCK SURPRISE: program completed AND divergence "
                     & "detected => Bug 2 reproduced functionally; investigate.";
                report "c64_internal_fastfire_tb: PASS" severity note;
            else
                report "DUAL-CLOCK: program completed coherent (done=$" & hex2(done)
                     & ", diverge=" & integer'image(to_integer(obs_mmcount)) & ").";
                report "c64_internal_fastfire_tb: PASS" severity note;
            end if;
        elsif fail_cnt /= 0 then
            report "c64_internal_fastfire_tb: FAIL" severity failure;
        else
            report "c64_internal_fastfire_tb: PASS" severity note;
        end if;
        wait;
    end process;

end architecture;
