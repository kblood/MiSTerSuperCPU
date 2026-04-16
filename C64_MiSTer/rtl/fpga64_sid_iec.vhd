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
generic(
	-- Wraps all debug-only RTL (crash trace ring buffer, SuperRAM read-path
	-- latches, $0801 wipe trigger, dbg_bug_buf packing) behind a single
	-- compile-time gate. Matches the Verilog `DEBUG_ENABLE macro in c64.sv.
	-- Release builds (DEBUG_ENABLE=false) tie all debug outputs to zero and
	-- let synthesis remove the unused storage, recovering ~1.5-2.5k ALMs and
	-- restoring positive clk32 setup slack. DO NOT use separate values on
	-- the two sides — the build script keeps them in sync.
	DEBUG_ENABLE : boolean := true
);
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
	sdram_raw   : in  unsigned(7 downto 0);  -- raw SDRAM dout, bypasses cartridge module
	sdram_superram : in unsigned(7 downto 0);  -- SDRAM dout_reu: bt=1 latch, clk64-domain stable
	sdram_hi    : in  unsigned(7 downto 0);  -- high byte of SDRAM word (bt-independent)
	sdram_lo    : in  unsigned(7 downto 0);  -- low byte of SDRAM word (bt-independent)
	ramDout     : out unsigned(7 downto 0);
	ramCE       : out std_logic;
	ramWE       : out std_logic;

	io_cycle    : out std_logic;
	ext_cycle   : out std_logic;
	refresh     : out std_logic;

	cia_mode    : in  std_logic;
	turbo_mode  : in  std_logic_vector(1 downto 0);
	turbo_speed : in  std_logic_vector(1 downto 0);
	scpu_speed  : in  std_logic_vector(1 downto 0) := "00"; -- 00=max,01=4x,10=2x,11=1MHz
	supercpu_en : in  std_logic := '0';
	supercpu_rom : in  std_logic := '0'; -- '1' = SuperCPU kickstart ROM active
	bram_invalidate : in std_logic := '0'; -- pulse to clear all BRAM valid bits
	-- io_cycle write-through to BRAM: keeps BRAM coherent with SDRAM for
	-- ioctl PRG loads that write SDRAM via io_cycle (which bypasses CPU bus).
	io_bram_we   : in std_logic := '0';
	io_bram_addr : in unsigned(15 downto 0) := (others => '0');
	io_bram_din  : in unsigned(7 downto 0)  := (others => '0');
	-- $0801 write PC trap (post-download): captures PC/IR of CPU writes at $0801
	dbg_0801_trap_en : in std_logic := '0'; -- active when ioctl_download=0 && !inj_meminit
	dbg_0801_pc      : out unsigned(15 downto 0);
	dbg_0801_ir      : out unsigned(7 downto 0);
	dbg_0801_data_out: out unsigned(7 downto 0);
	dbg_0801_cnt     : out unsigned(7 downto 0);
	supercpu_emul : out std_logic;             -- '1' = 65C816 in 6502 emulation mode
	supercpu_cycle : out std_logic;            -- '1' during CPU SDRAM access slot
	supercpu_bank : out unsigned(7 downto 0);  -- current bank byte (A23-A16)
	cpu_has_bus   : out std_logic;             -- '1' when CPU owns the bus (not VIC)

	-- Debug outputs (active CPU's bus signals)
	dbg_cpu_addr  : out unsigned(15 downto 0);
	dbg_cpu_data  : out unsigned(7 downto 0);
	dbg_cpu_we    : out std_logic;
	dbg_cpu_en    : out std_logic;
	dbg_cpu_sp    : out unsigned(15 downto 0);
	dbg_cpu_p     : out unsigned(7 downto 0);
	dbg_cpu_ir    : out unsigned(7 downto 0);
	dbg_cpu_pbr   : out unsigned(7 downto 0);
	dbg_cpu_dbr   : out unsigned(7 downto 0);
	-- CIA1 keyboard scan diagnostic: PA/PB captured when CPU reads $DC01 and PB≠$FF
	dbg_cia1_pa   : out unsigned(7 downto 0);
	dbg_cia1_pb   : out unsigned(7 downto 0);
	-- Screen-RAM write detector: captures last CPU write to $0400-$07FF (for @ artifact debug)
	dbg_scr_wr_addr : out unsigned(15 downto 0);
	dbg_scr_wr_pc   : out unsigned(15 downto 0);
	dbg_scr_wr_data : out unsigned(7 downto 0);
	dbg_scr_wr_ir   : out unsigned(7 downto 0);
	dbg_scr_zero_hit: out std_logic;
	dbg_scr_wr_bank : out unsigned(7 downto 0);
	dbg_scr_arm     : out std_logic;
	-- VIC read-side capture
	dbg_vic_zero_hit : out std_logic;
	dbg_vic_zero_addr: out unsigned(15 downto 0);
	dbg_vic_zero_cpu : out unsigned(15 downto 0);
	dbg_vic_zero_sysaddr : out unsigned(15 downto 0);
	dbg_vic_wr_match : out std_logic;
	dbg_vic_wr_pc    : out unsigned(15 downto 0);
	dbg_vic_prearm_cnt : out unsigned(7 downto 0);
	dbg_vic_hit_cnt    : out unsigned(7 downto 0);
	dbg_vic_mode       : out unsigned(7 downto 0);
	dbg_vic_cpuf_zero_cnt : out unsigned(7 downto 0);
	dbg_vic_cpue_live_zero_cnt : out unsigned(7 downto 0);
	dbg_vic_cpue_hold_zero_cnt : out unsigned(7 downto 0);
	dbg_vic_cpue_mismatch_cnt  : out unsigned(7 downto 0);
	-- Turbo/cache diagnostic outputs
	dbg_turbo_en       : out std_logic;
	dbg_cache_hit_d1   : out std_logic;
	dbg_enable_cpu_t65 : out std_logic;
	dbg_cpu_cyc        : out std_logic;
	dbg_diag           : out unsigned(7 downto 0);
	-- Crash trace ring buffer (128 entries, 5 bytes each: PC_lo, PC_hi, PBR, IR, P)
	-- Packed layout (LSB first):
	--   [7:0]       = status: bit0=frozen, bits[7:1]=write_pos[6:0]
	--   [4103:8]    = 128 × (PC_lo, PC_hi, PBR, IR) = 128 × 32 = 4096 bits
	--   [5127:4104] = 128 × P = 128 × 8 = 1024 bits
	-- Read-paging: c64.sv exposes one 32-entry page at $DF21-$DFA0 + $DFC9-$DFE8
	-- (select page via CPU write to $DF1F, bits[1:0]).
	dbg_bug_buf        : out std_logic_vector(5127 downto 0);
	-- Native mode IRQ vector value ($FFEE/$FFEF from scpu_native_vec)
	dbg_native_irq_vec : out std_logic_vector(15 downto 0);
	-- SuperRAM read-path diagnostic latches (captured on every enableCpu pulse
	-- where superram_in_pipeline=1 and cpuWe_pre=0). Exposed at $DFE9-$DFEF.
	dbg_srr_count      : out unsigned(15 downto 0);
	dbg_srr_data       : out unsigned(7 downto 0);
	dbg_srr_addr_hi    : out unsigned(7 downto 0);
	dbg_srr_cache_bank : out unsigned(7 downto 0);
	dbg_srr_addr_lo    : out unsigned(7 downto 0);
	dbg_srr_addr_mid   : out unsigned(7 downto 0);

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
	IOF_raw		: out std_logic;  -- IOF without io_enable, for REU cpu_cs
	iof_detect_o: out std_logic;  -- combinational iof_detect (diagnostic)
	-- Latched-at-IOF values: cpu_we / cpu_addr / cpu_dout captured on the
	-- same clk32 edge that registers IOF_raw, so they're phase-aligned with
	-- IOF_raw at reu.v's edge detector. Without these, single-cycle CPU
	-- writes complete before IOF_raw rises and reu.v sees them as reads.
	iof_we_o    : out std_logic;
	iof_addr_o  : out unsigned(15 downto 0);
	iof_dout_o  : out unsigned(7 downto 0);
	iof_fall_pulse_o : out std_logic;  -- 1-cycle pulse at end of $DFxx access
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

	-- Debug BRAM probe: bank-$00 64KB BRAM readback for simulation/desktop harnesses.
	bram_probe_addr : in  unsigned(15 downto 0) := (others => '0');
	bram_probe_data : out unsigned(7 downto 0);

	cass_motor  : out std_logic;
	cass_write  : out std_logic;
	cass_sense  : in  std_logic;
	cass_read   : in  std_logic
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
signal buslogic_ramData : unsigned(7 downto 0);  -- muxed RAM data for buslogic (BRAM or SDRAM)

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
signal cpuDi_raw    : unsigned(7 downto 0);
signal cpuDo        : unsigned(7 downto 0);
signal cpuDo_pre    : unsigned(7 downto 0);
-- Latched at IOF_raw rising for phase-aligned writes to reu.v
signal iof_we_r         : std_logic := '0';
signal iof_addr_r       : unsigned(15 downto 0) := (others => '0');
signal iof_dout_r       : unsigned(7 downto 0)  := (others => '0');
signal iof_detect_d2    : std_logic := '0';  -- alias of iof_detect_d1
signal iof_fall_pulse_r : std_logic := '0';  -- 1-cycle pulse at end of $DFxx access
signal cpuIO        : unsigned(7 downto 0);

-- 65C816 CPU signals
signal cpuAddr_816  : unsigned(15 downto 0);
signal cpuDo_816    : unsigned(7 downto 0);
signal cpuWe_816    : std_logic;
signal cpuIO_816    : unsigned(7 downto 0);
signal nmi_ack_816  : std_logic;
signal addr_hi_816  : unsigned(7 downto 0);
signal emu_mode_816 : std_logic;
-- $D07E ROM-visibility register.
-- Reset = '1' (SuperCPU ROM at $E000-$FFFF, so $FFFC = $FC90 = kickstart entry).
-- Kickstart writes $00 to $D07E at $80F7: ROM-vis = cpuDo(7) = 0 → C64 KERNAL visible.
-- After this, "LDA $FFFC" in the kickstart reads $FCE2 (C64 KERNAL reset vector)
-- instead of $FC90, and the RTL trick boots the C64 KERNAL successfully.
signal scpu_rom_vis      : std_logic := '1';
signal supercpu_en_prev  : std_logic := '0';
-- In native mode bank $00, force HIRAM=0/LORAM=0 so CPU always sees RAM at
-- $8000-$FFFF (not KERNAL/BASIC ROM). Real SuperCPU SRAM serves all bank $00
-- reads regardless of $01. Keep CHAREN=1 so I/O at $D000-$DFFF still works.
signal scpu_bankswitch   : unsigned(2 downto 0);
-- SuperCPU speed control (real hardware: $D07A/$D07B = software, $D072/$D073 = system)
signal scpu_speed_1mhz   : std_logic := '0';  -- '1' = software-forced 1MHz ($D07A)
signal scpu_sys_1mhz     : std_logic := '0';  -- '1' = system-forced 1MHz ($D072)
-- SuperCPU register visibility ($D07E = enable, $D07F = disable)
signal scpu_regs_enabled : std_logic := '1';
-- Hardware enable: ANY write to $D07E sets this. Write to $D07F/$D07D clears it.
-- When hwenable=1 and bootmap=0, kernal shadow is active at $E000-$FFFF.
signal scpu_hwenable     : std_logic := '0';
-- Boot ROM map: '1' at reset (EPROM at $8000-$FFFF). Cleared by write to $D0B6,
-- set by write to $D0B7 (both require hwenable=1).
signal scpu_bootmap      : std_logic := '1';
-- Optimization mode (real hardware: $D074-$D077 select mirror range; no-op here)
signal scpu_optim_mode   : unsigned(1 downto 0) := "11"; -- 11=no optimization (default)
signal vpa_816      : std_logic;
signal vda_816      : std_logic;
signal dbg_pc_816   : unsigned(15 downto 0);
signal dbg_sp_816   : unsigned(15 downto 0);
signal dbg_p_816    : unsigned(7 downto 0);
signal dbg_ir_816   : unsigned(7 downto 0);
signal dbg_pbr_816  : unsigned(7 downto 0);
signal dbg_dbr_816  : unsigned(7 downto 0);

-- 6510 CPU signals (renamed from _pre for MUX clarity)
signal cpuAddr_6510 : unsigned(15 downto 0);
signal cpuDo_6510   : unsigned(7 downto 0);
signal cpuWe_6510   : std_logic;
signal cpuIO_6510   : unsigned(7 downto 0);
signal nmi_ack_6510 : std_logic;
signal io_data_i    : unsigned(7 downto 0);
signal ioe_i        : std_logic;
signal iof_i        : std_logic;
signal iof_raw_i    : std_logic;  -- IOF without io_enable gating (for REU)

-- CPU enable gating: only active CPU gets clock enable pulses
signal enableCpu_6510 : std_logic;
signal enableCpu_816  : std_logic;

signal io_enable    : std_logic;
signal cpu_cyc      : std_logic;
signal cpu_cyc_s    : std_logic_vector(1 downto 0);
signal turbo_m      : std_logic_vector(2 downto 0);

-- SuperRAM 3-stage pipeline: extra delay for turbo slot SDRAM reads.
-- VIC0 SDRAM data clobbers dout_r before 2-stage enableCpu fires.
-- Adding 1 extra cycle gives the SDRAM read more time to complete.
signal superram_enable_delay : std_logic := '0';
signal superram_in_pipeline  : std_logic := '0';  -- latched when cpu_cyc fires for SuperRAM
signal superram_data_r       : unsigned(7 downto 0);  -- latched SDRAM data for SuperRAM reads
-- SuperRAM read-path diagnostic latches (exposed at $DFE9-$DFEF via c64.sv)
signal dbg_srr_count_r     : unsigned(15 downto 0) := (others => '0');
signal dbg_srr_data_r      : unsigned(7 downto 0)  := (others => '0');
signal dbg_srr_addr_hi_r   : unsigned(7 downto 0)  := (others => '0');
signal dbg_srr_cache_bank_r: unsigned(7 downto 0)  := (others => '0');
signal dbg_srr_addr_lo_r   : unsigned(7 downto 0)  := (others => '0');
signal dbg_srr_addr_mid_r  : unsigned(7 downto 0)  := (others => '0');
-- (cpuDi_r removed: cpuDi goes directly to CPU, io_data_r handles I/O)
-- I/O pipeline signals
signal io_in_pipeline        : std_logic := '0';
signal io_data_r             : unsigned(7 downto 0) := (others => '1');
-- io_read_deliver removed: cpuDi mux now uses combinational (enableCpu AND io_in_pipeline)
signal iof_detect            : std_logic;  -- combinational IOF detect from cpuAddr_pre
signal iof_detect_d1         : std_logic := '0';  -- registered IOF detect (1-cycle delayed)
signal at_cpuc               : std_logic;
signal at_cpucd              : std_logic;
signal io_slowdown           : std_logic;  -- suppress turbo for I/O addresses ($D000-$DFFF bank $00)
signal phantom_enable        : std_logic := '0'; -- fast path for VDA=0,VPA=0 cycles

-- BRAM CPU cache signals (retained for cache path, active when bram64k not used)
signal cache_hit     : std_logic;
signal cache_di      : unsigned(7 downto 0);
signal cache_hit_d1  : std_logic := '0';
signal cache_same_line : std_logic;
signal cache_flush   : std_logic;
signal cache_flush_sw : std_logic := '0';  -- software-triggered flush via $D078
signal cache_flush_bank : std_logic := '0'; -- flush on C64 bank register change
signal bram_invalidate_d     : std_logic := '0';
signal bram_invalidate_pulse : std_logic;  -- 1-cycle pulse on rising edge of bram_invalidate
signal cache_flush_active : std_logic; -- debug: cache is flushing
signal cache_tag_match    : std_logic; -- debug: tag matches current address
-- Write buffer drain signals
signal wb_pending    : std_logic;
signal wb_addr       : unsigned(15 downto 0);
signal wb_data       : unsigned(7 downto 0);
signal wb_ack        : std_logic;
signal wb_drain_active : std_logic;
signal cache_fill_we   : std_logic;
signal cache_fill_data : unsigned(7 downto 0);  -- muxed fill source
-- 64KB dual-port BRAM signals (bank $00 fast RAM)
signal bram64k_en     : std_logic;  -- master enable for BRAM path
signal bram_do        : unsigned(7 downto 0);  -- Port A read output (CPU)
signal bram_vic_do    : unsigned(7 downto 0);  -- Port B read output (VIC)
signal bram_we        : std_logic;  -- Port A write enable (CPU source)
signal bram_valid_cycle : std_logic; -- '1' when bus cycle is valid (not phantom)
signal bram_din       : unsigned(7 downto 0);  -- Port A data input (muxed: write data or fill data)
-- Port A mux: io_cycle bank $00 writes override CPU-driven signals
signal bram_port_a_addr : unsigned(15 downto 0);
signal bram_port_a_din  : unsigned(7 downto 0);
signal bram_port_a_we   : std_logic;
signal bram_hit_d1    : std_logic := '0';  -- registered BRAM hit (with suppress)
-- Per-page valid (register-based, combinational read) for always-RAM regions.
-- 256 flags, one per 256-byte page. Works for $0000-$7FFF, $C000-$CFFF because
-- CPU writes fill these pages densely before reading.
signal bram_pgvalid       : std_logic_vector(255 downto 0) := (others => '0');
signal bram_page_valid    : std_logic;  -- combinational read of bram_pgvalid
-- Per-byte M10K valid for ROM regions ($8000-$9FFF, $A000-$BFFF, $E000-$FFFF).
-- These regions fill byte-by-byte from SDRAM reads; per-page would be unsafe.
-- M10K has 1-cycle read latency, so ROM hits need a 2-cycle pipeline.
signal bram_byte_valid    : std_logic;  -- M10K per-byte valid output (1-cycle latency)
signal bram_rom_region    : std_logic;  -- '1' when addr in possibly-ROM region
signal bram_hit_addr      : std_logic;  -- combinational: address+bank check (no valid)
signal bram_hit_ram       : std_logic;  -- combinational: always-RAM hit (with page valid)
signal bram_hit_native    : std_logic;  -- combinational: native mode hit for $8000-$FFFF (excl. I/O)
signal bram_hit_rom_pre   : std_logic;  -- combinational: ROM region address check
signal bram_hit_rom_pre_d1: std_logic := '0';  -- pipelined ROM hit check (aligned with M10K)
signal bram_suppress      : std_logic := '0';  -- extra suppress cycle for ROM region hits
signal bram_hit_was_rom   : std_logic := '0';  -- track if last hit was from ROM region
signal bram_valid_clearing : std_logic := '1';  -- clearing M10K valid in progress (start cleared)
signal bram_valid_clr_ctr  : unsigned(15 downto 0) := (others => '0');
signal bram_valid_a_addr   : unsigned(15 downto 0);
signal bram_valid_a_din    : std_logic;
signal bram_valid_we       : std_logic;
-- IEC auto-slowdown: force 1MHz during CIA2 accesses (IEC serial bus)
signal iec_slow_mode : std_logic := '0';
signal iec_slow_ctr  : unsigned(19 downto 0) := (others => '0');
signal scpu_rom_overlay : std_logic;  -- SCPU ROM BRAM active (data differs from SDRAM)
-- Native mode vector SRAM: writable registers for $FFE4-$FFEF and $FF00-$FF01.
-- On real SuperCPU, $E000-$FFFF is SRAM populated by kickstart. We only provide
-- the vector area + RTI/RTL handlers. Software (e.g. Doom) can write its own
-- IRQ handler address to $FFE6/$FFE7 and it will persist.
signal scpu_rom_stub_active : std_logic;
signal scpu_rom_stub_data   : unsigned(7 downto 0);
-- 14 writable bytes: $FF00, $FF01, $FFE4-$FFEF
-- Index: 0=$FF00, 1=$FF01, 2=$FFE4, 3=$FFE5, ..., 13=$FFEF
type native_vec_array is array(0 to 13) of unsigned(7 downto 0);
signal scpu_native_vec : native_vec_array;

-- Crash trace ring buffer (2026-04-12 expanded for Doom K:2D→K:00 diagnosis)
-- 32 entries × (PC[15:0], PBR[7:0], IR[7:0]) = 32 × 32 bits = 128 bytes total.
-- Captures one entry per instruction (gated by dbg_pc_816 change) so 32 entries
-- = 32 instructions of pre-trigger history.
--
-- TWO-PHASE TRIGGER:
--   Phase 1 (free-run): capture every PC change. Always.
--   Phase 2 (tentative): on PBR=$2D→$00 transition, STOP CAPTURING and arm
--     a timeout counter. The buffer now holds the K:2D context at the moment
--     of transition. If PBR returns to non-$00 before timeout → false alarm
--     (normal VIC IRQ), release and resume capturing. If timeout expires while
--     still in $00 → permanent freeze (crash confirmed).
--
-- Buffer is exposed via $DF20-$DFA0 in c64.sv.
constant TRACE_DEPTH : integer := 128;
type trace_pc_arr_t   is array(0 to TRACE_DEPTH-1) of unsigned(15 downto 0);
type trace_byte_arr_t is array(0 to TRACE_DEPTH-1) of unsigned(7 downto 0);
signal bug_pc         : trace_pc_arr_t   := (others => (others => '0'));
signal bug_pbr        : trace_byte_arr_t := (others => (others => '0'));
signal bug_ir_buf     : trace_byte_arr_t := (others => (others => '0'));
signal bug_p          : trace_byte_arr_t := (others => (others => '0'));
signal bug_wp         : unsigned(6 downto 0) := (others => '0');
signal bug_frozen     : std_logic := '0';
signal bug_armed      : std_logic := '0';                       -- tentative freeze active
signal bug_timeout    : unsigned(23 downto 0) := (others => '0');-- 24-bit timeout (~16M CPU-enable cycles)
signal brk_detect_r   : std_logic := '0'; -- registered: BRK opcode in non-$00 bank
signal bram_inval_d   : std_logic := '0'; -- 1-cycle delay of bram_invalidate for edge detect
signal trace_prev_pc  : unsigned(15 downto 0) := (others => '0');
signal trace_prev_pbr : unsigned(7 downto 0)  := (others => '0');
signal trace_prev_ir  : unsigned(7 downto 0)  := (others => '0');
signal trace_prev_p   : unsigned(7 downto 0)  := (others => '0');
signal seen_bank_2d   : std_logic := '0';
signal cache_cpu_bank   : unsigned(7 downto 0);  -- bank for cache: $00 for T65, addr_hi_816 for SuperCPU
signal cache_cpu_en     : std_logic;             -- enable for cache: from active CPU

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
-- CIA1 keyboard scan diagnostic
signal dbg_cia1_pa_r : unsigned(7 downto 0) := x"FF";
signal dbg_cia1_pb_r : unsigned(7 downto 0) := x"FF";
-- Screen-RAM write detector (latches last CPU write to $0400-$07FF)
signal dbg_0801_pc_r    : unsigned(15 downto 0) := (others => '0');
signal dbg_0801_ir_r    : unsigned(7 downto 0)  := (others => '0');
signal dbg_0801_data_r  : unsigned(7 downto 0)  := (others => '0');
signal dbg_0801_cnt_r   : unsigned(7 downto 0)  := (others => '0');
signal dbg_scr_wr_addr_r : unsigned(15 downto 0) := (others => '0');
signal dbg_scr_wr_pc_r   : unsigned(15 downto 0) := (others => '0');
signal dbg_scr_wr_data_r : unsigned(7 downto 0) := (others => '0');
signal dbg_scr_wr_ir_r   : unsigned(7 downto 0) := (others => '0');
signal dbg_scr_wr_bank_r : unsigned(7 downto 0) := (others => '0');
signal dbg_scr_wr_arm_r  : std_logic := '0';
signal dbg_scr_wr_arm_ctr: unsigned(24 downto 0) := (others => '0');
signal dbg_scr_zero_hit_r: std_logic := '0'; -- sticky: '1' once a $00 write to screen RAM is detected
-- VIC c-access capture: detects when VIC reads $00 screen code during badline.
-- Pipeline: CPUC CE → c-access address (VM & colCounter) → SDRAM data arrives
-- at CPUE.5 → still on bus at next VIC2 → VIC latches c-access data at VIC2.
signal dbg_vic_zero_hit_r : std_logic := '0'; -- sticky: '1' once VIC reads $00 screen code
signal dbg_vic_zero_addr_r: unsigned(15 downto 0) := (others => '0'); -- vicAddr at CPUC (c-access addr)
signal dbg_vic_zero_cpu_r : unsigned(15 downto 0) := (others => '0'); -- packed diagnostic data
signal dbg_vic_zero_sysaddr_r : unsigned(15 downto 0) := (others => '0'); -- full systemAddr at CPUC
signal dbg_vic_wr_match_r : std_logic := '0'; -- '1' if last captured CPU screen write addr matched VIC-hit addr
signal dbg_vic_wr_pc_r    : unsigned(15 downto 0) := (others => '0'); -- PC of matching last CPU write
signal dbg_vic_prearm_cnt_r : unsigned(7 downto 0) := (others => '0'); -- VIC $00 hits before arm
signal dbg_vic_hit_cnt_r    : unsigned(7 downto 0) := (others => '0'); -- VIC $00 hits after arm
signal dbg_vic_mode_r       : unsigned(7 downto 0) := (others => '0'); -- runtime VIC test mode ($D07B bits 1:0)
signal dbg_vic_cpuf_zero_cnt_r : unsigned(7 downto 0) := (others => '0'); -- CPUF live vicDi == 00
signal dbg_vic_cpue_live_zero_cnt_r : unsigned(7 downto 0) := (others => '0'); -- CPUE live vicDi == 00
signal dbg_vic_cpue_hold_zero_cnt_r : unsigned(7 downto 0) := (others => '0'); -- CPUE held data == 00
signal dbg_vic_cpue_mismatch_cnt_r  : unsigned(7 downto 0) := (others => '0'); -- CPUE live /= held
signal vic_ca_addr_lat    : unsigned(15 downto 0) := (others => '0'); -- latch vicAddr at CPUC
signal vic_ca_sysaddr16_lat : unsigned(15 downto 0) := (others => '0'); -- latch full systemAddr at CPUC
signal vic_ca_sysaddr_lat : unsigned(7 downto 0) := (others => '0'); -- latch systemAddr[7:0] at CPUC
signal vic_ca_has_bus_lat  : std_logic := '0'; -- latch cpuHasBus at CPUC
signal vic_ca_pending      : std_logic := '0'; -- '1' = CPUC latch valid, waiting for VIC2
signal vic_ca_data_lat     : unsigned(7 downto 0) := (others => '0'); -- c-access data captured at CPUF
signal vic_ca_data_valid   : std_logic := '0'; -- '1' = vic_ca_data_lat is valid for next VIC2 consume
signal vicDi_hold_or_live  : unsigned(7 downto 0);
signal vic_hold_gate       : std_logic;
signal vic_early_ce        : std_logic;
signal dbg_hold_fire_cnt_r     : unsigned(7 downto 0) := (others => '0'); -- $D070: hold gate activations
signal dbg_hold_mismatch_cnt_r : unsigned(7 downto 0) := (others => '0'); -- $D071: held /= live at CPUF
signal dbg_hold_held_zero_cnt_r : unsigned(7 downto 0) := (others => '0'); -- $D072: held data = $00 at CPUF
signal dbg_hold_live_zero_cnt_r : unsigned(7 downto 0) := (others => '0'); -- $D073: live vicDi = $00 at CPUF

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
		-- Refresh moved to VIC2 (well before DMA0) to avoid collision with
		-- REU DMA. SDRAM refresh takes 8 clk64 cycles (4 clk_sys). VIC2 is
		-- 10 clk_sys before DMA0 (20 clk64), giving plenty of clearance.
		if preCycle = sysCycleDef'pred(CYCLE_VIC3) and rfsh_cycle = "00" then
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
-- When BRAM is enabled and VIC has the bus, feed BRAM Port B data to buslogic.
-- This gives VIC zero-contention access to bank $00 RAM via BRAM.
-- When CPU has the bus or BRAM disabled, use normal SDRAM data (ramDin).
-- When BRAM is enabled and VIC has the bus, feed BRAM Port B data to buslogic.
-- BRAM is filled from SDRAM reads + CPU writes, so VIC always gets correct data.
-- 1-cycle M10K latency matches the registered SDRAM data path timing.
-- VIC always reads from BRAM when enabled (no valid check — same as SDRAM behavior
-- during boot: uninitialized data is progressively overwritten by KERNAL).
-- Valid bits only gate the CPU turbo path, not the VIC display path.
buslogic_ramData <= bram_vic_do when (bram64k_en = '1' and cpuHasBus = '0' and systemAddr(15) = '0')
              else  ramDin;

buslogic: entity work.fpga64_buslogic
port map (
	clk => clk32,
	reset => reset,
	bios => bios,

	cpuHasBus => cpuHasBus,
	aec => aec,

	bankSwitch => scpu_bankswitch,

	game => game,
	exrom => exrom,
	io_rom => io_rom,
	io_ext => io_ext or sid_sel_r,
	io_data => io_data_i,

	ramData => buslogic_ramData,

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
	cs_ioF_raw => iof_raw_i,
	cs_romL => romL,
	cs_romH => romH,
	cs_UMAXromH => UMAXromH,

	c64rom_addr => c64rom_addr,
	c64rom_data => c64rom_data,
	c64rom_wr => c64rom_wr,

	supercpu_en => supercpu_en,
	supercpu_rom => supercpu_rom,
	supercpu_rom_vis => scpu_rom_vis,
	supercpu_bank => std_logic_vector(addr_hi_816)
);

IOE <= ioe_i;
IOF <= iof_i;
-- Simple IOF detect from cpuAddr_pre (bypasses bus logic -10ns path).
iof_detect <= '1' when cpuAddr_pre(15 downto 8) = x"DF" and addr_hi_816 = x"00" else '0';
iof_detect_o <= iof_detect;  -- expose for c64.sv diagnostic counters
-- Register IOF_raw to eliminate timing violations from the combinational
-- cpuAddr_pre → iof_detect → IOF_raw path (-10ns slack).
-- NOTE: previously gated with phi0_cpu, but the 2-stage SDRAM enable pipeline
-- pushes enableCpu to CPUF, so the CPU's new $DFxx address only appears at
-- EXT0 of the next rotation — by which time phi0_cpu has already gone low.
-- The gate caused IOF_raw to never rise from 1MHz BASIC writes (verified
-- 2026-04-13: iof_det_cnt=12, iof_raw_cnt=0). cpuWe_pre is held stable
-- across phases by the CPU, so the original phi0_cpu concern (cpu_we=0 in
-- non-CPU phases) does not apply with the dbg_cpu_we wiring.
-- IOF_raw is the registered 1-cycle-delayed iof_detect (kept for the
-- existing diagnostic path in c64.sv). For reu.v write detection we use
-- iof_fall_pulse_r instead: a 1-cycle pulse that fires ONE cycle after
-- iof_detect goes low. By that time iof_we_r / iof_addr_r / iof_dout_r
-- reflect the LAST observed values during the access — for writes that
-- means cpuWe=1 was captured, for reads cpuWe=0. reu.v's edge detector
-- sees a clean rising edge with cpu_we settled.
process(clk32)
begin
	if rising_edge(clk32) then
		iof_detect_d2    <= iof_detect;  -- alias of iof_detect_d1
		IOF_raw          <= iof_detect;  -- 1-cycle delayed, used for diagnostics
		iof_fall_pulse_r <= iof_detect_d2 and not iof_detect; -- 1-cycle pulse at end of access
		if iof_detect = '1' then
			iof_we_r   <= cpuWe_pre;
			iof_addr_r <= cpuAddr_pre;
			iof_dout_r <= cpuDo_pre;
		end if;
	end if;
end process;
iof_we_o   <= iof_we_r;
iof_addr_o <= iof_addr_r;
iof_dout_o <= iof_dout_r;
iof_fall_pulse_o <= iof_fall_pulse_r;
at_cpuc <= '1' when sysCycle = CYCLE_CPUC else '0';
-- Suppress BRAM hits from CPUB through CPUD: prevents the BRAM hit from the
-- previous instruction's fetch from advancing the CPU at the same rotation
-- as cpu_cyc fires for the IOF read. 3-cycle window ensures cpuAddr_pre
-- has settled to $DFxx before the force re-entry check at CPUC.
-- 4-cycle BRAM suppression: CPUA through CPUD.
at_cpucd <= '1' when sysCycle = CYCLE_CPUA or sysCycle = CYCLE_CPUB
                  or sysCycle = CYCLE_CPUC or sysCycle = CYCLE_CPUD else '0';
cs_io <= cs_vic or cs_sid or cs_color or cs_cia1 or cs_cia2 or ioe_i or iof_i;

-- SuperCPU register overlay: intercept reads from $D07x and $D0Bx when SuperCPU enabled,
-- but only in bank $00 (VIC-II mirror space). High-bank ($F0-$FF) accesses serve ROM data
-- from the buslogic and must not be intercepted here.
-- Real SuperCPU register behavior (c64-wiki.com/wiki/SuperCPU):
--   $D07A/$D07B = write-only speed triggers (no read value)
--   $D074-$D077 = write-only optimization mode triggers
--   $D07E = ROM visibility (read: bit7=scpu_rom_vis; write: enable regs + set ROM vis)
--   $D07F = write-only register disable
--   $D0B0 = mode detect: $40 = SuperCPU v2 in C64 mode (gated by scpu_regs_enabled)
--   $D0B2 = hardware status: $00 (SIMM present) (gated by scpu_regs_enabled)
--   $D0B4 = optimization mode flags (gated by scpu_regs_enabled)
--   $D0B5 = JiffyDOS/speed switch: bit7=jiffy(0), bit6=speed_1mhz (gated)
--   $D0B6 = emulation mode: bit7=emu_mode (1=6502, 0=native 65816) (gated)
--   $D0B8 = speed status: bit7=sw_1mhz, bit6=combined_1mhz (gated)
--   $D0B2 = hardware status: bit7=hwenable, bit6=sys_1mhz
--   $D0BC = computed: bit7=dosext(0), bit6=ramlink(0), bits2:0=optim_low(111)
--   $D070-$D07F reads pass through to normal C64 I/O (not intercepted by SCPU)
-- BRAM/Cache data MUST be first: during non-CPU slots, cs_vic reflects VIC's address
-- (not CPU's). If VIC reads $D000-$D3FF, cs_vic='1' could falsely match a
-- SuperCPU register condition, injecting register values into CPU data stream.
-- BRAM data takes top priority when bram_hit_d1 drives the CPU enable.
-- Cache data is second priority when cache_hit_d1 drives (SuperRAM or non-BRAM mode).
-- SuperRAM SDRAM bypass: when enableCpu fires for a SuperRAM read, use ramDin
-- directly instead of buslogic output. The 3-stage pipeline delivers enableCpu
-- at CPUF, which is the same edge where cpuHasBus clears (phi0_cpu→0).
-- Due to delta cycle ordering, the CPU sees CE=1 at EXT0 (one cycle later),
-- when cpuHasBus=0 and buslogic routes VIC data instead of CPU data.
-- Bypassing buslogic with ramDin (which still holds the SuperRAM SDRAM result)
-- avoids this problem. This only applies to reads (cpuWe_pre='0') from
-- SuperRAM banks (superram_in_pipeline='1'). Bank $00 and ROM reads are
-- unaffected (use BRAM, cache, or normal buslogic path).
-- IOF reads: use io_data directly (registered in c64.sv, bypasses bus logic).
-- iof_detect is combinational from cpuAddr_pre — when the CPU addresses $DFxx,
-- io_data has reu_dout/cart_data captured during the CPU phase (cpuHasBus='1').
-- This replaces the complex 3-stage IOF pipeline which had timing alignment
-- issues between enableCpu and io_in_pipeline in turbo mode.
-- ROM stub: provide native mode vectors and RTI handler after boot.
-- On real SuperCPU, internal SRAM at $E000-$FFFF is populated by kickstart with
-- KERNAL copy + native vectors. Since we don't have that SRAM content, this stub
-- provides minimal vectors pointing to RTI at $FF00. Active whenever bootmap=0
-- (boot complete) regardless of hwenable — real SRAM vectors persist after $D07F.
-- Native mode bank $00 RAM override: handled in cpuDi mux, not bankSwitch.
-- bankSwitch passes through unchanged to avoid affecting buslogic/VIC.
scpu_bankswitch <= cpuIO(2 downto 0);

-- Excludes $FFF0-$FFFF (emulation mode vectors, served by C64 KERNAL/RAM normally).
scpu_rom_stub_active <= '1' when supercpu_en = '1' and scpu_bootmap = '0'
                        and emu_mode_816 = '0' and addr_hi_816 = x"00"
                        and cpuAddr_pre(15 downto 8) = x"FF" and cpuWe_pre = '0'
                        and (cpuAddr_pre(7 downto 0) = x"00"   -- $FF00: RTI handler
                          or cpuAddr_pre(7 downto 0) = x"01"   -- $FF01: RTL handler
                          or (cpuAddr_pre(7 downto 4) = x"E" and cpuAddr_pre(3 downto 2) /= "00"))  -- $FFE4-$FFEF
                        else '0';
-- Read from writable native vector registers (explicit index, no arithmetic)
scpu_rom_stub_data <= scpu_native_vec(0)  when cpuAddr_pre(7 downto 0) = x"00" else  -- $FF00
                      scpu_native_vec(1)  when cpuAddr_pre(7 downto 0) = x"01" else  -- $FF01
                      scpu_native_vec(2)  when cpuAddr_pre(7 downto 0) = x"E4" else  -- $FFE4
                      scpu_native_vec(3)  when cpuAddr_pre(7 downto 0) = x"E5" else
                      scpu_native_vec(4)  when cpuAddr_pre(7 downto 0) = x"E6" else
                      scpu_native_vec(5)  when cpuAddr_pre(7 downto 0) = x"E7" else
                      scpu_native_vec(6)  when cpuAddr_pre(7 downto 0) = x"E8" else
                      scpu_native_vec(7)  when cpuAddr_pre(7 downto 0) = x"E9" else
                      scpu_native_vec(8)  when cpuAddr_pre(7 downto 0) = x"EA" else
                      scpu_native_vec(9)  when cpuAddr_pre(7 downto 0) = x"EB" else
                      scpu_native_vec(10) when cpuAddr_pre(7 downto 0) = x"EC" else
                      scpu_native_vec(11) when cpuAddr_pre(7 downto 0) = x"ED" else
                      scpu_native_vec(12) when cpuAddr_pre(7 downto 0) = x"EE" else
                      scpu_native_vec(13) when cpuAddr_pre(7 downto 0) = x"EF" else
                      x"00";

cpuDi <= io_data when (iof_detect = '1' and cpuWe_pre = '0') else
         scpu_rom_stub_data when (scpu_rom_stub_active = '1') else
         bram_do  when (bram_hit_d1 = '1') else
         cache_di when (cache_hit_d1 = '1' and scpu_rom_overlay = '0') else
         sdram_superram when (enableCpu = '1' and superram_in_pipeline = '1' and cpuWe_pre = '0') else
         -- TODO: Native mode bank $00 RAM override for $8000-$FFFF (Doom needs this)
         -- SuperCPU $D0Bx registers: gated by scpu_regs_enabled (write $D07F to disable)
         -- $D0BC: computed from dosext(0), ramlink(0), optim low bits
         ("00000" & scpu_optim_mode & '1') when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0BC" and scpu_regs_enabled = '1') else
         x"40" when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B0" and scpu_regs_enabled = '1') else
         -- $D0B2: bit7=hwenable, bit6=sys_1mhz (VICE-verified)
         (scpu_hwenable & scpu_sys_1mhz & "000000") when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B2" and scpu_regs_enabled = '1') else
         -- $D0B8: bit7=software 1MHz, bit6=combined 1MHz (sw OR sys)
         (scpu_speed_1mhz & (scpu_speed_1mhz or scpu_sys_1mhz) & "000000") when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B8" and scpu_regs_enabled = '1') else
         ("000000" & scpu_optim_mode) when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B4" and scpu_regs_enabled = '1') else
         -- $D0B5: bit7=JiffyDOS(0), bit6=speed switch (VICE-verified)
         ("0" & scpu_speed_1mhz & "000000") when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B5" and scpu_regs_enabled = '1') else
         -- $D0B6: bit7=emulation mode (1=6502 emu, 0=native 65816)
         (emu_mode_816 & "0000000") when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"0B6" and scpu_regs_enabled = '1') else
         -- $D07E: bit7=ROM visibility (not gated by scpu_regs_enabled)
         (scpu_rom_vis & "0000000") when (supercpu_en = '1' and addr_hi_816 = x"00" and cs_vic = '1' and cpuAddr(11 downto 0) = x"07E") else
         cpuDi_raw;

-- I/O data capture: bypass the bus logic's dataToCpu path entirely.
-- Use io_ext and io_data DIRECTLY from the c64.sv ports (which are
-- REGISTERED in c64.sv, stable at capture time). This avoids the
-- -10ns timing-violated path through dataToCpu → cpuDi.
process(clk32)
begin
	if rising_edge(clk32) then
		-- Capture io_data at superram_enable_delay (1 cycle BEFORE enableCpu).
		-- In the 3-stage IOF pipeline: cpu_cyc(CPUC) → cpu_cyc_s → superram_enable_delay(CPUE) → enableCpu(CPUF).
		-- The CPU samples cpuDi when enableCpu_816 goes high (EXT0 edge, after CPUF).
		-- io_data_r must be valid BY that point, so we capture at CPUE (superram_enable_delay)
		-- giving one cycle for the register to settle before the CPU reads it.
		-- io_ext at CPUE is still valid: cpuHasBus='1' until CPUF, so c64_addr=$DFxx.
		if superram_enable_delay = '1' and io_in_pipeline = '1' and io_ext = '1' then
			io_data_r <= io_data;
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
-- Hold register DISABLED: early CE at CPU8 reads ZP data ($00/$04) not screen data.
-- Confirmed by diag counters: HZRO=FF (held=$00 always), LZRO=00 (live correct).
-- The hold register was injecting wrong data into VIC, making the artifact worse.
vic_hold_gate <= '0'; -- disabled

vicDi_hold_or_live <= vicDi; -- always use live data
vicDiAec <= vicBus when aec = '0' else vicDi_hold_or_live;
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
-- CPU enable gating: only active CPU receives clock enable pulses
-- This prevents bus contention when switching between 6510 and 65C816
-- -----------------------------------------------------------------------
-- T65 gets BRAM acceleration (when enabled) or cache acceleration.
-- BRAM hit (bram_hit_d1): 1-cycle suppress for always-RAM, 2-cycle for ROM regions.
-- Cache hit (cache_hit_d1) has 1-cycle suppress — used for SuperRAM or non-BRAM mode.
-- SDRAM enables (enableCpu) are OR'd in for SDRAM-path accesses.
-- Guards (not cpu_cyc_s, not enableCpu) prevent double-enables during SDRAM pipeline.
enableCpu_6510 <= (bram_hit_d1 or (cache_hit_d1 and turbo_en) or (enableCpu and not dma_active))
                  when supercpu_en = '0' else '0';
-- SuperCPU (P65C816): BRAM acceleration + SDRAM path.
-- BRAM hit covers 32KB ($0000-$7FFF) always + 28KB ($8000-$FFFF excl I/O) in native mode.
-- SDRAM path handles SuperRAM (banks $01-$EF) and I/O.
-- Suppress BRAM/cache hits at CPUC: at this bus cycle, cpu_cyc may fire
-- for an I/O read. If a BRAM hit from the previous instruction also fires,
-- the CPU races past the I/O address before the pipeline can capture data.
-- sysCycle is registered — no timing issues (unlike cpu_cyc/cs_ram).
--
-- I/O slow-down: When the CPU addresses $D000-$DFFF in bank $00, suppress
-- turbo enables so the access waits for the 1MHz CPU slot (phi0_cpu='1').
-- Real SuperCPU hardware stalls the 20MHz CPU for I/O access, ensuring
-- VIC/SID/CIA writes/reads go through the C64 bus at 1MHz.
-- Without this, turbo-mode VIC writes are silently dropped (phi0_cpu='0').
-- Only slow down WRITES to I/O (VIC write gate needs phi0_cpu='1').
-- Reads from I/O registers work at turbo speed (data always on bus).
-- Also require VDA=1, VPA=0 to avoid slowing instruction fetches or phantom cycles.
io_slowdown <= '1' when cpuAddr_pre(15 downto 12) = x"D"
                     and addr_hi_816 = x"00"
                     and supercpu_en = '1'
                     and cpuWe_pre = '1'
                     and vpa_816 = '0'
                     and vda_816 = '1'
               else '0';

enableCpu_816  <= ((bram_hit_d1 and turbo_en and not at_cpucd and not io_slowdown) or
                   (cache_hit_d1 and turbo_en and not at_cpucd and not io_slowdown) or
                   (phantom_enable and turbo_en and not at_cpucd) or
                   (enableCpu and not dma_active))
                  when supercpu_en = '1' else '0';

-- -----------------------------------------------------------------------
-- 6510 CPU (active when supercpu_en = '0')
-- -----------------------------------------------------------------------
cpu_6510_inst: entity work.cpu_6510
port map (
	clk => clk32,
	reset => reset or supercpu_en,
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
	doIO => cpuIO_6510
);

-- -----------------------------------------------------------------------
-- 65C816 CPU (active when supercpu_en = '1')
-- -----------------------------------------------------------------------
cpu_816_inst: entity work.cpu_65c816
port map (
	clk => clk32,
	reset => reset or not supercpu_en,
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

	addr_hi => addr_hi_816,
	emulation_mode => emu_mode_816,
	vpa => vpa_816,
	vda => vda_816,

	dbg_pc => dbg_pc_816,
	dbg_sp => dbg_sp_816,
	dbg_p  => dbg_p_816,
	dbg_ir => dbg_ir_816,
	dbg_pbr => dbg_pbr_816,
	dbg_dbr => dbg_dbr_816,
	dbg_state => open
);

-- -----------------------------------------------------------------------
-- CPU MUX: select active CPU based on supercpu_en
-- -----------------------------------------------------------------------
cpuAddr_pre <= cpuAddr_816  when supercpu_en = '1' else cpuAddr_6510;
cpuDo_pre   <= cpuDo_816    when supercpu_en = '1' else cpuDo_6510;
-- FIX: Gate P65C816 WE with baLoc to prevent frozen write-enable during
-- badline halts.  T65 completes writes via really_rdy, then halts on a
-- read (cpuWe='0').  P65C816 halts immediately — its WE can freeze at '1'
-- (write), which tricks cpuHasBus into granting the bus during badlines,
-- causing systemAddr = cpuAddr instead of vicAddr → VIC reads wrong data.
-- Gating with baLoc: when BA is low the CPU is halted, so suppress WE.
cpuWe_pre   <= (cpuWe_816 and baLoc) when supercpu_en = '1' else cpuWe_6510;
cpuIO       <= cpuIO_816    when supercpu_en = '1' else cpuIO_6510;
nmi_ack     <= nmi_ack_816  when supercpu_en = '1' else nmi_ack_6510;

-- -----------------------------------------------------------------------
-- BRAM CPU cache: 8KB direct-mapped with write-through (Phase 2)
-- Accelerates RAM reads and writes to up to 32MHz by serving from BRAM.
-- Writes update cache immediately and queue to SDRAM via write buffer.
-- I/O accesses ($D000-$DFFF) always bypass cache and use the CPUC slot at 1MHz.
-- -----------------------------------------------------------------------
-- Route correct bank and enable to cache based on active CPU mode
cache_cpu_bank <= addr_hi_816 when supercpu_en = '1' else x"00";  -- T65 always bank $00
cache_cpu_en   <= enableCpu_816 when supercpu_en = '1' else enableCpu_6510;

cache_inst: entity work.cpu_cache
port map (
	clk       => clk32,
	reset     => reset,
	enable    => supercpu_en or turbo_en,  -- Phase 3: cache active for T65 turbo too
	cpu_addr  => cpuAddr_pre,
	cpu_bank  => cache_cpu_bank,
	cpu_we    => cpuWe_pre,
	cpu_do    => cpuDo_pre,
	cache_di  => cache_di,
	cache_hit => cache_hit,
	fill_data => cache_fill_data,
	fill_we   => cache_fill_we,
	fill_addr => cpuAddr_pre,
	fill_bank => cache_cpu_bank,
	wb_pending => wb_pending,
	wb_addr    => wb_addr,
	wb_data    => wb_data,
	wb_ack     => wb_ack,
	flush     => cache_flush,
	cpu_en    => cache_cpu_en,
	same_line => cache_same_line,
	dbg_flush_active => cache_flush_active,
	dbg_tag_match    => cache_tag_match
);

-- Flush cache on C64 memory map changes: bank register ($0001), EXROM, or GAME
-- changes invalidate cached data that may now be wrong (ROM/RAM/cartridge aliasing).
process(clk32)
	variable map_key     : std_logic_vector(4 downto 0);
	variable map_key_prev : std_logic_vector(4 downto 0) := "11111";
begin
	if rising_edge(clk32) then
		cache_flush_bank <= '0';
		map_key := std_logic_vector(cpuIO(2 downto 0)) & game & exrom;
		if map_key /= map_key_prev then
			cache_flush_bank <= '1';
		end if;
		map_key_prev := map_key;
	end if;
end process;

-- bram_invalidate arrives as a LEVEL held high for the entire ioctl_download +
-- inj_meminit window. Folding the level directly into cache_flush made the
-- cpu_cache flush state machine re-enter the 1024-cycle sweep continuously
-- for the full window (50-500 ms), which starved the CPU cache and slowed
-- BASIC cold boot so much that NEW ($A644) ran AFTER meminit ended — wiping
-- the just-loaded $0801/$0802 link bytes. Generate a 1-cycle pulse at the
-- rising edge so cache_flush triggers exactly one sweep per PRG load window.
process(clk32)
begin
	if rising_edge(clk32) then
		bram_invalidate_d <= bram_invalidate;
	end if;
end process;
bram_invalidate_pulse <= bram_invalidate and not bram_invalidate_d;

cache_flush <= reset or dma_active or cache_flush_sw or cache_flush_bank or bram_invalidate_pulse;

-- SCPU ROM overlay: when active, BRAM serves different data than SDRAM.
-- Cache fills from SDRAM, so cached data would be WRONG (C64 KERNAL/BASIC
-- instead of SCPU ROM). Suppress cache hits AND fills during overlay.
-- Gate by supercpu_en: ROM overlay only applies in SuperCPU mode.
-- In T65 mode, scpu_rom_vis is never cleared (no $D07E write), so without
-- the supercpu_en gate, having the ROM OSD option enabled would completely
-- block cache fills, cache_hit_d1, and the cpuDi cache_di mux.
scpu_rom_overlay <= supercpu_rom and scpu_rom_vis and supercpu_en;

-- Gate fill_we: don't fill cache during write buffer drain or SCPU ROM overlay.
-- Don't fill during CPU writes (SDRAM is being written, ramDin is stale).
-- Gate fill on baLoc: during badlines (baLoc='0'), cpuHasBus='0' so buslogic
-- outputs VIC data (not CPU data) on cpuDi_raw. Filling the cache with VIC
-- garbage corrupts cached bytes, causing wrong data on subsequent reads.
-- SuperRAM cache fill is suppressed (superram_in_pipeline guard in cache_fill_we).
-- Bank $00 fills from cpuDi_raw (buslogic output).
-- BISECT 2026-04-08: SuperRAM cache fills (commit 36c135c) caused 4-byte
-- instructions ($AF/$8F/$5C) to crash CPU when fetched from BRAM. Reverting
-- the SuperRAM fill enable until root cause understood.
cache_fill_data <= cpuDi_raw;
-- Gate cache fills during bram_invalidate: during ioctl PRG download +
-- inj_meminit, CPU cold-start reads could fill the cache with pre-load
-- (RAMTAS-zero) bytes that survive post-load. Per docs/prg_loading_debug_
-- without_hardware.md.
cache_fill_we <= enableCpu and not wb_drain_active and not cpuWe_pre
                 and bram_valid_cycle
                 and not scpu_rom_overlay
                 and not superram_in_pipeline
                 and not bram_invalidate
                 and baLoc;

-- Cache hit pipeline: allow hits during non-CPU slots + idle CPU slots.
-- The 1-cycle suppress after each hit accounts for M10K BRAM read latency.
--
-- SDRAM pipeline guard: cpu_cyc_s is the 2-stage pipeline that delivers
-- enableCpu. When cpu_cyc fires, the SDRAM reads the CPU's current address.
-- If cache_hit_d1 fires before enableCpu delivers that data, the CPU advances
-- and the SDRAM data becomes stale. Block cache_hit_d1 while either pipeline
-- stage is non-zero so the CPU waits for the SDRAM path.
process(clk32)
begin
	if rising_edge(clk32) then
		if cache_hit_d1 = '1' then
			-- Suppress for 1 cycle after cache hit (M10K read latency for new line).
			-- Wide cache lines (64-bit) make same-line data available immediately
			-- via the byte-select MUX, but skipping suppress crashes the CPU.
			-- Root cause: likely a timing race between combinational cache_di and
			-- the CPU's registered data latch. Needs simulation or SignalTap to
			-- diagnose. The wide line infrastructure remains for future use.
			cache_hit_d1 <= '0';
		elsif (sysCycle >= CYCLE_DMA0 and sysCycle <= CYCLE_VIC3) then
			-- Block cache hits during DMA/VIC slots (bus masters need SDRAM).
			cache_hit_d1 <= '0';
		elsif (sysCycle >= CYCLE_CPU0 and cpu_cyc = '0')
		   or (sysCycle >= CYCLE_CPU0 and wb_drain_active = '1') then
			-- CPU phase: evaluate cache hit (original behavior).
			-- Suppress for writes: writes MUST go through SDRAM (enableCpu) so
			-- that both SDRAM and BRAM receive the data.
			cache_hit_d1 <= cache_hit and not dma_active and baLoc
			                and bram_valid_cycle
			                and not cpuWe_pre
			                and not scpu_speed_1mhz
			                and not scpu_sys_1mhz
			                and not scpu_rom_overlay
			                and not iec_slow_mode
			                and not cpu_cyc_s(0)
			                and not cpu_cyc_s(1)
			                and not superram_enable_delay
			                and not enableCpu;
		elsif (sysCycle <= CYCLE_EXT3 or (sysCycle >= CYCLE_EXT4 and sysCycle <= CYCLE_EXT7))
		  and turbo_en = '1' then
			-- EXT phase: allow cache hits during EXT slots for turbo acceleration.
			-- These 8 slots are unused by other bus masters (VIC, DMA) and give
			-- up to 8 extra cache hit opportunities per rotation.
			cache_hit_d1 <= cache_hit and not dma_active and baLoc
			                and bram_valid_cycle
			                and not cpuWe_pre
			                and not scpu_speed_1mhz
			                and not scpu_sys_1mhz
			                and not scpu_rom_overlay
			                and not iec_slow_mode
			                and not cpu_cyc_s(0)
			                and not cpu_cyc_s(1)
			                and not superram_enable_delay
			                and not enableCpu;
		else
			cache_hit_d1 <= '0';
		end if;
	end if;
end process;

-- -----------------------------------------------------------------------
-- 64KB Dual-Port BRAM (bank $00 fast RAM)
-- Port A: CPU read/write (full speed, 1-cycle registered read)
-- Port B: VIC-II read (independent, zero contention)
-- Replaces cache for bank $00: 100% hit rate, no suppress penalty.
-- -----------------------------------------------------------------------
bram64k_en <= '1';  -- TEMP: enabled for isolation testing

-- BRAM data input mux: CPU write data, cache fill, or SDRAM read fill
-- Priority: 1. CPU writes (cpuDo_pre), 2. Cache hits (cache_di), 3. SDRAM fills (cpuDi_raw)
-- Cache fill: when cache_hit_d1='1', cache_di has the correct data for cpuAddr_pre.
-- Writing it to BRAM keeps BRAM coherent with cache, so VIC sees correct data.
bram_din <= cpuDo_pre when cpuWe_pre = '1'
       else cache_di  when cache_hit_d1 = '1'
       else cpuDi_raw;

-- Port A address/din/we muxing: when io_bram_we is asserted (io_cycle writing
-- to bank $00 from HPS ioctl path), override the CPU-driven signals so the
-- byte lands in BRAM. io_cycle phases run while CPU is halted so there is
-- no contention with CPU accesses. Correctness: without this, io_cycle PRG
-- loads leave BRAM stale with pre-load (RAMTAS zero) bytes while SDRAM has
-- the real PRG data, so CPU reads return zeros for every byte beyond the
-- first miss-fill.
bram_port_a_addr <= io_bram_addr when io_bram_we = '1' else cpuAddr_pre;
bram_port_a_din  <= io_bram_din  when io_bram_we = '1' else bram_din;
bram_port_a_we   <= io_bram_we or bram_we;

ram64k_inst: entity work.c64_ram64k
port map (
	clk    => clk32,
	-- Port A: CPU (or io_cycle write-through)
	a_addr => bram_port_a_addr,
	a_din  => bram_port_a_din,
	a_dout => bram_do,
	a_we   => bram_port_a_we,
	-- Port B: VIC-II (read only)
	b_addr => systemAddr,
	b_dout => bram_vic_do,
	-- Debug probe
	probe_addr => bram_probe_addr,
	probe_dout => bram_probe_data
);

-- BRAM write enable: CPU writes + SDRAM read fill + cache hit fill
-- Covers $0000-$FFFF (64KB): full bank $00 address space.
-- In native mode, $8000-$FFFF acts as SRAM shadow (like real SuperCPU).
-- In emulation mode, $8000-$FFFF BRAM is written but reads go through buslogic.
-- 1. CPU writes: write-through to BRAM (keeps BRAM coherent with SDRAM)
-- 2. SDRAM read fills: cpuDi_raw from buslogic (correct data for current config)
-- 3. Cache hit fills: cache_di from 8KB cache (keeps BRAM coherent when cache
--    serves data instead of SDRAM, so VIC sees correct data on Port B)
-- Read fills require cpuHasBus='1': during badlines (cpuHasBus='0'),
-- systemAddr=vicAddr so cpuDi_raw contains VIC data, not CPU data.
-- Valid bus cycle: P65C816 phantom cycles (VDA=0, VPA=0) have invalid
-- address/data/WE on the bus. Without this guard, phantom writes corrupt
-- random BRAM locations causing brown-screen garbage after reset.
-- T65 has no phantom cycles, so the gate is always '1' in T65 mode.
bram_valid_cycle <= (vda_816 or vpa_816) when supercpu_en = '1' else '1';

bram_we <= '1' when bram64k_en = '1'
                and cache_cpu_bank = x"00"
                and bram_valid_cycle = '1'
                and (
                    -- CPU write: store write data to BRAM
                    (cpuWe_pre = '1' and (enableCpu = '1' or bram_hit_d1 = '1'))
                    -- SDRAM read fill: store cpuDi_raw to BRAM
                    -- Guard: cpuHasBus ensures buslogic resolved for CPU, not VIC
                    or (cpuWe_pre = '0' and enableCpu = '1' and cpuHasBus = '1')
                    -- Cache hit fill: write cache_di to BRAM so VIC Port B is coherent
                    or (cpuWe_pre = '0' and cache_hit_d1 = '1')
                )
           else '0';

-- Per-byte M10K valid tracking REMOVED to save ~7 M10K blocks.
-- At 95% RAM block utilization, the fitter cannot place M10K correctly.
-- ROM region BRAM hits (bram_hit_rom_pre) are already disabled, so
-- bram_byte_valid is unused. Stub outputs to prevent synthesis errors.
bram_byte_valid <= '0';
bram_valid_a_addr <= (others => '0');
bram_valid_a_din  <= '0';
bram_valid_we     <= '0';

-- Clearing counter: sweeps all 64K entries on reset/invalidation/bank change.
-- 64K cycles at 32MHz = ~2ms. During clearing, ROM region BRAM hits are suppressed.
process(clk32)
begin
	if rising_edge(clk32) then
		if reset = '1' or bram_invalidate = '1' or cache_flush_bank = '1' or cache_flush_sw = '1' then
			bram_valid_clearing <= '1';
			bram_valid_clr_ctr <= (others => '0');
		elsif bram_valid_clearing = '1' then
			if bram_valid_clr_ctr = x"FFFF" then
				bram_valid_clearing <= '0';
			else
				bram_valid_clr_ctr <= bram_valid_clr_ctr + 1;
			end if;
		end if;
	end if;
end process;

-- Per-page valid tracking: 256 registers (all 256 pages for $0000-$FFFF).
-- Combinational read = zero latency. Pages 128-255 ($8000-$FFFF) are set
-- when CPU writes or SDRAM read fills occur (emulation mode fills with ROM data,
-- native mode fills with SRAM shadow data).
-- Cleared on reset/invalidation (NOT on bank change — bank $00 is bank-invariant).
process(clk32)
begin
	if rising_edge(clk32) then
		if reset = '1' or bram_invalidate = '1' or dma_active = '1' or cache_flush_sw = '1' then
			-- DMA writes bypass BRAM, so invalidate all pages when DMA is active
			-- to prevent bram_hit_d1 from serving stale data after DMA completes.
			-- cache_flush_sw ($D078 write) also clears BRAM pages so that
			-- externally-loaded code (mbc load_rom) isn't masked by stale BRAM.
			bram_pgvalid <= (others => '0');
		elsif io_bram_we = '1' then
			-- io_cycle write-through: mark the page valid so CPU reads hit BRAM
			-- with the just-written byte rather than stale pre-load data.
			bram_pgvalid(to_integer(unsigned(std_logic_vector(io_bram_addr(15 downto 8))))) <= '1';
		elsif bram_we = '1' then
			bram_pgvalid(to_integer(unsigned(std_logic_vector(cpuAddr_pre(15 downto 8))))) <= '1';
		end if;
	end if;
end process;

-- Combinational read: page valid for current CPU address (no latency!)
bram_page_valid <= bram_pgvalid(to_integer(unsigned(std_logic_vector(cpuAddr_pre(15 downto 8)))));

-- ROM region detection: disabled (BRAM hit for upper half gated by native mode)
bram_rom_region <= '0';

-- Base address check: bank $00, $0000-$7FFF, read access, no ROM overlay
-- This covers the always-available lower half (both emulation and native mode).
bram_hit_addr <= '1' when bram64k_en = '1'
                      and cache_cpu_bank = x"00"
                      and cpuAddr_pre(15) = '0'  -- $0000-$7FFF only
                      and cpuWe_pre = '0'
                      and scpu_rom_overlay = '0'
                else '0';

-- Native mode BRAM hit: $8000-$FFFF in bank $00, native mode only.
-- Excludes $D000-$DFFF (I/O region — always served by buslogic).
-- In native mode, real SuperCPU has 128KB SRAM for all of bank $00/$01.
-- BRAM acts as this SRAM shadow, filled from buslogic reads during emulation
-- mode (KERNAL/BASIC ROM data cached) and updated by CPU writes.
bram_hit_native <= '1' when bram64k_en = '1'
                        and cache_cpu_bank = x"00"
                        and cpuAddr_pre(15) = '1'         -- $8000-$FFFF
                        and cpuAddr_pre(15 downto 12) /= x"D"  -- exclude I/O $D000-$DFFF
                        and emu_mode_816 = '0'             -- native mode only
                        and cpuWe_pre = '0'
                        and scpu_rom_overlay = '0'
                        and bram_page_valid = '1'
                   else '0';

-- BRAM CPU read path: per-page valid gated by DMA coherency.
-- DMA invalidates all pages (bram_pgvalid cleared when dma_active='1'),
-- so stale data from DMA writes is never served. RAMTAS coarseness is
-- benign: M10K initializes to 0, matching SDRAM init for untouched bytes.
-- After KERNAL boot, all actively-used pages are naturally filled via
-- SDRAM reads (bram_we) and marked valid.
bram_hit_ram <= bram_hit_addr and not bram_rom_region and bram_page_valid;

-- ROM region pre-hit: needs M10K valid pipeline (slow path, 3 clocks/byte)
bram_hit_rom_pre <= '0';  -- TEMP: disabled for debugging
-- bram_hit_rom_pre <= bram_hit_addr and bram_rom_region and not bram_valid_clearing;

-- Hybrid BRAM hit pipeline:
-- Always-RAM ($0000-$7FFF, $C000-$CFFF): per-page valid (combinational) → 1-cycle suppress.
-- ROM regions ($8000-$9FFF, $A000-$BFFF, $E000-$FFFF): per-byte M10K valid (1-cycle
-- latency) → 2-cycle suppress (1 for M10K data + 1 for pipeline catch-up).
process(clk32)
begin
	if rising_edge(clk32) then
		-- Pipeline stage: align ROM pre-hit with M10K valid output
		bram_hit_rom_pre_d1 <= bram_hit_rom_pre;

		if bram_hit_d1 = '1' then
			-- Suppress cycle 1 (always needed: M10K data latency)
			bram_hit_d1 <= '0';
			bram_suppress <= bram_hit_was_rom;  -- ROM needs extra suppress
		elsif bram_suppress = '1' then
			-- Suppress cycle 2 (ROM-only: pipeline catch-up with new address)
			bram_hit_d1 <= '0';
			bram_suppress <= '0';
		elsif bram64k_en = '1'
		   and dma_active = '0' and baLoc = '1'
		   and scpu_speed_1mhz = '0'
		   and scpu_sys_1mhz = '0'
		   and iec_slow_mode = '0'
		   and cpu_cyc = '0'
		   and cpu_cyc_s(0) = '0'
		   and cpu_cyc_s(1) = '0'
		   and superram_enable_delay = '0'  -- 3-stage pipeline guard
		   and enableCpu = '0'
		then
			if (bram_hit_ram = '1' or bram_hit_native = '1') then
				-- Always-RAM or native mode upper half: page valid confirmed (combinational)
				bram_hit_d1 <= '1';
				bram_hit_was_rom <= '0';
			elsif bram_hit_rom_pre_d1 = '1' and bram_byte_valid = '1' then
				-- ROM region: per-byte valid confirmed (M10K pipelined)
				bram_hit_d1 <= '1';
				bram_hit_was_rom <= '1';
			else
				bram_hit_d1 <= '0';
			end if;
		else
			bram_hit_d1 <= '0';
		end if;
	end if;
end process;

-- -----------------------------------------------------------------------
-- Phantom cycle fast path (VDA=0, VPA=0)
-- 65C816 internal operations (register updates, address calculations) output
-- VDA=0, VPA=0 on the bus. These cycles don't access memory and just need a
-- clock enable to advance. Without this bypass, phantom cycles with non-$00
-- bank bytes (e.g., MVN destination bank) wait for the full SDRAM pipeline
-- (~32+ clk32 cycles at CPUC). The bypass generates an immediate enable,
-- eliminating 2 wasted SDRAM round-trips per MVN/MVP iteration.
-- Guards: no SDRAM pipeline in flight, no pending enable, turbo mode active.
-- -----------------------------------------------------------------------
process(clk32)
begin
	if rising_edge(clk32) then
		if phantom_enable = '1' then
			-- 1-cycle suppress (like BRAM/cache hit suppress)
			phantom_enable <= '0';
		elsif supercpu_en = '1'
		   and bram_valid_cycle = '0'   -- VDA=0 AND VPA=0
		   and turbo_en = '1'
		   and cpu_cyc = '0'
		   and cpu_cyc_s(0) = '0'
		   and cpu_cyc_s(1) = '0'
		   and superram_enable_delay = '0'
		   and enableCpu = '0'
		   and dma_active = '0'
		   and baLoc = '1'
		then
			phantom_enable <= '1';
		else
			phantom_enable <= '0';
		end if;
	end if;
end process;

-- Route 65C816-specific status signals to ports
supercpu_emul <= emu_mode_816;
-- Only assert banked SDRAM addressing during actual CPU RAM/ROM bus ownership.
supercpu_cycle <= cpu_cyc and cs_ram and cpuHasBus when supercpu_en = '1' else '0';
supercpu_bank <= addr_hi_816;
cpu_has_bus   <= cpuHasBus;

-- Debug outputs: dbg_cpu_addr feeds the SDRAM address path (scpu_superram_addr).
-- NEVER override it with latched/debug values — that breaks all SuperRAM reads.
dbg_cpu_addr <= cpuAddr_pre;
dbg_cpu_data <= cpuDo_pre;
dbg_cpu_we   <= cpuWe_pre;
dbg_cpu_en   <= enableCpu_816 when supercpu_en = '1' else enableCpu_6510;
-- Turbo/cache diagnostics (active signals for per-frame counting in overlay)
dbg_turbo_en       <= turbo_en;
dbg_cache_hit_d1   <= cache_hit_d1 or bram_hit_d1;
dbg_enable_cpu_t65 <= enableCpu_816 when supercpu_en = '1' else enableCpu_6510;
dbg_cpu_cyc        <= cpu_cyc; -- count cpu_cyc pulses per frame
-- Diagnostic byte: bit0=turbo_en, bit1=scpu_rom_vis, bit2=scpu_speed_1mhz,
-- bit3=iec_slow_mode, bit4=scpu_rom_overlay, bit5=cache_hit, bit6=enableCpu,
-- bit7=dma_active (was 0)
dbg_diag <= dma_active & enableCpu & cache_hit & scpu_rom_overlay & iec_slow_mode
            & scpu_speed_1mhz & scpu_rom_vis & turbo_en;
dbg_cpu_sp   <= dbg_sp_816 when supercpu_en = '1' else x"0000";
dbg_cpu_p    <= dbg_p_816  when supercpu_en = '1' else x"00";
dbg_cpu_ir   <= dbg_ir_816 when supercpu_en = '1' else x"00";
dbg_cpu_pbr  <= dbg_pbr_816 when supercpu_en = '1' else x"00";
dbg_cpu_dbr  <= dbg_dbr_816 when supercpu_en = '1' else x"00";

-- SuperRAM read-path diagnostics exposed to c64.sv
-- DEBUG_ENABLE=false ties them to zero; synthesis removes the latch process.
gen_srr_debug: if DEBUG_ENABLE generate
	dbg_srr_count      <= dbg_srr_count_r;
	dbg_srr_data       <= dbg_srr_data_r;
	dbg_srr_addr_hi    <= dbg_srr_addr_hi_r;
	dbg_srr_cache_bank <= dbg_srr_cache_bank_r;
	dbg_srr_addr_lo    <= dbg_srr_addr_lo_r;
	dbg_srr_addr_mid   <= dbg_srr_addr_mid_r;

	-- SuperRAM read-path capture: latch addr_hi_816/cache_cpu_bank/sdram_superram
	-- at the exact moment the CPU receives a SuperRAM read byte on cpuDi. The
	-- latch condition mirrors the cpuDi mux gate so only real reads are counted.
	-- Readable via $DFE9-$DFEF: count/data/addr_hi/cache_bank/addr_lo/addr_mid.
	process(clk32)
	begin
		if rising_edge(clk32) then
			if enableCpu = '1' and superram_in_pipeline = '1' and cpuWe_pre = '0' then
				dbg_srr_count_r      <= dbg_srr_count_r + 1;
				dbg_srr_data_r       <= sdram_superram;
				dbg_srr_addr_hi_r    <= addr_hi_816;
				dbg_srr_cache_bank_r <= cache_cpu_bank;
				dbg_srr_addr_lo_r    <= cpuAddr_pre(7 downto 0);
				dbg_srr_addr_mid_r   <= cpuAddr_pre(15 downto 8);
			end if;
		end if;
	end process;
end generate;

gen_srr_release: if not DEBUG_ENABLE generate
	dbg_srr_count      <= (others => '0');
	dbg_srr_data       <= (others => '0');
	dbg_srr_addr_hi    <= (others => '0');
	dbg_srr_cache_bank <= (others => '0');
	dbg_srr_addr_lo    <= (others => '0');
	dbg_srr_addr_mid   <= (others => '0');
end generate;

-- Crash trace capture process.
-- Free-running ring buffer of (PC, PBR, IR) tuples, one entry per instruction.
-- Two-phase trigger to distinguish crash from normal VIC IRQs:
--
-- Phase 1 (free-run): captures entries when PC changes. Detects $2D→$00
-- transition and arms Phase 2.
--
-- Phase 2 (tentative): captures DISABLED so the buffer preserves K:2D
-- context. Counter increments per CE cycle while PBR stays $00. If PBR
-- returns to non-$00 → false alarm, release back to Phase 1. If counter
-- reaches max → permanent freeze (the buffer holds the last 32 K:2D
-- instructions before the actual crash).
-- NOTE: This process deliberately does NOT clear trace signals on warm reset.
-- After a crash the CPU is in a BRK loop and needs a soft reset (which pulses
-- the C64 reset line) to boot BASIC, from which a reader PRG can dump the
-- trace via $DF20-$DFA0. Power-on initialization is handled by the VHDL
-- signal defaults. Once frozen, the trace stays frozen until cold boot OR
-- until a new PRG download starts (rising edge of bram_invalidate), which
-- unfreezes and rewinds the ring buffer so the post-load instruction stream
-- can be captured fresh.
--
-- DEBUG_ENABLE=false gates the process + packing out entirely and ties
-- dbg_bug_buf to zero. Trace signals (bug_*, trace_prev_*) remain declared
-- at architecture scope but are undriven; the synthesizer removes them.
gen_trace_debug: if DEBUG_ENABLE generate
	process(clk32)
	begin
		if rising_edge(clk32) then
			bram_inval_d <= bram_invalidate;
			-- Register the BRK-in-game detect independently of enableCpu_816 gating
			-- so the freeze path has a short, single-cycle-slack-friendly input.
			if enableCpu_816 = '1' and dbg_pbr_816 /= x"00" and dbg_ir_816 = x"00" then
				brk_detect_r <= '1';
			end if;

			-- Unconditional freeze-on-BRK: one FF → one FF path, no gates.
			-- Outside the `if supercpu_en='1' and bug_frozen='0'` gate so the
			-- assignment's critical path stays at a single clk32 cycle even when
			-- fitter placement is tight.
			if brk_detect_r = '1' then
				bug_frozen <= '1';
			end if;

			-- PRG-load trace reset: on rising edge of bram_invalidate (= start of
			-- ioctl PRG download), unfreeze and rewind the trace buffer so the
			-- cold-boot-NEW freeze from a prior run doesn't mask the actual
			-- post-load execution we want to capture.
			if bram_invalidate = '1' and bram_inval_d = '0' then
				bug_frozen  <= '0';
				bug_wp      <= (others => '0');
				brk_detect_r <= '0';
			end if;

			if supercpu_en = '1' and bug_frozen = '0' then
				if enableCpu_816 = '1' then
					-- Track previous values for transition detection (always update).
					trace_prev_pc  <= dbg_pc_816;
					trace_prev_pbr <= dbg_pbr_816;
					trace_prev_ir  <= dbg_ir_816;
					trace_prev_p   <= dbg_p_816;

					-- Mark Doom as "running" once bank $2D is seen — this gates the
					-- X-flag transition trigger so we don't catch any pre-Doom
					-- emulation-mode X=1 state during the C64 KERNAL boot path.
					if dbg_pbr_816 = x"2D" then
						seen_bank_2d <= '1';
					end if;

					-- Free-run capture on every IR change (one entry per instruction
					-- instead of per byte-fetch — doubles effective history depth).
					if dbg_ir_816 /= trace_prev_ir then
						bug_pc(to_integer(bug_wp))     <= dbg_pc_816;
						bug_pbr(to_integer(bug_wp))    <= dbg_pbr_816;
						bug_ir_buf(to_integer(bug_wp)) <= dbg_ir_816;
						bug_p(to_integer(bug_wp))      <= dbg_p_816;
						bug_wp <= bug_wp + 1;
					end if;

					-- Secondary trigger: freeze on the FIRST X=0→X=1 transition
					-- seen after Doom (bank $2D) has run.
					if seen_bank_2d = '1'
					   and dbg_p_816(4) = '1'
					   and trace_prev_p(4) = '0' then
						bug_frozen <= '1';
					end if;
				end if;

				-- $0801 wipe trigger: freeze once the $0801 write trap has fired
				-- (dbg_0801_cnt_r > 0 means CPU wrote $0801 post-download). The
				-- trap already filters cpuWe/cpuAddr/bank so we just consume its
				-- registered output to keep the bug_frozen set path short.
				if dbg_0801_cnt_r /= x"00" then
					bug_frozen <= '1';
				end if;
			end if;
		end if;
	end process;

	-- Pack the buffer into the wide output port (LSB first).
	-- byte 0 = status: bit0=frozen, bits[7:1]=write_pos[6:0].
	-- Each entry occupies 4 bytes: PC_lo, PC_hi, PBR, IR. 128 entries = 512 bytes.
	-- P region: 128 × 1 byte = 128 bytes at bits 4104..5127.
	-- Total: 1 + 512 + 128 = 641 bytes = 5128 bits.
	dbg_bug_buf(7 downto 0) <=
		std_logic_vector(bug_wp) & bug_frozen;

	trace_pack: for i in 0 to TRACE_DEPTH-1 generate
		dbg_bug_buf( 8 + i*32 +  7 downto  8 + i*32 +  0) <= std_logic_vector(bug_pc(i)(7 downto 0));
		dbg_bug_buf( 8 + i*32 + 15 downto  8 + i*32 +  8) <= std_logic_vector(bug_pc(i)(15 downto 8));
		dbg_bug_buf( 8 + i*32 + 23 downto  8 + i*32 + 16) <= std_logic_vector(bug_pbr(i));
		dbg_bug_buf( 8 + i*32 + 31 downto  8 + i*32 + 24) <= std_logic_vector(bug_ir_buf(i));
	end generate;

	-- P register bytes appended after the 128 4-byte entries. Layout:
	-- bits 4104..5127 = 128 × P byte (P region starts at 8 + 128*32 = 4104).
	trace_pack_p: for i in 0 to TRACE_DEPTH-1 generate
		dbg_bug_buf(4104 + i*8 + 7 downto 4104 + i*8) <= std_logic_vector(bug_p(i));
	end generate;
end generate;

gen_trace_release: if not DEBUG_ENABLE generate
	-- Release build: no trace capture, no packing. Tie the wide output port
	-- to zero so downstream logic has a stable constant driver; synthesis
	-- removes the unused trace_* / bug_* storage.
	dbg_bug_buf <= (others => '0');
end generate;

-- Expose native IRQ vector value for UART debug
dbg_native_irq_vec <= std_logic_vector(scpu_native_vec(13)) & std_logic_vector(scpu_native_vec(12));

-- Diagnostic: capture first time CPU enters a non-$00 bank (sticky max bank seen).
-- K (cia1_pa): highest bank byte (PBR) ever seen while CPU active.
-- R (cia1_pb): cpuAddr(7:0) at the moment that highest bank was first entered.
-- Interpretation: K:F8 R:FC = CPU successfully entered bank $F8 at $00FC (JML worked).
--                 K:00 R:00 = CPU never left bank $00 (JML failed or wrong reset vector).
gen_cia1_dbg_debug: if DEBUG_ENABLE generate
	process(clk32)
	begin
		if rising_edge(clk32) then
			if reset = '1' or (supercpu_en = '1' and supercpu_en_prev = '0') then
				dbg_cia1_pa_r <= x"00";
				dbg_cia1_pb_r <= x"00";
			elsif enableCpu_816 = '1' and supercpu_en = '1' then
				if addr_hi_816 > dbg_cia1_pa_r then
					dbg_cia1_pa_r <= addr_hi_816;       -- sticky max bank
					dbg_cia1_pb_r <= cpuAddr(7 downto 0); -- address when max bank was entered
				end if;
			end if;
		end if;
	end process;
	dbg_cia1_pa <= dbg_cia1_pa_r;
	dbg_cia1_pb <= dbg_cia1_pb_r;
end generate;

gen_cia1_dbg_release: if not DEBUG_ENABLE generate
	dbg_cia1_pa <= (others => '0');
	dbg_cia1_pb <= (others => '0');
end generate;

-- Screen-RAM write detector: latch addr/data/opcode/PC whenever CPU writes to $0400-$07FF.
-- Used to distinguish CPU-driven screen updates from non-CPU (read-side/timing) artifacts.
gen_scr_debug: if DEBUG_ENABLE generate
	process(clk32)
	begin
		if rising_edge(clk32) then
			if reset = '1' then
				dbg_scr_wr_addr_r <= (others => '0');
				dbg_scr_wr_pc_r   <= (others => '0');
				dbg_scr_wr_data_r <= (others => '0');
				dbg_scr_wr_ir_r   <= (others => '0');
				dbg_scr_wr_bank_r <= (others => '0');
				dbg_scr_wr_arm_r  <= '0';
				dbg_scr_wr_arm_ctr <= (others => '0');
				dbg_scr_zero_hit_r <= '0';
			elsif supercpu_en = '0' then
				dbg_scr_wr_bank_r <= (others => '0');
				dbg_scr_wr_arm_r  <= '0';
				dbg_scr_wr_arm_ctr <= (others => '0');
				dbg_scr_zero_hit_r <= '0';
			elsif dbg_scr_wr_arm_r = '0' then
				dbg_scr_wr_arm_ctr <= dbg_scr_wr_arm_ctr + 1;
				if dbg_scr_wr_arm_ctr = to_unsigned(31999999, dbg_scr_wr_arm_ctr'length) then
					dbg_scr_wr_arm_r <= '1';
				end if;
			elsif supercpu_en = '1' and cpuWe = '1' and sysCycle >= CYCLE_CPU0
			      and cpuAddr(15 downto 10) = "000001" then
				-- STICKY $00 capture: first zero-write to screen RAM locks the display.
				-- Once triggered, dbg_scr_zero_hit_r='1' freezes the capture registers
				-- so we can see where/how the $00 (@ artifact) was written.
				if cpuDo = x"00" and dbg_scr_zero_hit_r = '0' then
					dbg_scr_wr_addr_r <= cpuAddr;
					dbg_scr_wr_pc_r   <= dbg_pc_816;
					dbg_scr_wr_data_r <= cpuDo;
					dbg_scr_wr_ir_r   <= dbg_ir_816;
					dbg_scr_wr_bank_r <= addr_hi_816;
					dbg_scr_zero_hit_r <= '1';
				elsif dbg_scr_zero_hit_r = '0' then
					-- Rolling capture: filter ALL cursor-blink writes (PC=$EA20, any address).
					-- Previous filter was too narrow (only $04F0); cursor moves around.
					if dbg_pc_816 /= x"EA20" then
						dbg_scr_wr_addr_r <= cpuAddr;
						dbg_scr_wr_pc_r   <= dbg_pc_816;
						dbg_scr_wr_data_r <= cpuDo;
						dbg_scr_wr_ir_r   <= dbg_ir_816;
						dbg_scr_wr_bank_r <= addr_hi_816;
					end if;
				end if;
			end if;
		end if;
	end process;
	dbg_scr_wr_addr <= dbg_scr_wr_addr_r;
	dbg_scr_wr_pc   <= dbg_scr_wr_pc_r;
	dbg_scr_wr_data <= dbg_scr_wr_data_r;
	dbg_scr_wr_ir   <= dbg_scr_wr_ir_r;
	dbg_scr_zero_hit <= dbg_scr_zero_hit_r;
	dbg_scr_wr_bank <= dbg_scr_wr_bank_r;
	dbg_scr_arm <= dbg_scr_wr_arm_r;
end generate;

gen_scr_release: if not DEBUG_ENABLE generate
	dbg_scr_wr_addr  <= (others => '0');
	dbg_scr_wr_pc    <= (others => '0');
	dbg_scr_wr_data  <= (others => '0');
	dbg_scr_wr_ir    <= (others => '0');
	dbg_scr_zero_hit <= '0';
	dbg_scr_wr_bank  <= (others => '0');
	dbg_scr_arm      <= '0';
end generate;

-- $0801 write PC trap: captures PC/IR/data on every CPU write at $000801
-- while dbg_0801_trap_en='1'. Lets us find which BASIC/KERNAL routine is
-- wiping our PRG byte after an ioctl PRG load.
gen_0801_trap_debug: if DEBUG_ENABLE generate
	process(clk32)
	begin
		if rising_edge(clk32) then
			if reset = '1' or dbg_0801_trap_en = '0' then
				-- Reset when the window closes (download or meminit active) so each
				-- window starts counting fresh. Avoids accumulating from initial
				-- boot-NEW writes that happen before any PRG load.
				dbg_0801_pc_r   <= (others => '0');
				dbg_0801_ir_r   <= (others => '0');
				dbg_0801_data_r <= (others => '0');
				dbg_0801_cnt_r  <= (others => '0');
			elsif cpuWe = '1' and sysCycle >= CYCLE_CPU0
			      and cpuAddr = x"0801" and addr_hi_816 = x"00" then
				dbg_0801_pc_r   <= dbg_pc_816;
				dbg_0801_ir_r   <= dbg_ir_816;
				dbg_0801_data_r <= cpuDo;
				dbg_0801_cnt_r  <= dbg_0801_cnt_r + 1;
			end if;
		end if;
	end process;
	dbg_0801_pc       <= dbg_0801_pc_r;
	dbg_0801_ir       <= dbg_0801_ir_r;
	dbg_0801_data_out <= dbg_0801_data_r;
	dbg_0801_cnt      <= dbg_0801_cnt_r;
end generate;

gen_0801_trap_release: if not DEBUG_ENABLE generate
	dbg_0801_pc       <= (others => '0');
	dbg_0801_ir       <= (others => '0');
	dbg_0801_data_out <= (others => '0');
	dbg_0801_cnt      <= (others => '0');
end generate;

-- VIC c-access capture: detect when VIC receives $00 screen code during badline.
--
-- Corrected SDRAM pipeline timing:
--   VIC0 CE fires with g-access address (char bitmap, ~$1000+)
--     → data arrives at VIC2.5 → VIC latches at CPUE (g-access/bitmap data)
--   CPUC CE fires with c-access address (screen RAM, $0400+)
--     → data arrives at CPUE.5 → VIC latches at NEXT VIC2 (c-access/screen code)
--
-- So to capture c-access: latch vicAddr at CPUC, check vicDi at next VIC2.
-- The VIC entity outputs VM & colCounter (c-access addr) when phi='1' (CPU phase).
--
-- Packed cpu_r format:
--   (15)    = cpuHasBus at CPUC (should be '0' during badline steal)
--   (14)    = aec at VIC2 (should be '1')
--   (13:8)  = vicDi(5 downto 0) at VIC2 (c-access data from SDRAM)
--   (7:0)   = systemAddr(7 downto 0) at CPUC (verify SDRAM got correct addr)
gen_vic_debug: if DEBUG_ENABLE generate
process(clk32)
begin
	if rising_edge(clk32) then
		if reset = '1' then
			dbg_vic_zero_hit_r  <= '0';
			dbg_vic_zero_addr_r <= (others => '0');
			dbg_vic_zero_cpu_r  <= (others => '0');
			dbg_vic_zero_sysaddr_r <= (others => '0');
			dbg_vic_wr_match_r  <= '0';
			dbg_vic_wr_pc_r     <= (others => '0');
			dbg_vic_prearm_cnt_r <= (others => '0');
			dbg_vic_hit_cnt_r    <= (others => '0');
			dbg_vic_cpuf_zero_cnt_r <= (others => '0');
			dbg_vic_cpue_live_zero_cnt_r <= (others => '0');
			dbg_vic_cpue_hold_zero_cnt_r <= (others => '0');
			dbg_vic_cpue_mismatch_cnt_r  <= (others => '0');
			vic_ca_addr_lat     <= (others => '0');
			vic_ca_sysaddr16_lat <= (others => '0');
			vic_ca_sysaddr_lat  <= (others => '0');
			vic_ca_has_bus_lat  <= '0';
			vic_ca_pending      <= '0';
			vic_ca_data_lat     <= (others => '0');
			vic_ca_data_valid   <= '0';
		elsif supercpu_en = '0' then
			dbg_vic_zero_hit_r  <= '0';
			dbg_vic_wr_match_r  <= '0';
			dbg_vic_wr_pc_r     <= (others => '0');
			dbg_vic_prearm_cnt_r <= (others => '0');
			dbg_vic_hit_cnt_r    <= (others => '0');
			dbg_vic_cpuf_zero_cnt_r <= (others => '0');
			dbg_vic_cpue_live_zero_cnt_r <= (others => '0');
			dbg_vic_cpue_hold_zero_cnt_r <= (others => '0');
			dbg_vic_cpue_mismatch_cnt_r  <= (others => '0');
			dbg_hold_fire_cnt_r      <= (others => '0');
			dbg_hold_mismatch_cnt_r  <= (others => '0');
			dbg_hold_held_zero_cnt_r <= (others => '0');
			dbg_hold_live_zero_cnt_r <= (others => '0');
			vic_ca_pending      <= '0';
			vic_ca_data_valid   <= '0';
		else
			-- At CPUC: latch vicAddr and capture c-access data from CPU8's early
			-- SDRAM read. Data has had 1.5 clk32 (~47ns) to propagate through
			-- the combinational path (dout_r → sdram.dout → cartridge → buslogic
			-- → vicDi). Hold register presents this to VIC at CPUF with 3 clk32
			-- (~94ns) margin.
			if sysCycle = CYCLE_CPUC then
				vic_ca_addr_lat    <= vicAddr;
				vic_ca_sysaddr16_lat <= systemAddr;
				vic_ca_sysaddr_lat <= systemAddr(7 downto 0);
				vic_ca_has_bus_lat <= cpuHasBus;
				vic_ca_pending     <= '1';

				-- Capture for hold register: only during SuperCPU badlines
				if cpuHasBus = '0' and supercpu_en = '1' then
					vic_ca_data_lat   <= vicDi;
					vic_ca_data_valid <= '1';
				else
					vic_ca_data_valid <= '0';
				end if;
			end if;

			-- Diagnostic: count hold gate activations and mismatches.
			-- vic_hold_gate is combinational ('1' only at CPUF when conditions met).
			-- At this edge, vicDi is the "live" SDRAM data from the CPUC CE read
			-- (which had only 0.5 clk32 to settle). vic_ca_data_lat is the "held"
			-- data captured at CPUC from the earlier CPU8 CE read.
			-- Write any value to $D07C to clear all four diagnostic counters.
			if supercpu_en = '1' and cpuWe = '1' and cpuAddr = x"D07C" and addr_hi_816 = x"00" then
				dbg_hold_fire_cnt_r      <= (others => '0');
				dbg_hold_mismatch_cnt_r  <= (others => '0');
				dbg_hold_held_zero_cnt_r <= (others => '0');
				dbg_hold_live_zero_cnt_r <= (others => '0');
			elsif vic_hold_gate = '1' then
				dbg_hold_fire_cnt_r <= dbg_hold_fire_cnt_r + 1;
				if vic_ca_data_lat /= vicDi then
					dbg_hold_mismatch_cnt_r <= dbg_hold_mismatch_cnt_r + 1;
				end if;
				if vic_ca_data_lat = x"00" then
					dbg_hold_held_zero_cnt_r <= dbg_hold_held_zero_cnt_r + 1;
				end if;
				if vicDi = x"00" then
					dbg_hold_live_zero_cnt_r <= dbg_hold_live_zero_cnt_r + 1;
				end if;
			end if;

			-- Step 2: At VIC2 (next enaData pulse after CPUC), check the data.
			-- Use held c-access data when available; fallback to live vicDi.
			-- Count all VIC-side $00 hits, split by arm state.
			-- Trigger sticky detail capture on the first post-arm hit.
			if sysCycle = CYCLE_VIC2 and vic_ca_pending = '1' then
				if vic_ca_has_bus_lat = '0'
				   and vic_ca_addr_lat(15 downto 10) = "000001"
				   and vicDi_hold_or_live = x"00" then
					if dbg_scr_wr_arm_r = '0' then
						dbg_vic_prearm_cnt_r <= dbg_vic_prearm_cnt_r + 1;
					else
						dbg_vic_hit_cnt_r <= dbg_vic_hit_cnt_r + 1;
					end if;

					if dbg_vic_zero_hit_r = '0' and dbg_scr_wr_arm_r = '1' then
						dbg_vic_zero_hit_r  <= '1';
						dbg_vic_zero_addr_r <= vic_ca_addr_lat;
						dbg_vic_zero_sysaddr_r <= vic_ca_sysaddr16_lat;
						dbg_vic_zero_cpu_r  <= vic_ca_has_bus_lat & aec
						                     & vicDi_hold_or_live(5 downto 0) & vic_ca_sysaddr_lat;
						if dbg_scr_wr_addr_r = vic_ca_addr_lat then
							dbg_vic_wr_match_r <= '1';
							dbg_vic_wr_pc_r    <= dbg_scr_wr_pc_r;
						else
							dbg_vic_wr_match_r <= '0';
							dbg_vic_wr_pc_r    <= (others => '0');
						end if;
					end if;
				end if;

				vic_ca_pending <= '0';
				vic_ca_data_valid <= '0';
			end if;
		end if;
	end if;
end process;
dbg_vic_zero_hit  <= dbg_vic_zero_hit_r;
dbg_vic_zero_addr <= dbg_vic_zero_addr_r;
dbg_vic_zero_cpu  <= dbg_vic_zero_cpu_r;
dbg_vic_zero_sysaddr <= dbg_vic_zero_sysaddr_r;
dbg_vic_wr_match <= dbg_vic_wr_match_r;
dbg_vic_wr_pc    <= dbg_vic_wr_pc_r;
dbg_vic_prearm_cnt <= dbg_vic_prearm_cnt_r;
dbg_vic_hit_cnt    <= dbg_vic_hit_cnt_r;
dbg_vic_mode <= dbg_vic_mode_r;
dbg_vic_cpuf_zero_cnt <= dbg_vic_cpuf_zero_cnt_r;
dbg_vic_cpue_live_zero_cnt <= dbg_vic_cpue_live_zero_cnt_r;
dbg_vic_cpue_hold_zero_cnt <= dbg_vic_cpue_hold_zero_cnt_r;
dbg_vic_cpue_mismatch_cnt <= dbg_vic_cpue_mismatch_cnt_r;
end generate;

gen_vic_release: if not DEBUG_ENABLE generate
	dbg_vic_zero_hit  <= '0';
	dbg_vic_zero_addr <= (others => '0');
	dbg_vic_zero_cpu  <= (others => '0');
	dbg_vic_zero_sysaddr <= (others => '0');
	dbg_vic_wr_match <= '0';
	dbg_vic_wr_pc    <= (others => '0');
	dbg_vic_prearm_cnt <= (others => '0');
	dbg_vic_hit_cnt    <= (others => '0');
	dbg_vic_mode       <= (others => '0');
	dbg_vic_cpuf_zero_cnt <= (others => '0');
	dbg_vic_cpue_live_zero_cnt <= (others => '0');
	dbg_vic_cpue_hold_zero_cnt <= (others => '0');
	dbg_vic_cpue_mismatch_cnt  <= (others => '0');
end generate;

-- $D07E ROM-visibility switch.
-- Kickstart writes $00 to $D07E at $80F7 to expose C64 KERNAL at $E000-$FFFF.
-- Also reset on supercpu_en rising edge: if the user toggles SuperCPU mode off/on,
-- the kickstart must start fresh with scpu_rom_vis='1' (SCPU ROM at reset vector).
process(clk32)
begin
	if rising_edge(clk32) then
		supercpu_en_prev <= supercpu_en;
		cache_flush_sw <= '0';  -- auto-clear: flush is a 1-cycle pulse
		if reset = '1' or (supercpu_en = '1' and supercpu_en_prev = '0') then
			scpu_rom_vis      <= '1'; -- SuperCPU ROM visible on CPU start
			scpu_speed_1mhz   <= '0'; -- Default: 20MHz (cache handles I/O at 1MHz)
			scpu_sys_1mhz     <= '0'; -- Default: system turbo
			scpu_regs_enabled <= '1'; -- Registers visible after reset
			scpu_hwenable     <= '0'; -- Hardware registers disabled at reset
			scpu_bootmap      <= '1'; -- Boot ROM map active at reset
			scpu_optim_mode   <= "11"; -- No optimization (mirror all)
			dbg_vic_mode_r    <= (others => '0');
			-- Initialize native mode vector registers with defaults:
			-- $FF00=RTI($40), $FF01=RTL($6B), $FFE4-$FFEF = vectors → $FF00
			scpu_native_vec(0)  <= x"40"; -- $FF00: RTI
			scpu_native_vec(1)  <= x"6B"; -- $FF01: RTL
			scpu_native_vec(2)  <= x"00"; -- $FFE4: COP low
			scpu_native_vec(3)  <= x"FF"; -- $FFE5: COP high → $FF00
			scpu_native_vec(4)  <= x"00"; -- $FFE6: BRK low
			scpu_native_vec(5)  <= x"FF"; -- $FFE7: BRK high → $FF00
			scpu_native_vec(6)  <= x"00"; -- $FFE8: ABORT low
			scpu_native_vec(7)  <= x"FF"; -- $FFE9: ABORT high → $FF00
			scpu_native_vec(8)  <= x"00"; -- $FFEA: NMI low
			scpu_native_vec(9)  <= x"FF"; -- $FFEB: NMI high → $FF00
			scpu_native_vec(10) <= x"00"; -- $FFEC: unused low
			scpu_native_vec(11) <= x"FF"; -- $FFED: unused high → $FF00
			scpu_native_vec(12) <= x"00"; -- $FFEE: IRQ low
			scpu_native_vec(13) <= x"FF"; -- $FFEF: IRQ high → $FF00
		elsif supercpu_en = '1' and cpuWe = '1' and addr_hi_816 = x"00" then
			-- SuperCPU register writes (active in bank $00 only)
			-- $D072/$D073: system 1MHz (unconditional, works even with regs disabled)
			if cpuAddr = x"D072" then
				scpu_sys_1mhz <= '1';          -- Any write to $D072 = system 1MHz enable
			elsif cpuAddr = x"D073" then
				scpu_sys_1mhz <= '0';          -- Any write to $D073 = system 1MHz disable
			elsif cpuAddr = x"D07E" then
				-- VICE: ANY write to $D07E = hwenable strobe (data irrelevant)
				scpu_hwenable <= '1';
				scpu_regs_enabled <= '1';      -- $D07E also enables hardware registers
				-- Legacy: keep rom_vis behavior for kickstart boot compatibility.
				-- Auto-clear bootmap when rom_vis goes 1→0 (simulates kickstart $D0B6 write).
				if supercpu_rom = '1' then
					scpu_rom_vis <= cpuDo(7);
					if cpuDo(7) = '0' and scpu_rom_vis = '1' then
						scpu_bootmap <= '0';   -- kickstart clearing rom_vis = bootmap done
					end if;
				end if;
			elsif cpuAddr = x"D07F" or cpuAddr = x"D07D" then
				scpu_hwenable <= '0';          -- $D07F/$D07D clears hwenable
				scpu_regs_enabled <= '0';      -- $D07F/$D07D disables hardware registers
			elsif cpuAddr = x"D078" then
				cache_flush_sw <= '1';         -- SIMM config on real HW; we use as cache flush
			elsif cpuAddr = x"D07A" then
				scpu_speed_1mhz <= '1';        -- Any write to $D07A = software 1MHz
			elsif cpuAddr = x"D07B" or cpuAddr = x"D079" then
				scpu_speed_1mhz <= '0';        -- Any write to $D07B/$D079 = software turbo
			elsif cpuAddr = x"D074" then
				scpu_optim_mode <= "00";       -- VIC bank 2 optimization ($8000-$BFFF)
			elsif cpuAddr = x"D075" then
				scpu_optim_mode <= "01";       -- VIC bank 1 optimization ($4000-$7FFF)
			elsif cpuAddr = x"D076" then
				scpu_optim_mode <= "10";       -- BASIC optimization ($0400-$07FF)
			elsif cpuAddr = x"D077" then
				scpu_optim_mode <= "11";       -- No optimization (mirror all, default)
			end if;
			-- Bootmap registers (require hwenable=1, VICE-verified)
			if scpu_hwenable = '1' then
				if cpuAddr = x"D0B6" then
					scpu_bootmap <= '0';       -- Clear bootmap (kernal shadow active)
				elsif cpuAddr = x"D0B7" then
					scpu_bootmap <= '1';       -- Set bootmap (EPROM active)
				end if;
			end if;
			-- Debug registers (always writable, independent of scpu_regs_enabled)
			if cpuAddr = x"D07C" then
				dbg_vic_mode_r(1 downto 0) <= cpuDo(1 downto 0); -- runtime test mode
			end if;
			-- Native mode vector writes: bank $00, $FFxx, native mode
			-- Software (e.g. Doom) writes its own IRQ handler address to $FFE6/$FFE7
			if emu_mode_816 = '0' and cpuAddr(15 downto 8) = x"FF" then
				case cpuAddr(7 downto 0) is
					when x"00" => scpu_native_vec(0)  <= cpuDo;
					when x"01" => scpu_native_vec(1)  <= cpuDo;
					when x"E4" => scpu_native_vec(2)  <= cpuDo;
					when x"E5" => scpu_native_vec(3)  <= cpuDo;
					when x"E6" => scpu_native_vec(4)  <= cpuDo;
					when x"E7" => scpu_native_vec(5)  <= cpuDo;
					when x"E8" => scpu_native_vec(6)  <= cpuDo;
					when x"E9" => scpu_native_vec(7)  <= cpuDo;
					when x"EA" => scpu_native_vec(8)  <= cpuDo;
					when x"EB" => scpu_native_vec(9)  <= cpuDo;
					when x"EC" => scpu_native_vec(10) <= cpuDo;
					when x"ED" => scpu_native_vec(11) <= cpuDo;
					when x"EE" => scpu_native_vec(12) <= cpuDo;
					when x"EF" => scpu_native_vec(13) <= cpuDo;
					when others => null;
				end case;
			end if;
		end if;
	end if;
end process;

cass_motor <= cpuIO(5);
cass_write <= cpuIO(3);

-- IEC auto-slowdown: detect CIA2 IEC port WRITES and force 1MHz for ~32ms.
-- The IEC serial bus timing is sensitive to CPU speed — IEC routines bit-bang the
-- port at $DD00 and expect 1MHz-rate timing. Suppress cache-driven turbo enables
-- and SDRAM turbo slots while the timeout is active.
-- Trigger on WRITES to $DD00-$DD03 (port A/B data + DDR) — these control the
-- IEC serial bus lines (ATN, CLK, DATA).
-- Also trigger on READS of $DD00 (port A) — custom fastloaders poll CLK_IN/DATA_IN
-- (bits 6-7) for handshake and need 1MHz timing for protocol synchronization.
-- Do NOT trigger on reads of $DD04-$DD0F (timers, IRQ flags) — $DD0D IRQ
-- acknowledge fires every 60Hz and would keep iec_slow_mode permanently active.
process(clk32)
begin
	if rising_edge(clk32) then
		if reset = '1' then
			iec_slow_mode <= '0';
			iec_slow_ctr  <= (others => '0');
		else
			-- Countdown FIRST (lower priority — detection overrides below)
			if iec_slow_ctr /= 0 then
				iec_slow_ctr <= iec_slow_ctr - 1;
			else
				iec_slow_mode <= '0';
			end if;

			-- Detect CIA2 IEC port access — LAST assignment wins in VHDL
			-- WRITES to $DD00-$DD03, or READS of $DD00 (IEC bus status polling)
			if cpuAddr(15 downto 4) = x"DD0" and cs_cia2 = '1' and enableCpu = '1'
			   and ((cpuAddr(3 downto 2) = "00" and cpuWe = '1')
			     or (cpuAddr(3 downto 0) = x"0" and cpuWe = '0')) then
				iec_slow_mode <= '1';
				iec_slow_ctr  <= (others => '1');  -- ~32ms timeout at 32MHz
			end if;
		end if;
	end if;
end process;

-- Write buffer drain: steal CPU SDRAM slots when the CPU can run from cache.
-- Condition: buffer has entries AND current CPU read is a cache hit (so SDRAM
-- slot is redundant) AND we're in a CPU SDRAM slot AND not during DMA.
-- During drain: ramAddr/ramDout carry wb_addr/wb_data, ramWE='1' for the write.
-- enableCpu is suppressed (SDRAM doing write, not read — no valid CPU data).
-- The CPU still advances via cache_hit_d1 during this and adjacent slots.
-- Gate drain on bank $00 only: the write-back buffer stores 16-bit addresses
-- (no bank byte). Draining during non-bank-$00 cycles would override ramAddr
-- with a 16-bit wb_addr, bypassing the scpu_superram_addr calculation in c64.sv
-- and sending the write to the wrong SDRAM region (bank $00 instead of SuperRAM).
wb_drain_active <= '1' when wb_pending = '1' and cache_hit = '1'
                            and cpu_cyc = '1' and dma_active = '0'
                            and cache_cpu_bank = x"00"
                  else '0';
wb_ack <= wb_drain_active;

ramDout <= wb_data      when wb_drain_active = '1' else cpuDo;
ramAddr <= wb_addr      when wb_drain_active = '1' else systemAddr;
ramWE   <= '1'          when wb_drain_active = '1' and sysCycle >= CYCLE_CPU0
      else systemWe     when sysCycle >= CYCLE_CPU0
      else '0';

-- Early CE DISABLED: CPU8 reads returned ZP data, not screen data.
-- The extra SDRAM read was clobbering dout_r with wrong values.
vic_early_ce <= '0'; -- disabled
ramCE   <= cs_ram when sysCycle = CYCLE_VIC0 or cpu_cyc = '1' else '0';
-- Gate turbo slots (CPU0/CPU4/CPU8) on cpuHasBus AND baLoc: during badlines
-- (baLoc='0'), cpuWe='1' can grant cpuHasBus for write completion at CPUC.
-- But turbo SDRAM reads at CPU0/CPU4/CPU8 would use systemAddr=cpuAddr,
-- overwriting ramData with CPU data.  VIC c-access at CPUE then reads wrong
-- data.  baLoc gate ensures turbo slots only fire during non-badline periods.
-- SDRAM pipeline skip REVERTED: suppressing cpu_cyc on cache/BRAM hits
-- broke SuperCPU (black screen). The 65C816 needs SDRAM reads even when
-- cache reports a hit, due to phantom cycles and bank addressing.
-- TODO: gate SDRAM skip to T65-only mode after verifying 816 safety.
-- Turbo SDRAM slots (CPU0/CPU4/CPU8): bank $00 and ROM ($F0+) only.
-- SuperRAM ($01-$EF) uses CPUC only — the 3-stage pipeline state machine
-- has edge cases with rapid bank switching that cause crashes (Doom regression).
-- Bank $00 is safe because BRAM/cache hits deliver data directly.
-- ROM ($F0+) is safe because data comes from ROM BRAM, not SDRAM.
-- CPUC handles SuperRAM via the 3-stage pipeline + superram_data_r bypass.
cpu_cyc <= '1' when
				(sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1' and cpuHasBus = '1' and baLoc = '1' and (cache_cpu_bank = x"00" or cache_cpu_bank >= x"F0")) or
				(sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1' and cpuHasBus = '1' and baLoc = '1' and (cache_cpu_bank = x"00" or cache_cpu_bank >= x"F0")) or
				(sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1' and cpuHasBus = '1' and baLoc = '1' and (cache_cpu_bank = x"00" or cache_cpu_bank >= x"F0")) or
				(sysCycle = CYCLE_CPUC and (io_enable = '1'  or cs_ram = '1')) else '0';
				
process(clk32)
begin
	if rising_edge(clk32) then
		-- SDRAM pipeline: 2-stage shift register from cpu_cyc to enableCpu.
		-- SuperRAM (banks $01-$EF) uses a 3-stage pipeline: the extra cycle
		-- ensures the SDRAM read completes before enableCpu fires, even at
		-- turbo slots (CPU0/CPU4/CPU8) which are close to VIC0 in the rotation.
		-- Bank $00 and ROM ($F0+) use the standard 2-stage pipeline.
		-- When cache/BRAM hits advance the CPU, the pending SDRAM read becomes
		-- stale (wrong address). Cancel the pipeline to prevent delivering
		-- stale data via enableCpu. This allows cache/BRAM to fire freely
		-- without being blocked by the SDRAM pipeline guards.
		if (cache_hit_d1 = '1' or bram_hit_d1 = '1' or phantom_enable = '1') and turbo_en = '1' then
			-- Cache/BRAM/phantom hit advanced the CPU: cancel pending SDRAM pipeline
			cpu_cyc_s <= "00";
			enableCpu <= '0';
			superram_enable_delay <= '0';
			superram_in_pipeline <= '0';
			io_in_pipeline <= '0';
		else
			cpu_cyc_s <= cpu_cyc_s(0) & (cpu_cyc and not wb_drain_active);
			-- Latch whether this pipeline cycle is for SuperRAM
			if cpu_cyc = '1' and wb_drain_active = '0' then
				if cache_cpu_bank > x"00" and cache_cpu_bank < x"F0" then
					superram_in_pipeline <= '1';
				else
					superram_in_pipeline <= '0';
				end if;
			end if;
			-- 3-stage for SuperRAM AND I/O, 2-stage for bank $00 RAM/ROM
			if superram_in_pipeline = '1' or io_in_pipeline = '1' then
				superram_enable_delay <= cpu_cyc_s(1);
				enableCpu <= superram_enable_delay;
			else
				superram_enable_delay <= '0';
				enableCpu <= cpu_cyc_s(1);
			end if;
		end if;
		-- IOF pipeline detection: PRIMARY at CPUC + EDGE FALLBACK.
		-- Primary: at CPUC via cpu_cyc (works when address settled at CPUC).
		-- Fallback: iof_detect rising edge (catches late address settling).
		iof_detect_d1 <= iof_detect;
		if cpu_cyc = '1' and wb_drain_active = '0' then
			if iof_detect = '1' and cpuWe_pre = '0' then
				io_in_pipeline <= '1';
				cpu_cyc_s(0) <= '1';
			else
				io_in_pipeline <= '0';
			end if;
		end if;
		-- Fallback: iof_detect rising edge at ANY cycle
		if iof_detect_d1 = '0' and iof_detect = '1' and cpuWe_pre = '0'
		   and io_in_pipeline = '0' then
			io_in_pipeline <= '1';
			cpu_cyc_s(0) <= '1';
		end if;
		-- CRITICAL: clear io_in_pipeline when SDRAM pipeline delivers.
		-- enableCpu is the SDRAM pipeline output (NOT bram enableCpu_816).
		-- This prevents io_in_pipeline from persisting into the next instruction.
		-- Must be AFTER the else-branch so it can override the io_in_pipeline set.
		if enableCpu = '1' and io_in_pipeline = '1' then
			io_in_pipeline <= '0';
		end if;
		-- SuperRAM data path: cpuDi now uses sdram_superram (dout_reu from
		-- sdram.v) directly instead of superram_data_r. sdram_superram is a
		-- clk64-domain register (dout_reu_r) updated at STATE_READ only for
		-- bt=1 reads (SuperRAM). This avoids TWO timing issues:
		-- 1. bt race: io_cycle CE at EXT0 flips bt in sdram.v, corrupting
		--    the bt-dependent dout before a clk32-domain capture could read it.
		-- 2. SDRAM CAS latency race: the 3-stage pipeline's clk32 capture
		--    at superram_enable_delay (CPUE) or enableCpu (CPUF) may coincide
		--    with the clk64 STATE_READ edge, causing a clock domain crossing
		--    race where the old dout_r value is read instead of the new one.
		--    sdram_superram avoids this because it's stable 2+ clk64 cycles
		--    before the CPU reads cpuDi at enableCpu_816 time.
		-- Legacy capture retained for diagnostic purposes only.
		if superram_enable_delay = '1' and superram_in_pipeline = '1' then
			superram_data_r <= sdram_raw;  -- DIAGNOSTIC ONLY, not used in cpuDi
		end if;
		io_enable <= io_enable and not enableCpu;

		if sysCycle = CYCLE_EXT0 then
			io_enable <= '1';
		end if;
		-- Re-arm io_enable before the normal I/O slot (CPUC).  Turbo slots
		-- (CPU0/CPU4/CPU8) only fire for RAM, but their enableCpu pulses clear
		-- io_enable via the "and not enableCpu" line above.  Without this
		-- re-arm, a RAM access at a turbo slot would prevent the subsequent
		-- I/O access at CPUC from firing, skipping CIA2 writes and breaking
		-- the IEC serial bus.  The last turbo enableCpu fires at CPUA (from
		-- CPU8), so CPUB is the safe re-arm point.
		if sysCycle = CYCLE_CPUB then
			io_enable <= '1';
		end if;

		-- 2 points to register DMA request before CPU cycles.
		if sysCycle = CYCLE_EXT1 or sysCycle = CYCLE_EXT5 then
			dma_active <= dma_req;
			turbo_en <= turbo_mode(0);
			turbo_m <= "000";
			-- SuperCPU: auto-engage turbo (default max speed), OSD speed setting
			-- overrides when turbo_mode != Off. Software $D07A/$D07B always wins.
			-- T65 mode: turbo controlled by OSD setting as before.
			-- iec_slow_mode suppresses turbo during IEC serial bus access.
			-- NOTE: cs_io removed from gate — at EXT1/EXT5, cpuHasBus='0' so
			-- cs_io reflects VIC's address decode, not CPU's. This caused turbo
			-- to intermittently disable when VIC addressed $D000-$DFFF.
			-- I/O protection is already handled by cpu_cyc gating on cs_ram.
			if dma_req = '0' then
				if supercpu_en = '1' and scpu_speed_1mhz = '0' and scpu_sys_1mhz = '0' and iec_slow_mode = '0' then
					-- SuperCPU turbo: speed set by OSD SCPU Speed option.
					-- scpu_speed: 00=max (20MHz), 01=4x, 10=2x, 11=1MHz
					case scpu_speed is
						when "00" => turbo_m <= "111"; -- max: all 3 extra SDRAM slots
						when "01" => turbo_m <= "111"; -- 4x: all extra slots
						when "10" => turbo_m <= "010"; -- 2x: 1 extra slot
						when "11" => turbo_m <= "000"; -- 1MHz: no extra slots
						when others => turbo_m <= "111";
					end case;
					if scpu_speed = "11" then
						turbo_en <= '0'; -- 1MHz: disable cache/turbo
					else
						turbo_en <= '1'; -- turbo: enable cache + fast path
					end if;
					-- scpu_speed_1mhz='1': turbo_m stays "000" (1MHz from $D07A)
				elsif supercpu_en = '0' and iec_slow_mode = '0'
			      and ((turbo_mode(0) and turbo_state) = '1' or turbo_mode(1) = '1') then
					-- T65 mode ONLY: OSD-controlled turbo (not for SuperCPU 1MHz)
					turbo_en <= '1';  -- enable cache + fast path for T65 turbo
					case turbo_speed is
						when "00" => turbo_m <= "010"; -- 2x
						when "01" => turbo_m <= "110"; -- 3x
						when "10" => turbo_m <= "111"; -- 4x
						when "11" => turbo_m <= "000"; -- 1x (C64 speed)
					end case;
				end if;
			end if;
			-- Software 1MHz override: $D07A sets scpu_speed_1mhz, which MUST
			-- disable turbo_en so BRAM/cache hits don't bypass the SDRAM pipeline.
			-- Without this, turbo_en stays at turbo_mode(0) from OSD defaults,
			-- allowing BRAM hits to race the IOF I/O pipeline.
			if supercpu_en = '1' and (scpu_speed_1mhz = '1' or scpu_sys_1mhz = '1' or iec_slow_mode = '1') then
				turbo_en <= '0';
				turbo_m <= "000";
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

end architecture;
