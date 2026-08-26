// debug_uart_pool_fmt.sv
//
// Vanilla-cpu-swap minimal UART formatter. Emits ONE ASCII line per
// vblank rising edge containing the dbg_pool fields most relevant for
// the Dragon's Lair / SCPU-emu-mode investigation:
//
//   F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:#### J:#### #### #### #### M:#### #### #### #### G:## ## ## N:###### I:###### B:## C3:#### C9:#### D1:## D8:## C2:## D6:##\n
// v341: 1D:#### slot replaces dead R7; D6:## appended (line=230 bytes).
//
// J = 4-deep JSR-PC ring (low 16 bits)         from pool.jsr_pc_t0..t3
// M = 4-deep JMP-indirect target ring          from pool.jmp_tgt_t0..t3
// G = DL gate variables: $40 $44 $5C           from pool.mem_40/mem_44/mem_5C
// N = main-thread PC (last opcode fetch I=0)   from pool.pc_main
// I = IRQ-thread PC  (last opcode fetch I=1)   from pool.pc_irq
// B = wait-loop variable $0045                 from pool.mem_45
// C3 = opcode-fetch count at page $30          from pool.cnt_pc_30
// C9 = opcode-fetch count at page $97          from pool.cnt_pc_97
//
// Added 2026-05-01 after the dl_uart_baseline finding: V/Y/X are
// IDENTICAL T65 vs SCPU but PC distribution is disjoint, so the bug is
// in upstream state. JSR ring + JMP-target ring per frame gives 4
// samples × 50 fps = 200 calls/s of caller-chain visibility, vs the
// 4-per-screenshot the overlay provided.
//
// Bandwidth: 114 chars × 50 Hz = 5700 B/s, well below the 11520 B/s
// budget at 115200 baud.
//
// Fields:
//   F  = frame_count  (16-bit, ticks each vsync)
//   PC = cpu_pc       (24-bit; PBR:PC for SCPU, $00:PC for T65)
//   P  = cpu_p        (8-bit status flags)
//   V  = wr02_v0..v3  (4-deep ring of last values stored to $0002, oldest..newest)
//   YX = wr02_y || wr02_x (Y/X registers latched at most recent $0002 write)
//   WP = wr02_pc      (PC of the writer that last stored to $0002)
//   CG = cnt_wr02_chg (writes to $0002 where new value differed from previous)
//   CY = cnt_wr02     (total writes to $0002)
//
// 70 chars per line × 60 Hz = 4.2 KB/s — well below the 11.5 KB/s budget at
// 115200 baud, so a frame-per-line cadence is comfortable.
//
// State machine: a `byte_idx` counter walks 0..LINE_LEN-1. For each position
// we emit either a literal byte or a hex nibble of a latched field. After
// the trailing newline the FSM idles until the next vblank rising edge.

`include "debug_pkg.svh"

`ifdef DBG_UART

module debug_uart_pool_fmt
(
	input              clk,
	input              reset,
	input              enable,        // OSD-time enable
	input              vblank,        // pause-independent vblank
	input  dbg_pool_t  pool,

	output reg [7:0]   tx_data,
	output reg         tx_send,
	input              tx_busy
);

	// -----------------------------------------------------------------
	// Latch fields at vblank rising edge so the line is consistent.
	// -----------------------------------------------------------------
	reg vblank_d;
	wire vblank_rise = vblank & ~vblank_d;

	reg [15:0] lat_frame;
	reg [23:0] lat_pc;
	reg  [7:0] lat_p;
	reg  [7:0] lat_v0, lat_v1, lat_v2, lat_v3;
	reg  [7:0] lat_y, lat_x;
	reg [15:0] lat_sp;          // v280 doom triage: 16-bit SP
	reg [23:0] lat_wp;
	reg [15:0] lat_cg;     // v257 cnt_wr02_chg (now repurposed as W1)
	// 2026-05-10 doom-wait probe (Probe B): repurpose W1 slot to surface the
	// last-2 opcodes the SCPU actually fetched. Layout is now `OP:hh ll` where
	// hh = trace_op2 (one-back) and ll = trace_op3 (newest). Pairs with N
	// (last-fetch-PC main-thread) to confirm whether pc_main is a real
	// instruction or a frozen latch. Doom doesn't write $D001, so dropping
	// the d001_last_pc display loses no useful Doom signal.
	reg [15:0] lat_w1;     // now: {trace_op2, trace_op3} — opcode bytes
	// 29th pass (Wolf3D bank-$28 freeze, 2026-08-25): 2 post-trigger ring
	// slots (see debug_pkg.svh trace_pc4/trace_pc5 comment). UART-only —
	// overlay cell space is fully exhausted.
	reg [23:0] lat_tr_pc4, lat_tr_pc5;
	reg  [7:0] lat_tr_op4, lat_tr_op5;
	// 31st pass (Wolf3D freeze, 2026-08-25): screen-RAM write observer
	// (see debug_pkg.svh scr_write_pc comment). UART-only.
	reg [23:0] lat_scr_write_pc;
	reg  [7:0] lat_scr_write_count;
	// 32nd pass (Wolf3D freeze, 2026-08-25): 2 more post-trigger ring
	// slots (see debug_pkg.svh trace_pc6/trace_pc7 comment). UART-only.
	reg [23:0] lat_tr_pc6, lat_tr_pc7;
	reg  [7:0] lat_tr_op6, lat_tr_op7;
	// 33rd pass (Wolf3D freeze, 2026-08-26): JSR-ring snapshot latched
	// at the moment of the last screen write (see debug_pkg.svh
	// scr_write_jsr_a comment). UART-only.
	reg [15:0] lat_scr_write_jsr_a, lat_scr_write_jsr_b;
	// 34th pass (Wolf3D freeze, 2026-08-26): always-live current opcode
	// byte, paired with the already-live PC field.
	reg  [7:0] lat_cur_op;
	reg  [7:0] lat_wloop_lda_lo;
	reg  [7:0] lat_wloop_lda_hi;
	reg  [7:0] lat_wloop_sbc_lo;
	reg  [7:0] lat_wloop_sbc_hi;
	reg  [7:0] lat_wloop_ldx_lo;
	reg  [7:0] lat_wloop_ldx_hi;
	reg  [7:0] lat_wloop_val_2906;
	reg  [7:0] lat_wloop_val_4903;
	reg  [7:0] lat_wloop_val_f634;
	reg  [7:0] lat_wloop_sta1_lo;
	reg  [7:0] lat_wloop_sta1_hi;
	reg  [7:0] lat_wloop_sta2_lo;
	reg  [7:0] lat_wloop_sta2_hi;
	reg  [7:0] lat_wloop_sta3_lo;
	reg  [7:0] lat_wloop_sta3_hi;
	reg  [7:0] lat_wloop_inc_lo;
	reg  [7:0] lat_wloop_inc_hi;
	reg  [7:0] lat_wloop_lda1_lo;
	reg  [7:0] lat_wloop_lda1_hi;
	reg  [7:0] lat_wloop_lda2_lo;
	reg  [7:0] lat_wloop_lda2_hi;
	reg  [7:0] lat_wloop_adc_lo;
	reg  [7:0] lat_wloop_adc_hi;
	reg  [7:0] lat_wloop_rb0;
	reg  [7:0] lat_wloop_rb1;
	reg  [7:0] lat_wloop_rb2;
	reg  [7:0] lat_wloop_rb3;
	reg  [7:0] lat_wloop_rb4;
	reg  [7:0] lat_wloop_rb5;
	reg  [7:0] lat_wloop_rb6;
	reg  [7:0] lat_wloop_rb7;
	reg  [7:0] lat_wloop_rb8;
	reg  [7:0] lat_wloop_rb9;
	reg  [7:0] lat_wloop_rb10;
	reg  [7:0] lat_wloop_rb11;
	reg  [7:0] lat_wloop_rb12;
	reg  [7:0] lat_wloop_w2906_cnt;
	reg  [7:0] lat_wloop_w2906_val;
	reg  [7:0] lat_wloop_rb13;
	reg  [7:0] lat_wloop_rb14;
	reg  [7:0] lat_wloop_rb15;
	reg  [7:0] lat_wloop_rb16;
	reg  [7:0] lat_wloop_rb17;
	reg  [7:0] lat_wloop_rb18;
	reg  [7:0] lat_wloop_rb19;
	reg  [7:0] lat_wloop_rb20;
	reg  [7:0] lat_wloop_rb21;
	reg  [7:0] lat_wloop_rb22;
	reg  [7:0] lat_wloop_rb23;
	reg  [7:0] lat_wloop_rb24;
	reg  [7:0] lat_wloop_rb25;
	reg  [7:0] lat_wloop_rb26;
	reg  [7:0] lat_wloop_rb27;
	reg  [7:0] lat_wloop_rb28;
	reg  [7:0] lat_wloop_rb29;
	reg  [7:0] lat_wloop_rb30;
	reg  [7:0] lat_wloop_rb31;
	reg  [7:0] lat_wloop_rb32;
	reg  [7:0] lat_wloop_rb33;
	reg  [7:0] lat_wloop_rb34;
	reg  [7:0] lat_wloop_rb35;
	reg  [7:0] lat_wloop_rb36;
	reg  [7:0] lat_wloop_d292e;
	reg  [7:0] lat_wloop_d2930;
	reg  [7:0] lat_wloop_w292e_cnt;
	reg  [7:0] lat_wloop_w292e_val;
	reg  [7:0] lat_wloop_w2930_cnt;
	reg  [7:0] lat_wloop_w2930_val;
	reg [15:0] lat_cy;
	reg [15:0] lat_jsr0, lat_jsr1, lat_jsr2, lat_jsr3;
	reg [15:0] lat_jmp0, lat_jmp1, lat_jmp2, lat_jmp3;
	reg  [7:0] lat_m40, lat_m44, lat_m5c;
	reg [23:0] lat_pc_main, lat_pc_irq;
	reg  [7:0] lat_m45;
	reg [15:0] lat_c30, lat_c97;
	// v264: sprite-position last-write probes (replaces C3/C9 in line)
	reg  [7:0] lat_d000, lat_d001, lat_d002, lat_d003;
	reg  [7:0] lat_w5c0, lat_w5c1, lat_w5c2, lat_w5c3;
	reg [15:0] lat_w5cN;
	// v263: IRQ-source confirmation
	reg [15:0] lat_irq_fall;
	reg [15:0] lat_irq_vec;
	// 2026-05-09 doom-wait probe — last $00:$07xx read addr + data
	reg  [7:0] lat_rd07addr;
	reg  [7:0] lat_rd07data;
	reg  [7:0] lat_d019_rd;
	reg  [3:0] lat_d019_seen;
	// v267: $D012 raster-IRQ tail-chain timing (replaces DR/DS in line).
	reg [15:0] lat_d012_wc;     // d012_write_cycles (clk32 cycles)
	reg  [8:0] lat_d012_rr;     // raster_at_d012 (line 0..311 PAL)
	reg  [7:0] lat_d012_dv;     // d012_last_val (compare value)
	// v268: IRQ rising-edge counters (replaces SP:## ## ## ## in line).
	reg [15:0] lat_irq_rise_combined;
	reg [15:0] lat_irq_rise_vic;
	// v269: VIC-internal $D019 ack diagnostics (replaces IR/IV slot in
	// UART line — IR/IV are still latched to keep parsers backward
	// compatible if needed, but the visible bytes show VR/RR now).
	reg [15:0] lat_vic_d019_wr;
	reg [15:0] lat_vic_resetraster;
	// v9 MCP probe (2026-05-24): dc0d_rd_count (CIA1 ICR read counter)
	// and d019_wr_count (VIC IRQ ack write counter). Differential v8 ↔
	// MCP-active to test double-CIA-read hypothesis.
	reg [15:0] lat_dc0d_rd;
	reg [15:0] lat_d019_wr;
	// v12 (2026-05-24): CIA1-only IRQ falling-edge count, emitted as " C1:####".
	reg [15:0] lat_irq_cia1_fall;
	// v12b (2026-05-24): CIA1 IMR/CRA snapshots, emitted as " IM:## CR:##".
	reg [4:0]  lat_cia1_imr;
	reg [7:0]  lat_cia1_cra;
	reg [4:0]  lat_cia2_imr;
	reg [7:0]  lat_cia2_cra;
	reg [7:0]  lat_cia2_pra;
	reg [7:0]  lat_cia2_prb;
	reg [7:0]  lat_cia2_ddra;
	reg [7:0]  lat_cia2_ddrb;
	// Milestone B (2026-05-25): bridge-internal UART probes per
	// docs/milestone_b_bridge_probe_design.md §B. Latched at vblank rising
	// edge so the emitted UART line is internally consistent.
	reg [3:0]  lat_bridge_fsm_state;
	reg [7:0]  lat_bridge_last_bus_di;
	reg [15:0] lat_bridge_req_count;
	reg [15:0] lat_bridge_ack_count;
	reg [7:0]  lat_bridge_vec_fetch_count;
	// Milestone B v2 (2026-05-26): vblank-snapped bridge probes.
	reg [15:0] lat_bridge_wait_dwell_max;
	reg [7:0]  lat_bridge_activity_flags;
	reg [7:0]  lat_bridge_gap_max;
	reg [7:0]  lat_iec_lines;   // 2026-05-28: live IEC line states (LOAD wedge probe)
	// mb-probe-003 (2026-05-26): CIA1 Timer A + ICR taps.
	reg [15:0] lat_cia1_timer_a;
	reg [15:0] lat_cia1_timer_a_latch;
	reg  [4:0] lat_cia1_icr;
	// v309 doom wedge: BRK vector lo/hi — repurposes the AC slot.
	reg  [7:0] lat_brk_vec_lo;
	reg  [7:0] lat_brk_vec_hi;
	// v270: $D019 writer PC + last cpuDo + sticky cpuDo OR.
	reg [23:0] lat_d019_pc;
	reg  [7:0] lat_d019_val;
	reg  [7:0] lat_d019_seen_w;
	// v271: $D019 ack-write counter + ack-write PC.
	reg [15:0] lat_d019_ack_count;
	reg [23:0] lat_d019_ack_pc;
	// 2026-05-09 vanilla-cpu-swap: VIC bank-select probes (replaces AW/PA
	// in line bytes 202..219). D1 = $D011 (bit5=bitmap mode, bit4=DEN,
	// bit6=ECM), D8 = $D018 (screen+char/bitmap base), C2 = $DD00
	// (CIA2 PRA bits 0-1 = VIC bank). Together these tell us which 16KB
	// region VIC sees + whether Doom switched to bitmap mode for rendering.
	reg  [7:0] lat_d011v;
	reg  [7:0] lat_d018v;
	reg  [7:0] lat_dd00v;
	// v341 doom bitmap probe (2026-05-14): page-flip handshake bytes at
	// bank $00:$1D02/$1D04 and $D016 MCM bit. After v340n IRQ wedge fix,
	// Doom reaches bitmap mode (D1=$3B) but DD00 stuck at $02 — VIC sees
	// only bank 1 ($4000-$7FFF). $1D04 is the flag Doom's flip code BEQs
	// on; if it never reaches 0, the flip never picks bank 3. D6/$D016
	// MCM bit confirms multicolor vs hires bitmap mode.
	reg  [7:0] lat_m1d02;
	reg  [7:0] lat_m1d04;
	reg  [7:0] lat_d016v;
	// v346 doom bitmap-content probe: per-frame sticky OR of vicDi.
	reg  [7:0] lat_vic_di_or;
	// v347 doom bitmap-write probe: per-frame saturating count of CPU
	// writes to bank-0 SDRAM regions $4000-$5FFF (bm1) and $C000-$DFFF
	// (bm3). Latched on vsync rising edge.
	reg  [7:0] lat_bm1_writes;
	reg  [7:0] lat_bm3_writes;
	// more-turbo iter-4d (2026-05-30): read-only cpu_cache hit-rate observer.
	// HR = hits in last completed 256-cacheable-read window (sat 255;
	// HR/2.56 = approx %). HW = window-completion counter (liveness).
	reg  [7:0] lat_cache_hr;
	reg  [7:0] lat_cache_hw;

	// -----------------------------------------------------------------
	// Send FSM: drive tx_send for one cycle whenever tx is idle and the
	// next byte hasn't been issued yet. byte_idx indexes the line bytes
	// 0..LINE_LEN-1; LINE_LEN signals "line done, idle until next vblank".
	// -----------------------------------------------------------------
	// v9 MCP probe (2026-05-24): +16 bytes for " DR:#### D9:####" appended
	// after B3 — dc0d_rd_count and d019_wr_count for MCP-vs-passthrough
	// differential. Newline now at byte 260.
	// Option F (2026-05-25): +12 bytes for " M2:## T2:##" after CR (CIA2 imr/cra).
	// Renamed from I2/C2 to M2/T2 to avoid colliding with legacy C2: field.
	// Option G (2026-05-25): +24 bytes for " PA:## PB:## DA:## DB:##" — CIA2
	// PRA/PRB/DDRA/DDRB to detect IEC-port phantom writes during LOAD"*" wedge.
	// Milestone B (2026-05-25): +33 bytes for " FS:# DI:## RQ:#### AK:#### VF:##"
	// — bridge FSM state, last bus_di, req/ack counters, IRQ vector-fetch
	// counter per docs/milestone_b_bridge_probe_design.md §B.3.
	// Milestone B v2 (2026-05-26 — Codex Design 3): +20 bytes for
	// " WD:#### FL:## GM:##" — max WAIT_ACK dwell per frame, sticky activity
	// flags, max RQ-AK gap per frame.
	// mb-probe-003 (2026-05-26): +22 bytes for " TA:#### TL:#### IC:##" —
	// CIA1 Timer A current counter, reload latch, raw ICR pending bits.
	// New tail uses bytes 369..390; IE field at 391..396.
	// more-turbo iter-4d (2026-05-30): append " HR:## HW:##" (12 bytes) at
	// 397..408 for the read-only cpu_cache hit-rate observer; newline at 409.
	// 34th pass (2026-08-26): +6 bytes " OP:##" for the always-live
	// current-opcode field pushes total line length to 512 (LF now at
	// index 511), exactly at the 9-bit index's representable ceiling
	// (0..511) -- widened byte_idx/line_byte's index to 10 bits so
	// LINE_LEN=512 fits as a literal. Existing case items keep their
	// 9'd literals unchanged; Verilog zero-extends them for the
	// comparison, so no risk there.
	localparam LINE_LEN = 10'd721;

	reg [9:0] byte_idx;
	reg       byte_pending;     // a byte has been latched but not sent

	function [7:0] hex_nibble(input [3:0] n);
		hex_nibble = (n < 4'd10) ? (8'h30 + {4'b0, n})         // '0'..'9'
		                         : (8'h41 + {4'b0, n} - 8'd10); // 'A'..'F'
	endfunction

	// Combinational byte selector — emits the byte for `byte_idx`.
	function [7:0] line_byte(input [9:0] i);
		case (i)
			// "F:"
			8'd0:  line_byte = "F";
			8'd1:  line_byte = ":";
			// 4 hex nibbles of frame
			8'd2:  line_byte = hex_nibble(lat_frame[15:12]);
			8'd3:  line_byte = hex_nibble(lat_frame[11:8]);
			8'd4:  line_byte = hex_nibble(lat_frame[7:4]);
			8'd5:  line_byte = hex_nibble(lat_frame[3:0]);
			8'd6:  line_byte = " ";

			// "PC:"
			8'd7:  line_byte = "P";
			8'd8:  line_byte = "C";
			8'd9:  line_byte = ":";
			8'd10: line_byte = hex_nibble(lat_pc[23:20]);
			8'd11: line_byte = hex_nibble(lat_pc[19:16]);
			8'd12: line_byte = hex_nibble(lat_pc[15:12]);
			8'd13: line_byte = hex_nibble(lat_pc[11:8]);
			8'd14: line_byte = hex_nibble(lat_pc[7:4]);
			8'd15: line_byte = hex_nibble(lat_pc[3:0]);
			8'd16: line_byte = " ";

			// "P:"
			8'd17: line_byte = "P";
			8'd18: line_byte = ":";
			8'd19: line_byte = hex_nibble(lat_p[7:4]);
			8'd20: line_byte = hex_nibble(lat_p[3:0]);
			8'd21: line_byte = " ";

			// "V:## ## ## ##" (oldest..newest)
			8'd22: line_byte = "V";
			8'd23: line_byte = ":";
			8'd24: line_byte = hex_nibble(lat_v0[7:4]);
			8'd25: line_byte = hex_nibble(lat_v0[3:0]);
			8'd26: line_byte = " ";
			8'd27: line_byte = hex_nibble(lat_v1[7:4]);
			8'd28: line_byte = hex_nibble(lat_v1[3:0]);
			8'd29: line_byte = " ";
			8'd30: line_byte = hex_nibble(lat_v2[7:4]);
			8'd31: line_byte = hex_nibble(lat_v2[3:0]);
			8'd32: line_byte = " ";
			8'd33: line_byte = hex_nibble(lat_v3[7:4]);
			8'd34: line_byte = hex_nibble(lat_v3[3:0]);
			8'd35: line_byte = " ";

			// v280: "SP:####" — 16-bit P65C816 stack pointer (replaces YX).
			// Confirms whether SP=$6C0X at the BRK loop in Doom v274.
			8'd36: line_byte = "S";
			8'd37: line_byte = "P";
			8'd38: line_byte = ":";
			8'd39: line_byte = hex_nibble(lat_sp[15:12]);
			8'd40: line_byte = hex_nibble(lat_sp[11:8]);
			8'd41: line_byte = hex_nibble(lat_sp[7:4]);
			8'd42: line_byte = hex_nibble(lat_sp[3:0]);
			8'd43: line_byte = " ";

			// "WP:######"
			8'd44: line_byte = "W";
			8'd45: line_byte = "P";
			8'd46: line_byte = ":";
			8'd47: line_byte = hex_nibble(lat_wp[23:20]);
			8'd48: line_byte = hex_nibble(lat_wp[19:16]);
			8'd49: line_byte = hex_nibble(lat_wp[15:12]);
			8'd50: line_byte = hex_nibble(lat_wp[11:8]);
			8'd51: line_byte = hex_nibble(lat_wp[7:4]);
			8'd52: line_byte = hex_nibble(lat_wp[3:0]);
			8'd53: line_byte = " ";

			// v320 (2026-05-12): "YX:####" repurposes OP slot to show
			// the source address (HI:LO) of the last bank-$2B read of
			// $F7 from SuperRAM. lat_y = $99 (HI), lat_x = $98 (LO).
			// Combined with V ring's source bank, we get a 24-bit
			// SuperRAM address that returned $F7 to the sign-extend.
			8'd54: line_byte = "Y";
			8'd55: line_byte = "X";
			8'd56: line_byte = ":";
			8'd57: line_byte = hex_nibble(lat_y[7:4]);
			8'd58: line_byte = hex_nibble(lat_y[3:0]);
			8'd59: line_byte = hex_nibble(lat_x[7:4]);
			8'd60: line_byte = hex_nibble(lat_x[3:0]);
			8'd61: line_byte = " ";

			// "CY:####"
			8'd62: line_byte = "C";
			8'd63: line_byte = "Y";
			8'd64: line_byte = ":";
			8'd65: line_byte = hex_nibble(lat_cy[15:12]);
			8'd66: line_byte = hex_nibble(lat_cy[11:8]);
			8'd67: line_byte = hex_nibble(lat_cy[7:4]);
			8'd68: line_byte = hex_nibble(lat_cy[3:0]);
			8'd69: line_byte = " ";

			// "J:#### #### #### ####"
			8'd70: line_byte = "J";
			8'd71: line_byte = ":";
			8'd72: line_byte = hex_nibble(lat_jsr0[15:12]);
			8'd73: line_byte = hex_nibble(lat_jsr0[11:8]);
			8'd74: line_byte = hex_nibble(lat_jsr0[7:4]);
			8'd75: line_byte = hex_nibble(lat_jsr0[3:0]);
			8'd76: line_byte = " ";
			8'd77: line_byte = hex_nibble(lat_jsr1[15:12]);
			8'd78: line_byte = hex_nibble(lat_jsr1[11:8]);
			8'd79: line_byte = hex_nibble(lat_jsr1[7:4]);
			8'd80: line_byte = hex_nibble(lat_jsr1[3:0]);
			8'd81: line_byte = " ";
			8'd82: line_byte = hex_nibble(lat_jsr2[15:12]);
			8'd83: line_byte = hex_nibble(lat_jsr2[11:8]);
			8'd84: line_byte = hex_nibble(lat_jsr2[7:4]);
			8'd85: line_byte = hex_nibble(lat_jsr2[3:0]);
			8'd86: line_byte = " ";
			8'd87: line_byte = hex_nibble(lat_jsr3[15:12]);
			8'd88: line_byte = hex_nibble(lat_jsr3[11:8]);
			8'd89: line_byte = hex_nibble(lat_jsr3[7:4]);
			8'd90: line_byte = hex_nibble(lat_jsr3[3:0]);
			8'd91: line_byte = " ";

			// "M:#### #### #### ####"
			8'd92:  line_byte = "M";
			8'd93:  line_byte = ":";
			8'd94:  line_byte = hex_nibble(lat_jmp0[15:12]);
			8'd95:  line_byte = hex_nibble(lat_jmp0[11:8]);
			8'd96:  line_byte = hex_nibble(lat_jmp0[7:4]);
			8'd97:  line_byte = hex_nibble(lat_jmp0[3:0]);
			8'd98:  line_byte = " ";
			8'd99:  line_byte = hex_nibble(lat_jmp1[15:12]);
			8'd100: line_byte = hex_nibble(lat_jmp1[11:8]);
			8'd101: line_byte = hex_nibble(lat_jmp1[7:4]);
			8'd102: line_byte = hex_nibble(lat_jmp1[3:0]);
			8'd103: line_byte = " ";
			8'd104: line_byte = hex_nibble(lat_jmp2[15:12]);
			8'd105: line_byte = hex_nibble(lat_jmp2[11:8]);
			8'd106: line_byte = hex_nibble(lat_jmp2[7:4]);
			8'd107: line_byte = hex_nibble(lat_jmp2[3:0]);
			8'd108: line_byte = " ";
			8'd109: line_byte = hex_nibble(lat_jmp3[15:12]);
			8'd110: line_byte = hex_nibble(lat_jmp3[11:8]);
			8'd111: line_byte = hex_nibble(lat_jmp3[7:4]);
			8'd112: line_byte = hex_nibble(lat_jmp3[3:0]);

			// " G:## ## ##" — DL gate variables ($40 / $44 / $5C)
			8'd113: line_byte = " ";
			8'd114: line_byte = "G";
			8'd115: line_byte = ":";
			8'd116: line_byte = hex_nibble(lat_m40[7:4]);
			8'd117: line_byte = hex_nibble(lat_m40[3:0]);
			8'd118: line_byte = " ";
			8'd119: line_byte = hex_nibble(lat_m44[7:4]);
			8'd120: line_byte = hex_nibble(lat_m44[3:0]);
			8'd121: line_byte = " ";
			8'd122: line_byte = hex_nibble(lat_m5c[7:4]);
			8'd123: line_byte = hex_nibble(lat_m5c[3:0]);

			// " N:###### " main-thread PC (last opcode fetch with I=0)
			8'd124: line_byte = " ";
			8'd125: line_byte = "N";
			8'd126: line_byte = ":";
			8'd127: line_byte = hex_nibble(lat_pc_main[23:20]);
			8'd128: line_byte = hex_nibble(lat_pc_main[19:16]);
			8'd129: line_byte = hex_nibble(lat_pc_main[15:12]);
			8'd130: line_byte = hex_nibble(lat_pc_main[11:8]);
			8'd131: line_byte = hex_nibble(lat_pc_main[7:4]);
			8'd132: line_byte = hex_nibble(lat_pc_main[3:0]);

			// " I:###### " IRQ-thread PC (last opcode fetch with I=1)
			8'd133: line_byte = " ";
			8'd134: line_byte = "I";
			8'd135: line_byte = ":";
			8'd136: line_byte = hex_nibble(lat_pc_irq[23:20]);
			8'd137: line_byte = hex_nibble(lat_pc_irq[19:16]);
			8'd138: line_byte = hex_nibble(lat_pc_irq[15:12]);
			8'd139: line_byte = hex_nibble(lat_pc_irq[11:8]);
			8'd140: line_byte = hex_nibble(lat_pc_irq[7:4]);
			8'd141: line_byte = hex_nibble(lat_pc_irq[3:0]);

			// " B:## " wait-loop variable $0045
			8'd142: line_byte = " ";
			8'd143: line_byte = "B";
			8'd144: line_byte = ":";
			8'd145: line_byte = hex_nibble(lat_m45[7:4]);
			8'd146: line_byte = hex_nibble(lat_m45[3:0]);

			// v269: " VW:####" VIC-internal myWr_a $D019 count +
			//       " AC:####" VIC-internal resetRasterIrq (ack) count.
			// Distinguishes: VW=0 -> alignment failure; VW>0 AC=0 ->
			// data-bit-0 corruption; both>0 -> IRST race / re-fires.
			// (Replaces v268 IR/IV labels — those were 0/0 on SCPU,
			//  no further info gained. Same byte positions.)
			8'd147: line_byte = " ";
			8'd148: line_byte = "V";
			8'd149: line_byte = "W";
			8'd150: line_byte = ":";
			8'd151: line_byte = hex_nibble(lat_vic_d019_wr[15:12]);
			8'd152: line_byte = hex_nibble(lat_vic_d019_wr[11:8]);
			8'd153: line_byte = hex_nibble(lat_vic_d019_wr[7:4]);
			8'd154: line_byte = hex_nibble(lat_vic_d019_wr[3:0]);
			// v340n: restore AC field = VIC-internal resetRasterIrq count.
			// (v309 had repurposed AC → VB:#### BRK vector; BRK diagnostic
			// no longer needed since v340e+ work confirmed the BRK/RTI
			// paths.) AC is the IRST-clear pulse counter — pulses every
			// time the VIC's resetRasterIrq fires inside video_vicII_656x.
			// Together with VW (myWr_a $D019 write count) this distinguishes:
			//   VW=0 AC=0  → SCPU $D019 writes never reach the VIC bus
			//   VW>0 AC=0  → writes reach myWr_a but di_r(0) wrong or IRST
			//                latch ignores the write (suspected bug)
			//   VW>0 AC>0  → ack chain works; wedge has another cause
			8'd155: line_byte = " ";
			8'd156: line_byte = "A";
			8'd157: line_byte = "C";
			8'd158: line_byte = ":";
			8'd159: line_byte = hex_nibble(lat_vic_resetraster[15:12]);
			8'd160: line_byte = hex_nibble(lat_vic_resetraster[11:8]);
			8'd161: line_byte = hex_nibble(lat_vic_resetraster[7:4]);
			8'd162: line_byte = hex_nibble(lat_vic_resetraster[3:0]);

			// " W5:## ## ## ##" v262 4-deep ring of writes to $005C
			8'd163: line_byte = " ";
			8'd164: line_byte = "W";
			8'd165: line_byte = "5";
			8'd166: line_byte = ":";
			8'd167: line_byte = hex_nibble(lat_w5c0[7:4]);
			8'd168: line_byte = hex_nibble(lat_w5c0[3:0]);
			8'd169: line_byte = " ";
			8'd170: line_byte = hex_nibble(lat_w5c1[7:4]);
			8'd171: line_byte = hex_nibble(lat_w5c1[3:0]);
			8'd172: line_byte = " ";
			8'd173: line_byte = hex_nibble(lat_w5c2[7:4]);
			8'd174: line_byte = hex_nibble(lat_w5c2[3:0]);
			8'd175: line_byte = " ";
			8'd176: line_byte = hex_nibble(lat_w5c3[7:4]);
			8'd177: line_byte = hex_nibble(lat_w5c3[3:0]);

			// " N5:####" v262 total writes-to-$005C counter
			8'd178: line_byte = " ";
			8'd179: line_byte = "N";
			8'd180: line_byte = "5";
			8'd181: line_byte = ":";
			8'd182: line_byte = hex_nibble(lat_w5cN[15:12]);
			8'd183: line_byte = hex_nibble(lat_w5cN[11:8]);
			8'd184: line_byte = hex_nibble(lat_w5cN[7:4]);
			8'd185: line_byte = hex_nibble(lat_w5cN[3:0]);

			// v263: " IF:####" irq_fall_count (source IRQ_N falling edges)
			8'd186: line_byte = " ";
			8'd187: line_byte = "I";
			8'd188: line_byte = "F";
			8'd189: line_byte = ":";
			8'd190: line_byte = hex_nibble(lat_irq_fall[15:12]);
			8'd191: line_byte = hex_nibble(lat_irq_fall[11:8]);
			8'd192: line_byte = hex_nibble(lat_irq_fall[7:4]);
			8'd193: line_byte = hex_nibble(lat_irq_fall[3:0]);

			// v341 doom bitmap probe (2026-05-14): " 1D:####" — replaces
			// dead R7 doom-wait probe. First 2 hex digits = last value
			// at bank $00:$1D02; last 2 hex digits = last value at $1D04.
			// Doom's frame-flip code at $80:$0B40 reads $1D04 then BEQs
			// to pick VIC bank 3 ($C000) vs 1 ($4000). HW stuck at
			// DD00=$02 (bank 1) implies $1D04 != 0; surfacing both bytes
			// confirms the IRQ-handler producer at $0F58 ran (writes
			// $1D04) and the consumer at $0EED loop is/isn't advancing.
			8'd194: line_byte = " ";
			8'd195: line_byte = "1";
			8'd196: line_byte = "D";
			8'd197: line_byte = ":";
			8'd198: line_byte = hex_nibble(lat_m1d02[7:4]);
			8'd199: line_byte = hex_nibble(lat_m1d02[3:0]);
			8'd200: line_byte = hex_nibble(lat_m1d04[7:4]);
			8'd201: line_byte = hex_nibble(lat_m1d04[3:0]);

			// 2026-05-09 vanilla-cpu-swap: VIC bank-select probes
			// (replaces v271 AW/PA). " D1:## D8:## C2:##   " — last
			// CPU writes to $D011 (bitmap-mode bit), $D018 (screen+
			// char/bitmap base), $DD00 (CIA2 PRA = VIC bank select).
			// Goal: explain Doom's blank screen — does VIC see the
			// region Doom writes bitmap data into? DL bug is fixed
			// in master so AW/PA are obsolete here.
			// Width = 21 bytes (202..222) including 3 trailing spaces.
			8'd202: line_byte = " ";
			8'd203: line_byte = "D";
			8'd204: line_byte = "1";
			8'd205: line_byte = ":";
			8'd206: line_byte = hex_nibble(lat_d011v[7:4]);
			8'd207: line_byte = hex_nibble(lat_d011v[3:0]);
			8'd208: line_byte = " ";
			8'd209: line_byte = "D";
			8'd210: line_byte = "8";
			8'd211: line_byte = ":";
			8'd212: line_byte = hex_nibble(lat_d018v[7:4]);
			8'd213: line_byte = hex_nibble(lat_d018v[3:0]);
			8'd214: line_byte = " ";
			8'd215: line_byte = "C";
			8'd216: line_byte = "2";
			8'd217: line_byte = ":";
			8'd218: line_byte = hex_nibble(lat_dd00v[7:4]);
			8'd219: line_byte = hex_nibble(lat_dd00v[3:0]);
			// v341: append " D6:##" — $D016 latched last cpuDo. MCM bit
			// (bit 4) confirms multicolor bitmap vs hires; VICE shows
			// D016=$D8 (MCM=1) during Doom gameplay.
			8'd220: line_byte = " ";
			8'd221: line_byte = "D";
			8'd222: line_byte = "6";
			8'd223: line_byte = ":";
			8'd224: line_byte = hex_nibble(lat_d016v[7:4]);
			8'd225: line_byte = hex_nibble(lat_d016v[3:0]);
			// v346 doom bitmap-content probe: " B6:##" — per-frame
			// sticky OR of vicDi (the byte VIC fetches from RAM).
			// If $00 across Doom runtime, VIC sees only zeros →
			// screen genuinely empty. If non-zero, VIC sees data
			// and the black has a non-memory cause.
			8'd226: line_byte = " ";
			8'd227: line_byte = "B";
			8'd228: line_byte = "6";
			8'd229: line_byte = ":";
			8'd230: line_byte = hex_nibble(lat_vic_di_or[7:4]);
			8'd231: line_byte = hex_nibble(lat_vic_di_or[3:0]);
			// v347 " B1:## B3:##" — bm1/bm3 per-frame CPU-write counters
			8'd232: line_byte = " ";
			8'd233: line_byte = "B";
			8'd234: line_byte = "1";
			8'd235: line_byte = ":";
			8'd236: line_byte = hex_nibble(lat_bm1_writes[7:4]);
			8'd237: line_byte = hex_nibble(lat_bm1_writes[3:0]);
			8'd238: line_byte = " ";
			8'd239: line_byte = "B";
			8'd240: line_byte = "3";
			8'd241: line_byte = ":";
			8'd242: line_byte = hex_nibble(lat_bm3_writes[7:4]);
			8'd243: line_byte = hex_nibble(lat_bm3_writes[3:0]);

			// v9 MCP probe (2026-05-24): " DR:#### D9:####" appended.
			// DR = pool.dc0d_rd_count (CIA1 ICR reads, side-effect-bearing)
			// D9 = pool.d019_wr_count (CPU writes to $D019, ack chain)
			// Differential v8↔MCP-active hypothesis: if MCP causes double
			// reads of $DC0D, DR will be ~2× higher in MCP-active. If the
			// CPU is stuck in IRQ and never reaches the ack write, D9 will
			// be lower in MCP-active.
			8'd244: line_byte = " ";
			8'd245: line_byte = "D";
			8'd246: line_byte = "R";
			8'd247: line_byte = ":";
			8'd248: line_byte = hex_nibble(lat_dc0d_rd[15:12]);
			8'd249: line_byte = hex_nibble(lat_dc0d_rd[11:8]);
			8'd250: line_byte = hex_nibble(lat_dc0d_rd[7:4]);
			8'd251: line_byte = hex_nibble(lat_dc0d_rd[3:0]);
			8'd252: line_byte = " ";
			8'd253: line_byte = "D";
			8'd254: line_byte = "9";
			8'd255: line_byte = ":";
			9'd256: line_byte = hex_nibble(lat_d019_wr[15:12]);
			9'd257: line_byte = hex_nibble(lat_d019_wr[11:8]);
			9'd258: line_byte = hex_nibble(lat_d019_wr[7:4]);
			9'd259: line_byte = hex_nibble(lat_d019_wr[3:0]);

			// v12 (2026-05-24): " C1:####" — CIA1-only IRQ falling edges.
			// If C1 ≈ IF in both passthrough and MCP, the CIA1 IRQ output is
			// firing normally and the wedge is downstream of the AND. If C1
			// drops along with IF in MCP, MCP affects CIA1 IRQ generation.
			9'd260: line_byte = " ";
			9'd261: line_byte = "C";
			9'd262: line_byte = "1";
			9'd263: line_byte = ":";
			9'd264: line_byte = hex_nibble(lat_irq_cia1_fall[15:12]);
			9'd265: line_byte = hex_nibble(lat_irq_cia1_fall[11:8]);
			9'd266: line_byte = hex_nibble(lat_irq_cia1_fall[7:4]);
			9'd267: line_byte = hex_nibble(lat_irq_cia1_fall[3:0]);

			// v12b (2026-05-24): " IM:## CR:##" — CIA1 IMR mask (5 bits, hi
			// nibble = '0') + CRA Timer A control. If MCP causes a phantom
			// write that clears imr (bit0 = TA enable) or cra[0] (timer run),
			// IM or CR will differ from passthrough.
			9'd268: line_byte = " ";
			9'd269: line_byte = "I";
			9'd270: line_byte = "M";
			9'd271: line_byte = ":";
			9'd272: line_byte = hex_nibble({3'b000, lat_cia1_imr[4]});
			9'd273: line_byte = hex_nibble(lat_cia1_imr[3:0]);
			9'd274: line_byte = " ";
			9'd275: line_byte = "C";
			9'd276: line_byte = "R";
			9'd277: line_byte = ":";
			9'd278: line_byte = hex_nibble(lat_cia1_cra[7:4]);
			9'd279: line_byte = hex_nibble(lat_cia1_cra[3:0]);

			// Option F (2026-05-25): " M2:## T2:##" CIA2 IMR + CRA snapshots.
			// M2 hi nibble = '0' (imr is 5 bits). Renamed from I2/C2 to avoid
			// collision with the legacy "C2:" field appearing earlier in line.
			9'd280: line_byte = " ";
			9'd281: line_byte = "M";
			9'd282: line_byte = "2";
			9'd283: line_byte = ":";
			9'd284: line_byte = hex_nibble({3'b000, lat_cia2_imr[4]});
			9'd285: line_byte = hex_nibble(lat_cia2_imr[3:0]);
			9'd286: line_byte = " ";
			9'd287: line_byte = "T";
			9'd288: line_byte = "2";
			9'd289: line_byte = ":";
			9'd290: line_byte = hex_nibble(lat_cia2_cra[7:4]);
			9'd291: line_byte = hex_nibble(lat_cia2_cra[3:0]);

			// Option G (2026-05-25): " PA:## PB:## DA:## DB:##" CIA2 port + DDR.
			// CIA2 PRA $DD00 = IEC ATN/CLK/DATA out + serial bus drive bits.
			// CIA2 DDRA $DD02 sets which bits are outputs. If MCP phantom-clears
			// DDRA bits, IEC outputs go hi-Z and drive sees no command edges.
			9'd292: line_byte = " ";
			9'd293: line_byte = "P";
			9'd294: line_byte = "A";
			9'd295: line_byte = ":";
			9'd296: line_byte = hex_nibble(lat_cia2_pra[7:4]);
			9'd297: line_byte = hex_nibble(lat_cia2_pra[3:0]);
			9'd298: line_byte = " ";
			9'd299: line_byte = "P";
			9'd300: line_byte = "B";
			9'd301: line_byte = ":";
			9'd302: line_byte = hex_nibble(lat_cia2_prb[7:4]);
			9'd303: line_byte = hex_nibble(lat_cia2_prb[3:0]);
			9'd304: line_byte = " ";
			9'd305: line_byte = "D";
			9'd306: line_byte = "A";
			9'd307: line_byte = ":";
			9'd308: line_byte = hex_nibble(lat_cia2_ddra[7:4]);
			9'd309: line_byte = hex_nibble(lat_cia2_ddra[3:0]);
			9'd310: line_byte = " ";
			9'd311: line_byte = "D";
			9'd312: line_byte = "B";
			9'd313: line_byte = ":";
			9'd314: line_byte = hex_nibble(lat_cia2_ddrb[7:4]);
			9'd315: line_byte = hex_nibble(lat_cia2_ddrb[3:0]);

			// Milestone B (2026-05-25): bridge-internal UART probes per
			// docs/milestone_b_bridge_probe_design.md §B.3. Layout:
			//   " FS:# DI:## RQ:#### AK:#### VF:##"
			// 33 bytes total — FS=5, DI=6, RQ=8, AK=8, VF=6.
			// " FS:#" — bridge FSM state (1 hex char, 0..3).
			9'd316: line_byte = " ";
			9'd317: line_byte = "F";
			9'd318: line_byte = "S";
			9'd319: line_byte = ":";
			9'd320: line_byte = hex_nibble(lat_bridge_fsm_state);
			// " DI:##" — last_bus_di (bus_di_capture_reg).
			9'd321: line_byte = " ";
			9'd322: line_byte = "D";
			9'd323: line_byte = "I";
			9'd324: line_byte = ":";
			9'd325: line_byte = hex_nibble(lat_bridge_last_bus_di[7:4]);
			9'd326: line_byte = hex_nibble(lat_bridge_last_bus_di[3:0]);
			// " RQ:####" — saturating IDLE→REQ_PENDING request count.
			9'd327: line_byte = " ";
			9'd328: line_byte = "R";
			9'd329: line_byte = "Q";
			9'd330: line_byte = ":";
			9'd331: line_byte = hex_nibble(lat_bridge_req_count[15:12]);
			9'd332: line_byte = hex_nibble(lat_bridge_req_count[11:8]);
			9'd333: line_byte = hex_nibble(lat_bridge_req_count[7:4]);
			9'd334: line_byte = hex_nibble(lat_bridge_req_count[3:0]);
			// " AK:####" — saturating WAIT_ACK→LATCH ack count.
			9'd335: line_byte = " ";
			9'd336: line_byte = "A";
			9'd337: line_byte = "K";
			9'd338: line_byte = ":";
			9'd339: line_byte = hex_nibble(lat_bridge_ack_count[15:12]);
			9'd340: line_byte = hex_nibble(lat_bridge_ack_count[11:8]);
			9'd341: line_byte = hex_nibble(lat_bridge_ack_count[7:4]);
			9'd342: line_byte = hex_nibble(lat_bridge_ack_count[3:0]);
			// " VF:##" — saturating $00:$FFFE/$FFFF read count (IRQs).
			9'd343: line_byte = " ";
			9'd344: line_byte = "V";
			9'd345: line_byte = "F";
			9'd346: line_byte = ":";
			9'd347: line_byte = hex_nibble(lat_bridge_vec_fetch_count[7:4]);
			9'd348: line_byte = hex_nibble(lat_bridge_vec_fetch_count[3:0]);

			// Milestone B v2 (2026-05-26 — Codex Design 3) field layout:
			//   " WD:####"  — max WAIT_ACK dwell per frame (Race β detector)
			//   " FL:##"    — sticky activity flags
			//                 bit 0 = req_seen (any IDLE→REQ_PENDING)
			//                 bit 1 = ack_seen (any WAIT_ACK→LATCH)
			//                 bit 2 = wait_seen (any clk_cpu in WAIT_ACK)
			//                 bit 7 = wait_dwell saturated to $FFFF
			//   " GM:##"    — max RQ-AK gap per frame (sanity check)
			// " WD:####"
			9'd349: line_byte = " ";
			9'd350: line_byte = "W";
			9'd351: line_byte = "D";
			9'd352: line_byte = ":";
			9'd353: line_byte = hex_nibble(lat_bridge_wait_dwell_max[15:12]);
			9'd354: line_byte = hex_nibble(lat_bridge_wait_dwell_max[11:8]);
			9'd355: line_byte = hex_nibble(lat_bridge_wait_dwell_max[7:4]);
			9'd356: line_byte = hex_nibble(lat_bridge_wait_dwell_max[3:0]);
			// " FL:##"
			9'd357: line_byte = " ";
			9'd358: line_byte = "F";
			9'd359: line_byte = "L";
			9'd360: line_byte = ":";
			9'd361: line_byte = hex_nibble(lat_bridge_activity_flags[7:4]);
			9'd362: line_byte = hex_nibble(lat_bridge_activity_flags[3:0]);
			// " GM:##"
			9'd363: line_byte = " ";
			9'd364: line_byte = "G";
			9'd365: line_byte = "M";
			9'd366: line_byte = ":";
			9'd367: line_byte = hex_nibble(lat_bridge_gap_max[7:4]);
			9'd368: line_byte = hex_nibble(lat_bridge_gap_max[3:0]);

			// mb-probe-003: CIA1 Timer A internal state.
			//   " TA:####" = lat_cia1_timer_a       (live counter)
			//   " TL:####" = lat_cia1_timer_a_latch (reload value {ta_hi,ta_lo})
			//   " IC:##"   = lat_cia1_icr           (raw 5-bit ICR; bit 0 = TA pending)
			// " TA:####"
			9'd369: line_byte = " ";
			9'd370: line_byte = "T";
			9'd371: line_byte = "A";
			9'd372: line_byte = ":";
			9'd373: line_byte = hex_nibble(lat_cia1_timer_a[15:12]);
			9'd374: line_byte = hex_nibble(lat_cia1_timer_a[11:8]);
			9'd375: line_byte = hex_nibble(lat_cia1_timer_a[7:4]);
			9'd376: line_byte = hex_nibble(lat_cia1_timer_a[3:0]);
			// " TL:####"
			9'd377: line_byte = " ";
			9'd378: line_byte = "T";
			9'd379: line_byte = "L";
			9'd380: line_byte = ":";
			9'd381: line_byte = hex_nibble(lat_cia1_timer_a_latch[15:12]);
			9'd382: line_byte = hex_nibble(lat_cia1_timer_a_latch[11:8]);
			9'd383: line_byte = hex_nibble(lat_cia1_timer_a_latch[7:4]);
			9'd384: line_byte = hex_nibble(lat_cia1_timer_a_latch[3:0]);
			// " IC:##" — upper nibble is bit 4 only (icr is 5 bits)
			9'd385: line_byte = " ";
			9'd386: line_byte = "I";
			9'd387: line_byte = "C";
			9'd388: line_byte = ":";
			9'd389: line_byte = hex_nibble({3'b000, lat_cia1_icr[4]});
			9'd390: line_byte = hex_nibble(lat_cia1_icr[3:0]);

			// 2026-05-28: " IE:##" live IEC lines (1MHz LOAD wedge probe).
			//   bit0=c64_data bit1=c64_clk bit2=c64_atn(1=released)
			//   bit3=drive_data(1=released,0=pulling) bit4=drive_clk
			9'd391: line_byte = " ";
			9'd392: line_byte = "I";
			9'd393: line_byte = "E";
			9'd394: line_byte = ":";
			9'd395: line_byte = hex_nibble(lat_iec_lines[7:4]);
			9'd396: line_byte = hex_nibble(lat_iec_lines[3:0]);

			// iter-30 (2026-06-13): " WF:## WW:##" write-fraction observer
			// (reuses the same dead cpu_cache HR/HW slot the iter-29 page-hit
			// observer used; same lat_cache_hr/hw regs, now fed by the
			// WRITEFRAC_OBSERVER in fpga64_sid_iec.vhd). WF = SuperRAM WRITES per
			// last 256 SuperRAM CPU SDRAM accesses (sat $FF; /2.56 = write %). WW =
			// window-completion counter (advances => observer is live). HIGH WF =>
			// posted-write buffer (Track C) has high payoff. (When PAGEHIT_OBSERVER
			// is on instead, these two bytes carry PH/PW page-hit data — same slot.)
			9'd397: line_byte = " ";
			9'd398: line_byte = "B";
			9'd399: line_byte = "F";
			9'd400: line_byte = ":";
			9'd401: line_byte = hex_nibble(lat_cache_hr[7:4]);
			9'd402: line_byte = hex_nibble(lat_cache_hr[3:0]);
			9'd403: line_byte = " ";
			9'd404: line_byte = "B";
			9'd405: line_byte = "W";
			9'd406: line_byte = ":";
			9'd407: line_byte = hex_nibble(lat_cache_hw[7:4]);
			9'd408: line_byte = hex_nibble(lat_cache_hw[3:0]);

			// 29th pass (Wolf3D bank-$28 freeze, 2026-08-25): trace_pc4/pc5
			// + trace_op4/op5, the 2 opcode fetches captured right after
			// the trace-ring's freeze-trigger landing PC (trace_pc3).
			// UART-only field -- see lat_tr_pc4 declaration comment.
			9'd409: line_byte = " ";
			9'd410: line_byte = "P";
			9'd411: line_byte = "4";
			9'd412: line_byte = ":";
			9'd413: line_byte = hex_nibble(lat_tr_pc4[23:20]);
			9'd414: line_byte = hex_nibble(lat_tr_pc4[19:16]);
			9'd415: line_byte = hex_nibble(lat_tr_pc4[15:12]);
			9'd416: line_byte = hex_nibble(lat_tr_pc4[11:8]);
			9'd417: line_byte = hex_nibble(lat_tr_pc4[7:4]);
			9'd418: line_byte = hex_nibble(lat_tr_pc4[3:0]);
			9'd419: line_byte = " ";
			9'd420: line_byte = "O";
			9'd421: line_byte = "4";
			9'd422: line_byte = ":";
			9'd423: line_byte = hex_nibble(lat_tr_op4[7:4]);
			9'd424: line_byte = hex_nibble(lat_tr_op4[3:0]);
			9'd425: line_byte = " ";
			9'd426: line_byte = "P";
			9'd427: line_byte = "5";
			9'd428: line_byte = ":";
			9'd429: line_byte = hex_nibble(lat_tr_pc5[23:20]);
			9'd430: line_byte = hex_nibble(lat_tr_pc5[19:16]);
			9'd431: line_byte = hex_nibble(lat_tr_pc5[15:12]);
			9'd432: line_byte = hex_nibble(lat_tr_pc5[11:8]);
			9'd433: line_byte = hex_nibble(lat_tr_pc5[7:4]);
			9'd434: line_byte = hex_nibble(lat_tr_pc5[3:0]);
			9'd435: line_byte = " ";
			9'd436: line_byte = "O";
			9'd437: line_byte = "5";
			9'd438: line_byte = ":";
			9'd439: line_byte = hex_nibble(lat_tr_op5[7:4]);
			9'd440: line_byte = hex_nibble(lat_tr_op5[3:0]);

			// 31st pass (Wolf3D freeze, 2026-08-25): screen-RAM write
			// observer -- SW = PC of last write into $0400-$07E7 bank $00
			// since loader_armed_r; SC = saturating write count. Answers
			// whether anything still writes to screen RAM during the
			// confirmed ~10-min visual freeze (see
			// project_wolf3d_postreu_bank28_freeze_regression.md).
			9'd441: line_byte = " ";
			9'd442: line_byte = "S";
			9'd443: line_byte = "W";
			9'd444: line_byte = ":";
			9'd445: line_byte = hex_nibble(lat_scr_write_pc[23:20]);
			9'd446: line_byte = hex_nibble(lat_scr_write_pc[19:16]);
			9'd447: line_byte = hex_nibble(lat_scr_write_pc[15:12]);
			9'd448: line_byte = hex_nibble(lat_scr_write_pc[11:8]);
			9'd449: line_byte = hex_nibble(lat_scr_write_pc[7:4]);
			9'd450: line_byte = hex_nibble(lat_scr_write_pc[3:0]);
			9'd451: line_byte = " ";
			9'd452: line_byte = "S";
			9'd453: line_byte = "C";
			9'd454: line_byte = ":";
			9'd455: line_byte = hex_nibble(lat_scr_write_count[7:4]);
			9'd456: line_byte = hex_nibble(lat_scr_write_count[3:0]);

			// 32nd pass (Wolf3D freeze, 2026-08-25): 2 more post-trigger
			// ring slots (pc6/pc7), extending the 29th pass's pc4/pc5 to
			// 4 total post-landing fetches (see trace_frozen_r comment
			// in fpga64_sid_iec.vhd).
			9'd457: line_byte = " ";
			9'd458: line_byte = "P";
			9'd459: line_byte = "6";
			9'd460: line_byte = ":";
			9'd461: line_byte = hex_nibble(lat_tr_pc6[23:20]);
			9'd462: line_byte = hex_nibble(lat_tr_pc6[19:16]);
			9'd463: line_byte = hex_nibble(lat_tr_pc6[15:12]);
			9'd464: line_byte = hex_nibble(lat_tr_pc6[11:8]);
			9'd465: line_byte = hex_nibble(lat_tr_pc6[7:4]);
			9'd466: line_byte = hex_nibble(lat_tr_pc6[3:0]);
			9'd467: line_byte = " ";
			9'd468: line_byte = "O";
			9'd469: line_byte = "6";
			9'd470: line_byte = ":";
			9'd471: line_byte = hex_nibble(lat_tr_op6[7:4]);
			9'd472: line_byte = hex_nibble(lat_tr_op6[3:0]);

			9'd473: line_byte = " ";
			9'd474: line_byte = "P";
			9'd475: line_byte = "7";
			9'd476: line_byte = ":";
			9'd477: line_byte = hex_nibble(lat_tr_pc7[23:20]);
			9'd478: line_byte = hex_nibble(lat_tr_pc7[19:16]);
			9'd479: line_byte = hex_nibble(lat_tr_pc7[15:12]);
			9'd480: line_byte = hex_nibble(lat_tr_pc7[11:8]);
			9'd481: line_byte = hex_nibble(lat_tr_pc7[7:4]);
			9'd482: line_byte = hex_nibble(lat_tr_pc7[3:0]);
			9'd483: line_byte = " ";
			9'd484: line_byte = "O";
			9'd485: line_byte = "7";
			9'd486: line_byte = ":";
			9'd487: line_byte = hex_nibble(lat_tr_op7[7:4]);
			9'd488: line_byte = hex_nibble(lat_tr_op7[3:0]);

			// 33rd pass (Wolf3D freeze, 2026-08-26): JSR-ring snapshot at
			// the moment of the last screen write -- CA = newest call
			// site (jsr_pc_t3 at write time), CB = next-newest (t2).
			9'd489: line_byte = " ";
			9'd490: line_byte = "C";
			9'd491: line_byte = "A";
			9'd492: line_byte = ":";
			9'd493: line_byte = hex_nibble(lat_scr_write_jsr_a[15:12]);
			9'd494: line_byte = hex_nibble(lat_scr_write_jsr_a[11:8]);
			9'd495: line_byte = hex_nibble(lat_scr_write_jsr_a[7:4]);
			9'd496: line_byte = hex_nibble(lat_scr_write_jsr_a[3:0]);
			9'd497: line_byte = " ";
			9'd498: line_byte = "C";
			9'd499: line_byte = "B";
			9'd500: line_byte = ":";
			9'd501: line_byte = hex_nibble(lat_scr_write_jsr_b[15:12]);
			9'd502: line_byte = hex_nibble(lat_scr_write_jsr_b[11:8]);
			9'd503: line_byte = hex_nibble(lat_scr_write_jsr_b[7:4]);
			9'd504: line_byte = hex_nibble(lat_scr_write_jsr_b[3:0]);

			// 34th pass (Wolf3D freeze, 2026-08-26): always-live current
			// opcode byte, paired with the already-live PC field so a
			// stuck loop's per-address opcode can be reconstructed
			// offline from repeated UART sampling.
			10'd505: line_byte = " ";
			10'd506: line_byte = "O";
			10'd507: line_byte = "P";
			10'd508: line_byte = ":";
			10'd509: line_byte = hex_nibble(lat_cur_op[7:4]);
			10'd510: line_byte = hex_nibble(lat_cur_op[3:0]);
			// 36th pass: Wolf3D $0AC3-$0B0F copy-loop compare-operand
			// snoops (LA:=LDA operand addr, SB:=SBC operand addr,
			// LX:=LDX operand addr, all hi-then-lo hex nibbles).
			10'd511: line_byte = " ";
			10'd512: line_byte = "L";
			10'd513: line_byte = "A";
			10'd514: line_byte = ":";
			10'd515: line_byte = hex_nibble(lat_wloop_lda_hi[7:4]);
			10'd516: line_byte = hex_nibble(lat_wloop_lda_hi[3:0]);
			10'd517: line_byte = hex_nibble(lat_wloop_lda_lo[7:4]);
			10'd518: line_byte = hex_nibble(lat_wloop_lda_lo[3:0]);
			10'd519: line_byte = " ";
			10'd520: line_byte = "S";
			10'd521: line_byte = "B";
			10'd522: line_byte = ":";
			10'd523: line_byte = hex_nibble(lat_wloop_sbc_hi[7:4]);
			10'd524: line_byte = hex_nibble(lat_wloop_sbc_hi[3:0]);
			10'd525: line_byte = hex_nibble(lat_wloop_sbc_lo[7:4]);
			10'd526: line_byte = hex_nibble(lat_wloop_sbc_lo[3:0]);
			10'd527: line_byte = " ";
			10'd528: line_byte = "L";
			10'd529: line_byte = "X";
			10'd530: line_byte = ":";
			10'd531: line_byte = hex_nibble(lat_wloop_ldx_hi[7:4]);
			10'd532: line_byte = hex_nibble(lat_wloop_ldx_hi[3:0]);
			10'd533: line_byte = hex_nibble(lat_wloop_ldx_lo[7:4]);
			10'd534: line_byte = hex_nibble(lat_wloop_ldx_lo[3:0]);
			// 37th pass: runtime values at the loop's compare/index
			// addresses (VL:=value at LA addr, VS:=value at SB addr,
			// VX:=value at LX addr).
			10'd535: line_byte = " ";
			10'd536: line_byte = "V";
			10'd537: line_byte = "L";
			10'd538: line_byte = ":";
			10'd539: line_byte = hex_nibble(lat_wloop_val_2906[7:4]);
			10'd540: line_byte = hex_nibble(lat_wloop_val_2906[3:0]);
			10'd541: line_byte = " ";
			10'd542: line_byte = "V";
			10'd543: line_byte = "S";
			10'd544: line_byte = ":";
			10'd545: line_byte = hex_nibble(lat_wloop_val_4903[7:4]);
			10'd546: line_byte = hex_nibble(lat_wloop_val_4903[3:0]);
			10'd547: line_byte = " ";
			10'd548: line_byte = "V";
			10'd549: line_byte = "X";
			10'd550: line_byte = ":";
			10'd551: line_byte = hex_nibble(lat_wloop_val_f634[7:4]);
			10'd552: line_byte = hex_nibble(lat_wloop_val_f634[3:0]);
			// 38th pass: STA abs operand addresses (S1:/S2:/S3: for
			// the loop's three STA abs instructions in program order).
			10'd553: line_byte = " ";
			10'd554: line_byte = "S";
			10'd555: line_byte = "1";
			10'd556: line_byte = ":";
			10'd557: line_byte = hex_nibble(lat_wloop_sta1_hi[7:4]);
			10'd558: line_byte = hex_nibble(lat_wloop_sta1_hi[3:0]);
			10'd559: line_byte = hex_nibble(lat_wloop_sta1_lo[7:4]);
			10'd560: line_byte = hex_nibble(lat_wloop_sta1_lo[3:0]);
			10'd561: line_byte = " ";
			10'd562: line_byte = "S";
			10'd563: line_byte = "2";
			10'd564: line_byte = ":";
			10'd565: line_byte = hex_nibble(lat_wloop_sta2_hi[7:4]);
			10'd566: line_byte = hex_nibble(lat_wloop_sta2_hi[3:0]);
			10'd567: line_byte = hex_nibble(lat_wloop_sta2_lo[7:4]);
			10'd568: line_byte = hex_nibble(lat_wloop_sta2_lo[3:0]);
			10'd569: line_byte = " ";
			10'd570: line_byte = "S";
			10'd571: line_byte = "3";
			10'd572: line_byte = ":";
			10'd573: line_byte = hex_nibble(lat_wloop_sta3_hi[7:4]);
			10'd574: line_byte = hex_nibble(lat_wloop_sta3_hi[3:0]);
			10'd575: line_byte = hex_nibble(lat_wloop_sta3_lo[7:4]);
			10'd576: line_byte = hex_nibble(lat_wloop_sta3_lo[3:0]);
			// 39th pass: operand addresses of the arithmetic feeding
			// STA1 (IC:=INC operand, L1:/L2:=the two LDA operands,
			// AD:=ADC operand).
			10'd577: line_byte = " ";
			10'd578: line_byte = "I";
			10'd579: line_byte = "C";
			10'd580: line_byte = ":";
			10'd581: line_byte = hex_nibble(lat_wloop_inc_hi[7:4]);
			10'd582: line_byte = hex_nibble(lat_wloop_inc_hi[3:0]);
			10'd583: line_byte = hex_nibble(lat_wloop_inc_lo[7:4]);
			10'd584: line_byte = hex_nibble(lat_wloop_inc_lo[3:0]);
			10'd585: line_byte = " ";
			10'd586: line_byte = "L";
			10'd587: line_byte = "1";
			10'd588: line_byte = ":";
			10'd589: line_byte = hex_nibble(lat_wloop_lda1_hi[7:4]);
			10'd590: line_byte = hex_nibble(lat_wloop_lda1_hi[3:0]);
			10'd591: line_byte = hex_nibble(lat_wloop_lda1_lo[7:4]);
			10'd592: line_byte = hex_nibble(lat_wloop_lda1_lo[3:0]);
			10'd593: line_byte = " ";
			10'd594: line_byte = "L";
			10'd595: line_byte = "2";
			10'd596: line_byte = ":";
			10'd597: line_byte = hex_nibble(lat_wloop_lda2_hi[7:4]);
			10'd598: line_byte = hex_nibble(lat_wloop_lda2_hi[3:0]);
			10'd599: line_byte = hex_nibble(lat_wloop_lda2_lo[7:4]);
			10'd600: line_byte = hex_nibble(lat_wloop_lda2_lo[3:0]);
			10'd601: line_byte = " ";
			10'd602: line_byte = "A";
			10'd603: line_byte = "D";
			10'd604: line_byte = ":";
			10'd605: line_byte = hex_nibble(lat_wloop_adc_hi[7:4]);
			10'd606: line_byte = hex_nibble(lat_wloop_adc_hi[3:0]);
			10'd607: line_byte = hex_nibble(lat_wloop_adc_lo[7:4]);
			10'd608: line_byte = hex_nibble(lat_wloop_adc_lo[3:0]);
			// 40th pass: raw code-byte dump at $0AEC-$0AF8 (13 bytes),
			// label RB: followed by 26 hex chars (2 per byte).
			10'd609: line_byte = " ";
			10'd610: line_byte = "R";
			10'd611: line_byte = "B";
			10'd612: line_byte = ":";
			10'd613: line_byte = hex_nibble(lat_wloop_rb0[7:4]);
			10'd614: line_byte = hex_nibble(lat_wloop_rb0[3:0]);
			10'd615: line_byte = hex_nibble(lat_wloop_rb1[7:4]);
			10'd616: line_byte = hex_nibble(lat_wloop_rb1[3:0]);
			10'd617: line_byte = hex_nibble(lat_wloop_rb2[7:4]);
			10'd618: line_byte = hex_nibble(lat_wloop_rb2[3:0]);
			10'd619: line_byte = hex_nibble(lat_wloop_rb3[7:4]);
			10'd620: line_byte = hex_nibble(lat_wloop_rb3[3:0]);
			10'd621: line_byte = hex_nibble(lat_wloop_rb4[7:4]);
			10'd622: line_byte = hex_nibble(lat_wloop_rb4[3:0]);
			10'd623: line_byte = hex_nibble(lat_wloop_rb5[7:4]);
			10'd624: line_byte = hex_nibble(lat_wloop_rb5[3:0]);
			10'd625: line_byte = hex_nibble(lat_wloop_rb6[7:4]);
			10'd626: line_byte = hex_nibble(lat_wloop_rb6[3:0]);
			10'd627: line_byte = hex_nibble(lat_wloop_rb7[7:4]);
			10'd628: line_byte = hex_nibble(lat_wloop_rb7[3:0]);
			10'd629: line_byte = hex_nibble(lat_wloop_rb8[7:4]);
			10'd630: line_byte = hex_nibble(lat_wloop_rb8[3:0]);
			10'd631: line_byte = hex_nibble(lat_wloop_rb9[7:4]);
			10'd632: line_byte = hex_nibble(lat_wloop_rb9[3:0]);
			10'd633: line_byte = hex_nibble(lat_wloop_rb10[7:4]);
			10'd634: line_byte = hex_nibble(lat_wloop_rb10[3:0]);
			10'd635: line_byte = hex_nibble(lat_wloop_rb11[7:4]);
			10'd636: line_byte = hex_nibble(lat_wloop_rb11[3:0]);
			10'd637: line_byte = hex_nibble(lat_wloop_rb12[7:4]);
			10'd638: line_byte = hex_nibble(lat_wloop_rb12[3:0]);
			// 41st pass: write-bus-gated $2906 snoop. W2:ccvv where cc
			// is the saturating write count (0 = never written) and vv
			// is the last-written value.
			10'd639: line_byte = " ";
			10'd640: line_byte = "W";
			10'd641: line_byte = "2";
			10'd642: line_byte = ":";
			10'd643: line_byte = hex_nibble(lat_wloop_w2906_cnt[7:4]);
			10'd644: line_byte = hex_nibble(lat_wloop_w2906_cnt[3:0]);
			10'd645: line_byte = hex_nibble(lat_wloop_w2906_val[7:4]);
			10'd646: line_byte = hex_nibble(lat_wloop_w2906_val[3:0]);
			// 42nd pass: raw code-byte dump at $0AF9-$0B10 (24 bytes),
			// continuing the 40th pass's ground-truth dump forward.
			10'd647: line_byte = " ";
			10'd648: line_byte = "R";
			10'd649: line_byte = "B";
			10'd650: line_byte = "2";
			10'd651: line_byte = ":";
			10'd652: line_byte = hex_nibble(lat_wloop_rb13[7:4]);
			10'd653: line_byte = hex_nibble(lat_wloop_rb13[3:0]);
			10'd654: line_byte = hex_nibble(lat_wloop_rb14[7:4]);
			10'd655: line_byte = hex_nibble(lat_wloop_rb14[3:0]);
			10'd656: line_byte = hex_nibble(lat_wloop_rb15[7:4]);
			10'd657: line_byte = hex_nibble(lat_wloop_rb15[3:0]);
			10'd658: line_byte = hex_nibble(lat_wloop_rb16[7:4]);
			10'd659: line_byte = hex_nibble(lat_wloop_rb16[3:0]);
			10'd660: line_byte = hex_nibble(lat_wloop_rb17[7:4]);
			10'd661: line_byte = hex_nibble(lat_wloop_rb17[3:0]);
			10'd662: line_byte = hex_nibble(lat_wloop_rb18[7:4]);
			10'd663: line_byte = hex_nibble(lat_wloop_rb18[3:0]);
			10'd664: line_byte = hex_nibble(lat_wloop_rb19[7:4]);
			10'd665: line_byte = hex_nibble(lat_wloop_rb19[3:0]);
			10'd666: line_byte = hex_nibble(lat_wloop_rb20[7:4]);
			10'd667: line_byte = hex_nibble(lat_wloop_rb20[3:0]);
			10'd668: line_byte = hex_nibble(lat_wloop_rb21[7:4]);
			10'd669: line_byte = hex_nibble(lat_wloop_rb21[3:0]);
			10'd670: line_byte = hex_nibble(lat_wloop_rb22[7:4]);
			10'd671: line_byte = hex_nibble(lat_wloop_rb22[3:0]);
			10'd672: line_byte = hex_nibble(lat_wloop_rb23[7:4]);
			10'd673: line_byte = hex_nibble(lat_wloop_rb23[3:0]);
			10'd674: line_byte = hex_nibble(lat_wloop_rb24[7:4]);
			10'd675: line_byte = hex_nibble(lat_wloop_rb24[3:0]);
			10'd676: line_byte = hex_nibble(lat_wloop_rb25[7:4]);
			10'd677: line_byte = hex_nibble(lat_wloop_rb25[3:0]);
			10'd678: line_byte = hex_nibble(lat_wloop_rb26[7:4]);
			10'd679: line_byte = hex_nibble(lat_wloop_rb26[3:0]);
			10'd680: line_byte = hex_nibble(lat_wloop_rb27[7:4]);
			10'd681: line_byte = hex_nibble(lat_wloop_rb27[3:0]);
			10'd682: line_byte = hex_nibble(lat_wloop_rb28[7:4]);
			10'd683: line_byte = hex_nibble(lat_wloop_rb28[3:0]);
			10'd684: line_byte = hex_nibble(lat_wloop_rb29[7:4]);
			10'd685: line_byte = hex_nibble(lat_wloop_rb29[3:0]);
			10'd686: line_byte = hex_nibble(lat_wloop_rb30[7:4]);
			10'd687: line_byte = hex_nibble(lat_wloop_rb30[3:0]);
			10'd688: line_byte = hex_nibble(lat_wloop_rb31[7:4]);
			10'd689: line_byte = hex_nibble(lat_wloop_rb31[3:0]);
			10'd690: line_byte = hex_nibble(lat_wloop_rb32[7:4]);
			10'd691: line_byte = hex_nibble(lat_wloop_rb32[3:0]);
			10'd692: line_byte = hex_nibble(lat_wloop_rb33[7:4]);
			10'd693: line_byte = hex_nibble(lat_wloop_rb33[3:0]);
			10'd694: line_byte = hex_nibble(lat_wloop_rb34[7:4]);
			10'd695: line_byte = hex_nibble(lat_wloop_rb34[3:0]);
			10'd696: line_byte = hex_nibble(lat_wloop_rb35[7:4]);
			10'd697: line_byte = hex_nibble(lat_wloop_rb35[3:0]);
			10'd698: line_byte = hex_nibble(lat_wloop_rb36[7:4]);
			10'd699: line_byte = hex_nibble(lat_wloop_rb36[3:0]);
			// 43rd pass: steady-state values of the two ADC step
			// deltas ($292E/$2930) implicated by the 42nd pass's
			// disasm as feeding the frozen $2906 STA.
			10'd700: line_byte = " ";
			10'd701: line_byte = "D";
			10'd702: line_byte = "2";
			10'd703: line_byte = ":";
			10'd704: line_byte = hex_nibble(lat_wloop_d292e[7:4]);
			10'd705: line_byte = hex_nibble(lat_wloop_d292e[3:0]);
			10'd706: line_byte = hex_nibble(lat_wloop_d2930[7:4]);
			10'd707: line_byte = hex_nibble(lat_wloop_d2930[3:0]);
			// 44th pass: write-bus-gated proof of whether $292E/$2930
			// are EVER written -- cnt/val pairs for each address.
			10'd708: line_byte = " ";
			10'd709: line_byte = "W";
			10'd710: line_byte = "3";
			10'd711: line_byte = ":";
			10'd712: line_byte = hex_nibble(lat_wloop_w292e_cnt[7:4]);
			10'd713: line_byte = hex_nibble(lat_wloop_w292e_cnt[3:0]);
			10'd714: line_byte = hex_nibble(lat_wloop_w292e_val[7:4]);
			10'd715: line_byte = hex_nibble(lat_wloop_w292e_val[3:0]);
			10'd716: line_byte = hex_nibble(lat_wloop_w2930_cnt[7:4]);
			10'd717: line_byte = hex_nibble(lat_wloop_w2930_cnt[3:0]);
			10'd718: line_byte = hex_nibble(lat_wloop_w2930_val[7:4]);
			10'd719: line_byte = hex_nibble(lat_wloop_w2930_val[3:0]);
			10'd720: line_byte = 8'h0A;

			default: line_byte = 8'h20;
		endcase
	endfunction

	always @(posedge clk) begin
		vblank_d <= vblank;
		tx_send  <= 1'b0;

		if (reset || !enable) begin
			byte_idx     <= LINE_LEN;
			byte_pending <= 1'b0;
			tx_data      <= 8'h00;
		end
		else begin
			// Latch + start a new line on each vblank rising edge,
			// but only if the previous one finished (otherwise we drop
			// this frame to keep the line atomic).
			if (vblank_rise && byte_idx >= LINE_LEN && !tx_busy) begin
				lat_frame <= pool.frame_count;
				lat_pc    <= pool.cpu_pc;
				lat_p     <= pool.cpu_p;
				lat_v0    <= pool.wr02_v0;
				lat_v1    <= pool.wr02_v1;
				lat_v2    <= pool.wr02_v2;
				lat_v3    <= pool.wr02_v3;
				lat_y     <= pool.wr02_y;
				lat_x     <= pool.wr02_x;
				lat_sp    <= pool.cpu_sp;     // v280 doom triage
				lat_wp    <= pool.wr02_pc;
				lat_cg    <= pool.cnt_wr02_chg;
				lat_w1    <= {pool.trace_op2, pool.trace_op3};  // OP probe (2026-05-10)
				lat_tr_pc4 <= pool.trace_pc4;
				lat_tr_pc5 <= pool.trace_pc5;
				lat_tr_op4 <= pool.trace_op4;
				lat_tr_op5 <= pool.trace_op5;
				lat_scr_write_pc    <= pool.scr_write_pc;
				lat_scr_write_count <= pool.scr_write_count;
				lat_tr_pc6 <= pool.trace_pc6;
				lat_tr_pc7 <= pool.trace_pc7;
				lat_tr_op6 <= pool.trace_op6;
				lat_tr_op7 <= pool.trace_op7;
				lat_scr_write_jsr_a <= pool.scr_write_jsr_a;
				lat_scr_write_jsr_b <= pool.scr_write_jsr_b;
				lat_cur_op <= pool.cur_op;
				lat_wloop_lda_lo <= pool.wloop_lda_lo;
				lat_wloop_lda_hi <= pool.wloop_lda_hi;
				lat_wloop_sbc_lo <= pool.wloop_sbc_lo;
				lat_wloop_sbc_hi <= pool.wloop_sbc_hi;
				lat_wloop_ldx_lo <= pool.wloop_ldx_lo;
				lat_wloop_ldx_hi <= pool.wloop_ldx_hi;
				lat_wloop_val_2906 <= pool.wloop_val_2906;
				lat_wloop_val_4903 <= pool.wloop_val_4903;
				lat_wloop_val_f634 <= pool.wloop_val_f634;
				lat_wloop_sta1_lo <= pool.wloop_sta1_lo;
				lat_wloop_sta1_hi <= pool.wloop_sta1_hi;
				lat_wloop_sta2_lo <= pool.wloop_sta2_lo;
				lat_wloop_sta2_hi <= pool.wloop_sta2_hi;
				lat_wloop_sta3_lo <= pool.wloop_sta3_lo;
				lat_wloop_sta3_hi <= pool.wloop_sta3_hi;
				lat_wloop_inc_lo  <= pool.wloop_inc_lo;
				lat_wloop_inc_hi  <= pool.wloop_inc_hi;
				lat_wloop_lda1_lo <= pool.wloop_lda1_lo;
				lat_wloop_lda1_hi <= pool.wloop_lda1_hi;
				lat_wloop_lda2_lo <= pool.wloop_lda2_lo;
				lat_wloop_lda2_hi <= pool.wloop_lda2_hi;
				lat_wloop_adc_lo  <= pool.wloop_adc_lo;
				lat_wloop_adc_hi  <= pool.wloop_adc_hi;
				lat_wloop_rb0     <= pool.wloop_rb0;
				lat_wloop_rb1     <= pool.wloop_rb1;
				lat_wloop_rb2     <= pool.wloop_rb2;
				lat_wloop_rb3     <= pool.wloop_rb3;
				lat_wloop_rb4     <= pool.wloop_rb4;
				lat_wloop_rb5     <= pool.wloop_rb5;
				lat_wloop_rb6     <= pool.wloop_rb6;
				lat_wloop_rb7     <= pool.wloop_rb7;
				lat_wloop_rb8     <= pool.wloop_rb8;
				lat_wloop_rb9     <= pool.wloop_rb9;
				lat_wloop_rb10    <= pool.wloop_rb10;
				lat_wloop_rb11    <= pool.wloop_rb11;
				lat_wloop_rb12    <= pool.wloop_rb12;
				lat_wloop_w2906_cnt <= pool.wloop_w2906_cnt;
				lat_wloop_w2906_val <= pool.wloop_w2906_val;
				lat_wloop_rb13    <= pool.wloop_rb13;
				lat_wloop_rb14    <= pool.wloop_rb14;
				lat_wloop_rb15    <= pool.wloop_rb15;
				lat_wloop_rb16    <= pool.wloop_rb16;
				lat_wloop_rb17    <= pool.wloop_rb17;
				lat_wloop_rb18    <= pool.wloop_rb18;
				lat_wloop_rb19    <= pool.wloop_rb19;
				lat_wloop_rb20    <= pool.wloop_rb20;
				lat_wloop_rb21    <= pool.wloop_rb21;
				lat_wloop_rb22    <= pool.wloop_rb22;
				lat_wloop_rb23    <= pool.wloop_rb23;
				lat_wloop_rb24    <= pool.wloop_rb24;
				lat_wloop_rb25    <= pool.wloop_rb25;
				lat_wloop_rb26    <= pool.wloop_rb26;
				lat_wloop_rb27    <= pool.wloop_rb27;
				lat_wloop_rb28    <= pool.wloop_rb28;
				lat_wloop_rb29    <= pool.wloop_rb29;
				lat_wloop_rb30    <= pool.wloop_rb30;
				lat_wloop_rb31    <= pool.wloop_rb31;
				lat_wloop_rb32    <= pool.wloop_rb32;
				lat_wloop_rb33    <= pool.wloop_rb33;
				lat_wloop_rb34    <= pool.wloop_rb34;
				lat_wloop_rb35    <= pool.wloop_rb35;
				lat_wloop_rb36    <= pool.wloop_rb36;
				lat_wloop_d292e   <= pool.wloop_d292e;
				lat_wloop_d2930   <= pool.wloop_d2930;
				lat_wloop_w292e_cnt <= pool.wloop_w292e_cnt;
				lat_wloop_w292e_val <= pool.wloop_w292e_val;
				lat_wloop_w2930_cnt <= pool.wloop_w2930_cnt;
				lat_wloop_w2930_val <= pool.wloop_w2930_val;
				lat_cy    <= pool.cnt_wr02;
				lat_jsr0  <= pool.jsr_pc_t0;
				lat_jsr1  <= pool.jsr_pc_t1;
				lat_jsr2  <= pool.jsr_pc_t2;
				lat_jsr3  <= pool.jsr_pc_t3;
				lat_jmp0  <= pool.jmp_tgt_t0;
				lat_jmp1  <= pool.jmp_tgt_t1;
				lat_jmp2  <= pool.jmp_tgt_t2;
				lat_jmp3  <= pool.jmp_tgt_t3;
				lat_m40   <= pool.mem_40;
				lat_m44   <= pool.mem_44;
				lat_m5c   <= pool.mem_5C;
				lat_pc_main <= pool.pc_main;
				lat_pc_irq  <= pool.pc_irq;
				lat_m45     <= pool.mem_45;
				lat_c30     <= pool.cnt_pc_30;
				lat_c97     <= pool.cnt_pc_97;
				lat_d000    <= pool.d000_last_val;
				lat_d001    <= pool.d001_last_val;
				lat_d002    <= pool.d002_last_val;
				lat_d003    <= pool.d003_last_val;
				lat_w5c0    <= pool.wr5C_v0;
				lat_w5c1    <= pool.wr5C_v1;
				lat_w5c2    <= pool.wr5C_v2;
				lat_w5c3    <= pool.wr5C_v3;
				lat_w5cN    <= pool.cnt_wr5C;
				lat_irq_fall  <= pool.irq_fall_count;
				lat_irq_vec   <= pool.irq_vec_count;
				// 2026-05-09 doom-wait probe — last read in $00:$07xx
				lat_rd07addr  <= pool.rd07xx_addr;
				lat_rd07data  <= pool.rd07xx_data;
				lat_d019_rd   <= pool.d019_last_read;
				lat_d019_seen <= pool.d019_seen_bits;
				// v267: $D012 raster-IRQ tail-chain timing latches
				lat_d012_wc   <= pool.d012_write_cycles;
				lat_d012_rr   <= pool.raster_at_d012;
				lat_d012_dv   <= pool.d012_last_val;
				// v268: IRQ rising-edge counter latches
				lat_irq_rise_combined <= pool.irq_combined_rise_count;
				lat_irq_rise_vic      <= pool.irq_vic_rise_count;
				// v269: VIC-internal $D019 ack diagnostic latches
				lat_vic_d019_wr       <= pool.vic_d019_wr_count;
				lat_vic_resetraster   <= pool.vic_resetraster_count;
				// v9 MCP probe (2026-05-24): CIA1 ICR-read + d019 ack-write
				lat_dc0d_rd           <= pool.dc0d_rd_count;
				lat_d019_wr           <= pool.d019_wr_count;
				// v12 (2026-05-24): CIA1-only IRQ falling edges
				lat_irq_cia1_fall     <= pool.irq_cia1_fall_count;
				// v12b (2026-05-24): CIA1 IMR/CRA snapshots
				lat_cia1_imr          <= pool.cia1_imr;
				lat_cia1_cra          <= pool.cia1_cra;
				// Option F (2026-05-25): CIA2 imr/cra snapshots
				lat_cia2_imr          <= pool.cia2_imr;
				lat_cia2_cra          <= pool.cia2_cra;
				// Option G (2026-05-25): CIA2 PRA/PRB/DDR snapshots
				lat_cia2_pra          <= pool.cia2_pra;
				lat_cia2_prb          <= pool.cia2_prb;
				lat_cia2_ddra         <= pool.cia2_ddra;
				lat_cia2_ddrb         <= pool.cia2_ddrb;
				// v309: BRK vector lo/hi
				lat_brk_vec_lo        <= pool.brk_vec_lo;
				lat_brk_vec_hi        <= pool.brk_vec_hi;
				// v270: $D019 writer-PC + sticky cpuDo OR latches
				lat_d019_pc      <= pool.d019_last_pc;
				lat_d019_val     <= pool.d019_last_val;
				lat_d019_seen_w  <= pool.d019_seen_writes;
				// v271: $D019 ack-write counter + ack-write PC latches
				lat_d019_ack_count <= pool.d019_ack_count;
				lat_d019_ack_pc    <= pool.d019_ack_pc;
				// 2026-05-09 vanilla-cpu-swap: VIC-bank probe latches
				lat_d011v <= pool.vic_d011;
				lat_d018v <= pool.vic_d018;
				lat_dd00v <= pool.vic_dd00;
				// v341 doom bitmap probe
				lat_m1d02 <= pool.mem_1d02;
				lat_m1d04 <= pool.mem_1d04;
				lat_d016v <= pool.vic_d016;
				// v346 doom bitmap-content probe (per-frame vicDi OR)
				lat_vic_di_or <= pool.vic_di_or;
				// v347 doom bitmap-write probe (bm1/bm3 per-frame counters)
				lat_bm1_writes <= pool.bm1_writes;
				lat_bm3_writes <= pool.bm3_writes;
				// more-turbo iter-4d: read-only cpu_cache hit-rate observer.
				lat_cache_hr   <= pool.cache_hr;
				lat_cache_hw   <= pool.cache_hw;
				// Milestone B (2026-05-25): bridge-internal UART probes per
				// docs/milestone_b_bridge_probe_design.md §B. Already
				// 2-FF-synced to clk_sys in c64.sv; latch once per vblank
				// so the UART line stays internally consistent.
				lat_bridge_fsm_state       <= pool.bridge_fsm_state;
				lat_bridge_last_bus_di     <= pool.bridge_last_bus_di;
				lat_bridge_req_count       <= pool.bridge_req_count;
				lat_bridge_ack_count       <= pool.bridge_ack_count;
				lat_bridge_vec_fetch_count <= pool.bridge_vec_fetch_count;
				// Milestone B v2 (2026-05-26): vblank-snapped probes.
				lat_bridge_wait_dwell_max  <= pool.bridge_wait_dwell_max;
				lat_bridge_activity_flags  <= pool.bridge_activity_flags;
				lat_bridge_gap_max         <= pool.bridge_gap_max;
				// 2026-05-28: live IEC line states (1MHz LOAD wedge probe).
				lat_iec_lines              <= pool.iec_lines;
				// mb-probe-003: CIA1 internal taps (clk_sys-domain regs,
				// no sync needed — captured at vblank for line consistency).
				lat_cia1_timer_a           <= pool.cia1_timer_a;
				lat_cia1_timer_a_latch     <= pool.cia1_timer_a_latch;
				lat_cia1_icr               <= pool.cia1_icr;
				byte_idx  <= 9'd0;
			end
			else if (byte_idx < LINE_LEN && !tx_busy && !byte_pending) begin
				tx_data      <= line_byte(byte_idx);
				tx_send      <= 1'b1;
				byte_pending <= 1'b1;
			end
			else if (byte_pending && tx_busy) begin
				// Send pulse acknowledged by transmitter; advance.
				byte_pending <= 1'b0;
				byte_idx     <= byte_idx + 9'd1;
			end
		end
	end

endmodule

`endif
