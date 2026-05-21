library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.c64_powerup_init_pkg.all;

entity verilator_c64_vanilla_top is
    generic (
        -- Keep the first desktop MVP modest so synthesis-to-Verilog stays
        -- tractable. This is enough for bank $00 RAM plus headroom for small
        -- PRG experiments. Raise later once the flow is stable or replace the
        -- SDRAM model with a Verilator-specific host memory backend.
        SDRAM_BYTES : integer := 256 * 1024
    );
    port (
        clk32 : in std_logic;
        reset : in std_logic;

        -- Host-driven ROM streaming into fpga64_buslogic's writable dprom.
        rom_wr   : in std_logic;
        rom_addr : in unsigned(13 downto 0);
        rom_data : in std_logic_vector(7 downto 0);

        -- Host-driven PRG loader matching the reduced-harness ioctl model.
        ioctl_download : in std_logic;
        ioctl_wr       : in std_logic;
        ioctl_addr     : in unsigned(15 downto 0);
        ioctl_data     : in std_logic_vector(7 downto 0);
        ioctl_index    : in std_logic_vector(7 downto 0);

        -- Simulation-only power-up RAM initialization control.
        -- 00=off, 01=zero, 10=VICE-style deterministic pattern.
        powerup_init_mode : in std_logic_vector(1 downto 0);

        -- Inputs forwarded to the real core.
        ps2_key   : in std_logic_vector(10 downto 0);
        kbd_reset : in std_logic;
        shift_mod : in std_logic_vector(1 downto 0);
        joyA      : in std_logic_vector(6 downto 0);
        joyB      : in std_logic_vector(6 downto 0);
        pot1      : in std_logic_vector(7 downto 0);
        pot2      : in std_logic_vector(7 downto 0);
        pot3      : in std_logic_vector(7 downto 0);
        pot4      : in std_logic_vector(7 downto 0);

        -- Direct SDRAM probe for memory inspection.
        probe_addr : in unsigned(23 downto 0);
        probe_data : out std_logic_vector(7 downto 0);

        -- Raw video/audio from the real core.
        hsync : out std_logic;
        vsync : out std_logic;
        red   : out std_logic_vector(7 downto 0);
        green : out std_logic_vector(7 downto 0);
        blue  : out std_logic_vector(7 downto 0);
        audio_l : out std_logic_vector(17 downto 0);
        audio_r : out std_logic_vector(17 downto 0);

        -- Debug/status exported for the host.
        dbg_pc      : out unsigned(15 downto 0);
        dbg_pbr     : out unsigned(7 downto 0);
        dbg_p       : out unsigned(7 downto 0);
        dbg_ir      : out unsigned(7 downto 0);
        dbg_addr    : out unsigned(15 downto 0);
        dbg_data_in : out std_logic_vector(7 downto 0);
        dbg_we      : out std_logic;
        dbg_scr_wr_addr : out unsigned(15 downto 0);
        dbg_scr_wr_pc   : out unsigned(15 downto 0);
        dbg_scr_wr_data : out unsigned(7 downto 0);
        dbg_scr_wr_ir   : out unsigned(7 downto 0);
        dbg_scr_zero_hit: out std_logic;

        status_inj_busy      : out std_logic;
        status_inj_end       : out unsigned(15 downto 0);
        status_bram_inval    : out std_logic;
        status_powerup_busy  : out std_logic;
        cpu_has_bus          : out std_logic;
        supercpu_emul     : out std_logic;
        supercpu_cycle    : out std_logic;
        supercpu_bank     : out unsigned(7 downto 0)
    );
end entity;

architecture rtl of verilator_c64_vanilla_top is
    signal reset_n    : std_logic;
    signal core_reset : std_logic;

    signal c64_addr       : unsigned(15 downto 0);
    signal c64_data_out   : unsigned(7 downto 0);
    signal c64_data_in    : unsigned(7 downto 0);
    signal sdram_data_raw : unsigned(7 downto 0);
    signal sdram_data_reu : unsigned(7 downto 0);
    signal sdram_data_hi  : unsigned(7 downto 0);
    signal sdram_data_lo  : unsigned(7 downto 0);
    signal ram_ce         : std_logic;
    signal ram_we         : std_logic;

    signal io_cycle    : std_logic;
    signal ext_cycle   : std_logic;
    signal refresh_sig : std_logic;

    signal hsync_sig : std_logic;
    signal vsync_sig : std_logic;
    signal r_sig     : unsigned(7 downto 0);
    signal g_sig     : unsigned(7 downto 0);
    signal b_sig     : unsigned(7 downto 0);

    signal audio_l_sig : std_logic_vector(17 downto 0);
    signal audio_r_sig : std_logic_vector(17 downto 0);

    signal dbg_cpu_addr_s : unsigned(15 downto 0);
    signal dbg_cpu_data_s : unsigned(7 downto 0);
    signal dbg_cpu_we_s   : std_logic;
    signal dbg_cpu_en_s   : std_logic;
    signal dbg_cpu_sp_s   : unsigned(15 downto 0);
    signal dbg_cpu_p_s    : unsigned(7 downto 0);
    signal dbg_cpu_ir_s   : unsigned(7 downto 0);
    signal dbg_cpu_pbr_s  : unsigned(7 downto 0);
    signal dbg_cpu_dbr_s  : unsigned(7 downto 0);

    signal supercpu_emul_s  : std_logic;
    signal supercpu_cycle_s : std_logic;
    signal supercpu_bank_s  : unsigned(7 downto 0);
    signal cpu_has_bus_s    : std_logic;
    signal dbg_scr_wr_addr_s : unsigned(15 downto 0);
    signal dbg_scr_wr_pc_s   : unsigned(15 downto 0);
    signal dbg_scr_wr_data_s : unsigned(7 downto 0);
    signal dbg_scr_wr_ir_s   : unsigned(7 downto 0);
    signal dbg_scr_zero_hit_s: std_logic;

    signal ioctl_load_addr    : unsigned(24 downto 0) := (others => '0');
    signal inj_end_sig        : unsigned(15 downto 0) := (others => '0');
    signal ioctl_req_wr       : std_logic := '0';
    signal io_cycle_addr      : unsigned(24 downto 0) := (others => '0');
    signal io_cycle_data      : unsigned(7 downto 0) := (others => '0');
    signal io_cycle_we        : std_logic := '0';
    signal io_bram_we_pulse   : std_logic := '0';
    signal inj_meminit        : std_logic := '0';
    signal inj_meminit_data   : unsigned(7 downto 0) := (others => '0');
    signal old_download       : std_logic := '0';
    signal bram_inval_hold    : std_logic;
    signal powerup_init_armed : std_logic := '1';
    signal powerup_init_busy  : std_logic := '0';
    signal powerup_init_addr  : unsigned(15 downto 0) := (others => '0');

    signal sdram_addr       : unsigned(23 downto 0) := (others => '0');
    signal sdram_din        : std_logic_vector(7 downto 0) := (others => '0');
    signal sdram_we_sig     : std_logic := '0';
    signal sdram_re_sig     : std_logic := '0';
    signal sdram_dout       : std_logic_vector(7 downto 0);
    signal sdram_probe_dout : std_logic_vector(7 downto 0);
begin
    core_reset <= reset or powerup_init_armed or powerup_init_busy;
    reset_n    <= not core_reset;

    -- Same PRG-load glue as the proven reduced harness.
    prg_load_sm : process(clk32)
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                ioctl_load_addr    <= (others => '0');
                inj_end_sig        <= (others => '0');
                ioctl_req_wr       <= '0';
                io_cycle_we        <= '0';
                io_bram_we_pulse   <= '0';
                inj_meminit        <= '0';
                inj_meminit_data   <= (others => '0');
                old_download       <= '0';
                powerup_init_armed <= '1';
                powerup_init_busy  <= '0';
                powerup_init_addr  <= (others => '0');
            else
                io_cycle_we      <= '0';
                io_bram_we_pulse <= '0';
                old_download     <= ioctl_download;

                if powerup_init_armed = '1' then
                    powerup_init_armed <= '0';
                    powerup_init_addr  <= (others => '0');
                    if powerup_init_mode = "00" then
                        powerup_init_busy <= '0';
                    else
                        powerup_init_busy <= '1';
                    end if;
                elsif powerup_init_busy = '1' then
                    io_cycle_addr    <= "000000000" & powerup_init_addr;
                    io_cycle_data    <= c64_powerup_init_byte(powerup_init_addr, powerup_init_mode);
                    io_cycle_we      <= '1';
                    io_bram_we_pulse <= '1';
                    if powerup_init_addr = x"FFFF" then
                        powerup_init_busy <= '0';
                    else
                        powerup_init_addr <= powerup_init_addr + 1;
                    end if;
                else
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
        end if;
    end process;

    bram_inval_hold <= ioctl_download or inj_meminit or powerup_init_busy;

    sdram_write_mux : process(clk32)
    begin
        if rising_edge(clk32) then
            sdram_we_sig <= '0';
            sdram_re_sig <= '0';
            sdram_din    <= (others => '0');

            if reset /= '1' then
                if io_cycle_we = '1' then
                    sdram_we_sig <= '1';
                    sdram_addr   <= io_cycle_addr(23 downto 0);
                    sdram_din    <= std_logic_vector(io_cycle_data);
                elsif ram_we = '1' then
                    sdram_we_sig <= '1';
                    sdram_addr   <= x"00" & c64_addr;
                    sdram_din    <= std_logic_vector(c64_data_out);
                elsif ram_ce = '1' then
                    sdram_re_sig <= '1';
                    sdram_addr   <= x"00" & c64_addr;
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
            we         => sdram_we_sig,
            re         => sdram_re_sig,
            dout       => sdram_dout,
            probe_addr => probe_addr,
            probe_dout => sdram_probe_dout
        );

    c64_data_in    <= unsigned(sdram_dout);
    sdram_data_raw <= unsigned(sdram_dout);
    sdram_data_reu <= unsigned(sdram_dout);
    sdram_data_hi  <= unsigned(sdram_dout);
    sdram_data_lo  <= unsigned(sdram_dout);
    probe_data      <= sdram_probe_dout;

    dut : entity work.fpga64_sid_iec
        port map (
            clk32        => clk32,
            reset_n      => reset_n,
            bios         => "00",
            pause        => '0',
            pause_out    => open,
            ps2_key      => ps2_key,
            kbd_reset    => kbd_reset,
            shift_mod    => shift_mod,
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
            supercpu_en  => '0',
            supercpu_rom => '0',
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
            dbg_scr_wr_addr => dbg_scr_wr_addr_s,
            dbg_scr_wr_pc   => dbg_scr_wr_pc_s,
            dbg_scr_wr_data => dbg_scr_wr_data_s,
            dbg_scr_wr_ir   => dbg_scr_wr_ir_s,
            dbg_scr_zero_hit=> dbg_scr_zero_hit_s,
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
            joyA        => joyA,
            joyB        => joyB,
            pot1        => pot1,
            pot2        => pot2,
            pot3        => pot3,
            pot4        => pot4,
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
            c64rom_addr => std_logic_vector(rom_addr),
            c64rom_data => rom_data,
            c64rom_wr   => rom_wr,
            cass_motor  => open,
            cass_write  => open,
            cass_sense  => '1',
            cass_read   => '1'
        );

    hsync   <= hsync_sig;
    vsync   <= vsync_sig;
    red     <= std_logic_vector(r_sig);
    green   <= std_logic_vector(g_sig);
    blue    <= std_logic_vector(b_sig);
    audio_l <= audio_l_sig;
    audio_r <= audio_r_sig;

    dbg_pc      <= dbg_cpu_addr_s;
    dbg_pbr     <= dbg_cpu_pbr_s;
    dbg_p       <= dbg_cpu_p_s;
    dbg_ir      <= dbg_cpu_ir_s;
    dbg_addr    <= dbg_cpu_addr_s;
    dbg_data_in <= std_logic_vector(dbg_cpu_data_s);
    dbg_we      <= dbg_cpu_we_s;
    dbg_scr_wr_addr <= dbg_scr_wr_addr_s;
    dbg_scr_wr_pc   <= dbg_scr_wr_pc_s;
    dbg_scr_wr_data <= dbg_scr_wr_data_s;
    dbg_scr_wr_ir   <= dbg_scr_wr_ir_s;
    dbg_scr_zero_hit <= dbg_scr_zero_hit_s;

    status_inj_busy     <= inj_meminit;
    status_inj_end      <= inj_end_sig;
    status_bram_inval   <= bram_inval_hold;
    status_powerup_busy <= powerup_init_busy;
    cpu_has_bus         <= cpu_has_bus_s;
    supercpu_emul     <= supercpu_emul_s;
    supercpu_cycle    <= supercpu_cycle_s;
    supercpu_bank     <= supercpu_bank_s;
end architecture;
