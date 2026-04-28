-- c64_reduced_top_v2.vhd
--
-- Phase 4b: wraps the REAL fpga64_sid_iec.vhd in a simulation-friendly top
-- level. Pulls in VHDL stubs for every Verilog child (mos6526, sid_top)
-- instantiated inside fpga64_sid_iec plus the GHDL shims for the files
-- that cannot be parsed under --std=08 (cpu_6510, fpga64_rgbcolor) and a
-- patched copy of fpga64_sid_iec.vhd itself (for the one missing
-- when-others case).
--
-- Architecture:
--
--                 +--------------- c64_reduced_top_v2 ---------------+
--                 |                                                   |
--  ioctl  ───────>|  prg_load_sm (same as Phase 4 v1)                |
--  probe  ───────>|  (+ bram_invalidate + cache_flush glue)          |
--                 |                                                   |
--                 |  ROM loader (elaboration-time)                   |
--                 |  → c64rom_wr handshake into kernel_c64 dprom     |
--                 |                                                   |
--                 |    +-- fpga64_sid_iec (REAL) -----------------+  |
--                 |    |                                          |  |
--                 |    |  sysCycle 32-phase bus arbitration        |  |
--                 |    |  cpu_65c816 (REAL)   cpu_6510 (STUB)      |  |
--                 |    |  cpu_cache (REAL)    c64_ram64k (REAL)    |  |
--                 |    |  fpga64_buslogic (REAL)                   |  |
--                 |    |  video_vicII_656x (REAL)                  |  |
--                 |    |  mos6526 x2 (STUB)  sid_top (STUB)        |  |
--                 |    |                                          |  |
--                 |    +-- ramAddr, ramDin, ramDout ->             |  |
--                 |         simple_sdram_model (shared)            |  |
--                 |                                                   |
--                 +---------------------------------------------------+
--
-- What you get vs Phase 4 v1:
--   * REAL sysCycle / enableCpu / enableCia / enableVic scheduling
--   * REAL cpu_cache (8KB direct-mapped with write-through)
--   * REAL 64KB dual-port BRAM (bank $00)
--   * REAL buslogic (ROM/RAM/IO map, bankSwitch, $D078 etc)
--   * REAL VIC-II (no visible output, but it drives the bus-arb state)
--   * REAL bram_invalidate / cache_flush rising-edge pulse generator
--   * REAL inj_meminit path (through c64.sv-style glue below)
--
-- What's still missing:
--   * No REU, no cartridge, no C1351, no SDRAM.v (we use simple_sdram_model)
--   * No IEC drives, no keyboard input (CIA1 stub returns $FF)
--   * No video pixels visible (VIC r/g/b outputs land in the void)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rom_loader_pkg.all;

entity c64_reduced_top_v2 is
    generic (
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

        -- Bench-side probe: combinational byte read from SDRAM model
        probe_addr : in  unsigned(23 downto 0);
        probe_data : out std_logic_vector(7 downto 0);

        -- Bench-side probe: synchronous byte read from BRAM (c64_ram64k Port C).
        -- probe_addr(15:0) drives the BRAM address; bram_probe_data is the
        -- clocked readback (1-cycle latency).
        bram_probe_data : out std_logic_vector(7 downto 0);

        -- CPU observability (from the REAL dbg_* outputs of fpga64_sid_iec)
        dbg_pc       : out unsigned(15 downto 0);
        dbg_pbr      : out unsigned(7 downto 0);
        dbg_p        : out unsigned(7 downto 0);
        dbg_ir       : out unsigned(7 downto 0);
        dbg_addr     : out unsigned(15 downto 0);
        dbg_data_in  : out std_logic_vector(7 downto 0);
        dbg_we       : out std_logic;

        -- Loader status
        status_inj_busy  : out std_logic;
        status_inj_end   : out unsigned(15 downto 0);
        status_bram_inval: out std_logic;
        status_rom_found : out std_logic;  -- '1' if a real ROM was loaded
        status_rom_src   : out std_logic_vector(7 downto 0) -- src tag byte
    );
end entity;

architecture rtl of c64_reduced_top_v2 is

    ------------------------------------------------------------------
    -- fpga64_sid_iec ports (only the ones we actively drive)
    ------------------------------------------------------------------
    signal reset_n : std_logic;
    signal c64_addr : unsigned(15 downto 0);
    signal c64_data_out : unsigned(7 downto 0);
    signal c64_data_in  : unsigned(7 downto 0);
    signal sdram_data_raw : unsigned(7 downto 0);
    signal sdram_data_reu : unsigned(7 downto 0);
    signal sdram_data_hi  : unsigned(7 downto 0);
    signal sdram_data_lo  : unsigned(7 downto 0);
    signal ram_ce : std_logic;
    signal ram_we : std_logic;

    signal io_cycle  : std_logic;
    signal ext_cycle : std_logic;
    signal refresh_sig : std_logic;

    signal hsync_sig : std_logic;
    signal vsync_sig : std_logic;
    signal r_sig, g_sig, b_sig : unsigned(7 downto 0);

    signal audio_l_sig : std_logic_vector(17 downto 0);
    signal audio_r_sig : std_logic_vector(17 downto 0);

    -- Debug outputs from fpga64_sid_iec
    signal dbg_cpu_addr_s : unsigned(15 downto 0);
    signal dbg_cpu_data_s : unsigned(7 downto 0);
    signal dbg_cpu_we_s   : std_logic;
    signal dbg_cpu_en_s   : std_logic;
    signal dbg_cpu_sp_s   : unsigned(15 downto 0);
    signal dbg_cpu_p_s    : unsigned(7 downto 0);
    signal dbg_cpu_ir_s   : unsigned(7 downto 0);
    signal dbg_cpu_pbr_s  : unsigned(7 downto 0);
    signal dbg_cpu_dbr_s  : unsigned(7 downto 0);

    signal supercpu_emul_s : std_logic;
    signal supercpu_cycle_s : std_logic;
    signal supercpu_bank_s : unsigned(7 downto 0);
    signal cpu_has_bus_s : std_logic;

    ------------------------------------------------------------------
    -- io_cycle / inj_meminit / bram_invalidate glue (from c64.sv)
    ------------------------------------------------------------------
    signal ioctl_load_addr  : unsigned(24 downto 0) := (others => '0');
    signal inj_end_sig      : unsigned(15 downto 0) := (others => '0');
    signal ioctl_req_wr     : std_logic := '0';
    signal io_cycle_addr    : unsigned(24 downto 0) := (others => '0');
    signal io_cycle_data    : unsigned(7 downto 0) := (others => '0');
    signal io_cycle_we      : std_logic := '0';
    signal io_bram_we_pulse : std_logic := '0';
    signal inj_meminit      : std_logic := '0';
    signal inj_meminit_data : unsigned(7 downto 0) := (others => '0');
    signal old_download     : std_logic := '0';

    signal bram_inval_hold  : std_logic;

    ------------------------------------------------------------------
    -- c64rom_wr handshake: drives the kernel_c64 dprom at reset
    ------------------------------------------------------------------
    signal c64rom_addr_sig : std_logic_vector(13 downto 0) := (others => '0');
    signal c64rom_data_sig : std_logic_vector(7 downto 0) := (others => '0');
    signal c64rom_wr_sig   : std_logic := '0';

    signal rom_image : rom_bin_t (0 to 16383);
    signal rom_status_s : rom_status_t;

    -- ROM load sequencer
    signal rom_load_state : integer range 0 to 2 := 0;  -- 0=idle,1=loading,2=done
    signal rom_load_idx   : integer range 0 to 16384 := 0;

    ------------------------------------------------------------------
    -- SDRAM model (replaces sdram.v)
    ------------------------------------------------------------------
    signal sdram_addr : unsigned(23 downto 0) := (others => '0');
    signal sdram_din  : std_logic_vector(7 downto 0) := (others => '0');
    signal sdram_we   : std_logic := '0';
    signal sdram_re   : std_logic := '0';
    signal sdram_dout : std_logic_vector(7 downto 0);
    signal sdram_probe_dout : std_logic_vector(7 downto 0);
    signal bram_probe_dout_s : unsigned(7 downto 0);

begin

    reset_n <= not reset;

    ------------------------------------------------------------------
    -- ROM loading: on first cycle out of reset, walk through all 16KB
    -- and push them over the c64rom_wr handshake. This lands in the
    -- kernel_c64 dprom inside fpga64_buslogic.vhd.
    ------------------------------------------------------------------
    rom_init : process
        variable v_image  : rom_bin_t (0 to 16383);
        variable v_status : rom_status_t;
    begin
        -- Elaboration-time (or deferred-init) ROM resolution
        resolve_kernal_basic(v_image, v_status);
        rom_image    <= v_image;
        rom_status_s <= v_status;
        report "rom_loader: found=" & boolean'image(v_status.found)
               & " src=" & v_status.source;
        wait;
    end process;

    status_rom_found <= '1' when rom_status_s.found else '0';
    status_rom_src   <= x"52" when rom_status_s.found else x"46"; -- 'R' / 'F'

    rom_push : process(clk32)
    begin
        if rising_edge(clk32) then
            c64rom_wr_sig <= '0';
            if reset = '1' then
                rom_load_state <= 0;
                rom_load_idx   <= 0;
            else
                case rom_load_state is
                    when 0 =>
                        rom_load_state <= 1;
                        rom_load_idx   <= 0;
                    when 1 =>
                        if rom_load_idx < 16384 then
                            c64rom_addr_sig <= std_logic_vector(
                                to_unsigned(rom_load_idx, 14));
                            c64rom_data_sig <= rom_image(rom_load_idx);
                            c64rom_wr_sig   <= '1';
                            rom_load_idx    <= rom_load_idx + 1;
                        else
                            rom_load_state <= 2;
                        end if;
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- PRG-load state machine (faithful to c64.sv lines 1396-1443)
    ------------------------------------------------------------------
    prg_load_sm : process(clk32)
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                ioctl_load_addr  <= (others => '0');
                inj_end_sig      <= (others => '0');
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

                if ioctl_req_wr = '1' then
                    io_cycle_addr <= ioctl_load_addr;
                    if inj_meminit = '1' then
                        io_cycle_data <= inj_meminit_data;
                    else
                        io_cycle_data <= unsigned(ioctl_data);
                    end if;
                    io_cycle_we <= '1';
                    if ioctl_load_addr(24 downto 16) = "000000000" then
                        io_bram_we_pulse <= '1';
                    end if;
                    ioctl_load_addr <= ioctl_load_addr + 1;
                    ioctl_req_wr    <= '0';
                end if;

                if ioctl_wr = '1' and ioctl_index = x"01" and ioctl_download = '1' then
                    if ioctl_addr = 0 then
                        ioctl_load_addr(7 downto 0) <= unsigned(ioctl_data);
                        inj_end_sig(7 downto 0)     <= unsigned(ioctl_data);
                    elsif ioctl_addr = 1 then
                        ioctl_load_addr(15 downto 8) <= unsigned(ioctl_data);
                        inj_end_sig(15 downto 8)     <= unsigned(ioctl_data);
                    else
                        ioctl_req_wr <= '1';
                        inj_end_sig  <= inj_end_sig + 1;
                    end if;
                end if;

                if old_download = '1' and ioctl_download = '0'
                   and ioctl_index = x"01" and inj_meminit = '0' then
                    inj_meminit     <= '1';
                    ioctl_load_addr <= (others => '0');
                end if;

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
                                inj_meminit_data <= inj_end_sig(7 downto 0);
                                ioctl_req_wr     <= '1';
                            when 16#2E# | 16#30# | 16#32# | 16#AF# =>
                                inj_meminit_data <= inj_end_sig(15 downto 8);
                                ioctl_req_wr     <= '1';
                            when others =>
                                ioctl_load_addr <= ioctl_load_addr + 1;
                        end case;
                    end if;
                end if;
            end if;
        end if;
    end process;

    bram_inval_hold <= ioctl_download or inj_meminit;

    ------------------------------------------------------------------
    -- SDRAM model: fed by ramAddr/ramDout/ramWE AND by io_cycle writes
    -- (those need to land in bank $00 of SDRAM for SuperRAM coherency)
    ------------------------------------------------------------------
    sdram_write_mux : process(clk32)
    begin
        if rising_edge(clk32) then
            sdram_we   <= '0';
            sdram_re   <= '0';
            sdram_din  <= (others => '0');

            if reset /= '1' then
                if io_cycle_we = '1' then
                    sdram_we   <= '1';
                    sdram_addr <= io_cycle_addr(23 downto 0);
                    sdram_din  <= std_logic_vector(io_cycle_data);
                elsif ram_we = '1' then
                    -- Real writes via ramAddr/ramDout — always bank $00
                    sdram_we   <= '1';
                    sdram_addr <= x"00" & c64_addr;
                    sdram_din  <= std_logic_vector(c64_data_out);
                elsif ram_ce = '1' then
                    sdram_re   <= '1';
                    sdram_addr <= x"00" & c64_addr;
                end if;
            end if;
        end if;
    end process;

    sdram_inst : entity work.simple_sdram_model
        generic map (
            MEM_BYTES => SDRAM_BYTES
        )
        port map (
            clk        => clk32,
            reset      => reset,
            addr       => sdram_addr,
            din        => sdram_din,
            we         => sdram_we,
            re         => sdram_re,
            dout       => sdram_dout,
            probe_addr => probe_addr,
            probe_dout => sdram_probe_dout
        );

    -- fpga64_sid_iec.ramDin is the data coming BACK from SDRAM. Drive it
    -- directly from the (combinational) sdram_dout.
    c64_data_in    <= unsigned(sdram_dout);
    sdram_data_raw <= unsigned(sdram_dout);
    sdram_data_reu <= unsigned(sdram_dout);
    sdram_data_hi  <= unsigned(sdram_dout);
    sdram_data_lo  <= unsigned(sdram_dout);

    probe_data <= sdram_probe_dout;
    bram_probe_data <= std_logic_vector(bram_probe_dout_s);

    ------------------------------------------------------------------
    -- DUT: the REAL fpga64_sid_iec
    ------------------------------------------------------------------
    dut : entity work.fpga64_sid_iec
        port map (
            clk32        => clk32,
            reset_n      => reset_n,
            bios         => "00",  -- dol_C64 (has writable kernel_c64 dprom)

            pause        => '0',
            pause_out    => open,

            ps2_key      => (others => '0'),
            kbd_reset    => '0',
            shift_mod    => "00",

            ramAddr      => c64_addr,
            ramDin       => c64_data_in,
            sdram_raw    => sdram_data_raw,
            sdram_superram => sdram_data_reu,
            sdram_hi     => sdram_data_hi,
            sdram_lo     => sdram_data_lo,
            ramDout      => c64_data_out,
            ramCE        => ram_ce,
            ramWE        => ram_we,

            io_cycle     => io_cycle,
            ext_cycle    => ext_cycle,
            refresh      => refresh_sig,

            cia_mode     => '0',
            turbo_mode   => "00",
            turbo_speed  => "00",
            scpu_speed   => "00",
            supercpu_en  => '1',       -- active CPU = 65C816
            supercpu_rom => '0',       -- no kickstart ROM — run C64 KERNAL directly
            bram_invalidate => bram_inval_hold,
            io_bram_we   => io_bram_we_pulse,
            io_bram_addr => io_cycle_addr(15 downto 0),
            io_bram_din  => io_cycle_data,

            dbg_0801_trap_en => '0',
            dbg_0801_pc      => open,
            dbg_0801_ir      => open,
            dbg_0801_data_out=> open,
            dbg_0801_cnt     => open,

            supercpu_emul  => supercpu_emul_s,
            supercpu_cycle => supercpu_cycle_s,
            supercpu_bank  => supercpu_bank_s,
            cpu_has_bus    => cpu_has_bus_s,

            dbg_cpu_addr => dbg_cpu_addr_s,
            dbg_cpu_data => dbg_cpu_data_s,
            dbg_cpu_we   => dbg_cpu_we_s,
            dbg_cpu_en   => dbg_cpu_en_s,
            dbg_cpu_sp   => dbg_cpu_sp_s,
            dbg_cpu_p    => dbg_cpu_p_s,
            dbg_cpu_ir   => dbg_cpu_ir_s,
            dbg_cpu_pbr  => dbg_cpu_pbr_s,
            dbg_cpu_dbr  => dbg_cpu_dbr_s,

            dbg_cia1_pa  => open,
            dbg_cia1_pb  => open,

            dbg_scr_wr_addr => open,
            dbg_scr_wr_pc   => open,
            dbg_scr_wr_data => open,
            dbg_scr_wr_ir   => open,
            dbg_scr_zero_hit=> open,
            dbg_scr_wr_bank => open,
            dbg_scr_arm     => open,

            dbg_vic_zero_hit => open,
            dbg_vic_zero_addr=> open,
            dbg_vic_zero_cpu => open,
            dbg_vic_zero_sysaddr => open,
            dbg_vic_wr_match => open,
            dbg_vic_wr_pc    => open,
            dbg_vic_prearm_cnt => open,
            dbg_vic_hit_cnt    => open,
            dbg_vic_mode       => open,
            dbg_vic_cpuf_zero_cnt => open,
            dbg_vic_cpue_live_zero_cnt => open,
            dbg_vic_cpue_hold_zero_cnt => open,
            dbg_vic_cpue_mismatch_cnt  => open,

            dbg_turbo_en       => open,
            dbg_cache_hit_d1   => open,
            dbg_enable_cpu_t65 => open,
            dbg_cpu_cyc        => open,
            dbg_diag           => open,
            dbg_bug_buf        => open,
            dbg_native_irq_vec => open,
            dbg_srr_count      => open,
            dbg_srr_data       => open,
            dbg_srr_addr_hi    => open,
            dbg_srr_cache_bank => open,
            dbg_srr_addr_lo    => open,
            dbg_srr_addr_mid   => open,

            vic_variant => "00",
            ntscMode    => '0',
            hsync       => hsync_sig,
            vsync       => vsync_sig,
            r           => r_sig,
            g           => g_sig,
            b           => b_sig,

            game        => '1',
            exrom       => '1',
            io_rom      => '0',
            io_ext      => '0',
            io_data     => (others => '1'),
            irq_n       => '1',
            nmi_n       => '1',
            nmi_ack     => open,
            romL        => open,
            romH        => open,
            UMAXromH    => open,
            IOE         => open,
            IOF         => open,
            IOF_raw     => open,
            iof_detect_o=> open,
            iof_we_o    => open,
            iof_addr_o  => open,
            iof_dout_o  => open,
            iof_fall_pulse_o => open,
            freeze_key  => open,
            mod_key     => open,
            tape_play   => open,

            dma_req     => '0',
            dma_cycle   => open,
            dma_addr    => (others => '0'),
            dma_dout    => (others => '0'),
            dma_din     => open,
            dma_we      => '0',
            irq_ext_n   => '1',

            joyA        => (others => '0'),
            joyB        => (others => '0'),
            pot1        => (others => '0'),
            pot2        => (others => '0'),
            pot3        => (others => '0'),
            pot4        => (others => '0'),

            audio_l     => audio_l_sig,
            audio_r     => audio_r_sig,
            sid_filter  => "00",
            sid_ver     => "00",
            sid_mode    => "000",
            sid_cfg     => "0000",
            sid_fc_off_l=> (others => '0'),
            sid_fc_off_r=> (others => '0'),
            sid_ld_clk  => '0',
            sid_ld_addr => (others => '0'),
            sid_ld_data => (others => '0'),
            sid_ld_wr   => '0',
            sid_digifix => '0',

            pb_i        => (others => '1'),
            pb_o        => open,
            pa2_i       => '1',
            pa2_o       => open,
            pc2_n_o     => open,
            flag2_n_i   => '1',
            sp2_i       => '1',
            sp2_o       => open,
            sp1_i       => '1',
            sp1_o       => open,
            cnt2_i      => '1',
            cnt2_o      => open,
            cnt1_i      => '1',
            cnt1_o      => open,

            iec_data_o  => open,
            iec_data_i  => '1',
            iec_clk_o   => open,
            iec_clk_i   => '1',
            iec_atn_o   => open,

            c64rom_addr => c64rom_addr_sig,
            c64rom_data => c64rom_data_sig,
            c64rom_wr   => c64rom_wr_sig,

            cass_motor  => open,
            cass_write  => open,
            cass_sense  => '1',
            cass_read   => '1'
        );

    -- bram_probe_* port wiring on fpga64_sid_iec was attempted in a prior
    -- session but never landed in RTL — leave bram_probe_data tied to zero
    -- and rely on SDRAM-side checks. Re-introduce only if c64_ram64k Port C
    -- is propagated up through fpga64_sid_iec entity.
    bram_probe_dout_s <= (others => '0');

    ------------------------------------------------------------------
    -- Debug pass-through to bench
    ------------------------------------------------------------------
    dbg_pc      <= dbg_cpu_addr_s;  -- approximation; real PC via dbg_cpu_addr
    dbg_pbr     <= dbg_cpu_pbr_s;
    dbg_p       <= dbg_cpu_p_s;
    dbg_ir      <= dbg_cpu_ir_s;
    dbg_addr    <= dbg_cpu_addr_s;
    dbg_data_in <= std_logic_vector(dbg_cpu_data_s);
    dbg_we      <= dbg_cpu_we_s;

    status_inj_busy   <= inj_meminit;
    status_inj_end    <= inj_end_sig;
    status_bram_inval <= bram_inval_hold;

end architecture;
