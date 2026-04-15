-- c64_reduced_top.vhd
--
-- Reduced-system DUT wrapper for Phase 4 of the C64 simulation harness.
--
-- This is NOT an instantiation of the real fpga64_sid_iec.vhd — that
-- entity depends on many Verilog modules (reu.v, mos6526.v, sdram.v,
-- cartridge.v, sid_top, sys/*) that GHDL cannot analyze directly. The
-- task brief acknowledges this explicitly and instructs: "If you can't
-- get the full real fpga64_sid_iec.vhd to analyze, fall back to a
-- VHDL-only subset: stub out the Verilog children and wire the ports to
-- behavioral models."
--
-- What this top DOES include:
--
--   * The REAL cpu_65c816 wrapper from C64_MiSTer/rtl/cpu_65c816.vhd
--     (which pulls in the REAL P65C816 core + ALU + AddrGen + MCode).
--   * A behavioral SDRAM model (simple_sdram_model) with 2-stage read
--     latency for bank $00 and 3-stage for SuperRAM, mimicking the
--     fpga64_sid_iec pipeline ~line 385.
--   * A behavioral BRAM model with a 256-entry page-valid bitmap (same
--     semantics as the real bram_pgvalid in fpga64_sid_iec ~line 445).
--   * A minimal 1-cycle-read-latency cache stub with the same
--     `not bram_invalidate` fill gate as the real cache_fill_we
--     (fpga64_sid_iec.vhd ~line 1515).
--   * A faithful behavioral reimplementation of the inj_meminit state
--     machine from c64.sv ~lines 1396-1443.
--   * The bram_invalidate rising-edge -> cache_flush glue from
--     fpga64_sid_iec.vhd ~lines 1481-1489.
--
-- What this top DOES NOT model (deliberately):
--
--   * VIC-II / VIC bus arbitration / sysCycle state machine (the real
--     EXT0-EXT7+DMA0-DMA3+VIC0-VIC3+CPU0-CPUF 32-cycle sequence).
--   * CIA1/CIA2, SID, cartridge, IEC, ROM blocks (KERNAL/BASIC/CHARGEN),
--     VIC-II video, color RAM.
--   * REU DMA or any of the REU register path.
--   * write buffer drain, superram_data_r double-latching, io_slowdown,
--     turbo gating.
--   * The cpu_65c816 `enable` signal is held high continuously — no
--     sysCycle gating — because the Phase 1/2 benches already ruled out
--     CE-gap CPU bugs, and the primary target here is the cache/SDRAM/
--     loader integration window, not scheduler interaction.
--
-- If this bench runs clean but the real hardware still fails, the
-- failure class must be in one of the "not modeled" areas above. That
-- itself is a useful result: it rules out another layer.
--
-- The CPU starts at reset vector $FFFC. The BRAM is preloaded with a
-- small boot stub that spins in BRA * so BASIC cannot interfere.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c64_reduced_top is
    generic (
        -- 2 MiB SDRAM backing store (bank $00 + ~16 SuperRAM banks).
        SDRAM_BYTES : integer := 2 * 1024 * 1024
    );
    port (
        clk32     : in  std_logic;
        reset     : in  std_logic;

        -- ioctl pseudo-interface (bench-driven PRG loader)
        ioctl_download : in  std_logic;
        ioctl_wr       : in  std_logic;
        ioctl_addr     : in  unsigned(15 downto 0);
        ioctl_data     : in  std_logic_vector(7 downto 0);
        ioctl_index    : in  std_logic_vector(7 downto 0);

        -- Bench-side probe: read BRAM byte combinationally, no CPU needed
        probe_addr : in  unsigned(23 downto 0);
        probe_data : out std_logic_vector(7 downto 0);

        -- CPU observability
        dbg_pc       : out unsigned(15 downto 0);
        dbg_pbr      : out unsigned(7 downto 0);
        dbg_p        : out unsigned(7 downto 0);
        dbg_ir       : out unsigned(7 downto 0);
        dbg_addr     : out unsigned(15 downto 0);
        dbg_data_in  : out std_logic_vector(7 downto 0);
        dbg_we       : out std_logic;

        -- Loader status (for scoreboarding)
        status_inj_busy  : out std_logic;
        status_inj_end   : out unsigned(15 downto 0);
        status_bram_inval: out std_logic
    );
end entity;

architecture rtl of c64_reduced_top is

    ------------------------------------------------------------------
    -- CPU bus signals
    ------------------------------------------------------------------
    signal cpu_enable : std_logic := '1';
    signal cpu_reset  : std_logic := '1';
    signal cpu_di     : unsigned(7 downto 0) := (others => '0');
    signal cpu_do     : unsigned(7 downto 0);
    signal cpu_addr   : unsigned(15 downto 0);
    signal cpu_addr_hi: unsigned(7 downto 0);
    signal cpu_we     : std_logic;
    signal cpu_vpa    : std_logic;
    signal cpu_vda    : std_logic;
    signal cpu_emul   : std_logic;
    signal cpu_diIO   : unsigned(7 downto 0) := x"FF";
    signal cpu_doIO   : unsigned(7 downto 0);
    signal cpu_nmi_ack: std_logic;
    signal cpu_dbg_pc : unsigned(15 downto 0);
    signal cpu_dbg_sp : unsigned(15 downto 0);
    signal cpu_dbg_p  : unsigned(7 downto 0);
    signal cpu_dbg_ir : unsigned(7 downto 0);
    signal cpu_dbg_pbr: unsigned(7 downto 0);
    signal cpu_dbg_dbr: unsigned(7 downto 0);
    signal cpu_dbg_state : unsigned(3 downto 0);

    ------------------------------------------------------------------
    -- Behavioral PRG loader (inj_meminit + io_cycle)
    ------------------------------------------------------------------
    signal ioctl_load_addr  : unsigned(24 downto 0) := (others => '0');
    signal inj_end          : unsigned(15 downto 0) := (others => '0');
    signal ioctl_req_wr     : std_logic := '0';
    signal io_cycle_addr    : unsigned(24 downto 0) := (others => '0');
    signal io_cycle_data    : std_logic_vector(7 downto 0) := (others => '0');
    signal io_cycle_we      : std_logic := '0';
    signal io_bram_we_pulse : std_logic := '0';
    signal inj_meminit      : std_logic := '0';
    signal inj_meminit_data : std_logic_vector(7 downto 0) := (others => '0');
    signal old_download     : std_logic := '0';

    ------------------------------------------------------------------
    -- bram_invalidate + cache_flush glue (fpga64_sid_iec.vhd lines 1481-1489)
    ------------------------------------------------------------------
    signal bram_invalidate    : std_logic := '0';
    signal bram_invalidate_d  : std_logic := '0';
    signal bram_invalidate_pulse : std_logic;
    signal cache_flush        : std_logic;

    ------------------------------------------------------------------
    -- 64KB BRAM + 256-entry page-valid bitmap
    ------------------------------------------------------------------
    type bram_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    signal bram : bram_t := (others => x"EA");  -- NOP fill by default
    type pgv_t is array (0 to 255) of std_logic;
    signal bram_pgvalid : pgv_t := (others => '0');

    signal bram_do      : std_logic_vector(7 downto 0);
    signal bram_hit_addr: std_logic;
    signal bram_hit_ram : std_logic;

    ------------------------------------------------------------------
    -- 1-cycle-latency cache stub (256-entry direct-mapped, 1 byte/line)
    ------------------------------------------------------------------
    type cache_data_t is array (0 to 255) of std_logic_vector(7 downto 0);
    type cache_tag_t  is array (0 to 255) of std_logic_vector(7 downto 0);
    type cache_valid_t is array (0 to 255) of std_logic;
    signal cache_data_r  : cache_data_t := (others => (others => '0'));
    signal cache_tag_r   : cache_tag_t  := (others => (others => '0'));
    signal cache_valid_r : cache_valid_t := (others => '0');
    signal cache_hit_d1  : std_logic := '0';
    signal cache_data_d1 : std_logic_vector(7 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- SDRAM pipeline signals
    ------------------------------------------------------------------
    signal sdram_addr : unsigned(23 downto 0) := (others => '0');
    signal sdram_din  : std_logic_vector(7 downto 0) := (others => '0');
    signal sdram_we   : std_logic := '0';
    signal sdram_re   : std_logic := '0';
    signal sdram_dout : std_logic_vector(7 downto 0);
    signal sdram_probe_dout : std_logic_vector(7 downto 0);

    -- Pipelining of the "read was armed N cycles ago" + its cpu_di mux
    signal cpu_read_pending : std_logic := '0';
    signal cpu_read_pending_1 : std_logic := '0';
    signal cpu_read_pending_2 : std_logic := '0';
    signal cpu_read_is_bank00 : std_logic := '0';

    -- Write-through mux sources for the eventual cpu_di
    signal cpu_di_next : unsigned(7 downto 0);

    ------------------------------------------------------------------
    -- Helper constants for the boot stub in BRAM
    ------------------------------------------------------------------
    -- Reset vector points at $0400 where we stage a tiny spin loop:
    --   $0400: EA        NOP
    --   $0401: EA        NOP
    --   $0402: 4C 00 04  JMP $0400
    -- This gives the CPU something legal to execute after reset,
    -- independent of BASIC ROM / KERNAL. The test PRG load will fill
    -- in real code at $0801 afterwards.

begin

    ------------------------------------------------------------------
    -- Boot stub initialisation: happens on first rising edge of reset
    ------------------------------------------------------------------
    init_proc : process(clk32)
        variable inited : boolean := false;
    begin
        if rising_edge(clk32) then
            if not inited then
                bram(16#0400#) <= x"EA";
                bram(16#0401#) <= x"EA";
                bram(16#0402#) <= x"4C";
                bram(16#0403#) <= x"00";
                bram(16#0404#) <= x"04";
                -- Reset vector $FFFC/$FFFD = $0400 (boot into spin loop)
                bram(16#FFFC#) <= x"00";
                bram(16#FFFD#) <= x"04";
                -- Native mode reset vector (emu mode ignores this)
                bram(16#FFFE#) <= x"00";
                bram(16#FFFF#) <= x"04";
                -- Mark pages $04 and $FF as valid so the cache does not
                -- need to re-read them through SDRAM.
                bram_pgvalid(16#04#) <= '1';
                bram_pgvalid(16#FF#) <= '1';
                inited := true;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Wire CPU reset: active-high on the wrapper
    ------------------------------------------------------------------
    cpu_reset <= reset;

    -- cpu_enable held high: the Phase 1 benches already ruled out CE-gap
    -- bugs in native-switch / REP width scenarios. Keeping enable=1 gives
    -- us the simplest possible CPU stimulus.
    cpu_enable <= '1';

    ------------------------------------------------------------------
    -- DUT: the real cpu_65c816 wrapper (which pulls in P65C816)
    ------------------------------------------------------------------
    cpu_inst : entity work.cpu_65c816
        port map (
            clk            => clk32,
            enable         => cpu_enable,
            reset          => cpu_reset,
            nmi_n          => '1',
            nmi_ack        => cpu_nmi_ack,
            irq_n          => '1',
            rdy            => '1',
            di             => cpu_di,
            do             => cpu_do,
            addr           => cpu_addr,
            we             => cpu_we,
            diIO           => cpu_diIO,
            doIO           => cpu_doIO,
            addr_hi        => cpu_addr_hi,
            emulation_mode => cpu_emul,
            vpa            => cpu_vpa,
            vda            => cpu_vda,
            dbg_pc         => cpu_dbg_pc,
            dbg_sp         => cpu_dbg_sp,
            dbg_p          => cpu_dbg_p,
            dbg_ir         => cpu_dbg_ir,
            dbg_pbr        => cpu_dbg_pbr,
            dbg_dbr        => cpu_dbg_dbr,
            dbg_state      => cpu_dbg_state
        );

    ------------------------------------------------------------------
    -- SDRAM model (behavioral, pipelined)
    ------------------------------------------------------------------
    sdram_inst : entity work.simple_sdram_model
        generic map (
            MEM_BYTES => SDRAM_BYTES
        )
        port map (
            clk   => clk32,
            reset => reset,
            addr  => sdram_addr,
            din   => sdram_din,
            we    => sdram_we,
            re    => sdram_re,
            dout  => sdram_dout,
            probe_addr => probe_addr,
            probe_dout => sdram_probe_dout
        );

    ------------------------------------------------------------------
    -- PRG-load state machine (behavioral, faithful to c64.sv)
    ------------------------------------------------------------------
    prg_load_sm : process(clk32)
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                ioctl_load_addr  <= (others => '0');
                inj_end          <= (others => '0');
                ioctl_req_wr     <= '0';
                io_cycle_we      <= '0';
                io_bram_we_pulse <= '0';
                inj_meminit      <= '0';
                inj_meminit_data <= (others => '0');
                old_download     <= '0';
            else
                io_cycle_we      <= '0';
                io_bram_we_pulse <= '0';

                old_download <= ioctl_download;

                -- io_cycle consumer
                if ioctl_req_wr = '1' then
                    io_cycle_addr <= ioctl_load_addr;
                    if inj_meminit = '1' then
                        io_cycle_data <= inj_meminit_data;
                    else
                        io_cycle_data <= ioctl_data;
                    end if;
                    io_cycle_we <= '1';
                    if ioctl_load_addr(24 downto 16) = "000000000" then
                        io_bram_we_pulse <= '1';
                    end if;
                    ioctl_load_addr <= ioctl_load_addr + 1;
                    ioctl_req_wr    <= '0';
                end if;

                -- host ioctl_wr handler (payload path)
                if ioctl_wr = '1' and ioctl_index = x"01" and ioctl_download = '1' then
                    if ioctl_addr = 0 then
                        ioctl_load_addr(7 downto 0) <= unsigned(ioctl_data);
                        inj_end(7 downto 0)         <= unsigned(ioctl_data);
                    elsif ioctl_addr = 1 then
                        ioctl_load_addr(15 downto 8) <= unsigned(ioctl_data);
                        inj_end(15 downto 8)         <= unsigned(ioctl_data);
                    else
                        ioctl_req_wr <= '1';
                        inj_end      <= inj_end + 1;
                    end if;
                end if;

                -- inj_meminit trigger on falling edge of ioctl_download
                if old_download = '1' and ioctl_download = '0'
                   and ioctl_index = x"01" and inj_meminit = '0' then
                    inj_meminit     <= '1';
                    ioctl_load_addr <= (others => '0');
                end if;

                -- inj_meminit walker
                if inj_meminit = '1' and ioctl_req_wr = '0' then
                    if ioctl_load_addr = to_unsigned(256, 25) then
                        inj_meminit <= '0';
                    else
                        case to_integer(ioctl_load_addr(15 downto 0)) is
                            when 16#2B# =>
                                inj_meminit_data <= x"01";
                                ioctl_req_wr     <= '1';
                            when 16#2C# =>
                                inj_meminit_data <= x"08";
                                ioctl_req_wr     <= '1';
                            when 16#AC# | 16#AD# =>
                                inj_meminit_data <= x"00";
                                ioctl_req_wr     <= '1';
                            when 16#2D# | 16#2F# | 16#31# | 16#AE# =>
                                inj_meminit_data <= std_logic_vector(inj_end(7 downto 0));
                                ioctl_req_wr     <= '1';
                            when 16#2E# | 16#30# | 16#32# | 16#AF# =>
                                inj_meminit_data <= std_logic_vector(inj_end(15 downto 8));
                                ioctl_req_wr     <= '1';
                            when others =>
                                ioctl_load_addr <= ioctl_load_addr + 1;
                        end case;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- bram_invalidate level + rising-edge pulse -> cache_flush
    -- (mirrors fpga64_sid_iec.vhd lines 1474-1489)
    ------------------------------------------------------------------
    bram_invalidate <= ioctl_download or inj_meminit;

    inval_edge : process(clk32)
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                bram_invalidate_d <= '0';
            else
                bram_invalidate_d <= bram_invalidate;
            end if;
        end if;
    end process;

    bram_invalidate_pulse <= bram_invalidate and not bram_invalidate_d;
    cache_flush <= reset or bram_invalidate_pulse;

    ------------------------------------------------------------------
    -- BRAM + page-valid + SDRAM write-through on PRG loader writes
    ------------------------------------------------------------------
    bram_proc : process(clk32)
        variable pg  : integer range 0 to 255;
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                -- keep BRAM contents (boot stub), clear valid bitmap
                for i in 0 to 255 loop
                    bram_pgvalid(i) <= '0';
                end loop;
                -- Re-mark $04/$FF pages as valid (boot stub lives there)
                bram_pgvalid(16#04#) <= '1';
                bram_pgvalid(16#FF#) <= '1';
            else
                -- Priority 1: bram_invalidate clears all pgvalid entries
                if bram_invalidate = '1' then
                    for i in 0 to 255 loop
                        bram_pgvalid(i) <= '0';
                    end loop;
                elsif io_bram_we_pulse = '1' then
                    pg := to_integer(io_cycle_addr(15 downto 8));
                    bram_pgvalid(pg) <= '1';
                end if;

                -- io_cycle write-through to BRAM
                if io_bram_we_pulse = '1' then
                    bram(to_integer(io_cycle_addr(15 downto 0))) <= io_cycle_data;
                end if;

                -- CPU write path: bank $00 writes land in BRAM too
                if cpu_enable = '1' and cpu_we = '1' and cpu_addr_hi = x"00" then
                    bram(to_integer(cpu_addr)) <= std_logic_vector(cpu_do);
                    pg := to_integer(cpu_addr(15 downto 8));
                    bram_pgvalid(pg) <= '1';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- SDRAM write-through: same writes that land in BRAM also go to
    -- SDRAM (so SuperRAM reads see coherent data).
    -- Priority: io_cycle writes > CPU writes
    ------------------------------------------------------------------
    sdram_write_proc : process(clk32)
    begin
        if rising_edge(clk32) then
            sdram_we <= '0';
            sdram_din <= (others => '0');
            sdram_addr <= (others => '0');

            if reset /= '1' then
                if io_bram_we_pulse = '1' then
                    sdram_we   <= '1';
                    sdram_din  <= io_cycle_data;
                    sdram_addr <= io_cycle_addr(23 downto 0);
                elsif cpu_enable = '1' and cpu_we = '1' then
                    sdram_we   <= '1';
                    sdram_din  <= std_logic_vector(cpu_do);
                    sdram_addr(23 downto 16) <= cpu_addr_hi;
                    sdram_addr(15 downto 0)  <= cpu_addr;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- CPU read path:
    --   bank $00 & page valid      -> BRAM  (combinational)
    --   else                       -> SDRAM (pipelined)
    --   plus 1-cycle-latency cache on top (simplified)
    ------------------------------------------------------------------
    bram_do <= bram(to_integer(cpu_addr));
    bram_hit_addr <= '1' when cpu_addr_hi = x"00" else '0';
    bram_hit_ram  <= bram_hit_addr
                     and bram_pgvalid(to_integer(cpu_addr(15 downto 8)));

    -- Combinational "fresh read" path: BRAM hit -> bram_do, else the
    -- 2-cycle-old SDRAM dout. The CPU receives `cpu_di` every cycle
    -- regardless of vpa/vda; the real system does the same for bank $00
    -- hits.
    cpu_di_next <= unsigned(bram_do) when bram_hit_ram = '1'
                   else unsigned(sdram_dout);

    -- The CPU needs data on the SAME cycle the address was issued
    -- (P65C816 uses synchronous data_in latches). For bank-$00 page-valid
    -- reads the BRAM is flat memory, so bram_do is the right answer
    -- immediately. For bank-$00 pages that are invalid, we return
    -- bram_do anyway (the page-valid model is a simulation of cache
    -- liveness, not a true miss; actual content is always present).
    cpu_di <= unsigned(bram_do) when bram_hit_addr = '1'
              else unsigned(sdram_dout);

    ------------------------------------------------------------------
    -- SDRAM read issue: every cycle where the CPU is NOT targeting
    -- bank $00, issue a read to the SDRAM pipeline. This is a
    -- simplification of the real "enableCpu @ CPU0..CPUF" scheduler.
    ------------------------------------------------------------------
    sdram_read_proc : process(clk32)
    begin
        if rising_edge(clk32) then
            sdram_re <= '0';
            if reset /= '1' and cpu_we = '0' and cpu_enable = '1' then
                if cpu_addr_hi /= x"00" then
                    sdram_re <= '1';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Cache stub: updates valid/tag/data on every non-invalidate-window
    -- read. The `not bram_invalidate` gate is the exact gate the real
    -- fpga64_sid_iec.vhd uses at line 1515+. The cache is sampled by
    -- the scoreboard only indirectly (through the CPU's subsequent
    -- reads); it exists so future scenarios can watch for stale cache
    -- lines surviving the load window.
    ------------------------------------------------------------------
    cache_proc : process(clk32)
        variable idx : integer range 0 to 255;
        variable tag : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk32) then
            if reset = '1' or cache_flush = '1' then
                for i in 0 to 255 loop
                    cache_valid_r(i) <= '0';
                end loop;
                cache_hit_d1 <= '0';
                cache_data_d1 <= (others => '0');
            else
                if cpu_enable = '1' and cpu_we = '0' and bram_invalidate = '0'
                   and cpu_addr_hi = x"00" then
                    idx := to_integer(cpu_addr(7 downto 0));
                    tag := std_logic_vector(cpu_addr(15 downto 8));
                    cache_data_r(idx) <= bram_do;
                    cache_tag_r(idx)  <= tag;
                    cache_valid_r(idx)<= '1';
                    cache_hit_d1  <= '1';
                    cache_data_d1 <= bram_do;
                else
                    cache_hit_d1 <= '0';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Outputs
    ------------------------------------------------------------------
    probe_data <= bram(to_integer(probe_addr(15 downto 0)))
                  when probe_addr(23 downto 16) = x"00"
                  else sdram_probe_dout;

    dbg_pc      <= cpu_dbg_pc;
    dbg_pbr     <= cpu_dbg_pbr;
    dbg_p       <= cpu_dbg_p;
    dbg_ir      <= cpu_dbg_ir;
    dbg_addr    <= cpu_addr;
    dbg_data_in <= std_logic_vector(cpu_di);
    dbg_we      <= cpu_we;

    status_inj_busy   <= inj_meminit;
    status_inj_end    <= inj_end;
    status_bram_inval <= bram_invalidate;

end architecture;
