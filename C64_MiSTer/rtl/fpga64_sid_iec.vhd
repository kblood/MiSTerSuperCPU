-- -----------------------------------------------------------------------
--
--                                 FPGA 64
--
--     A fully functional commodore 64 implementation in a single FPGA
--
-- -----------------------------------------------------------------------
-- Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
-- -----------------------------------------------------------------------
--
-- System runs on 32 Mhz
-- The VIC-II runs in 4 cycles of first 16 cycles.
-- The CPU runs in the last 16 cycles. Effective cpu speed is 1 Mhz.
-- 
-- -----------------------------------------------------------------------
-- Dar 08/03/2014 
--
-- Based on fpga64_cone
-- add external selection for 15KHz(TV)/31KHz(VGA)
-- add external selection for power on NTSC(60Hz)/PAL(50Hz)
-- add external conection in/out for IEC signal
-- add sid entity 
-- -----------------------------------------------------------------------
-- 
-- Alexey Melnikov 2021
-- 
-- add dma engine
-- implement up to 4x turbo of C128 and smart types.
-- add user port signals
-- various fixes and tweaks
-- 
-- -----------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.std_logic_unsigned.ALL;
use IEEE.numeric_std.all;

-- -----------------------------------------------------------------------

entity fpga64_sid_iec is
port(
	clk32       : in  std_logic;
	reset_n     : in  std_logic;
	bios        : in  std_logic_vector(1 downto 0);
	
	pause       : in  std_logic := '0';
	pause_out   : out std_logic;

	-- keyboard interface (use any ordinairy PS2 keyboard)
	ps2_key     : in  std_logic_vector(10 downto 0);
	kbd_reset   : in  std_logic := '0';
	shift_mod   : in  std_logic_vector(1 downto 0);

	-- external memory
	ramAddr     : out unsigned(15 downto 0);
	ramDin      : in  unsigned(7 downto 0);
	ramDout     : out unsigned(7 downto 0);
	ramCE       : out std_logic;
	ramWE       : out std_logic;

	io_cycle    : out std_logic;
	ext_cycle   : out std_logic;
	refresh     : out std_logic;

	cia_mode    : in  std_logic;
	turbo_mode  : in  std_logic_vector(1 downto 0);
	turbo_speed : in  std_logic_vector(1 downto 0);

	-- VGA/SCART interface
	vic_variant : in  std_logic_vector(1 downto 0);
	ntscMode    : in  std_logic;
	hsync       : out std_logic;
	vsync       : out std_logic;
	r           : out unsigned(7 downto 0);
	g           : out unsigned(7 downto 0);
	b           : out unsigned(7 downto 0);

	-- cartridge port
	game        : in  std_logic;
	exrom       : in  std_logic;
	io_rom      : in  std_logic;
	io_ext      : in  std_logic;
	io_data     : in  unsigned(7 downto 0);
	irq_n       : in  std_logic;
	nmi_n       : in  std_logic;
	nmi_ack     : out std_logic;
	romL        : out std_logic;
	romH        : out std_logic;
	UMAXromH 	: out std_logic;
	IOE			: out std_logic;
	IOF			: out std_logic;
	freeze_key  : out std_logic;
	mod_key     : out std_logic;
	tape_play   : out std_logic;

	-- dma access
	dma_req     : in  std_logic := '0';
	dma_cycle   : out std_logic;
	dma_addr    : in  unsigned(15 downto 0) := (others => '0');
	dma_dout    : in  unsigned(7 downto 0) := (others => '0');
	dma_din     : out unsigned(7 downto 0);
	dma_we      : in  std_logic := '0';
	irq_ext_n   : in  std_logic := '1';

	-- joystick interface
	joyA        : in  std_logic_vector(6 downto 0);
	joyB        : in  std_logic_vector(6 downto 0);
	pot1        : in  std_logic_vector(7 downto 0);
	pot2        : in  std_logic_vector(7 downto 0);
	pot3        : in  std_logic_vector(7 downto 0);
	pot4        : in  std_logic_vector(7 downto 0);

	--SID
	audio_l     : out std_logic_vector(17 downto 0);
	audio_r     : out std_logic_vector(17 downto 0);
	sid_filter  : in  std_logic_vector(1 downto 0);
	sid_ver     : in  std_logic_vector(1 downto 0);
	sid_mode    : in  unsigned(2 downto 0);
	sid_cfg     : in  std_logic_vector(3 downto 0);
	sid_fc_off_l: in  std_logic_vector(12 downto 0);
	sid_fc_off_r: in  std_logic_vector(12 downto 0);
	sid_ld_clk  : in  std_logic;
	sid_ld_addr : in  std_logic_vector(11 downto 0);
	sid_ld_data : in  std_logic_vector(15 downto 0);
	sid_ld_wr   : in  std_logic;
	sid_digifix : in  std_logic;
	
	-- USER
	pb_i        : in  unsigned(7 downto 0);
	pb_o        : out unsigned(7 downto 0);
	pa2_i       : in  std_logic;
	pa2_o       : out std_logic;
	pc2_n_o     : out std_logic;
	flag2_n_i   : in  std_logic;
	sp2_i       : in  std_logic;
	sp2_o       : out std_logic;
	sp1_i       : in  std_logic;
	sp1_o       : out std_logic;
	cnt2_i      : in  std_logic;
	cnt2_o      : out std_logic;
	cnt1_i      : in  std_logic;
	cnt1_o      : out std_logic;

	-- IEC
	iec_data_o	: out std_logic;
	iec_data_i	: in  std_logic;
	iec_clk_o	: out std_logic;
	iec_clk_i	: in  std_logic;
	iec_atn_o	: out std_logic;
	
	c64rom_addr : in  std_logic_vector(13 downto 0);
	c64rom_data : in  std_logic_vector(7 downto 0);
	c64rom_wr   : in  std_logic;

	cass_motor  : out std_logic;
	cass_write  : out std_logic;
	cass_sense  : in  std_logic;
	cass_read   : in  std_logic;

	-- SuperCPU integration (Phase A)
	-- supercpu_en='0' (default) : T65 6510 path active, vanilla behavior.
	-- supercpu_en='1'           : P65C816 active in emulation mode at reset.
	supercpu_en   : in  std_logic := '0';
	supercpu_bank : out std_logic_vector(7 downto 0);   -- bank byte (A23-A16); $00 when 6510 active
	emu_mode_816  : out std_logic;                      -- '1' = emulation mode (always '1' when 6510 active)
	-- Phase D: external SDRAM mux gates the SuperRAM SDRAM cycle on
	-- cpu_has_bus so VIC-II reads (during VIC slots) never resolve to a
	-- stale supercpu_bank value left over from the prior CPU instruction.
	cpu_has_bus   : out std_logic;                      -- '1' during CPU slots (CYCLE_CPU0..CPUF), '0' during VIC/DMA/EXT

	-- Layered debug overlay port hops (rtl/debug/). Always-active outputs
	-- driven from existing internal signals + small latches; the c64.sv
	-- consumers gate them by DBG_CAP_* and discard them in release.
	dbg_raster_line : out std_logic_vector(8 downto 0); -- VIC.debugY
	dbg_d018        : out std_logic_vector(7 downto 0); -- last cpuDo to $D018
	dbg_d016        : out std_logic_vector(7 downto 0); -- last cpuDo to $D016
	dbg_dd00        : out std_logic_vector(7 downto 0); -- last cpuDo to $DD00
	dbg_cpu_pc_24   : out std_logic_vector(23 downto 0); -- {PBR,PC} for SCPU, {x"00",PC} for T65 (uses cpuAddr_6510 as PC proxy)
	-- P65C816-only diagnostics (zero when T65 active). When SCPU=on, dbg_p
	-- exposes P (NV-MX-DIZC) and dbg_dbr the data bank register. Both are
	-- used by the overlay to detect emu-mode flag drift (X→0, M→0, DBR→!0)
	-- which would mis-execute indexed addressing.
	dbg_p           : out std_logic_vector(7 downto 0);
	dbg_dbr         : out std_logic_vector(7 downto 0);
	-- 2026-04-30 DL triage: latch PC + 8-bit count on every $DD00 write
	-- so the overlay can show WHERE in DL the bad VIC bank value comes
	-- from. T65 writes $01; SCPU writes $00/$02. PC here is bad-write source.
	dbg_dd00_write_pc    : out std_logic_vector(23 downto 0);
	dbg_dd00_write_count : out std_logic_vector(7 downto 0);
	-- Per-value PC latches (indexed by cpuDo[1:0]) for routine-by-routine
	-- comparison T65 vs SCPU. If v1 stays at 0 in SCPU mode but populates
	-- in T65, that's proof the $01-writing path is never executed in SCPU.
	dbg_dd00_pc_v0       : out std_logic_vector(23 downto 0);
	dbg_dd00_pc_v1       : out std_logic_vector(23 downto 0);
	dbg_dd00_pc_v2       : out std_logic_vector(23 downto 0);
	dbg_dd00_pc_v3       : out std_logic_vector(23 downto 0);
	dbg_dd00_cnt_v0      : out std_logic_vector(7 downto 0);
	dbg_dd00_cnt_v1      : out std_logic_vector(7 downto 0);
	dbg_dd00_cnt_v2      : out std_logic_vector(7 downto 0);
	dbg_dd00_cnt_v3      : out std_logic_vector(7 downto 0);
	dbg_d018_last_pc     : out std_logic_vector(23 downto 0);
	dbg_d018_count       : out std_logic_vector(7 downto 0);
	dbg_d018_bad_pc      : out std_logic_vector(23 downto 0);
	dbg_d018_bad_count   : out std_logic_vector(7 downto 0)
);
end fpga64_sid_iec;

-- -----------------------------------------------------------------------

architecture rtl of fpga64_sid_iec is
-- System state machine
type sysCycleDef is (
	CYCLE_EXT0, CYCLE_EXT1, CYCLE_EXT2, CYCLE_EXT3,
	CYCLE_DMA0, CYCLE_DMA1, CYCLE_DMA2, CYCLE_DMA3,
	CYCLE_EXT4, CYCLE_EXT5, CYCLE_EXT6, CYCLE_EXT7,
	CYCLE_VIC0, CYCLE_VIC1, CYCLE_VIC2, CYCLE_VIC3,
	CYCLE_CPU0, CYCLE_CPU1, CYCLE_CPU2, CYCLE_CPU3,
	CYCLE_CPU4, CYCLE_CPU5, CYCLE_CPU6, CYCLE_CPU7,
	CYCLE_CPU8, CYCLE_CPU9, CYCLE_CPUA, CYCLE_CPUB,
	CYCLE_CPUC, CYCLE_CPUD, CYCLE_CPUE, CYCLE_CPUF
);

signal sysCycle     : sysCycleDef := sysCycleDef'low;
signal preCycle     : sysCycleDef := sysCycleDef'low;
signal sysEnable    : std_logic;
signal rfsh_cycle   : unsigned(1 downto 0);

signal dma_active   : std_logic;

signal phi0_cpu     : std_logic;
signal cpuHasBus    : std_logic;

signal baLoc        : std_logic;
signal ba_dma       : std_logic;
signal aec          : std_logic;

signal enableCpu    : std_logic;
signal enableVic    : std_logic;
signal enablePixel  : std_logic;
signal enableSid    : std_logic;

signal irq_cia1     : std_logic;
signal irq_cia2     : std_logic;
signal irq_vic      : std_logic;

signal systemWe     : std_logic;
signal pulseWr_io   : std_logic;
signal systemAddr   : unsigned(15 downto 0);

signal cs_io        : std_logic;
signal cs_vic       : std_logic;
signal cs_sid       : std_logic;
signal cs_color     : std_logic;
signal cs_cia1      : std_logic;
signal cs_cia2      : std_logic;
signal cs_ram       : std_logic;
signal cpuWe        : std_logic;
signal cpuWe_pre    : std_logic;
signal cpuAddr      : unsigned(15 downto 0);
signal cpuAddr_pre  : unsigned(15 downto 0);
signal cpuDi        : unsigned(7 downto 0);
signal cpuDo        : unsigned(7 downto 0);
signal cpuDo_pre    : unsigned(7 downto 0);
signal cpuIO        : unsigned(7 downto 0);

-- Per-CPU outputs for the dual-CPU mux (Phase A).
-- Both CPUs are instantiated; only one gets enable pulses based on
-- supercpu_en. Outputs are muxed into the existing cpuAddr_pre / cpuDo_pre /
-- cpuWe_pre / cpuIO / nmi_ack signals so the rest of the system is unchanged.
signal cpuAddr_6510 : unsigned(15 downto 0);
signal cpuDo_6510   : unsigned(7 downto 0);
signal cpuWe_6510   : std_logic;
signal cpuIO_6510   : unsigned(7 downto 0);
signal nmi_ack_6510 : std_logic;
signal cpuAddr_816  : unsigned(15 downto 0);
signal cpuDo_816    : unsigned(7 downto 0);
signal cpuWe_816    : std_logic;
signal cpuIO_816    : unsigned(7 downto 0);
signal nmi_ack_816  : std_logic;
signal addr_hi_816  : unsigned(7 downto 0);
signal emu_mode_816_i : std_logic;
signal vpa_816      : std_logic;  -- unused for now; reserved for future
signal vda_816      : std_logic;  -- unused for now; reserved for future
signal enableCpu_6510 : std_logic;
signal enableCpu_816  : std_logic;

-- Layered debug overlay internal signals (rtl/debug/).
signal dbg_d018_r     : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_d016_r     : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_dd00_r     : std_logic_vector(7 downto 0) := (others => '0');
-- 2026-04-30 DL triage extension: PC + count on each $DD00 write
signal dbg_dd00_pc_r    : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_dd00_count_r : std_logic_vector(7 downto 0)  := (others => '0');
-- Per-value PC latches indexed by cpuDo[1:0]
signal dbg_dd00_pc_v0_r : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_dd00_pc_v1_r : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_dd00_pc_v2_r : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_dd00_pc_v3_r : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_dd00_cnt_v0_r : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_dd00_cnt_v1_r : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_dd00_cnt_v2_r : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_dd00_cnt_v3_r : std_logic_vector(7 downto 0) := (others => '0');
-- v210: D018 write tracking (PC + counts, separate "bad" vs "any")
signal dbg_d018_last_pc_r  : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_d018_count_r    : std_logic_vector(7 downto 0)  := (others => '0');
signal dbg_d018_bad_pc_r   : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_d018_bad_count_r: std_logic_vector(7 downto 0)  := (others => '0');
-- T65 PC tracking — latch cpuAddr_6510 each cycle T65 is enabled and
-- Sync='1' (opcode-fetch cycle). That snapshot equals the PC of the
-- instruction that just started.
signal t65_sync   : std_logic;
signal t65_pc_latch : unsigned(15 downto 0) := (others => '0');
signal dd00_pc_now : std_logic_vector(23 downto 0);
signal dbg_raster_y   : unsigned(8 downto 0);
signal dbg_pc_816_i   : unsigned(15 downto 0);
signal dbg_pbr_816_i  : unsigned(7 downto 0);
signal dbg_p_816_i    : unsigned(7 downto 0);
signal dbg_dbr_816_i  : unsigned(7 downto 0);

-- ----------------------------------------------------------------------
-- Phase B — SuperCPU $D07x / $D0Bx register file (lifted from master).
-- All register state lives only when supercpu_en=1; vanilla 6510 mode
-- is unaffected (the read mux clauses gate on supercpu_en).
-- ----------------------------------------------------------------------
signal supercpu_en_prev  : std_logic := '0';                            -- rising-edge detect on supercpu_en
signal scpu_rom_vis      : std_logic := '1';                            -- '1' = SuperCPU ROM at $E000-$FFFF (Phase C uses)
signal scpu_speed_1mhz   : std_logic := '0';                            -- $D07A=1, $D07B=0
signal scpu_sys_1mhz     : std_logic := '0';                            -- $D072=1, $D073=0
signal scpu_regs_enabled : std_logic := '1';                            -- $D07E enables, $D07F/$D07D disables
signal scpu_hwenable     : std_logic := '0';                            -- ANY write to $D07E sets; $D07F/$D07D clears
signal scpu_bootmap      : std_logic := '1';                            -- '1' at reset (EPROM at $8000-$FFFF)
signal scpu_optim_mode   : unsigned(1 downto 0) := "11";                -- $D074-$D077 select; "11" = no optimization
signal cpuDi_raw         : unsigned(7 downto 0);                        -- raw bus data; SuperCPU regs mux ahead of this
signal io_data_i    : unsigned(7 downto 0);
signal ioe_i        : std_logic;
signal iof_i        : std_logic;

signal io_enable    : std_logic;
signal cpu_cyc      : std_logic;
signal cpu_cyc_s    : std_logic_vector(1 downto 0);
signal turbo_m      : std_logic_vector(2 downto 0);

signal reset        : std_logic := '1';

-- CIA signals
signal enableCia_p  : std_logic;
signal enableCia_n  : std_logic;
signal cia1Do       : unsigned(7 downto 0);
signal cia2Do       : unsigned(7 downto 0);
signal cia1_pai     : unsigned(7 downto 0);
signal cia1_pao     : unsigned(7 downto 0);
signal cia1_pbi     : unsigned(7 downto 0);
signal cia1_pbo     : unsigned(7 downto 0);
signal cia2_pai     : unsigned(7 downto 0);
signal cia2_pao     : unsigned(7 downto 0);
signal cia2_pbi     : unsigned(7 downto 0);
signal cia2_pbo     : unsigned(7 downto 0);
signal cia2_pbe     : unsigned(7 downto 0);

signal todclk       : std_logic;

-- video
signal vicColorIndex: unsigned(3 downto 0);
signal vicBus       : unsigned(7 downto 0);
signal vicDi        : unsigned(7 downto 0);
signal vicDiAec     : unsigned(7 downto 0);
signal vicAddr      : unsigned(15 downto 0);
signal vicData      : unsigned(7 downto 0);
signal lastVicDi    : unsigned(7 downto 0);
signal vicAddr1514  : unsigned(1 downto 0);
signal colorData    : unsigned(3 downto 0);
signal colorDataAec : unsigned(3 downto 0);
signal turbo_en     : std_logic;
signal turbo_state  : std_logic;

-- SID signals
signal sid_do       : unsigned(7 downto 0);
signal sid_sel_l    : std_logic;
signal sid_sel_r    : std_logic;
signal pot_x1       : std_logic_vector(7 downto 0);
signal pot_y1       : std_logic_vector(7 downto 0);
signal pot_x2       : std_logic_vector(7 downto 0);
signal pot_y2       : std_logic_vector(7 downto 0);

component sid_top
	port (
		reset         : in  std_logic;
		clk           : in  std_logic;
		ce_1m         : in  std_logic;

		cs            : in  std_logic_vector(1 downto 0);
		we            : in  std_logic;
		addr          : in  unsigned(4 downto 0);
		data_in       : in  unsigned(7 downto 0);
		data_out      : out unsigned(7 downto 0);

		pot_x_l       : in  std_logic_vector(7 downto 0) := (others => '0');
		pot_y_l       : in  std_logic_vector(7 downto 0) := (others => '0');
		pot_x_r       : in  std_logic_vector(7 downto 0) := (others => '0');
		pot_y_r       : in  std_logic_vector(7 downto 0) := (others => '0');

		audio_l       : out std_logic_vector(17 downto 0);
		audio_r       : out std_logic_vector(17 downto 0);

		ext_in_l      : in  std_logic_vector(17 downto 0);
		ext_in_r      : in  std_logic_vector(17 downto 0);

		fc_offset_l   : in  std_logic_vector(12 downto 0);
		fc_offset_r   : in  std_logic_vector(12 downto 0);

		filter_en     : in  std_logic_vector(1 downto 0);
		mode          : in  std_logic_vector(1 downto 0);
		cfg           : in  std_logic_vector(3 downto 0);

		ld_clk        : in  std_logic;
		ld_addr       : in  std_logic_vector(11 downto 0);
		ld_data       : in  std_logic_vector(15 downto 0);
		ld_wr         : in  std_logic
  );
end component;

component mos6526
	PORT (
		clk           : in  std_logic;
		mode          : in  std_logic := '0'; -- 0 - 6526 "old", 1 - 8521 "new"
		phi2_p        : in  std_logic;
		phi2_n        : in  std_logic;
		res_n         : in  std_logic;
		cs_n          : in  std_logic;
		rw            : in  std_logic; -- '1' - read, '0' - write
		rs            : in  unsigned(3 downto 0);
		db_in         : in  unsigned(7 downto 0);
		db_out        : out unsigned(7 downto 0);
		pa_in         : in  unsigned(7 downto 0);
		pa_out        : out unsigned(7 downto 0);
		pa_oe         : out unsigned(7 downto 0);
		pb_in         : in  unsigned(7 downto 0);
		pb_out        : out unsigned(7 downto 0);
		pb_oe         : out unsigned(7 downto 0);
		flag_n        : in  std_logic;
		pc_n          : out std_logic;
		tod           : in  std_logic;
		sp_in         : in  std_logic;
		sp_out        : out std_logic;
		cnt_in        : in  std_logic;
		cnt_out       : out std_logic;
		irq_n         : out std_logic
	);
end component; 

begin

-- -----------------------------------------------------------------------
-- Local signal to outside world
-- -----------------------------------------------------------------------

io_cycle <= '1' when
	(sysCycle >= CYCLE_EXT0 and sysCycle <= CYCLE_EXT3) or
	(sysCycle >= CYCLE_EXT4 and sysCycle <= CYCLE_EXT7 and rfsh_cycle /= "00")  else '0';

-- -----------------------------------------------------------------------
-- System state machine, controls bus accesses
-- and triggers enables of other components
-- -----------------------------------------------------------------------

sysCycle <= preCycle when sysEnable = '1' else CYCLE_EXT4;
pause_out <= not sysEnable;

process(clk32)
begin
	if rising_edge(clk32) then
		preCycle <= sysCycleDef'succ(preCycle);
		if preCycle = sysCycleDef'high then
			preCycle <= sysCycleDef'low;
			if sysEnable = '1' then
				rfsh_cycle <= rfsh_cycle + 1;
			end if;
		end if;
		
		refresh <= '0';
		if preCycle = sysCycleDef'pred(CYCLE_EXT4) and rfsh_cycle = "00" then
			sysEnable <= not pause;
			refresh <= '1';
		end if;
	end if;
end process;

process(clk32)
begin
	if rising_edge(clk32) then
		if preCycle = sysCycleDef'high then
			reset <= not reset_n;
		end if;
	end if;
end process;

-- PHI0/2-clock emulation
process(clk32)
begin
	if rising_edge(clk32) then
		if sysCycle = sysCycleDef'pred(CYCLE_CPU0) then
			phi0_cpu <= '1';
			if baLoc = '1' or (cpuWe = '1' and dma_active = '0') or (ba_dma = '1' and dma_active = '1') then
				cpuHasBus <= '1';
			end if;
		end if;
		if sysCycle = sysCycleDef'high then
			phi0_cpu <= '0';
			cpuHasBus <= '0';
		end if;
	end if;
end process;

process(clk32)
begin
	if rising_edge(clk32) then
		enableVic <= '0';
		enableCia_n <= '0';
		enableCia_p <= '0';
		enableSid <= '0';

		case sysCycle is
		when CYCLE_VIC2 =>
			enableVic <= '1';
		when CYCLE_CPUE =>
			enableVic <= '1';
		when CYCLE_CPUC =>
			enableCia_n <= '1';
		when CYCLE_CPUF =>
			enableCia_p <= '1';
			enableSid <= '1';
		when others =>
			null;
		end case;
	end if;
end process;

-- -----------------------------------------------------------------------
-- Color RAM
-- -----------------------------------------------------------------------
colorram: entity work.spram
generic map (
	DATA_WIDTH => 4,
	ADDR_WIDTH => 10
)
port map (
	clk => clk32,
	we => cs_color and pulseWr_io,
	addr => systemAddr(9 downto 0),
	data => cpuDo(3 downto 0),
	q => colorData
);

-- -----------------------------------------------------------------------
-- PLA and bus-switches
-- -----------------------------------------------------------------------
buslogic: entity work.fpga64_buslogic
port map (
	clk => clk32,
	reset => reset,
	bios => bios,

	cpuHasBus => cpuHasBus,
	aec => aec,

	bankSwitch => cpuIO(2 downto 0),

	game => game,
	exrom => exrom,
	io_rom => io_rom,
	io_ext => io_ext or sid_sel_r,
	io_data => io_data_i,

	ramData => ramDin,

	cpuWe => cpuWe,
	cpuAddr => cpuAddr,
	cpuData => cpuDo,
	vicAddr => vicAddr,
	vicData => vicData,
	sidData => sid_do,
	colorData => colorData,
	cia1Data => cia1Do,
	cia2Data => cia2Do,
	lastVicData => lastVicDi,

	systemWe => systemWe,
	systemAddr => systemAddr,
	dataToCpu => cpuDi_raw,
	dataToVic => vicDi,

	io_enable => io_enable,

	cs_vic => cs_vic,
	cs_sid => cs_sid,
	cs_color => cs_color,
	cs_cia1 => cs_cia1,
	cs_cia2 => cs_cia2,
	cs_ram => cs_ram,
	cs_ioE => ioe_i,
	cs_ioF => iof_i,
	cs_romL => romL,
	cs_romH => romH,
	cs_UMAXromH => UMAXromH,

	c64rom_addr => c64rom_addr,
	c64rom_data => c64rom_data,
	c64rom_wr => c64rom_wr,

	-- Phase C: SuperCPU kickstart ROM + sysram + I/O gate
	supercpu_en      => supercpu_en,
	supercpu_rom     => '1',  -- always present on this branch (no compile-time strip)
	supercpu_rom_vis => scpu_rom_vis,
	supercpu_bank    => std_logic_vector(addr_hi_816)
);

IOE <= ioe_i;
IOF <= iof_i;
cs_io <= cs_vic or cs_sid or cs_color or cs_cia1 or cs_cia2 or ioe_i or iof_i;

-- ----------------------------------------------------------------------
-- Phase B — SuperCPU register read mux. Lifted from master, simplified
-- (no scpu_native_vec / kickstart-overlay intercepts; those land in
-- Phase C).
--
-- Real SuperCPU register behavior (c64-wiki.com/wiki/SuperCPU):
--   $D072/$D073 = system 1MHz on/off
--   $D074-$D077 = optimization mode triggers
--   $D078       = SIMM/DMA status. Real HW returns bit7=busy (0 in steady
--                 state). We return $00 — polling demos like SCPU KICKS!
--                 hang on BPL otherwise.
--   $D07A/$D07B = software speed triggers (1MHz / turbo)
--   $D07E       = ROM-vis / hwenable strobe (any write enables regs)
--   $D07F/$D07D = disable regs / clear hwenable
--   $D0B0       = mode detect: $40 = SuperCPU v2 in C64 mode
--   $D0B2       = bit7=hwenable, bit6=sys_1mhz
--   $D0B3       = open-bus stub ($00, software-compat)
--   $D0B4       = optimization mode flags
--   $D0B5       = bit7=JiffyDOS(0), bit6=software speed
--   $D0B6       = bit7=emulation mode (1=6502, 0=native)
--   $D0B8       = bit7=sw 1MHz, bit6=combined 1MHz
--   $D0BC       = computed: bits2:0 = optim_low(111)
--
-- All clauses gate on supercpu_en='1' AND addr_hi_816=$00 so they never
-- intercept reads in 6510 mode or in non-zero banks.
-- ----------------------------------------------------------------------
cpuDi <= ("00000" & scpu_optim_mode & '1')
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0BC" and scpu_regs_enabled = '1') else
         x"40"
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B0" and scpu_regs_enabled = '1') else
         (scpu_hwenable & scpu_sys_1mhz & "000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B2" and scpu_regs_enabled = '1') else
         (scpu_speed_1mhz & (scpu_speed_1mhz or scpu_sys_1mhz) & "000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B8" and scpu_regs_enabled = '1') else
         ("000000" & scpu_optim_mode)
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B4" and scpu_regs_enabled = '1') else
         x"00"
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B3" and scpu_regs_enabled = '1') else
         x"00"
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"078" and scpu_regs_enabled = '1') else
         ("0" & scpu_speed_1mhz & "000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B5" and scpu_regs_enabled = '1') else
         (emu_mode_816_i & "0000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B6" and scpu_regs_enabled = '1') else
         (scpu_rom_vis & "0000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"07E") else
         cpuDi_raw;

-- ----------------------------------------------------------------------
-- Phase B — SuperCPU register write state machine. Lifted from master.
-- All writes gated on supercpu_en='1' and addr_hi_816=$00.
-- Reset (or rising edge of supercpu_en) initializes state.
-- ----------------------------------------------------------------------
process(clk32)
begin
	if rising_edge(clk32) then
		supercpu_en_prev <= supercpu_en;
		if reset = '1' or (supercpu_en = '1' and supercpu_en_prev = '0') then
			scpu_rom_vis      <= '1';
			scpu_speed_1mhz   <= '0';
			scpu_sys_1mhz     <= '0';
			scpu_regs_enabled <= '1';
			scpu_hwenable     <= '0';
			scpu_bootmap      <= '1';
			scpu_optim_mode   <= "11";
		elsif supercpu_en = '1' and cpuWe = '1' and addr_hi_816 = x"00" then
			-- $D072/$D073: system 1MHz (works even with regs disabled)
			if cpuAddr = x"D072" then
				scpu_sys_1mhz <= '1';
			elsif cpuAddr = x"D073" then
				scpu_sys_1mhz <= '0';
			elsif cpuAddr = x"D07E" then
				-- ANY write to $D07E = hwenable strobe (data irrelevant)
				scpu_hwenable     <= '1';
				scpu_regs_enabled <= '1';
				-- bit7=ROM visibility (kickstart writes $00 to expose KERNAL)
				scpu_rom_vis <= cpuDo(7);
				if cpuDo(7) = '0' and scpu_rom_vis = '1' then
					scpu_bootmap <= '0';   -- kickstart clearing rom_vis = bootmap done
				end if;
			elsif cpuAddr = x"D07F" or cpuAddr = x"D07D" then
				scpu_hwenable     <= '0';
				scpu_regs_enabled <= '0';
			elsif cpuAddr = x"D07A" then
				scpu_speed_1mhz <= '1';
			elsif cpuAddr = x"D07B" or cpuAddr = x"D079" then
				scpu_speed_1mhz <= '0';
			elsif cpuAddr = x"D074" then
				scpu_optim_mode <= "00";
			elsif cpuAddr = x"D075" then
				scpu_optim_mode <= "01";
			elsif cpuAddr = x"D076" then
				scpu_optim_mode <= "10";
			elsif cpuAddr = x"D077" then
				scpu_optim_mode <= "11";
			end if;
			-- Bootmap registers (require hwenable=1)
			if scpu_hwenable = '1' then
				if cpuAddr = x"D0B6" then
					scpu_bootmap <= '0';
				elsif cpuAddr = x"D0B7" then
					scpu_bootmap <= '1';
				end if;
			end if;
		end if;
	end if;
end process;

process(clk32)
begin
	if rising_edge(clk32) then
		pulseWr_io <= '0';
		if cpuWe = '1' then
			if sysCycle = CYCLE_CPUC then
				pulseWr_io <= '1';
			end if;
		end if;
	end if;
end process;

-- -----------------------------------------------------------------------
-- VIC-II video interface chip
-- -----------------------------------------------------------------------
process(clk32)
begin
	if rising_edge(clk32) then
		if phi0_cpu = '1' then
			if cpuWe = '1' and cs_vic = '1' then
				vicBus <= cpuDo;
			else
				vicBus <= x"FF";
			end if;
		end if;
	end if;
end process;

-- In the first three cycles after BA went low, the VIC reads
-- $ff as character pointers and
-- as color information the lower 4 bits of the opcode after the access to $d011.
vicDiAec <= vicBus when aec = '0' else vicDi;
colorDataAec <= cpuDi(3 downto 0) when aec = '0' else colorData;

vic: entity work.video_vicii_656x
generic map (
	registeredAddress => true,
	emulateRefresh => true,
	emulateLightpen => true,
	emulateGraphics => true
)			
port map (
	clk => clk32,
	reset => reset,
	enaPixel => enablePixel,
	enaData => enableVic,
	phi => phi0_cpu,
	
	baSync => '0',
	ba => baLoc,
	ba_dma => ba_dma,

	mode6569 => (not ntscMode),
	mode6567old => '0',
	mode6567R8 => ntscMode,
	mode6572 => '0',
	variant => vic_variant,

	turbo_en => turbo_en,
	turbo_state => turbo_state,
	
	cs => cs_vic,
	we => cpuWe,
	lp_n => cia1_pbi(4),

	aRegisters => cpuAddr(5 downto 0),
	diRegisters => cpuDo,
	di => vicDiAec,
	diColor => colorDataAec,
	do => vicData,

	vicAddr => vicAddr(13 downto 0),
	addrValid => aec,
	
	hsync => hSync,
	vsync => vSync,
	colorIndex => vicColorIndex,

	debugY => dbg_raster_y,

	irq_n => irq_vic
);

c64colors: entity work.fpga64_rgbcolor
port map (
	index => vicColorIndex,
	r => r,
	g => g,
	b => b
);

process(clk32)
begin
	if rising_edge(clk32) then
		if sysCycle = CYCLE_VIC3 then
			lastVicDi <= vicDi;
		end if;
	end if;
end process;

-- VIC bank to address lines
-- 
-- The glue logic on a C64C will generate a glitch during 10 <-> 01
-- generating 00 (in other words, bank 3) for one cycle.
--
-- When using the data direction register to change a single bit 0->1
-- (in other words, decreasing the video bank number by 1 or 2),
-- the bank change is delayed by one cycle. This effect is unstable.
process(clk32)
begin
	if rising_edge(clk32) then
		if phi0_cpu = '0' and enableVic = '1' then
			vicAddr1514 <= not cia2_pao(1 downto 0);
		end if;
	end if;
end process;

-- emulate only the first glitch (enough for Undead from Emulamer)
vicAddr(15 downto 14) <= "11" when ((vicAddr1514 xor not cia2_pao(1 downto 0)) = "11") and (cia2_pao(0) /= cia2_pao(1)) else not unsigned(cia2_pao(1 downto 0));

-- Pixel timing
process(clk32)
begin
	if rising_edge(clk32) then
		enablePixel <= '0';
		if sysCycle = CYCLE_VIC2
		or sysCycle = CYCLE_EXT2
		or sysCycle = CYCLE_DMA2
		or sysCycle = CYCLE_EXT6
		or sysCycle = CYCLE_CPU2
		or sysCycle = CYCLE_CPU6
		or sysCycle = CYCLE_CPUA
		or sysCycle = CYCLE_CPUE then
			enablePixel <= '1';
		end if;
	end if;
end process;

-- -----------------------------------------------------------------------
-- SID
-- -----------------------------------------------------------------------

--	Right SID Port: Same,DE00,D420,D500,DF00

sid_sel_l <= cs_sid when sid_mode(2 downto 1) /= 1 else (cs_sid and ((not sid_mode(0) and not cpuAddr(5)) or (sid_mode(0) and not cpuAddr(8))));
sid_sel_r <= sid_sel_l when sid_mode = 0 else ioe_i when sid_mode = 1 else iof_i when sid_mode = 4 else (cs_sid and not sid_sel_l);
io_data_i <= io_data when io_ext = '1' else sid_do when sid_sel_r = '1' else (others => '1');

pot_x1 <= (others => '1' ) when cia1_pao(6) = '0' else not pot1;
pot_y1 <= (others => '1' ) when cia1_pao(6) = '0' else not pot2;
pot_x2 <= (others => '1' ) when cia1_pao(7) = '0' else not pot3;
pot_y2 <= (others => '1' ) when cia1_pao(7) = '0' else not pot4;

sid : sid_top
port map (
	reset => reset,
	clk => clk32,
	ce_1m => enableSid,
	we => pulseWr_io,
	cs => sid_sel_r & sid_sel_l,
	addr => cpuAddr(4 downto 0),
	data_in => cpuDo,
	data_out => sid_do,
	pot_x_l => pot_x1 and pot_x2,
	pot_y_l => pot_y1 and pot_y2,

	audio_l => audio_l,
	audio_r => audio_r,

	ext_in_l(17) => sid_ver(0) and sid_digifix,
	ext_in_l(16 downto 0) => (others => '0'),

	ext_in_r(17) => sid_ver(1) and sid_digifix,
	ext_in_r(16 downto 0) => (others => '0'),

	filter_en => sid_filter,
	mode    => sid_ver,
	cfg     => sid_cfg,
	
	fc_offset_l => sid_fc_off_l,
	fc_offset_r => sid_fc_off_r,

	ld_clk  => sid_ld_clk,
	ld_addr => sid_ld_addr,
	ld_data => sid_ld_data,
	ld_wr   => sid_ld_wr
);

-- -----------------------------------------------------------------------
-- CIAs
-- -----------------------------------------------------------------------
cia1: mos6526
port map (
	clk => clk32,
	mode => cia_mode,
	phi2_p => enableCia_p,
	phi2_n => enableCia_n,
	res_n => not reset,
	cs_n => not cs_cia1,
	rw => not cpuWe,

	rs => cpuAddr(3 downto 0),
	db_in => cpuDo,
	db_out => cia1Do,

	pa_in => cia1_pai,
	pa_out => cia1_pao,
	pb_in => cia1_pbi,
	pb_out => cia1_pbo,

	flag_n => cass_read,
	sp_in => sp1_i,
	sp_out => sp1_o,
	cnt_in => cnt1_i,
	cnt_out => cnt1_o,

	tod => todclk,

	irq_n => irq_cia1
);

cia2: mos6526
port map (
	clk => clk32,
	mode => cia_mode,
	phi2_p => enableCia_p,
	phi2_n => enableCia_n,
	res_n => not reset,
	cs_n => not cs_cia2,
	rw => not cpuWe,

	rs => cpuAddr(3 downto 0),
	db_in => cpuDo,
	db_out => cia2Do,

	pa_in => cia2_pai and cia2_pao,
	pa_out => cia2_pao,
	pb_in => (pb_i and not cia2_pbe) or (cia2_pbo and cia2_pbe),
	pb_out => cia2_pbo,
	pb_oe => cia2_pbe,

	flag_n => flag2_n_i,
	pc_n => pc2_n_o,

	sp_in => sp2_i,
	sp_out => sp2_o,
	cnt_in => cnt2_i,
	cnt_out => cnt2_o,

	tod => todclk,

	irq_n => irq_cia2
);

serialBus: process(clk32)
begin
	if rising_edge(clk32) then
		if sysCycle = CYCLE_EXT5 then
			cia2_pai(7) <= iec_data_i and not cia2_pao(5);
			cia2_pai(6) <= iec_clk_i and not cia2_pao(4);
		end if;
	end if;
end process;

cia2_pai(5 downto 0) <= "111" & pa2_i & "11";

iec_data_o <= not cia2_pao(5);
iec_clk_o  <= not cia2_pao(4);
iec_atn_o  <= not cia2_pao(3);

pb_o  <= cia2_pbo;
pa2_o <= cia2_pao(2);

process(clk32)
variable sum: integer range 0 to 33000000;
begin
	if rising_edge(clk32) then
		if reset = '1' then
			todclk <= '0';
			sum := 0;
		elsif ntscMode = '1' then
			sum := sum + 120;
			if sum >= 32727266 then
				sum := sum - 32727266;
				todclk <= not todclk;
			end if;
		else
			sum := sum + 100;
			if sum >= 31527954 then
				sum := sum - 31527954;
				todclk <= not todclk;
			end if;
		end if;
	end if;
end process;

-- -----------------------------------------------------------------------
-- CPU / DMA  -  dual instance: T65-based 6510 (default) + P65C816 (SuperCPU)
-- -----------------------------------------------------------------------
-- Only the active CPU gets enable pulses. The inactive CPU still receives
-- clk and reset but never advances. Outputs are muxed at cpuAddr_pre etc.
enableCpu_6510 <= enableCpu and not dma_active and not supercpu_en;
enableCpu_816  <= enableCpu and not dma_active and supercpu_en;

cpu_6510_inst: entity work.cpu_6510
port map (
	clk => clk32,
	reset => reset,
	enable => enableCpu_6510,
	nmi_n => irq_cia2 and nmi_n,
	nmi_ack => nmi_ack_6510,
	irq_n => irq_cia1 and irq_vic and irq_n and irq_ext_n,
	rdy => baLoc,

	di => cpuDi,
	addr => cpuAddr_6510,
	do => cpuDo_6510,
	we => cpuWe_6510,

	diIO => cpuIO_6510(7) & cpuIO_6510(6) & cpuIO_6510(5) & cass_sense & cpuIO_6510(3) & "111",
	doIO => cpuIO_6510,
	sync_out => t65_sync
);

cpu_65c816_inst: entity work.cpu_65c816
port map (
	clk => clk32,
	reset => reset,
	enable => enableCpu_816,
	nmi_n => irq_cia2 and nmi_n,
	nmi_ack => nmi_ack_816,
	irq_n => irq_cia1 and irq_vic and irq_n and irq_ext_n,
	rdy => baLoc,

	di => cpuDi,
	addr => cpuAddr_816,
	do => cpuDo_816,
	we => cpuWe_816,

	diIO => cpuIO_816(7) & cpuIO_816(6) & cpuIO_816(5) & cass_sense & cpuIO_816(3) & "111",
	doIO => cpuIO_816,

	addr_hi        => addr_hi_816,
	emulation_mode => emu_mode_816_i,
	vpa            => vpa_816,
	vda            => vda_816,

	dbg_pc    => dbg_pc_816_i,
	dbg_sp    => open,
	dbg_p     => dbg_p_816_i,
	dbg_ir    => open,
	dbg_pbr   => dbg_pbr_816_i,
	dbg_dbr   => dbg_dbr_816_i,
	dbg_x     => open,
	dbg_y     => open,
	dbg_d     => open,
	dbg_state => open
);

-- CPU-output mux: select active CPU's outputs.
cpuAddr_pre <= cpuAddr_816  when supercpu_en = '1' else cpuAddr_6510;
cpuDo_pre   <= cpuDo_816    when supercpu_en = '1' else cpuDo_6510;
cpuWe_pre   <= cpuWe_816    when supercpu_en = '1' else cpuWe_6510;
cpuIO       <= cpuIO_816    when supercpu_en = '1' else cpuIO_6510;
nmi_ack     <= nmi_ack_816  when supercpu_en = '1' else nmi_ack_6510;

-- Expose bank + emu_mode to the rest of the system. When 6510 is active,
-- bank is forced to $00 and emu_mode='1' so downstream consumers always see
-- a sane "emulation mode bank $00" view in the default configuration.
supercpu_bank <= std_logic_vector(addr_hi_816)         when supercpu_en = '1' else x"00";
emu_mode_816  <= emu_mode_816_i                        when supercpu_en = '1' else '1';
cpu_has_bus   <= cpuHasBus;

cass_motor <= cpuIO(5);
cass_write <= cpuIO(3);

ramDout <= cpuDo;
ramAddr <= systemAddr;
ramWE   <= systemWe when sysCycle >= CYCLE_CPU0 else '0';
ramCE   <= cs_ram when sysCycle = CYCLE_VIC0 or cpu_cyc = '1' else '0';
cpu_cyc <= '1' when 
				(sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1' ) or
				(sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1' ) or
				(sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1' ) or
				(sysCycle = CYCLE_CPUC and (io_enable = '1'  or cs_ram = '1')) else '0';
				
process(clk32)
begin
	if rising_edge(clk32) then
		cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc;
		enableCpu <= cpu_cyc_s(1);
		io_enable <= io_enable and not enableCpu;

		if sysCycle = CYCLE_EXT0 then
			io_enable <= '1';
		end if;

		-- 2 points to register DMA request before CPU cycles.
		if sysCycle = CYCLE_EXT1 or sysCycle = CYCLE_EXT5 then
			dma_active <= dma_req;
			turbo_en <= turbo_mode(0);
			turbo_m <= "000";
			if cs_io = '0' and dma_req = '0' and ((turbo_mode(0) and turbo_state) = '1' or turbo_mode(1) = '1') then
				case turbo_speed is
					when "00" => turbo_m <= "010";
					when "01" => turbo_m <= "110";
					when "10" => turbo_m <= "111";
					when "11" => turbo_m <= "111"; -- unused
				end case;
			end if;
		end if;
	end if;
end process;

cpuAddr <= cpuAddr_pre when dma_active = '0' else dma_addr;
cpuDo   <= cpuDo_pre   when dma_active = '0' else dma_dout;
cpuWe   <= cpuWe_pre   when dma_active = '0' else dma_we;

ext_cycle <= '1' when (sysCycle >= CYCLE_DMA0 and sysCycle <= CYCLE_DMA3) else '0';
dma_cycle <= '1' when (sysCycle >= CYCLE_CPU0 and sysCycle <= CYCLE_CPUF) and cpuHasBus = '1' and dma_active = '1' else '0';
dma_din   <= cpuDi;

-- -----------------------------------------------------------------------
-- Keyboard
-- -----------------------------------------------------------------------
Keyboard: entity work.fpga64_keyboard
port map (
	clk => clk32,
	
	reset => kbd_reset,
	ps2_key => ps2_key,

	joyA => not unsigned(joyA(6 downto 0)),
	joyB => not unsigned(joyB(6 downto 0)),
	pai => cia1_pao,
	pbi => cia1_pbo,
	pao => cia1_pai,
	pbo => cia1_pbi,
	
	shift_mod => shift_mod,

	restore_key => freeze_key,
	tape_play => tape_play,
	mod_key => mod_key,
	backwardsReadingEnabled => '1'
);

-- ----------------------------------------------------------------------
-- Layered debug overlay register-write captures (rtl/debug/).
-- Latches the CPU bus byte being written to $D018, $D016, $DD00.
-- Driven from already-decoded cs_vic / cs_cia2 + cpuWe + cpuAddr; no
-- bus snooping needed.
-- ----------------------------------------------------------------------
process(clk32)
begin
	if rising_edge(clk32) then
		if reset = '1' then
			dbg_d018_r <= (others => '0');
			dbg_d016_r <= (others => '0');
			dbg_dd00_r <= (others => '0');
			dbg_dd00_pc_r    <= (others => '0');
			dbg_dd00_count_r <= (others => '0');
			dbg_dd00_pc_v0_r <= (others => '0');
			dbg_dd00_pc_v1_r <= (others => '0');
			dbg_dd00_pc_v2_r <= (others => '0');
			dbg_dd00_pc_v3_r <= (others => '0');
			dbg_dd00_cnt_v0_r <= (others => '0');
			dbg_dd00_cnt_v1_r <= (others => '0');
			dbg_dd00_cnt_v2_r <= (others => '0');
			dbg_dd00_cnt_v3_r <= (others => '0');
			dbg_d018_last_pc_r   <= (others => '0');
			dbg_d018_count_r     <= (others => '0');
			dbg_d018_bad_pc_r    <= (others => '0');
			dbg_d018_bad_count_r <= (others => '0');
			t65_pc_latch    <= (others => '0');
		else
			-- T65 PC tracking: latch cpuAddr_6510 on opcode fetch (Sync=1)
			-- AND when T65 is enabled. enableCpu_6510 = T65's CE pulse.
			if supercpu_en = '0' and enableCpu_6510 = '1' and t65_sync = '1' then
				t65_pc_latch <= cpuAddr_6510;
			end if;
			if cs_vic = '1' and cpuWe = '1' then
				if cpuAddr(5 downto 0) = "011000" then
					dbg_d018_r <= std_logic_vector(cpuDo);
					dbg_d018_last_pc_r <= dd00_pc_now;
					dbg_d018_count_r <= std_logic_vector(unsigned(dbg_d018_count_r) + 1);
					if std_logic_vector(cpuDo) /= x"18" then
						dbg_d018_bad_pc_r    <= dd00_pc_now;
						dbg_d018_bad_count_r <= std_logic_vector(unsigned(dbg_d018_bad_count_r) + 1);
					end if;
				elsif cpuAddr(5 downto 0) = "010110" then
					dbg_d016_r <= std_logic_vector(cpuDo);
				end if;
			end if;
			if cs_cia2 = '1' and cpuWe = '1' and cpuAddr(3 downto 0) = "0000" then
				dbg_dd00_r <= std_logic_vector(cpuDo);
				dbg_dd00_pc_r <= dd00_pc_now;
				case cpuDo(1 downto 0) is
					when "00"   =>
						dbg_dd00_pc_v0_r  <= dd00_pc_now;
						dbg_dd00_cnt_v0_r <= std_logic_vector(unsigned(dbg_dd00_cnt_v0_r) + 1);
					when "01"   =>
						dbg_dd00_pc_v1_r  <= dd00_pc_now;
						dbg_dd00_cnt_v1_r <= std_logic_vector(unsigned(dbg_dd00_cnt_v1_r) + 1);
					when "10"   =>
						dbg_dd00_pc_v2_r  <= dd00_pc_now;
						dbg_dd00_cnt_v2_r <= std_logic_vector(unsigned(dbg_dd00_cnt_v2_r) + 1);
					when others =>
						dbg_dd00_pc_v3_r  <= dd00_pc_now;
						dbg_dd00_cnt_v3_r <= std_logic_vector(unsigned(dbg_dd00_cnt_v3_r) + 1);
				end case;
				dbg_dd00_count_r <= std_logic_vector(unsigned(dbg_dd00_count_r) + 1);
			end if;
		end if;
	end if;
end process;

dbg_d018        <= dbg_d018_r;
dbg_d016        <= dbg_d016_r;
dbg_dd00        <= dbg_dd00_r;
dbg_raster_line <= std_logic_vector(dbg_raster_y);

dbg_cpu_pc_24   <= std_logic_vector(dbg_pbr_816_i) & std_logic_vector(dbg_pc_816_i)
                       when supercpu_en = '1'
                       else x"00" & std_logic_vector(cpuAddr_6510);

-- P/DBR overlay drivers: meaningful only when SCPU=on (P65C816 active).
-- When T65 active they read 0 — overlay viewer treats those as "not
-- applicable" since the T65 path doesn't have these registers anyway.
dbg_p   <= std_logic_vector(dbg_p_816_i)   when supercpu_en = '1' else x"00";
dbg_dbr <= std_logic_vector(dbg_dbr_816_i) when supercpu_en = '1' else x"00";

dbg_dd00_write_pc    <= dbg_dd00_pc_r;
dbg_dd00_write_count <= dbg_dd00_count_r;
dbg_dd00_pc_v0       <= dbg_dd00_pc_v0_r;
dbg_dd00_pc_v1       <= dbg_dd00_pc_v1_r;
dbg_dd00_pc_v2       <= dbg_dd00_pc_v2_r;
dbg_dd00_pc_v3       <= dbg_dd00_pc_v3_r;
dbg_dd00_cnt_v0      <= dbg_dd00_cnt_v0_r;
dbg_dd00_cnt_v1      <= dbg_dd00_cnt_v1_r;
dbg_dd00_cnt_v2      <= dbg_dd00_cnt_v2_r;
dbg_dd00_cnt_v3      <= dbg_dd00_cnt_v3_r;
dbg_d018_last_pc     <= dbg_d018_last_pc_r;
dbg_d018_count       <= dbg_d018_count_r;
dbg_d018_bad_pc      <= dbg_d018_bad_pc_r;
dbg_d018_bad_count   <= dbg_d018_bad_count_r;

-- Compose 24-bit "current PC" for $DD00 write capture: PBR:PC for SCPU,
-- $00:t65_pc_latch (last opcode-fetch address) for T65.
dd00_pc_now <= std_logic_vector(dbg_pbr_816_i) & std_logic_vector(dbg_pc_816_i)
               when supercpu_en = '1'
               else x"00" & std_logic_vector(t65_pc_latch);

end architecture;
