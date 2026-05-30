-- c64_reduced_harness_tb_mb.vhd
--
-- Milestone B system-level GHDL bench (2026-05-30). Derived from
-- c64_reduced_harness_tb_v2.vhd but with TWO key differences that finally
-- exercise the real 65C816 inside the real fpga64_sid_iec:
--
--   1. It DRIVES clk_cpu. The v2 bench left clk_cpu at its '0' default, so
--      cpu_65c816_inst (clk => clk_cpu, fpga64_sid_iec.vhd:3010) never
--      clocked — v2's 85/85 PASS was entirely the ioctl/SDRAM/arbiter
--      plumbing with a FROZEN CPU. This bench supplies clk_cpu so the CPU
--      actually runs.
--
--   2. It parameterises the MCP bridge via the new fpga64_sid_iec generic
--      SCPU_MCP_ACTIVE (threaded through c64_reduced_top_v2):
--        * MCP=0, RATIO=1  → passthrough, clk_cpu = clk32 (32 MHz). This is
--          the real-HW shipped config. Baseline "the CPU executes."
--        * MCP=1, RATIO=2  → Milestone B: clk_cpu = 64 MHz across the MCP
--          async bridge CDC. The historically-wedging configuration.
--
-- Run both and compare. If the MCP/64 run reaches the same KERNAL-execution
-- liveness as the passthrough/32 run, Milestone B is functionally sound at
-- the system level (the past E.1/F.1 wedges were integration/STA, not the
-- handshake). If MCP/64 wedges while passthrough runs, we've reproduced the
-- silicon wedge IN SIM — fixable with no FPGA build.
--
-- LIVENESS / CORRECTNESS criteria (the real CPU verification):
--   * en_count grows  — the CPU receives clock-enables AND its clk ticks.
--   * addr_activity    — dbg_addr changes on many clk32 edges (a wedged CPU
--                        freezes its bus address after the reset-vector
--                        fetch; a running KERNAL changes it constantly).
--   * max_pc reaches KERNAL ($E000+) — the reset vector dispatched into ROM.
--   * a scripted PRG load reads back coherently (memory path intact).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

use work.prg_loader_pkg.all;

entity c64_reduced_harness_tb_mb is
    generic (
        -- clk_cpu = RATIO * 32 MHz. 1 = matched (passthrough net). 2 = 64 MHz.
        RATIO : positive := 2;
        -- 0 = bridge passthrough, 1 = MCP async bridge active.
        MCP   : integer range 0 to 1 := 1;
        -- clk32 cycles to run the CPU after the ROM-load window.
        RUN_CYCLES : positive := 40000
    );
end entity;

architecture sim of c64_reduced_harness_tb_mb is

    constant CLK32_PERIOD : time := 31250 ps;          -- ~32 MHz
    constant CLKCPU_PERIOD : time := CLK32_PERIOD / RATIO;

    function to_sl(i : integer) return std_logic is
    begin
        if i = 0 then return '0'; else return '1'; end if;
    end function;
    constant MCP_SL : std_logic := to_sl(MCP);

    signal clk32   : std_logic := '0';
    signal clk_cpu : std_logic := '0';
    signal reset   : std_logic := '1';

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
    signal dbg_en_count: unsigned(31 downto 0);
    signal dbg_diag    : unsigned(7 downto 0);

    -- Loader status
    signal status_inj_busy   : std_logic;
    signal status_inj_end    : unsigned(15 downto 0);
    signal status_bram_inval : std_logic;
    signal status_rom_found  : std_logic;
    signal status_rom_src    : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;

    -- Liveness monitors (clk32 domain)
    signal addr_activity : unsigned(31 downto 0) := (others => '0');
    signal max_pc        : unsigned(15 downto 0) := (others => '0');
    signal mon_enable    : std_logic := '0';

    -- Scenario payload: tiny PRG at $0801 (same as v2)
    constant PRG_PAYLOAD : byte_array_t := (
        0  => x"0B", 1  => x"08",
        2  => x"0A", 3  => x"00",
        4  => x"9E",
        5  => x"32", 6  => x"30", 7  => x"36", 8  => x"31",
        9  => x"00",
        10 => x"00", 11 => x"00", 12 => x"00",
        13 => x"EA"
    );

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
        ioctl_wr <= '0'; ba := ba + 1;
        wait until rising_edge(clk);
        ioctl_addr <= ba; ioctl_data <= load_hi; ioctl_wr <= '1';
        wait until rising_edge(clk);
        ioctl_wr <= '0'; ba := ba + 1;
        for i in payload'range loop
            wait until rising_edge(clk);
            ioctl_addr <= ba; ioctl_data <= payload(i); ioctl_wr <= '1';
            wait until rising_edge(clk);
            ioctl_wr <= '0'; ba := ba + 1;
        end loop;
        wait until rising_edge(clk);
        ioctl_download <= '0';
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

    ------------------------------------------------------------------
    -- Clocks: clk32 and clk_cpu both start at t=0 → rising edges aligned
    -- (models a PLL-derived 2:1 relationship, same as cpu_in_bridge_tb).
    ------------------------------------------------------------------
    clk32   <= not clk32   after CLK32_PERIOD / 2 when not sim_done else '0';
    clk_cpu <= not clk_cpu after CLKCPU_PERIOD / 2 when not sim_done else '0';

    rstgen : process
    begin
        reset <= '1';
        wait for 16 * CLK32_PERIOD;
        wait until rising_edge(clk32);
        reset <= '0';
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT (Phase 4b top, now with clk_cpu + MCP generic threaded)
    ------------------------------------------------------------------
    dut : entity work.c64_reduced_top_v2
        generic map (
            SDRAM_BYTES     => 2 * 1024 * 1024,
            SCPU_MCP_ACTIVE => MCP_SL
        )
        port map (
            clk32             => clk32,
            clk_cpu           => clk_cpu,
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
            dbg_en_count      => dbg_en_count,
            dbg_diag_out      => dbg_diag,
            status_inj_busy   => status_inj_busy,
            status_inj_end    => status_inj_end,
            status_bram_inval => status_bram_inval,
            status_rom_found  => status_rom_found,
            status_rom_src    => status_rom_src
        );

    ------------------------------------------------------------------
    -- Liveness monitor: count clk32 edges where the CPU bus address moved,
    -- and track the max PC/addr observed. Enabled by mon_enable so the
    -- ROM-load window doesn't inflate the counts.
    ------------------------------------------------------------------
    monitor : process(clk32)
        variable prev_addr : unsigned(15 downto 0) := (others => '0');
    begin
        if rising_edge(clk32) then
            if mon_enable = '1' then
                if dbg_addr /= prev_addr then
                    addr_activity <= addr_activity + 1;
                end if;
                if dbg_addr > max_pc then
                    max_pc <= dbg_addr;
                end if;
            end if;
            prev_addr := dbg_addr;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Stimulus + verdict
    ------------------------------------------------------------------
    stim : process
        variable rb        : std_logic_vector(7 downto 0);
        variable en0, en1  : unsigned(31 downto 0);
        variable act       : unsigned(31 downto 0);
        variable mpc       : unsigned(15 downto 0);
        variable pass_cnt  : integer := 0;
        variable fail_cnt  : integer := 0;
        variable l         : line;
    begin
        report "==== Milestone B harness: RATIO=" & integer'image(RATIO)
               & " MCP=" & integer'image(MCP) & " ====";

        wait until reset = '0';
        -- ROM loader pushes 16 KB over c64rom_wr (~16k clk32). Wait it out.
        tick(clk32, 22_000);
        report "ROM status: found=" & std_logic'image(status_rom_found)
               & " src=$" & hex2(status_rom_src);

        -- Begin liveness window.
        en0 := dbg_en_count;
        mon_enable <= '1';
        tick(clk32, RUN_CYCLES);
        mon_enable <= '0';
        en1 := dbg_en_count;
        act := addr_activity;
        mpc := max_pc;

        report "LIVENESS: en_count " & integer'image(to_integer(en0))
               & " -> " & integer'image(to_integer(en1))
               & " (delta " & integer'image(to_integer(en1 - en0)) & ")";
        report "LIVENESS: addr_activity = " & integer'image(to_integer(act))
               & " over " & integer'image(RUN_CYCLES) & " clk32 cycles";
        report "LIVENESS: max_pc/addr observed = $" & hex4(std_logic_vector(mpc));
        report "LIVENESS: final dbg_addr=$" & hex4(std_logic_vector(dbg_addr))
               & " ir=$" & hex2(std_logic_vector(dbg_ir))
               & " pbr=$" & hex2(std_logic_vector(dbg_pbr))
               & " diag=$" & hex2(std_logic_vector(dbg_diag));

        -- Criterion 1: CPU getting clock-enables (not frozen).
        if (en1 - en0) > 100 then
            report "CHK1 en_count grew: PASS"; pass_cnt := pass_cnt + 1;
        else
            report "CHK1 en_count did NOT grow (CPU frozen): FAIL" severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- Criterion 2: bus address actively changing (not wedged in a tight
        -- loop / stuck at reset vector).
        if act > 500 then
            report "CHK2 addr_activity healthy: PASS"; pass_cnt := pass_cnt + 1;
        else
            report "CHK2 addr_activity too low (wedge): FAIL" severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- Criterion 3: PC reached KERNAL ROM ($E000+) — reset vector
        -- dispatched into the KERNAL, i.e. the CPU fetched + executed.
        if mpc >= x"E000" then
            report "CHK3 reached KERNAL ROM: PASS"; pass_cnt := pass_cnt + 1;
        else
            report "CHK3 never reached $E000 (no ROM dispatch): FAIL" severity warning;
            fail_cnt := fail_cnt + 1;
        end if;

        -- Criterion 4: memory path coherent — scripted PRG load + readback.
        report "==== PRG load + readback ($0801) ====";
        push_prg(clk32, ioctl_download, ioctl_wr, ioctl_addr, ioctl_data,
                 x"01", x"08", PRG_PAYLOAD);
        tick(clk32, 4);
        while status_inj_busy /= '0' loop
            wait until rising_edge(clk32);
        end loop;
        tick(clk32, 16);
        for i in PRG_PAYLOAD'range loop
            probe_byte(clk32, probe_addr, probe_data,
                       x"00" & (to_unsigned(16#0801#, 16) + to_unsigned(i, 16)), rb);
            if rb = PRG_PAYLOAD(i) then
                pass_cnt := pass_cnt + 1;
            else
                report "CHK4 payload[" & integer'image(i) & "] FAIL got $"
                       & hex2(rb) & " exp $" & hex2(PRG_PAYLOAD(i))
                       severity warning;
                fail_cnt := fail_cnt + 1;
            end if;
        end loop;
        report "CHK4 PRG readback done";

        -- ---- DIAGNOSTIC: sample internal fpga64_sid_iec signals --------
        report "DIAG reset_n(top)=" & std_logic'image(
                   << signal .c64_reduced_harness_tb_mb.dut.reset_n : std_logic >>)
             & " reset(fpga)=" & std_logic'image(
                   << signal .c64_reduced_harness_tb_mb.dut.dut.reset : std_logic >>)
             & " sysEnable=" & std_logic'image(
                   << signal .c64_reduced_harness_tb_mb.dut.dut.sysEnable : std_logic >>);
        report "DIAG enableCpu_816=" & std_logic'image(
                   << signal .c64_reduced_harness_tb_mb.dut.dut.enableCpu_816 : std_logic >>)
             & " baLoc=" & std_logic'image(
                   << signal .c64_reduced_harness_tb_mb.dut.dut.baLoc : std_logic >>)
             & " cpu816_en_to_cpu=" & std_logic'image(
                   << signal .c64_reduced_harness_tb_mb.dut.dut.cpu816_enable_to_cpu : std_logic >>)
             & " cpu816_rdy_to_cpu=" & std_logic'image(
                   << signal .c64_reduced_harness_tb_mb.dut.dut.cpu816_rdy_to_cpu : std_logic >>);

        report "==== SUMMARY: pass=" & integer'image(pass_cnt)
               & " fail=" & integer'image(fail_cnt) & " ====";
        sim_done <= true;
        if fail_cnt /= 0 then
            report "c64_reduced_harness_tb_mb: FAIL" severity failure;
        else
            report "c64_reduced_harness_tb_mb: PASS" severity note;
        end if;
        wait;
    end process;

end architecture;
