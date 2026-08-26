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
	-- Milestone B sim-first gate (2026-05-30): '0' = today's hardware
	-- behavior (bridge in SAME_CLOCK_PASSTHROUGH, clk_cpu=clk_sys, the
	-- HW-shipped config). '1' = engage the MCP async bridge so the CPU
	-- runs in a separate clk_cpu (64MHz) domain across the CDC handshake.
	-- Threaded to scpu_async_bridge.SAME_CLOCK_PASSTHROUGH below as its
	-- inverse. Default '0' keeps the synthesised build bit-identical; only
	-- the GHDL Milestone-B harness sets it to '1'.
	SCPU_MCP_ACTIVE : std_logic := '0'
);
port(
	clk32       : in  std_logic;
	clk_cpu     : in  std_logic := '0';
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
	-- IOF falling-edge fix (Phase 1 of scpu_full_implementation_plan):
	-- Latched cpu_we/addr/dout captured during the $DFxx access window,
	-- plus a 1-cycle pulse fired at the end of the access. reu.v drives
	-- its cpu_cs/cpu_we/cpu_addr/cpu_dout from these so turbo-mode
	-- single-cycle accesses are visible to the 1MHz REU device. Without
	-- this, raw IOF rises too late for cpuWe_pre to settle and REU
	-- misclassifies turbo writes as reads.
	iof_we_o    : out std_logic;
	iof_addr_o  : out unsigned(15 downto 0);
	iof_dout_o  : out unsigned(7 downto 0);
	iof_fall_pulse_o : out std_logic;
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
	-- SDRAM backpressure (Layer 2 prep, 2026-05-20).
	-- sdram_ready='1' when the SDRAM controller is idle and safe to start
	-- a new access. Synchronised to clk32 inside this entity. Step 1 only
	-- wires + synchronises this; Step 2 will gate cpu_cyc on it for the
	-- alt-slot fast-path. Default '1' so the port stays compile-compatible
	-- with any unwired instantiation.
	sdram_ready   : in  std_logic := '1';
	-- Step 6 Phase 6a (2026-05-20): "dout_r is fresh" handshake from
	-- sdram_pm. Level signal — set post-sample edge, cleared at next
	-- ce-edge. Phase 6b consumer replaces the cpu_cyc_s fixed shift
	-- with a wait on sdram_data_valid_sync. Default '1' keeps the port
	-- compile-compatible with non-handshake-aware instantiations.
	sdram_data_valid : in std_logic := '1';
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
	dbg_d011        : out std_logic_vector(7 downto 0); -- last cpuDo to $D011 (VIC ctl1)
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
	-- 29th pass: 2 post-trigger ring slots, UART-only (see trace_pc4_r
	-- declaration comment).
	dbg_trace_pc4        : out std_logic_vector(23 downto 0);
	dbg_trace_pc5        : out std_logic_vector(23 downto 0);
	dbg_trace_op4        : out std_logic_vector(7 downto 0);
	dbg_trace_op5        : out std_logic_vector(7 downto 0);
	-- 31st pass: screen-RAM ($0400-$07E7, bank $00) write observer
	-- (see dbg_scr_write_pc_r declaration comment).
	dbg_scr_write_pc     : out std_logic_vector(23 downto 0);
	dbg_scr_write_count  : out std_logic_vector(7 downto 0);
	-- 32nd pass: 2 more post-trigger ring slots (see trace_pc6_r
	-- declaration comment).
	dbg_trace_pc6        : out std_logic_vector(23 downto 0);
	dbg_trace_pc7        : out std_logic_vector(23 downto 0);
	dbg_trace_op6        : out std_logic_vector(7 downto 0);
	dbg_trace_op7        : out std_logic_vector(7 downto 0);
	-- 33rd pass: JSR-ring snapshot at the moment of the last screen
	-- write (see scr_write_jsr_a_r declaration comment).
	dbg_scr_write_jsr_a  : out std_logic_vector(15 downto 0);
	dbg_scr_write_jsr_b  : out std_logic_vector(15 downto 0);
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
	-- 34th pass: always-live current opcode byte (see cur_op_r comment).
	dbg_cur_op           : out std_logic_vector(7 downto 0);
	-- 36th pass (Wolf3D freeze, 2026-08-26): static code-byte snoops of
	-- the $0AC3-$0B0F copy-loop's compare operands, recovering the
	-- embedded absolute-address operands of its LDA/SBC/LDX instructions
	-- (bank-$00 code bytes, read as data during the CPU's own operand
	-- fetch, so no separate memory-read mechanism is needed).
	dbg_wloop_lda_lo     : out std_logic_vector(7 downto 0);
	dbg_wloop_lda_hi     : out std_logic_vector(7 downto 0);
	dbg_wloop_sbc_lo     : out std_logic_vector(7 downto 0);
	dbg_wloop_sbc_hi     : out std_logic_vector(7 downto 0);
	dbg_wloop_ldx_lo     : out std_logic_vector(7 downto 0);
	dbg_wloop_ldx_hi     : out std_logic_vector(7 downto 0);
	-- 37th pass (Wolf3D freeze, 2026-08-26): runtime VALUES at the
	-- compare/index addresses found by the 36th pass ($2906, $4903,
	-- $F634) -- tells us whether the loop's compare inputs and X-reload
	-- source are moving or frozen during the observed freeze window.
	dbg_wloop_val_2906   : out std_logic_vector(7 downto 0);
	dbg_wloop_val_4903   : out std_logic_vector(7 downto 0);
	dbg_wloop_val_f634   : out std_logic_vector(7 downto 0);
	-- 38th pass (Wolf3D freeze, 2026-08-26): operand-address bytes of
	-- the loop's 3 STA abs instructions ($0AF6/$0AFF/$0B0E), to check
	-- whether any of them writes back to $2906/$4903/$F634 (self-update
	-- bug) or none do (external state never seeded).
	dbg_wloop_sta1_lo    : out std_logic_vector(7 downto 0);
	dbg_wloop_sta1_hi    : out std_logic_vector(7 downto 0);
	dbg_wloop_sta2_lo    : out std_logic_vector(7 downto 0);
	dbg_wloop_sta2_hi    : out std_logic_vector(7 downto 0);
	dbg_wloop_sta3_lo    : out std_logic_vector(7 downto 0);
	dbg_wloop_sta3_hi    : out std_logic_vector(7 downto 0);
	-- 39th pass (Wolf3D freeze, 2026-08-26): operand-address bytes of
	-- the arithmetic feeding STA1 ($2906): INC $0AEC, LDA $0AEE,
	-- LDA $0AF0, ADC $0AF3. Finds exactly which cells feed the always-
	-- zero result stored back to $2906.
	dbg_wloop_inc_lo     : out std_logic_vector(7 downto 0);
	dbg_wloop_inc_hi     : out std_logic_vector(7 downto 0);
	dbg_wloop_lda1_lo    : out std_logic_vector(7 downto 0);
	dbg_wloop_lda1_hi    : out std_logic_vector(7 downto 0);
	dbg_wloop_lda2_lo    : out std_logic_vector(7 downto 0);
	dbg_wloop_lda2_hi    : out std_logic_vector(7 downto 0);
	dbg_wloop_adc_lo     : out std_logic_vector(7 downto 0);
	dbg_wloop_adc_hi     : out std_logic_vector(7 downto 0);
	-- 40th pass (Wolf3D freeze, 2026-08-26): the 39th pass's fixed-offset
	-- operand guesses turned out inconsistent with the real instruction
	-- boundaries (INC decode checked out, LDA1 did not). Dump the raw
	-- code bytes at $0AEC-$0AF8 (13 bytes) so the real instruction
	-- stream can be hand-disassembled from HW-confirmed bytes instead
	-- of guessed offsets.
	dbg_wloop_rb0        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb1        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb2        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb3        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb4        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb5        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb6        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb7        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb8        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb9        : out std_logic_vector(7 downto 0);
	dbg_wloop_rb10       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb11       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb12       : out std_logic_vector(7 downto 0);
	-- 41st pass (Wolf3D freeze, 2026-08-26): the 40th pass showed $0AF6
	-- is a READ (LDA $2906), not a write, retracting the 38th pass's
	-- "self-update" claim. Gate a snoop on the CPU WRITE bus itself
	-- (not code position) to get an assumption-free answer: is $2906
	-- EVER written anywhere in the observed run? w2906_cnt saturates
	-- at $FF (0 = never written); w2906_val is the last write's data.
	dbg_wloop_w2906_cnt  : out std_logic_vector(7 downto 0);
	dbg_wloop_w2906_val  : out std_logic_vector(7 downto 0);
	-- 42nd pass (Wolf3D freeze, 2026-08-26): extend the raw-byte
	-- ground-truth dump forward from where the 40th pass left off
	-- ($0AEC-$0AF8) to $0AF9-$0B10, to directly locate the real
	-- STA $2906 the 41st pass proved fires every iteration.
	dbg_wloop_rb13       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb14       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb15       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb16       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb17       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb18       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb19       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb20       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb21       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb22       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb23       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb24       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb25       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb26       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb27       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb28       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb29       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb30       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb31       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb32       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb33       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb34       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb35       : out std_logic_vector(7 downto 0);
	dbg_wloop_rb36       : out std_logic_vector(7 downto 0);
	-- 43rd pass: steady-state values of the two step-accumulator
	-- deltas ($292E/$2930) the 42nd pass's disasm showed feeding
	-- the frozen $2906 STA via ADC.
	dbg_wloop_d292e      : out std_logic_vector(7 downto 0);
	dbg_wloop_d2930      : out std_logic_vector(7 downto 0);
	-- 44th pass: write-bus-gated proof of whether $292E/$2930 (the
	-- frozen step-table deltas) are EVER written during the run.
	dbg_wloop_w292e_cnt  : out std_logic_vector(7 downto 0);
	dbg_wloop_w292e_val  : out std_logic_vector(7 downto 0);
	dbg_wloop_w2930_cnt  : out std_logic_vector(7 downto 0);
	dbg_wloop_w2930_val  : out std_logic_vector(7 downto 0);
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
	-- 2026-08-24: signed JSR/JSL vs RTS/RTL call-depth drift counter.
	dbg_call_depth       : out std_logic_vector(15 downto 0);
	dbg_call_depth_maxabs : out std_logic_vector(3 downto 0);
	-- 2026-08-24 (15th pass): last vector-fetch address (low 16 bits,
	-- bank always $00), rezeroed at loader.prg entry ($0700).
	dbg_vecfetch_addr    : out std_logic_vector(15 downto 0);
	-- 2026-08-24 (18th pass): actual CPU-bus-read bytes at $04FD/$04FE
	-- (hi/bank of loader.prg's JML ($04FC) exit vector), rezeroed at
	-- loader.prg entry ($0700). See vecfetch_addr comment above and
	-- project_wolf3d_postreu_bank28_freeze_regression.md 18th-pass update.
	dbg_jmlvec_hi        : out std_logic_vector(7 downto 0);
	dbg_jmlvec_bank      : out std_logic_vector(7 downto 0);
	-- 2026-08-24 (19th pass): last-read $07B9 value (skip-table REU
	-- source mid-byte), rezeroed at loader.prg entry ($0700).
	dbg_last_07b9        : out std_logic_vector(7 downto 0);
	-- v230: source-ack discrimination. d019_wr_count counts CPU
	-- writes to $D019 (VIC IRQ status, write-1-to-clear). dc0d_rd_count
	-- counts $DC0D reads (CIA1 ICR, read-to-ack). T65 should hit
	-- d019_wr_count = IRQ entries (= IV/2). SCPU < that = ack missing.
	dbg_d019_wr_count    : out std_logic_vector(15 downto 0);
	dbg_dc0d_rd_count    : out std_logic_vector(15 downto 0);
	-- v231: source-side IRQ falling-edge count (matches IV/2 if no
	-- mid-handler re-entry).
	dbg_irq_fall_count   : out std_logic_vector(15 downto 0);
	-- v12 (2026-05-24): CIA1-only IRQ falling-edge count. Pre-AND with
	-- vic/n/ext_n. Differential vs dbg_irq_fall_count disambiguates
	-- whether MCP affects CIA1 internally (both rates drop together)
	-- or whether a downstream AND'd term eats the assertion (CIA1
	-- rate stays ~50/s, combined drops).
	dbg_irq_cia1_fall_count : out std_logic_vector(15 downto 0);
	-- v12b (2026-05-24): CIA1 imr/cra current value snapshots. If MCP
	-- causes phantom $DC0D/$DC0E writes during LOAD, imr (interrupt
	-- mask) or cra (Timer A control) will differ from passthrough.
	dbg_cia1_imr         : out std_logic_vector(4 downto 0);
	dbg_cia1_cra         : out std_logic_vector(7 downto 0);
	-- mb-probe-003 (2026-05-26): CIA1 Timer A counter, reload latch,
	-- and raw 5-bit ICR pending bits. Identifies whether Timer A IRQ
	-- generation stops because (a) counter frozen at $0000 = count
	-- enable lost via phantom CRA[0] clear, (b) reload latch frozen at
	-- $0000 = phantom write to $DC04/$DC05, (c) ICR bit 0 stuck set =
	-- int_reset doesn't fire on $DC0D read, or (d) all three sane and
	-- irq_n stays high anyway = downstream IRQ logic bug.
	dbg_cia1_timer_a       : out std_logic_vector(15 downto 0);
	dbg_cia1_timer_a_latch : out std_logic_vector(15 downto 0);
	dbg_cia1_icr           : out std_logic_vector(4 downto 0);
	-- Option F (2026-05-25): CIA2 imr/cra snapshots for LOAD"*",8,1 wedge.
	-- Distinguishes CIA2 phantom-write (would change imr/cra during wedge)
	-- from IEC protocol stall (imr/cra steady but byte-receive stuck).
	dbg_cia2_imr         : out std_logic_vector(4 downto 0);
	dbg_cia2_cra         : out std_logic_vector(7 downto 0);
	-- Option G (2026-05-25): CIA2 port + DDR snapshots. PRA/DDRA = $DD00/$DD02
	-- (IEC ATN/CLK/DATA out + serial bus drive bits). PRB/DDRB = $DD01/$DD03
	-- (user port). If MCP phantom-writes any of these between bridge requests,
	-- IEC handshake breaks silently.
	dbg_cia2_pra         : out std_logic_vector(7 downto 0);
	dbg_cia2_prb         : out std_logic_vector(7 downto 0);
	dbg_cia2_ddra        : out std_logic_vector(7 downto 0);
	dbg_cia2_ddrb        : out std_logic_vector(7 downto 0);
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
	-- 2026-05-09 doom-wait probe: last cpu read in $00:$0700-$07FF.
	-- _addr is the low byte of the read address; _data is the byte read.
	dbg_rd07xx_addr      : out std_logic_vector(7 downto 0);
	dbg_rd07xx_data      : out std_logic_vector(7 downto 0);
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
	dbg_cpu_sp                 : out std_logic_vector(15 downto 0);
	-- v309 doom wedge: scpu_native_vec(2)/(3) = BRK vector lo/hi as
	-- installed by software via writes to $00:$FFE6/$FFE7. Wedge at
	-- $00:$0706 with R7:$0500 implies CPU loops fetching BRK at $0705
	-- — confirming whether BRK vector itself = $0705 ($05, $07) closes
	-- the loop in one hop. If vec != $0705 then BRK vectors elsewhere
	-- and some downstream path returns to $0705.
	dbg_brk_vec_lo             : out std_logic_vector(7 downto 0);
	dbg_brk_vec_hi             : out std_logic_vector(7 downto 0);
	-- v341 doom bitmap probe (2026-05-14): Doom's page-flip handshake bytes.
	-- After v340n IRQ wedge fix, VICE renders the Doom title bitmap but HW
	-- stays black with DD00 stuck at $02 (bank 1 only — no page flip). The
	-- flip code at $80:$0B40 reads $1D04 then BEQs; HW always takes the
	-- non-zero branch ($1D04 never reaches 0). Surfacing the last seen
	-- $1D02 + $1D04 cpuDi values lets us see the handshake state directly.
	dbg_mem_1d02               : out std_logic_vector(7 downto 0);
	dbg_mem_1d04               : out std_logic_vector(7 downto 0);

	-- v346 doom bitmap-content probe (2026-05-16): per-frame sticky OR of
	-- vicDi (the byte VIC reads from RAM at each VIC fetch slot). After v345g
	-- confirmed UART runtime fields are byte-identical between v342's render
	-- success and v345g's black, the question shifted to "what's in the VIC's
	-- view of RAM". This OR resets on vsync rising edge and accumulates over
	-- one frame; the value latched the next vsync_rise tells us whether VIC
	-- saw any non-zero byte that frame. B6=$00 → screen is genuinely empty
	-- (everything VIC fetched was zero). B6 != $00 → screen has data but VIC
	-- pipeline / colour / mode register is mismatched.
	dbg_vic_di_or              : out std_logic_vector(7 downto 0);

	-- Milestone B (2026-05-25): bridge-internal UART probes per
	-- docs/milestone_b_bridge_probe_design.md §B. These are clk_cpu-domain
	-- snapshots; c64.sv handles the 2-FF sync into clk_sys for the UART
	-- formatter. Purpose: discriminate Race α (vector-byte aliasing) vs
	-- Race β (ack-stall accumulation) at the LOAD"*",8,1 wedge moment.
	dbg_bridge_fsm_state       : out std_logic_vector(3 downto 0);
	dbg_bridge_last_bus_di     : out std_logic_vector(7 downto 0);
	dbg_bridge_req_count       : out std_logic_vector(15 downto 0);
	dbg_bridge_ack_count       : out std_logic_vector(15 downto 0);
	dbg_bridge_vec_fetch_count : out std_logic_vector(7 downto 0);
	-- Milestone B v2 (2026-05-26): three new bridge probes per Codex
	-- Design 3. WD = max WAIT_ACK dwell in clk_cpu cycles per vblank;
	-- FL = sticky activity flags; GM = max RQ-AK gap per vblank.
	dbg_bridge_wait_dwell_max  : out std_logic_vector(15 downto 0);
	dbg_bridge_activity_flags  : out std_logic_vector(7 downto 0);
	dbg_bridge_gap_max         : out std_logic_vector(7 downto 0);

	-- Milestone A Option (b) (2026-05-26): SuperRAM-only HIT gate for
	-- sdram_pm.v. Surfaces the internal scpu_fast_path signal so the
	-- controller's HIT path engages only on SuperRAM traffic (banks != $00,
	-- not I/O, no DMA). c64.sv passes this through into sdram_pm's new
	-- fast_path input. Drives '0' when 6510-only or during DMA, which keeps
	-- the controller on its MISS-only path = bit-identical to Build B.
	scpu_fast_path_o           : out std_logic;

	-- more-turbo iter-4d (2026-05-30): read-only cpu_cache HIT-RATE OBSERVER.
	-- A dead-RTL cpu_cache runs as a pure observer (cache_hit NOT fed to the
	-- CPU) so it cannot affect Doom/Lorenz/native. dbg_cache_hr = HITs in the
	-- last completed 256-cacheable-read window (saturating; HR/256 = hit rate,
	-- HR/2.56 ~= percent). The sliding window discards the cold-start compulsory
	-- misses that polluted the cumulative GHDL number, so it tracks STEADY
	-- STATE. dbg_cache_hw = window-completion counter (wraps every 256 windows;
	-- liveness — if it advances between UART lines the observer is seeing CPU
	-- read traffic). Measures the real bank-$00 + SuperRAM locality that decides
	-- whether reviving the cache + a hit-shortens-cycle arbiter can beat the
	-- ~4MHz cpuDi-mux-bound ceiling (docs/session_handoff.md NEXT LEVER).
	dbg_cache_hr               : out std_logic_vector(7 downto 0);
	dbg_cache_hw               : out std_logic_vector(7 downto 0)
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
signal sysEnable    : std_logic := '0';            -- FPGA power-up = 0 (sim init; HW no-op)
signal rfsh_cycle   : unsigned(1 downto 0) := "00"; -- FPGA power-up = 0 (sim init; HW no-op)

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
-- Layer 2 backpressure (Step 1, 2026-05-20):
-- 2-FF synchroniser bringing sdram_ready (clk64-domain output of sdram_pm)
-- into the clk32 domain. The sync chain is kept for Step 5 (Build C
-- revival) where the actual ready edge timing matters. Step 2 below
-- uses a *local* counter (cycle-accurate, no sync latency) for backpressure.
signal sdram_ready_sync : std_logic_vector(1 downto 0) := "11";
attribute preserve : boolean;
attribute preserve of sdram_ready_sync : signal is true;

-- Step 6 Phase 6a (2026-05-20): single-flop sync of sdram_data_valid into
-- the clk32 domain. data_valid is a level signal that stays high for
-- several clk64 between sample-edge and next ce-edge, so single-flop is
-- metastability-safe. `preserve` prevents Quartus from optimising the
-- signal away while the Phase 6b consumer is being built.
signal sdram_data_valid_sync : std_logic := '1';
attribute preserve of sdram_data_valid_sync : signal is true;

-- Step 6 (Milestone A, 2026-05-22): edge-detect prev for sdram_ready_sync.
-- Used to early-clear sdram_busy_cnt when the SDRAM controller reports
-- ready BEFORE the static decrement would expire. On Build B (4-clk32
-- cycle, 2-FF sync = ~2 clk32 latency) the synced edge arrives at
-- clk32 5-6 — after the static counter has already cleared at clk32 4 —
-- so this is a no-op for the current SDRAM controller. Becomes active
-- under Build C's 3-clk64 HIT path where the synced edge arrives at
-- clk32 ~3, opening the alt-slot window at CPU2.
-- Init HIGH to match sdram_ready_sync init; prevents a spurious power-on
-- edge clear when the counter hasn't been loaded yet.
signal sdram_ready_sync_prev : std_logic := '1';
attribute preserve of sdram_ready_sync_prev : signal is true;

-- Option C Mitigation A — SCPU SuperRAM alt-slot fast-path (Step 2, 2026-05-20).
-- scpu_fast_path is '1' when the SCPU CPU core is executing in a SuperRAM
-- bank (≠ $00) and the current access does not hit I/O ($D000-$DFFF) and
-- no DMA is active. NOTE: the alt-slot consumer of this signal (CYCLE_CPU2/
-- 6/A/E + scpu_fast_path) was bench-removed at Step 2 commit because empirically
-- folding it into cpu_cyc wedges Doom even with the SDRAM-busy gate that
-- static analysis says should block every fire on Build B. The signal is
-- driven (kept for Step 5 revival) but currently has no consumer — Quartus
-- will dead-strip it. See cpu_cyc assignment below + docs/plan_supercpu_speedup_stepped.md.
signal scpu_fast_path : std_logic;

-- Local counter that predicts SDRAM busy time. Starts at 3 (= 4 clk32 = 8
-- clk64) when a cpu_cyc fires on a cs_ram=1 access, ticks down on each
-- clk32 until it reaches 0. Any cpu_cyc fire is blocked while sdram_busy='1'.
-- For Build B's baseline 8-clk64 SDRAM cycle this matches today's cadence
-- exactly: CPU0→CPU4 spacing of 4 clk32 leaves the counter at 0 by CPU4,
-- so existing terms are not blocked. For Build C HIT path (3 clk64) this
-- can be tightened in Step 5.
signal sdram_busy_cnt : unsigned(2 downto 0) := (others => '0');
signal sdram_busy     : std_logic;

-- Milestone A Build C (2026-05-25): HIT/MISS predictor for the busy-counter
-- preload. Mirrors sdram_pm.v's internal row-tracking against the bus-side
-- address visible here. When the prediction is HIT, the preload is "001"
-- (short reservation; ready_sync rising edge closes the rest of the loop);
-- otherwise "011" (Build B worst-case floor — bit-identical to the
-- pre-Build-C behaviour). The mirror is INTENTIONALLY conservative: any
-- false-MISS prediction just keeps the existing cadence, while a false-HIT
-- prediction would risk firing the alt-slot before the controller is done.
-- The predictor therefore only marks HIT when it has high confidence.
--
-- DESIGN NOTE: sdram_pm.v's HIT detection runs on the *final* 25-bit SDRAM
-- address built in c64.sv (scpu_sdram_addr | cart_addr | reu_ram_addr
-- depending on mux state). fpga64_sid_iec.vhd does not see that mux. For
-- the SCPU long-mode path the predictor uses {addr_hi_816, systemAddr}
-- which matches the dominant case (Doom/Wolf3D-style SuperRAM workloads).
-- For the 6510 / bank-$00 path the predictor uses systemAddr alone (bank
-- = 0 implicitly). Cartridge mem-req and REU DMA paths are predicted MISS
-- (their addressing isn't tracked here). All these conservatism choices
-- are safe — they never produce false HITs, just leave some HIT cycles
-- on the table that the real sdram_pm.v will still service in 3 clk64.
signal sdram_pred_bank      : unsigned(1 downto 0) := (others => '0');
signal sdram_pred_row       : unsigned(12 downto 0) := (others => '0');
signal sdram_pred_valid     : std_logic := '0';
signal sdram_hit_pred       : std_logic;

-- Step 5 trial (2026-05-20, side branch step5-altslot-registered):
-- Registered alt-slot fire signal — recovery from the Step 2 alt-slot wedge.
-- Latched at CPU1/5/9/D under busy='0' + scpu_fast_path + cs_ram, then ORed
-- into cpu_cyc combinationally. Goal: keep cpu_cyc → ramCE → cart_ce hazard-
-- free by feeding alt-slot through a register output (no LUT cluster shared
-- with the main combinational gate). On Build B (counter=3, 4-clk32 SDRAM
-- cycle) sdram_busy=1 at CPU1 so alt_fire_r latches 0 → no alt fire → bit-
-- identical behaviour to Step 2 / bisect-1. On Build C HIT (counter=1)
-- alt_fire_r latches 1 → CPU2 fires next clk32 → 8 MHz cadence.
signal alt_fire_r : std_logic := '0';

-- Step 7b (2026-05-23): Conservative variant — alt-fire at CPU3/7/B/F
-- gated on scpu_fast_path (SuperRAM bank ≠ $00 only). Previous Step 7
-- (bank-0 safe) wedged KERNAL cold-init at $00:E357 from boot. This
-- variant keeps bank-0 accesses on original cadence (boot path intact)
-- while letting SuperRAM accesses (Doom, Wolf3D, long-mode bench) get
-- the extra fire. Trade-off: bench's bank-0 ZP loop won't show
-- speedup, but SuperRAM workloads should observe ~5 MHz vs 4.
signal alt_fire_r2     : std_logic := '0';
signal cpuWe        : std_logic;
signal cpuWe_pre    : std_logic;
signal b00_fast_read : std_logic;  -- iter-31 step 6: current cycle is a fast bank-$00 READ
signal cpuAddr      : unsigned(15 downto 0);
signal cpuAddr_pre  : unsigned(15 downto 0);
signal cpuDi        : unsigned(7 downto 0);
signal cpuDo        : unsigned(7 downto 0);
signal cpuDo_pre    : unsigned(7 downto 0);
signal cpuIO        : unsigned(7 downto 0);

-- IOF falling-edge fix (Phase 1) — see entity comment above.
signal iof_detect       : std_logic;  -- combinational IOF detect from cpuAddr_pre
signal iof_detect_d2    : std_logic := '0';  -- 1-cycle delayed detect
signal iof_fall_pulse_r : std_logic := '0';  -- 1-cycle pulse at end of $DFxx access
signal iof_we_r         : std_logic := '0';
signal iof_addr_r       : unsigned(15 downto 0) := (others => '0');
signal iof_dout_r       : unsigned(7 downto 0)  := (others => '0');

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
-- Raw P65C816 outputs, fed into the async bridge. The bridge produces
-- the cpu*_816 signals consumed by the rest of the arbiter.
signal cpu816_addr_raw    : unsigned(15 downto 0);
signal cpu816_addr_hi_raw : unsigned(7 downto 0);
signal cpu816_do_raw      : unsigned(7 downto 0);
signal cpu816_we_raw      : std_logic;
signal cpu816_vpa_raw     : std_logic;
signal cpu816_vda_raw     : std_logic;
signal cpu816_di_to_cpu   : unsigned(7 downto 0);
signal cpu816_rdy_to_cpu  : std_logic;
signal cpu816_enable_to_cpu : std_logic;
signal cpu816_dbg_is_slow : std_logic;
-- Milestone B (2026-05-25): bridge-internal probes (clk_cpu domain).
-- Wired from scpu_async_bridge_inst out the entity ports to c64.sv.
signal cpu816_dbg_fsm_state          : unsigned(3 downto 0);
signal cpu816_dbg_last_bus_di        : unsigned(7 downto 0);
signal cpu816_dbg_req_count          : unsigned(15 downto 0);
signal cpu816_dbg_ack_count          : unsigned(15 downto 0);
signal cpu816_dbg_vec_fetch_count    : unsigned(7 downto 0);
-- Milestone B v2 (Codex Design 3) snapshot outputs from bridge.
signal cpu816_dbg_wait_dwell_max     : unsigned(15 downto 0);
signal cpu816_dbg_activity_flags     : unsigned(7 downto 0);
signal cpu816_dbg_gap_max            : unsigned(7 downto 0);
signal cpuIO_816    : unsigned(7 downto 0);
signal nmi_ack_816  : std_logic;
signal addr_hi_816  : unsigned(7 downto 0);
signal emu_mode_816_i : std_logic;
signal vpa_816      : std_logic;  -- unused for now; reserved for future
signal vda_816      : std_logic;  -- unused for now; reserved for future
-- v13g (2026-05-25): 1-cycle delayed vpa/vda for widening the CIA2
-- cs_n gate window. v13e proved the v13d CIA1-style gate
-- (cs_n => not (cs_cia2 and (not cpuWe or vpa or vda))) drops some
-- early KERNAL CIA2 setup write, wedging CPU at PC=$018C. CIA2 IEC
-- writes appear edge-timing-critical in a way CIA1 mask writes aren't.
-- Hypothesis: widening the gate by 1 clk_sys cycle on either side of
-- the vpa/vda window keeps phantom-write protection (gap between
-- requests is many cycles) while letting all legitimate writes through.
signal vpa_816_d1   : std_logic := '0';
signal vda_816_d1   : std_logic := '0';
signal cia2_write_safe : std_logic;
signal enableCpu_6510 : std_logic;
signal enableCpu_816  : std_logic;

-- Layered debug overlay internal signals (rtl/debug/).
signal dbg_d018_r     : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_d016_r     : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_dd00_r     : std_logic_vector(7 downto 0) := (others => '0');
signal dbg_d011_r     : std_logic_vector(7 downto 0) := (others => '0');
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
-- 31st pass (Wolf3D freeze, 2026-08-25): screen-RAM ($0400-$07E7,
-- bank $00) write observer. The plain-playthrough hang-check confirmed
-- a real visual freeze (screen 99.7%+ pixel-identical for ~10 min post
-- bank-$28 landing) -- this tracks whether ANYTHING still writes to
-- screen RAM after the loader arms, or whether the screen-update
-- routine simply stops being called. Mirrors the d018 observer above.
signal dbg_scr_write_pc_r    : std_logic_vector(23 downto 0) := (others => '0');
signal dbg_scr_write_count_r : std_logic_vector(7 downto 0)  := (others => '0');
-- 33rd pass (Wolf3D freeze, 2026-08-26): snapshot the 2 newest entries
-- of the always-live JSR ring (jsr_pc_t3_r/t2_r) at the exact moment
-- the screen-write observer above fires. The JSR ring keeps updating
-- after the freeze (any periodic IRQ's own JSRs overwrite it), so a
-- live read during the freeze doesn't show who called the LAST real
-- screen write -- this latches that context right when it happens.
-- _a = newest call site (t3, direct caller of the writer or a routine
-- on its way there), _b = next-newest (t2, its caller).
signal scr_write_jsr_a_r : std_logic_vector(15 downto 0) := (others => '0');
signal scr_write_jsr_b_r : std_logic_vector(15 downto 0) := (others => '0');
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
-- 29th pass (Wolf3D bank-$28 freeze): 2 extra post-trigger ring slots.
-- trace_pc3_r/trace_op3_r stay exactly as before -- the fetch that MET
-- the freeze-trigger condition (unchanged capture logic below). Once
-- the trigger has been seen, trig_seen_r gates a small counter that
-- captures the NEXT 2 opcode fetches into pc4/pc5 (1 and 2 fetches
-- past the landing PC) before trace_frozen_r finally latches. UART-
-- only readout (debug_uart_pool_fmt.sv) -- overlay cell space is
-- fully exhausted (see debug_overlay_format.sv row 12/14 comments).
signal trig_seen_r      : std_logic := '0';
signal post_trig_cnt_r  : unsigned(1 downto 0) := (others => '0');
signal trace_pc4_r : std_logic_vector(23 downto 0) := (others => '0');
signal trace_pc5_r : std_logic_vector(23 downto 0) := (others => '0');
signal trace_op4_r : std_logic_vector(7 downto 0) := (others => '0');
signal trace_op5_r : std_logic_vector(7 downto 0) := (others => '0');
-- 32nd pass (Wolf3D freeze, 2026-08-25): 2 more post-trigger slots
-- (pc6/pc7), reusing the same post_trig_cnt_r counter (2-bit already
-- supports states 0-3, no width change needed) -- 4 fetches past the
-- bank-$28 landing instead of 2, to see further past the generic
-- LDA/STA/LDA idiom the 29th/30th passes found there.
signal trace_pc6_r : std_logic_vector(23 downto 0) := (others => '0');
signal trace_pc7_r : std_logic_vector(23 downto 0) := (others => '0');
signal trace_op6_r : std_logic_vector(7 downto 0) := (others => '0');
signal trace_op7_r : std_logic_vector(7 downto 0) := (others => '0');
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
-- v341 doom bitmap probe: page-flip handshake bytes at bank $00:$1D02/$1D04.
-- $1D04 is the flag the main loop reads to decide bank-1 vs bank-3 in
-- Doom's double-buffer flip ($80:$0B40 area). HW page-flip is stuck at
-- DD00=$02 (bank 1) so $1D04 never reaches 0.
signal mem_1d02_r : std_logic_vector(7 downto 0) := (others => '0');
signal mem_1d04_r : std_logic_vector(7 downto 0) := (others => '0');
-- v255: CPU IO port direction ($0000) + data ($0001). Bits in $0001
-- (LORAM/HIRAM/CHAREN) gate ROM/RAM visibility at $A000/$E000/$D000.
-- If SCPU has different value here, the SAME PC sees different bytes
-- in modes -- can produce wildly different code paths.
signal mem_00_r : std_logic_vector(7 downto 0) := (others => '0');
signal mem_01_r : std_logic_vector(7 downto 0) := (others => '0');
-- v219: opcode-fetch counter (free-running, never resets in normal op)
signal op_count_r : unsigned(23 downto 0) := (others => '0');
-- 34th pass: always-live current opcode byte (see cur_op_r usage comment).
signal cur_op_r : std_logic_vector(7 downto 0) := (others => '0');
-- 36th pass: Wolf3D $0AC3-$0B0F copy-loop compare-operand snoops.
signal wloop_lda_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_lda_hi_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_sbc_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_sbc_hi_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_ldx_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_ldx_hi_r : std_logic_vector(7 downto 0) := (others => '0');
-- 37th pass: runtime values at $2906/$4903/$F634.
signal wloop_val_2906_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_val_4903_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_val_f634_r : std_logic_vector(7 downto 0) := (others => '0');
-- 38th pass: STA abs operand-address bytes ($0AF6/$0AFF/$0B0E).
signal wloop_sta1_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_sta1_hi_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_sta2_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_sta2_hi_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_sta3_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_sta3_hi_r : std_logic_vector(7 downto 0) := (others => '0');
-- 39th pass: operand-address bytes of the arithmetic feeding STA1.
signal wloop_inc_lo_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_inc_hi_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_lda1_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_lda1_hi_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_lda2_lo_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_lda2_hi_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_adc_lo_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_adc_hi_r  : std_logic_vector(7 downto 0) := (others => '0');
-- 40th pass: raw code-byte dump at $0AEC-$0AF8 (13 bytes).
signal wloop_rb0_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb1_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb2_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb3_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb4_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb5_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb6_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb7_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb8_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb9_r  : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb10_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb11_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb12_r : std_logic_vector(7 downto 0) := (others => '0');
-- 41st pass: write-bus-gated snoop of $2906 (0 count = never written).
signal wloop_w2906_cnt_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_w2906_val_r : std_logic_vector(7 downto 0) := (others => '0');
-- 42nd pass: raw code-byte dump at $0AF9-$0B10 (24 bytes).
signal wloop_rb13_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb14_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb15_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb16_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb17_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb18_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb19_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb20_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb21_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb22_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb23_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb24_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb25_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb26_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb27_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb28_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb29_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb30_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb31_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb32_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb33_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb34_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb35_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_rb36_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_d292e_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_d2930_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_w292e_cnt_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_w292e_val_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_w2930_cnt_r : std_logic_vector(7 downto 0) := (others => '0');
signal wloop_w2930_val_r : std_logic_vector(7 downto 0) := (others => '0');
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
-- 2026-08-24 Wolf3D wild-jump investigation: JSR/RTS call-depth drift
-- detector. Hardware-IRQ theory falsified this pass (irq_vec_count flat
-- at $34 through the whole t=15-30s divergence window); next suspect is
-- an unbalanced JSR/JSL vs RTS/RTL pair inside loader.prg's REU-poll
-- loop walking SP toward $01FF via repeated RTS/RTL pulls with no
-- matching push. call_depth_r increments on JSR($20)/JSL($22) opcode
-- fetch, decrements on RTS($60)/RTL($6B) opcode fetch. A flat loop
-- should hover near a small constant; sustained drift = confirmed.
-- Signed so a net-negative drift (more returns than calls) is visible
-- as the top bit set / large hex value rather than wrapping silently.
signal call_depth_r     : signed(15 downto 0) := (others => '0');
-- 2026-08-24 (14th pass): raw call_depth_r nibble sampled at 7
-- timepoints came back A,6,D,7,8,6,6 -- neither flat nor monotone,
-- but a 4-bit *signed* sample of a value that may have wrapped past
-- +-15 many times is fundamentally ambiguous (true depth 7 and true
-- depth 23 both show as hex 7). call_depth_maxabs_r is a saturating
-- (clamped at 15, never decrements) magnitude tracker instead: its
-- value across the same 7 timestamped samples is monotonic non-
-- decreasing, so the *trajectory* (not just one noisy sample) shows
-- whether abnormal depth appears specifically during the t=15-30s
-- divergence window or was already present at t=5s (normal nesting).
signal call_depth_maxabs_r : unsigned(3 downto 0) := (others => '0');
-- 2026-08-24 (15th pass): call_depth_maxabs_r saturated at $F from t=5s
-- even after the $0700-entry rezero -- consistent with the loader's own
-- code containing ordinary (benign) JSR-call/JMP-exit asymmetry, which
-- at MHz-order execution rates saturates a maxabs-15 tracker within
-- milliseconds regardless of zero point. Falsifies the COUNTER as a
-- diagnostic, not the underlying theory. Pivoted to a more direct
-- signal: the P65C816 core's VPB (vector pull) output plus the address
-- bus during vector-fetch cycles directly identifies which interrupt
-- vector (if any) fires and when, rather than inferring it indirectly
-- from call/return balance. Latches the low 16 bits of the last
-- vector-fetch address (bank is always $00 for all vector classes) any
-- time VPB pulses low, rezeroed at the same $00:0700 loader-entry PC as
-- call_depth. A nonzero final value after the run means at least one
-- vector pull happened after the loader took over; the specific value
-- (per P65C816.vhd:780-794's ADDR_BUS(3 downto 0) encoding) identifies
-- which vector class: $FFE4/5=COP(native) $FFE6/7=BRK(native)
-- $FFE8/9=ABORT(native) $FFEA/B=NMI(native) $FFEC/D=RESET(native, should
-- never occur post-boot) $FFEE/F=IRQ(native); $FFF4/5=COP(emu)
-- $FFF8/9=ABORT(emu) $FFFA/B=NMI(emu) $FFFC/D=RESET(emu) $FFFE/F=
-- IRQ/BRK(emu, both native BRK and emu BRK/IRQ share this address --
-- distinguish via the live E= overlay field at the same timestamp).
signal vecfetch_addr_r : std_logic_vector(15 downto 0) := (others => '0');
-- 18th pass (2026-08-24): loader.prg's JML ($04FC) exit-vector bytes, as
-- actually read off the CPU data bus (not inferred from static REU-file
-- offsets, which proved unreliable -- see
-- project_wolf3d_postreu_bank28_freeze_regression.md). VICE ground truth
-- for $04FD (hi) / $04FE (bank) is $00/$20 (target $20:0000, clean boot).
signal jmlvec_hi_r      : std_logic_vector(7 downto 0) := (others => '0');
signal jmlvec_bank_r    : std_logic_vector(7 downto 0) := (others => '0');
-- 19th pass (2026-08-24): last-read value of C64 RAM $07B9 (skip-table
-- REU source mid-byte) -- disambiguates the jmlvec divergence between a
-- wrong-REU-offset-read (control-flow) and right-offset-wrong-data
-- (REU-FETCH data integrity) cause. See jmlvec_hi_r comment above.
signal last_07b9_read_r : std_logic_vector(7 downto 0) := (others => '0');
-- 20th pass (2026-08-24): repurposes the existing v250 trace_pc/trace_op
-- ring (rows 14/12) with a NEW freeze trigger. The old $DF01-write
-- trigger is Doom-dispatcher-specific and effectively dead for Wolf3D.
-- loader_armed_r goes high once execution reaches loader.prg's
-- relocated entry ($0700) and stays high; once armed, the FIRST
-- opcode fetch with PC bank=0 and PC>$07DB (past loader.prg's own
-- 220-byte code footprint, which spans exactly $0700-$07DB) freezes
-- the ring. This captures the exact 4 PC/opcode pairs straddling the
-- moment execution leaves loader.prg's own code -- distinguishing a
-- relocation-copy bounds bug (falls straight off $07DB) from a wild
-- branch elsewhere. See project_wolf3d_postreu_bank28_freeze_regression.md
-- 20th-pass update.
signal loader_armed_r   : std_logic := '0';
-- v13 (2026-05-24) $DC0D write count for phantom-write detection
signal dc0d_wr_count_r  : unsigned(15 downto 0) := (others => '0');
-- v231 IRQ source-level falling-edge counter
signal irq_combined     : std_logic;
signal irq_combined_d   : std_logic := '1';
signal irq_fall_count_r : unsigned(15 downto 0) := (others => '0');
-- v12 (2026-05-24) CIA1-only IRQ falling-edge counter for MCP probe
signal irq_cia1_d       : std_logic := '1';
signal irq_cia1_fall_count_r : unsigned(15 downto 0) := (others => '0');
-- v12b (2026-05-24) CIA1 internal reg taps for phantom-write detection
signal cia1_imr_lvl     : std_logic_vector(4 downto 0);
signal cia1_cra_lvl     : std_logic_vector(7 downto 0);
-- mb-probe-003: CIA1 Timer A + ICR internal taps
signal cia1_timer_a_lvl       : std_logic_vector(15 downto 0);
signal cia1_timer_a_latch_lvl : std_logic_vector(15 downto 0);
signal cia1_icr_lvl           : std_logic_vector(4 downto 0);
-- Option F (2026-05-25) CIA2 internal reg taps for LOAD"*",8,1 wedge probe
signal cia2_imr_lvl     : std_logic_vector(4 downto 0);
signal cia2_cra_lvl     : std_logic_vector(7 downto 0);
-- Option G (2026-05-25) CIA2 port + DDR taps for IEC-port phantom-write detect
signal cia2_pra_lvl     : std_logic_vector(7 downto 0);
signal cia2_prb_lvl     : std_logic_vector(7 downto 0);
signal cia2_ddra_lvl    : std_logic_vector(7 downto 0);
signal cia2_ddrb_lvl    : std_logic_vector(7 downto 0);
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
-- v290: capture writer-PC of any "$F7 → $00:$0090" store. Doom hardcodes
-- music_num=-9 ($FFF7) at $2C:$5D78 and $2C:$712C with `LDA #$FFF7; STA $90`.
-- Pins which literal-load site (or other code) writes -9 at runtime.
-- Last-write-wins: Doom halts after music error so last $F7→$90 store is
-- the music store. Printer overwrites $90 with $C0 (string offset) but
-- that doesn't match the cpuDo_pre=$F7 filter.
signal wr90_F7_pc_r     : std_logic_vector(23 downto 0) := (others => '0');
signal wr90_F7_count_r  : unsigned(7 downto 0) := (others => '0');
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
-- 2026-05-09 doom-wait probe: capture the LAST cpu read in $00:$0700-$07FF
-- (page-$07 is where Doom's wait loop at $41:$DB9A polls $00:$0707+X
-- via `df 07 07 00 / b0 03 / d0 fe`, and where the recompiler stores
-- its standard MIPS-jalr indirect pointer used by 58 JML[$0707] sites
-- + 22 JMP($0707) sites). Field rd07xx_addr captures the low byte of
-- the read address; rd07xx_data captures the byte returned. Together
-- they reveal what the wait condition is comparing against.
-- See docs/probe_plan_07xx_read_capture.md and
-- project_doom_wait_loop_at_41db9a.md for full context.
signal rd07xx_addr_r    : std_logic_vector(7 downto 0)   := (others => '0');
signal rd07xx_data_r    : std_logic_vector(7 downto 0)   := (others => '0');
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
-- 2026-08-24 (15th pass): VPB (vector pull, active low) raw output from
-- the P65C816 core via cpu_65c816.vhd's new dbg_vpb port -- asserts low
-- exactly on cycles where the address bus carries a vector-fetch
-- address (P65C816.vhd:819-823, combinational on MC.ADDR_BUS="1111").
signal dbg_vpb_816_i    : std_logic;
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
signal scpu_speed_reg_written : std_logic := '0';                       -- '1' once software writes $D07A/$D07B/$D079; gates emu-mode turbo so the default (Lorenz/BASIC, which never touch it) stays 1MHz
signal emu_serial_throttle    : std_logic := '0';                       -- '1' while emu-mode PC is in the KERNAL IEC serial routines (pages $ED/$EE) -> force 1MHz
signal scpu_sys_1mhz     : std_logic := '0';                            -- $D072=1, $D073=0
signal scpu_force_1mhz   : std_logic := '0';                            -- = scpu_speed_1mhz OR scpu_sys_1mhz OR cia2_throttle_active
-- Problem C (Codex 2026-05-27): per-access CIA2 auto-throttle. Whenever
-- the CPU touches $DD00-$DDFF and supercpu_en is on, hold the 1MHz
-- throttle for N clk32 cycles so KERNAL's IEC byte-receive loop at
-- $EEAF gets stock-CIA2 timing without requiring software to set $D072.
-- Fixes MCP+LOAD wedge (PC stuck at $00:$E5D5, IRQ counter frozen, see
-- memory btest_passthrough_breaks_boot for diagnostic confirmation).
signal cia2_throttle_active : std_logic := '0';
signal cia2_throttle_cnt    : unsigned(6 downto 0) := (others => '0');   -- 7-bit: 0..127 clk32 cycles (1..4 1MHz periods)
signal scpu_regs_enabled : std_logic := '1';                            -- $D07E enables, $D07F/$D07D disables
signal scpu_hwenable     : std_logic := '0';                            -- ANY write to $D07E sets; $D07F/$D07D clears
signal scpu_bootmap      : std_logic := '1';                            -- v343 retry: bootmap on at reset (kickstart needs it)
-- 2026-05-11 attempt with bootmap='1' wedged because EPROM kickstart at
-- $F8:$80C1 loops in $00:$8054-$8082 handler region. Since then two
-- structural fixes landed that touch the kickstart's environment:
--   b2d44d1 — I/O decode read-mux now respects bank (kickstart probes I/O)
--   41b1ae2 — $0EED IRQ wedge cleared (raster IRQ + $D01A persistence)
-- v343 retries bootmap='1' at cold boot. If still wedges, defaulting to
-- '0' is one-line revert. Wolf3D needs kickstart to populate banks
-- $F0-$FE with copied ROM code (49+98+67 JMLs to $FC/$F5/$F4 hit empty
-- SuperRAM and spin in $00:$284A loop at runtime).
signal scpu_optim_mode   : unsigned(1 downto 0) := "11";                -- $D074-$D077 select; "11" = no optimization
-- Bug 3 (firmware_correctness_plan.md Stage 1): SIMM-extent registers
-- $D27C-$D27F are writable by the kickstart's STZ at $F8:$81EB-$81F0.
-- Real HW exposes these as the available-RAM extent so software can size
-- itself. Reset defaults match the prior hardcoded read constants so any
-- consumer that polls them before the kickstart writes sees the same
-- "$02-$F6 = SuperRAM bank $02..$F5" geometry the v347 build advertised.
signal scpu_simm_27c     : unsigned(7 downto 0) := x"00";                -- first available page low
signal scpu_simm_27d     : unsigned(7 downto 0) := x"02";                -- first available page bank
signal scpu_simm_27e     : unsigned(7 downto 0) := x"00";                -- last+1 page low
signal scpu_simm_27f     : unsigned(7 downto 0) := x"F6";                -- last+1 page bank
-- Phase 5 (WriteSmart + write buffer drain) — architectural gap analysis.
--
-- Real CMD SuperCPU has 128KB on-board SRAM + 1-byte write buffer that
-- captures CPU writes at 20MHz then drains to the 1MHz motherboard bus
-- in the background; the optimization-mode register ($D074..$D077) gates
-- whether the slow drain copy happens at all (mode 0 = always mirror;
-- mode 3 = SRAM-only writes, motherboard stays stale).
--
-- vanilla-cpu-swap structurally cannot duplicate this because we have
-- NO separate motherboard-mirror to skip. Writes already go directly
-- to their final destination:
--   bank $00 RAM   → c64_ram64k BRAM (1-cycle clk32, full SCPU speed)
--   bank $01-$FF   → SDRAM (3-stage pipeline, completes within CPUC slot)
--   I/O ($Dxxx)    → CIA/SID/VIC at 1MHz via CYCLE_CPUC arbitration
--                    (which itself stretches the I/O cycle 3-5 clk32 ≈
--                    the same window a 1-byte write buffer would queue
--                    a 1MHz write into before the CPU runs free again)
--
-- So our existing CPUC-only arbitration IS the write buffer functionally.
-- optim_mode register stays software-visible (so JiffyDOS / SuperCPU
-- software that polls $D0B4 sees consistent behaviour) but doesn't
-- gate any internal path because there's no slow-mirror path to gate.
--
-- Implementing a true WriteSmart with separate motherboard-mirror SRAM
-- (the "Real HW: 128KB SRAM" entry in CLAUDE.md) would require ~32KB
-- additional M10K (we're at 73%) + a write-arbitration FSM. 4 prior
-- master-branch attempts black-screened on first boot. Not attempted
-- here without an off-device cocotb write-path harness that does not
-- currently exist.
signal scpu_irq_tramp_installed : std_logic := '0';                     -- '1' once software has written to $00:$FCEE-$FCF1 (user IRQ handler installed); '0' = use default JML stub
signal scpu_irq_vec_installed   : std_logic := '0';                     -- v356: '1' once software has written $00:$FFEE or $FFEF (own native IRQ vector); used by stub-tail JML to pick user vec vs hardcoded Doom $0D3C fallback
-- Phase 6 — DOS extension mode ($D0BC R/W + $D0BE / $D0BF).
-- Per VICE scpu64mem.c, $D0BC stores a flag byte that JiffyDOS-style
-- fast loaders and SuperCPU file extensions read to detect SCPU
-- presence + DOS-extension availability. $D0BE writes set the mode
-- (typical $80 = enabled), $D0BF writes clear it. Most software
-- ignores this — included for full VICE/CMD spec coverage so any
-- title that polls it sees consistent behaviour.
signal scpu_dos_ext_mode : unsigned(7 downto 0) := x"00";

-- Phase 3 — writable native vectors at $00:$FFE4..$FFEF (12 bytes).
-- EPROM kickstart writes real handler addresses here during cold boot;
-- the bootmap intercept (in fpga64_buslogic.vhd) gives the kickstart
-- a way to run from EPROM, and these writable vectors let it install
-- the real CMD handler entry points so native BRK/COP/ABORT/NMI/IRQ
-- traps land in the kernel kickstart copied to $00:$801A-$8054.
-- Reset defaults point at $00:$FF00 (existing RTI sink) — matches
-- the prior hardcoded intercept exactly, so cold-boot behaviour
-- before EPROM runs is unchanged.
-- Index: 0..1 = $FFE4..$FFE5 (COP), 2..3 = $FFE6..$FFE7 (BRK),
--        4..5 = $FFE8..$FFE9 (ABORT), 6..7 = $FFEA..$FFEB (NMI),
--        8..9 = $FFEC..$FFED (unused), 10..11 = $FFEE..$FFEF (IRQ).
type native_vec_array is array(0 to 11) of unsigned(7 downto 0);
signal scpu_native_vec : native_vec_array := (
    0 => x"00", 1 => x"FF",   -- COP   → $00:$FF00
    2 => x"00", 3 => x"FF",   -- BRK   → $00:$FF00
    4 => x"00", 5 => x"FF",   -- ABORT → $00:$FF00
    6 => x"00", 7 => x"FF",   -- NMI   → $00:$FF00
    8 => x"00", 9 => x"FF",   -- unused
    10 => x"00", 11 => x"FF"  -- IRQ   → $00:$FF00
);
-- v2 of NMI install path (2026-05-09): hold a 16-bit register that
-- shadows whatever software wrote to $XX:$FFEA/$FFEB (XX=$00 or $FF —
-- per AmiDog recomp's `.databank $ff` hint, the runtime may write the
-- NMI vector with DBR=$FF, not DBR=$00). Native NMI vector reads at
-- $00:$FFEA/$FFEB always return this register, defaulted to the safe
-- $FF00 ack stub at cold boot.
signal scpu_nmi_vec_lo : std_logic_vector(7 downto 0) := x"00";
signal scpu_nmi_vec_hi : std_logic_vector(7 downto 0) := x"FF";
signal cpuDi_raw         : unsigned(7 downto 0);                        -- raw bus data; SuperCPU regs mux ahead of this
signal cpuDi_nocache     : unsigned(7 downto 0);                        -- iter-7d: cpuDi WITHOUT the read-path cache override (SCPU regs + ramDin/cpuDi_raw). The exact byte the CPU reads on a cache MISS; the read-path cache fills from THIS (never cpuDi) so a registered-override spurious assert can't feed cache output back into a miss fill (Codex iter-7d Q3).
signal io_data_i    : unsigned(7 downto 0);
signal ioe_i        : std_logic;
signal iof_i        : std_logic;

signal io_enable    : std_logic;
signal cpu_cyc      : std_logic;
signal cpu_cyc_va_ok : std_logic;   -- iter-27: VDA/VPA qualifier for the main prefetch (INTERNAL_FAST_FIRE only)
signal cpu_cyc_s    : std_logic_vector(1 downto 0);
signal turbo_m      : std_logic_vector(2 downto 0);
-- iter-15 (2026-06-02): same-line 2x alt-fire single gap-gated enable scheduler.
-- en_gap = clk32 since the last generated enableCpu pulse (bench `cycles_since_latch`
-- convention: reset to 0 on fire, +1 otherwise, saturating). Gates the fast 2-apart
-- consume (en_gap>=1 + LIVE same-line + LIVE hit) vs the full-margin main (en_gap>=3 =
-- the proven 4-apart cadence/SDRAM window). See docs/iter14_altfire_rtl_brief.md
-- "iter-15 CORRECTION" + the proof bench cpu_cache_sched_phasing_tb. Inert when
-- ALT_FIRE_SAMELINE=false (enableCpu stays = cpu_cyc_s(1), RBF bit-identical).
signal en_gap       : unsigned(5 downto 0) := (others => '1');

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

-- CIA2 write latch+replay (Codex 2026-05-27): the v13g cia2_write_safe
-- gate keeps cs_n='0' for ~2 clk32 around the bridge access window, but
-- in MCP mode the actual CIA write-sample edge (rising clk32 at end of
-- CYCLE_CPUD interval where phi2_n=enableCia_n='1') can miss that window
-- entirely. mos6526.v:123 latches on `wr = phi2_n & !cs_n & !rw` at
-- posedge clk → cs_n must be '0' during the CYCLE_CPUD interval. We
-- capture the write into pending regs whenever cs_cia2+cpuWe+write_safe
-- is true, then replay (fire) at sysCycle=CYCLE_CPUC so cs_n is held
-- low for the full CYCLE_CPUD interval.
signal cia2_wr_pending : std_logic := '0';
signal cia2_wr_fire    : std_logic := '0';
signal cia2_wr_rs      : unsigned(3 downto 0) := (others => '0');
signal cia2_wr_do      : unsigned(7 downto 0) := (others => '0');
signal cia2_cs_n       : std_logic;
signal cia2_rw_q       : std_logic;
signal cia2_rs_q       : unsigned(3 downto 0);
signal cia2_db_q       : unsigned(7 downto 0);

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
-- v346 sticky OR of vicDi over one frame, used by debug overlay/UART.
-- Resets on vSync rising edge; accumulates non-zero bytes through the
-- frame. Latched into the dbg pool on the same edge that resets it, so
-- the UART/overlay sees the previous frame's OR value.
signal vic_di_or_r   : unsigned(7 downto 0) := (others => '0');
signal vic_di_or_lat : unsigned(7 downto 0) := (others => '0');

-- more-turbo iter-4d (2026-05-30): read-only cpu_cache HIT-RATE OBSERVER.
-- Structurally mirrors sim/c64_reduced_harness/c64_cache_hitrate_tb.vhd (which
-- was cross-validated against tools/cache_replay.py at 94.13%): a uniform 1-clk
-- tap register, then a real cpu_cache fed read-only (cacheable_wr is hard '0'
-- in the RTL; wb_enable='0' here). cache_hit is observed ONLY — never wired to
-- the CPU — so this whole block is behaviourally inert (cannot break boot/Doom/
-- Lorenz). The bench taps cobs_*_cum via external names to confirm the in-RTL
-- observer reproduces the same hit count before any synthesis build.
signal tap_addr_r    : unsigned(15 downto 0) := (others => '0');
signal tap_bank_r    : unsigned(7 downto 0)  := (others => '0');
signal tap_we_r      : std_logic := '0';
signal tap_di_r      : unsigned(7 downto 0)  := (others => '0');
signal tap_do_r      : unsigned(7 downto 0)  := (others => '0');
signal tap_en_r      : std_logic := '0';
signal tap_valid_r   : std_logic := '0';
signal cobs_reset    : std_logic;
signal cobs_di       : unsigned(7 downto 0);   -- cache_di (observed, unused)
signal cobs_hit      : std_logic;              -- cache_hit (observed, NOT fed to CPU)
signal cobs_cacheable: std_logic := '0';
signal cobs_eval     : std_logic := '0';       -- this clk32: a cacheable READ step
-- cumulative (exact GHDL cross-check vs c64_cache_hitrate_tb acc_reads/acc_hits)
signal cobs_reads_cum: unsigned(31 downto 0) := (others => '0');
signal cobs_hits_cum : unsigned(31 downto 0) := (others => '0');
-- 256-read sliding window -> steady-state hit rate (drops cold compulsory misses)
signal cobs_win_cnt  : unsigned(7 downto 0) := (others => '0');  -- 0..255, wraps each 256 reads
signal cobs_win_hits : unsigned(8 downto 0) := (others => '0');  -- hits in current window (0..256)
signal cobs_hr_reg   : unsigned(7 downto 0) := (others => '0');  -- last window: hits-per-256 (sat 255)
signal cobs_hw_reg   : unsigned(7 downto 0) := (others => '0');  -- window-completion count (liveness)

-- iter-29 (2026-06-13) PAGE-HIT-RATE observer. Read-only; measures the DRAM
-- row-locality of the CPU's SDRAM access stream to gate the page-mode SDRAM
-- rewrite (the only remaining sound speed lever — see
-- project_pagemode_decision_rule_corrected). Models a realistic page-mode
-- controller with ONE OPEN ROW PER SDRAM BANK (the SDRAM device keeps 4 rows
-- open, sd_ba=addr[22:21]=supercpu_bank[6:5]). A bank's row stays open until a
-- different-row access to THAT bank or a refresh (refresh precharges all banks).
-- HIT = this CPU cs_ram access targets the same row[20:8] as the currently-open
-- row of its bank. This is the CORRECT model: it does NOT count bank-$00
-- zeropage/stack accesses as evicting the SuperRAM (bank $28→sd_ba"01") row, so
-- it captures the speedup a per-bank page-mode controller would actually see.
-- (build #1, md5 42b6da7c, used a single GLOBAL open row = a lower bound: Doom
-- title-screen ~50% because interleaved bank-$00 accesses falsely evicted the
-- SuperRAM row. This per-bank build is the decisive number.)
-- Repurposes the PH:## PW:## UART field (the cpu_cache observer it replaces is
-- dead; that instance then prunes). PH = hits per 256 CPU SDRAM accesses (sat
-- 255; PH/2.56 ~= %), PW = window-completion counter (liveness). CORRECTED
-- decision rule: HIGH PH => page-mode is a big win => pursue; PH<~45% => drop.
-- Counter-only: changes NO cadence => cannot wedge (safe to build). When
-- PAGEHIT_OBSERVER=false, dbg_cache_hr/hw revert to cobs => RBF bit-identical.
-- iter-30 (2026-06-13) D-GATE: re-enabled to model a WIDER open row. A1 found
-- Doom's SuperRAM traffic is ~99% reads (write fraction ~0.7%), so the read path
-- is where ~all SuperRAM bandwidth is => the read-latency lever (page-mode) is the
-- matching option. VICE models 2-8KB SIMM rows; ours is 256B because the SDRAM
-- column = {addr[23]=1(fixed), c64_addr[7:0]} => only c64_addr[7:0]=256 sequential.
-- PAGEHIT_COL_EXTRA folds N extra low row-bits into the column to model a column
-- remap: 0=256B (iter-29 baseline, got ~54%), 1=512B (achievable: use all 9 chip
-- column bits = c64_addr[8:0]), 2=1KB, 3=2KB (theoretical ceiling — needs >9
-- column bits the chip lacks). Mask the low COL_EXTRA bits of req_row to 0 so
-- addresses sharing a wider aligned region count as the same open row. If 512B
-- locality is materially >54%, page-mode+remap revives; else page-mode stays
-- dropped and only the 65C816-internal pipeline (Lever 2) remains.
constant PAGEHIT_OBSERVER  : boolean := false;  -- iter-31: slot handed to BANKFRAC_OBSERVER
constant PAGEHIT_COL_EXTRA : integer := 0;   -- 0=256B(canonical) 1=512B 2=1KB 3=2KB; iter-30 measured 512B==54%==256B (no gain, remap useless)
type ph_row_arr_t is array(0 to 3) of unsigned(12 downto 0);
signal ph_row_b     : ph_row_arr_t := (others => (others => '0'));  -- open row per sd_ba
signal ph_valid_b   : std_logic_vector(3 downto 0) := (others => '0');
signal ph_win_cnt   : unsigned(7 downto 0)  := (others => '0');  -- 0..255
signal ph_win_hits  : unsigned(8 downto 0)  := (others => '0');  -- 0..256
signal ph_hr_reg    : unsigned(7 downto 0)  := (others => '0');  -- hits per 256 (sat 255)
signal ph_hw_reg    : unsigned(7 downto 0)  := (others => '0');  -- window-completion (liveness)

-- ── iter-30 (2026-06-13) TRACK A1: WRITEFRAC_OBSERVER — read-only, wedge-safe ──
-- Sizes the posted-write-buffer payoff (Track C) before any risky build by
-- measuring what FRACTION of the CPU's SuperRAM (scpu_fast_path) SDRAM accesses
-- are WRITES. VICE confirms the SuperCPU's speed model posts writes (free) while
-- reads cannot be (scpu64cpu.c buffer_finish/wait_buffer); our gain is therefore
-- bounded by this write fraction. Counter-only: shares the EXACT structure of
-- pagehit_obs (256-access window, sat-255 result, liveness counter) and changes
-- NO cadence => cannot wedge. Reuses the dead HR/HW UART slot, now labelled
-- "WF:## WW:##" in debug_uart_pool_fmt.sv. WF = SuperRAM writes per last 256
-- SuperRAM CPU SDRAM accesses (sat $FF; WF/2.56 = write %); WW = window-completion
-- counter (advances => observer live). Gate = cpu_cyc='1' and cs_ram='1' and
-- scpu_fast_path='1' (SuperRAM bank $02+, exactly the buffer's target); tally =
-- cpuWe='1'. When WRITEFRAC_OBSERVER=false the mux reverts (PAGEHIT or cobs) =>
-- RBF bit-identical. Probe: tools/writefrac_probe.py.
constant WRITEFRAC_OBSERVER : boolean := false;  -- iter-30: A1 measured (~0.7%), slot handed back to PAGEHIT for the wider-row D-gate
signal wf_win_cnt   : unsigned(7 downto 0)  := (others => '0');  -- 0..255 SuperRAM accesses
signal wf_win_wr    : unsigned(8 downto 0)  := (others => '0');  -- writes in window 0..256
signal wf_fr_reg    : unsigned(7 downto 0)  := (others => '0');  -- writes per 256 (sat 255)
signal wf_ww_reg    : unsigned(7 downto 0)  := (others => '0');  -- window-completion (liveness)

-- ── iter-31 (2026-06-13) BANKFRAC_OBSERVER — read-only, wedge-safe ──────────────
-- Sizes the AUTHORITATIVE bank-$00 BRAM lever (operator question 2026-06-13: the
-- real SuperCPU's fast tier is the 128KB SRAM banks $00/$01, which we run in slow
-- SDRAM). Moving bank $00 into BRAM only pays in proportion to the bank-$00 share
-- of CPU memory traffic — instruction fetch is SuperRAM ($20) and stays SDRAM-
-- bound. This counts, over each 256 total CPU SDRAM (cs_ram) accesses, how many
-- target bank $00 (addr_hi_816 = $00). BF = bank-$00 accesses per last 256 CPU
-- SDRAM accesses (sat $FF; BF/2.56 = bank-$00 %); BW = window-completion liveness.
-- EXACT structure of pagehit/writefrac (no cadence change => cannot wedge); reuses
-- the dead HR/HW UART slot. Probe: tools/bankfrac_probe.py.
constant BANKFRAC_OBSERVER : boolean := true;   -- iter-31: measure bank-$00 access fraction (prize for bank-$00 BRAM)
signal bf_win_cnt   : unsigned(7 downto 0)  := (others => '0');  -- 0..255 total CPU SDRAM accesses
signal bf_win_b0    : unsigned(8 downto 0)  := (others => '0');  -- bank-$00 accesses in window 0..256
signal bf_fr_reg    : unsigned(7 downto 0)  := (others => '0');  -- bank-$00 per 256 (sat 255)
signal bf_ww_reg    : unsigned(7 downto 0)  := (others => '0');  -- window-completion (liveness)

-- ── more-turbo iter-6: READ-PATH (cache feeds the CPU) — GATED, ADDITIVE ──
-- CACHE_READ_PATH=false (default) => the read-path generate block below emits
-- ZERO hardware and rp_cache_* keep their inert defaults, so cpuDi + the
-- arbiter hit predictor are bit-identical to today (the observer above is the
-- only cache instance). Flip true ONLY to (a) run the c64_reduced_harness boot
-- test with the cache feeding the CPU (functional M10K-latency/alignment proof,
-- GHDL models the 1-clk cache_di latency), or (b) a probe synth to read STA on
-- the cache_di->cpuDi path. The two consumers (cache_di->cpuDi override at the
-- top of the cpuDi mux + rp_cache_hit->sdram_hit_pred short grant) are wired as
-- an INSEPARABLE pair — shortening the grant without the data override is the
-- Doom BRK $00:000A stale-latch class. Read-only: write hits stay disabled.
constant CACHE_READ_PATH : boolean := false;  -- iter-22 REVERTED to Doom-safe baseline after HW-FALSIFICATION (build 404422c5, 2026-06-04): cache-on + FILL_CANCEL_ON_WRITE did NOT fix Bug 2 — Doom wedged at PC:00D013 (crashed into I/O space, white screen) and the divergence detector STILL read WD=2 at $20:00AE (cache=$00 vs SDRAM=$4A), byte-identical to iter-18. WHY the GHDL-proven cancel was a HW no-op: the cancel window (read-miss -> fast fill-fire, ~4 clk32) does NOT overlap the loader's write to $20:00AE (which lands many loops later); the fill FIRES and allocates the stale $00 BEFORE the write arrives, so there is no pending fill to cancel. cpu_cache_fill_invalidate_race_tb modeled the write INSIDE the pending window = a timing that does not occur in deployed passthrough (same class of sim/HW mismatch as FILL_TXMATCH iter-16). FILL_CANCEL_ON_WRITE stays in source (inert when false; closes a real but rare race) but is NOT the Bug-2 cause. NEXT (GHDL-first): a SYSTEM-level repro (c64_reduced_harness: fpga64 + sdram_pm + loader write->read with real fill/invalidate timing) is required — the cpu_cache UNIT bench cannot see the actual fill-fire-vs-write ordering. [iter-18 history follows] RESTORED Doom-safe baseline (was true for the ground-truth override build 595008b1). RBF bit-identical to shipped when false; all cache constants below become don't-care. iter-18 RESULT: the FILL_DATAVALID_GATE fix (below) collapsed the HW divergence detector from WD=FFFF (saturated, unfixed) to WD=2 ⇒ the fill-data-phase root cause + fix are corroborated on silicon. RESIDUAL: 2 mismatches at bank $20 $00AE, cache=$00 vs SDRAM=$4A — the $00 is a pre-write/empty value = a SECOND, distinct loader-write→fill-read ORDERING race (Codex candidate a), NOT the fill-phase bug. The override consume path is still HW-UNVALIDATED: the REU loader was environmentally stuck (WP:00FD83 fetch-wait + KERNAL idle $E5xx, CPU never reached bank $20). NEXT (GHDL-first): extend sim/cache_coherency_tb to model the loader-WRITE→fill-READ ordering (cache=$00 residual) before any further override-on HW build. --- iter-17 DIAG BUILD (Build-D config: data override OFF + divergence detector). RESTORE false after. DOOM-SAFE BASELINE (restored 2026-06-03 after iter-17 Build D). iter-17 RESULT: Build D (this=true, CACHE_DATA_OVERRIDE=false, HITPRED_SHORTGRANT=false) reaches the DOOM TITLE SCREEN ⇒ the cache FOOTPRINT is INNOCENT; the cache-on Doom crashes are TWO FUNCTIONAL bugs — (1) hit_pred grant [leave HITPRED_SHORTGRANT=false, mooted], (2) the `_d1` cpuDi data override serving a wrong bank-$20 byte [ISOLATION C `4160e2ef`, the bug to FIX next, GHDL-first]. Lever SALVAGEABLE: fix bug 2 → re-enable (true + CACHE_DATA_OVERRIDE=true + HITPRED_SHORTGRANT=false), then add ALT_FIRE for the 3×. iter-17 DIAGNOSTIC 2026-06-03: cache instance + fill + hit_pred all LIVE but the cpuDi DATA override is gated OFF via CACHE_DATA_OVERRIDE (below). Partitions Bug 2: if Doom RUNS, the corruptor is the data override (cache_di->cpuDi->P65C816, logically coherent per me+Codex => timing-marginal); if Doom CRASHES, the only remaining active difference is the sdram_hit_pred short grant ("001" reservation on a HIT), confirming the grant/dual-tracker desync. RESTORE :=false after the experiment. PRIOR: iter-16 2026-06-03 HW RESULT: the transaction-matched fill fix (FILL_TXMATCH, build af834bf9) had ZERO effect on Doom — it crashes at the IDENTICAL instruction (last good PC:2003AB fetching real bytes 8D 7A D0 A9, then a stale operand sends PC wild to $80007F -> bank $4D/$2B runaway -> bank-$00 wedge), byte-for-byte the same as the unfixed cache-on build 38118b68. => the fill-tuple SKEW is NOT Bug 2's HW cause: in the deployed SAME_CLOCK_PASSTHROUGH config the bridge holds cpuAddr stable through the access, so capture-at-issue == live cpuAddr at the fill edge = a no-op. Bug 2's corruptor is elsewhere on the read path (prime remaining suspect: the iter-7d registered _d1 hit/di override serving a cross-line-stale byte). REVERTED FALSE to keep the shipped baseline Doom-safe; re-investigate GHDL-first before the next build. The FILL_TXMATCH capture RTL stays in source (correct-in-principle, inert while this gate is false). [Earlier note, still valid for the cache-OFF A/B:] Was REVERTED FALSE 2026-06-02 to restore Doom. HW-FALSIFIED for Doom: full UART trace (doomtrace_38118b68) shows the loader DOES populate bank $20 + Doom DOES launch (PC:2000B6, first fetches = real code 8D 7A D0 A9), but the SuperRAM cache then serves STALE bytes on bank-$20 reads => Doom reads a garbage operand, JMPs wild to bank $2B/$4D, crashes to bank-$00 runaway (SP draining). Confirmed cadence-INDEPENDENT (alt-fire OFF in build 38118b68 still corrupts) so the iter-15 3x speedup, which intrinsically needs this path, is unshippable until a GHDL-proven SuperRAM write->read coherency fix lands. cache-OFF baseline (95db2dda) reaches Init Playloop on the SAME SDRAM image => bank $20 has real data => the read path is the corruptor. Re-enable ONLY after sim/cache_coherency_tb reproduces the bank-$20 loader-write->Doom-read staleness + proves the fix. [orig default false] (RBF bit-identical to shipped when off). iter-15: was flipped TRUE to feed the cache + the same-line 2x scheduler (ALT_FIRE_SAMELINE). HW-proven clean at 4-apart (iter-7e e9c36c3e) for BOOT/Lorenz but NOT Doom. [orig default false] (RBF bit-identical when off). ITER-7e 2026-05-31 HW-CONFIRMED: with fix B (rp_cacheable excludes ROM-shadowable bank-$00 $8/9/A/B/E/F + non-RAM $D), probe build e9c36c3e (this flag TRUE) BOOTS CLEAN (SCPU64 V0.07/READY) + Lorenz scpu PASS (serial LOAD = the e0e83e5c corruption case, now clean) + Lorenz t65 PASS (no regression). FIRST clean HW boot of the cache read path feeding the CPU. Ships false until the variable-cadence 2x arbiter (the actual speedup; this is correctness-only at 4-apart). ITER-7d 2026-05-31: the cpuDi override now consumes the REGISTERED rp_cache_hit_d1/rp_cache_di_d1 (below) + fills from cpuDi_nocache, converting the masked single-cycle consume into a genuine 2-cycle path. Scripted setup-1 STA on the fitted probe build 3514fc7d (cache_sta_probe.tcl, cache_1cyc_path_iter7d.txt): forced -setup 1 worst slack = +7.797ns (0 viol) on rp_cache_hit_d1 -> P65C816|AddrGen|PCr — vs iter-6's -0.651ns FAIL on the un-registered path. So the masked-timing violation behind the iter-7c boot corruption (build 0228d2b6 garbled boot) is ELIMINATED off-device. REMAINING GATE = HW (needs MiSTer): flip true, build, confirm boot clean + Lorenz scpu/t65 100% + Doom no-regress at the existing 4-apart cadence (this is correctness-only — no speed change yet; the variable-cadence 2x arbiter is the follow-up). Until HW-confirmed, ships false. HISTORY: iter-7c (this flag true, pre-register) HW-FALSIFIED — fill-on-miss-only corrupted boot ("< 0JEEP"), control 97392a1f clean; iter-7b cache-only (e0e83e5c) booted clean but corrupted Lorenz LOAD.
-- iter-17 DIAGNOSTIC (2026-06-03): independent gate for the cpuDi cache-DATA
-- override, so a CACHE_READ_PATH=true build can run with the cache instance +
-- fill + sdram_hit_pred ALL live while the CPU still gets SDRAM-passthrough data
-- (cpuDi = cpuDi_nocache). This partitions Bug 2 (Doom cache-on crash) into
-- "data override" vs "hit_pred grant" — the only two things cache-on changes,
-- both functional-coherent per me+Codex (=> remaining cause is timing/CDC, not
-- logic). Set false for the diagnostic build; restore true (with CACHE_READ_PATH
-- false) for the shipped Doom-safe baseline where this is don't-care.
constant CACHE_DATA_OVERRIDE : boolean := true;  -- iter-18 GROUND-TRUTH build: override ON to directly test the FILL_DATAVALID_GATE fix (the divergence detector is phase-ambiguous — it samples cpuDi_nocache at the consume edge launch+2, BEFORE data is fresh @ launch+3, so even a CORRECT cache mismatches the stale reference => WD unreliable). Doom override-on is the unambiguous test: reaches title/menu + Lorenz clean => fill fix WORKS, add alt-fire for 3x; crashes => fix insufficient (switch to dout_reu VIC-immune fill source). PRIOR (iter-17 DIAG): Build-D config (override OFF => CPU reads SDRAM, Doom runs clean) so the divergence detector below can flag cache!=SDRAM with no crash noise. RESTORE true after. don't-care while CACHE_READ_PATH=false (Doom-safe baseline). iter-17 BUILD D (2026-06-03) flipped this to data override OFF + HITPRED_SHORTGRANT=false => BOTH CPU-facing cache effects off, but CACHE_READ_PATH=true so the cache is still compiled-in + filling/snooping. DECISIVE corner of the partition: vs 48730a04 (data off, hit_pred ON => CRASH) differs only by hit_pred; vs ISOLATION C 4160e2ef (data ON, hit_pred off => CRASH) differs only by data override. D RUNS => 48730a04 crash was hit_pred + ISOLATION C crash was the _d1 data override (TWO functional bugs, footprint innocent); D CRASHES => the cache's mere presence corrupts (masked-timing / fitter footprint, STA-clean but real-violating, the clk48/SLOT3 class) => cache lever DEAD for Doom => pivot to Milestone C. PRIOR: iter-17 FIX build had this true (ISOLATION C, HW-CRASHED 4160e2ef 2026-06-03 — turning hit_pred off did NOT save Doom, so hit_pred is not the sole corruptor; the data override is implicated). RESTORE true (with CACHE_READ_PATH=false) for the shipped Doom-safe baseline where this is don't-care.
-- iter-17 Bug 2 FIX gate: false => sdram_hit_pred forced '0' (no cache-hit grant
-- shortening), the HW-proven corruptor (diagnostic 48730a04). Assignment ~:3411.
constant HITPRED_SHORTGRANT : boolean := false;
signal rp_cache_di   : unsigned(7 downto 0) := (others => '0'); -- inert default => override never fires
signal rp_cache_hit  : std_logic := '0';                       -- inert default => hit_pred stays '0'
signal rp_cacheable  : std_logic := '0';
-- iter-15: the cache's LIVE same_line (line/tag equality vs the previous clk32's
-- address). Wired from read_path_cache.same_line (was `open`). The fast 2-apart fire
-- gate reads this LIVE (NOT registered _d1) at the even fire-eval slot — proven by
-- cpu_cache_sched_phasing_tb (LIVE=PASS, _d1=FAIL) + Codex. Inert '0' when the read
-- path is absent (CACHE_READ_PATH=false) => fast path can never fire.
signal rp_same_line  : std_logic := '0';
signal rp_fill_we    : std_logic := '0';
-- iter-7d (2026-05-31): REGISTERED cache-HIT override. The cpuDi override now
-- consumes these 1-clk32-delayed copies instead of the combinational
-- rp_cache_hit/rp_cache_di, so the masked single-cycle path
-- line_word->cache_di(byte-select)->cpuDi->P65C816 and tag_mem->tag_match->cpuDi
-- (select) are BOTH split by a pipeline register => the forced setup-1 STA probe
-- should go positive (iter-7c HW corruption was that masked single-cycle consume).
-- Edge phase (cross-line hit, addr presented at edge N): rp_cache_di correct only
-- from [N+1,N+2) (line_word settles at N+1); the register samples it into
-- rp_cache_di_d1 valid from [N+2,N+3). The CPU latches at the 4-apart main slot
-- (~N+4) so the settled value is captured; the transient stale window [N+1,N+2)
-- is never latched (alt_fire OFF => strictly 4-apart). Inert '0' defaults keep
-- CACHE_READ_PATH=false bit-identical. See docs/iter7d_codex_brief.md.
signal rp_cache_di_d1  : unsigned(7 downto 0) := (others => '0');
signal rp_cache_hit_d1 : std_logic := '0';

-- iter-17 DIAGNOSTIC (2026-06-03): cache-HIT data-divergence detector. On every
-- consume edge where the override would fire (rp_cache_hit_d1='1'), compare the
-- cache byte the override DELIVERS (rp_cache_di_d1) against the live SDRAM
-- passthrough (cpuDi_nocache = the Build-D-proven-correct byte for cpuAddr). Any
-- mismatch IS Bug 2 (the cache serves != SDRAM on a hit). Captures the FIRST one
-- {addr,bank,cache,sdram} + a saturating count. Run in Build-D config (override
-- OFF) so Doom runs clean and the count reflects pure content divergence, NOT
-- post-crash pollution. count==0 => content coherent => bug is override DELIVERY
-- (phase/line_word), not content. count>0 => content diverges => addr/bytes show
-- where/what. Exposed via the (passthrough-inert) bridge probe UART fields below.
signal diag_mm_count   : unsigned(15 downto 0) := (others => '0');
signal diag_mm_addr    : unsigned(15 downto 0) := (others => '0');
signal diag_mm_bank    : unsigned(7 downto 0)  := (others => '0');
signal diag_mm_cache   : unsigned(7 downto 0)  := (others => '0');
signal diag_mm_sdram   : unsigned(7 downto 0)  := (others => '0');

-- iter-16 (2026-06-03): TRANSACTION-MATCHED FILL TUPLE (Bug 2 fix).
-- The read-path cache fill data (fill_data => cpuDi_nocache) is the SDRAM read
-- result for the address the CPU ISSUED a few clk32 ago, but fill_addr/fill_bank
-- were wired to the LIVE cpuAddr/addr_hi_816. In passthrough the P65C816 core
-- drives its NEXT fetch address combinationally while `enable` is high, so at the
-- rp_fill_we (=enableCpu_816) fill edge the live cpuAddr has already advanced past
-- the address whose data is on cpuDi_nocache => the fill stores the just-read byte
-- under a LATER address's line => a later read of that line HITs and returns the
-- stale "previous byte" (the Doom bank-$20 runaway, project_cache_invalidate_cpuen
-- _hole). FIX: capture {addr_hi_816,cpuAddr} at SDRAM read-ISSUE (the cpu_cyc CPU
-- SuperRAM read slot, where cpuAddr = the address actually driven to SDRAM, proven
-- correct because cache-OFF consumes that data right) and tag the fill with the
-- captured tuple. Robust to the exact pipeline latency / combinational advance.
-- GHDL-proven: cpu_cache_superram_pipe_tb (live tag = 63/64 stale; matched = 0).
-- Inert when CACHE_READ_PATH=false (regs unused, fill_addr falls back to cpuAddr).
signal rp_fill_addr_r  : unsigned(15 downto 0) := (others => '0');
signal rp_fill_bank_r  : unsigned(7 downto 0)  := (others => '0');
signal rp_fill_addr_sel : unsigned(15 downto 0) := (others => '0'); -- FILL_TXMATCH mux
signal rp_fill_bank_sel : unsigned(7 downto 0)  := (others => '0');
-- iter-18 (2026-06-03): Bug 2 ROOT-CAUSE fix — data-valid-gated delayed fill.
signal rp_fill_we_imm   : std_logic := '0';                          -- legacy immediate miss-fill
signal rp_fill_req      : std_logic := '0';                          -- pending miss-fill (set @ consume, cleared @ fire)
signal rp_fill_fire     : std_logic := '0';                          -- fire when SDRAM data fresh
signal rp_fill_addr_dly : unsigned(15 downto 0) := (others => '0');   -- addr latched @ consume (matched to dout_r)
signal rp_fill_bank_dly : unsigned(7 downto 0)  := (others => '0');
-- iter-24 STAGED FILL (FILL_STAGED_TUPLE): the reg->reg fill tuple staged one
-- clk32 after rp_fill_fire so the M10K write data comes from a settled register
-- instead of the deep cpuDi_nocache mux. Inert when FILL_STAGED_TUPLE=false.
signal rp_fill_data_st  : unsigned(7 downto 0)  := (others => '0');   -- staged fill_data (= cpuDi_nocache @ fire)
signal rp_fill_addr_st  : unsigned(15 downto 0) := (others => '0');   -- staged fill_addr (matched to data)
signal rp_fill_bank_st  : unsigned(7 downto 0)  := (others => '0');   -- staged fill_bank (matched to data)
signal rp_fill_we_st    : std_logic := '0';                          -- staged fill we (M10K write @ fire+2)
signal rp_fill_arm      : std_logic := '0';                          -- stage-1 arm: re-capture settled data @ fire+1
-- iter-24: final fill-port selects (staged tuple vs the existing direct path).
signal rp_fill_data_sel : unsigned(7 downto 0)  := (others => '0');
signal rp_fill_we_sel   : std_logic := '0';
signal rp_fill_addr_sel2 : unsigned(15 downto 0) := (others => '0');
signal rp_fill_bank_sel2 : unsigned(7 downto 0)  := (others => '0');

-- iter-15 (2026-06-02): enable the same-line 2x alt-fire single gap-gated scheduler.
-- Requires CACHE_READ_PATH=true (the read path supplies rp_same_line/rp_cache_hit).
-- When false, enableCpu <= cpu_cyc_s(1) exactly as shipped (RBF bit-identical). When
-- true AND supercpu_en, a single registered scheduler owns enableCpu: SLOW mode (bank
-- $00 / I/O / throttle, scpu_fast_path=0) emits the baseline cpu_cyc_s(1) main pulse
-- guarded by en_gap>=3 (bit-identical to baseline in steady slow, the guard only
-- suppresses a too-soon main right after a fast); FAST mode (SuperRAM, scpu_fast_path=1,
-- not throttled, not dma) runs a uniform even-CPU-slot gap scheduler: main at en_gap>=3
-- (4-apart = proven SDRAM window), fast 2-apart at en_gap>=1 + LIVE rp_same_line +
-- LIVE rp_cache_hit + baLoc + cpu816_rdy (stall-safe). Off-device proof:
-- cpu_cache_sched_phasing_tb (LIVE gate PASS warm+cold, _d1 FAIL). HW-GATED until
-- boot+Lorenz+Doom+Wolf3D+speed confirmed.
constant ALT_FIRE_SAMELINE : boolean := false;  -- iter-17 ISOLATION build C: alt OFF to make a SINGLE-variable test vs known-crash 38118b68 (data ON, alt OFF, hit_pred ON). Now data ON, alt OFF, hit_pred OFF => isolates whether the hit_pred grant is the 4-apart Doom corruptor. iter-15b PARTITION (2026-06-02): SuperRAM-only caching did NOT fix the $0D67/$AB loader freeze (bank-$00 caching ruled OUT). Remaining suspects with bank $00 uncached: (A) alt-fire 2x cadence disrupting the loader's SuperRAM transfer, or (B) SuperRAM cache DATA staleness. This build = cache-on (SuperRAM-only) + alt OFF (4-apart). If Doom runs -> (A) alt-fire; if it still wedges at $0D67 -> (B) SuperRAM data. Revert to true once partitioned. iter-16: (B) ROOT-CAUSED as the fill-tuple skew; FILL_TXMATCH below is the fix — keep alt OFF for the first fix build to isolate read-coherency from the speedup.

-- iter-27 (2026-06-09): INTERNAL-CYCLE FAST-FIRE speed lever. The CPU spends
-- ~22.6% of its cycles on INTERNAL operations (VDA=0 and VPA=0 -- RMW modify,
-- decimal correct, taken-branch IO, transfers, NOP, REP/SEP, XBA, stack/ctrl
-- IO). On an internal cycle the W65C816 makes NO valid memory access, so the
-- data bus is don't-care -- PROVEN by the SST garbage-injection sweep (force
-- D_IN garbage whenever VDA=VPA=0 -> 0 fail across all 256 opcodes x emu/native
-- = 5.12M cases; see sim/p65c816_singlesteptest, -GarbageInternal). Because an
-- internal cycle reads no SDRAM, it can advance the CPU 2-apart (next even CPU
-- slot, en_gap>=2) WITHOUT waiting for the 4-clk32 SDRAM window -- a fundamentally
-- DIFFERENT class from the dead cache/alt-fire levers, which all raced SDRAM data
-- delivery. This change:
--   * adds NO new data-capturing register (unlike the Bug-2 cache fill FF),
--   * reads NO SDRAM on the fast cycle (so no stale-latch class),
--   * respects `set_multicycle_path -setup 2 -to *P65C816*` (C64.sdc:44) by
--     firing only on even slots with en_gap>=2 (>=2 clk32 between fires); the
--     CPU-internal reg->ALU->reg paths close at setup-2 (+23.6ns, iter-19 STA),
--   * leaves every MEMORY cycle on the proven main path (cpu_cyc prefetch +
--     cpu_cyc_s(1) consume = full SDRAM window), so no memory access is shortened.
-- Expected throughput gain ~+12-15% (22.6% of cycles at 2x). Default false =>
-- enableCpu <= cpu_cyc_s(1) exactly as shipped (RBF bit-identical).
--
-- iter-27 v2 (Codex falsification #1 ADDRESSED): the dangling-MAIN hazard is
-- removed by VDA/VPA-gating cpu_cyc itself. When INTERNAL_FAST_FIRE, cpu_cyc is
-- additionally qualified by (vda_816 or vpa_816) (cpu_cyc_va_ok, near the cpu_cyc
-- assignment) so an INTERNAL cycle issues NO prefetch and NO pending cpu_cyc_s(1)
-- MAIN pulse — it is advanced ONLY by the fast-internal scheduler branch. Memory
-- cycles (VDA or VPA = 1) keep the full prefetch+consume SDRAM window unchanged.
-- When the constant is false, cpu_cyc_va_ok folds to '1' => cpu_cyc and the
-- scheduler are bit-identical to the shipped arbiter (RBF bit-identical).
--
-- ⚠ STILL GATED false / NOT YET HW-BUILT. Two residual Codex risks need a SYSTEM
-- bench (c64_reduced_harness + faithful clk64_sdram_model — a zero-delay bench
-- cannot see prefetch/consume desync, the Bug-2 lesson) before any HW build:
--   (#2 PHASE) confirm vda_816/vpa_816 sampled at the enableCpu decision edge are
--      the PENDING cycle's flags, not the just-completed cycle's (en_gap>=2 gives
--      settle time; Codex rates this "unlikely" but it is the #1 thing to assert).
--   (#3 CLASSIFY) assert NO cpu_cyc / cpu_cyc_s(1) pulse is ever generated while
--      VDA=VPA=0, and final machine state + instruction-retire count match the
--      INTERNAL_FAST_FIRE=false baseline bit-for-bit (only the cycle count drops).
-- Semantic precondition (D_IN unused on internal cycles) is PROVEN (5.12M SST
-- garbage sweep, committed 2c34007).
constant INTERNAL_FAST_FIRE : boolean := false;  -- iter-27 HW-DEAD (2026-06-09): build 0675f71e (this constant=true) WEDGED on HW —
-- black screen, CPU hard-pinned at PC:$EE97 (KERNAL IEC region), never reached READY. Control: the iter-26 shipped
-- RBF 3698680a deployed to the SAME MiSTer in the SAME session booted clean (SCPU64 V0.07 / READY, PC cycling the
-- real keyboard-idle loop $E5CD-$E5D6). So the wedge is THIS lever, not the environment. Falsifies the handoff's
-- "different class / no SDRAM-staleness risk" hope: fast-firing internal cycles 2-apart still advances the CPU's
-- phase ahead of the ~4-clk32 SDRAM read cadence, so the FOLLOWING memory fetch races SDRAM latency = the same
-- setup-time/phase class that killed every cache lever (Bug 2). Bench-clean (zero-delay system bench bit-identical
-- 178->0, ~8% faster) + SST 0/5.12M semantics + Codex logic-clean all PASSED yet HW wedges — exactly the class a
-- zero-delay bench cannot reproduce. Kept gated false (RBF bit-identical to shipped) as the record; bench +
-- garbage-sweep harness retained. Do NOT re-enable without a latency-faithful KERNAL-boot bench that reproduces it.

-- iter-28 (2026-06-09 analysis / 2026-06-13 FALSIFIED): MILESTONE C demand arbiter
-- @ clk32. Adds busy-gated cpu_cyc terms at the intermediate CPU-region slots
-- (CPU1/2/3/5/6/7/9/A/B), gated identically to the baseline RAM terms and kept
-- INSIDE the sdram_busy='0' gate, intending to raise the 4 MHz floor (cpu_cyc only
-- at CPU0/4/8/C) to ~5 MHz.
--
-- VERDICT: **INERT — this lever adds ZERO fires.** The original GOAL-A premise
-- ("busy_cnt='011' ALREADY permits a 3-clk32 cadence; only the slot positions stop
-- it") is WRONG. "011" with the static decrement (3786-3791: 011->010->001->000)
-- clears sdram_busy only at N+4, so after any cs_ram fire at slot N, sdram_busy='1'
-- through N+1..N+3 — and every demand slot requires cs_ram='1', so it is ALWAYS
-- busy-blocked within that window. "011" is therefore a 4-apart FLOOR, not a
-- 3-apart permit. The sdram_ready early-clear (3787) cannot help: on HW the V6
-- 6-clk64 MISS access + 2-FF ready sync makes the ready rising-edge visible in
-- clk32 only at ~N+5, strictly later than the static N+4.
--
-- PROOF (sim, 2026-06-13): c64_reduced_harness run_internal_fastfire.sh, three
-- configs — DEMAND=0 / DEMAND=1 / DEMAND=1+NOEARLYCLEAR — are BYTE-IDENTICAL
-- (cpu_cyc_fires=7640, ticks_to_op2000=68776, witnesses $AA/$4A/$4A/$EE). Disabling
-- the early-clear (NOEARLYCLEAR, patch#10) changes nothing => the early-clear is
-- redundant and the static-decrement 4-apart floor governs. The instrumentation's
-- "min_cyc_gap=3" counts IDLE holes between fires (since_cyc increments only when
-- cpu_cyc=0), so gap=3 = a 4-apart cadence = the documented 4 MHz floor, NOT
-- 3-apart. (A 2026-06-09 note misread gap=3 as "3-apart over-firing"; corrected.)
--
-- To actually reach a 3-apart cs_ram cadence requires reducing the reservation to
-- "010" (clears at N+3). That puts the SDRAM ce-edge spacing at exactly 6 clk64 =
-- the V6 throughput floor with ZERO slack: the clk32->clk64 cpu_cyc->ce strobe sync
-- (C64.sdc:82-90, a real 3-FF synchronizer => +/-1 clk64 capture uncertainty) can
-- then land the 2nd ce-edge at q=5 (mid-sample) => FSM restart => corruption = the
-- same setup/phase-race class as the 6 HW-dead levers. So "010" is NOT safe either.
-- The only sound throughput lever is a page-mode SDRAM controller (open-row
-- back-to-back column reads, no 6-clk64 spacing requirement) — the deferred Build-A
-- rewrite that wedged at PC=$0D62. See memory project_demand_arbiter_inert_zerodelay.
--
-- Kept as a gated dead-lever record (default false => Quartus constant-folds the
-- demand term away; cpu_cyc + RBF bit-identical to shipped 3698680a). Do NOT build.
constant DEMAND_ARBITER : boolean := false;  -- iter-28: HW-INERT (busy-blocked); dead record

-- iter-31 (2026-06-14) STEP 6: authoritative bank-$00 BRAM fast-fire. Builds on the
-- HW-validated step-2 BRAM (c64.sv, commit 36a8d12). Fast-fire ONLY bank-$00 READS
-- 2-apart (data from the on-chip BRAM = ~1 clk64 MATCHED latency, NOT the ~5 clk64
-- SDRAM that made the 6 dead levers race the di setup window). Bank-$00 WRITES + all
-- SuperRAM stay on the 4-apart cpu_cyc MAIN path (preserves the BRAM write strobe via
-- ramCE->cart_ce->sdram_eff_ce AND the fixed cpu_cyc->cpu_cyc_s(1) 2-clk32 SDRAM
-- window for every SuperRAM access). Codex-vetted v3
-- (tools/codex-out/bank00-fastfire-step6-v3-review.txt): the classifier MUST qualify
-- (vda_816 or vpa_816) — an internal cycle (VDA=VPA=0, stale bank-$00 addr, cpuWe=0)
-- would otherwise be misclassified as a fast read = the dead internal-fast-fire lever.
-- Default false => RBF-identical (b00_fast_read folds to '0', cpu_cyc/enableCpu
-- bit-identical to the shipped arbiter).
constant BANK00_FASTFIRE : boolean := true;   -- shipped (4c9cd300): iter-31 step 6 bank-$00 k=2 fast-fire. (Kicks-intro flicker A/B FALSIFIED cadence-as-cause: uniform 4-apart flickers identically.)

-- 2026-06-19: BADLINE-AWARE bank-$00 fast read (Kicks-intro flicker COMPAT lever).
-- A real SuperCPU executes from its own SRAM and does NOT stall on C64 VIC badlines
-- (it is off the C64 bus; it only syncs to 1 MHz for actual bus/I-O accesses). Our
-- shipped fast path requires baLoc='1' (FAST branch below), so our bank-$00 execution
-- STALLS every badline = unlike real HW = a jitter source for cycle-timed raster
-- effects (SCPU-Kicks DMAGIC intro overlay flickers). A bank-$00 BRAM fast READ touches
-- NO bus (data from on-chip bram_q), so it can safely advance through a badline. When
-- true, the FAST branch drops the baLoc='1' requirement FOR BANK-$00 FAST READS ONLY
-- (b00_fast_read='1'); writes/SuperRAM/I-O stay baLoc/cpu_cyc-gated as before. Slot set
-- is UNCHANGED (even CPU slots CPU0..CPUC) so CPU SDRAM accesses stay slot-separated
-- from VIC fetches; only the per-badline stall is removed. Default false => RBF-identical
-- (folds to the shipped baLoc-gated FAST branch). GHDL-prove arbiter-safe
-- (no spurious cpu_cyc, no sdram_busy_cnt disturbance, no fast fire in a VIC slot)
-- BEFORE any HW build. Visual flicker + badline fidelity need ONE HW build to confirm.
constant BANK00_BADLINE_FAST : boolean := false;  -- HW-FALSIFIED 2026-06-19 (build de147ffc): made the Kicks intro flicker WORSE ("really bad" — garbled logo + more all-black frames). Advancing bank-$00 code through badlines DESYNCS the CPU from the VIC raster, moving each cycle-timed $D021 bar write to a more-wrong raster position. The badline stall was partly keeping us CLOSER to raster sync, not adding jitter. Do NOT re-enable.

-- iter-16 (2026-06-03): transaction-matched fill tuple — the Bug 2 fix. See the
-- rp_fill_addr_r/rp_fill_bank_r decl above. When true (and CACHE_READ_PATH), the
-- cache fill is tagged with the address captured at SDRAM read-issue instead of the
-- live (combinationally-advanced) cpuAddr. Only meaningful when CACHE_READ_PATH=true.
constant FILL_TXMATCH : boolean := false;  -- iter-17b DIAG: test whether the LIVE-cpuAddr fill (=false, sampled at the SAME consume edge as cpuDi_nocache => matched pair, the Build-D-correct argument) gives WD=0, vs the iter-16 read-issue capture (=true) which gave WD=FFFF (content widely wrong). RESTORE per outcome.

-- iter-18 (2026-06-03): Bug 2 ROOT-CAUSE fix — gate the SuperRAM cache fill on the
-- SDRAM data-valid handshake. ROOT CAUSE (HW divergence-detector WD=FFFF, $2000C5
-- cache=$03 vs SDRAM=$40; + RTL + Codex; + GHDL cpu_cache_filldata_phase_tb
-- BUGGY=64/FIXED=0): the fill FF latches cpuDi_nocache (= ramDin = sdram_pm dout_r)
-- at enableCpu_816 (= cpu_cyc_s(1) = launch+2 clk32), but dout_r is FRESH only at q=5
-- (~launch+3). So the immediate fill captures the PREVIOUS read's byte = stale; the
-- CPU itself reads correctly because C64.sdc `set_multicycle_path -setup 2/4
-- -to *P65C816*` lets its capture FF settle ~4 clk32 late (after q=5) — the fill FF
-- has no such relief. That asymmetry is why Build-D RUNS (CPU-only) while cache content
-- is wrong, and why golden-data benches never caught it. FIX: at a miss consume latch a
-- pending request + the matched addr/bank, then fire the cache fill_we when
-- sdram_data_valid_sync is high (dout_r fresh = THIS access's byte, asserted ~launch+4,
-- before the next read's ce-edge clears it) sampling LIVE cpuDi_nocache. When false, the
-- legacy immediate fill. Only meaningful when CACHE_READ_PATH=true.
constant FILL_DATAVALID_GATE : boolean := true;

-- iter-22 (2026-06-04): Bug 2 second-race fix — CANCEL an in-flight SuperRAM
-- fill when a CPU write targets its pending address. ROOT CAUSE (iter-18 HW
-- divergence detector residual: bank $20 $00AE cache=$00 vs SDRAM=$4A, the
-- pre-write EMPTY value cached over the loader's written byte; + GHDL
-- cpu_cache_fill_invalidate_race_tb BUG=1/FIX=0): a CPU read MISSES a not-yet
-- -filled SuperRAM line, launching an SDRAM fill that carries the byte sampled
-- at read-issue (= the pre-transfer $00). Before that delayed fill fires, the
-- Doom loader long-stores the real byte ($4A) to the same address. The cache's
-- invalidate_wr (cpu_we) is a NO-OP because the line is not yet tagged for that
-- address (the fill has not allocated it) -> tag_match=0. The in-flight fill
-- then lands and ALLOCATES the line with the stale $00, valid=1, never
-- invalidated -> every later read HITs $00. The cache cannot fix this (nothing
-- to invalidate at write time), so cancel the PENDING FILL here: clear
-- rp_fill_req when cpuWe matches the latched rp_fill_addr_dly/rp_fill_bank_dly.
-- The line then stays unallocated -> the re-read misses -> SDRAM path returns
-- the correct (post-write) byte and a fresh fill caches it. Cancelling on a
-- match is safe by construction (a spurious cancel only costs a re-fetch).
-- Only meaningful with FILL_DATAVALID_GATE (the delayed-fill pending window).
constant FILL_CANCEL_ON_WRITE : boolean := true;

-- iter-24 (2026-06-05): Bug 2 SETUP-TIME fix — matched-tuple STAGED FILL.
-- The dual-clock GHDL harness (sim/c64_reduced_harness, CLK64_SDRAM=1) proved
-- Bug 2 is a setup-time ASYMMETRY, not a functional ordering bug: the direct
-- fill (fill_data => cpuDi_nocache) drives the deep dout_r->mux path (~26ns)
-- ACROSS the cpu_cache port boundary into the M10K write (with its own setup),
-- and that combined path does not settle within the ~1 clk32 functionally
-- available at rp_fill_fire — while the P65C816 di-capture FF gets the
-- C64.sdc `-setup 2/4 -to *P65C816*` relief the fill FF has no equivalent of.
-- In zero-delay sim both FFs latch the same value on the same edge, so no
-- bench (unit/system/single-/dual-clock) can reproduce it (see
-- project_bug2_setup_time_class; explains the four prior HW no-ops).
-- FIX (Codex-vetted, robust 3-stage): give the deep mux the FULL 2 clk32 the
-- multicycle promises by RE-capturing the data one clk32 AFTER fire (a capture
-- AT fire samples the mux on the same edge the direct M10K did = no settling
-- gain, only endpoint shortening). Stage 1 @fire latches addr/bank + provisional
-- data + arms; stage 2 @fire+1 re-captures the now-settled cpuDi_nocache when the
-- CPU is still on this access (passthrough holds cpuAddr stable, iter-16) and
-- emits fill_we; the M10K writes reg->reg at fire+2. Fire-edge + gap-cycle write
-- cancels (Codex); an fire+2 write is caught by cpu_cache's cpu_wr_pending>fill
-- priority. See stage_fill_proc. Default FALSE => staged regs pruned =>
-- bit-identical shipped. Validation is STA + HW, NOT GHDL (zero-delay sim cannot
-- model the asymmetry). Only meaningful with CACHE_READ_PATH and FILL_DATAVALID_GATE.
constant FILL_STAGED_TUPLE : boolean := false;

-- iter-7 (2026-05-30): RDY-handshake gate for the cache-HIT alt-slot (the
-- cadence-correctness half — the STA gate cleared the data-path-timing half).
-- When RDY_HANDSHAKE, AND `data_ready` onto the 816 rdy port (:~3092) so a CPU
-- READ that goes through SDRAM (cs_ram='1') stalls until either the read-path
-- cache HITs (rp_cache_hit) or the SDRAM controller reports its dout fresh
-- (sdram_data_valid_sync). Non-SDRAM reads (I/O/ROM/color, cs_ram='0') and
-- writes (rdy_gated forces RDY=1 on writes inside cpu_65c816) are never stalled.
-- This makes speculative alt_fire_r2 CE pulses safe: a miss just holds RDY low
-- until data arrives, so the CPU never latches stale SDRAM (the documented
-- alt-slot Doom-wedge class). DEFAULT FALSE => data_ready forced '1' =>
-- `rdy <= baLoc and cpu816_rdy_to_cpu and '1'` = bit-identical to shipped.
-- GHDL-prove the stall-on-miss behaviour (sim/scpu_async_bridge_tb/
-- cpu_in_bridge_superram_tb) BEFORE flipping this true + enabling alt_fire_r2.
constant RDY_HANDSHAKE : boolean := false;  -- committed default false. Build-1 (true, +CACHE_READ_PATH true, alt_fire OFF) HW-FALSIFIED 2026-05-31: boot WEDGED, PC frozen $00FCE5 in KERNAL reset. Gating the live 816 rdy on data_ready/sdram_data_valid_sync stalls the CPU forever — sdram_data_valid_sync does NOT track per-access read-readiness against the real sdram_pm. NOTE: Build-1 enabled BOTH flags → wedge not isolated to RDY_HANDSHAKE alone; needs a cache-only (CACHE_READ_PATH=true, RDY_HANDSHAKE=false) HW build to clear CACHE_READ_PATH.
signal data_ready    : std_logic := '1';  -- inert default => rdy unchanged

signal vSync_sig     : std_logic := '0';
signal vSync_prev_r  : std_logic := '0';
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
		irq_n         : out std_logic;
		dbg_imr       : out std_logic_vector(4 downto 0);
		dbg_cra       : out std_logic_vector(7 downto 0);
		-- Option G (2026-05-25): CIA port + DDR taps for IEC phantom-write probe
		dbg_pra       : out std_logic_vector(7 downto 0);
		dbg_prb       : out std_logic_vector(7 downto 0);
		dbg_ddra      : out std_logic_vector(7 downto 0);
		dbg_ddrb      : out std_logic_vector(7 downto 0);
		-- mb-probe-003 (2026-05-26): Timer A + ICR internal state
		dbg_timer_a       : out std_logic_vector(15 downto 0);
		dbg_timer_a_latch : out std_logic_vector(15 downto 0);
		dbg_icr           : out std_logic_vector(4 downto 0)
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

-- v13g (2026-05-25): 1-cycle delayed vpa/vda for the CIA2 write gate.
-- The combinational cia2_write_safe widens the "safe to write" window
-- by 1 clk_sys cycle on each side of the vpa/vda transitions, so CIA2
-- IEC edge-timing-critical writes don't fall on the gate's edges.
-- Between bridge requests (vpa/vda low for many cycles), the gate
-- still blocks phantom writes — a 1-cycle widening is far smaller
-- than the inter-request gap.
process(clk32) begin
	if rising_edge(clk32) then
		vpa_816_d1 <= vpa_816;
		vda_816_d1 <= vda_816;
	end if;
end process;

cia2_write_safe <= vpa_816 or vda_816 or vpa_816_d1 or vda_816_d1;

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
	supercpu_bank    => std_logic_vector(addr_hi_816),
	scpu_native_mode => not emu_mode_816_i,
	-- Phase 3: bootmap intercept at bank $00:$E000-$FFFF
	scpu_bootmap     => scpu_bootmap
);

IOE <= ioe_i;
IOF <= iof_i;
cs_io <= cs_vic or cs_sid or cs_color or cs_cia1 or cs_cia2 or ioe_i or iof_i;

-- ----------------------------------------------------------------------
-- Phase 1: IOF falling-edge pulse + latched cpu inputs for reu.v.
-- Ported from master fpga64_sid_iec.vhd:903-937.
--
-- Why: vanilla-cpu-swap's c64.sv wires reu.v's cpu_cs directly to raw
-- IOF. In turbo/SCPU mode, the CPU's STA $DFxx write cycle is only
-- ~1 clk32 long — by the time IOF rises, cpuWe_pre has already
-- dropped, causing REU to misclassify the write as a read. Same
-- problem for reads: the access ends before REU's edge detector
-- registers it.
--
-- Fix: capture cpuWe_pre / cpuAddr_pre / cpuDo_pre into latches while
-- iof_detect is asserted, then fire iof_fall_pulse_r as a 1-cycle pulse
-- at the cycle iof_detect drops. By that cycle the latches hold the
-- LAST observed values during the access. reu.v sees a clean rising
-- edge on cpu_cs with cpu_we settled to 1 for writes / 0 for reads.
iof_detect <= '1' when cpuAddr_pre(15 downto 8) = x"DF" and addr_hi_816 = x"00" else '0';

process(clk32)
begin
    if rising_edge(clk32) then
        iof_detect_d2    <= iof_detect;
        iof_fall_pulse_r <= iof_detect_d2 and not iof_detect;  -- 1-cycle pulse at end of access
        if iof_detect = '1' then
            iof_we_r   <= cpuWe_pre;
            iof_addr_r <= cpuAddr_pre;
            iof_dout_r <= cpuDo_pre;
        end if;
    end if;
end process;

iof_we_o         <= iof_we_r;
iof_addr_o       <= iof_addr_r;
iof_dout_o       <= iof_dout_r;
iof_fall_pulse_o <= iof_fall_pulse_r;

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
--                 Phase 7 note: master repurposes $D078 as a cache-flush
--                 write port; vanilla-cpu-swap has no cache infrastructure
--                 so $D078 is already CMD-spec-compliant (read-only $00,
--                 writes no-op via fallthrough). No move-to-$D0BD needed.
--                 Bootmap-ROM coverage: bank $00:$E000-$FFFF overlay
--                 (Phase 3) + bank $F8 dprom (v298) match CMD HW; we
--                 deliberately leave banks $F0-$F7 / $F9-$FF returning
--                 the $6B-RTL trap stub so Doom's recompiler-emitted
--                 JSLs into empty banks remain detectable (changing
--                 these to EPROM mirror could mask the underlying bug).
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
--
-- 2026-05-29 COMPAT FIX: these $D0Bx/$D07E status-register read clauses
-- formerly used the `cs_vic='1' AND cpuAddr(11:0)=x"0Bx"` form, which is
-- DEAD on the 65C816 path (cs_vic deasserts before the cpuDi sample edge in
-- the bridge/turbo path — proven by probe_d27.prg on v347: every $D0Bx read
-- returned $FF / VIC-mirror garbage). They now use the 16-bit `cpuAddr_816`
-- compare — the same bridge-latched-address mechanism the $D27x SIMM and
-- $FFEx native-vector clauses below use, which IS hardware-proven to fire
-- (RBF 0a8490a5, memory bug3_outer_mux_actually_works). Headline effect:
-- $D0B0 SuperCPU presence-detect ($40) and $D0B2/$D0B4/$D0B5/$D0B6/$D0B8/
-- $D0BC status now read correctly, so external SCPU-aware software that
-- probes them (e.g. detect-then-accelerate libraries) sees a real SuperCPU
-- instead of open bus. Policy gates (scpu_regs_enabled) are unchanged.
-- ----------------------------------------------------------------------
-- iter-7d: read-path HIT override now uses the REGISTERED hit/di (rp_cache_*_d1)
-- so the masked single-cycle cache->P65C816 path is split by a pipeline register
-- (see decl ~:1581). The non-override base is factored into cpuDi_nocache below;
-- the cache fills from cpuDi_nocache (NOT cpuDi) so this override can never feed
-- back into a fill. CACHE_READ_PATH=false => the term is constant-false => cpuDi
-- collapses to cpuDi_nocache (bit-identical to shipped). rp_cache_hit_d1='0' when
-- off => inert. cache excludes $Dxxx so SCPU regs below are never shadowed.
cpuDi <= rp_cache_di_d1
            when (CACHE_READ_PATH and CACHE_DATA_OVERRIDE and rp_cache_hit_d1 = '1') else
         cpuDi_nocache;

cpuDi_nocache <=
         scpu_dos_ext_mode
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0BC" and scpu_regs_enabled = '1') else
         x"40"
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0B0" and scpu_regs_enabled = '1') else
         (scpu_hwenable & scpu_sys_1mhz & "000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0B2" and scpu_regs_enabled = '1') else
         (scpu_speed_1mhz & (scpu_speed_1mhz or scpu_sys_1mhz) & "000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0B8" and scpu_regs_enabled = '1') else
         ("000000" & scpu_optim_mode)
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0B4" and scpu_regs_enabled = '1') else
         x"00"
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0B3" and scpu_regs_enabled = '1') else
         x"00"
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D078" and scpu_regs_enabled = '1') else
         ("0" & scpu_speed_1mhz & "000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0B5" and scpu_regs_enabled = '1') else
         (emu_mode_816_i & "0000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D0B6" and scpu_regs_enabled = '1') else
         (scpu_rom_vis & "0000000")
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D07E") else
         -- ----------------------------------------------------------------
         -- SuperRAM extent variables ($D27C-$D27F) — User Guide spec.
         -- Real CMD SuperCPU firmware writes these into the $D200-$D3FF
         -- 512-byte SCPU sysram during boot so software can read the
         -- installed-RAM extent. AmiDog's MIPS-recompiler runtime
         -- plausibly polls these to size its Z_Malloc heap; all-zeros
         -- signals "no expansion installed" and may scope allocation
         -- to bank $00 only (breaks Doom/Wolf3D).
         --
         -- This branch removed the $D200-$D3FF SCPU sysram (Phase C
         -- decision: dprom disturbs vanilla fitter), so $D2xx reads
         -- currently fall through to VIC-mirror garbage. We restore
         -- spec compliance for these 4 specific bytes via the read mux.
         --
         --   $D27C = first available page low byte    = $00
         --   $D27D = bank of first available page     = $02 (SuperRAM start)
         --   $D27E = last available page+1 low byte   = $00
         --   $D27F = bank of last available page+1    = $F6 (= $F5 + 1)
         --
         -- Intentionally NOT gated on scpu_regs_enabled — real HW SRAM
         -- is permanently present, not subject to $D07E hwenable.
         -- Bug 3 (firmware_correctness_plan.md Stage 1): writable.
         -- Kickstart's STZ at $F8:$81EB-$81F0 updates these; the prior
         -- hardcoded read constants ignored those writes. The 16-bit
         -- `cpuAddr_816` compare (vs `cs_vic + cpuAddr(11:0)`) matches
         -- the working pattern used by the native-vector intercepts
         -- below. The $D0Bx status clauses ABOVE were converted to this
         -- same `cpuAddr_816` mechanism on 2026-05-29 (they previously used
         -- the dead cs_vic form — memory cs_vic_gated_scpu_reg_reads_are_dead).
         -- Empirically verified by the bridge-side data-latch diagnostic
         -- in RBF md5 0a8490a5 (commit 81af800f91-dirty): kickstart's
         -- $F8:$8116 SBC $D27D read sees bus_di_in = $02 at the ack
         -- edge — i.e. these clauses fire. See memory
         -- bug3_outer_mux_actually_works.
         scpu_simm_27c
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D27C") else
         scpu_simm_27d
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D27D") else
         scpu_simm_27e
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D27E") else
         scpu_simm_27f
            when (supercpu_en = '1' and addr_hi_816 = x"00" and cpuAddr_816 = x"D27F") else
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
         -- Phase 3 — native vectors $FFE4..$FFEF served from writable
         -- scpu_native_vec array. Reset defaults match the old hardcoded
         -- pattern (all vectors → $00:$FF00). The EPROM kickstart writes
         -- real handler addresses here during cold boot, replacing the
         -- defaults with pointers into the RAM kernel at $00:$801A-$8054.
         -- After EPROM runs, native BRK/COP/ABORT/NMI/IRQ dispatch goes
         -- to the real CMD handlers instead of our synthesized ack stub.
         -- scpu_nmi_vec_lo/hi (legacy NMI capture from $FFEA/EB) is
         -- superseded by scpu_native_vec(6/7) — kept in the write logic
         -- for backwards compat but no longer read here.
         scpu_native_vec(0)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE4") else  -- COP   L
         scpu_native_vec(1)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE5") else  -- COP   H
         -- v311 doom wedge: BRK vector hardcoded to $00:$FF00 regardless
         -- of whatever software installs at $00:$FFE6/$FFE7. v310 found
         -- Doom dynamically rewrites the BRK vector to $XX05 inside the
         -- JIT scratchpad ($0705 then $0B05 …); each $XX05 byte is $00
         -- (register-spill data, not a handler) which creates an
         -- infinite BRK→vector→$XX05→BRK self-loop. Forcing the vector
         -- to $FF00 sends BRK to our ack-stub (PHP/SEP/PHA/4×ack/PLA/
         -- PLP/RTI) which returns to wherever BRK was pushed from,
         -- letting Doom continue. Native-mode + bank-$00 gate keeps the
         -- override invisible to T65 / emu mode / other banks.
         x"00"  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE6") else  -- BRK   L → forced $00
         x"FF"  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE7") else  -- BRK   H → forced $FF
         scpu_native_vec(4)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE8") else  -- ABORT L
         scpu_native_vec(5)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFE9") else  -- ABORT H
         scpu_native_vec(6)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEA") else  -- NMI   L
         scpu_native_vec(7)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEB") else  -- NMI   H
         scpu_native_vec(8)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEC") else  -- unused L
         scpu_native_vec(9)  when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFED") else  -- unused H
         -- v340e (2026-05-13): IRQ vector now follows software writes via
         -- scpu_native_vec(10/11). Was hardcoded to $00FF in v312 to route
         -- IRQ to our $FF00 ack stub — that was a paranoia workaround for
         -- the prior IRQ-refire wedge whose actual root cause was the I/O
         -- decode bug (commit b2d44d1). With that fixed, Doom installs its
         -- own handler at $0D3C (`8D EE FF ... 8D EF FF` at $0DAC area) and
         -- the cooperative dispatch chain needs IRQ to actually reach
         -- $0D3C → JMP ($1D00) → $0D6C → STA $1D02 = $1D04 ack. Returning
         -- $00FF here trapped IRQ in the $FF00 ack-only stub and never
         -- woke the consumer at $0EED. Reset default is still $00FF so
         -- pre-init IRQs (before software writes the vector) still land
         -- on the ack stub harmlessly.
         -- v340m: hardcode IRQ vector back to $00:$FF00 (our ack stub).
         -- v340e let this follow software writes so Doom's $0D40 ran
         -- directly, but v340j/l proved CPU aborts ORA at $0F:$F1DA after
         -- opcode fetch — IRQ source must be persistently asserted because
         -- Doom's handler doesn't ack the hardware sources properly. By
         -- routing IRQ through our stub first (acks all sources), then
         -- JML $00:$0D40 (Doom's handler still runs its SW ack), both
         -- conditions are satisfied. Doom's writes to $FFEE/$FFEF still
         -- go to scpu_native_vec storage but are ignored on read.
         -- v356 (2026-05-19): force $FFEE/$FFEF reads back to $00/$FF so
         -- IRQ ALWAYS routes through the $FF00 ack stub. The stub-tail
         -- JML (at $FF2A-$FF2D) then jumps to scpu_native_vec(10/11) IF
         -- software installed (scpu_irq_vec_installed='1'), else falls
         -- back to Doom's hardcoded $0D3C. This combines v340m (all hw
         -- sources acked) with v351 (Wolf3D's own handler runs). v351's
         -- direct-vector path was bypassing our hw ack, leaving CIA1
         -- timer-A / sprite-collision / REU IRQ pending after Wolf3D's
         -- handler RTI → IRQ refire wedge at $0F:$A63C.
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEE") else  -- IRQ L = $00 (route to $FF00 stub)
         x"FF" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FFEF") else  -- IRQ H = $FF
         -- ----------------------------------------------------------------
         -- IRQ JML trampoline at $00:$FCEE..$FCF1 (4 bytes, RAM-backed).
         --
         -- Default (scpu_irq_tramp_installed = '0'): synthesized as
         --   JML $00:$FF00 (5C 00 FF 00) → our ack stub at $FF00.
         -- Once software writes any byte in $FCEE-$FCF1, the latch flips
         -- to '1' and reads thereafter return whatever software has put
         -- in RAM (i.e. its own JML target).
         --
         -- Software install pattern (typical):
         --   SEI                  ; mask IRQs while patching
         --   LDA #$5C : STA $FCEE ; JML opcode (sets latch)
         --   LDA #lo  : STA $FCEF
         --   LDA #mid : STA $FCF0
         --   LDA #hi  : STA $FCF1
         --   CLI
         --
         -- After install, on every IRQ:
         --   $FFEE/EF returns $EE/$FC → CPU jumps to $00:$FCEE
         --   $00:$FCEE..$FCF1 reads return user's JML (software-RAM)
         --   CPU executes JML to user handler
         --   User handler does its own ack + RTI
         -- emu_mode_816_i='0' gate is mandatory: in emu mode the KERNAL
         -- ROM at $FCEE-$FCF1 contains real code (`$FD 20 5B FF` =
         -- operand-high of JSR $FD15, then JSR $FF5B). Overriding it
         -- corrupts KERNAL cold-start init and hangs the C64. Trampoline
         -- only matters in native mode anyway (native IRQ vector points
         -- here), so emu-mode invisible is correct.
         x"5C" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FCEE" and scpu_irq_tramp_installed = '0') else  -- JML opcode
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FCEF" and scpu_irq_tramp_installed = '0') else  -- target L = $00
         x"FF" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FCF0" and scpu_irq_tramp_installed = '0') else  -- target M = $FF
         x"00" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"FCF1" and scpu_irq_tramp_installed = '0') else  -- target bank = $00
         -- ----------------------------------------------------------------
         -- IRQ ack stub at $00:$FF00..$FF1A (replaces bare RTI sink).
         --
         -- Real CMD SuperCPU EPROM ($F0-$FF) contains IRQ handler stubs
         -- at $00:$8000+ reached via JML trampolines at $00:$FCxx, themselves
         -- reached via the native vectors at $00:$FFE4..$FFEF. Those handlers
         -- ack the IRQ source ($D019 for VIC, $DC0D/$DD0D for CIA1/CIA2)
         -- before RTI. We have neither the EPROM nor the OS image, so the
         -- previous v285 RTI-only sink left IRQ sources un-acked, causing
         -- IRQ storms (every cycle: vector→$FF00→RTI→IRQ refires).
         --
         -- Symptom: Wolf3D wedges with PC pegged at $00:$FF00 + J ring
         -- bouncing through bank $2C functions — IRQ source kept refiring.
         --
         -- IMPORTANT — must use LONG addressing (opcode $AF/$8F):
         -- Wolf3D's IRQs fire with Data Bank = $2B (B:2B in UART). Plain
         -- absolute mode (LDA/STA $D019) would resolve to $2B:$D019,
         -- which is SuperRAM, NOT the VIC chip. Long mode (LDA $00D019)
         -- always targets bank $00 regardless of B.
         --
         -- Likewise SEP #$20 (not #$30) — only force M=1, leave X
         -- alone. Setting X=1 zeroes the upper 8 bits of X/Y per the
         -- W65C816 spec, which would corrupt user index registers.
         --
         -- Sequence (native mode, 27 bytes, balanced stack):
         --   $FF00  08            PHP                ; save P (M bit etc.)
         --   $FF01  E2 20         SEP #$20           ; force M=1 (8-bit A)
         --   $FF03  48            PHA                ; save A (1 byte)
         --   $FF04  AF 19 D0 00   LDA $00D019        ; read VIC IRQ status
         --   $FF08  8F 19 D0 00   STA $00D019        ; ack (write 1s back)
         --   $FF0C  AF 0D DC 00   LDA $00DC0D        ; ack CIA1 (read clears)
         --   $FF10  AF 0D DD 00   LDA $00DD0D        ; ack CIA2 (read clears)
         --   $FF14  AF 00 DF 00   LDA $00DF00        ; v299 — REVERTED to v296
         --                                          ; REU-ack form. Empirical
         --                                          ; finding 2026-05-11: v297
         --                                          ; conclusion "timing only"
         --                                          ; was incomplete. v297/v298
         --                                          ; unstuck the FIRST wedge
         --                                          ; (the BRK loop at $41:$DB93
         --                                          ; — that fix WAS timing) but
         --                                          ; Doom then hits a SECOND
         --                                          ; wedge at $2B:$2292 where
         --                                          ; the recompiler arms a REU
         --                                          ; FETCH whose completion-IRQ
         --                                          ; refires forever because
         --                                          ; the stub didn't read
         --                                          ; $DF00. doom_v298_transition
         --                                          ; _zoom.py captured SP
         --                                          ; leaking $16/vblank then
         --                                          ; wrapping into bank $0F via
         --                                          ; corrupted RTI. Reverting
         --                                          ; restores REU ack so the
         --                                          ; second wedge clears.
         --   $FF18  68            PLA                ; restore A
         --   $FF19  28            PLP                ; restore P
         --   $FF1A  40            RTI
         --
         -- Stack consumption: IRQ entry 4 + PHP 1 + PHA 1 = 6 pushed,
         -- popped same. Native mode only (gated emu_mode_816_i='0').
         -- v313 — emu_mode_816_i gate REMOVED so stub bytes are visible in
         -- both native and emu mode. SP-delta analysis on v311/v312 trace
         -- showed +3 post-RTI (emu semantics) while stub bytes were still
         -- visible, indicating XCE-drop bug desynced the E flag from
         -- emu_mode_816_i output. Making the stub mode-agnostic in SCPU
         -- bank-$00 lets the ack code run regardless of which mode the
         -- CPU thinks it's in.
         x"08" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF00") else  -- PHP
         x"E2" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF01") else  -- SEP imm
         x"20" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF02") else  -- imm = $20 (M=1, X untouched)
         x"48" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF03") else  -- PHA
         x"AF" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF04") else  -- LDA long
         x"19" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF05") else  -- L
         x"D0" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF06") else  -- M
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF07") else  -- bank = $00
         x"8F" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF08") else  -- STA long
         x"19" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF09") else  -- L
         x"D0" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF0A") else  -- M
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF0B") else  -- bank = $00
         x"AF" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF0C") else  -- LDA long
         x"0D" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF0D") else  -- L (CIA1 ICR)
         x"DC" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF0E") else  -- M
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF0F") else  -- bank = $00
         x"AF" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF10") else  -- LDA long
         x"0D" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF11") else  -- L (CIA2 ICR)
         x"DD" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF12") else  -- M
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF13") else  -- bank = $00
         x"AF" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF14") else  -- LDA long
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF15") else  -- L (REU $DF00 — v299 revert)
         x"DF" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF16") else  -- M (REU base)
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF17") else  -- bank = $00
         -- v313 — Extend ack stub: after the four ack reads, hard-disable
         -- the IRQ sources at their mask registers so even un-acked sources
         -- can't keep IRQ_N asserted. Disable sequence ($FF18-$FF27):
         --   $FF18  A9 00         LDA #$00
         --   $FF1A  EA EA EA EA   (was: STA $00D01A — see v340d note below)
         --   $FF1E  A9 7F         LDA #$7F
         --   $FF20  8F 0D DC 00   STA $00DC0D   ; CIA1 ICR (write $7F clears all)
         --   $FF24  8F 0D DD 00   STA $00DD0D   ; CIA2 ICR
         -- Then PLA/PLP/RTI moved to $FF28-$FF2A.
         --
         -- v340e (2026-05-13): NOP out STA $00D01A.
         -- v340k (2026-05-14): REVERTED v340e — restore STA $00D01A=$00.
         -- v342 (2026-05-14): RE-NOP STA $D01A. v341 UART capture proved
         -- Doom now boots through R_Init into main game loop (PC at
         -- $2A:$55xx / $20:DAxx, VW=AC=monotonically equal) but only
         -- 2 IRQs fire in 240s because the mask kill freezes all VIC
         -- IRQs after the first one. Doom's $0EED page-flip consumer
         -- waits forever ($1D02=$00, $1D04=$01 — IRQ handler $0D6C
         -- never runs the cooperative STA $1D02=$1D04 ack). VICE shows
         -- Doom expects $D01A=$F1 to persist across IRQs. With our
         -- stub forwarding to $0D3C (which acks $D019 and advances
         -- $D012), the $D019 write-1-clear path alone is sufficient
         -- to deassert the IRQ line — VW/AC counter equality in v340n
         -- proves the FPGA's IRST clear actually works now. Replace
         -- the 4 STA-long bytes with NOPs ($EA); keep LDA #$00 since
         -- v348 (2026-05-18): NOP the CIA1/CIA2 mask clears at $FF1E-$FF27.
         -- Previously this wrote $7F to $DC0D/$DD0D, which DISABLES all CIA
         -- IRQ enable bits ($7F write to ICR = clear all enables). For Wolf3D
         -- which uses CIA1 timer for frame timing, this kills the timer IRQ
         -- on the first IRQ fired, leaving the game frame-stuck. Doom v342
         -- works without CIA IRQs (uses VIC raster), so it doesn't notice.
         -- The $D019 + $DC0D/$DD0D ack READS at $FF04-$FF13 already clear
         -- pending IRQ sources via write-1-to-clear / read-to-clear. The
         -- mask-disable here was overkill defense from v313 era.
         -- Leaving $FF18/$FF19 (LDA #$00) and $FF1A-$FF1D NOPs intact for
         -- byte layout compatibility.
         x"A9" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF18") else  -- LDA imm (vestigial)
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF19") else  -- #$00
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF1A") else  -- NOP (was STA $D01A, v342)
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF1B") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF1C") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF1D") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF1E") else  -- NOP (was LDA #$7F)
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF1F") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF20") else  -- NOP (was STA $DC0D mask)
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF21") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF22") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF23") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF24") else  -- NOP (was STA $DD0D mask)
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF25") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF26") else  -- NOP
         x"EA" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF27") else  -- NOP
         x"68" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF28") else  -- PLA
         x"28" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF29") else  -- PLP
         -- v356 (2026-05-19): dynamic JML target from scpu_native_vec(10/11)
         -- when software installed (scpu_irq_vec_installed='1'), else
         -- fallback to Doom's hardcoded $0D3C. Combined with $FFEE/$FFEF
         -- forced to $00/$FF (above), this means EVERY IRQ now routes
         -- through our hw-ack stub first, then to the game's installed
         -- handler.
         --   Wolf3D: writes $FFEE/$FFEF=$B5/$B7 → JML $00:$B7B5
         --   Doom: if recompiler writes $FFEE/$FFEF → JML there.
         --         If not, fallback JML $00:$0D3C (v350 behaviour).
         --
         -- Bytes: $5C <lo> <hi> $00 (JML long).
         x"5C" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF2A") else  -- JML long
         scpu_native_vec(10) when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF2B" and scpu_irq_vec_installed = '1') else  -- user IRQ L
         x"3C" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF2B") else  -- Doom fallback LO = $3C
         scpu_native_vec(11) when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF2C" and scpu_irq_vec_installed = '1') else  -- user IRQ H
         x"0D" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF2C") else  -- Doom fallback MID = $0D
         x"00" when (supercpu_en = '1' and addr_hi_816 = x"00"
                     and cpuAddr = x"FF2D") else  -- target bank = $00
         -- ----------------------------------------------------------------
         -- v310 doom wedge: override $00:$0705 read to return $40 (RTI).
         -- Doom's recompiler installs BRK vector → $00:$0705 (per v309
         -- VB:0507 capture) but the byte at $0705 is $00 (BRK opcode in
         -- native), creating an infinite BRK→$0705→BRK self-loop. SP
         -- descends $2664/vblank at 1MHz bank-$00 push rate. Forcing
         -- $0705 reads to return $40 (RTI) makes BRK a no-op so the CPU
         -- returns to wherever BRK was pushed from. This is a PROBE —
         -- if Doom advances past the wedge, we've localized the bug to
         -- the JIT $0705 byte content. Native-mode + bank-$00 gate
         -- prevents collateral damage to T65 / emu mode / other banks.
         x"40" when (supercpu_en = '1' and emu_mode_816_i = '0' and addr_hi_816 = x"00"
                     and cpuAddr = x"0705") else  -- $00:$0705 → RTI probe
         -- ----------------------------------------------------------------
         -- ROOT-CAUSE READ FIX (2026-05-13): bypass buslogic I/O decode for
         -- SCPU long-mode reads (addr_hi_816 /= $00). buslogic decodes
         -- cs_vic/cs_sid/cs_color/cs_cia* purely from cpuAddr[15:12]=$D with
         -- no bank check, so any SCPU access at $XX:$Dxxx (bank != $00)
         -- read I/O register garbage (color RAM open-bus / VIC raster / CIA
         -- timers) instead of the SuperRAM byte at that long address.
         -- scpu_sdram_addr correctly routes SDRAM to {1,bank,addr16} but
         -- the data came back from buslogic's I/O mux. ramDin carries
         -- sdram_data (via cartridge passthrough), so muxing it in here
         -- restores the correct SuperRAM byte for any non-$00 bank.
         -- Bank $00 falls through to cpuDi_raw unchanged, preserving all
         -- legacy 6510/T65 behaviour and SCPU register intercepts above.
         -- See project_bug_pinned_io_decode_ignores_bank.md for full
         -- analysis + code-peek evidence.
         --
         -- v345e (2026-05-15): gate the bank-$F8+ carve-out on bootmap='1'
         -- only. With bootmap='0' (post-kickstart and v345d default), bank
         -- $F8-$FF reads flow through ramDin (= uninit SDRAM = $00 = BRK
         -- opcodes). Doom's 693 bank-$FF JMLs then BRK → $00:$FF00 ack
         -- stub → soft no-op (matches v344b behaviour where Doom rendered
         -- title at 240s).
         -- With bootmap='1' (during kickstart reset chain), bank $F8-$FF
         -- reads route to cpuDi_raw = buslogic's scpuRomData mirror, so
         -- JML $F8:$00FC → JML $F8:$80C1 kickstart fetch returns real
         -- EPROM bytes instead of BRK.
         -- v345d (no gate) regressed Doom because scpu64.mif is 60% $FF
         -- padding; bank-$FF reads fetched $FF → SBC long,X chain → state
         -- corruption. Full analysis: docs/v345e_fix_plan.md.
         --
         -- v347/Phase 3 (2026-05-26 — Codex Fourth Option): retain only the
         -- $F8:$8147 synthesised RTL. The $8148 entry-bypass is REMOVED so
         -- the kickstart's SIMM-detection JSL at $F8:$810E now reaches the
         -- real scan; c64.sv's simm_detect_active remaps bank $F6/$F7 to
         -- $02/$03 during the scan so the alias-loop CMPs at $F8:$81A9-$81D5
         -- observe the expected SIMM aliasing.
         --
         -- The $8147 clause stays because XCE at $8146 switches to emu mode
         -- BEFORE the $8147 opcode fetch; in emu mode with bootmap='0' the
         -- bank-$F8 fetch otherwise falls through to ramDin = uninit SDRAM
         -- = $00 = BRK. Genuine EPROM byte IS $6B (RTL), so the synthesis
         -- here is non-spoofing.
         x"6B" when (supercpu_en = '1' and addr_hi_816 = x"F8"
                     and (cpuAddr = x"8147" or cpuAddr = x"8148")
                     and cpuWe = '0') else
         -- v346 (2026-05-26): widen carve-out so native-mode SCPU at
         -- bank $F8 keeps fetching from EPROM (cpuDi_raw → buslogic →
         -- scpuRomData) even after kickstart clears bootmap via STA
         -- $D07E. Needed by the v347 bypass path: the kickstart
         -- continuation at $F8:$8112-$8147 (post-RTL synthesis) still
         -- runs in native mode with bootmap='0' and must read real
         -- EPROM bytes, not uninit SDRAM.
         ramDin when (supercpu_en = '1' and addr_hi_816 /= x"00"
                     and not (scpu_bootmap = '1' and unsigned(addr_hi_816) >= x"F8")
                     and not (emu_mode_816_i = '0' and addr_hi_816 = x"F8")) else
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
			scpu_speed_reg_written <= '0';
			scpu_sys_1mhz     <= '0';
			scpu_regs_enabled <= '1';
			scpu_hwenable     <= '0';
			-- v347 (2026-05-26): bootmap='1' at reset. v345f's failure mode
			-- (bootmap='1' + STA $D07E mid-kickstart cuts EPROM exposure →
			-- BRK → SP runaway) is now covered by the v347 cpuDi bypass at
			-- $F8:$8148 (above) PLUS the v346 native-mode bank-$F8 carve-out
			-- in the ramDin gate. With bootmap='1' at reset, the CPU fetches
			-- 2026-05-28: reverted to '0' — v347's bootmap='1' at reset
			-- causes the kickstart to run on every reset, including the
			-- PRG-load reset_wait (c64.sv:429-437, 100000-cycle window for
			-- SCPU PRGs). During that window, the kickstart's MVN
			-- ($F8:$0100→$01:$0100-$60FF, mirrored to bank $00 via
			-- bank01_mirror_to_00) OVERWRITES the just-injected PRG at
			-- $0801. Doom MGL autoload regression Bug B was caused by
			-- exactly this — confirmed empirically: aafa4a4-CLEAN
			-- (bootmap='0' default) streams Doom; HEAD (bootmap='1') does
			-- not. Per v348 commit message: "Doom regression is upstream
			-- of Phase 3 — caused by the kickstart running at all".
			-- LKG 8a7489ef predates v347 and used bootmap='0' default —
			-- this restores that. v347 $F8:$8147/$8148 bypass + widened
			-- bank-$F8 carve-out are retained, harmless when kickstart
			-- doesn't run.
			scpu_bootmap      <= '0';
			scpu_optim_mode   <= "11";
			scpu_irq_tramp_installed <= '0';
			scpu_irq_vec_installed   <= '0';  -- v356
			scpu_nmi_vec_lo   <= x"00";
			scpu_nmi_vec_hi   <= x"FF";
			scpu_dos_ext_mode <= x"00";  -- Phase 6: DOS extension disabled at reset
			-- Bug 3: SIMM-extent reset defaults match the previously
			-- hardcoded read constants so a poll before any kickstart
			-- write sees identical geometry.
			scpu_simm_27c     <= x"00";
			scpu_simm_27d     <= x"02";
			scpu_simm_27e     <= x"00";
			scpu_simm_27f     <= x"F6";
			-- Phase 3 — native vector defaults: all → $00:$FF00 (RTI sink).
			-- Matches the prior hardcoded intercept pattern exactly so
			-- cold-boot behaviour before EPROM kickstart is unchanged.
			scpu_native_vec(0)  <= x"00"; scpu_native_vec(1)  <= x"FF";  -- COP
			scpu_native_vec(2)  <= x"00"; scpu_native_vec(3)  <= x"FF";  -- BRK
			scpu_native_vec(4)  <= x"00"; scpu_native_vec(5)  <= x"FF";  -- ABORT
			scpu_native_vec(6)  <= x"00"; scpu_native_vec(7)  <= x"FF";  -- NMI
			scpu_native_vec(8)  <= x"00"; scpu_native_vec(9)  <= x"FF";  -- unused
			scpu_native_vec(10) <= x"00"; scpu_native_vec(11) <= x"FF";  -- IRQ
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
				scpu_speed_reg_written <= '1';
			elsif cpuAddr = x"D07B" or cpuAddr = x"D079" then
				scpu_speed_1mhz <= '0';
				scpu_speed_reg_written <= '1';
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
			-- Phase 6 — DOS extension mode. Per VICE scpu64mem.c, $D0BE
			-- and $D0BF only fire when hwenable=1 (same gate as bootmap).
			-- $D0BC accepts direct writes (so software can set arbitrary
			-- mode values); $D0BE sets bit7 (the "enabled" sentinel),
			-- $D0BF clears the register. Real CMD HW uses bit7 alone;
			-- we pass all 8 bits through for forward-compat.
			if scpu_hwenable = '1' then
				if cpuAddr = x"D0BC" then
					scpu_dos_ext_mode <= cpuDo;
				elsif cpuAddr = x"D0BE" then
					scpu_dos_ext_mode <= cpuDo or x"80";
				elsif cpuAddr = x"D0BF" then
					scpu_dos_ext_mode <= x"00";
				end if;
			end if;
			-- IRQ JML trampoline install latch.
			-- Any write into $FCEE..$FCF1 (the IRQ JML trampoline area)
			-- means software is installing its own handler — switch the
			-- read mux off the synthesized default and over to RAM.
			if cpuAddr = x"FCEE" or cpuAddr = x"FCEF"
			or cpuAddr = x"FCF0" or cpuAddr = x"FCF1" then
				scpu_irq_tramp_installed <= '1';
			end if;
			-- NMI vector capture (bank $00 path).
			-- AmiDog recompiler's `_tick_install` (`hello/native.s`
			-- lines 90-93) writes `_tick_irq` address to $FFEA/$FFEB.
			-- Capture into our shadow register so subsequent NMI fetches
			-- at $00:$FFEA/$FFEB return the user's installed vector.
			-- CIA2 timer A IRQ routes to NMI on the C64; without a
			-- working NMI install path, _tick_count never advances and
			-- Doom's wait-for-tick loop hangs after entering recompiled
			-- code.  See project_bank_fx_narrow_unblocks_doom_dispatcher.
			if cpuAddr = x"FFEA" then
				scpu_nmi_vec_lo <= std_logic_vector(cpuDo);
			elsif cpuAddr = x"FFEB" then
				scpu_nmi_vec_hi <= std_logic_vector(cpuDo);
			end if;
			-- Bug 3 (firmware_correctness_plan.md Stage 1): SIMM-extent
			-- registers. Kickstart STZ at $F8:$81EB-$81F0 writes $00 to
			-- all four; later boot code may write configured values. No
			-- hwenable gate — real HW exposes SRAM extent regs as
			-- always-on (matches the symmetric ungated read path above).
			if cpuAddr = x"D27C" then
				scpu_simm_27c <= cpuDo;
			elsif cpuAddr = x"D27D" then
				scpu_simm_27d <= cpuDo;
			elsif cpuAddr = x"D27E" then
				scpu_simm_27e <= cpuDo;
			elsif cpuAddr = x"D27F" then
				scpu_simm_27f <= cpuDo;
			end if;
			-- Phase 3 — writable native vectors. EPROM kickstart writes
			-- handler addresses to $00:$FFE4..$FFEF during cold boot;
			-- after install, native traps land in real CMD handlers
			-- instead of our synthesized $FF00 RTI sink.
			-- Native mode gate (emu_mode_816_i='0') because the EPROM
			-- enters native via CLC/XCE before installing vectors.
			if emu_mode_816_i = '0' and cpuAddr(15 downto 8) = x"FF" then
				case cpuAddr(7 downto 0) is
					when x"E4" => scpu_native_vec(0)  <= cpuDo;
					when x"E5" => scpu_native_vec(1)  <= cpuDo;
					when x"E6" => scpu_native_vec(2)  <= cpuDo;
					when x"E7" => scpu_native_vec(3)  <= cpuDo;
					when x"E8" => scpu_native_vec(4)  <= cpuDo;
					when x"E9" => scpu_native_vec(5)  <= cpuDo;
					when x"EA" => scpu_native_vec(6)  <= cpuDo;
					when x"EB" => scpu_native_vec(7)  <= cpuDo;
					when x"EC" => scpu_native_vec(8)  <= cpuDo;
					when x"ED" => scpu_native_vec(9)  <= cpuDo;
					when x"EE" => scpu_native_vec(10) <= cpuDo; scpu_irq_vec_installed <= '1';  -- v356
					when x"EF" => scpu_native_vec(11) <= cpuDo; scpu_irq_vec_installed <= '1';  -- v356
					when others => null;
				end case;
			end if;
		end if;
		-- NMI vector capture (bank $FF path) — parallel to the bank-$00
		-- elsif above. Per native.s `.databank $ff ; fixme`, the recomp
		-- runtime may execute STA $FFEA with DBR=$FF, in which case the
		-- absolute-mode address resolves to $FF:$FFEA, not $00:$FFEA.
		-- We grab both, since the actual NMI vector fetch is always at
		-- $00:$FFEA/$FFEB regardless of whose write installed it.
		if reset = '0' and supercpu_en = '1' and cpuWe = '1'
		   and addr_hi_816 = x"FF" then
			if cpuAddr = x"FFEA" then
				scpu_nmi_vec_lo <= std_logic_vector(cpuDo);
			elsif cpuAddr = x"FFEB" then
				scpu_nmi_vec_hi <= std_logic_vector(cpuDo);
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
	vsync => vSync_sig,
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

-- v346: per-frame sticky OR of vicDi. Resets on vSync rising edge,
-- accumulates through the frame. vic_di_or_lat captures the previous
-- frame's value just before reset so the UART/debug pool reads a
-- stable per-frame number rather than the in-flight register.
process(clk32)
begin
	if rising_edge(clk32) then
		vSync_prev_r <= vSync_sig;
		if vSync_prev_r = '0' and vSync_sig = '1' then
			vic_di_or_lat <= vic_di_or_r;
			vic_di_or_r   <= (others => '0');
		elsif sysCycle = CYCLE_VIC3 then
			vic_di_or_r <= vic_di_or_r or vicDi;
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
-- v13d (2026-05-24): cs_cia1 gated ONLY for WRITES (cpuWe=1). Read path
-- is preserved exactly, so KERNAL polling/timing reads of CIA registers
-- are unaffected. Writes require an active CPU access (vpa OR vda) — this
-- blocks the phantom-write seen in v12b_mcp where stale cpu_req_we_reg
-- caused multi-strobe writes to $DC0D between requests.
-- (v13b full-gating broke IEC; v13c CIA1-only-full broke at different
-- PC range; this targeted write-only gating is the surgical attempt.)
cia1: mos6526
port map (
	clk => clk32,
	mode => cia_mode,
	phi2_p => enableCia_p,
	phi2_n => enableCia_n,
	res_n => not reset,
	-- v13d (2026-05-25): write-only gate. Reads ungated (cpuWe=0 → not
	-- cpuWe='1' → cs always asserted on cs_cia1). Writes require vpa OR
	-- vda active (= bridge has a real CPU request in flight). Blocks
	-- phantom $DC0D writes from the "between requests" window in the
	-- MCP bridge (see [[v12b-mcp-phantom-write-confirmed-2026-05-24]]).
	-- v13e tried the same gate on CIA2 and broke IEC; v13f tried
	-- bridge-level gating and wedged CPU at PC=$FCD1. v13d remains the
	-- best-known partial fix: LOAD"$",8 works, LOAD"*",8,1 wedges
	-- (CIA2 still vulnerable).
	cs_n => not (cs_cia1 and (not cpuWe or vpa_816 or vda_816)),
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

	irq_n => irq_cia1,
	dbg_imr => cia1_imr_lvl,
	dbg_cra => cia1_cra_lvl,
	dbg_pra => open,
	dbg_prb => open,
	dbg_ddra => open,
	dbg_ddrb => open,
	-- mb-probe-003: Timer A + ICR internal taps on CIA1 only.
	dbg_timer_a       => cia1_timer_a_lvl,
	dbg_timer_a_latch => cia1_timer_a_latch_lvl,
	dbg_icr           => cia1_icr_lvl
);

-- v14 (Codex 2026-05-27): CIA2 write latch+replay. The v13g widened
-- write_safe gate kept cs_n='0' for the bridge access window, but in
-- MCP mode the bridge's vpa/vda window can fall entirely outside the
-- one-clk32 CYCLE_CPUD interval where enableCia_n is high. The CIA
-- latches writes on `wr = phi2_n & !cs_n & !rw` at posedge clk
-- (mos6526.v:123); if cs_n is high during CYCLE_CPUD, the write is
-- dropped. We now latch the write request into cia2_wr_pending when
-- cs_cia2+cpuWe+write_safe is true, then fire it deterministically at
-- sysCycle=CYCLE_CPUC so cs_cia2_n is asserted for the entire CYCLE_CPUD
-- interval. Reads remain ungated.
process(clk32) begin
	if rising_edge(clk32) then
		cia2_wr_fire <= '0';
		if reset = '1' then
			cia2_wr_pending <= '0';
		else
			if cs_cia2 = '1' and cpuWe = '1' and cia2_write_safe = '1'
			   and cia2_wr_pending = '0' then
				cia2_wr_pending <= '1';
				cia2_wr_rs      <= cpuAddr(3 downto 0);
				cia2_wr_do      <= cpuDo;
			end if;
			if sysCycle = CYCLE_CPUC and cia2_wr_pending = '1' then
				cia2_wr_fire    <= '1';
				cia2_wr_pending <= '0';
			end if;
		end if;
	end if;
end process;

cia2_cs_n <= '0' when cia2_wr_fire = '1'
                  or (cs_cia2 = '1' and cpuWe = '0') else '1';
cia2_rw_q <= '0' when cia2_wr_fire = '1' else not cpuWe;
cia2_rs_q <= cia2_wr_rs when cia2_wr_fire = '1' else cpuAddr(3 downto 0);
cia2_db_q <= cia2_wr_do when cia2_wr_fire = '1' else cpuDo;

cia2: mos6526
port map (
	clk => clk32,
	mode => cia_mode,
	phi2_p => enableCia_p,
	phi2_n => enableCia_n,
	res_n => not reset,
	cs_n => cia2_cs_n,
	rw => cia2_rw_q,

	rs => cia2_rs_q,
	db_in => cia2_db_q,
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

	irq_n => irq_cia2,
	dbg_imr => cia2_imr_lvl,
	dbg_cra => cia2_cra_lvl,
	dbg_pra => cia2_pra_lvl,
	dbg_prb => cia2_prb_lvl,
	dbg_ddra => cia2_ddra_lvl,
	dbg_ddrb => cia2_ddrb_lvl,
	-- mb-probe-003: CIA2 internal taps not currently routed to UART
	-- (only CIA1 Timer A is suspect for the wedge).
	dbg_timer_a       => open,
	dbg_timer_a_latch => open,
	dbg_icr           => open
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
--
-- Phase 2 (I/O cycle stretching) — already implicit in this arbitration:
--   line 2236 below: turbo_m is only loaded when cs_io='0'
--   line 2218 below: cpu_cyc for I/O is gated solely on (sysCycle=CYCLE_CPUC
--                    AND (io_enable='1' or cs_ram='1'))
-- So I/O accesses always go through the slowest path (CPUC slot only) —
-- ~32 clk32 cycles between successive I/O CPU advances regardless of
-- turbo speed. This is more stretching than VICE's explicit
-- scpu64_clock_*_stretch_io() (~2-3 CPU cycles).
--
-- Master needed an explicit io_slowdown gate because it added fast paths
-- (bram_hit_d1 / cache_hit_d1 / phantom_enable) that could bypass CPUC
-- arbitration. This branch has no such fast paths — the simpler scheme
-- above means I/O is always stretched. No additional Phase 2 RTL is
-- required. Verified absent: bram_hit_d1, cache_hit_d1, phantom_enable.
--
-- Phase 8 (1MHz badline emulation in turbo): already implemented via
-- the rdy=>baLoc wiring on both CPU instances below. VIC drops baLoc
-- during badline raster fetches (40 cycles/line, every 8th line); the
-- P65C816 RDY input then stalls the CPU mid-cycle (subject to the
-- rdy_gated-by-write fix from cf49066). Software running in turbo SEES
-- the badline stall, matching real CMD SuperCPU "1MHz badline" mode.
-- No additional Phase 8 RTL is required.
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
	clk => clk_cpu,
	reset => reset,
	-- F.3' enable CDC fix (2026-05-24): drive enable from the bridge's
	-- cpu_enable_out. In passthrough mode (EFF_BRIDGE_ACTIVE='0') the
	-- bridge passes enableCpu_816 through unchanged → bit-identical to
	-- baseline. In MCP mode (EFF_BRIDGE_ACTIVE='1') the bridge fires
	-- cpu_enable on the same clk_cpu edge it releases cpu_rdy, so the
	-- CPU sees EN=RDY AND CE true simultaneously (project_f3_mcp_
	-- data_path_broken_on_hw_2026_05_24.md root cause). Verified at
	-- RATIO=1/2/3 in sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd.
	enable => cpu816_enable_to_cpu,
	nmi_n => irq_cia2 and nmi_n,
	nmi_ack => nmi_ack_816,
	irq_n => irq_cia1 and irq_vic and irq_n and irq_ext_n,
	-- F.diag fix (2026-05-22): rdy is the AND of baLoc (VIC badline stall,
	-- load-bearing per Phase 8 comment above) and the bridge's MCP stall.
	-- Pre-bridge code wired this directly to baLoc; bridging through the
	-- bridge alone (with cpu_rdy_out <= '1' at BRIDGE_ACTIVE='0') broke
	-- the badline stall and caused $AB-on-every-read memory corruption.
	rdy => baLoc and cpu816_rdy_to_cpu and data_ready,  -- iter-7: data_ready inert '1' unless RDY_HANDSHAKE (decl :~1581)

	di => cpu816_di_to_cpu,
	addr => cpu816_addr_raw,
	do => cpu816_do_raw,
	we => cpu816_we_raw,

	diIO => cpuIO_816(7) & cpuIO_816(6) & cpuIO_816(5) & cass_sense & cpuIO_816(3) & "111",
	doIO => cpuIO_816,

	addr_hi        => cpu816_addr_hi_raw,
	emulation_mode => emu_mode_816_i,
	vpa            => cpu816_vpa_raw,
	vda            => cpu816_vda_raw,

	dbg_pc    => dbg_pc_816_i,
	dbg_sp    => dbg_sp_816_i,
	dbg_p     => dbg_p_816_i,
	dbg_ir    => open,
	dbg_pbr   => dbg_pbr_816_i,
	dbg_dbr   => dbg_dbr_816_i,
	dbg_x     => dbg_x_816_i,
	dbg_y     => dbg_y_816_i,
	dbg_d     => open,
	dbg_state => open,
	dbg_vpb   => dbg_vpb_816_i
);

-- D4.2 (2026-05-21): CACHE_ACTIVE='1' wedges KERNAL with $AB on every ZP
-- read across FOUR different cache patterns; rolled back, scaffolding
-- preserved. Phase F.5 revisits once the F.1 MCP rewrite collapses the
-- cpu_di mux topology. See project_bridge_cache_d4_2_wedge.md.
--
-- Phase F.1 (2026-05-21): bridge rewritten to MCP / word-synchronizer
-- handshake per docs/async_bridge_mcp_handshake_plan.md. Port renamed
-- bus_rdy_in -> bus_ack_pulse_in (single-cycle clk_sys pulse, not level)
-- and wired to enableCpu_816 — the arbiter's CPU-slot pulse, which IS
-- the cycle the CPU latches cpuDi. With BRIDGE_ACTIVE='0' the new MCP
-- FSM is dead-output (cpu_di_out muxes to bus_di_in passthrough),
-- preserving baseline behavior bit-for-bit.
scpu_async_bridge_inst: entity work.scpu_async_bridge
generic map (
	-- F.3' enable retry 2026-05-24: bridge's cpu_enable_out now aligned
	-- with cpu_rdy_out release on the same clk_cpu edge, so EN=RDY AND CE
	-- both true simultaneously. Validated at RATIO=1/2/3 in sim with real
	-- P65C816 (sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd). EFF_BRIDGE_
	-- ACTIVE = '1' AND NOT '0' = '1' → MCP path drives all CPU-side outputs.
	BRIDGE_ACTIVE          => '1',
	CACHE_ACTIVE           => '0',
	-- v8 IEC fix (2026-05-24, RBF b1aceea1): SAME_CLOCK_PASSTHROUGH='1'
	-- disables the MCP path entirely (EFF_BRIDGE_ACTIVE = '1' AND NOT
	-- '1' = '0' → pure passthrough). Confirmed by hardware test:
	-- LOAD"$",8 → SEARCHING FOR $ → LOADING → READY (was wedge at
	-- $EEAC under v7 MCP-active + throttle), and LOAD"*",8,1 also
	-- completes successfully both at native turbo AND with $D072
	-- throttle. The MCP path's vpa/vda hold-for-roundtrip was breaking
	-- CIA2 reads in the IEC byte-receive loop (see project memory
	-- project_v8_passthrough_iec_fix_2026_05_24.md).
	--
	-- MCP path provides ZERO speedup at clk_cpu=clk_sys (the bridge
	-- only matters for cross-domain CDC at clk_cpu=64MHz). So flipping
	-- to passthrough is the strict win until clk_cpu=64MHz revival.
	-- The bridge code is preserved intact: setting SAME_CLOCK_PASSTHROUGH
	-- back to '0' re-arms MCP — keep that for the future 64MHz path.
	--
	-- $D072/$D07A throttle stays effective in passthrough because it
	-- gates cpu_cyc → enableCpu_816, which now drives cpu_enable_out
	-- directly via bus_ack_pulse_in.
	-- 2026-05-25: passthrough mode (MCP disabled) to test whether v13d
	-- CIA1 + v13g CIA2 cs-gates work correctly without MCP. Disambiguates
	-- whether remaining LOAD"*" wedge is MCP-specific or affects passthrough.
	-- 2026-05-26 (mb-probe-001 result): re-enabled MCP on top of Option (a)
	-- silicon and ran milestone-b probe (FS/DI/RQ/AK/VF). MCP wedge
	-- reproduces identically: CIA1 IF/C1 frozen → irq_n stuck low → ICR
	-- never cleared. Race α (PC byte-aliasing) FALSIFIED. Race β (RQ-AK
	-- divergence) NOT discriminable because both saturated at $FFFF before
	-- first vblank sample. FS=IDLE/WAIT_ACK split ~50/50, not stuck at 2.
	-- 2026-05-26 (mb-probe-002, Codex Design 3 build): flipping back to '0'
	-- to re-engage MCP path so the v2 vblank-snapped bridge probes
	-- (RQ/AK wrapping, WD dwell-max, FL activity flags, GM gap-max) can
	-- actually observe the wedge. v1's saturating counters maxed out at
	-- $FFFF before the first vblank sample; v2 fixes that with source-
	-- domain snapshot + vblank-rise capture. REMEMBER TO REVERT TO '1'
	-- BEFORE MERGING if MCP debug is incomplete (see Codex review for
	-- the rationale on snapshot-before-case ordering).
	-- 2026-05-28: reverted to '1' (LKG 18167a5 behavior). MCP path was
	-- the only difference between LKG's known-good Doom autoload and
	-- my fix-stacked HEAD build that still wedged at REU C0500. The
	-- 851-line bridge+sid_iec changes between LKG and HEAD include MCP
	-- activation in d673dd6; with bootmap='0' at reset, kickstart no
	-- longer runs so boot doesn't depend on MCP. Passthrough='1' makes
	-- EFF_BRIDGE_ACTIVE=0 → CPU runs at full speed on clk_sys directly,
	-- bypassing the F.3' CDC bridge that was wedging Doom's REU FETCH
	-- chain. Tradeoff: loses observability of the kickstart's irq_n-stuck
	-- mechanism — but kickstart isn't running anymore, so that's moot.
	-- 2026-05-30: parameterised via the entity generic SCPU_MCP_ACTIVE
	-- (default '0' ⇒ this stays '1' ⇒ bit-identical to the shipped HW
	-- build). The Milestone-B GHDL harness sets SCPU_MCP_ACTIVE='1' so
	-- this becomes '0' and the MCP path re-arms for clk_cpu=64MHz sim.
	SAME_CLOCK_PASSTHROUGH => (not SCPU_MCP_ACTIVE)
)
port map (
	clk_cpu        => clk_cpu,
	clk_sys        => clk32,
	reset          => reset,

	cpu_addr_in    => cpu816_addr_raw,
	cpu_addr_hi_in => cpu816_addr_hi_raw,
	cpu_do_in      => cpu816_do_raw,
	cpu_we_in      => cpu816_we_raw,
	cpu_vpa_in     => cpu816_vpa_raw,
	cpu_vda_in     => cpu816_vda_raw,
	cpu_di_out     => cpu816_di_to_cpu,
	cpu_rdy_out    => cpu816_rdy_to_cpu,
	cpu_enable_out => cpu816_enable_to_cpu,

	bus_addr_out     => cpuAddr_816,
	bus_addr_hi_out  => addr_hi_816,
	bus_do_out       => cpuDo_816,
	bus_we_out       => cpuWe_816,
	bus_vpa_out      => vpa_816,
	bus_vda_out      => vda_816,
	bus_di_in        => cpuDi,
	bus_ack_pulse_in => enableCpu_816,
	-- F.3' arbiter prefetch strobe — combinational cpu_cyc fires
	-- 2 clk_sys ahead of enableCpu_816 (= 4 clk_cpu at 2:1 ratio).
	-- Wired now so the port exists, but unused until F.3' enables
	-- the MCP path (BRIDGE_ACTIVE='1' + SAME_CLOCK_PASSTHROUGH='0').
	bus_request_strobe_in => cpu_cyc,

	dbg_is_slow      => cpu816_dbg_is_slow,

	-- Milestone B (2026-05-25): bridge-internal UART probes.
	dbg_fsm_state           => cpu816_dbg_fsm_state,
	dbg_last_bus_di         => cpu816_dbg_last_bus_di,
	dbg_req_count           => cpu816_dbg_req_count,
	dbg_ack_count           => cpu816_dbg_ack_count,
	dbg_irq_vec_fetch_count => cpu816_dbg_vec_fetch_count,
	-- Milestone B v2 (2026-05-26 — Codex Design 3): vblank-snapped probes.
	dbg_wait_dwell_max      => cpu816_dbg_wait_dwell_max,
	dbg_activity_flags      => cpu816_dbg_activity_flags,
	dbg_gap_max             => cpu816_dbg_gap_max,
	-- vSync_sig is the clk_sys-domain vblank rising edge (PAL ~50Hz /
	-- NTSC ~60Hz). The bridge 3-FF syncs it into clk_cpu and
	-- rising-edge-detects to trigger the per-frame snapshot.
	dbg_vblank_sys_in       => vSync_sig
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
-- Milestone A Option (b) (2026-05-26): export the internal scpu_fast_path
-- signal so c64.sv can wire it into sdram_pm.v's HIT gate. Driven from
-- the existing internal definition further down (line ~2974).
scpu_fast_path_o <= scpu_fast_path;

cass_motor <= cpuIO(5);
cass_write <= cpuIO(3);

ramDout <= cpuDo;
ramAddr <= systemAddr;
ramWE   <= systemWe when sysCycle >= CYCLE_CPU0 else '0';
ramCE   <= cs_ram when sysCycle = CYCLE_VIC0 or cpu_cyc = '1' else '0';

-- Step 2 (Mitigation A, 2026-05-20) combinational helpers.
-- sdram_busy: asserted while the local predictor counter is non-zero.
-- scpu_fast_path: asserted when SCPU is executing in a SuperRAM bank
-- (≠ $00), not hitting I/O, and no DMA active. Alt-slot CPU enables
-- (CPU2/6/A/E) are admitted only on this path; main-slot terms below
-- are unchanged in semantics — they're still gated on cs_ram which
-- becomes '1' for bank ≠ $00 via scpu_long_access in fpga64_buslogic.
sdram_busy     <= '1' when sdram_busy_cnt /= "000" else '0';
scpu_fast_path <= '1' when supercpu_en = '1'
                       and addr_hi_816 /= x"00"
                       and cs_io = '0'
                       and dma_active = '0' else '0';

-- Milestone A Build C HIT/MISS predictor (2026-05-25). Combinational
-- comparison against the row register updated below in the clk32 process.
-- Decoded address bits mirror sdram_pm.v's slicing:
--   bank = sdram_addr_25[22:21]
--   row  = sdram_addr_25[20:8]
-- For the SCPU long-mode path the upstream 25-bit address is
-- {1'b1, addr_hi_816, systemAddr} (matching scpu_sdram_addr in c64.sv when
-- supercpu_enable && supercpu_bank != $00). For bank-$00 / 6510 / vanilla
-- the upstream is {1'b0, 8'b0, systemAddr} (cart_addr collapses to
-- systemAddr's 16-bit address with the cart-region prefix). The two cases
-- have different bank/row layouts, so the predictor is INTENTIONALLY
-- conservative: only mark HIT when (a) the predictor was last updated for
-- the SAME path class AND (b) the bank+row bits actually match. Path-class
-- transitions invalidate the row (handled in the clk32 process below).
-- 2026-05-28: predictor force-disabled. Per session_handoff §5, the
-- dual-tracker (sdram_pm.v last_row_valid vs this sdram_pred_valid) can
-- disagree across the refresh→VIC0 window — when sdram_pm closes the row
-- on a non-fast_path MISS but sdram_pred_valid stays high until CYCLE_VIC0,
-- the arbiter trusts HIT (busy_cnt=001) while sdram_pm executes MISS
-- (~8 clk64), so the CPU latches stale data. This caused Doom autoload's
-- REU→SuperRAM transfer to corrupt mid-stream → BRK $00:000A. Forcing
-- hit_pred='0' makes the arbiter always use MISS budget (busy_cnt=011),
-- bit-identical to Build B / pre-829ee06. Slight perf cost (~2-4 clk64
-- per CPU access) but Doom runs.
-- iter-6: when CACHE_READ_PATH, a read-path cache HIT shortens the grant
-- (busy_cnt<="001", :3404) — INSEPARABLE from the cache_di->cpuDi override at
-- :1932 (shortening without the data override = the BRK $00:000A stale-latch
-- the comment above describes). rp_cache_hit is inert '0' when the read path is
-- off, so this is bit-identical to `<= '0'` in the shipped (false) config.
-- iter-17 (2026-06-03) Bug 2 FIX: HITPRED_SHORTGRANT gates the cache-hit grant
-- shortening. HW-PROVEN (diagnostic build 48730a04, CACHE_DATA_OVERRIDE=false):
-- with the cpuDi DATA override OFF (CPU got byte-identical baseline SDRAM
-- passthrough) but this short grant LIVE, Doom STILL crashed (bank-$20 -> wild
-- $80/$2B/$29) => the corruptor is THIS grant, not the cache data. Mechanism:
-- "001" reservation -> sdram_busy clears early (:3376) -> cpu_cyc fires sooner
-- (:3489, cpu_cyc gated on sdram_busy='0') -> cpu_cyc_s(1)/enableCpu consume
-- sooner -> CPU latches SDRAM data before the ~79ns sdram_pm read settles =
-- stale. This is the dual-tracker desync force-disabled at :3387-3396. Forcing
-- '0' keeps the documented-safe full "011" reservation. The iter-15 alt-fire
-- FAST path (2-apart on hits, :3635-3641) is INDEPENDENT of sdram_busy/hit_pred
-- (data from the registered _d1 cache latch, no SDRAM) so the 3x speedup
-- survives. The old "INSEPARABLE pair" warning was only about shortening
-- WITHOUT the override; never-shortening (this) is the safe direction.
-- (HITPRED_SHORTGRANT declared with the other cache constants ~:1593.)
sdram_hit_pred <= rp_cache_hit when (CACHE_READ_PATH and HITPRED_SHORTGRANT) else '0';

-- iter-7 RDY-handshake data-ready term (see decl near :1581). Ready immediately
-- for non-SDRAM reads (cs_ram='0' => I/O/ROM/color, combinational) and whenever
-- the cache HITs; otherwise wait for the SDRAM controller's per-access fresh-dout
-- handshake. Inert '1' unless RDY_HANDSHAKE and supercpu_en (6510 path untouched).
data_ready <= '1' when (not RDY_HANDSHAKE) or supercpu_en = '0' or cs_ram = '0'
              else (rp_cache_hit or sdram_data_valid_sync);

-- Step 7b (2026-05-23): no extra combinational helper needed —
-- alt_fire_r2 reuses scpu_fast_path directly (already SuperRAM-only).

-- Step 2 (2026-05-20): busy-counter backpressure infrastructure.
-- Main-slot terms gated on sdram_busy='0'. With Build B's 8-clk64 SDRAM
-- cycle, the counter is 0 at every CPU0/4/8/C boundary, so this gate is
-- a no-op for today's cadence (verified PASS, 6/6 Doom hashes vs v356).
-- The alt-slot fast-path (CPU2/6/A/E + scpu_fast_path) is INTENTIONALLY
-- omitted at this step: empirically, simply adding the alt-slot term to
-- cpu_cyc (with either OUTER or INNER busy gate) wedges Doom even
-- though static analysis shows the gate should block every fire on
-- Build B. Suspect: synthesis-level hazard on cpu_cyc → ramCE → cart_ce
-- propagation when alt-slot inputs are folded into the same LUT. To be
-- re-investigated together with Step 5 (Build C revival), where the
-- alt-slot becomes actually useful (cycle=3 clk64, busy_cnt tighter).
-- 2026-05-24: scpu_force_1mhz throttles cpu_cyc to a single CYCLE_CPUC slot
-- per 1MHz period when software asserts $D072 (system 1MHz) or $D07A
-- (SCPU 1MHz). Required so KERNAL IEC byte-receive ($EEAF) gets stock
-- 1MHz CIA2 timing — without this, LOAD"*",8,1 wedges on the F.3' bridge
-- (~3MHz effective). Bridge-side change deemed unnecessary: enableCpu_816 =
-- cpu_cyc_s(1), so gating cpu_cyc here propagates through the bridge ack
-- pulse naturally and makes the CPU advance at 1MHz with no MCP changes.
scpu_force_1mhz <= scpu_speed_1mhz or scpu_sys_1mhz or cia2_throttle_active or emu_serial_throttle;

-- Emulation-mode KERNAL serial throttle. Hold the CPU at 1MHz whenever it
-- executes the stock IEC serial routines (pages $ED/$EE, bank $00) in
-- emulation mode. Those routines bit-bang the c1541 with CPU-cycle-counted
-- NOP delays ($ED66-$ED90 send, $EE13 ACPTR receive) that desync the drive
-- at turbo speed -> $ED5A LOAD wedge. Native mode never runs them (no serial).
-- This also protects LOAD/SAVE if SCPU-aware software left emulation in fast
-- mode ($D07B) before a serial transaction. Registered (1 clk32 engage/release
-- latency is negligible vs the hundreds-of-clk32 serial bit cells).
process(clk32)
begin
	if rising_edge(clk32) then
		-- iter-31b: fire in BOTH emu AND native mode. The earlier "native mode
		-- never runs serial" assumption is FALSE for the SCPU64 ROM: the Lorenz
		-- chained-test LOAD ($ED5A serial) ran/wedged DESPITE the prior emu-only
		-- throttle, implying the SCPU64 KERNAL services serial in native mode.
		-- Throttling $ED/$EE bank-$00 serial in both modes forces 1MHz there so
		-- the bit-bang timing is correct regardless of CPU mode AND keeps fast-fire
		-- off during serial (scpu_force_1mhz gate). Doom never executes $ED/$EE at
		-- runtime, so no game impact.
		if supercpu_en = '1'
			and cpu_pc_now(23 downto 16) = x"00"
			and (cpu_pc_now(15 downto 8) = x"ED" or cpu_pc_now(15 downto 8) = x"EE") then
			emu_serial_throttle <= '1';
		else
			emu_serial_throttle <= '0';
		end if;
	end if;
end process;

-- Problem C (Codex 2026-05-27): CIA2 auto-throttle counter. Reloads on any
-- accepted CPU CIA2 access; counts down on every clk32 otherwise. While
-- nonzero, scpu_force_1mhz stays asserted so the CPU advances one slot per
-- 1MHz period. Trigger condition matches Codex's recommendation:
-- supercpu_en + addr_hi_816=$00 + cs_cia2 + enableCpu_816 (covers both
-- reads and writes; CIA2 polling reads are the actual wedge mechanism).
-- N=64 clk32 = 2 1MHz periods after each access. Sweep target if this
-- proves insufficient: 32/64/128.
cia2_throttle_active <= '1' when cia2_throttle_cnt /= 0 else '0';

process(clk32)
begin
	if rising_edge(clk32) then
		if reset = '1' then
			cia2_throttle_cnt <= (others => '0');
		elsif supercpu_en = '1' and addr_hi_816 = x"00"
			and cs_cia2 = '1' and enableCpu_816 = '1' then
			cia2_throttle_cnt <= to_unsigned(64, cia2_throttle_cnt'length);
		elsif cia2_throttle_cnt /= 0 then
			cia2_throttle_cnt <= cia2_throttle_cnt - 1;
		end if;
	end if;
end process;

-- iter-27 fix (Codex falsification #1): VDA/VPA qualifier for the main prefetch.
-- When INTERNAL_FAST_FIRE, an INTERNAL cycle (VDA=VPA=0) must NOT issue a cpu_cyc
-- prefetch — otherwise the fast-internal scheduler advances the CPU past that
-- cycle while a dangling cpu_cyc_s(1) MAIN pulse (from the bogus prefetch's
-- stale address) fires on the FOLLOWING cycle and consumes the wrong SDRAM read
-- => stale di => wedge. Gating cpu_cyc on (vda or vpa) means internal cycles
-- issue no prefetch and no pending MAIN; they are advanced ONLY by the
-- fast-internal branch. When the constant is false this is '1' always =>
-- cpu_cyc is bit-identical to the shipped arbiter (Quartus constant-folds it).
cpu_cyc_va_ok <= '1' when (not INTERNAL_FAST_FIRE) or (vda_816 = '1' or vpa_816 = '1') else '0';

-- iter-31 step 6: fast bank-$00 READ classifier (Codex v3 + iter-31b NATIVE-ONLY gate).
-- Real memory READ (vda or vpa => excludes internal VDA=VPA=0 cycles, the
-- internal-fast-fire hazard), bank $00 only (addr_hi=$00 => the c64.sv $01->$00 mirror
-- stays 4-apart; safe because b00_fast_read='1' implies c64.sv is_bank00='1'), cs_ram
-- (excludes $Dxxx I/O), not a write (writes keep the cpu_cyc MAIN path for the BRAM
-- write strobe), not throttled, no DMA. Folds to '0' when BANK00_FASTFIRE=false =>
-- cpu_cyc/enableCpu bit-identical.
-- NATIVE-ONLY (emu_mode_816_i='0'): iter-31b HW finding — emu/turbo fast-fire ran the
-- Lorenz scpu suite ~2.4-3x faster but (a) changes CPU-cycles-per-CIA-tick vs control
-- (risks the cycle-sensitive Lorenz CIA-timer tests) and (b) disrupted the KERNAL serial
-- LOAD ($ED5A) that chains the test programs. Gating to native mode makes ALL emulation-
-- mode code (Lorenz's 6502 test bodies, stock C64 software, KERNAL/IEC timing loops)
-- bit-identical to control => Lorenz scpu stays 100%. Doom runs NATIVE (XCE; JML $20:0000)
-- so it keeps the full 38.8% bank-$00 win. Native SuperCPU software is the speed target;
-- emu mode is the compat target and does not need acceleration.
b00_fast_read <= '1' when BANK00_FASTFIRE and supercpu_en = '1' and cs_ram = '1'
                      and emu_mode_816_i = '0'
                      and addr_hi_816 = x"00"
                      and (vda_816 = '1' or vpa_816 = '1')
                      and cpuWe_pre = '0'
                      and scpu_force_1mhz = '0' and dma_active = '0' else '0';

cpu_cyc <= '1' when (sdram_busy = '0' and cpu_cyc_va_ok = '1' and (
				(sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1' and scpu_force_1mhz = '0' and b00_fast_read = '0') or
				(sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1' and scpu_force_1mhz = '0' and b00_fast_read = '0') or
				(sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1' and scpu_force_1mhz = '0' and b00_fast_read = '0') or
				(sysCycle = CYCLE_CPUC and (io_enable = '1'  or (cs_ram = '1' and b00_fast_read = '0'))) or
				-- iter-28 Milestone C: demand slots — busy-gated extra CPU-region
				-- fires (inside the sdram_busy='0' gate above; busy_cnt="011" paces
				-- to >=3 clk32). SCPU full-turbo (turbo_m="111") + RAM only + not
				-- throttled. Folds away when DEMAND_ARBITER=false. Slots CPU1..CPUB
				-- (NOT CPUC/D/E/F): the last possible consume is CPUB+2=CPUD (CPUC's
				-- own consume CPUE is existing behaviour), all in-region. CPUD/E are
				-- EXCLUDED because they are NOT reliably busy-blocked — an io_enable
				-- CPUC fire (cs_ram=0) does NOT load busy_cnt, so a following RAM
				-- access at CPUE could fire and its consume would land in the next
				-- period's EXT0 (Codex iter-28 review, hole #5).
				(DEMAND_ARBITER and supercpu_en = '1' and turbo_m = "111"
				   and cs_ram = '1' and scpu_force_1mhz = '0'
				   and (sysCycle = CYCLE_CPU1 or sysCycle = CYCLE_CPU2 or sysCycle = CYCLE_CPU3
				        or sysCycle = CYCLE_CPU5 or sysCycle = CYCLE_CPU6 or sysCycle = CYCLE_CPU7
				        or sysCycle = CYCLE_CPU9 or sysCycle = CYCLE_CPUA or sysCycle = CYCLE_CPUB))
			)) or (alt_fire_r = '1' and scpu_force_1mhz = '0')
			   or (alt_fire_r2 = '1' and scpu_force_1mhz = '0') else '0';
				
process(clk32)
begin
	if rising_edge(clk32) then
		-- Layer 2 sync (Step 1, 2026-05-20): bring sdram_ready into clk32.
		-- 2-FF chain. Consumer wired in Step 2.
		sdram_ready_sync <= sdram_ready_sync(0) & sdram_ready;

		-- Step 6 Phase 6a (2026-05-20): single-flop sync of sdram_data_valid.
		-- Consumer (RDY-handshake gate replacing cpu_cyc_s) lands in Phase 6b.
		sdram_data_valid_sync <= sdram_data_valid;

		-- Step 2 (Mitigation A, 2026-05-20): local SDRAM-busy predictor.
		-- Reset to 3 on any cpu_cyc fire that drives an SDRAM transaction
		-- (cs_ram = '1' covers bank-$00 RAM AND SuperRAM via the
		-- scpu_long_access OR in fpga64_buslogic.vhd:551). Decrement one
		-- per clk32 down to 0. Build B baseline SDRAM cycle = 8 clk64 =
		-- 4 clk32 → counter is 0 by the next main slot (CPU0→CPU4 is 4
		-- clk32), preserving today's cadence. Alt-slot CPU2 (2 clk32
		-- later) sees counter ≠ 0 with Build B → blocked. Counter
		-- decrement length will be tightened in Step 5 once Build C's
		-- 3-clk64 HIT path is back.
		-- Step 6 (Milestone A, 2026-05-22): augment the static decrement
		-- with an early-clear on the rising edge of the 2-FF synced
		-- sdram_ready. Static decrement remains the safety floor (cycle-
		-- accurate for Build B 4-clk32 cycles, prevents permanent wedge
		-- if ready_sync is stuck). On Build C HIT the synced edge arrives
		-- earlier than the static expiry and unblocks alt-slot at CPU2.
		sdram_ready_sync_prev <= sdram_ready_sync(1);
		-- Milestone A Build C (2026-05-25): HIT-aware preload. When the
		-- local predictor says the upcoming SDRAM cycle hits an already-
		-- open row, the cycle is ~3 clk64 instead of ~6; preload "001"
		-- so the counter clears in ~1 clk32 and the alt-slot at CPU2 can
		-- fire safely. ready_sync rising-edge early-clear (below) closes
		-- the rest of the loop for MISS cases. See design doc §3.2 / §4.1.
		--
		-- Predictor row register is updated in the same block so the next
		-- access can hit. Update applies to cs_ram accesses only — the
		-- I/O and color paths don't go through sdram_pm and shouldn't
		-- pollute the row state. Cs_ram covers both bank-$00 RAM and
		-- SuperRAM (via scpu_long_access in fpga64_buslogic.vhd).
		if cpu_cyc = '1' and cs_ram = '1' then
			if sdram_hit_pred = '1' then
				sdram_busy_cnt <= "001";   -- Build C HIT — short reservation
			else
				sdram_busy_cnt <= "011";   -- Build B MISS — worst-case floor
			end if;
			-- Update the predictor row to whatever this access hit, so
			-- the next access can HIT against it. The slicing matches
			-- the comb. predictor above so the next sample sees the row
			-- it just opened.
			if scpu_fast_path = '1' then
				sdram_pred_bank <= addr_hi_816(6 downto 5);
				sdram_pred_row  <= addr_hi_816(4 downto 0)
				                 & systemAddr(15 downto 8);
			else
				sdram_pred_bank <= "00";
				sdram_pred_row  <= "00000" & systemAddr(15 downto 8);
			end if;
			sdram_pred_valid <= '1';
		elsif sdram_busy_cnt /= "000" then
			if sdram_ready_sync(1) = '1' and sdram_ready_sync_prev = '0' then
				sdram_busy_cnt <= "000";
			else
				sdram_busy_cnt <= sdram_busy_cnt - 1;
			end if;
		end if;
		-- Refresh invalidates the open row inside sdram_pm.v; the
		-- predictor must follow. `refresh` is generated on this same
		-- module elsewhere; for now invalidate on every video VIC0 slot
		-- to be safe (refresh-issuing windows live in those slots).
		-- Coarse-grain but never produces false HITs — only drops some
		-- HITs that would otherwise be safe.
		if sysCycle = CYCLE_VIC0 then
			sdram_pred_valid <= '0';
		end if;

		-- Step 5 trial: latch alt-slot fire decision one clk32 ahead of
		-- the alt slot itself (at CPU1/5/9/D). cpu_cyc then sees alt-slot
		-- via a clean register output rather than a combinational LUT
		-- cluster, avoiding the Step 2 wedge.
		-- HARD-GATED OFF 2026-05-23 after controlled-variable measurement
		-- (RBF a993d7b7 alt_fire_r ON vs RBF 453a3380 both OFF) showed
		-- bench COUNT-per-PASS bit-identical at ~2575 iter/window:
		-- Step 5 alt_fire_r contributes 0% on Build B because the
		-- SDRAM cycle (~4 clk32) is too long for any alt-slot fire to
		-- be safe. Restore + retry on Build C's ~3-clk32 page-mode SDRAM.
		-- See project_alt_fire_r_dead_on_buildB_2026_05_23.md in memory.
		--if (sysCycle = CYCLE_CPU1 or sysCycle = CYCLE_CPU5
		--    or sysCycle = CYCLE_CPU9 or sysCycle = CYCLE_CPUD)
		--   and scpu_fast_path = '1'
		--   and cs_ram = '1'
		--   and sdram_busy = '0' then
		--	alt_fire_r <= '1';
		--else
			alt_fire_r <= '0';
		--end if;

		-- Step 7b (2026-05-23): SuperRAM-only alt-fire at CPU3/7/B/F.
		-- Sample at CPU2/6/A/E with predicate sdram_busy_cnt <= 1
		-- (= going to be free next clk32). Gated on scpu_fast_path so
		-- bank-0 accesses (KERNAL ROM, BASIC, ZP) stay on the original
		-- 4-MHz cadence. SuperRAM accesses (Doom/Wolf3D recompiler code,
		-- long-mode bench) get the extra fire = 5 MHz cap for those
		-- workloads.
		-- HARD-GATED OFF 2026-05-23 to test whether alt_fire_r2 is the
		-- cause of the bank-$20 payload wedge in superram_bench / b20
		-- border probes. If border turns red on this OFF build, RTL
		-- fix is to gate alt_fire_r2 on sdram_ready_sync rising edge
		-- or extra busy_cnt tick. Re-enable by restoring the original
		-- condition below.
		--if (sysCycle = CYCLE_CPU2 or sysCycle = CYCLE_CPU6
		--    or sysCycle = CYCLE_CPUA or sysCycle = CYCLE_CPUE)
		--   and scpu_fast_path = '1'
		--   and cs_ram = '1'
		--   and sdram_busy_cnt <= "001" then
		--	alt_fire_r2 <= '1';
		--else
			alt_fire_r2 <= '0';
		--end if;

		cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc;

		-- ── iter-15: same-line 2x alt-fire single gap-gated enable scheduler ──
		-- Replaces the shipped `enableCpu <= cpu_cyc_s(1)`. When ALT_FIRE_SAMELINE or
		-- CACHE_READ_PATH is false, or in 6510 mode, this collapses to the baseline
		-- pulse (RBF bit-identical). Otherwise ONE registered scheduler owns enableCpu
		-- with TWO fire sources:
		--   MAIN (both modes): the baseline cpu_cyc_s(1) pulse guarded by en_gap>=3.
		--     cpu_cyc_s(1) carries ALL baseline permits (turbo_m / cs_ram / io_enable@CPUC
		--     / not scpu_force_1mhz) AND ties the consume to the real SDRAM prefetch slot
		--     (cpu_cyc @ CPU0/4/8/C → cpu_cyc_s(1) @ CPU2/6/A/E → enable CPU3/7/B/F). So a
		--     MISS main always gets the proven 4-apart SDRAM window. The en_gap>=3 guard
		--     suppresses a too-soon main right after a fast (steady slow keeps en_gap>=3 =
		--     baseline bit-identical; Codex iter-15 review: do NOT fire off-prefetch mains).
		--   FAST (fast mode only: SuperRAM exec, not throttled, not dma): a 2-apart consume
		--     at an even CPU slot, gated en_gap>=1 + LIVE rp_same_line + LIVE rp_cache_hit
		--     (NOT _d1 — proven by cpu_cache_sched_phasing_tb) + baLoc + cpu816_rdy_to_cpu
		--     (so the pulse is a real CPU advance — no en_gap desync on a VIC-badline stall).
		--     A fast fire is ALWAYS a cache HIT (rp_cache_hit) so it needs no SDRAM — that
		--     is why it may land off the prefetch cadence. Writes/misses (rp_cache_hit=0)
		--     fall to the MAIN path = 4-apart = safe.
		-- en_gap: clk32 since the last fire; reset on fire, saturating +1 otherwise.
		if INTERNAL_FAST_FIRE and supercpu_en = '1' then
			-- ── iter-27: internal-cycle fast-fire scheduler ──
			-- MAIN: every MEMORY cycle stays on the proven prefetch-tied pulse
			-- (cpu_cyc @ CPU0/4/8/C reserves SDRAM -> cpu_cyc_s(1) @ CPU2/6/A/E
			-- consumes after the full ~4-clk32 window). No memory access shortened.
			if cpu_cyc_s(1) = '1' then
				enableCpu <= '1';
				en_gap    <= (others => '0');
			-- FAST-INTERNAL: the PENDING cycle is internal (VDA=0 and VPA=0 => the
			-- W65C816 makes no valid memory access this cycle, data bus don't-care,
			-- proven by the SST garbage sweep). Advance 2-apart at an even CPU slot,
			-- en_gap>=2 (>=2 clk32 => honours C64.sdc:44 -setup 2 -to *P65C816*).
			-- Reads no SDRAM => no stale-latch class. baLoc + cpu816_rdy_to_cpu so
			-- the pulse is a real CPU advance (not a VIC-badline / not-ready stall).
			elsif vda_816 = '0' and vpa_816 = '0'
			      and scpu_force_1mhz = '0' and dma_active = '0'
			      and en_gap >= 2
			      and baLoc = '1' and cpu816_rdy_to_cpu = '1'
			      and ( sysCycle = CYCLE_CPU0 or sysCycle = CYCLE_CPU2
			            or sysCycle = CYCLE_CPU4 or sysCycle = CYCLE_CPU6
			            or sysCycle = CYCLE_CPU8 or sysCycle = CYCLE_CPUA
			            or sysCycle = CYCLE_CPUC or sysCycle = CYCLE_CPUE ) then
				enableCpu <= '1';
				en_gap    <= (others => '0');
			else
				enableCpu <= '0';
				if en_gap < 63 then en_gap <= en_gap + 1; end if;
			end if;
		elsif BANK00_FASTFIRE and supercpu_en = '1' then
			-- ── iter-31 step 6: authoritative bank-$00 BRAM fast-fire scheduler ──
			-- MAIN: the prefetch-tied pulse. With bank-$00 reads excluded from cpu_cyc
			-- above, cpu_cyc_s(1) now ONLY carries SuperRAM / bank-$00-write / io consumes
			-- => every real SDRAM access keeps its proven cpu_cyc(CPU0/4/8/C)->cpu_cyc_s(1)
			-- (+2 clk32) window. No en_gap guard needed here (cpu_cyc itself is throttled
			-- by busy_cnt="011"); every real consume must fire.
			if cpu_cyc_s(1) = '1' then
				enableCpu <= '1';
				en_gap    <= (others => '0');
			-- FAST: the pending cycle is a bank-$00 READ served by the on-chip BRAM
			-- (~1 clk64 MATCHED latency => no late-SDRAM-data di race, the death class).
			-- Advance 2-apart at an even CPU slot, en_gap>=2 (honours C64.sdc -setup 2
			-- -to *P65C816*). baLoc + cpu816_rdy_to_cpu => a real CPU advance (not a
			-- VIC-badline / not-ready stall). NOT CPUE (its +2 consume wraps into EXT).
			-- baLoc gate: shipped path stalls on VIC badlines (baLoc='0'). When
			-- BANK00_BADLINE_FAST, a bank-$00 BRAM read (no bus access) may advance
			-- through a badline, matching a real SuperCPU running from SRAM. cpu816_rdy
			-- still required (a genuine CPU-ready advance). Slots unchanged so CPU SDRAM
			-- accesses stay slot-separated from VIC fetches.
			elsif b00_fast_read = '1'
			      and en_gap >= 2
			      and (baLoc = '1' or BANK00_BADLINE_FAST) and cpu816_rdy_to_cpu = '1'
			      and ( sysCycle = CYCLE_CPU0 or sysCycle = CYCLE_CPU2
			            or sysCycle = CYCLE_CPU4 or sysCycle = CYCLE_CPU6
			            or sysCycle = CYCLE_CPU8 or sysCycle = CYCLE_CPUA
			            or sysCycle = CYCLE_CPUC ) then
				enableCpu <= '1';
				en_gap    <= (others => '0');
			else
				enableCpu <= '0';
				if en_gap < 63 then en_gap <= en_gap + 1; end if;
			end if;
		elsif not (ALT_FIRE_SAMELINE and CACHE_READ_PATH) or supercpu_en = '0' then
			enableCpu <= cpu_cyc_s(1);
			if cpu_cyc_s(1) = '1' then en_gap <= (others => '0');
			elsif en_gap < 63 then en_gap <= en_gap + 1; end if;
		elsif ( cpu_cyc_s(1) = '1' and en_gap >= 3 )                 -- MAIN (baseline cadence)
		      or ( scpu_fast_path = '1' and scpu_force_1mhz = '0' and dma_active = '0'
		           and en_gap >= 1 and rp_same_line = '1' and rp_cache_hit = '1'
		           and baLoc = '1' and cpu816_rdy_to_cpu = '1'
		           and ( sysCycle = CYCLE_CPU2 or sysCycle = CYCLE_CPU4
		                 or sysCycle = CYCLE_CPU6 or sysCycle = CYCLE_CPU8
		                 or sysCycle = CYCLE_CPUA or sysCycle = CYCLE_CPUC
		                 or sysCycle = CYCLE_CPUE ) ) then            -- FAST (2-apart cache hit)
			enableCpu <= '1';
			en_gap    <= (others => '0');
		else
			enableCpu <= '0';
			if en_gap < 63 then en_gap <= en_gap + 1; end if;
		end if;

		io_enable <= io_enable and not enableCpu;

		if sysCycle = CYCLE_EXT0 then
			io_enable <= '1';
		end if;

		-- 2 points to register DMA request before CPU cycles.
		if sysCycle = CYCLE_EXT1 or sysCycle = CYCLE_EXT5 then
			dma_active <= dma_req;
			turbo_en <= turbo_mode(0);
			turbo_m <= "000";
			if cs_io = '0' and dma_req = '0' then
				-- SCPU native mode is fast-by-default: force max turbo (4x). The
				-- stock 1MHz-timed KERNAL serial LOAD/SAVE routine only runs in
				-- EMULATION mode, so native turbo never desyncs the c1541. (A
				-- disk_access-gated emu+native turbo was tried 2026-05-29 and
				-- regressed LOAD -> $ED5A wedge, because emu-mode serial still ran
				-- at 4x.) Native software (Doom gameplay) never touches serial.
				-- scpu_force_1mhz ($D07A/$D072/cia2_throttle) still gates the turbo
				-- slots on top, and the cs_io guard keeps all I/O at 1MHz.
				if supercpu_en = '1' and emu_mode_816_i = '0' then
					turbo_m <= "111";
				elsif supercpu_en = '1' and emu_mode_816_i = '1'
					and scpu_speed_reg_written = '1' and scpu_speed_1mhz = '0' then
					-- SCPU emulation mode, software took speed control and asked
					-- for fast ($D07B): 4x. The speed-reg-written latch keeps the
					-- DEFAULT (Lorenz/BASIC/LOAD/Doom-loader, which never write
					-- $D07A/$D07B) at the OSD-default 1MHz so Lorenz stays 100%.
					-- emu_serial_throttle still forces 1MHz during KERNAL serial.
					turbo_m <= "111";
				elsif (turbo_mode(0) and turbo_state) = '1' or turbo_mode(1) = '1' then
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
	-- 2026-08-24 (14th pass): scratch var for call_depth_maxabs_r update
	variable call_depth_next : signed(15 downto 0);
	variable call_depth_mag  : unsigned(15 downto 0);
begin
	if rising_edge(clk32) then
		if reset = '1' then
			dbg_d018_r <= (others => '0');
			dbg_d016_r <= (others => '0');
			dbg_dd00_r <= (others => '0');
			dbg_d011_r <= (others => '0');
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
			dbg_scr_write_pc_r    <= (others => '0');
			dbg_scr_write_count_r <= (others => '0');
			scr_write_jsr_a_r     <= (others => '0');
			scr_write_jsr_b_r     <= (others => '0');
			trace_pc0_r          <= (others => '0');
			trace_pc1_r          <= (others => '0');
			trace_pc2_r          <= (others => '0');
			trace_pc3_r          <= (others => '0');
			trace_op0_r          <= (others => '0');
			trace_op1_r          <= (others => '0');
			trace_op2_r          <= (others => '0');
			trace_op3_r          <= (others => '0');
			trace_frozen_r       <= '0';
			trig_seen_r          <= '0';
			post_trig_cnt_r      <= (others => '0');
			trace_pc4_r          <= (others => '0');
			trace_pc5_r          <= (others => '0');
			trace_op4_r          <= (others => '0');
			trace_op5_r          <= (others => '0');
			trace_pc6_r          <= (others => '0');
			trace_pc7_r          <= (others => '0');
			trace_op6_r          <= (others => '0');
			trace_op7_r          <= (others => '0');
			-- v250: skip first 32 STA $DF01 writes so trace ring captures
			-- steady-state IRQ-handler call chain, not the loader's
			-- one-shot setup writes.
			trigger_skip_r       <= to_unsigned(32, 8);
			scpu_iclr_r          <= '0';
			irq_vec_count_r      <= (others => '0');
			min_p_r              <= x"FF";
			rti_count_r          <= (others => '0');
			nmi_vec_count_r      <= (others => '0');
			call_depth_r         <= (others => '0');
			call_depth_maxabs_r  <= (others => '0');
			vecfetch_addr_r      <= (others => '0');
			jmlvec_hi_r          <= (others => '0');
			jmlvec_bank_r        <= (others => '0');
			last_07b9_read_r     <= (others => '0');
			loader_armed_r       <= '0';
			d019_wr_count_r      <= (others => '0');
			dc0d_rd_count_r      <= (others => '0');
			dc0d_wr_count_r      <= (others => '0');
			irq_combined_d       <= '1';
			irq_fall_count_r     <= (others => '0');
			irq_cia1_d           <= '1';
			irq_cia1_fall_count_r <= (others => '0');
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
			wr90_F7_pc_r         <= (others => '0');
			wr90_F7_count_r      <= (others => '0');
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
			rd07xx_addr_r        <= (others => '0');     -- doom-wait probe
			rd07xx_data_r        <= (others => '0');
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
				elsif cpuAddr(5 downto 0) = "010001" then
					dbg_d011_r <= std_logic_vector(cpuDo);
				end if;
			end if;

			-- 31st pass: screen-RAM write observer (bank $00 $0400-$07E7).
			-- Independent of cs_vic -- this is a plain RAM write, not a
			-- register write, so it needs its own address-range check.
			-- Gated on loader_armed_r so boot-time BASIC/KERNAL screen
			-- writes (before the loader even starts) don't pollute the
			-- count; gated on bank $00 (addr_hi_816) so a native-mode
			-- write to some OTHER bank's $xx:04xx-$xx:07E7 doesn't
			-- falsely count as a screen write.
			if loader_armed_r = '1' and cpuWe = '1'
			   and (supercpu_en = '0' or addr_hi_816 = x"00")
			   and cpuAddr >= x"0400" and cpuAddr <= x"07E7" then
				dbg_scr_write_pc_r <= cpu_pc_now;
				if unsigned(dbg_scr_write_count_r) /= x"FF" then
					dbg_scr_write_count_r <= std_logic_vector(unsigned(dbg_scr_write_count_r) + 1);
				end if;
				-- 33rd pass: snapshot the JSR ring's 2 newest entries (their
				-- pre-this-edge values) so the LAST real screen write's call
				-- context survives even though the ring itself keeps moving.
				scr_write_jsr_a_r <= jsr_pc_t3_r;
				scr_write_jsr_b_r <= jsr_pc_t2_r;
			end if;

			-- v219: opcode-fetch throughput counter. Free-running 24-bit;
			-- consumer subtracts samples to get opcodes/frame.
			if opcode_fetch_pulse = '1' then
				op_count_r <= op_count_r + 1;
			end if;

			-- 34th pass (Wolf3D freeze, 2026-08-26): always-live current
			-- opcode byte, paired with the already-live cpu_pc (dbg PC:
			-- field) so repeated UART sampling of a stuck loop lets the
			-- opcode at each visited PC be reconstructed offline without
			-- needing a dedicated memory-range dump. See
			-- project_wolf3d_postreu_bank28_freeze_regression.md 33rd/34th
			-- pass notes -- the live PC was found parked in a tight bank-$00
			-- loop ($0AC3-$0B10) unrelated to the historical bank-$28 trace
			-- ring capture, and this loop isn't part of wolf3d_loader.prg
			-- (confirmed by reading the file: it only spans $0801-$08FD).
			if opcode_fetch_pulse = '1' then
				cur_op_r <= std_logic_vector(cpuDi);
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
				-- 2026-05-09 doom-wait probe: latch reads in $00:$0700-$07FF
				-- (Doom main thread polls $00:$0707+X here per
				-- project_doom_wait_loop_at_41db9a.md).
				-- Bank gate: when supercpu_en='0' addr_hi_816 isn't meaningful
				-- so only gate in SCPU mode.
				if cpuAddr_pre(15 downto 8) = x"07"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					rd07xx_addr_r <= std_logic_vector(cpuAddr_pre(7 downto 0));
					rd07xx_data_r <= std_logic_vector(cpuDi);
					-- v307: per-address READ snapshots surfaced via wr5C ring.
					-- v309 (2026-05-12): back to $0705..$0708 (the BRK area).
					-- v308 already captured $0709-$070C = 00 8D 0A DF
					-- (STA $DF0A — REU register write). Now the focus is
					-- WHO targets $0705: is it the BRK vector? Companion
					-- change below surfaces scpu_native_vec(2)/(3) via UART
					-- to confirm BRK→$0705 vector install.
					case cpuAddr_pre(7 downto 0) is
						when x"05" => wr5C_v0_r <= std_logic_vector(cpuDi);
						when x"06" => wr5C_v1_r <= std_logic_vector(cpuDi);
						when x"07" => wr5C_v2_r <= std_logic_vector(cpuDi);
						when x"08" => wr5C_v3_r <= std_logic_vector(cpuDi);
						when others => null;
					end case;
				end if;
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
				-- v295: in SCPU mode the split is now PB-based, NOT
				-- I-flag-based. Recompiled Doom code lives in banks $20+;
				-- bank $00 holds bootstrap + IRQ ack stub ($FF00) + native
				-- vector intercepts. The previous I-flag gate
				-- (cpu_p_now(2) = '0') was blind to recompiler code that
				-- runs SEI'd between dispatches — pc_main_r appeared frozen
				-- at the first I=0 fetch even when main was actually
				-- advancing. PB != $00 catches every main-bank fetch
				-- regardless of I bit.
				--
				-- In T65 mode cpu_pc_now upper bits are forced to $00
				-- (T65 has no bank register), so the PB-based criterion
				-- would route every T65 fetch to pc_irq_r. Keep the
				-- original I-flag split for T65 to preserve prior debug
				-- behavior.
				if opcode_fetch_pulse = '1' then
					if (supercpu_en = '1' and cpu_pc_now(23 downto 16) /= x"00")
					   or (supercpu_en = '0' and cpu_p_now(2) = '0') then
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
				-- 2026-08-24 Wolf3D bank-$28-freeze probe: HW-vs-VICE byte
				-- compare at the $0AC0-$0B10 trampoline/scatter routine
				-- (REU-DMA-installed, not part of loader.prg's own bytes).
				-- VICE reference values (known-good, from wolf3d_vice_probe.py
				-- snapshot): 0AC0=$97 0AC8=$A0 0AD0=$00 0AE0=$97 0AF0=$17
				-- 0B00=$FF 0B10=$20. See
				-- project_wolf3d_postreu_bank28_freeze_regression.md.
				-- (Supersedes the prior Asterix $0300-$4000 round-2 probe.)
				if cpuAddr_pre = x"0AC0" then mem_80_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0AC8" then mem_81_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0AD0" then mem_82_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0AE0" then mem_83_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0AF0" then mem_84_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0B00" then mem_85_r <= std_logic_vector(cpuDi); end if;
				if cpuAddr_pre = x"0B10" then mem_86_r <= std_logic_vector(cpuDi); end if;
				-- 2026-08-24 Wolf3D write-attribution bitmaps (repurposing the
				-- dead $0087/$0088 value-snoop, freed since v254's JSR ring
				-- replaced the row that used to display them). Post-mux
				-- cpuAddr/cpuWe (NOT the _pre variants) so a REU-FETCH write
				-- is visible here: dma_active='1' means cpuAddr/cpuWe were
				-- overridden with dma_addr/dma_we (fpga64:4133-4135). Bit N
				-- set = checkpoint N (same 7 addresses/order as the ZP= grid:
				-- $0AC0,$0AC8,$0AD0,$0AE0,$0AF0,$0B00,$0B10) was EVER written
				-- by that source this run. mem_87=DMA-sourced, mem_88=CPU-
				-- store-sourced. See
				-- project_wolf3d_postreu_bank28_freeze_regression.md.
				if cpuWe = '1' then
					if cpuAddr = x"0AC0" then
						if dma_active = '1' then mem_87_r(0) <= '1'; else mem_88_r(0) <= '1'; end if;
					end if;
					if cpuAddr = x"0AC8" then
						if dma_active = '1' then mem_87_r(1) <= '1'; else mem_88_r(1) <= '1'; end if;
					end if;
					if cpuAddr = x"0AD0" then
						if dma_active = '1' then mem_87_r(2) <= '1'; else mem_88_r(2) <= '1'; end if;
					end if;
					if cpuAddr = x"0AE0" then
						if dma_active = '1' then mem_87_r(3) <= '1'; else mem_88_r(3) <= '1'; end if;
					end if;
					if cpuAddr = x"0AF0" then
						if dma_active = '1' then mem_87_r(4) <= '1'; else mem_88_r(4) <= '1'; end if;
					end if;
					if cpuAddr = x"0B00" then
						if dma_active = '1' then mem_87_r(5) <= '1'; else mem_88_r(5) <= '1'; end if;
					end if;
					if cpuAddr = x"0B10" then
						if dma_active = '1' then mem_87_r(6) <= '1'; else mem_88_r(6) <= '1'; end if;
					end if;
				end if;
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
				-- 41st pass: write-bus-gated snoop of $2906 (Wolf3D
				-- freeze) -- direct proof of whether it's ever written
				-- anywhere, replacing the fragile code-position guessing
				-- used in the 36th-39th passes. cnt saturates at $FF;
				-- 0 = never written during the capture window.
				if cpuAddr_pre = x"2906"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					if wloop_w2906_cnt_r /= x"FF" then
						wloop_w2906_cnt_r <= std_logic_vector(unsigned(wloop_w2906_cnt_r) + 1);
					end if;
					wloop_w2906_val_r <= std_logic_vector(cpuDo_pre);
				end if;
				-- 44th pass: same write-bus-gated technique applied to
				-- the two step-table deltas the 43rd pass proved read
				-- back frozen at $00 -- direct proof of whether the
				-- loader ever writes them at all.
				if cpuAddr_pre = x"292E"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					if wloop_w292e_cnt_r /= x"FF" then
						wloop_w292e_cnt_r <= std_logic_vector(unsigned(wloop_w292e_cnt_r) + 1);
					end if;
					wloop_w292e_val_r <= std_logic_vector(cpuDo_pre);
				end if;
				if cpuAddr_pre = x"2930"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					if wloop_w2930_cnt_r /= x"FF" then
						wloop_w2930_cnt_r <= std_logic_vector(unsigned(wloop_w2930_cnt_r) + 1);
					end if;
					wloop_w2930_val_r <= std_logic_vector(cpuDo_pre);
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
				-- v291 — refine v290 writer-PC capture by gating on PBR=$2C.
				-- v290 result: ALL-PBR last writer was $2B:$245C with count
				-- 245 — a noisy generic Doom state-machine (NOT music_num).
				-- Refined PBR=$2C filter answers: do the literal-load sites
				-- $2C:$5D78 / $2C:$712C ever fire? If yes, mem_40/44/5C holds
				-- writer PC ≈ $2C:$5D7B or $2C:$712F. If count (B:) = 0, the
				-- literal-load is dead code on this run; music_num=-9 must
				-- arrive at print via a different bank ($86? printf via
				-- [$88]+$0C indirect from a different banked routine?).
				-- v292 — capture writer-PC of last STORE to $00:$00FC with
				-- value $5C (LO byte of $A95C trap). VICE Doom oracle proves
				-- divergence: VICE Doom runs past, hardware halts at $2C:$A95C
				-- via JML[$74]. The dispatcher trampoline does
				-- `LDA $FC; STA $74; LDA $FE; STA $76; JML [$74]`, so the
				-- WRONG value arrives via earlier `STA $FC` from an upstream
				-- handler. Catch that store to pinpoint the buggy code path.
				-- doom.reu has NO `LDA #$A95C` literal, so the value $A95C
				-- must come from a table lookup or computation.
				-- Filter: $FC writes with value=$5C (LO byte). On halt-cycle
				-- the LO half of dispatch ptr is $5C ($A95C low byte).
				if addr_hi_816 = x"00" and cpuAddr_pre = x"00FC"
				   and cpuDo_pre = x"5C" then
					wr90_F7_pc_r    <= cpu_pc_now;
					wr90_F7_count_r <= wr90_F7_count_r + 1;
					mem_40_r        <= cpu_pc_now(7 downto 0);
					mem_44_r        <= cpu_pc_now(15 downto 8);
					mem_5C_r        <= cpu_pc_now(23 downto 16);
					mem_45_r        <= std_logic_vector(wr90_F7_count_r + 1);
				end if;
				-- v293 doom triage: REPURPOSE wr02_* from old $00:$6C00..$6C07
				-- BRK-loop region (resolved by v286 RTI sink) to ALL writes
				-- of bank $00:$00FC — the JML [$0074] dispatcher LO byte.
				-- v292 already captured the $5C-filtered writer (88 firings,
				-- writer = LOADER $00:$077D); this UNFILTERED ring + count +
				-- value trail tells us whether Doom EVER overwrites $00FC
				-- with a non-$5C value on hardware (VICE oracle proves it
				-- does on x64sc — divergence is HW-only). UART fields:
				--   V:  ring of last 4 values written to $00:$00FC
				--   YX: Y/X at most recent write
				--   WP: writer-PC (PBR:PC) of most recent write
				--   CG: count of writes where new value ≠ previous
				--   CY: total writes
				-- If hardware shows CY = 88 (matching v292's $5C count) and
				-- CG = 1 (only the very first write was a "change"), then
				-- the loader's 88×$5C writes are the ONLY writes Doom ever
				-- makes to $00:$00FC on hardware — bug is "missing Doom
				-- overwrite". If CY > 88 or CG > 1, hardware DOES write
				-- non-$5C values and the V ring shows what they are.
				-- v320 (2026-05-12): write-side filter REMOVED.
				-- The wr02_* ring is now driven by a READ-side filter
				-- placed OUTSIDE this `enableCpu='1' and cpuWe='1'` block
				-- (see new block after line 3224 end-if). Reasoning: a
				-- $F7 write filter inside the write-gate cannot detect
				-- READS, and v319 results showed write-side captures
				-- were dominated by recompiler JIT output to bank $5C
				-- (too noisy). Read-side filter is more targeted.
				if cpuAddr_pre = x"0003" then
					wr03_pc_r  <= cpu_pc_now;
					wr03_val_r <= std_logic_vector(cpuDo_pre);
				end if;
				-- v303 (2026-05-12) Doom JIT-scratchpad probe — REPURPOSED
				-- from v262 $005C ring. VICE xscpu64 oracle (snapshot run
				-- 2026-05-10) proves $00:$0700-$07FF is the recompiler's
				-- JIT scratchpad in bank $2B (continuously overwritten
				-- with new SCPU code). Hardware reads $00 at $0706 when
				-- the wedge sets in — either recompiler emits $00 there
				-- or our SCPU long-store path from bank $2B → bank $00
				-- drops bytes. This capture answers:
				--   N5 = total writes to $00:$0706 (if 0 on hardware:
				--     recompiler never targets that addr — different
				--     codegen than VICE; if >0: writes happen, but…)
				--   W5 ring = last 4 byte values written there (if all
				--     $00: writes are $00, recompiler-emitted; if non-
				--     zero values but readback is $00: HW path drops).
				-- Bank-gated so SuperRAM writes at other-bank:$0706 do
				-- not pollute the count.
				-- v304 (2026-05-12): v303 CPU-only result = 405 writes of
				-- uniform $05 over 90s, but readback shows $00. CPU bus
				-- writes alone can't explain the corruption. New probe
				-- block below (outside enableCpu gate) ALSO captures REU
				-- DMA writes (dma_active='1' overrides cpuAddr/cpuDo/cpuWe
				-- with dma_addr/dma_dout/dma_we). If REU FETCH destination
				-- ever overlaps $0700-$07BA, those writes were invisible
				-- to v303 and would corrupt the dispatcher bytes.
				-- v306 (2026-05-12): widen W5 ring to capture writes across the
				-- full recompiler scratchpad $00:$0700-$070F. Repurpose
				-- cnt_wr5C as a 16-bit "addresses-written" bitmap (bit N set =
				-- $070N was written at least once by CPU). This will reveal
				-- whether the recompiler EVER writes $0705 (where the wedge's
				-- BRK opcode $00 sits per the v305 capture).
				-- v307 (2026-05-12): wr5C_v0..v3 ring REPURPOSED to READ-side
				-- snapshots at $0705/$0706/$0707/$0708 (updated in the read
				-- block above). The bitmap update below stays — bit N still
				-- set on any write to $070N — but no value-ring update here.
				if addr_hi_816 = x"00" and cpuAddr_pre(15 downto 4) = x"070" then
					case cpuAddr_pre(3 downto 0) is
						when x"0" => cnt_wr5C_r(0)  <= '1';
						when x"1" => cnt_wr5C_r(1)  <= '1';
						when x"2" => cnt_wr5C_r(2)  <= '1';
						when x"3" => cnt_wr5C_r(3)  <= '1';
						when x"4" => cnt_wr5C_r(4)  <= '1';
						when x"5" => cnt_wr5C_r(5)  <= '1';
						when x"6" => cnt_wr5C_r(6)  <= '1';
						when x"7" => cnt_wr5C_r(7)  <= '1';
						when x"8" => cnt_wr5C_r(8)  <= '1';
						when x"9" => cnt_wr5C_r(9)  <= '1';
						when x"A" => cnt_wr5C_r(10) <= '1';
						when x"B" => cnt_wr5C_r(11) <= '1';
						when x"C" => cnt_wr5C_r(12) <= '1';
						when x"D" => cnt_wr5C_r(13) <= '1';
						when x"E" => cnt_wr5C_r(14) <= '1';
						when x"F" => cnt_wr5C_r(15) <= '1';
						when others => null;
					end case;
				end if;
			end if;
			-- v340b (2026-05-13): capture $1D02-$1D05 data bytes that the
			-- $0EED wedge loop polls. VICE disassembly of $0EED:
			--   $0EED  AD 02 1D    LDA $1D02      (M=16, reads $1D02+$1D03)
			--   $0EF0  CD 04 1D    CMP $1D04      (reads $1D04+$1D05)
			--   $0EF3  D0 F8       BNE $0EED
			-- VICE at the BP: $1D02 = $1D04 = $01 → BNE not taken → loop
			-- falls through and Doom progresses. On HW the loop wedges
			-- forever, so $1D02 ≠ $1D04 on HW. This probe captures the
			-- actual bytes.
			--
			-- Filter: bank-$00 READ of $1D02/$1D03/$1D04/$1D05. Each
			-- address latches cpuDi into a fixed slot:
			--   $1D02 → V0  (LDA $1D02 LO byte)
			--   $1D03 → V1  (LDA $1D02 HI byte — A high)
			--   $1D04 → V2  (CMP $1D04 LO byte)
			--   $1D05 → V3  (CMP $1D04 HI byte)
			-- Also latch $1D00 → Y, $1D01 → X for context (the byte just
			-- before $1D02). WP holds PC at most recent fire. CY counts
			-- total fires (huge if loop is hot).
			-- Plan: C:\Users\Caldor\.claude\plans\nifty-swinging-pearl.md
			-- v340f (2026-05-14): capture VIC display registers to debug
			-- post-$0EED-fix black screen. v340e cleared $0EED wedge, Doom
			-- now reaches gameplay state (CPU healthy, IRQ chain firing) but
			-- screen renders all-black. VICE at the same code location loops
			-- through $0F:F1DA + sister addresses too, so foreground isn't
			-- wedged. Hypothesis: VIC mode/pointer/color state differs from
			-- VICE — e.g., $D011 display-enable bit clear, $D018 wrong
			-- screen/bitmap pointer, or $D020/$D021 forcing black.
			-- Filter all writes to: $00:$D011 ctrl1, $D016 ctrl2, $D018
			-- mem ptrs, $D020 border, $D021 bg. Last value per addr → slot.
			-- v340l (2026-05-14): per-LO-nibble cum-OR with bit-7 marker.
			-- v340j was ambiguous: V1/V2/V3/Y/X = $00 could mean either
			-- "fetch fired with cpuDi=$00" (JIT corruption) or "fetch never
			-- fired" (operand fetch never reaches that byte on HW).
			-- Disambiguator: cum-OR cpuDi with $80 marker. If V3 = $00, the
			-- $D case never fired (operand fetch never reaches byte 3). If
			-- V3 = $80, fired but byte was $00. If V3 = $86, fired with $06.
			-- V0 keeps latch semantics (already confirms $1F captured).
			-- v355 (2026-05-19): probe live read values at $00:$3706-$370B.
			-- v354 confirmed handler at $00:$2200-$220B =
			--   SEP #$20; LDA $3706; STA $3704; BEQ +7; LDA #$00; ...
			-- Handler dispatches on byte at $00:$3706. In wedge state $3706
			-- presumably stays non-zero (handler never reaches BEQ-taken).
			-- Capture live values at each $370x read so we can see what
			-- dispatch byte the handler sees. V0..V5 = bytes at addresses
			-- $3706, $3707, $3708, $3709, $370A, $370B (low nibble decides
			-- which V slot is latched).
			if enableCpu = '1' and cpuWe_pre = '0' and addr_hi_816 = x"00"
			   and cpuAddr_pre(15 downto 4) = x"370" then
				cnt_wr02_r <= cnt_wr02_r + 1;
				wr02_pc_r  <= cpu_pc_now;
				case cpuAddr_pre(3 downto 0) is
					when x"6" => wr02_v0_r <= std_logic_vector(cpuDi);
					when x"7" => wr02_v1_r <= std_logic_vector(cpuDi);
					when x"8" => wr02_v2_r <= std_logic_vector(cpuDi);
					when x"9" => wr02_v3_r <= std_logic_vector(cpuDi);
					when x"A" => wr02_y_r  <= std_logic_vector(cpuDi);
					when x"B" => wr02_x_r  <= std_logic_vector(cpuDi);
					when others => null;
				end case;
			end if;
			-- v340n (2026-05-14): v304 DMA-side $0706 overload REMOVED.
			-- VW/AC counters now exclusively track the original VIC ack
			-- pulses (vic_d019_wr_pulse / vic_resetraster_pulse) again so
			-- we can diagnose whether SCPU's $D019 ack writes actually
			-- pulse myWr_a inside the VIC and whether resetRasterIrq
			-- fires. If VW >> AC, SCPU writes reach myWr_a but IRST isn't
			-- being cleared (the suspected bug at video_vicII_656x.vhd:77).
			-- If VW stays 0 while Doom keeps stuck on ORA at $F1DA, the
			-- writes never reach myWr_a (timing / bus phase issue).
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

			-- 2026-08-24 Wolf3D wild-jump investigation: call-depth
			-- drift. $20=JSR, $22=JSL, $60=RTS, $6B=RTL.
			-- 15th pass: call_depth_maxabs_r saturated at $F by t=5s
			-- in HW (before loader.prg's SEI even runs) -- ordinary
			-- KERNAL/BASIC boot nesting alone exceeds 15 levels, so a
			-- "since reset" counter is uninformative for this bug.
			-- Rezero both counters the moment PC reaches loader.prg's
			-- relocated entry point ($00:0700, confirmed from the
			-- disassembly in the 11th-pass memory update) so depth is
			-- measured from the loader taking over, not from boot.
			if opcode_fetch_pulse = '1' then
				if cpu_pc_now = x"000700" then
					call_depth_r        <= (others => '0');
					call_depth_maxabs_r <= (others => '0');
				else
					call_depth_next := call_depth_r;
					if cpuDi = x"20" or cpuDi = x"22" then
						call_depth_next := call_depth_r + 1;
					elsif cpuDi = x"60" or cpuDi = x"6B" then
						call_depth_next := call_depth_r - 1;
					end if;
					call_depth_r <= call_depth_next;
					-- 14th pass: saturating (never-decrementing)
					-- magnitude tracker -- see declaration comment.
					if call_depth_next(15) = '1' then
						call_depth_mag := unsigned(-call_depth_next);
					else
						call_depth_mag := unsigned(call_depth_next);
					end if;
					if call_depth_mag > 15 then
						call_depth_maxabs_r <= x"F";
					elsif call_depth_mag(3 downto 0) > call_depth_maxabs_r then
						call_depth_maxabs_r <= call_depth_mag(3 downto 0);
					end if;
				end if;
			end if;

			-- 15th pass: direct vector-fetch capture (see vecfetch_addr_r
			-- declaration comment). Rezeroed on the same $0700 loader-entry
			-- trigger as call_depth; latched independently of
			-- opcode_fetch_pulse since VPB asserts during the address-bus
			-- phase of interrupt entry, not an opcode fetch.
			if opcode_fetch_pulse = '1' and cpu_pc_now = x"000700" then
				vecfetch_addr_r <= (others => '0');
			elsif supercpu_en = '1' and dbg_vpb_816_i = '0' then
				vecfetch_addr_r <= std_logic_vector(cpu816_addr_raw);
			end if;

			-- 18th pass: snoop the actual bytes the CPU reads at $04FD/$04FE
			-- (the hi-byte and bank-byte of loader.prg's JML ($04FC) exit
			-- vector). VICE ground truth for this exact loader+REU pairing
			-- reads 00 20 there (target $20:0000, same convention as Doom's
			-- JML $20:0000) and boots cleanly -- see
			-- project_wolf3d_postreu_bank28_freeze_regression.md 18th-pass
			-- update. If HW reads something else here, the REU/SuperRAM
			-- write path for the skip-flag table is corrupting data; if it
			-- matches, the bug is downstream of the JML itself. Rezeroed on
			-- the same $0700 entry trigger as vecfetch_addr/call_depth.
			if opcode_fetch_pulse = '1' and cpu_pc_now = x"000700" then
				jmlvec_hi_r   <= (others => '0');
				jmlvec_bank_r <= (others => '0');
			elsif supercpu_en = '1' and cpu816_we_raw = '0' and cpu816_vda_raw = '1' then
				if cpu816_addr_raw = x"04FD" then
					jmlvec_hi_r <= std_logic_vector(cpu816_di_to_cpu);
				elsif cpu816_addr_raw = x"04FE" then
					jmlvec_bank_r <= std_logic_vector(cpu816_di_to_cpu);
				end if;
			end if;

			-- 19th pass: snoop the value of C64 RAM $07B9 (the skip-table's
			-- REU source mid-byte, per the loader.prg disassembly) each
			-- time the CPU reads it, to disambiguate the jmlvec divergence:
			-- if this settles near $FF (a near-complete 256-bank sweep),
			-- HW believes it read the same REU offset VICE did and the
			-- delivered DATA was wrong (REU-FETCH data-integrity bug); if
			-- it settles far from $FF, HW's own loop terminated after a
			-- different number of iterations than VICE's (a control-flow/
			-- cycle-count divergence). See jmlvec_hi_r comment and
			-- project_wolf3d_postreu_bank28_freeze_regression.md 19th-pass
			-- update. Rezeroed on the same $0700 entry trigger.
			if opcode_fetch_pulse = '1' and cpu_pc_now = x"000700" then
				last_07b9_read_r <= (others => '0');
				loader_armed_r   <= '1';
			elsif supercpu_en = '1' and cpu816_we_raw = '0' and cpu816_vda_raw = '1'
					and cpu816_addr_raw = x"07B9" then
				last_07b9_read_r <= std_logic_vector(cpu816_di_to_cpu);
			end if;

			-- 20th pass: latch trig_seen_r the first time an OPCODE FETCH
			-- (not a data read) lands outside loader.prg's own
			-- $0700-$07DB code footprint, once armed. 29th pass: renamed
			-- from directly setting trace_frozen_r -- the actual freeze
			-- is now deferred 2 more opcode fetches (see the post-trigger
			-- ring-shift block below) so trace_pc4/pc5 can capture what
			-- happens right after the landing PC. trace_pc3_r/op3_r still
			-- capture this exact triggering fetch unchanged, since this
			-- block and the ring-shift block both read the OLD (pre-edge)
			-- value of trig_seen_r/trace_frozen_r within the same cycle.
			-- 30th pass (2026-08-25): retargeted from "bank $00 past the
			-- loader footprint" (26th-29th passes: caught an unrelated,
			-- apparently-benign bank-$0C->bank-$00 hop, 2 fetches past
			-- landing showed ordinary LDA/STA/LDA dp code) to "first
			-- opcode fetch in bank $28 after arming" -- bank $28 is the
			-- ORIGINALLY-reported hang bank ($28:$3BB6, 12th-pass era)
			-- that this whole 20-pass trace-ring lineage has never once
			-- observed. If this never fires, P4/P5 stay all-zero, which
			-- itself is the answer: bank $28 is not reached at all in
			-- the current HEAD run.
			if trig_seen_r = '0' and loader_armed_r = '1'
			   and opcode_fetch_pulse = '1'
			   and cpu_pc_now(23 downto 16) = x"28" then
				trig_seen_r <= '1';
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
			-- v13 (2026-05-24): $DC0D write count. If MCP without bus_we
			-- gating causes phantom IMR-clears, this counts the spurious
			-- write cycles. With the gating fix in place, this should match
			-- passthrough's $DC0D write rate.
			if cs_cia1 = '1' and cpuWe = '1' and cpuAddr(3 downto 0) = "1101" then
				dc0d_wr_count_r <= dc0d_wr_count_r + 1;
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
			-- v12 (2026-05-24): CIA1-only falling-edge count for MCP probe.
			-- Differential vs irq_fall_count_r tells us whether MCP wedge
			-- affects CIA1 IRQ generation or only the downstream AND.
			irq_cia1_d <= irq_cia1;
			if irq_cia1_d = '1' and irq_cia1 = '0' then
				irq_cia1_fall_count_r <= irq_cia1_fall_count_r + 1;
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
			-- 29th pass: once trig_seen_r is set (from the SAME cycle
			-- onward -- trig_seen_r reads as the OLD value here, so the
			-- triggering fetch itself still falls into the pre-trigger
			-- branch and lands in trace_pc3/op3 exactly as before), stop
			-- shifting pc0..pc3 and instead capture the next 2 opcode
			-- fetches into pc4/pc5, then finally latch trace_frozen_r.
			if trace_frozen_r = '0' and opcode_fetch_pulse = '1' then
				if trig_seen_r = '0' then
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
				elsif post_trig_cnt_r = 0 then
					trace_pc4_r     <= cpu_pc_now;
					trace_op4_r     <= std_logic_vector(cpuDi);
					post_trig_cnt_r <= to_unsigned(1, 2);
				elsif post_trig_cnt_r = 1 then
					trace_pc5_r     <= cpu_pc_now;
					trace_op5_r     <= std_logic_vector(cpuDi);
					post_trig_cnt_r <= to_unsigned(2, 2);
				elsif post_trig_cnt_r = 2 then
					trace_pc6_r     <= cpu_pc_now;
					trace_op6_r     <= std_logic_vector(cpuDi);
					post_trig_cnt_r <= to_unsigned(3, 2);
				elsif post_trig_cnt_r = 3 then
					trace_pc7_r     <= cpu_pc_now;
					trace_op7_r     <= std_logic_vector(cpuDi);
					trace_frozen_r  <= '1';
				end if;
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
				-- 36th pass: Wolf3D $0AC3-$0B0F copy-loop compare-operand
				-- snoops. These are static bank-$00 CODE bytes (the
				-- embedded absolute-address operands of the loop's
				-- LDA $0AC6/SBC $0AC9/LDX $0AD6 instructions), read as
				-- data during the CPU's own operand-fetch cycles — no
				-- separate memory-read mechanism needed. Gate to bank
				-- $00 so no other bank's code shadows these addresses.
				if cpuAddr_pre = x"0AC7"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_lda_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AC8"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_lda_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0ACA"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sbc_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0ACB"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sbc_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AD7"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_ldx_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AD8"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_ldx_hi_r <= std_logic_vector(cpuDi);
				end if;
				-- 37th pass: runtime values at the loop's compare/index
				-- addresses (the CPU already reads these every
				-- iteration via LDA $2906/SBC $4903/LDX $F634).
				if cpuAddr_pre = x"2906"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_val_2906_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"4903"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_val_4903_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"F634"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_val_f634_r <= std_logic_vector(cpuDi);
				end if;
				-- 38th pass: STA abs operand-address bytes ($0AF6's
				-- operand at $0AF7/$0AF8, $0AFF's at $0B00/$0B01,
				-- $0B0E's at $0B0F/$0B10). Operand bytes are fetched
				-- as reads regardless of the instruction being a store.
				if cpuAddr_pre = x"0AF7"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sta1_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF8"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sta1_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B00"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sta2_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B01"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sta2_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B0F"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sta3_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B10"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_sta3_hi_r <= std_logic_vector(cpuDi);
				end if;
				-- 39th pass: operand-address bytes of INC $0AEC / LDA
				-- $0AEE / LDA $0AF0 / ADC $0AF3 (the arithmetic feeding
				-- the always-zero result stored to $2906).
				if cpuAddr_pre = x"0AED"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_inc_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AEE"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_inc_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AEF"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_lda1_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF0"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_lda1_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF1"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_lda2_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF2"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_lda2_hi_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF4"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_adc_lo_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF5"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_adc_hi_r <= std_logic_vector(cpuDi);
				end if;
				-- 40th pass: raw code-byte dump at $0AEC-$0AF8 (13 bytes)
				-- to hand-disassemble the real instruction stream after
				-- the 39th pass's fixed-offset operand guesses turned
				-- out inconsistent with the true boundaries.
				if cpuAddr_pre = x"0AEC"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb0_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AED"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb1_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AEE"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb2_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AEF"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb3_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF0"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb4_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF1"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb5_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF2"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb6_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF3"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb7_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF4"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb8_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF5"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb9_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF6"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb10_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF7"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb11_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AF8"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb12_r <= std_logic_vector(cpuDi);
				end if;
				-- 42nd pass: raw code-byte dump at $0AF9-$0B10 (24 bytes),
				-- continuing the 40th pass's ground-truth dump forward to
				-- locate the real STA $2906.
				if cpuAddr_pre = x"0AF9"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb13_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AFA"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb14_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AFB"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb15_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AFC"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb16_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AFD"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb17_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AFE"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb18_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0AFF"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb19_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B00"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb20_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B01"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb21_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B02"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb22_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B03"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb23_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B04"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb24_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B05"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb25_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B06"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb26_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B07"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb27_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B08"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb28_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B09"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb29_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B0A"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb30_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B0B"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb31_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B0C"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb32_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B0D"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb33_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B0E"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb34_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B0F"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb35_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"0B10"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_rb36_r <= std_logic_vector(cpuDi);
				end if;
				-- 43rd pass: steady-state read snoop of the two
				-- ADC operands ($292E/$2930) the 42nd pass's
				-- disasm showed feeding the frozen $2906 STA.
				if cpuAddr_pre = x"292E"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_d292e_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"2930"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					wloop_d2930_r <= std_logic_vector(cpuDi);
				end if;
				-- v341 doom bitmap probe: latch reads of $00:$1D02/$1D04
				-- (page-flip handshake). Gate to bank $00 in SCPU mode so
				-- bank-$XX:$1D02 in JIT code doesn't shadow these.
				if cpuAddr_pre = x"1D02"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					mem_1d02_r <= std_logic_vector(cpuDi);
				end if;
				if cpuAddr_pre = x"1D04"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					mem_1d04_r <= std_logic_vector(cpuDi);
				end if;
			end if;
			-- v341: also latch writes (Doom both reads and writes these).
			if enableCpu = '1' and cpuWe_pre = '1' then
				if cpuAddr_pre = x"1D02"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					mem_1d02_r <= std_logic_vector(cpuDo_pre);
				end if;
				if cpuAddr_pre = x"1D04"
				   and (supercpu_en = '0' or addr_hi_816 = x"00") then
					mem_1d04_r <= std_logic_vector(cpuDo_pre);
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
dbg_d011        <= dbg_d011_r;
dbg_raster_line <= std_logic_vector(dbg_raster_y);
-- v341 doom bitmap probe
dbg_mem_1d02    <= mem_1d02_r;
dbg_mem_1d04    <= mem_1d04_r;
-- v346 doom bitmap-content probe — sticky OR of vicDi over previous frame
dbg_vic_di_or   <= std_logic_vector(vic_di_or_lat);
-- Milestone B (2026-05-25): bridge-internal UART probes — direct pass-through
-- from scpu_async_bridge_inst (still in clk_cpu domain). c64.sv re-syncs into
-- clk_sys via 2-FF chains before driving the dbg_pool / UART formatter.
dbg_bridge_fsm_state       <= std_logic_vector(cpu816_dbg_fsm_state);
dbg_bridge_last_bus_di     <= std_logic_vector(cpu816_dbg_last_bus_di);
-- iter-17 DIAGNOSTIC: when CACHE_READ_PATH (diag build), repurpose the
-- passthrough-INERT Milestone-B bridge-probe UART fields to carry the cache-hit
-- divergence detector results: RQ=first-mismatch addr, AK={cache:sdram} bytes,
-- WD=saturating mismatch count, GM=first-mismatch bank. When false (baseline),
-- bit-identical to the original bridge-probe wiring.
dbg_bridge_req_count       <= std_logic_vector(diag_mm_addr) when CACHE_READ_PATH
                              else std_logic_vector(cpu816_dbg_req_count);
dbg_bridge_ack_count       <= (std_logic_vector(diag_mm_cache) & std_logic_vector(diag_mm_sdram)) when CACHE_READ_PATH
                              else std_logic_vector(cpu816_dbg_ack_count);
dbg_bridge_vec_fetch_count <= std_logic_vector(cpu816_dbg_vec_fetch_count);
-- Milestone B v2 (2026-05-26): vblank-snapped bridge probes.
dbg_bridge_wait_dwell_max  <= std_logic_vector(diag_mm_count) when CACHE_READ_PATH
                              else std_logic_vector(cpu816_dbg_wait_dwell_max);
dbg_bridge_activity_flags  <= std_logic_vector(cpu816_dbg_activity_flags);
dbg_bridge_gap_max         <= std_logic_vector(diag_mm_bank) when CACHE_READ_PATH
                              else std_logic_vector(cpu816_dbg_gap_max);

-- ====================================================================
-- more-turbo iter-4d (2026-05-30): read-only cpu_cache HIT-RATE OBSERVER
-- (see the signal-declaration block + entity-port comment). Mirrors
-- c64_cache_hitrate_tb.vhd exactly: 1-clk uniform tap register, cacheable
-- gate identical to cpu_cache.vhd:188, real cpu_cache fed read-only, and a
-- counter that maintains both cumulative (GHDL cross-check) and a 256-read
-- sliding-window hit rate (UART readout). Observer-only: cobs_hit drives the
-- counter, never the CPU.
-- ====================================================================
cobs_reset <= not reset_n;

cobs_tap : process(clk32)
begin
	if rising_edge(clk32) then
		tap_addr_r  <= cpuAddr;
		tap_bank_r  <= addr_hi_816;
		tap_we_r    <= cpuWe;
		tap_di_r    <= cpuDi;
		tap_do_r    <= cpuDo;
		tap_en_r    <= enableCpu_816;
		tap_valid_r <= vda_816 or vpa_816;
	end if;
end process;

cobs_cacheable <= '1' when (tap_bank_r = x"00" and tap_addr_r(15 downto 12) /= x"D")
                        or (tap_bank_r > x"00" and tap_bank_r < x"F0")
                  else '0';
cobs_eval <= tap_en_r and tap_valid_r and (not tap_we_r) and cobs_cacheable;

cache_observer : entity work.cpu_cache
	port map (
		clk        => clk32,
		reset      => cobs_reset,
		enable     => '1',
		cpu_addr   => tap_addr_r,
		cpu_bank   => tap_bank_r,
		cpu_we     => tap_we_r,
		cpu_do     => tap_do_r,
		cache_di   => cobs_di,
		cache_hit  => cobs_hit,
		fill_data  => tap_di_r,
		fill_we    => cobs_eval,
		fill_addr  => tap_addr_r,
		fill_bank  => tap_bank_r,
		wb_pending => open,
		wb_addr    => open,
		wb_data    => open,
		wb_ack     => '0',
		flush      => '0',
		cpu_en     => tap_en_r,
		wb_enable  => '0',
		same_line  => open,
		dbg_flush_active => open,
		dbg_tag_match    => open
	);

cobs_count : process(clk32)
	variable wh : unsigned(8 downto 0);
begin
	if rising_edge(clk32) then
		if cobs_reset = '1' then
			cobs_reads_cum <= (others => '0');
			cobs_hits_cum  <= (others => '0');
			cobs_win_cnt   <= (others => '0');
			cobs_win_hits  <= (others => '0');
			cobs_hr_reg    <= (others => '0');
			cobs_hw_reg    <= (others => '0');
		elsif cobs_eval = '1' then
			cobs_reads_cum <= cobs_reads_cum + 1;
			if cobs_hit = '1' then
				cobs_hits_cum <= cobs_hits_cum + 1;
				wh := cobs_win_hits + 1;
			else
				wh := cobs_win_hits;
			end if;
			if cobs_win_cnt = x"FF" then
				-- 256th read closes the window: latch hits-per-256 (sat 255)
				if wh(8) = '1' then
					cobs_hr_reg <= x"FF";
				else
					cobs_hr_reg <= wh(7 downto 0);
				end if;
				cobs_hw_reg   <= cobs_hw_reg + 1;
				cobs_win_cnt  <= (others => '0');
				cobs_win_hits <= (others => '0');
			else
				cobs_win_cnt  <= cobs_win_cnt + 1;
				cobs_win_hits <= wh;
			end if;
		end if;
	end if;
end process;

-- iter-29 page-hit-rate observer (see decl ~:1574). Independent of the cobs
-- cache observer above; counts DRAM row-locality of CPU SDRAM accesses to gate
-- the page-mode rewrite. Read-only — touches no cadence/arbiter logic.
pagehit_obs : process(clk32)
	variable req_bank : unsigned(1 downto 0);
	variable req_row  : unsigned(12 downto 0);
	variable idx      : integer range 0 to 3;
	variable is_hit   : std_logic;
	variable wh       : unsigned(8 downto 0);
begin
	if rising_edge(clk32) then
		if cobs_reset = '1' then
			ph_valid_b  <= (others => '0');
			ph_win_cnt  <= (others => '0');
			ph_win_hits <= (others => '0');
			ph_hr_reg   <= (others => '0');
			ph_hw_reg   <= (others => '0');
		else
			-- A CPU SDRAM access this clk32 (same gate as the arbiter's
			-- predictor-row update at the cs_ram block, :3768).
			if cpu_cyc = '1' and cs_ram = '1' then
				-- Post-mapping {bank,row} of THIS access (mirrors :3778-3786;
				-- bank=sd_ba=addr[22:21], row=addr[20:8]).
				if scpu_fast_path = '1' then
					req_bank := addr_hi_816(6 downto 5);
					req_row  := addr_hi_816(4 downto 0) & systemAddr(15 downto 8);
				else
					req_bank := "00";
					req_row  := "00000" & systemAddr(15 downto 8);
				end if;
				for b in 0 to PAGEHIT_COL_EXTRA - 1 loop req_row(b) := '0'; end loop; idx := to_integer(req_bank);
				-- HIT iff it matches THIS bank's currently-open row (per-bank
				-- model: other banks' open rows are unaffected).
				if ph_valid_b(idx) = '1' and req_row = ph_row_b(idx) then
					is_hit := '1';
				else
					is_hit := '0';
				end if;
				if is_hit = '1' then
					wh := ph_win_hits + 1;
				else
					wh := ph_win_hits;
				end if;
				if ph_win_cnt = x"FF" then
					-- 256th access closes the window: latch hits-per-256 (sat 255).
					if wh(8) = '1' then
						ph_hr_reg <= x"FF";
					else
						ph_hr_reg <= wh(7 downto 0);
					end if;
					ph_hw_reg   <= ph_hw_reg + 1;
					ph_win_cnt  <= (others => '0');
					ph_win_hits <= (others => '0');
				else
					ph_win_cnt  <= ph_win_cnt + 1;
					ph_win_hits <= wh;
				end if;
				-- Open this access's row in its bank for the next comparison.
				ph_row_b(idx)   <= req_row;
				ph_valid_b(idx) <= '1';
			end if;
			-- A real refresh auto-precharges ALL banks => every open row closes.
			-- Same condition as the refresh issue at :1989. Refresh and a CPU
			-- access never share a clk32 (different sysCycle slots); give
			-- refresh priority on the valid bits to stay conservative.
			if preCycle = sysCycleDef'pred(CYCLE_EXT4) and rfsh_cycle = "00" then
				ph_valid_b <= (others => '0');
			end if;
		end if;
	end if;
end process;

-- iter-30 TRACK A1: write-fraction observer (SuperRAM CPU SDRAM accesses).
-- Same window/saturation/liveness shape as pagehit_obs; tallies cpuWe instead of
-- a row-hit. Read-only => no cadence change => cannot wedge.
writefrac_obs : process(clk32)
	variable wr : unsigned(8 downto 0);
begin
	if rising_edge(clk32) then
		if cobs_reset = '1' then
			wf_win_cnt <= (others => '0');
			wf_win_wr  <= (others => '0');
			wf_fr_reg  <= (others => '0');
			wf_ww_reg  <= (others => '0');
		else
			-- A CPU SuperRAM SDRAM access this clk32 (the posted-write buffer's
			-- exact target: bank $02+ via scpu_fast_path, RAM via cs_ram).
			if cpu_cyc = '1' and cs_ram = '1' and scpu_fast_path = '1' then
				if cpuWe = '1' then
					wr := wf_win_wr + 1;
				else
					wr := wf_win_wr;
				end if;
				if wf_win_cnt = x"FF" then
					-- 256th access closes the window: latch writes-per-256 (sat 255).
					if wr(8) = '1' then
						wf_fr_reg <= x"FF";
					else
						wf_fr_reg <= wr(7 downto 0);
					end if;
					wf_ww_reg  <= wf_ww_reg + 1;
					wf_win_cnt <= (others => '0');
					wf_win_wr  <= (others => '0');
				else
					wf_win_cnt <= wf_win_cnt + 1;
					wf_win_wr  <= wr;
				end if;
			end if;
		end if;
	end if;
end process;

-- iter-31 BANKFRAC_OBSERVER: bank-$00 share of CPU SDRAM traffic. Window = 256
-- total CPU SDRAM (cs_ram) accesses; tally = those with addr_hi_816 = $00.
-- Same window/saturation/liveness shape as writefrac_obs; read-only => cannot wedge.
bankfrac_obs : process(clk32)
	variable b0 : unsigned(8 downto 0);
begin
	if rising_edge(clk32) then
		if cobs_reset = '1' then
			bf_win_cnt <= (others => '0');
			bf_win_b0  <= (others => '0');
			bf_fr_reg  <= (others => '0');
			bf_ww_reg  <= (others => '0');
		else
			-- Any CPU RAM (SDRAM) access this clk32 (bank $00 RAM or SuperRAM).
			if cpu_cyc = '1' and cs_ram = '1' then
				if addr_hi_816 = x"00" then
					b0 := bf_win_b0 + 1;
				else
					b0 := bf_win_b0;
				end if;
				if bf_win_cnt = x"FF" then
					-- 256th access closes the window: latch bank-$00-per-256 (sat 255).
					if b0(8) = '1' then
						bf_fr_reg <= x"FF";
					else
						bf_fr_reg <= b0(7 downto 0);
					end if;
					bf_ww_reg  <= bf_ww_reg + 1;
					bf_win_cnt <= (others => '0');
					bf_win_b0  <= (others => '0');
				else
					bf_win_cnt <= bf_win_cnt + 1;
					bf_win_b0  <= b0;
				end if;
			end if;
		end if;
	end if;
end process;

dbg_cache_hr <= std_logic_vector(bf_fr_reg) when BANKFRAC_OBSERVER
                else std_logic_vector(wf_fr_reg) when WRITEFRAC_OBSERVER
                else std_logic_vector(ph_hr_reg) when PAGEHIT_OBSERVER
                else std_logic_vector(cobs_hr_reg);
dbg_cache_hw <= std_logic_vector(bf_ww_reg) when BANKFRAC_OBSERVER
                else std_logic_vector(wf_ww_reg) when WRITEFRAC_OBSERVER
                else std_logic_vector(ph_hw_reg) when PAGEHIT_OBSERVER
                else std_logic_vector(cobs_hw_reg);

-- ====================================================================
-- more-turbo iter-6: READ-PATH cache (feeds the CPU). GATED + ADDITIVE.
-- Emitted ONLY when CACHE_READ_PATH=true. Distinct from the observer above:
-- addressed on the CURRENT cpuAddr/addr_hi_816 (NOT the 1-clk taps), so
-- rp_cache_hit/rp_cache_di are live DURING the access for the cpuDi override
-- + grant-shorten. Fills with cpuDi (the exact byte the CPU latches — the mux
-- at :1932 already resolves SuperRAM->ramDin / bank-$00->cpuDi_raw) on each
-- cacheable read step (enableCpu_816 pulse). CPU writes invalidate via cpu_we;
-- snoop tied off here (KERNAL boot has no DMA; the unit+system benches already
-- proved snoop, real DMA-strobe wiring is a follow-up). Read-only (wb_enable
-- '0'). When CACHE_READ_PATH=false this generate is empty and rp_cache_* keep
-- their inert defaults => cpuDi + sdram_hit_pred bit-identical to today.
-- ====================================================================
-- iter-7e (2026-05-31) BANK-SWITCH COHERENCY: exclude bank-$00 ROM-shadowable
-- ranges from the read-path cache. The cache tag (cpu_bank & addr[15:12]) does
-- NOT encode ROM/RAM visibility (cpuIO/$01 = bankSwitch, :1837), so a byte
-- cached while ROM is visible at $8000-$BFFF (cart/BASIC) or $E000-$FFFF
-- (KERNAL) is returned STALE after the CPU switches $01 to read RAM at the same
-- address — the read-path cache instance wires flush=>'0' (:4941), so the
-- bank-switch flush the design intended (cpu_cache.vhd:200-201) never fires.
-- This was the iter-7c/7d boot-corruption root cause (HW-falsified `0228d2b6`,
-- `3514fc7d`): fill-on-every-read masked it by continuously refreshing each byte
-- with the currently-visible value; fill-on-miss-only holds the first-seen byte
-- forever -> stale -> garbled boot. Writes are invalidated (invalidate_wr) and
-- ROM never changes, so the ONLY staleness mechanism for a cached bank-$00 byte
-- is ROM/RAM bank switching => excluding the shadowable ranges is coherent by
-- construction. SuperRAM (banks $02+) has no ROM shadow (unaffected — the
-- speed-critical Doom workload keeps full caching); always-RAM bank-$00
-- ($0000-$7FFF, $C000-$CFFF) stays cached + invalidate_wr-coherent. Gating only
-- the fill transitively suppresses the hit + override (an unfilled line never
-- validates -> never hits), so cpu_cache.vhd (and the observer) stay untouched.
-- iter-15b (2026-06-02): SuperRAM-ONLY fill gate (banks $02-$EF), matching the
-- narrowed cacheable_addr in cpu_cache.vhd. The earlier bank-$00 always-RAM
-- caching was claimed "coherent by construction" (writes via invalidate_wr +
-- ROM-shadow ranges excluded), but it crashed Doom THREE ways even after the
-- invalidate_wr cpu_en-gate fix (eeee wedge, bank-$00 runaway, $0D67
-- poll-freeze) — a third bank-$00 staleness path (the cpuIO bank-switch flush
-- not firing reliably under Doom's $01-port banking) survived. Caching bank $00
-- buys ~zero speed (the 2x alt-fire fires only on SuperRAM scpu_fast_path), so
-- drop it: bank $00/$01 run in proven 4-apart passthrough. SuperRAM ($02-$EF)
-- keeps full caching + the speedup; coherency there is CPU-writes-only
-- (invalidate_wr). Bank $01 excluded (mirrors bank $00 SDRAM; never a CPU bank).
rp_cacheable <= '1' when (addr_hi_816 >= x"02" and addr_hi_816 < x"F0") -- SuperRAM only ($02-$EF)
                else '0';

gen_read_path : if CACHE_READ_PATH generate
	-- iter-7c FIX: gate fill on a MISS only (not rp_cache_hit). Filling on a hit
	-- re-writes the line from cpuDi, which on a hit IS rp_cache_di (the cache's own
	-- output). On a CROSS-LINE hit, line_word (registered, cpu_cache.vhd:284-296)
	-- still holds the PREVIOUS line's byte for one cycle, so the fill-back writes
	-- that stale byte into the NEW line's data bank = permanent self-corruption.
	-- Reproduced + fix validated off-device: sim/cache_coherency_tb/
	-- cpu_cache_fillonhit_tb.vhd ($AA leaks into line B with fill-on-hit; clean
	-- when gated). Textbook cache behaviour anyway: never re-fill a hit.
	-- legacy immediate miss-fill decision (samples cpuDi_nocache AT the consume,
	-- before dout_r is fresh => stale; see FILL_DATAVALID_GATE for the fix).
	rp_fill_we_imm <= enableCpu_816 and (vda_816 or vpa_816) and (not cpuWe)
	                  and rp_cacheable and (not rp_cache_hit);

	-- iter-18 Bug-2 ROOT-CAUSE fix: data-valid-gated delayed fill. Latch the miss
	-- request + the matched address/bank at the consume edge; fire the actual cache
	-- fill_we only once sdram_data_valid_sync is high (dout_r fresh @ q=5 = this
	-- access's byte, asserted before the next read's ce-edge clears data_valid).
	-- cpuAddr at the consume rising edge is still THIS access's address (it advances
	-- after the edge), so rp_fill_addr_dly is transaction-matched to the fired byte.
	rp_fill_req_proc : process(clk32)
	begin
		if rising_edge(clk32) then
			if rp_fill_fire = '1' then
				rp_fill_req <= '0';            -- request serviced
			end if;
			-- iter-22 Bug-2 fix: a CPU write to the pending fill address makes the
			-- in-flight (pre-write) byte stale. Cancel the fill so the line stays
			-- unallocated and the next read re-fetches the written byte. A write
			-- cycle has rp_fill_we_imm=0 (it requires not cpuWe), so this cancel
			-- and the set below never target the same access.
			if FILL_CANCEL_ON_WRITE and rp_fill_req = '1' and cpuWe = '1'
			   and cpuAddr = rp_fill_addr_dly and addr_hi_816 = rp_fill_bank_dly then
				rp_fill_req <= '0';            -- in-flight fill cancelled
			end if;
			if rp_fill_we_imm = '1' then       -- set wins over clear (cannot coincide @ >=4-apart)
				rp_fill_req      <= '1';
				rp_fill_addr_dly <= cpuAddr;
				rp_fill_bank_dly <= addr_hi_816;
			end if;
		end if;
	end process;
	rp_fill_fire <= rp_fill_req and sdram_data_valid_sync;

	-- fill_we to the cache: data-valid-gated (fix) or legacy immediate.
	rp_fill_we <= rp_fill_fire when FILL_DATAVALID_GATE else rp_fill_we_imm;

	-- iter-24 STAGED FILL (robust, 3-stage). The KEY insight (Codex-confirmed):
	-- capturing cpuDi_nocache AT rp_fill_fire samples the deep mux on the SAME edge
	-- the direct M10K write did => no extra functional settling, only endpoint
	-- shortening (marginal). The robust fix RE-captures one clk32 LATER, at which
	-- point the deep cpuDi_nocache mux has had the full 2 clk32 since dout_r went
	-- fresh (= the C64.sdc:31-33 multicycle's promised budget) to settle.
	--   Stage 1 @ fire (F): latch addr/bank + a provisional (F-sampled, addr-matched)
	--     data byte and ARM stage 2 — unless a CPU write hits this address on the
	--     SAME edge (FILL_CANCEL_ON_WRITE clears rp_fill_req but rp_fill_fire/we are
	--     already high this cycle, so the arm must be cancelled here — Codex).
	--   Stage 2 @ F+1: if the CPU is still on this access (passthrough holds cpuAddr
	--     stable, iter-16) RE-capture the now-settled byte; else keep the provisional.
	--     Emit rp_fill_we_st (M10K writes reg->reg at F+2) unless a write hit the
	--     staged address during this gap cycle. (An F+2 write is handled by the
	--     cache's own cpu_wr_pending > fill priority, cpu_cache.vhd:351.)
	-- NOTE: assumes >=4-apart miss cadence (alt-fire OFF). A faster miss cadence
	-- (alt-fire) would need re-review of back-to-back fire / dout_r-overwrite.
	stage_fill_proc : process(clk32)
	begin
		if rising_edge(clk32) then
			rp_fill_we_st <= '0';
			rp_fill_arm   <= '0';
			-- Stage 1 @ fire
			if rp_fill_we = '1'
			   and not (FILL_CANCEL_ON_WRITE and cpuWe = '1'
			            and cpuAddr = rp_fill_addr_sel and addr_hi_816 = rp_fill_bank_sel) then
				rp_fill_addr_st <= rp_fill_addr_sel;
				rp_fill_bank_st <= rp_fill_bank_sel;
				rp_fill_data_st <= cpuDi_nocache;   -- provisional (addr-matched fallback)
				rp_fill_arm     <= '1';
			end if;
			-- Stage 2 @ fire+1
			if rp_fill_arm = '1' then
				if cpuAddr = rp_fill_addr_st and addr_hi_816 = rp_fill_bank_st
				   and cpuWe = '0' then
					rp_fill_data_st <= cpuDi_nocache;   -- robust: fully-settled re-capture
				end if;
				if not (FILL_CANCEL_ON_WRITE and cpuWe = '1'
				        and cpuAddr = rp_fill_addr_st and addr_hi_816 = rp_fill_bank_st) then
					rp_fill_we_st <= '1';
				end if;
			end if;
		end if;
	end process;

	-- Final fill-port selects: staged tuple (FILL_STAGED_TUPLE) vs the direct path.
	rp_fill_data_sel  <= rp_fill_data_st when FILL_STAGED_TUPLE else cpuDi_nocache;
	rp_fill_we_sel    <= rp_fill_we_st  when FILL_STAGED_TUPLE else rp_fill_we;
	rp_fill_addr_sel2 <= rp_fill_addr_st when FILL_STAGED_TUPLE else rp_fill_addr_sel;
	rp_fill_bank_sel2 <= rp_fill_bank_st when FILL_STAGED_TUPLE else rp_fill_bank_sel;

	-- iter-7d: register the cache HIT override one clk32. rp_cache_hit/rp_cache_di
	-- are combinational on the live cpuAddr; rp_cache_di is only valid the cycle
	-- AFTER line_word settles (cross-line). Sampling both into _d1 here lets the
	-- cpuDi override (re-rooted above) consume registered signals so the masked
	-- single-cycle path is genuinely split. Lives in gen_read_path so the FFs are
	-- absent when CACHE_READ_PATH=false (rp_cache_*_d1 keep their inert '0' defaults).
	process(clk32)
	begin
		if rising_edge(clk32) then
			rp_cache_hit_d1 <= rp_cache_hit;
			rp_cache_di_d1  <= rp_cache_di;
		end if;
	end process;

	-- iter-17 DIAGNOSTIC: detect cache-hit data divergence (see decl ~:1621).
	-- At the consume edge (enableCpu_816) with the override active (rp_cache_hit_d1),
	-- the CPU would latch rp_cache_di_d1; the correct value is cpuDi_nocache (live
	-- SDRAM, what Build D feeds and runs Doom on). A mismatch flags the exact Bug-2
	-- corruption. cpuAddr/addr_hi_816 are stable through the 4-apart access, so the
	-- SDRAM byte on cpuDi_nocache belongs to the same address as the cache byte.
	diag_proc: process(clk32)
	begin
		if rising_edge(clk32) then
			if enableCpu_816 = '1' and rp_cache_hit_d1 = '1'
			   and rp_cache_di_d1 /= cpuDi_nocache then
				if diag_mm_count = 0 then
					diag_mm_addr  <= cpuAddr;
					diag_mm_bank  <= addr_hi_816;
					diag_mm_cache <= rp_cache_di_d1;
					diag_mm_sdram <= cpuDi_nocache;
				end if;
				if diag_mm_count /= x"FFFF" then
					diag_mm_count <= diag_mm_count + 1;
				end if;
			end if;
		end if;
	end process;

	-- iter-16 Bug-2 fix: capture the SuperRAM read tuple at SDRAM read-ISSUE.
	-- cpu_cyc marks the CPU's SDRAM access slot; there cpuAddr/addr_hi_816 are the
	-- address actually driven to the SDRAM (ramAddr <= systemAddr) for THIS read —
	-- the address whose data returns on cpuDi_nocache and is consumed at the later
	-- enableCpu_816 (the fill edge). enableCpu_816 is low during cpu_cyc, so cpuAddr
	-- has NOT yet combinationally advanced here = the un-skewed read address. Holding
	-- it until rp_fill_we makes fill_addr/fill_bank match fill_data. Gated on a
	-- cacheable CPU read so non-cacheable / write / VIC traffic never overwrites it.
	process(clk32)
	begin
		if rising_edge(clk32) then
			if supercpu_en = '1' and cpu_cyc = '1' and rp_cacheable = '1' and cpuWe = '0' then
				rp_fill_addr_r <= cpuAddr;
				rp_fill_bank_r <= addr_hi_816;
			end if;
		end if;
	end process;

	-- Fill address/bank select. iter-18: when FILL_DATAVALID_GATE, use the address
	-- latched at the consume (matched to the dout_r byte fired at data-valid). Else
	-- the FILL_TXMATCH read-issue capture, or legacy live cpuAddr.
	rp_fill_addr_sel <= rp_fill_addr_dly when FILL_DATAVALID_GATE
	                    else rp_fill_addr_r when FILL_TXMATCH
	                    else cpuAddr;
	rp_fill_bank_sel <= rp_fill_bank_dly when FILL_DATAVALID_GATE
	                    else rp_fill_bank_r when FILL_TXMATCH
	                    else addr_hi_816;

	read_path_cache : entity work.cpu_cache
		port map (
			clk        => clk32,
			reset      => cobs_reset,
			enable     => supercpu_en,
			cpu_addr   => cpuAddr,
			cpu_bank   => addr_hi_816,
			cpu_we     => cpuWe,
			cpu_do     => cpuDo,
			cache_di   => rp_cache_di,
			cache_hit  => rp_cache_hit,
			-- iter-24: fill data/we/addr/bank go through *_sel (staged reg->reg tuple
			-- when FILL_STAGED_TUPLE, else the direct path). fill_data base is the
			-- pre-override cpuDi_nocache (iter-7d: NOT cpuDi — using cpuDi would feed
			-- the registered override's output back into the cache on a stale-hit cycle,
			-- Codex Q3). fill_addr/bank are the transaction-matched tuple (iter-16).
			fill_data  => rp_fill_data_sel,
			fill_we    => rp_fill_we_sel,
			fill_addr  => rp_fill_addr_sel2,
			fill_bank  => rp_fill_bank_sel2,
			wb_pending => open,
			wb_addr    => open,
			wb_data    => open,
			wb_ack     => '0',
			flush      => '0',
			cpu_en     => enableCpu_816,
			wb_enable  => '0',
			-- iter-15b: DMA-snoop coherency for the cache read path. REU FETCH DMA
			-- writes bank-$00 motherboard RAM by overriding cpuAddr/cpuWe with
			-- dma_addr/dma_we (fpga64:3667-3669); REU never touches SuperRAM, so the
			-- written bank is always $00. Without this, a byte the CPU cached in
			-- bank $00 stays valid after the REU overwrites it ⇒ the Doom loader's
			-- REU→SuperRAM copy reads stale data and wedges ("eeee" screen, the
			-- iter-7f-documented CACHE_READ_PATH Doom regression). snoop_inv
			-- invalidates the matching byte at top priority (cpu_cache.vhd:393).
			snoop_we   => dma_active and cpuWe,
			snoop_addr => cpuAddr,
			snoop_bank => x"00",
			same_line  => rp_same_line,   -- iter-15: LIVE same-line for the fast-fire gate
			dbg_flush_active => open,
			dbg_tag_match    => open
		);
end generate;

-- vsync output: route through internal signal so the per-frame OR latch
-- (above) can detect the rising edge.
vsync           <= vSync_sig;

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
dbg_trace_pc4        <= trace_pc4_r;
dbg_trace_pc5        <= trace_pc5_r;
dbg_trace_op4        <= trace_op4_r;
dbg_trace_op5        <= trace_op5_r;
dbg_scr_write_pc     <= dbg_scr_write_pc_r;
dbg_scr_write_count  <= dbg_scr_write_count_r;
dbg_trace_pc6        <= trace_pc6_r;
dbg_trace_pc7        <= trace_pc7_r;
dbg_trace_op6        <= trace_op6_r;
dbg_trace_op7        <= trace_op7_r;
dbg_scr_write_jsr_a  <= scr_write_jsr_a_r;
dbg_scr_write_jsr_b  <= scr_write_jsr_b_r;
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
dbg_cur_op           <= cur_op_r;
dbg_wloop_lda_lo     <= wloop_lda_lo_r;
dbg_wloop_lda_hi     <= wloop_lda_hi_r;
dbg_wloop_sbc_lo     <= wloop_sbc_lo_r;
dbg_wloop_sbc_hi     <= wloop_sbc_hi_r;
dbg_wloop_ldx_lo     <= wloop_ldx_lo_r;
dbg_wloop_ldx_hi     <= wloop_ldx_hi_r;
dbg_wloop_val_2906   <= wloop_val_2906_r;
dbg_wloop_val_4903   <= wloop_val_4903_r;
dbg_wloop_val_f634   <= wloop_val_f634_r;
dbg_wloop_sta1_lo    <= wloop_sta1_lo_r;
dbg_wloop_sta1_hi    <= wloop_sta1_hi_r;
dbg_wloop_sta2_lo    <= wloop_sta2_lo_r;
dbg_wloop_sta2_hi    <= wloop_sta2_hi_r;
dbg_wloop_sta3_lo    <= wloop_sta3_lo_r;
dbg_wloop_sta3_hi    <= wloop_sta3_hi_r;
dbg_wloop_inc_lo     <= wloop_inc_lo_r;
dbg_wloop_inc_hi     <= wloop_inc_hi_r;
dbg_wloop_lda1_lo    <= wloop_lda1_lo_r;
dbg_wloop_lda1_hi    <= wloop_lda1_hi_r;
dbg_wloop_lda2_lo    <= wloop_lda2_lo_r;
dbg_wloop_lda2_hi    <= wloop_lda2_hi_r;
dbg_wloop_adc_lo     <= wloop_adc_lo_r;
dbg_wloop_adc_hi     <= wloop_adc_hi_r;
dbg_wloop_rb0        <= wloop_rb0_r;
dbg_wloop_rb1        <= wloop_rb1_r;
dbg_wloop_rb2        <= wloop_rb2_r;
dbg_wloop_rb3        <= wloop_rb3_r;
dbg_wloop_rb4        <= wloop_rb4_r;
dbg_wloop_rb5        <= wloop_rb5_r;
dbg_wloop_rb6        <= wloop_rb6_r;
dbg_wloop_rb7        <= wloop_rb7_r;
dbg_wloop_rb8        <= wloop_rb8_r;
dbg_wloop_rb9        <= wloop_rb9_r;
dbg_wloop_rb10       <= wloop_rb10_r;
dbg_wloop_rb11       <= wloop_rb11_r;
dbg_wloop_rb12       <= wloop_rb12_r;
dbg_wloop_w2906_cnt  <= wloop_w2906_cnt_r;
dbg_wloop_w2906_val  <= wloop_w2906_val_r;
dbg_wloop_rb13       <= wloop_rb13_r;
dbg_wloop_rb14       <= wloop_rb14_r;
dbg_wloop_rb15       <= wloop_rb15_r;
dbg_wloop_rb16       <= wloop_rb16_r;
dbg_wloop_rb17       <= wloop_rb17_r;
dbg_wloop_rb18       <= wloop_rb18_r;
dbg_wloop_rb19       <= wloop_rb19_r;
dbg_wloop_rb20       <= wloop_rb20_r;
dbg_wloop_rb21       <= wloop_rb21_r;
dbg_wloop_rb22       <= wloop_rb22_r;
dbg_wloop_rb23       <= wloop_rb23_r;
dbg_wloop_rb24       <= wloop_rb24_r;
dbg_wloop_rb25       <= wloop_rb25_r;
dbg_wloop_rb26       <= wloop_rb26_r;
dbg_wloop_rb27       <= wloop_rb27_r;
dbg_wloop_rb28       <= wloop_rb28_r;
dbg_wloop_rb29       <= wloop_rb29_r;
dbg_wloop_rb30       <= wloop_rb30_r;
dbg_wloop_rb31       <= wloop_rb31_r;
dbg_wloop_rb32       <= wloop_rb32_r;
dbg_wloop_rb33       <= wloop_rb33_r;
dbg_wloop_rb34       <= wloop_rb34_r;
dbg_wloop_rb35       <= wloop_rb35_r;
dbg_wloop_rb36       <= wloop_rb36_r;
dbg_wloop_d292e      <= wloop_d292e_r;
dbg_wloop_d2930      <= wloop_d2930_r;
dbg_wloop_w292e_cnt  <= wloop_w292e_cnt_r;
dbg_wloop_w292e_val  <= wloop_w292e_val_r;
dbg_wloop_w2930_cnt  <= wloop_w2930_cnt_r;
dbg_wloop_w2930_val  <= wloop_w2930_val_r;
dbg_scpu_iclr        <= scpu_iclr_r;
dbg_irq_vec_count    <= std_logic_vector(irq_vec_count_r);
dbg_min_p            <= min_p_r;
dbg_rti_count        <= std_logic_vector(rti_count_r);
dbg_nmi_vec_count    <= std_logic_vector(nmi_vec_count_r);
dbg_call_depth       <= std_logic_vector(call_depth_r);
dbg_call_depth_maxabs <= std_logic_vector(call_depth_maxabs_r);
dbg_vecfetch_addr    <= vecfetch_addr_r;
dbg_jmlvec_hi        <= jmlvec_hi_r;
dbg_jmlvec_bank      <= jmlvec_bank_r;
dbg_last_07b9        <= last_07b9_read_r;
dbg_d019_wr_count    <= std_logic_vector(d019_wr_count_r);
dbg_dc0d_rd_count    <= std_logic_vector(dc0d_rd_count_r);
dbg_irq_fall_count   <= std_logic_vector(irq_fall_count_r);
dbg_irq_cia1_fall_count <= std_logic_vector(irq_cia1_fall_count_r);
dbg_cia1_imr <= cia1_imr_lvl;
dbg_cia1_cra <= cia1_cra_lvl;
dbg_cia1_timer_a       <= cia1_timer_a_lvl;
dbg_cia1_timer_a_latch <= cia1_timer_a_latch_lvl;
dbg_cia1_icr           <= cia1_icr_lvl;
dbg_cia2_imr  <= cia2_imr_lvl;
dbg_cia2_cra  <= cia2_cra_lvl;
dbg_cia2_pra  <= cia2_pra_lvl;
dbg_cia2_prb  <= cia2_prb_lvl;
dbg_cia2_ddra <= cia2_ddra_lvl;
dbg_cia2_ddrb <= cia2_ddrb_lvl;

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
-- 2026-05-09 doom-wait probe: last cpu read in $00:$0700-$07FF
dbg_rd07xx_addr <= rd07xx_addr_r;
dbg_rd07xx_data <= rd07xx_data_r;
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

-- v309: surface native BRK vector lo/hi for the Doom wedge probe.
dbg_brk_vec_lo <= std_logic_vector(scpu_native_vec(2));
dbg_brk_vec_hi <= std_logic_vector(scpu_native_vec(3));

-- Compose 24-bit "current PC" for $DD00 write capture: PBR:PC for SCPU,
-- $00:t65_pc_latch (last opcode-fetch address) for T65.
dd00_pc_now <= std_logic_vector(dbg_pbr_816_i) & std_logic_vector(dbg_pc_816_i)
               when supercpu_en = '1'
               else x"00" & std_logic_vector(t65_pc_latch);

end architecture;
