-- c64_cache_hitrate_tb.vhd
--
-- Read-only BRAM-cache HIT-RATE observer on the REAL boot access stream.
--
-- Purpose (2026-05-30, more-turbo iter-4): the SLOT3 / page-mode levers died
-- because synthetic access patterns over-promised; the durable lesson is to
-- measure against a REAL CPU instruction+data stream. This bench boots the
-- real fpga64_sid_iec (via c64_reduced_top_v2, same as _tb_v2) with real ROMs,
-- and uses VHDL-2008 external names to tap the live CPU memory-access stream
-- (cpuAddr / addr_hi_816 / cpuWe / cpuDi / enableCpu_816 / vda_816 / vpa_816).
-- It drives a REAL `cpu_cache` instance (the exact dead RTL, READ-ONLY:
-- cacheable_wr stays '0') as an OBSERVER — its cache_di/cache_hit are NOT fed
-- back to the CPU. We count, over the boot + run window, how many cacheable
-- READ accesses HIT vs MISS. That is the bank-$00 locality number that decides
-- whether reviving the read cache + a hit-shortens-cycle arbiter can beat the
-- ~4MHz cpuDi-mux-bound ceiling (see docs/session_handoff.md §NEXT LEVER).
--
-- NOTE: this harness has no SuperRAM/Doom code, so the stream is dominated by
-- bank-$00 KERNAL/BASIC/ZP/stack — exactly the CPU's "home" passthrough traffic
-- the cache would accelerate. SuperRAM (Doom) locality is a separate measurement
-- needing a Doom trace; this bench answers the bank-$00 half first.
--
-- Reuses _tb_v2's boot/ROM-load/PRG scaffolding verbatim; the only additions are
-- the cache observer, the external-name taps, and the hit-rate report.
--
-- Exit code 0 = PASS (always; this is a measurement, not a pass/fail gate). The
-- headline numbers are in the "CACHE_HITRATE" report lines.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

use work.prg_loader_pkg.all;

entity c64_cache_hitrate_tb is
end entity;

architecture sim of c64_cache_hitrate_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- ~32 MHz

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- ioctl pseudo-interface
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

    -- Loader status
    signal status_inj_busy   : std_logic;
    signal status_inj_end    : unsigned(15 downto 0);
    signal status_bram_inval : std_logic;
    signal status_rom_found  : std_logic;
    signal status_rom_src    : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;

    ------------------------------------------------------------------
    -- Cache observer wiring (driven from registered external-name taps)
    ------------------------------------------------------------------
    signal tap_addr   : unsigned(15 downto 0) := (others => '0');
    signal tap_bank   : unsigned(7 downto 0)  := (others => '0');
    signal tap_we     : std_logic := '0';
    signal tap_di     : unsigned(7 downto 0)  := (others => '0');
    signal tap_do     : unsigned(7 downto 0)  := (others => '0');
    signal tap_en     : std_logic := '0';  -- enableCpu_816 (1-cyc CPU step), registered
    signal tap_valid  : std_logic := '0';  -- (vda_816 or vpa_816), registered

    signal cache_di      : unsigned(7 downto 0);
    signal cache_hit     : std_logic;
    signal cache_fill_we : std_logic := '0';
    signal cacheable     : std_logic := '0';
    signal access_eval   : std_logic := '0';  -- this clk: a cacheable READ step to count

    -- hit-rate accumulators (read at sim end)
    signal acc_reads   : integer := 0;  -- cacheable read accesses evaluated
    signal acc_hits    : integer := 0;  -- of those, cache HIT
    signal acc_zp      : integer := 0;  -- subset: addr < $0200 (ZP+stack)
    signal acc_zp_hits : integer := 0;
    -- coverage diagnostics: is the execution representative or a tight loop?
    signal acc_allreads : integer := 0;  -- ALL read steps (incl non-cacheable)
    signal acc_nonzp    : integer := 0;  -- cacheable reads with addr >= $0200
    signal acc_banknz   : integer := 0;  -- cacheable reads with bank /= $00
    signal max_addr     : unsigned(15 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- Helpers (verbatim from _tb_v2)
    ------------------------------------------------------------------
    procedure tick(signal clk : std_logic; n : natural) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

    procedure push_prg(
        signal clk            : in    std_logic;
        signal ioctl_download : out   std_logic;
        signal ioctl_wr       : out   std_logic;
        signal ioctl_addr     : out   unsigned(15 downto 0);
        signal ioctl_data     : out   std_logic_vector(7 downto 0);
        constant load_lo      : in    std_logic_vector(7 downto 0);
        constant load_hi      : in    std_logic_vector(7 downto 0);
        constant payload      : in    byte_array_t
    ) is
        variable ba : unsigned(15 downto 0) := (others => '0');
    begin
        ioctl_download <= '1';
        wait until rising_edge(clk);
        ioctl_addr <= ba; ioctl_data <= load_lo; ioctl_wr <= '1';
        wait until rising_edge(clk);
        ioctl_wr <= '0'; wait until rising_edge(clk); ba := ba + 1;
        ioctl_addr <= ba; ioctl_data <= load_hi; ioctl_wr <= '1';
        wait until rising_edge(clk);
        ioctl_wr <= '0'; wait until rising_edge(clk); ba := ba + 1;
        for i in payload'range loop
            ioctl_addr <= ba; ioctl_data <= payload(i); ioctl_wr <= '1';
            wait until rising_edge(clk);
            ioctl_wr <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            ba := ba + 1;
        end loop;
        ioctl_download <= '0';
    end procedure;

    constant PRG_PAYLOAD : byte_array_t := (
        0  => x"0B", 1  => x"08", 2  => x"0A", 3  => x"00", 4  => x"9E",
        5  => x"32", 6  => x"30", 7  => x"36", 8  => x"31", 9  => x"00",
        10 => x"00", 11 => x"00", 12 => x"00", 13 => x"EA"
    );

begin

    ------------------------------------------------------------------
    -- Clock + reset
    ------------------------------------------------------------------
    clkgen : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
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
    -- DUT (real fpga64_sid_iec via the Phase 4b top)
    ------------------------------------------------------------------
    dut : entity work.c64_reduced_top_v2
        generic map ( SDRAM_BYTES => 2 * 1024 * 1024 )  -- SCPU_MCP_ACTIVE='0' (passthrough)
        port map (
            clk32             => clk,
            clk_cpu           => clk,   -- passthrough RATIO=1: CPU clock = clk32. MUST be
                                        -- driven — the v2 default '0' freezes the CPU at $0000.
            reset             => reset,
            ioctl_download    => ioctl_download,
            ioctl_wr          => ioctl_wr,
            ioctl_addr        => ioctl_addr,
            ioctl_data        => ioctl_data,
            ioctl_index       => ioctl_index,
            probe_addr        => probe_addr,
            probe_data        => probe_data,
            dbg_pc            => dbg_pc,
            dbg_pbr           => dbg_pbr,
            dbg_p             => dbg_p,
            dbg_ir            => dbg_ir,
            dbg_addr          => dbg_addr,
            dbg_data_in       => dbg_data_in,
            dbg_we            => dbg_we,
            status_inj_busy   => status_inj_busy,
            status_inj_end    => status_inj_end,
            status_bram_inval => status_bram_inval,
            status_rom_found  => status_rom_found,
            status_rom_src    => status_rom_src
        );

    ------------------------------------------------------------------
    -- External-name TAP process: copy live fpga64_sid_iec internal CPU
    -- access signals into local tb signals (registered, 1-clk uniform
    -- delay — internally consistent for hit-rate). External names must be
    -- declared in a process declarative region (the dut hierarchy is not
    -- elaborated at architecture-declaration time). Hierarchy:
    --   c64_cache_hitrate_tb -> dut (c64_reduced_top_v2) -> dut (fpga64_sid_iec)
    ------------------------------------------------------------------
    tap_proc : process(clk)
        alias ext_cpuAddr is
            << signal .c64_cache_hitrate_tb.dut.dut.cpuAddr : unsigned(15 downto 0) >>;
        alias ext_bank is
            << signal .c64_cache_hitrate_tb.dut.dut.addr_hi_816 : unsigned(7 downto 0) >>;
        alias ext_cpuWe is
            << signal .c64_cache_hitrate_tb.dut.dut.cpuWe : std_logic >>;
        alias ext_cpuDi is
            << signal .c64_cache_hitrate_tb.dut.dut.cpuDi : unsigned(7 downto 0) >>;
        alias ext_cpuDo is
            << signal .c64_cache_hitrate_tb.dut.dut.cpuDo : unsigned(7 downto 0) >>;
        alias ext_en is
            << signal .c64_cache_hitrate_tb.dut.dut.enableCpu_816 : std_logic >>;
        alias ext_vda is
            << signal .c64_cache_hitrate_tb.dut.dut.vda_816 : std_logic >>;
        alias ext_vpa is
            << signal .c64_cache_hitrate_tb.dut.dut.vpa_816 : std_logic >>;
    begin
        if rising_edge(clk) then
            tap_addr  <= ext_cpuAddr;
            tap_bank  <= ext_bank;
            tap_we    <= ext_cpuWe;
            tap_di    <= ext_cpuDi;
            tap_do    <= ext_cpuDo;
            tap_en    <= ext_en;
            tap_valid <= ext_vda or ext_vpa;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Cacheability (mirror cpu_cache.vhd:188 cacheable_addr): bank $00
    -- except $D000-$DFFF, or banks $01-$EF (SuperRAM).
    ------------------------------------------------------------------
    cacheable <= '1' when (tap_bank = x"00" and tap_addr(15 downto 12) /= x"D")
                       or (tap_bank > x"00" and tap_bank < x"F0")
                 else '0';

    -- A cacheable READ step this clk = count it + (opportunistically) fill it.
    access_eval   <= tap_en and tap_valid and (not tap_we) and cacheable;
    cache_fill_we <= access_eval;  -- fill the line with the data the CPU just read

    ------------------------------------------------------------------
    -- REAL cpu_cache as a READ-ONLY observer. cacheable_wr is hard '0'
    -- inside the RTL (write hits disabled), and wb_enable='0' here too, so
    -- no write-path / drain behavior is exercised. cache_di/cache_hit are
    -- observed, NOT fed to the CPU.
    ------------------------------------------------------------------
    cache : entity work.cpu_cache
        port map (
            clk        => clk,
            reset      => reset,
            enable     => '1',
            cpu_addr   => tap_addr,
            cpu_bank   => tap_bank,
            cpu_we     => tap_we,
            cpu_do     => tap_do,
            cache_di   => cache_di,
            cache_hit  => cache_hit,
            fill_data  => tap_di,
            fill_we    => cache_fill_we,
            fill_addr  => tap_addr,
            fill_bank  => tap_bank,
            wb_pending => open,
            wb_addr    => open,
            wb_data    => open,
            wb_ack     => '0',
            flush      => '0',
            cpu_en     => tap_en,
            wb_enable  => '0',
            same_line  => open,
            dbg_flush_active => open,
            dbg_tag_match    => open
        );

    ------------------------------------------------------------------
    -- Hit-rate counter. On each cacheable READ step, cache_hit is
    -- combinational against the tag/valid state built by PRIOR fills
    -- (first touch of a byte = MISS; the fill lands this clk; repeats HIT).
    ------------------------------------------------------------------
    count_proc : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' and tap_en = '1' and tap_valid = '1' and tap_we = '0' then
                acc_allreads <= acc_allreads + 1;
            end if;
            if reset = '0' and access_eval = '1' then
                acc_reads <= acc_reads + 1;
                if cache_hit = '1' then
                    acc_hits <= acc_hits + 1;
                end if;
                if tap_addr > max_addr and tap_bank = x"00" then
                    max_addr <= tap_addr;
                end if;
                if tap_bank = x"00" and tap_addr < x"0200" then
                    acc_zp <= acc_zp + 1;
                    if cache_hit = '1' then
                        acc_zp_hits <= acc_zp_hits + 1;
                    end if;
                else
                    acc_nonzp <= acc_nonzp + 1;
                end if;
                if tap_bank /= x"00" then
                    acc_banknz <= acc_banknz + 1;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Access-stream trace dumper. One line per CPU memory-access step
    -- (read OR write, so the replay model can apply invalidate-on-write):
    --     <we> <bank_hex2> <addr_hex4>
    -- Consumed by tools/cache_replay.py for geometry sweeps + cross-check,
    -- and the same format a future HW {bank,addr,we} UART trace will use.
    -- Bounded so the file stays manageable.
    ------------------------------------------------------------------
    trace_dump : process(clk)
        file f        : text;
        variable L    : line;
        variable opened : boolean := false;
        variable n      : integer := 0;
        constant TRACE_MAX : integer := 200000;
    begin
        if rising_edge(clk) then
            if not opened then
                file_open(f, "access_trace.txt", write_mode);
                write(L, string'("# we bank addr  (CPU mem-access steps; reduced_harness KERNAL stream)"));
                writeline(f, L);
                opened := true;
            end if;
            if reset = '0' and tap_en = '1' and tap_valid = '1' and n < TRACE_MAX then
                write(L, std_logic'image(tap_we)(2));  -- '0' or '1' char
                write(L, string'(" "));
                write(L, to_hstring(std_logic_vector(tap_bank)));
                write(L, string'(" "));
                write(L, to_hstring(std_logic_vector(tap_addr)));
                writeline(f, L);
                n := n + 1;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Stimulus: boot the core with real ROMs, load a PRG, then run a long
    -- execution window so the cache observer sees a substantial real stream.
    ------------------------------------------------------------------
    stim : process
        variable hr_x100, zp_x100 : integer;
    begin
        wait until reset = '0';
        tick(clk, 20_000);  -- ROM-load window
        report "==== ROM status: found=" & std_logic'image(status_rom_found)
                & " src=$" & hex2(status_rom_src);

        -- warm-up run
        tick(clk, 5_000);

        -- load a tiny PRG (exercises ioctl + RAM writes; harmless to cache)
        push_prg(clk, ioctl_download, ioctl_wr, ioctl_addr, ioctl_data,
                 x"01", x"08", PRG_PAYLOAD);
        tick(clk, 4);
        while status_inj_busy /= '0' loop
            wait until rising_edge(clk);
        end loop;

        -- long execution window: this is where most of the access stream
        -- accrues (real KERNAL/BASIC fetch + ZP/stack data traffic).
        report "==== Running 200,000-cycle execution window for hit-rate ====";
        tick(clk, 200_000);

        -- report
        if acc_reads > 0 then
            hr_x100 := (acc_hits * 10000) / acc_reads;
        else
            hr_x100 := 0;
        end if;
        if acc_zp > 0 then
            zp_x100 := (acc_zp_hits * 10000) / acc_zp;
        else
            zp_x100 := 0;
        end if;

        report "==== CACHE_HITRATE (read-only observer, real boot stream) ====";
        report "CACHE_HITRATE total_cacheable_reads=" & integer'image(acc_reads)
               & " hits=" & integer'image(acc_hits);
        report "CACHE_HITRATE overall_hit_pct=" & integer'image(hr_x100 / 100)
               & "." & integer'image(hr_x100 mod 100) & "%";
        report "CACHE_HITRATE zp_stack_reads=" & integer'image(acc_zp)
               & " zp_stack_hits=" & integer'image(acc_zp_hits)
               & " zp_stack_hit_pct=" & integer'image(zp_x100 / 100)
               & "." & integer'image(zp_x100 mod 100) & "%";
        report "CACHE_COVERAGE all_read_steps=" & integer'image(acc_allreads)
               & " nonzp_cacheable_reads=" & integer'image(acc_nonzp)
               & " banknz_reads=" & integer'image(acc_banknz)
               & " max_bank0_addr=$" & hex4(std_logic_vector(max_addr))
               & " final_pc=$" & hex2(std_logic_vector(dbg_pbr))
               & ":" & hex4(std_logic_vector(dbg_pc));

        sim_done <= true;
        report "c64_cache_hitrate_tb: DONE" severity note;
        wait;
    end process;

end architecture;
