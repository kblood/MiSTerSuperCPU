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
	dbg_d018_bad_count   : out std_logic_vector(7 downto 0);
	dbg_d018_bad_value   : out std_logic_vector(7 downto 0);
	dbg_trace_pc0        : out std_logic_vector(23 downto 0);
	dbg_trace_pc1        : out std_logic_vector(23 downto 0);
	dbg_trace_pc2        : out std_logic_vector(23 downto 0);
	dbg_trace_pc3        : out std_logic_vector(23 downto 0);
	dbg_trace_op0        : out std_logic_vector(7 downto 0);
	dbg_trace_op1        : out std_logic_vector(7 downto 0);
	dbg_trace_op2        : out std_logic_vector(7 downto 0);
	dbg_trace_op3        : out std_logic_vector(7 downto 0);
	dbg_trace_frozen     : out std_logic;
	-- v254: 4-deep JSR ring (lower-16-bit PC of last JSR / JSL fetched).
	-- Independent of trace_frozen. Reveals upstream callers of writer.
	dbg_jsr_pc_t0        : out std_logic_vector(15 downto 0);
	dbg_jsr_pc_t1        : out std_logic_vector(15 downto 0);
	dbg_jsr_pc_t2        : out std_logic_vector(15 downto 0);
	dbg_jsr_pc_t3        : out std_logic_vector(15 downto 0);
	-- v255: 4-deep JMP-indirect target ring + IRQ vector + IO port.
	-- jmp_tgt_tN = lower-16-bit PC of last 4 JMP-indirect targets
	-- (post $6C/$7C/$DC). mem_0314/mem_0315 = KERNAL IRQ vector bytes.
	-- mem_00/mem_01 = CPU IO port direction/data registers.
	dbg_jmp_tgt_t0       : out std_logic_vector(15 downto 0);
	dbg_jmp_tgt_t1       : out std_logic_vector(15 downto 0);
	dbg_jmp_tgt_t2       : out std_logic_vector(15 downto 0);
	dbg_jmp_tgt_t3       : out std_logic_vector(15 downto 0);
	dbg_mem_0314         : out std_logic_vector(7 downto 0);
	dbg_mem_0315         : out std_logic_vector(7 downto 0);
	dbg_mem_00           : out std_logic_vector(7 downto 0);
	dbg_mem_01           : out std_logic_vector(7 downto 0);
	-- v219: 24-bit opcode counter, ticks on opcode_fetch_pulse. Wraps
	-- every ~16 sec at 1MHz. Per-frame delta = opcodes/frame; T65 vs
	-- SCPU comparison answers "same code, slower" (similar deltas) vs
	-- "different code path" (very different deltas).
	dbg_op_count         : out std_logic_vector(23 downto 0);
	-- v228: I-flag diagnostics. scpu_iclr=1 if SCPU's I-flag ever
	-- observed at 0; irq_vec_count counts $FFFE/$FFFF reads (IRQ
	-- vector fetches); min_p = lowest dbg_p_816 ever observed.
	dbg_scpu_iclr        : out std_logic;
	dbg_irq_vec_count    : out std_logic_vector(15 downto 0);
	dbg_min_p            : out std_logic_vector(7 downto 0);
	-- v229: tail-chain diagnostics. rti_count counts $40 opcode
	-- executions (matches IRQ exits). nmi_vec_count counts
	-- $FFFA/$FFFB reads. Compare IRQ entries vs RTI count to detect
	-- mid-handler re-entry; NMI count > 0 indicates NMI path active.
	dbg_rti_count        : out std_logic_vector(15 downto 0);
	dbg_nmi_vec_count    : out std_logic_vector(15 downto 0);
	-- v230: source-ack discrimination. d019_wr_count counts CPU
	-- writes to $D019 (VIC IRQ status, write-1-to-clear). dc0d_rd_count
	-- counts $DC0D reads (CIA1 ICR, read-to-ack). T65 should hit
	-- d019_wr_count = IRQ entries (= IV/2). SCPU < that = ack missing.
	dbg_d019_wr_count    : out std_logic_vector(15 downto 0);
	dbg_dc0d_rd_count    : out std_logic_vector(15 downto 0);
	-- v231: source-side IRQ falling-edge count (matches IV/2 if no
	-- mid-handler re-entry).
	dbg_irq_fall_count   : out std_logic_vector(15 downto 0);
	-- v232: per-source IRQ level samples + last $D019 write value.
	-- Identifies WHICH source is stuck low and confirms whether the
	-- SCPU is writing the correct ack value to $D019.
	dbg_irq_vic_lvl      : out std_logic;
	dbg_irq_cia1_lvl     : out std_logic;
	dbg_irq_n_lvl        : out std_logic;
	dbg_irq_ext_lvl      : out std_logic;
	dbg_d019_last_val    : out std_logic_vector(7 downto 0);
	-- v234: $D019 read-side probes. d019_last_read latches cpuDi at
	-- every CPU read of $D019 (cs_vic+~cpuWe+offset=$19). seen_bits
	-- is sticky-OR of bits 0..3 across all reads. d01a_last_val =
	-- last cpuDo on $D01A write (VIC IRQ enable mask). Together
	-- these tell us: (a) does SCPU read different sources from $D019
	-- than T65 (= upstream branch divergence), or (b) does it read
	-- the same value but ack differently (= CPU/decode bug), and
	-- (c) is the IRQ enable mask the same on both modes.
	dbg_d019_last_read   : out std_logic_vector(7 downto 0);
	dbg_d019_seen_bits   : out std_logic_vector(3 downto 0);
	dbg_d01a_last_val    : out std_logic_vector(7 downto 0);
	-- v235: VIC sprite-control register write probes. T65 reads
	-- $D019=$F1 (raster only) but SCPU reads $F7 (raster + sprite-bgnd
	-- + sprite-sprite collisions). The extra collision IRQs must mean
	-- sprites are wrong on SCPU. These probes capture last-written
	-- values + writer PC + write count for the sprite control regs:
	--   $D015 = sprite enable mask (one bit per sprite)
	--   $D017 = sprite Y-expand mask
	--   $D01B = sprite-background priority mask
	--   $D01C = sprite multicolor mask
	--   $D01D = sprite X-expand mask
	-- d015_last_pc records the PBR:PC that wrote $D015 (the canonical
	-- "is this a per-frame multiplexer or a setup-time write?"
	-- question). d015_wr_count saturates at $FF.
	dbg_d015_last_val    : out std_logic_vector(7 downto 0);
	dbg_d015_last_pc     : out std_logic_vector(23 downto 0);
	dbg_d015_wr_count    : out std_logic_vector(7 downto 0);
	dbg_d017_last_val    : out std_logic_vector(7 downto 0);
	dbg_d01b_last_val    : out std_logic_vector(7 downto 0);
	dbg_d01c_last_val    : out std_logic_vector(7 downto 0);
	dbg_d01d_last_val    : out std_logic_vector(7 downto 0);
	-- v236: sprite-position probes. Sprite control (D015/D01B/D01C)
	-- was identical T65 vs SCPU; yet SCPU still latches IMBC+IMMC
	-- collisions. Must be sprite POSITIONS that differ. These four
	-- 8-bit latches expose the last-written values for sprite 0 X
	-- ($D000), sprite 0 Y ($D001), sprite 1 X ($D002), sprite 1 Y
	-- ($D003) — sufficient for sprite-sprite IMMC overlap detection.
	-- $D010 (high-X bits) added so we can disambiguate X >= $100.
	dbg_d000_last_val    : out std_logic_vector(7 downto 0);
	dbg_d001_last_val    : out std_logic_vector(7 downto 0);
	dbg_d001_last_pc     : out std_logic_vector(23 downto 0);
	dbg_d002_last_val    : out std_logic_vector(7 downto 0);
	dbg_d003_last_val    : out std_logic_vector(7 downto 0);
	dbg_d010_last_val    : out std_logic_vector(7 downto 0);
	-- v238: I-flag edge probes (sampled at opcode_fetch_pulse only).
	-- v237's min_p was sampled every clock; we couldn't tell if the
	-- I=0 moments were inside IRQ-entry microcode or at instruction
	-- boundaries. By sampling P(2) only at opcode-fetch (= first cycle
	-- of an instruction), we discriminate "main loop has I=1" from
	-- "we caught a transient I=0 inside IRQ entry". Edge detection
	-- captures PC where I transitioned, plus a count to gauge
	-- frequency.
	dbg_p_set_pc         : out std_logic_vector(23 downto 0); -- PC at last 0->1 (I-set)
	dbg_p_clr_pc         : out std_logic_vector(23 downto 0); -- PC at last 1->0 (I-clear)
	dbg_p_set_count      : out std_logic_vector(15 downto 0); -- # of 0->1 transitions
	dbg_p_clr_count      : out std_logic_vector(15 downto 0); -- # of 1->0 transitions
	dbg_p_opfetch_min    : out std_logic_vector(7 downto 0);  -- min P at opcode fetch
	-- v239: IRQ vector + zero-page stub + $0314/$0315 + cpuIO snapshot
	-- to discriminate "RAM at $FFFE differs T65 vs SCPU" (setup bug)
	-- from "$0062 stub dispatches differently" (CPU instruction bug).
	dbg_vec_lo           : out std_logic_vector(7 downto 0);  -- byte read from $FFFE
	dbg_vec_hi           : out std_logic_vector(7 downto 0);  -- byte read from $FFFF
	dbg_mem_314          : out std_logic_vector(7 downto 0);  -- byte read from $0314
	dbg_mem_315          : out std_logic_vector(7 downto 0);  -- byte read from $0315
	dbg_mem_62           : out std_logic_vector(7 downto 0);  -- byte read from $0062
	dbg_mem_63           : out std_logic_vector(7 downto 0);  -- byte read from $0063
	dbg_mem_64           : out std_logic_vector(7 downto 0);  -- byte read from $0064
	dbg_io_at_vec        : out std_logic_vector(2 downto 0);  -- cpuIO[2:0] at last $FFFE fetch
	-- v240: extend stub coverage to $0065..$006B + capture RTI PC.
	-- v239 confirmed RAM identical T65/SCPU at $0062..$0064; divergence
	-- is inside the handler. v240 grabs more stub bytes + the address
	-- of the last RTI to localize where each handler ends.
	dbg_mem_65           : out std_logic_vector(7 downto 0);
	dbg_mem_66           : out std_logic_vector(7 downto 0);
	dbg_mem_67           : out std_logic_vector(7 downto 0);
	dbg_mem_68           : out std_logic_vector(7 downto 0);
	dbg_mem_69           : out std_logic_vector(7 downto 0);
	dbg_mem_6A           : out std_logic_vector(7 downto 0);
	dbg_mem_6B           : out std_logic_vector(7 downto 0);
	-- v242: byte 6C..73 — stub continuation past STA $6F to expose the
	-- JMP/JSR/branch that dispatches to the handler body.
	dbg_mem_6C           : out std_logic_vector(7 downto 0);
	dbg_mem_6D           : out std_logic_vector(7 downto 0);
	dbg_mem_6E           : out std_logic_vector(7 downto 0);
	dbg_mem_6F           : out std_logic_vector(7 downto 0);
	dbg_mem_70           : out std_logic_vector(7 downto 0);
	dbg_mem_71           : out std_logic_vector(7 downto 0);
	dbg_mem_72           : out std_logic_vector(7 downto 0);
	dbg_mem_73           : out std_logic_vector(7 downto 0);
	-- v243: extend through $0078 (8 more bytes — should reveal
	-- JMP/JSR dispatch target after stable-raster NOP padding).
	dbg_mem_74           : out std_logic_vector(7 downto 0);
	dbg_mem_75           : out std_logic_vector(7 downto 0);
	dbg_mem_76           : out std_logic_vector(7 downto 0);
	dbg_mem_77           : out std_logic_vector(7 downto 0);
	dbg_mem_78           : out std_logic_vector(7 downto 0);
	-- v243: dispatch-target PC. Captured at the first opcode_fetch
	-- where PC leaves zero-page (i.e., the handler that the $0062
	-- stub jumps to). T65 expected to rotate; SCPU expected stuck.
	dbg_disp_target_pc   : out std_logic_vector(23 downto 0);
	-- v244: bytes at $3380..$338F (16 bytes covering full dispatcher
	-- head). T65 reaches FLI/chain/gameplay from here; SCPU always
	-- selects $811C chain. Disassembling these bytes reveals the
	-- divergent branch.
	dbg_mem_3380         : out std_logic_vector(7 downto 0);
	dbg_mem_3381         : out std_logic_vector(7 downto 0);
	dbg_mem_3382         : out std_logic_vector(7 downto 0);
	dbg_mem_3383         : out std_logic_vector(7 downto 0);
	dbg_mem_3384         : out std_logic_vector(7 downto 0);
	dbg_mem_3385         : out std_logic_vector(7 downto 0);
	dbg_mem_3386         : out std_logic_vector(7 downto 0);
	dbg_mem_3387         : out std_logic_vector(7 downto 0);
	dbg_mem_3388         : out std_logic_vector(7 downto 0);
	dbg_mem_3389         : out std_logic_vector(7 downto 0);
	dbg_mem_338A         : out std_logic_vector(7 downto 0);
	dbg_mem_338B         : out std_logic_vector(7 downto 0);
	dbg_mem_338C         : out std_logic_vector(7 downto 0);
	dbg_mem_338D         : out std_logic_vector(7 downto 0);
	dbg_mem_338E         : out std_logic_vector(7 downto 0);
	dbg_mem_338F         : out std_logic_vector(7 downto 0);
	-- v244: bytes at $9F09..$9F18 (16 bytes — FLI handler entry).
	-- Verify FLI body is loaded in RAM same on both modes.
	dbg_mem_9F09         : out std_logic_vector(7 downto 0);
	dbg_mem_9F0A         : out std_logic_vector(7 downto 0);
	dbg_mem_9F0B         : out std_logic_vector(7 downto 0);
	dbg_mem_9F0C         : out std_logic_vector(7 downto 0);
	dbg_mem_9F0D         : out std_logic_vector(7 downto 0);
	dbg_mem_9F0E         : out std_logic_vector(7 downto 0);
	dbg_mem_9F0F         : out std_logic_vector(7 downto 0);
	dbg_mem_9F10         : out std_logic_vector(7 downto 0);
	dbg_mem_9F11         : out std_logic_vector(7 downto 0);
	dbg_mem_9F12         : out std_logic_vector(7 downto 0);
	dbg_mem_9F13         : out std_logic_vector(7 downto 0);
	dbg_mem_9F14         : out std_logic_vector(7 downto 0);
	dbg_mem_9F15         : out std_logic_vector(7 downto 0);
	dbg_mem_9F16         : out std_logic_vector(7 downto 0);
	dbg_mem_9F17         : out std_logic_vector(7 downto 0);
	dbg_mem_9F18         : out std_logic_vector(7 downto 0);
	-- v244: 2nd-level dispatch PC. Snapshot at first opcode_fetch
	-- where PC leaves $33xx range. Should match the RTI ring head
	-- ($9F09 / $811C / $1Cxx etc.).
	dbg_disp2_target_pc  : out std_logic_vector(23 downto 0);
	-- v244: 4-deep PC trace ring restricted to PC[15:8]=$33.
	-- Captures the execution path through the dispatcher per IRQ.
	dbg_pc33_t0          : out std_logic_vector(23 downto 0);
	dbg_pc33_t1          : out std_logic_vector(23 downto 0);
	dbg_pc33_t2          : out std_logic_vector(23 downto 0);
	dbg_pc33_t3          : out std_logic_vector(23 downto 0);
	-- v244: PC of last write to $0070 / $0071 (zero-page vars
	-- that diverge T65/SCPU per v242). T65 only — SCPU never
	-- writes to these (so wr_pc stays at reset value $000000).
	dbg_wr70_pc          : out std_logic_vector(23 downto 0);
	dbg_wr71_pc          : out std_logic_vector(23 downto 0);
	dbg_rti_pc           : out std_logic_vector(23 downto 0); -- PC of last RTI execution
	-- v241: RTI-snapshot ring. On every RTI execution, snapshot the
	-- previous 2 opcode-fetch PCs alongside the RTI PC itself. Gives
	-- "handler tail = ... PC2 -> PC1 -> RTI" to localize the divergent
	-- jump instruction.
	dbg_rti_h1           : out std_logic_vector(23 downto 0); -- PC 1 before RTI
	dbg_rti_h2           : out std_logic_vector(23 downto 0); -- PC 2 before RTI
	-- v245: bytes around the divergent writer at $335F. v244 proved
	-- T65 and SCPU execute the SAME instruction at $335F but store
	-- DIFFERENT values ($00/$05 vs $EA/$EA). 16 bytes covering
	-- $335D..$336C reveal the A-feeding instruction.
	dbg_mem_335D         : out std_logic_vector(7 downto 0);
	dbg_mem_335E         : out std_logic_vector(7 downto 0);
	dbg_mem_335F         : out std_logic_vector(7 downto 0);
	dbg_mem_3360         : out std_logic_vector(7 downto 0);
	dbg_mem_3361         : out std_logic_vector(7 downto 0);
	dbg_mem_3362         : out std_logic_vector(7 downto 0);
	dbg_mem_3363         : out std_logic_vector(7 downto 0);
	dbg_mem_3364         : out std_logic_vector(7 downto 0);
	dbg_mem_3365         : out std_logic_vector(7 downto 0);
	dbg_mem_3366         : out std_logic_vector(7 downto 0);
	dbg_mem_3367         : out std_logic_vector(7 downto 0);
	dbg_mem_3368         : out std_logic_vector(7 downto 0);
	dbg_mem_3369         : out std_logic_vector(7 downto 0);
	dbg_mem_336A         : out std_logic_vector(7 downto 0);
	dbg_mem_336B         : out std_logic_vector(7 downto 0);
	dbg_mem_336C         : out std_logic_vector(7 downto 0);
	-- v245: bytes at $3300-$3307 (other dispatcher entry — $3380 is
	-- known to be JMP $3100, but $3300 path is where T65 reaches FLI).
	dbg_mem_3300         : out std_logic_vector(7 downto 0);
	dbg_mem_3301         : out std_logic_vector(7 downto 0);
	dbg_mem_3302         : out std_logic_vector(7 downto 0);
	dbg_mem_3303         : out std_logic_vector(7 downto 0);
	dbg_mem_3304         : out std_logic_vector(7 downto 0);
	dbg_mem_3305         : out std_logic_vector(7 downto 0);
	dbg_mem_3306         : out std_logic_vector(7 downto 0);
	dbg_mem_3307         : out std_logic_vector(7 downto 0);
	-- v245: bytes at $3100-$3107 (chain handler entry — both modes
	-- hit this; SCPU always lands here, T65 alternates with $3200).
	dbg_mem_3100         : out std_logic_vector(7 downto 0);
	dbg_mem_3101         : out std_logic_vector(7 downto 0);
	dbg_mem_3102         : out std_logic_vector(7 downto 0);
	dbg_mem_3103         : out std_logic_vector(7 downto 0);
	dbg_mem_3104         : out std_logic_vector(7 downto 0);
	dbg_mem_3105         : out std_logic_vector(7 downto 0);
	dbg_mem_3106         : out std_logic_vector(7 downto 0);
	dbg_mem_3107         : out std_logic_vector(7 downto 0);
	-- v245: actual VALUE on cpuDo at the moment of $0070/$0071 write.
	-- v244 inferred values from later READS but a second writer could
	-- have intervened. Direct write-cycle capture is unambiguous.
	dbg_wr70_val         : out std_logic_vector(7 downto 0);
	dbg_wr71_val         : out std_logic_vector(7 downto 0);
	-- v246: bytes $0079..$007F (7 bytes past v243's $78 boundary).
	-- v245 proved the divergence is upstream of the writer at $335F:
	-- the IRQ stub dispatches to $3300 (=>JMP $3200) or $3380 (=>JMP
	-- $3100), and SCPU is biased toward $3380. The dispatch JMP
	-- itself must live at $0079..$007F.
	dbg_mem_79           : out std_logic_vector(7 downto 0);
	dbg_mem_7A           : out std_logic_vector(7 downto 0);
	dbg_mem_7B           : out std_logic_vector(7 downto 0);
	dbg_mem_7C           : out std_logic_vector(7 downto 0);
	dbg_mem_7D           : out std_logic_vector(7 downto 0);
	dbg_mem_7E           : out std_logic_vector(7 downto 0);
	dbg_mem_7F           : out std_logic_vector(7 downto 0);
	-- v246: counters for disp2_target hits at $3200 vs $3100. Quantifies
	-- the FLI/gameplay-vs-chain asymmetry. T65 expected ~50/50, SCPU
	-- expected biased to $3100.
	dbg_cnt_3200         : out std_logic_vector(15 downto 0);
	dbg_cnt_3100         : out std_logic_vector(15 downto 0);
	-- v247: $5B + DF01 + bytes $0080-$008B. v246 proved IRQ stub does
	-- LDA $5B / STA $DFxx; REU cmd readback differs T65=$31 vs SCPU=$7D.
	-- Suspect LDA $5B returns different value between modes (or some
	-- prior writer differs).
	-- v259: DL gate variables ($40/$44/$5C). Per x64sc disasm.
	dbg_mem_40           : out std_logic_vector(7 downto 0);
	dbg_mem_44           : out std_logic_vector(7 downto 0);
	dbg_mem_5C           : out std_logic_vector(7 downto 0);
	-- v260: PC main/irq split + mem_45 + page counters
	dbg_pc_main          : out std_logic_vector(23 downto 0);
	dbg_pc_irq           : out std_logic_vector(23 downto 0);
	dbg_mem_45           : out std_logic_vector(7 downto 0);
	dbg_cnt_pc_30        : out std_logic_vector(15 downto 0);
	dbg_cnt_pc_97        : out std_logic_vector(15 downto 0);
	dbg_mem_5B           : out std_logic_vector(7 downto 0);
	dbg_wr5B_pc          : out std_logic_vector(23 downto 0);
	dbg_wr5B_val         : out std_logic_vector(7 downto 0);
	dbg_wr_df01_pc       : out std_logic_vector(23 downto 0);
	dbg_wr_df01_val      : out std_logic_vector(7 downto 0);
	dbg_cnt_df01         : out std_logic_vector(15 downto 0);
	dbg_mem_80           : out std_logic_vector(7 downto 0);
	dbg_mem_81           : out std_logic_vector(7 downto 0);
	dbg_mem_82           : out std_logic_vector(7 downto 0);
	dbg_mem_83           : out std_logic_vector(7 downto 0);
	dbg_mem_84           : out std_logic_vector(7 downto 0);
	dbg_mem_85           : out std_logic_vector(7 downto 0);
	dbg_mem_86           : out std_logic_vector(7 downto 0);
	dbg_mem_87           : out std_logic_vector(7 downto 0);
	dbg_mem_88           : out std_logic_vector(7 downto 0);
	dbg_mem_89           : out std_logic_vector(7 downto 0);
	dbg_mem_8A           : out std_logic_vector(7 downto 0);
	dbg_mem_8B           : out std_logic_vector(7 downto 0);
	-- v249: IRQ dispatch ptr + JMP indirect operand high byte +
	-- 4-deep P ring at IRQ entry. v248 confirmed IRQ stub ends at
	-- JMP ($XX02), operand low=$02 not $FF (so NMOS fix doesn't
	-- apply). Need mem_8C to get operand high; mem_02/mem_03 carry
	-- the dispatch target word; wr02/wr03_pc/val pinpoint writer;
	-- p_irq_tN catches flag-state divergence at IRQ entry.
	dbg_mem_8C           : out std_logic_vector(7 downto 0);
	dbg_mem_02           : out std_logic_vector(7 downto 0);
	dbg_mem_03           : out std_logic_vector(7 downto 0);
	dbg_wr02_pc          : out std_logic_vector(23 downto 0);
	dbg_wr02_val         : out std_logic_vector(7 downto 0);
	dbg_wr03_pc          : out std_logic_vector(23 downto 0);
	dbg_wr03_val         : out std_logic_vector(7 downto 0);
	-- v256: write-count to $0002 (dispatch vector lo). Increments on
	-- every cpuWe to $0002. SCPU << T65 if vector-update is skipped.
	dbg_cnt_wr02         : out std_logic_vector(15 downto 0);
	-- v257: write-count to $0002 where new VALUE differs from previous.
	-- Tests "SCPU writes same target repeatedly" hypothesis numerically.
	dbg_cnt_wr02_chg     : out std_logic_vector(15 downto 0);
	-- v258: 4-deep ring of values stored to $0002 (newest = v3, oldest = v0).
	-- Probes the value distribution directly. Plus X+Y register state at the
	-- moment of the most-recent $0002 write (to identify upstream table index).
	dbg_wr02_v0          : out std_logic_vector(7 downto 0);
	dbg_wr02_v1          : out std_logic_vector(7 downto 0);
	dbg_wr02_v2          : out std_logic_vector(7 downto 0);
	dbg_wr02_v3          : out std_logic_vector(7 downto 0);
	dbg_wr02_y           : out std_logic_vector(7 downto 0);
	dbg_wr02_x           : out std_logic_vector(7 downto 0);
	dbg_p_irq_t0         : out std_logic_vector(7 downto 0);
	dbg_p_irq_t1         : out std_logic_vector(7 downto 0);
	dbg_p_irq_t2         : out std_logic_vector(7 downto 0);
	dbg_p_irq_t3         : out std_logic_vector(7 downto 0);
	-- v262: 4-deep ring of values written to $005C (DL IRQ-handler state
	-- counter) + total-write counter. Reveals $5C cycle directly on hw.
	dbg_wr5C_v0          : out std_logic_vector(7 downto 0);
	dbg_wr5C_v1          : out std_logic_vector(7 downto 0);
	dbg_wr5C_v2          : out std_logic_vector(7 downto 0);
	dbg_wr5C_v3          : out std_logic_vector(7 downto 0);
	dbg_cnt_wr5C         : out std_logic_vector(15 downto 0);
	-- v267: $D012 raster-IRQ tail-chain timing (Path B1).
	-- v266 ruled out collision-IRQ as the cause of SCPU's 3.755 IRQ
	-- entries/frame. Hypothesis: SCPU's slower emu-mode IRQ handler
	-- updates $D012 (raster compare) AFTER the raster has advanced
	-- past the new compare, so IRST re-asserts immediately and the
	-- CPU tail-chains on a single source pulse. These four signals
	-- snapshot the most recent CPU write to $D012:
	--   d012_write_cycles : clk32 cycles since LAST IRQ_N falling
	--                       edge (saturating at 0xFFFF). T65 ~ 320,
	--                       SCPU expected larger.
	--   d012_last_val     : value written.
	--   raster_at_d012    : raster line (0..311 PAL) at write moment.
	--                       If raster_at_d012 > d012_last_val,
	--                       compare register is BEHIND the beam.
	--   d012_last_pc      : writer PC (confirms IRQ-handler writer).
	-- d012_wr_count delta-per-frame quantifies write rate.
	dbg_d012_write_cycles : out std_logic_vector(15 downto 0);
	dbg_d012_last_val     : out std_logic_vector(7 downto 0);
	dbg_raster_at_d012    : out std_logic_vector(8 downto 0);
	dbg_d012_last_pc      : out std_logic_vector(23 downto 0);
	dbg_d012_wr_count     : out std_logic_vector(15 downto 0);
	-- v268: irq_vic rising-edge counter + combined rising-edge counter.
	dbg_irq_vic_rise_count   : out std_logic_vector(15 downto 0);
	dbg_irq_combined_rise_count : out std_logic_vector(15 downto 0);
	-- v269: VIC-internal IRQ ack diagnostics.
	--   vic_d019_wr_count   : myWr_a fires AND addr_r=$D019 inside the VIC
	--                         (regardless of di_r(0)). Distinct from the
	--                         existing dbg_d019_wr_count which counts CPU-side
	--                         attempts. T65 expected ~1/frame; SCPU=0 ⇒
	--                         alignment failure (write doesn't reach VIC's
	--                         myWr_a path at all).
	--   vic_resetraster_count : resetRasterIrq pulses (IRST being cleared).
	--                         T65 expected ~1/frame == vic_d019_wr_count.
	--                         If SCPU has vic_d019_wr_count>0 but
	--                         vic_resetraster_count=0 ⇒ data-bit-0 corruption.
	dbg_vic_d019_wr_count      : out std_logic_vector(15 downto 0);
	dbg_vic_resetraster_count  : out std_logic_vector(15 downto 0);
	-- v270: pinpoint who writes $D019 with bit-0 cleared on SCPU.
	--   d019_last_pc       : cpu_pc_now at most recent $D019 write.
	--   d019_seen_writes   : sticky 8-bit OR of cpuDo across all $D019
	--                        writes. If bit 0 stays 0 across the whole
	--                        capture on SCPU ⇒ SCPU NEVER writes a value
	--                        with bit 0 set ⇒ wrong handler is running.
	dbg_d019_last_pc           : out std_logic_vector(23 downto 0);
	dbg_d019_seen_writes       : out std_logic_vector(7 downto 0);
	-- v271: pinpoint the IRST-ack instruction.
	--   d019_ack_count : count of $D019 writes with cpuDo(0)=1
	--                    (the only writes that actually clear IRST).
	--                    T65 expects ~1/frame; SCPU expects 0/frame.
	--   d019_ack_pc    : cpu_pc_now at the most-recent ack write.
	--                    On T65 this points at the actual ack handler;
	--                    disasm + compare to SCPU's main-IRQ path to find
	--                    the divergent branch.
	dbg_d019_ack_count         : out std_logic_vector(15 downto 0);
	dbg_d019_ack_pc            : out std_logic_vector(23 downto 0);
	-- v280 doom triage: P65C816 stack pointer (16-bit), live every cycle.
	-- Confirms whether SP=$6C0X at the BRK loop in Doom.
	dbg_cpu_sp                 : out std_logic_vector(15 downto 0)
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
signal dbg_d018_bad_value_r: std_logic_vector(7 downto 0)  := (others => '0');
-- v211: 4-deep PC ring buffer, frozen on first D018 != $18 write
signal trace_pc0_r : std_logic_vector(23 downto 0) := (others => '0');
signal trace_pc1_r : std_logic_vector(23 downto 0) := (others => '0');
signal trace_pc2_r : std_logic_vector(23 downto 0) := (others => '0');
signal trace_pc3_r : std_logic_vector(23 downto 0) := (others => '0');
-- v223: parallel 4-deep opcode-byte ring. Captures cpuDi at the same
-- edge as the PC ring on opcode_fetch_pulse. Decoupled from PC: pairs
-- {trace_pc0, trace_op0} ... {trace_pc3, trace_op3}.
-- Tells us the actual byte at each captured PC. T65/SCPU both should
-- see the same opcode at the same address; if the bytes differ it's
-- RAM corruption, if the bytes are the same but ring chains differ
-- it's a CPU instruction-decode divergence.
signal trace_op0_r : std_logic_vector(7 downto 0) := (others => '0');
signal trace_op1_r : std_logic_vector(7 downto 0) := (others => '0');
signal trace_op2_r : std_logic_vector(7 downto 0) := (others => '0');
signal trace_op3_r : std_logic_vector(7 downto 0) := (others => '0');
signal trace_frozen_r : std_logic := '0';
-- v254: JSR ring. Pushes cpu_pc_now (lower 16 bits) on opcode_fetch_pulse
-- when cpuDi = $20 (JSR abs) or $22 (JSL abslong). Independent of trace
-- freeze. Captures the upstream callers that JSR'd into the writer.
-- t0=oldest, t3=newest. The newest JSR before $DF01 trigger reveals who
-- called the writer routine; older entries reveal the call chain.
signal jsr_pc_t0_r : std_logic_vector(15 downto 0) := (others => '0');
signal jsr_pc_t1_r : std_logic_vector(15 downto 0) := (others => '0');
signal jsr_pc_t2_r : std_logic_vector(15 downto 0) := (others => '0');
signal jsr_pc_t3_r : std_logic_vector(15 downto 0) := (others => '0');
-- v255: JMP-indirect target ring. After fetching $6C (JMP abs-indirect),
-- $7C (JMP abs,X), or $DC (JML long-indirect), the very next opcode
-- fetch IS the resolved target. Push that target's lower 16 bits to a
-- 4-deep ring. DL's IRQ stub at $0079..$008B does `JMP ($0002)` so this
-- ring captures which writer routine the $0002 vector pointed to at
-- each IRQ. T65 vs SCPU divergence here = the dispatcher chose
-- different writers despite the same vector address.
signal jmp_ind_pending_r : std_logic := '0';
signal jmp_tgt_t0_r : std_logic_vector(15 downto 0) := (others => '0');
signal jmp_tgt_t1_r : std_logic_vector(15 downto 0) := (others => '0');
signal jmp_tgt_t2_r : std_logic_vector(15 downto 0) := (others => '0');
signal jmp_tgt_t3_r : std_logic_vector(15 downto 0) := (others => '0');
-- v255: KERNAL IRQ-vector RAM bytes. Latched on every CPU READ of $0314
-- ($EA31 default points to KERNAL IRQ tail) and $0315. DL replaces this
-- vector to install its own raster handler. If T65 and SCPU read
-- different bytes here, the IRQ entry diverges.
signal mem_0314_r : std_logic_vector(7 downto 0) := (others => '0');
signal mem_0315_r : std_logic_vector(7 downto 0) := (others => '0');
-- v255: CPU IO port direction ($0000) + data ($0001). Bits in $0001
-- (LORAM/HIRAM/CHAREN) gate ROM/RAM visibility at $A000/$E000/$D000.
-- If SCPU has different value here, the SAME PC sees different bytes
-- in modes -- can produce wildly different code paths.
signal mem_00_r : std_logic_vector(7 downto 0) := (others => '0');
signal mem_01_r : std_logic_vector(7 downto 0) := (others => '0');
-- v219: opcode-fetch counter (free-running, never resets in normal op)
signal op_count_r : unsigned(23 downto 0) := (others => '0');
-- v228: I-flag diagnostics for SCPU.
--  scpu_iclr_r = '1' once dbg_p_816(2) was ever observed = 0 with SCPU
--                active. If stays '0', SCPU never reaches I=0 — IRQ off.
--  irq_vec_count_r = 16-bit counter of cpu reads from $FFFE/$FFFF
--                (IRQ vector fetches). T65 should tick this every raster
--                ISR; SCPU stays at 0 if no IRQ ever fires.
--  min_p_r = minimum dbg_p_816 value observed when SCPU active. Initial
--                $FF; tracks lowest P seen → reveals I-bit floor.
signal scpu_iclr_r      : std_logic := '0';
signal irq_vec_count_r  : unsigned(15 downto 0) := (others => '0');
signal min_p_r          : std_logic_vector(7 downto 0) := x"FF";
-- v229
signal rti_count_r      : unsigned(15 downto 0) := (others => '0');
signal nmi_vec_count_r  : unsigned(15 downto 0) := (others => '0');
-- v230
signal d019_wr_count_r  : unsigned(15 downto 0) := (others => '0');
signal dc0d_rd_count_r  : unsigned(15 downto 0) := (others => '0');
-- v231 IRQ source-level falling-edge counter
signal irq_combined     : std_logic;
signal irq_combined_d   : std_logic := '1';
signal irq_fall_count_r : unsigned(15 downto 0) := (others => '0');
-- v232 last $D019 write value
signal d019_last_val_r  : std_logic_vector(7 downto 0) := (others => '0');
-- v234 $D019 read-side probes
signal d019_last_read_r : std_logic_vector(7 downto 0) := (others => '0');
signal d019_seen_bits_r : std_logic_vector(3 downto 0) := (others => '0');
signal d01a_last_val_r  : std_logic_vector(7 downto 0) := (others => '0');
-- v235 sprite-control write probes
signal d015_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d015_last_pc_r   : std_logic_vector(23 downto 0) := (others => '0');
signal d015_wr_count_r  : unsigned(7 downto 0)          := (others => '0');
signal d017_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d01b_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d01c_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d01d_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
-- v236 sprite-position write probes
signal d000_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d001_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d001_last_pc_r   : std_logic_vector(23 downto 0) := (others => '0');
-- v267: $D012 raster-IRQ tail-chain timing.
signal cycles_since_irq_fall_r : unsigned(15 downto 0)         := (others => '0');
signal d012_write_cycles_r     : std_logic_vector(15 downto 0) := (others => '0');
signal d012_last_val_r         : std_logic_vector(7 downto 0)  := (others => '0');
signal raster_at_d012_r        : std_logic_vector(8 downto 0)  := (others => '0');
signal d012_last_pc_r          : std_logic_vector(23 downto 0) := (others => '0');
signal d012_wr_count_r         : unsigned(15 downto 0)         := (others => '0');
-- v268: VIC irq line rising-edge counter. v267 falsified the
-- "compare written behind beam" hypothesis. Direct test now: does
-- irq_vic actually rise on SCPU after $D019 ack? IF (combined) is
-- 0/frame on SCPU; counting irq_vic specifically isolates whether
-- the VIC's own IRST latch clears or whether some other source on
-- the irq_combined OR-chain holds combined low. Expected T65 rise
-- count == fall count. Expected SCPU rise count = 0 if IRST never
-- clears at VIC level.
signal irq_vic_d              : std_logic := '1';
signal irq_vic_rise_count_r   : unsigned(15 downto 0) := (others => '0');
signal irq_combined_rise_count_r : unsigned(15 downto 0) := (others => '0');
-- v269: VIC-internal $D019 ack diagnostics
signal vic_d019_wr_pulse        : std_logic := '0';
signal vic_resetraster_pulse    : std_logic := '0';
signal vic_d019_wr_count_r      : unsigned(15 downto 0) := (others => '0');
signal vic_resetraster_count_r  : unsigned(15 downto 0) := (others => '0');
-- v270: writer-PC + sticky write-OR at $D019.
signal d019_last_pc_r           : std_logic_vector(23 downto 0) := (others => '0');
signal d019_seen_writes_r       : std_logic_vector(7 downto 0)  := (others => '0');
-- v271: ack-write counter + ack-write PC latch.
-- Bumps only when CPU writes $D019 with cpuDo(0)=1 (the IRST-ack pattern).
-- d019_ack_pc_r captures the PC of the most-recent ack write so we can
-- disasm the actual ack instruction and find where SCPU branches off.
signal d019_ack_count_r         : unsigned(15 downto 0) := (others => '0');
signal d019_ack_pc_r            : std_logic_vector(23 downto 0) := (others => '0');
signal d002_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d003_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
signal d010_last_val_r  : std_logic_vector(7 downto 0)  := (others => '0');
-- v238 I-flag edge probes (sampled on opcode_fetch_pulse only)
signal p_i_prev_r       : std_logic                      := '1'; -- starts at I=1 (reset state)
signal p_set_pc_r       : std_logic_vector(23 downto 0)  := (others => '0');
signal p_clr_pc_r       : std_logic_vector(23 downto 0)  := (others => '0');
signal p_set_count_r    : unsigned(15 downto 0)          := (others => '0');
signal p_clr_count_r    : unsigned(15 downto 0)          := (others => '0');
signal p_opfetch_min_r  : std_logic_vector(7 downto 0)   := x"FF";
-- v239 IRQ vector + zero-page stub + $0314/$0315 + cpuIO snapshot
signal vec_lo_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal vec_hi_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_314_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_315_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_62_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_63_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_64_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal io_at_vec_r      : std_logic_vector(2 downto 0)   := (others => '0');
-- v240 extended stub bytes + RTI PC
signal mem_65_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_66_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_67_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_68_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_69_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_6A_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_6B_r         : std_logic_vector(7 downto 0)   := (others => '0');
-- v242: stub continuation $006C..$0073
signal mem_6C_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_6D_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_6E_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_6F_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_70_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_71_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_72_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_73_r         : std_logic_vector(7 downto 0)   := (others => '0');
-- v243: extend $0074..$0078 + dispatch-target PC tracker
signal mem_74_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_75_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_76_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_77_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_78_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal disp_target_pc_r : std_logic_vector(23 downto 0)  := (others => '0');
signal pc_was_zp_r      : std_logic                      := '0';
-- v244: dispatcher disasm + FLI verify + PC trace ring + write-PC
type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);
signal mem_3380_r       : byte_array_t(0 to 15)          := (others => (others => '0'));
signal mem_9F09_r       : byte_array_t(0 to 15)          := (others => (others => '0'));
signal disp2_target_pc_r: std_logic_vector(23 downto 0)  := (others => '0');
signal pc_was_33_r      : std_logic                      := '0';
signal pc33_t0_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal pc33_t1_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal pc33_t2_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal pc33_t3_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal wr70_pc_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal wr71_pc_r        : std_logic_vector(23 downto 0)  := (others => '0');
-- v245: bytes around the divergent writer at $335F + $3300/$3100
-- dispatcher entries + actual write VALUES at $0070/$0071.
signal mem_335D_r       : byte_array_t(0 to 15)          := (others => (others => '0')); -- $335D..$336C
signal mem_3300_r       : byte_array_t(0 to 7)           := (others => (others => '0')); -- $3300..$3307
signal mem_3100_r       : byte_array_t(0 to 7)           := (others => (others => '0')); -- $3100..$3107
signal wr70_val_r       : std_logic_vector(7 downto 0)   := (others => '0');
signal wr71_val_r       : std_logic_vector(7 downto 0)   := (others => '0');
-- v246: bytes $0079..$007F + dispatch counters
signal mem_79_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_7A_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_7B_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_7C_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_7D_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_7E_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_7F_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal cnt_3200_r       : std_logic_vector(15 downto 0)  := (others => '0');
signal cnt_3100_r       : std_logic_vector(15 downto 0)  := (others => '0');
-- v259: DL gate variables. Per x64sc disasm at $8100-$811C, the
-- per-IRQ game-advance gate is `LDA $44 / BNE $811C ; LDA $40 / BEQ $811C`.
-- T65 reaches JMP $1F4E (game advance, page $1F); SCPU goes to RTI tail
-- ($811C -> $8166) and never reaches $1Fxx. Capture $40/$44/$5C bytes
-- to localize which gate variable is corrupted on SCPU.
signal mem_40_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_44_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_5C_r         : std_logic_vector(7 downto 0)   := (others => '0');
-- v260: main-thread vs IRQ-thread PC split. Per v3 finding, gate at
-- $8108/$810E doesn't discriminate — divergence is in main-thread
-- code path after $309A->JMP $8F2B. Latch PC at last opcode fetch
-- gated by I-flag state. Plus mem_45 (wait-loop variable) and
-- per-page opcode counters for $30 (T65 FLI body) and $97 (SCPU
-- mirror).
signal pc_main_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal pc_irq_r         : std_logic_vector(23 downto 0)  := (others => '0');
signal mem_45_r         : std_logic_vector(7 downto 0)   := (others => '0');
-- v283 doom triage: latch-once first-writer-PC + DATA for $00:$6C03 writes.
signal first_w6c03_latched_r : std_logic := '0';
signal cnt_pc_30_r      : std_logic_vector(15 downto 0)  := (others => '0');
signal cnt_pc_97_r      : std_logic_vector(15 downto 0)  := (others => '0');
signal cpu_p_now        : std_logic_vector(7 downto 0);
-- v247: $5B + DF01 + bytes $0080-$008B
signal mem_5B_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal wr5B_pc_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal wr5B_val_r       : std_logic_vector(7 downto 0)   := (others => '0');
signal wr_df01_pc_r     : std_logic_vector(23 downto 0)  := (others => '0');
signal wr_df01_val_r    : std_logic_vector(7 downto 0)   := (others => '0');
signal cnt_df01_r       : std_logic_vector(15 downto 0)  := (others => '0');
signal mem_80_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_81_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_82_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_83_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_84_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_85_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_86_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_87_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_88_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_89_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_8A_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_8B_r         : std_logic_vector(7 downto 0)   := (others => '0');
-- v249: IRQ dispatch ptr + JMP operand high byte + 4-deep P ring
signal mem_8C_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_02_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal mem_03_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal wr02_pc_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal wr02_val_r       : std_logic_vector(7 downto 0)   := (others => '0');
signal wr03_pc_r        : std_logic_vector(23 downto 0)  := (others => '0');
signal wr03_val_r       : std_logic_vector(7 downto 0)   := (others => '0');
-- v256: counter of writes to $0002 (dispatch vector lo). Increments on
-- every cpuWe to $0002. T65 should tick this once per IRQ; SCPU should
-- tick it less often if dispatch-vector update is skipped.
signal cnt_wr02_r       : unsigned(15 downto 0)          := (others => '0');
-- v257: counter of writes to $0002 where new value DIFFERS from previous.
-- T65: cnt_wr02_chg ≈ cnt_wr02 (each IRQ fresh target).
-- SCPU: cnt_wr02_chg << cnt_wr02 (same target stored repeatedly).
signal cnt_wr02_chg_r   : unsigned(15 downto 0)          := (others => '0');
-- v258: 4-deep ring of $0002 values (newest=v3) + register state at write.
signal wr02_v0_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal wr02_v1_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal wr02_v2_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal wr02_v3_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal wr02_y_r         : std_logic_vector(7 downto 0)   := (others => '0');
signal wr02_x_r         : std_logic_vector(7 downto 0)   := (others => '0');
-- v262: 4-deep ring of $005C values (newest=v3) + total-write counter.
signal wr5C_v0_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal wr5C_v1_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal wr5C_v2_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal wr5C_v3_r        : std_logic_vector(7 downto 0)   := (others => '0');
signal cnt_wr5C_r       : unsigned(15 downto 0)          := (others => '0');
-- T65 register file (PC[16] | S[8] | P[8] | Y[8] | X[8] | A[8]).
signal t65_regs         : std_logic_vector(63 downto 0)  := (others => '0');
-- P65C816 X/Y register exports (formerly `open`).
signal dbg_x_816_i      : unsigned(15 downto 0);
signal dbg_y_816_i      : unsigned(15 downto 0);
signal dbg_sp_816_i     : unsigned(15 downto 0);
-- Muxed CPU X/Y at current cycle (zero-extends 8-bit T65 values).
signal cpu_x_now        : std_logic_vector(7 downto 0);
signal cpu_y_now        : std_logic_vector(7 downto 0);
signal p_irq_t0_r       : std_logic_vector(7 downto 0)   := (others => '0');
signal p_irq_t1_r       : std_logic_vector(7 downto 0)   := (others => '0');
signal p_irq_t2_r       : std_logic_vector(7 downto 0)   := (others => '0');
signal p_irq_t3_r       : std_logic_vector(7 downto 0)   := (others => '0');
-- Edge-detect for $FFFE vector fetch (rising edge of vec_lo grab)
signal vec_lo_grab_d    : std_logic                      := '0';
signal rti_pc_r         : std_logic_vector(23 downto 0)  := (others => '0');
-- v241 RTI-snapshot ring: pc_r{0,1} are a rolling 2-deep history of
-- opcode-fetch PCs (internal only). On RTI, copy them into rti_h{1,2}.
signal pc_r0            : std_logic_vector(23 downto 0)  := (others => '0');
signal pc_r1            : std_logic_vector(23 downto 0)  := (others => '0');
signal rti_h1_r         : std_logic_vector(23 downto 0)  := (others => '0');
signal rti_h2_r         : std_logic_vector(23 downto 0)  := (others => '0');
-- v218: skip-first-8 D8 writes counter. T65 only writes D8 a few
-- times during init (V never shows D8); SCPU writes D8 many times
-- in gameplay. Skip=8 lets us capture an actual gameplay corruption
-- chain (not the legitimate init write).
signal trigger_skip_r : unsigned(7 downto 0) := to_unsigned(8, 8);
signal cpu_pc_now : std_logic_vector(23 downto 0);
signal opcode_fetch_pulse : std_logic;
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
-- v266: gated diRegisters input to VIC. When SCPU is on, writes to
-- $D01A force EMBC/EMMC bits to 0 — disables sprite-bgnd and
-- sprite-sprite collision IRQ enables. v263/v264/v265 chain
-- diagnosed continuous collision tail-chain on SCPU as proximate
-- cause of DL rendering corruption. This gate tests the diagnosis.
signal vicRegsDi    : unsigned(7 downto 0);
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
         -- v285 — Native vector intercept + RTI sink (mini SCPU ROM stub).
         --
         -- All native vectors at $00:$FFE4..$FFEF point to $00:$FF00, which
         -- we mux to return $40 (RTI). On BRK/COP/ABORT/NMI/IRQ in native
         -- mode the CPU pushes 4 bytes, fetches the vector, jumps to $FF00,
         -- finds RTI, and silently returns. SP stays balanced.
         --
         -- Without this, $00:$FFE6/E7 reads C64 KERNAL ROM ($03 $6C), the
         -- BRK vector resolves to $00:$6C03 (RAM byte $00 = BRK opcode), and
         -- the CPU enters an unrecoverable BRK→push→fetch→BRK loop. Doom
         -- triggers a native BRK during boot/init and dies; v284 capture
         -- proved Doom never writes to $6C03, so no Doom-side fix exists.
         --
         -- Real SCPU has $FCxx trampolines (JML $00:$80xx) reached via the
         -- $FFExx vectors, with SCPU OS handlers RAM-loaded at $00:$80xx
         -- by the SCPU boot ROM. We have neither the boot ROM nor the OS
         -- image, so the RTI sink is the safest fallback.
         --
         -- Gated on emu_mode_816_i='0' (native mode only). Vanilla 6510/T65
         -- and SCPU emulation mode see KERNAL ROM bytes unchanged. Native
         -- mode is the only mode that fetches from $FFE0..$FFEF; emu mode
         -- BRK uses $FFFE/FF (untouched, normal C64 KERNAL flow).
         -- (Earlier scpu_hwenable gate was wrong — Doom's prologue does
         -- STA $D07F right after STA $D07E, clearing hwenable, so the
         -- override never fired during Doom's BRK.)
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE4") else  -- COP  L → $00:$FF00
         x"FF" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE5") else  -- COP  H
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE6") else  -- BRK  L → $00:$FF00
         x"FF" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE7") else  -- BRK  H
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE8") else  -- ABORT L → $00:$FF00
         x"FF" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE9") else  -- ABORT H
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEA") else  -- NMI  L → $00:$FF00
         x"FF" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEB") else  -- NMI  H
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEE") else  -- IRQ  L → $00:$FF00
         x"FF" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEF") else  -- IRQ  H
         x"40" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF00") else  -- RTI sink at $00:$FF00
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

-- v266 (REVERTED): tested gating CPU writes to $D01A bits 1+2 in SCPU
-- mode. Hardware result: zero effect on spr0_y, IRQ rate, or W1 PCs
-- — proved that DL on SCPU is NOT seeing extra collision IRQs
-- through $D01A. The 3.755 IRQ entries/frame on SCPU come from
-- raster-IRQ tail-chain timing instead. Reverted to passthrough.
vicRegsDi <= cpuDo;
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
	-- v233: experimental kludge — force lp_n=1 when SCPU=on so VIC's
	-- lightpen IRQ never asserts. Confirms whether LP is the source of
	-- the stuck-low irq_vic seen in v232 (V=0 always on SCPU).
	lp_n => cia1_pbi(4) or supercpu_en,

	aRegisters => cpuAddr(5 downto 0),
	diRegisters => vicRegsDi,
	di => vicDiAec,
	diColor => colorDataAec,
	do => vicData,

	vicAddr => vicAddr(13 downto 0),
	addrValid => aec,
	
	hsync => hSync,
	vsync => vSync,
	colorIndex => vicColorIndex,

	debugY => dbg_raster_y,

	irq_n => irq_vic,

	-- v269 VIC-internal IRQ ack diagnostics
	dbg_d019_wr_pulse     => vic_d019_wr_pulse,
	dbg_resetraster_pulse => vic_resetraster_pulse
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
	sync_out => t65_sync,
	regs => t65_regs
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
	dbg_sp    => dbg_sp_816_i,
	dbg_p     => dbg_p_816_i,
	dbg_ir    => open,
	dbg_pbr   => dbg_pbr_816_i,
	dbg_dbr   => dbg_dbr_816_i,
	dbg_x     => dbg_x_816_i,
	dbg_y     => dbg_y_816_i,
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
					when others => turbo_m <= "000"; -- GHDL: std_logic_vector is open-valued
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
			dbg_d018_bad_value_r <= (others => '0');
			trace_pc0_r          <= (others => '0');
			trace_pc1_r          <= (others => '0');
			trace_pc2_r          <= (others => '0');
			trace_pc3_r          <= (others => '0');
			trace_op0_r          <= (others => '0');
			trace_op1_r          <= (others => '0');
			trace_op2_r          <= (others => '0');
			trace_op3_r          <= (others => '0');
			trace_frozen_r       <= '0';
			-- v250: skip first 32 STA $DF01 writes so trace ring captures
			-- steady-state IRQ-handler call chain, not the loader's
			-- one-shot setup writes.
			trigger_skip_r       <= to_unsigned(32, 8);
			scpu_iclr_r          <= '0';
			irq_vec_count_r      <= (others => '0');
			min_p_r              <= x"FF";
			rti_count_r          <= (others => '0');
			nmi_vec_count_r      <= (others => '0');
			d019_wr_count_r      <= (others => '0');
			dc0d_rd_count_r      <= (others => '0');
			irq_combined_d       <= '1';
			irq_fall_count_r     <= (others => '0');
			d019_last_read_r     <= (others => '0');
			d019_seen_bits_r     <= (others => '0');
			d01a_last_val_r      <= (others => '0');
			d015_last_val_r      <= (others => '0');
			d015_last_pc_r       <= (others => '0');
			d015_wr_count_r      <= (others => '0');
			d017_last_val_r      <= (others => '0');
			d01b_last_val_r      <= (others => '0');
			d01c_last_val_r      <= (others => '0');
			d01d_last_val_r      <= (others => '0');
			d000_last_val_r      <= (others => '0');
			d001_last_val_r      <= (others => '0');
			d001_last_pc_r       <= (others => '0');
			-- v267: $D012 timing probe
			cycles_since_irq_fall_r <= (others => '0');
			d012_write_cycles_r     <= (others => '0');
			d012_last_val_r         <= (others => '0');
			raster_at_d012_r        <= (others => '0');
			d012_last_pc_r          <= (others => '0');
			d012_wr_count_r         <= (others => '0');
			-- v268: VIC IRQ rising-edge probes
			irq_vic_d                   <= '1';
			irq_vic_rise_count_r        <= (others => '0');
			irq_combined_rise_count_r   <= (others => '0');
			-- v269: VIC-internal $D019 ack diagnostics
			vic_d019_wr_count_r         <= (others => '0');
			vic_resetraster_count_r     <= (others => '0');
			-- v270: $D019 writer PC + sticky cpuDo-OR
			d019_last_pc_r              <= (others => '0');
			d019_seen_writes_r          <= (others => '0');
			-- v271: ack-write counter + ack-write PC
			d019_ack_count_r            <= (others => '0');
			d019_ack_pc_r               <= (others => '0');
			d002_last_val_r      <= (others => '0');
			d003_last_val_r      <= (others => '0');
			d010_last_val_r      <= (others => '0');
			-- v238 I-flag edge probes
			p_i_prev_r           <= '1';
			p_set_pc_r           <= (others => '0');
			p_clr_pc_r           <= (others => '0');
			p_set_count_r        <= (others => '0');
			p_clr_count_r        <= (others => '0');
			p_opfetch_min_r      <= x"FF";
			-- v239
			vec_lo_r             <= (others => '0');
			vec_hi_r             <= (others => '0');
			mem_314_r            <= (others => '0');
			mem_315_r            <= (others => '0');
			mem_62_r             <= (others => '0');
			mem_63_r             <= (others => '0');
			mem_64_r             <= (others => '0');
			io_at_vec_r          <= (others => '0');
			-- v240
			mem_65_r             <= (others => '0');
			mem_66_r             <= (others => '0');
			mem_67_r             <= (others => '0');
			mem_68_r             <= (others => '0');
			mem_69_r             <= (others => '0');
			mem_6A_r             <= (others => '0');
			mem_6B_r             <= (others => '0');
			mem_6C_r             <= (others => '0');
			mem_6D_r             <= (others => '0');
			mem_6E_r             <= (others => '0');
			mem_6F_r             <= (others => '0');
			mem_70_r             <= (others => '0');
			mem_71_r             <= (others => '0');
			mem_72_r             <= (others => '0');
			mem_73_r             <= (others => '0');
			mem_74_r             <= (others => '0');
			mem_75_r             <= (others => '0');
			mem_76_r             <= (others => '0');
			mem_77_r             <= (others => '0');
			mem_78_r             <= (others => '0');
			disp_target_pc_r     <= (others => '0');
			pc_was_zp_r          <= '0';
			-- v244 reset
			for i in 0 to 15 loop
				mem_3380_r(i) <= (others => '0');
				mem_9F09_r(i) <= (others => '0');
			end loop;
			disp2_target_pc_r    <= (others => '0');
			pc_was_33_r          <= '0';
			pc33_t0_r            <= (others => '0');
			pc33_t1_r            <= (others => '0');
			pc33_t2_r            <= (others => '0');
			pc33_t3_r            <= (others => '0');
			wr70_pc_r            <= (others => '0');
			wr71_pc_r            <= (others => '0');
			-- v245
			for i in 0 to 15 loop
				mem_335D_r(i) <= (others => '0');
			end loop;
			for i in 0 to 7 loop
				mem_3300_r(i) <= (others => '0');
				mem_3100_r(i) <= (others => '0');
			end loop;
			wr70_val_r           <= (others => '0');
			wr71_val_r           <= (others => '0');
			-- v246
			mem_79_r             <= (others => '0');
			mem_7A_r             <= (others => '0');
			mem_7B_r             <= (others => '0');
			mem_7C_r             <= (others => '0');
			mem_7D_r             <= (others => '0');
			mem_7E_r             <= (others => '0');
			mem_7F_r             <= (others => '0');
			cnt_3200_r           <= (others => '0');
			cnt_3100_r           <= (others => '0');
			-- v247
			-- v259
			mem_40_r             <= (others => '0');
			mem_44_r             <= (others => '0');
			mem_5C_r             <= (others => '0');
			-- v260
			pc_main_r            <= (others => '0');
			pc_irq_r             <= (others => '0');
			mem_45_r             <= (others => '0');
			first_w6c03_latched_r <= '0';
			cnt_pc_30_r          <= (others => '0');
			cnt_pc_97_r          <= (others => '0');
			mem_5B_r             <= (others => '0');
			wr5B_pc_r            <= (others => '0');
			wr5B_val_r           <= (others => '0');
			wr_df01_pc_r         <= (others => '0');
			wr_df01_val_r        <= (others => '0');
			cnt_df01_r           <= (others => '0');
			mem_80_r             <= (others => '0');
			mem_81_r             <= (others => '0');
			mem_82_r             <= (others => '0');
			mem_83_r             <= (others => '0');
			mem_84_r             <= (others => '0');
			mem_85_r             <= (others => '0');
			mem_86_r             <= (others => '0');
			mem_87_r             <= (others => '0');
			mem_88_r             <= (others => '0');
			mem_89_r             <= (others => '0');
			mem_8A_r             <= (others => '0');
			mem_8B_r             <= (others => '0');
			-- v249
			mem_8C_r             <= (others => '0');
			mem_02_r             <= (others => '0');
			mem_03_r             <= (others => '0');
			wr02_pc_r            <= (others => '0');
			wr02_val_r           <= (others => '0');
			wr03_pc_r            <= (others => '0');
			wr03_val_r           <= (others => '0');
			cnt_wr02_r           <= (others => '0');     -- v256
			cnt_wr02_chg_r       <= (others => '0');     -- v257
			wr02_v0_r            <= (others => '0');     -- v258
			wr02_v1_r            <= (others => '0');
			wr02_v2_r            <= (others => '0');
			wr02_v3_r            <= (others => '0');
			wr02_y_r             <= (others => '0');
			wr02_x_r             <= (others => '0');
			wr5C_v0_r            <= (others => '0');     -- v262
			wr5C_v1_r            <= (others => '0');
			wr5C_v2_r            <= (others => '0');
			wr5C_v3_r            <= (others => '0');
			cnt_wr5C_r           <= (others => '0');
			p_irq_t0_r           <= (others => '0');
			p_irq_t1_r           <= (others => '0');
			p_irq_t2_r           <= (others => '0');
			p_irq_t3_r           <= (others => '0');
			vec_lo_grab_d        <= '0';
			rti_pc_r             <= (others => '0');
			-- v241
			pc_r0                <= (others => '0');
			pc_r1                <= (others => '0');
			rti_h1_r             <= (others => '0');
			rti_h2_r             <= (others => '0');
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
						dbg_d018_bad_value_r <= std_logic_vector(cpuDo);
						-- v250: $9F13 trigger retired (v227-v249 history).
						-- Replaced by STA $DF01 trigger near line 2101.
						-- DL on this branch never reaches $9F13 reliably
						-- under either mode, so the old trigger never
						-- fired in steady state.
					end if;
				elsif cpuAddr(5 downto 0) = "010110" then
					dbg_d016_r <= std_logic_vector(cpuDo);
				end if;
			end if;

			-- v219: opcode-fetch throughput counter. Free-running 24-bit;
			-- consumer subtracts samples to get opcodes/frame.
			if opcode_fetch_pulse = '1' then
				op_count_r <= op_count_r + 1;
			end if;

			-- v228: track if SCPU's I-flag ever clears, count IRQ vector
			-- fetches, and track minimum P observed for SCPU.
			if supercpu_en = '1' then
				if dbg_p_816_i(2) = '0' then
					scpu_iclr_r <= '1';
				end if;
				if unsigned(dbg_p_816_i) < unsigned(min_p_r) then
					min_p_r <= std_logic_vector(dbg_p_816_i);
				end if;
			end if;
			-- IRQ vector fetch detection. Active CPU reading $00FFFE or
			-- $00FFFF (or $FFEE/F in native mode) — vector fetch. We use
			-- cpuAddr_pre because that's the muxed pre-DMA address.
			-- enableCpu gates so we sample on a CPU cycle, not idle.
			if enableCpu = '1' and cpuWe_pre = '0'
			   and cpuAddr_pre(15 downto 1) = "111111111111111" then
				-- match $FFFE or $FFFF (low bit don't-care)
				irq_vec_count_r <= irq_vec_count_r + 1;
			end if;

			-- v249: P-flag ring at IRQ entry. Sample dbg_p_816_i on the
			-- first byte of the vector fetch ($FFFE). t3 = newest, t0 =
			-- oldest. Reveals D / V / C flag drift across IRQs that could
			-- divert the SCPU handler vs T65.
			if enableCpu = '1' and cpuWe_pre = '0' and cpuAddr_pre = x"FFFE" then
				p_irq_t0_r <= p_irq_t1_r;
				p_irq_t1_r <= p_irq_t2_r;
				p_irq_t2_r <= p_irq_t3_r;
				p_irq_t3_r <= std_logic_vector(dbg_p_816_i);
			end if;

			-- v239: latch byte values at key IRQ-vector and stub addresses
			-- so we can compare T65 vs SCPU. Ungated on supercpu_en — the
			-- *active* CPU's reads populate these regardless of mode. Use
			-- cpuDi (data into CPU) which is the read result.
			if enableCpu = '1' and cpuWe_pre = '0' then
				if cpuAddr_pre = x"FFFE" then
					vec_lo_r    <= std_logic_vector(cpuDi);
					io_at_vec_r <= std_logic_vector(cpuIO(2 downto 0));
				end if;
				if cpuAddr_pre = x"FFFF" then
					vec_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0314" then
					mem_314_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0315" then
					mem_315_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0062" then
					mem_62_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0063" then
					mem_63_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0064" then
					mem_64_r <= std_logic_vector(cpuDi);
				end if;
				-- v240: more stub bytes
				if cpuAddr_pre = x"0065" then
					mem_65_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0066" then
					mem_66_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0067" then
					mem_67_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0068" then
					mem_68_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0069" then
					mem_69_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"006A" then
					mem_6A_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"006B" then
					mem_6B_r <= std_logic_vector(cpuDi);
				end if;
				-- v242: continuation past STA $6F
				if cpuAddr_pre = x"006C" then
					mem_6C_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"006D" then
					mem_6D_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"006E" then
					mem_6E_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"006F" then
					mem_6F_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0070" then
					mem_70_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0071" then
					mem_71_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0072" then
					mem_72_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0073" then
					mem_73_r <= std_logic_vector(cpuDi);
				end if;
				-- v243 extended stub bytes
				if cpuAddr_pre = x"0074" then
					mem_74_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0075" then
					mem_75_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0076" then
					mem_76_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0077" then
					mem_77_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0078" then
					mem_78_r <= std_logic_vector(cpuDi);
				end if;
				-- v246: $0079..$007F to find the dispatch JMP
				if cpuAddr_pre = x"0079" then mem_79_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"007A" then mem_7A_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"007B" then mem_7B_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"007C" then mem_7C_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"007D" then mem_7D_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"007E" then mem_7E_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"007F" then mem_7F_r <= std_logic_vector(cpuDi); end if;
				-- v282 doom triage: latch SuperRAM bank $01:$6C00/$6C03/$6C05 reads
				-- via cpuDi. (Bank-$01-mirror hypothesis was disproven 2026-05-05:
				-- bank $01:$6C00..$6C07 readout was all $00, plus bank $00 BRAM is
				-- reset on core reload so a peek-PRG cannot read post-Doom $00:$6Cxx.)
				-- v283 latch-once first-writer-PC for $00:$6C03 lives in the
				-- cpuWe_pre='1' block below (around the wr02_pc_r area).
				-- v260: PC main/irq split + page counters, gated by opcode_fetch_pulse
				if opcode_fetch_pulse = '1' then
					if cpu_p_now(2) = '0' then
						pc_main_r <= cpu_pc_now;
					else
						pc_irq_r <= cpu_pc_now;
					end if;
					if cpu_pc_now(15 downto 8) = x"30" then
						cnt_pc_30_r <= std_logic_vector(unsigned(cnt_pc_30_r) + 1);
					end if;
					if cpu_pc_now(15 downto 8) = x"97" then
						cnt_pc_97_r <= std_logic_vector(unsigned(cnt_pc_97_r) + 1);
					end if;
				end if;
				-- v247: $005B + $0080-$008B byte capture
				if cpuAddr_pre = x"005B" then mem_5B_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0080" then mem_80_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0081" then mem_81_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0082" then mem_82_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0083" then mem_83_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0084" then mem_84_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0085" then mem_85_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0086" then mem_86_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0087" then mem_87_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0088" then mem_88_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0089" then mem_89_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"008A" then mem_8A_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"008B" then mem_8B_r <= std_logic_vector(cpuDi); end if;
				-- v249: $008C (JMP indirect operand high byte) + $0002/$0003
				-- (the actual dispatch ptr if JMP ($0002))
				if cpuAddr_pre = x"008C" then mem_8C_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0002" then mem_02_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0003" then mem_03_r <= std_logic_vector(cpuDi); end if;
				-- v244: bytes at $3380..$338F (dispatcher disasm).
				-- cpuAddr_pre is 16 bits, top 12 bits select the
				-- $338x range. Index into the byte array by low 4
				-- bits of cpuAddr_pre.
				if cpuAddr_pre(15 downto 4) = x"338" then
					mem_3380_r(to_integer(unsigned(cpuAddr_pre(3 downto 0))))
						<= std_logic_vector(cpuDi);
				end if;
				-- v244: bytes at $9F09..$9F18 (FLI body verify).
				-- $9F09..$9F0F = low nibble 9..F of $9F0x; then
				-- $9F10..$9F18 = low nibble 0..8 of $9F1x.
				if cpuAddr_pre(15 downto 4) = x"9F0"
				   and unsigned(cpuAddr_pre(3 downto 0)) >= 9 then
					-- offsets 0..6 of mem_9F09_r
					mem_9F09_r(to_integer(unsigned(cpuAddr_pre(3 downto 0))) - 9)
						<= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre(15 downto 4) = x"9F1"
				   and unsigned(cpuAddr_pre(3 downto 0)) <= 8 then
					-- offsets 7..15 of mem_9F09_r
					mem_9F09_r(to_integer(unsigned(cpuAddr_pre(3 downto 0))) + 7)
						<= std_logic_vector(cpuDi);
				end if;
				-- v245: bytes at $335D..$336C (writer + context).
				-- $335D..$335F = low nibble D..F of $335x; then
				-- $3360..$336C = low nibble 0..C of $336x. Index
				-- offsets: 0..2 = D,E,F at $335x; 3..15 = 0..C at $336x.
				if cpuAddr_pre(15 downto 4) = x"335"
				   and unsigned(cpuAddr_pre(3 downto 0)) >= 13 then
					-- $335D..$335F => offsets 0..2
					mem_335D_r(to_integer(unsigned(cpuAddr_pre(3 downto 0))) - 13)
						<= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre(15 downto 4) = x"336"
				   and unsigned(cpuAddr_pre(3 downto 0)) <= 12 then
					-- $3360..$336C => offsets 3..15
					mem_335D_r(to_integer(unsigned(cpuAddr_pre(3 downto 0))) + 3)
						<= std_logic_vector(cpuDi);
				end if;
				-- v245: bytes at $3300..$3307 (other dispatcher entry).
				if cpuAddr_pre(15 downto 4) = x"330"
				   and cpuAddr_pre(3) = '0' then
					mem_3300_r(to_integer(unsigned(cpuAddr_pre(2 downto 0))))
						<= std_logic_vector(cpuDi);
				end if;
				-- v245: bytes at $3100..$3107 (chain handler entry).
				if cpuAddr_pre(15 downto 4) = x"310"
				   and cpuAddr_pre(3) = '0' then
					mem_3100_r(to_integer(unsigned(cpuAddr_pre(2 downto 0))))
						<= std_logic_vector(cpuDi);
				end if;
			end if;
			-- v244: write-PC capture for $0070 / $0071 (zero-page vars
			-- that diverge T65/SCPU per v242). Trigger on cpuWe_pre.
			-- v245: also capture cpuDo (actual stored byte) at the same
			-- write cycle.
			-- v247: also capture write to $5B (suspect — the IRQ stub
			-- LDAs from $5B then writes to REU $DF01) and to $DF01
			-- (REU command — readback differs T65=$31 vs SCPU=$7D).
			if enableCpu = '1' and cpuWe_pre = '1' then
				if cpuAddr_pre = x"0070" then
					wr70_pc_r  <= cpu_pc_now;
					wr70_val_r <= std_logic_vector(cpuDo_pre);
				end if;
				if cpuAddr_pre = x"0071" then
					wr71_pc_r  <= cpu_pc_now;
					wr71_val_r <= std_logic_vector(cpuDo_pre);
				end if;
				if cpuAddr_pre = x"005B" then
					wr5B_pc_r  <= cpu_pc_now;
					wr5B_val_r <= std_logic_vector(cpuDo_pre);
				end if;
				if cpuAddr_pre = x"DF01" then
					wr_df01_pc_r  <= cpu_pc_now;
					wr_df01_val_r <= std_logic_vector(cpuDo_pre);
					cnt_df01_r    <= std_logic_vector(unsigned(cnt_df01_r) + 1);
					-- v252: filter trigger to skip $832C (the shared immediate-
					-- DMA REU-setup writer reached by both modes) and capture
					-- the ALTERNATE $FD-writer routes. T65 visits $852B/
					-- $805F/$8835; SCPU visits $8062/$8028/$862C rarely.
					-- The trace ring will pick up WHICHEVER alternate route
					-- the mode reaches first, plus its 4-deep call chain.
					if trace_frozen_r = '0'
					   and cpu_pc_now(15 downto 12) = x"8"
					   and cpu_pc_now(11 downto 0) /= x"32C" then
						trace_frozen_r <= '1';
					end if;
				end if;
				-- v249: writers to $0002 / $0003 (the JMP ($0002) target ptr
				-- if mem_8C=$00). Whoever wrote to these bytes upstream
				-- defined the IRQ dispatch destination.
				-- v279 doom triage: WP repurposed — capture writer-PC of any write
				-- to bank $00:$6C00..$6C07 (Doom's stuck-region). If a write happens
				-- here, WP shows the PC of the writing instruction, telling us who
				-- corrupted bank $00:$6C00 (currently $AB) or $6C03 ($00 BRK).
				-- v287 doom triage: latch $00:$0074..$0076 (JML [$0074] dispatch ptr).
				-- v286 RTI sink unblocked the BRK loop — Doom now halts via
				-- JML [$0074] → $2C:$A95C after printing "Bad music number -9".
				-- mem_40/44/5C show what dispatch ptr Doom installed; G:## ## ##
				-- in UART = $0074 / $0075 / $0076 = full 24-bit JML target.
				-- (Earlier v283 first-writer-PC latch retired — it established
				-- G:00 00 00 so Doom never writes $6C03; that's now in commit
				-- 906bc0c memory.)
				if addr_hi_816 = x"00" and cpuAddr_pre = x"0074" then
					mem_40_r <= std_logic_vector(cpuDo_pre);
				end if;
				if addr_hi_816 = x"00" and cpuAddr_pre = x"0075" then
					mem_44_r <= std_logic_vector(cpuDo_pre);
				end if;
				if addr_hi_816 = x"00" and cpuAddr_pre = x"0076" then
					mem_5C_r <= std_logic_vector(cpuDo_pre);
				end if;
				if addr_hi_816 = x"00" and cpuAddr_pre = x"0045" then
					mem_45_r <= std_logic_vector(cpuDo_pre);
				end if;
				if addr_hi_816 = x"00"
				   and cpuAddr_pre(15 downto 8) = x"6C"
				   and cpuAddr_pre(7 downto 3) = "00000" then
					wr02_pc_r  <= cpu_pc_now;
					wr02_val_r <= std_logic_vector(cpuDo_pre);
					cnt_wr02_r <= cnt_wr02_r + 1;
					-- v257: increment chg counter only when new ≠ previous.
					-- wr02_val_r still holds the previous-cycle value here.
					if std_logic_vector(cpuDo_pre) /= wr02_val_r then
						cnt_wr02_chg_r <= cnt_wr02_chg_r + 1;
					end if;
					-- v258: push value into 4-deep ring (newest = v3).
					wr02_v0_r <= wr02_v1_r;
					wr02_v1_r <= wr02_v2_r;
					wr02_v2_r <= wr02_v3_r;
					wr02_v3_r <= std_logic_vector(cpuDo_pre);
					-- v258: latch register state at the write.
					wr02_y_r  <= cpu_y_now;
					wr02_x_r  <= cpu_x_now;
				end if;
				if cpuAddr_pre = x"0003" then
					wr03_pc_r  <= cpu_pc_now;
					wr03_val_r <= std_logic_vector(cpuDo_pre);
				end if;
				-- v262: ring of values written to $005C (DL IRQ counter).
				-- Writers are STX $5C at $8166 (decremented X) and STA $5C
				-- at $3343 (setup-time reset). Newest = v3.
				if cpuAddr_pre = x"005C" then
					wr5C_v0_r  <= wr5C_v1_r;
					wr5C_v1_r  <= wr5C_v2_r;
					wr5C_v2_r  <= wr5C_v3_r;
					wr5C_v3_r  <= std_logic_vector(cpuDo_pre);
					cnt_wr5C_r <= cnt_wr5C_r + 1;
				end if;
			end if;
			-- v243: dispatch-target PC. Snapshot the PC at the FIRST
			-- opcode_fetch_pulse where PC leaves the zero-page-stub
			-- range ($00xx). Tracks what handler the $0062 IRQ stub
			-- jumps to. Updates only on zp→non-zp transition; stays
			-- latched until the next dispatch happens.
			-- v244: also capture disp2_target_pc (first non-$33xx PC
			-- after PC was at $33xx) and the 4-deep PC trace ring
			-- restricted to $33xx (execution path through dispatcher).
			if opcode_fetch_pulse = '1' then
				if pc_was_zp_r = '1' and cpu_pc_now(15 downto 8) /= x"00" then
					disp_target_pc_r <= cpu_pc_now;
				end if;
				if cpu_pc_now(15 downto 8) = x"00" then
					pc_was_zp_r <= '1';
				else
					pc_was_zp_r <= '0';
				end if;
				-- v244: 2nd-level dispatch — first PC outside $33xx
				-- after a $33xx PC. Should match RTI ring head
				-- ($9F09 / $811C / $1Cxx etc.).
				-- v246: bump counters when target is $3200 (FLI/gameplay
				-- via $3300) or $3100 (chain via $3380). Quantifies the
				-- ratio T65 (~50/50) vs SCPU (biased to $3100).
				if pc_was_33_r = '1' and cpu_pc_now(15 downto 8) /= x"33" then
					disp2_target_pc_r <= cpu_pc_now;
					if cpu_pc_now(15 downto 0) = x"3200" then
						cnt_3200_r <= std_logic_vector(unsigned(cnt_3200_r) + 1);
					end if;
					if cpu_pc_now(15 downto 0) = x"3100" then
						cnt_3100_r <= std_logic_vector(unsigned(cnt_3100_r) + 1);
					end if;
				end if;
				if cpu_pc_now(15 downto 8) = x"33" then
					pc_was_33_r <= '1';
				else
					pc_was_33_r <= '0';
				end if;
				-- v244: 4-deep PC trace ring while PC[15:8]=$33.
				-- Shifts only when the fetch is in the $33xx range,
				-- so we capture the dispatcher's exact instruction
				-- sequence (no out-of-range pollution).
				if cpu_pc_now(15 downto 8) = x"33" then
					pc33_t3_r <= pc33_t2_r;
					pc33_t2_r <= pc33_t1_r;
					pc33_t1_r <= pc33_t0_r;
					pc33_t0_r <= cpu_pc_now;
				end if;
			end if;
			-- v240/v241: PC at RTI + 2 PCs leading up to it. pc_r0/pc_r1
			-- are an internal 2-deep rolling history of opcode-fetch PCs;
			-- when an RTI is fetched, snapshot the current PC + pc_r0 +
			-- pc_r1 into rti_pc_r / rti_h1_r / rti_h2_r. Sequence
			-- semantics: rti_h2 -> rti_h1 -> rti_pc (RTI itself).
			if opcode_fetch_pulse = '1' then
				if cpuDi = x"40" then
					rti_pc_r <= cpu_pc_now;
					rti_h1_r <= pc_r0;
					rti_h2_r <= pc_r1;
				end if;
				-- shift rolling history every opcode (RTI included)
				pc_r0 <= cpu_pc_now;
				pc_r1 <= pc_r0;
			end if;

			-- v229: NMI vector fetch detection ($FFFA / $FFFB).
			if enableCpu = '1' and cpuWe_pre = '0'
			   and cpuAddr_pre(15 downto 1) = "111111111111101" then
				nmi_vec_count_r <= nmi_vec_count_r + 1;
			end if;

			-- v229: RTI execution. Detect $40 opcode at fetch pulse.
			-- Pairs with IRQ entry: should match irq-entries (= IV/2)
			-- in steady state. If RTI count << IRQ entries, handler
			-- re-enters mid-execution = tail-chain bug.
			if opcode_fetch_pulse = '1' and cpuDi = x"40" then
				rti_count_r <= rti_count_r + 1;
			end if;

			-- v230: $D019 write count (VIC IRQ ack). cs_vic gated to
			-- VIC chip-select; cpuWe = active write; offset $19 = D019.
			-- v270: also latch writer PC and OR cpuDo into a sticky
			-- accumulator. d019_seen_writes_r reveals whether any write
			-- in the entire capture had bit 0 set (= valid IRST ack).
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "011001" then
				d019_wr_count_r    <= d019_wr_count_r + 1;
				d019_last_val_r    <= std_logic_vector(cpuDo);
				d019_last_pc_r     <= cpu_pc_now;
				d019_seen_writes_r <= d019_seen_writes_r or std_logic_vector(cpuDo);
				-- v271: a "real" IRST ack write has cpuDo bit 0 = 1.
				-- Count those separately and capture their PC. v269
				-- expects T65 ~1/frame, SCPU 0/frame.
				if cpuDo(0) = '1' then
					d019_ack_count_r <= d019_ack_count_r + 1;
					d019_ack_pc_r    <= cpu_pc_now;
				end if;
			end if;
			-- v230: $DC0D read count (CIA1 ICR, read-to-ack).
			if cs_cia1 = '1' and cpuWe = '0' and cpuAddr(3 downto 0) = "1101" then
				dc0d_rd_count_r <= dc0d_rd_count_r + 1;
			end if;

			-- v234: $D019 read value latch + sticky bits-seen mask. cpuDi
			-- carries VIC's `do` output during a $D019 read. Bits 0-3 are
			-- the IRST/IMBC/IMMC/ILP latches that VIC currently exposes to
			-- the CPU. seen_bits accumulates which sources have EVER been
			-- observed set across all reads — diagnoses whether SCPU's
			-- handler dispatch is reading a different mix of sources than
			-- T65's handler. Saturating sticky OR.
			if cs_vic = '1' and cpuWe = '0' and cpuAddr(5 downto 0) = "011001" then
				d019_last_read_r <= std_logic_vector(cpuDi);
				d019_seen_bits_r <= d019_seen_bits_r or std_logic_vector(cpuDi(3 downto 0));
			end if;

			-- v234: $D01A write value latch (VIC IRQ enable mask).
			-- Tells us which IRQ sources DL has enabled. If T65 and SCPU
			-- end up with different enable masks, the upstream branch
			-- divergence already happened during VIC setup.
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "011010" then
				d01a_last_val_r <= std_logic_vector(cpuDo);
			end if;

			-- v235: sprite-control register write probes. Five regs
			-- ($D015/$D017/$D01B/$D01C/$D01D) latch last-written byte.
			-- $D015 additionally latches PBR:PC of the writer + saturates
			-- an 8-bit write counter (frequency hint: per-frame
			-- multiplexer vs setup-time enable).
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "010101" then
				d015_last_val_r <= std_logic_vector(cpuDo);
				d015_last_pc_r  <= cpu_pc_now;
				if d015_wr_count_r /= x"FF" then
					d015_wr_count_r <= d015_wr_count_r + 1;
				end if;
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "010111" then
				d017_last_val_r <= std_logic_vector(cpuDo);
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "011011" then
				d01b_last_val_r <= std_logic_vector(cpuDo);
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "011100" then
				d01c_last_val_r <= std_logic_vector(cpuDo);
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "011101" then
				d01d_last_val_r <= std_logic_vector(cpuDo);
			end if;

			-- v236: sprite-position write probes. Latch last-written
			-- byte for sprite 0/1 X/Y ($D000-$D003) + $D010 high-X bits.
			-- Sprite control was identical T65 vs SCPU; if positions
			-- differ here, sprite-sprite collision IRQ asymmetry is
			-- explained.
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "000000" then
				d000_last_val_r <= std_logic_vector(cpuDo);
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "000001" then
				d001_last_val_r <= std_logic_vector(cpuDo);
				d001_last_pc_r  <= cpu_pc_now;
			end if;
			-- v267: $D012 (raster compare) write capture for tail-chain
			-- timing analysis. Snapshot cycles since last IRQ_N falling
			-- edge, value being written, current raster line, writer PC.
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "010010" then
				d012_write_cycles_r <= std_logic_vector(cycles_since_irq_fall_r);
				d012_last_val_r     <= std_logic_vector(cpuDo);
				raster_at_d012_r    <= std_logic_vector(dbg_raster_y);
				d012_last_pc_r      <= cpu_pc_now;
				d012_wr_count_r     <= d012_wr_count_r + 1;
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "000010" then
				d002_last_val_r <= std_logic_vector(cpuDo);
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "000011" then
				d003_last_val_r <= std_logic_vector(cpuDo);
			end if;
			if cs_vic = '1' and cpuWe = '1' and cpuAddr(5 downto 0) = "010000" then
				d010_last_val_r <= std_logic_vector(cpuDo);
			end if;

			-- v238: I-flag edge probes. Sample P(2) at opcode_fetch only,
			-- so we don't catch transient values inside multi-cycle
			-- microcode (BRK/IRQ entry, RTI). The PC at the moment of an
			-- I-flag edge identifies the first instruction that observes
			-- the new I value:
			--   - 0->1 edge PC = first opcode of IRQ handler / after SEI
			--   - 1->0 edge PC = first opcode after RTI / after CLI
			-- Counts let us see how often each transition occurs.
			-- p_opfetch_min separates "main code has I=1" (= still ~$34)
			-- from "I=0 only seen inside IRQ entry" (v237 saw min=$30
			-- but every-clock sampling can't tell us if that was at an
			-- instruction boundary).
			if supercpu_en = '1' and opcode_fetch_pulse = '1' then
				if p_i_prev_r = '0' and dbg_p_816_i(2) = '1' then
					p_set_pc_r    <= cpu_pc_now;
					p_set_count_r <= p_set_count_r + 1;
				elsif p_i_prev_r = '1' and dbg_p_816_i(2) = '0' then
					p_clr_pc_r    <= cpu_pc_now;
					p_clr_count_r <= p_clr_count_r + 1;
				end if;
				p_i_prev_r <= dbg_p_816_i(2);
				if unsigned(dbg_p_816_i) < unsigned(p_opfetch_min_r) then
					p_opfetch_min_r <= std_logic_vector(dbg_p_816_i);
				end if;
			end if;

			-- v231: combined IRQ_N falling edges (source-side firing rate).
			-- Each true raster IRQ produces one 1->0 edge; tail-chain inside
			-- CPU doesn't move this counter. T65 IV/2 should match this; if
			-- SCPU IV/2 >> this, CPU is re-entering on a single source pulse.
			-- v267: also reset cycles_since_irq_fall_r on the same edge so
			-- the next $D012 write captures wall-clock time spent in the
			-- handler before raster compare gets re-armed.
			irq_combined_d <= irq_combined;
			if irq_combined_d = '1' and irq_combined = '0' then
				irq_fall_count_r        <= irq_fall_count_r + 1;
				cycles_since_irq_fall_r <= (others => '0');
			elsif cycles_since_irq_fall_r /= x"FFFF" then
				cycles_since_irq_fall_r <= cycles_since_irq_fall_r + 1;
			end if;
			-- v268: irq_combined rising-edge counter (0->1 transitions).
			if irq_combined_d = '0' and irq_combined = '1' then
				irq_combined_rise_count_r <= irq_combined_rise_count_r + 1;
			end if;
			-- v268: irq_vic rising-edge counter (specifically the VIC's
			-- own IRQ output line, before AND with cia1/nmi/external).
			-- If irq_vic rises, VIC IRST has been cleared. If irq_vic
			-- never rises after the first fall, $D019 ack writes are
			-- not reaching the VIC's resetRasterIrq pulse path.
			irq_vic_d <= irq_vic;
			if irq_vic_d = '0' and irq_vic = '1' then
				irq_vic_rise_count_r <= irq_vic_rise_count_r + 1;
			end if;

			-- v269: VIC-internal $D019 ack diagnostics. Both signals are
			-- 1-clk32 pulses generated inside the VIC. vic_d019_wr_count
			-- ticks every time myWr_a fires with addr_r=$D019 regardless
			-- of di_r(0). vic_resetraster_count ticks every time the VIC's
			-- internal resetRasterIrq pulses (IRST clear).
			if vic_d019_wr_pulse = '1' then
				vic_d019_wr_count_r <= vic_d019_wr_count_r + 1;
			end if;
			if vic_resetraster_pulse = '1' then
				vic_resetraster_count_r <= vic_resetraster_count_r + 1;
			end if;

			-- v211: PC ring buffer push on opcode-fetch pulses, only while
			-- not frozen. cpu_pc_now / opcode_fetch_pulse are concurrent.
			-- v223: parallel opcode-byte ring captures cpuDi at the same
			-- edge. {pcN, opN} are paired entries.
			if trace_frozen_r = '0' and opcode_fetch_pulse = '1' then
				trace_pc0_r <= trace_pc1_r;
				trace_pc1_r <= trace_pc2_r;
				trace_pc2_r <= trace_pc3_r;
				trace_pc3_r <= cpu_pc_now;
				trace_op0_r <= trace_op1_r;
				trace_op1_r <= trace_op2_r;
				-- (continued below; trace_op2_r / trace_op3_r assignment kept
				-- adjacent in original block; the v254 JSR ring is updated
				-- BELOW, after this block, so it lives independent of the
				-- trace_frozen gate.)
				trace_op2_r <= trace_op3_r;
				trace_op3_r <= std_logic_vector(cpuDi);
			end if;
			-- v254: JSR ring. Always-live (NOT gated by trace_frozen_r), so
			-- each screenshot captures the *most recent* 4 JSRs even after
			-- the writer trigger has fired. cpuDi = $20 (JSR abs) or $22
			-- (JSL abslong) at opcode_fetch_pulse defines a JSR fetch. Push
			-- the JSR's own PC (lower 16 bits) into the ring so the entry
			-- IS the caller's address. t0 = oldest, t3 = newest.
			if opcode_fetch_pulse = '1' and (cpuDi = x"20" or cpuDi = x"22") then
				jsr_pc_t0_r <= jsr_pc_t1_r;
				jsr_pc_t1_r <= jsr_pc_t2_r;
				jsr_pc_t2_r <= jsr_pc_t3_r;
				jsr_pc_t3_r <= cpu_pc_now(15 downto 0);
			end if;
			-- v255: JMP-indirect target ring. Two-step: (a) on opcode fetch
			-- of $6C/$7C/$DC, set jmp_ind_pending_r; (b) on the NEXT
			-- opcode_fetch_pulse, the cpu_pc_now IS the target -- push to
			-- ring and clear flag. Ordering inside this if-block matters:
			-- check pending FIRST (so the same fetch that resolves a target
			-- doesn't also re-arm pending if the target is itself JMP ind).
			if opcode_fetch_pulse = '1' then
				if jmp_ind_pending_r = '1' then
					jmp_tgt_t0_r <= jmp_tgt_t1_r;
					jmp_tgt_t1_r <= jmp_tgt_t2_r;
					jmp_tgt_t2_r <= jmp_tgt_t3_r;
					jmp_tgt_t3_r <= cpu_pc_now(15 downto 0);
					jmp_ind_pending_r <= '0';
				end if;
				if cpuDi = x"6C" or cpuDi = x"7C" or cpuDi = x"DC" then
					jmp_ind_pending_r <= '1';
				end if;
			end if;
			-- v255: latch RAM bytes on CPU read. cpuWe_pre='0' = read; we
			-- snoop cpuDi at the cycle the address bus has cpuAddr_pre.
			if enableCpu = '1' and cpuWe_pre = '0' then
				if cpuAddr_pre = x"0314" then
					mem_0314_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0315" then
					mem_0315_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0000" then
					mem_00_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0001" then
					mem_01_r <= std_logic_vector(cpuDi);
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
dbg_d018_bad_value   <= dbg_d018_bad_value_r;
dbg_trace_pc0        <= trace_pc0_r;
dbg_trace_pc1        <= trace_pc1_r;
dbg_trace_pc2        <= trace_pc2_r;
dbg_trace_pc3        <= trace_pc3_r;
dbg_trace_op0        <= trace_op0_r;
dbg_trace_op1        <= trace_op1_r;
dbg_trace_op2        <= trace_op2_r;
dbg_trace_op3        <= trace_op3_r;
dbg_trace_frozen     <= trace_frozen_r;
-- v254: JSR ring outputs (lower 16 bits of last 4 JSR/JSL fetches)
dbg_jsr_pc_t0        <= jsr_pc_t0_r;
dbg_jsr_pc_t1        <= jsr_pc_t1_r;
dbg_jsr_pc_t2        <= jsr_pc_t2_r;
dbg_jsr_pc_t3        <= jsr_pc_t3_r;
-- v255: JMP-indirect target ring + IRQ vector + IO port
dbg_jmp_tgt_t0       <= jmp_tgt_t0_r;
dbg_jmp_tgt_t1       <= jmp_tgt_t1_r;
dbg_jmp_tgt_t2       <= jmp_tgt_t2_r;
dbg_jmp_tgt_t3       <= jmp_tgt_t3_r;
dbg_mem_0314         <= mem_0314_r;
dbg_mem_0315         <= mem_0315_r;
dbg_mem_00           <= mem_00_r;
dbg_mem_01           <= mem_01_r;
dbg_op_count         <= std_logic_vector(op_count_r);
dbg_scpu_iclr        <= scpu_iclr_r;
dbg_irq_vec_count    <= std_logic_vector(irq_vec_count_r);
dbg_min_p            <= min_p_r;
dbg_rti_count        <= std_logic_vector(rti_count_r);
dbg_nmi_vec_count    <= std_logic_vector(nmi_vec_count_r);
dbg_d019_wr_count    <= std_logic_vector(d019_wr_count_r);
dbg_dc0d_rd_count    <= std_logic_vector(dc0d_rd_count_r);
dbg_irq_fall_count   <= std_logic_vector(irq_fall_count_r);

-- v231 source-IRQ aggregate (mirror of port-map gate)
irq_combined <= irq_cia1 and irq_vic and irq_n and irq_ext_n;

-- v232 per-source IRQ levels + last $D019 write value
dbg_irq_vic_lvl   <= irq_vic;
dbg_irq_cia1_lvl  <= irq_cia1;
dbg_irq_n_lvl     <= irq_n;
dbg_irq_ext_lvl   <= irq_ext_n;
dbg_d019_last_val <= d019_last_val_r;
-- v234 $D019 read-side + $D01A enable-mask probes
dbg_d019_last_read <= d019_last_read_r;
dbg_d019_seen_bits <= d019_seen_bits_r;
dbg_d01a_last_val  <= d01a_last_val_r;
-- v235 sprite-control write probes
dbg_d015_last_val  <= d015_last_val_r;
dbg_d015_last_pc   <= d015_last_pc_r;
dbg_d015_wr_count  <= std_logic_vector(d015_wr_count_r);
dbg_d017_last_val  <= d017_last_val_r;
dbg_d01b_last_val  <= d01b_last_val_r;
dbg_d01c_last_val  <= d01c_last_val_r;
dbg_d01d_last_val  <= d01d_last_val_r;
-- v236 sprite-position outputs
dbg_d000_last_val  <= d000_last_val_r;
dbg_d001_last_val  <= d001_last_val_r;
dbg_d001_last_pc   <= d001_last_pc_r;
-- v267 $D012 timing outputs
dbg_d012_write_cycles <= d012_write_cycles_r;
dbg_d012_last_val     <= d012_last_val_r;
dbg_raster_at_d012    <= raster_at_d012_r;
dbg_d012_last_pc      <= d012_last_pc_r;
dbg_d012_wr_count     <= std_logic_vector(d012_wr_count_r);
-- v268 IRQ rising-edge outputs
dbg_irq_vic_rise_count      <= std_logic_vector(irq_vic_rise_count_r);
dbg_irq_combined_rise_count <= std_logic_vector(irq_combined_rise_count_r);
-- v269 VIC-internal IRQ ack outputs
dbg_vic_d019_wr_count      <= std_logic_vector(vic_d019_wr_count_r);
dbg_vic_resetraster_count  <= std_logic_vector(vic_resetraster_count_r);
-- v270 $D019 writer-PC + sticky cpuDo-OR outputs
dbg_d019_last_pc           <= d019_last_pc_r;
dbg_d019_seen_writes       <= d019_seen_writes_r;
-- v271 ack-write counter + ack-write PC outputs
dbg_d019_ack_count         <= std_logic_vector(d019_ack_count_r);
dbg_d019_ack_pc            <= d019_ack_pc_r;
dbg_d002_last_val  <= d002_last_val_r;
dbg_d003_last_val  <= d003_last_val_r;
dbg_d010_last_val  <= d010_last_val_r;
-- v238 I-flag edge outputs
dbg_p_set_pc       <= p_set_pc_r;
dbg_p_clr_pc       <= p_clr_pc_r;
dbg_p_set_count    <= std_logic_vector(p_set_count_r);
dbg_p_clr_count    <= std_logic_vector(p_clr_count_r);
dbg_p_opfetch_min  <= p_opfetch_min_r;

-- v239 IRQ vector + zero-page stub + $0314/$0315 + cpuIO snapshot
dbg_vec_lo    <= vec_lo_r;
dbg_vec_hi    <= vec_hi_r;
dbg_mem_314   <= mem_314_r;
dbg_mem_315   <= mem_315_r;
dbg_mem_62    <= mem_62_r;
dbg_mem_63    <= mem_63_r;
dbg_mem_64    <= mem_64_r;
dbg_io_at_vec <= io_at_vec_r;
-- v240 extended stub bytes + RTI PC
dbg_mem_65    <= mem_65_r;
dbg_mem_66    <= mem_66_r;
dbg_mem_67    <= mem_67_r;
dbg_mem_68    <= mem_68_r;
dbg_mem_69    <= mem_69_r;
dbg_mem_6A    <= mem_6A_r;
dbg_mem_6B    <= mem_6B_r;
-- v242 stub continuation $006C..$0073
dbg_mem_6C    <= mem_6C_r;
dbg_mem_6D    <= mem_6D_r;
dbg_mem_6E    <= mem_6E_r;
dbg_mem_6F    <= mem_6F_r;
dbg_mem_70    <= mem_70_r;
dbg_mem_71    <= mem_71_r;
dbg_mem_72    <= mem_72_r;
dbg_mem_73    <= mem_73_r;
-- v243 extension $0074..$0078 + dispatch-target PC
dbg_mem_74    <= mem_74_r;
dbg_mem_75    <= mem_75_r;
dbg_mem_76    <= mem_76_r;
dbg_mem_77    <= mem_77_r;
dbg_mem_78    <= mem_78_r;
dbg_disp_target_pc <= disp_target_pc_r;
-- v244 dispatcher disasm + FLI verify + PC trace + write-PC
dbg_mem_3380  <= mem_3380_r(0);
dbg_mem_3381  <= mem_3380_r(1);
dbg_mem_3382  <= mem_3380_r(2);
dbg_mem_3383  <= mem_3380_r(3);
dbg_mem_3384  <= mem_3380_r(4);
dbg_mem_3385  <= mem_3380_r(5);
dbg_mem_3386  <= mem_3380_r(6);
dbg_mem_3387  <= mem_3380_r(7);
dbg_mem_3388  <= mem_3380_r(8);
dbg_mem_3389  <= mem_3380_r(9);
dbg_mem_338A  <= mem_3380_r(10);
dbg_mem_338B  <= mem_3380_r(11);
dbg_mem_338C  <= mem_3380_r(12);
dbg_mem_338D  <= mem_3380_r(13);
dbg_mem_338E  <= mem_3380_r(14);
dbg_mem_338F  <= mem_3380_r(15);
dbg_mem_9F09  <= mem_9F09_r(0);
dbg_mem_9F0A  <= mem_9F09_r(1);
dbg_mem_9F0B  <= mem_9F09_r(2);
dbg_mem_9F0C  <= mem_9F09_r(3);
dbg_mem_9F0D  <= mem_9F09_r(4);
dbg_mem_9F0E  <= mem_9F09_r(5);
dbg_mem_9F0F  <= mem_9F09_r(6);
dbg_mem_9F10  <= mem_9F09_r(7);
dbg_mem_9F11  <= mem_9F09_r(8);
dbg_mem_9F12  <= mem_9F09_r(9);
dbg_mem_9F13  <= mem_9F09_r(10);
dbg_mem_9F14  <= mem_9F09_r(11);
dbg_mem_9F15  <= mem_9F09_r(12);
dbg_mem_9F16  <= mem_9F09_r(13);
dbg_mem_9F17  <= mem_9F09_r(14);
dbg_mem_9F18  <= mem_9F09_r(15);
dbg_disp2_target_pc <= disp2_target_pc_r;
dbg_pc33_t0   <= pc33_t0_r;
dbg_pc33_t1   <= pc33_t1_r;
dbg_pc33_t2   <= pc33_t2_r;
dbg_pc33_t3   <= pc33_t3_r;
dbg_wr70_pc   <= wr70_pc_r;
dbg_wr71_pc   <= wr71_pc_r;
dbg_rti_pc    <= rti_pc_r;
-- v241 RTI snapshot ring
dbg_rti_h1    <= rti_h1_r;
dbg_rti_h2    <= rti_h2_r;
-- v245 dispatcher disasm $335D..$336C, $3300..$3307, $3100..$3107 + write values
dbg_mem_335D <= mem_335D_r(0);
dbg_mem_335E <= mem_335D_r(1);
dbg_mem_335F <= mem_335D_r(2);
dbg_mem_3360 <= mem_335D_r(3);
dbg_mem_3361 <= mem_335D_r(4);
dbg_mem_3362 <= mem_335D_r(5);
dbg_mem_3363 <= mem_335D_r(6);
dbg_mem_3364 <= mem_335D_r(7);
dbg_mem_3365 <= mem_335D_r(8);
dbg_mem_3366 <= mem_335D_r(9);
dbg_mem_3367 <= mem_335D_r(10);
dbg_mem_3368 <= mem_335D_r(11);
dbg_mem_3369 <= mem_335D_r(12);
dbg_mem_336A <= mem_335D_r(13);
dbg_mem_336B <= mem_335D_r(14);
dbg_mem_336C <= mem_335D_r(15);
dbg_mem_3300 <= mem_3300_r(0);
dbg_mem_3301 <= mem_3300_r(1);
dbg_mem_3302 <= mem_3300_r(2);
dbg_mem_3303 <= mem_3300_r(3);
dbg_mem_3304 <= mem_3300_r(4);
dbg_mem_3305 <= mem_3300_r(5);
dbg_mem_3306 <= mem_3300_r(6);
dbg_mem_3307 <= mem_3300_r(7);
dbg_mem_3100 <= mem_3100_r(0);
dbg_mem_3101 <= mem_3100_r(1);
dbg_mem_3102 <= mem_3100_r(2);
dbg_mem_3103 <= mem_3100_r(3);
dbg_mem_3104 <= mem_3100_r(4);
dbg_mem_3105 <= mem_3100_r(5);
dbg_mem_3106 <= mem_3100_r(6);
dbg_mem_3107 <= mem_3100_r(7);
dbg_wr70_val <= wr70_val_r;
dbg_wr71_val <= wr71_val_r;
-- v246
dbg_mem_79   <= mem_79_r;
dbg_mem_7A   <= mem_7A_r;
dbg_mem_7B   <= mem_7B_r;
dbg_mem_7C   <= mem_7C_r;
dbg_mem_7D   <= mem_7D_r;
dbg_mem_7E   <= mem_7E_r;
dbg_mem_7F   <= mem_7F_r;
dbg_cnt_3200 <= cnt_3200_r;
dbg_cnt_3100 <= cnt_3100_r;
-- v247
-- v259: DL gate variables
dbg_mem_40      <= mem_40_r;
dbg_mem_44      <= mem_44_r;
dbg_mem_5C      <= mem_5C_r;
-- v260: PC main/irq split + page counters
dbg_pc_main     <= pc_main_r;
dbg_pc_irq      <= pc_irq_r;
dbg_mem_45      <= mem_45_r;
dbg_cnt_pc_30   <= cnt_pc_30_r;
dbg_cnt_pc_97   <= cnt_pc_97_r;
-- Muxed P (status flags) for I-flag gating in capture logic above.
cpu_p_now       <= std_logic_vector(dbg_p_816_i)
                   when supercpu_en = '1'
                   else t65_regs(31 downto 24);
dbg_mem_5B      <= mem_5B_r;
dbg_wr5B_pc     <= wr5B_pc_r;
dbg_wr5B_val    <= wr5B_val_r;
dbg_wr_df01_pc  <= wr_df01_pc_r;
dbg_wr_df01_val <= wr_df01_val_r;
dbg_cnt_df01    <= cnt_df01_r;
dbg_mem_80   <= mem_80_r;
dbg_mem_81   <= mem_81_r;
dbg_mem_82   <= mem_82_r;
dbg_mem_83   <= mem_83_r;
dbg_mem_84   <= mem_84_r;
dbg_mem_85   <= mem_85_r;
dbg_mem_86   <= mem_86_r;
dbg_mem_87   <= mem_87_r;
dbg_mem_88   <= mem_88_r;
dbg_mem_89   <= mem_89_r;
dbg_mem_8A   <= mem_8A_r;
dbg_mem_8B   <= mem_8B_r;
-- v249
dbg_mem_8C    <= mem_8C_r;
dbg_mem_02    <= mem_02_r;
dbg_mem_03    <= mem_03_r;
dbg_wr02_pc   <= wr02_pc_r;
dbg_wr02_val  <= wr02_val_r;
dbg_wr03_pc   <= wr03_pc_r;
dbg_wr03_val  <= wr03_val_r;
dbg_cnt_wr02  <= std_logic_vector(cnt_wr02_r);
dbg_cnt_wr02_chg <= std_logic_vector(cnt_wr02_chg_r);   -- v257
-- v258
dbg_wr02_v0   <= wr02_v0_r;
dbg_wr02_v1   <= wr02_v1_r;
dbg_wr02_v2   <= wr02_v2_r;
dbg_wr02_v3   <= wr02_v3_r;
dbg_wr02_y    <= wr02_y_r;
dbg_wr02_x    <= wr02_x_r;
dbg_p_irq_t0  <= p_irq_t0_r;
dbg_p_irq_t1  <= p_irq_t1_r;
dbg_p_irq_t2  <= p_irq_t2_r;
dbg_p_irq_t3  <= p_irq_t3_r;
-- v262: $005C write-ring + counter
dbg_wr5C_v0   <= wr5C_v0_r;
dbg_wr5C_v1   <= wr5C_v1_r;
dbg_wr5C_v2   <= wr5C_v2_r;
dbg_wr5C_v3   <= wr5C_v3_r;
dbg_cnt_wr5C  <= std_logic_vector(cnt_wr5C_r);

-- v211: opcode-fetch pulse + current PC.
-- T65: SYNC=1 + enableCpu_6510=1 → opcode-fetch cycle, latch cpuAddr_6510.
-- P65C816: vpa=vda=1 + enableCpu_816=1 → opcode-fetch cycle.
-- cpu_pc_now reuses the same PC source as dd00_pc_now (PBR:PC for SCPU,
-- $00:t65_pc_latch for T65). Note for T65 this lags by one opcode (latch
-- is updated on SYNC, so pulse-edge sees previous opcode's PC) but ring
-- still walks the chain correctly.
cpu_pc_now <= std_logic_vector(dbg_pbr_816_i) & std_logic_vector(dbg_pc_816_i)
              when supercpu_en = '1'
              else x"00" & std_logic_vector(t65_pc_latch);
opcode_fetch_pulse <= (vpa_816 and vda_816 and enableCpu_816)
                      when supercpu_en = '1'
                      else (t65_sync and enableCpu_6510);

-- v258: muxed CPU X/Y at the current cycle. P65C816 native exposes 16-bit
-- X/Y; emu mode forces hi byte to $00 internally so [7:0] is correct.
-- T65 Regs layout (T65.vhd:275): {PC[16] S[16] P[8] Y[8] X[8] A[8]}.
-- → PC=[63:48], S=[47:32], P=[31:24], Y=[23:16], X=[15:8], A=[7:0].
cpu_x_now <= std_logic_vector(dbg_x_816_i(7 downto 0))
             when supercpu_en = '1'
             else t65_regs(15 downto 8);
cpu_y_now <= std_logic_vector(dbg_y_816_i(7 downto 0))
             when supercpu_en = '1'
             else t65_regs(23 downto 16);

-- v280: 16-bit SP for UART pool. SCPU = full 16-bit SP. T65 S is 16-bit
-- but only low byte is meaningful for 6510; high byte is forced $01.
dbg_cpu_sp <= std_logic_vector(dbg_sp_816_i)
              when supercpu_en = '1'
              else x"01" & t65_regs(39 downto 32);

-- Compose 24-bit "current PC" for $DD00 write capture: PBR:PC for SCPU,
-- $00:t65_pc_latch (last opcode-fetch address) for T65.
dd00_pc_now <= std_logic_vector(dbg_pbr_816_i) & std_logic_vector(dbg_pc_816_i)
               when supercpu_en = '1'
               else x"00" & std_logic_vector(t65_pc_latch);

end architecture;
