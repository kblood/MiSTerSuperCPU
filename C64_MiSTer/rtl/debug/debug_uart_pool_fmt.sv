// debug_uart_pool_fmt.sv
//
// Vanilla-cpu-swap minimal UART formatter. Emits ONE ASCII line per
// vblank rising edge containing the dbg_pool fields most relevant for
// the Dragon's Lair / SCPU-emu-mode investigation:
//
//   F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:#### J:#### #### #### #### M:#### #### #### #### G:## ## ## N:###### I:###### B:## C3:#### C9:####\n
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
	reg [23:0] lat_wp;
	reg [15:0] lat_cg;     // v257 cnt_wr02_chg (now repurposed as W1)
	reg [15:0] lat_w1;     // v265 d001_last_pc[15:0] — writer PC of $D001
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
	// v270: $D019 writer PC + last cpuDo + sticky cpuDo OR.
	reg [23:0] lat_d019_pc;
	reg  [7:0] lat_d019_val;
	reg  [7:0] lat_d019_seen_w;
	// v271: $D019 ack-write counter + ack-write PC.
	reg [15:0] lat_d019_ack_count;
	reg [23:0] lat_d019_ack_pc;

	// -----------------------------------------------------------------
	// Send FSM: drive tx_send for one cycle whenever tx is idle and the
	// next byte hasn't been issued yet. byte_idx indexes the line bytes
	// 0..LINE_LEN-1; LINE_LEN signals "line done, idle until next vblank".
	// -----------------------------------------------------------------
	localparam LINE_LEN = 8'd224;

	reg [7:0] byte_idx;
	reg       byte_pending;     // a byte has been latched but not sent

	function [7:0] hex_nibble(input [3:0] n);
		hex_nibble = (n < 4'd10) ? (8'h30 + {4'b0, n})         // '0'..'9'
		                         : (8'h41 + {4'b0, n} - 8'd10); // 'A'..'F'
	endfunction

	// Combinational byte selector — emits the byte for `byte_idx`.
	function [7:0] line_byte(input [7:0] i);
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

			// "YX:####"
			8'd36: line_byte = "Y";
			8'd37: line_byte = "X";
			8'd38: line_byte = ":";
			8'd39: line_byte = hex_nibble(lat_y[7:4]);
			8'd40: line_byte = hex_nibble(lat_y[3:0]);
			8'd41: line_byte = hex_nibble(lat_x[7:4]);
			8'd42: line_byte = hex_nibble(lat_x[3:0]);
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

			// v265: "W1:####" — d001_last_pc[15:0], writer PC of $D001 (sprite0 Y)
			8'd54: line_byte = "W";
			8'd55: line_byte = "1";
			8'd56: line_byte = ":";
			8'd57: line_byte = hex_nibble(lat_w1[15:12]);
			8'd58: line_byte = hex_nibble(lat_w1[11:8]);
			8'd59: line_byte = hex_nibble(lat_w1[7:4]);
			8'd60: line_byte = hex_nibble(lat_w1[3:0]);
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

			// v263: " VC:####" irq_vec_count ($FFFE/$FFFF reads)
			8'd194: line_byte = " ";
			8'd195: line_byte = "V";
			8'd196: line_byte = "C";
			8'd197: line_byte = ":";
			8'd198: line_byte = hex_nibble(lat_irq_vec[15:12]);
			8'd199: line_byte = hex_nibble(lat_irq_vec[11:8]);
			8'd200: line_byte = hex_nibble(lat_irq_vec[7:4]);
			8'd201: line_byte = hex_nibble(lat_irq_vec[3:0]);

			// v271: " AW:#### PA:######   " — count of $D019 writes
			// with cpuDo bit 0 = 1 (real IRST acks), and PC of the
			// most-recent ack write. Replaces v270 D9/P9/S. v270 told
			// us the last write each frame is the cleanup ($F2/$F8);
			// AW/PA pinpoints the actual ack instruction. Predict T65
			// AW=1/frame, SCPU AW=0/frame; T65 PA = ack handler PC.
			// Width = 21 bytes (202..222) including 3 trailing spaces.
			8'd202: line_byte = " ";
			8'd203: line_byte = "A";
			8'd204: line_byte = "W";
			8'd205: line_byte = ":";
			8'd206: line_byte = hex_nibble(lat_d019_ack_count[15:12]);
			8'd207: line_byte = hex_nibble(lat_d019_ack_count[11:8]);
			8'd208: line_byte = hex_nibble(lat_d019_ack_count[7:4]);
			8'd209: line_byte = hex_nibble(lat_d019_ack_count[3:0]);
			8'd210: line_byte = " ";
			8'd211: line_byte = "P";
			8'd212: line_byte = "A";
			8'd213: line_byte = ":";
			8'd214: line_byte = hex_nibble(lat_d019_ack_pc[23:20]);
			8'd215: line_byte = hex_nibble(lat_d019_ack_pc[19:16]);
			8'd216: line_byte = hex_nibble(lat_d019_ack_pc[15:12]);
			8'd217: line_byte = hex_nibble(lat_d019_ack_pc[11:8]);
			8'd218: line_byte = hex_nibble(lat_d019_ack_pc[7:4]);
			8'd219: line_byte = hex_nibble(lat_d019_ack_pc[3:0]);
			8'd220: line_byte = " ";
			8'd221: line_byte = " ";
			8'd222: line_byte = " ";

			// newline (LINE_LEN-1)
			8'd223: line_byte = 8'h0A;

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
				lat_wp    <= pool.wr02_pc;
				lat_cg    <= pool.cnt_wr02_chg;
				lat_w1    <= pool.d001_last_pc[15:0];
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
				// v270: $D019 writer-PC + sticky cpuDo OR latches
				lat_d019_pc      <= pool.d019_last_pc;
				lat_d019_val     <= pool.d019_last_val;
				lat_d019_seen_w  <= pool.d019_seen_writes;
				// v271: $D019 ack-write counter + ack-write PC latches
				lat_d019_ack_count <= pool.d019_ack_count;
				lat_d019_ack_pc    <= pool.d019_ack_pc;
				byte_idx  <= 8'd0;
			end
			else if (byte_idx < LINE_LEN && !tx_busy && !byte_pending) begin
				tx_data      <= line_byte(byte_idx);
				tx_send      <= 1'b1;
				byte_pending <= 1'b1;
			end
			else if (byte_pending && tx_busy) begin
				// Send pulse acknowledged by transmitter; advance.
				byte_pending <= 1'b0;
				byte_idx     <= byte_idx + 8'd1;
			end
		end
	end

endmodule

`endif
