// debug_uart_pool_fmt.sv
//
// Vanilla-cpu-swap minimal UART formatter. Emits ONE ASCII line per
// vblank rising edge containing the dbg_pool fields most relevant for
// the Dragon's Lair / SCPU-emu-mode investigation:
//
//   F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:#### J:#### #### #### #### M:#### #### #### ####\n
//
// J = 4-deep JSR-PC ring (low 16 bits)         from pool.jsr_pc_t0..t3
// M = 4-deep JMP-indirect target ring          from pool.jmp_tgt_t0..t3
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
	reg [15:0] lat_cg;
	reg [15:0] lat_cy;
	reg [15:0] lat_jsr0, lat_jsr1, lat_jsr2, lat_jsr3;
	reg [15:0] lat_jmp0, lat_jmp1, lat_jmp2, lat_jmp3;

	// -----------------------------------------------------------------
	// Send FSM: drive tx_send for one cycle whenever tx is idle and the
	// next byte hasn't been issued yet. byte_idx indexes the line bytes
	// 0..LINE_LEN-1; LINE_LEN signals "line done, idle until next vblank".
	// -----------------------------------------------------------------
	localparam LINE_LEN = 8'd114;

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

			// "CG:####"
			8'd54: line_byte = "C";
			8'd55: line_byte = "G";
			8'd56: line_byte = ":";
			8'd57: line_byte = hex_nibble(lat_cg[15:12]);
			8'd58: line_byte = hex_nibble(lat_cg[11:8]);
			8'd59: line_byte = hex_nibble(lat_cg[7:4]);
			8'd60: line_byte = hex_nibble(lat_cg[3:0]);
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

			// newline
			8'd113: line_byte = 8'h0A;

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
				lat_cy    <= pool.cnt_wr02;
				lat_jsr0  <= pool.jsr_pc_t0;
				lat_jsr1  <= pool.jsr_pc_t1;
				lat_jsr2  <= pool.jsr_pc_t2;
				lat_jsr3  <= pool.jsr_pc_t3;
				lat_jmp0  <= pool.jmp_tgt_t0;
				lat_jmp1  <= pool.jmp_tgt_t1;
				lat_jmp2  <= pool.jmp_tgt_t2;
				lat_jmp3  <= pool.jmp_tgt_t3;
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
