// debug_overlay_format.sv
//
// Layout 1 (DL triage) -- 22 chars x 4 rows.
//
//   Row 0: "REU C=#### A=######   "  c64-target / RAM addr (24-bit hex)
//   Row 1: "VIC 18=## 16=## R=### "  $D018, $D016, raster line (hex)
//   Row 2: "PC=###### P=## B=##   "  CPU PC + P (NV-MX-DIZC) + DBR
//   Row 3: "CMD=## E=# DD=## SC=# "  REU last cmd, emu mode, $DD00, scpu_en
//
// 2026-04-30 dropped F=#### from row 2 to make room for P (status flags)
// and B (DBR) — needed to detect emu-mode flag drift in DL triage. If P
// shows X or M cleared (bits 4-5) while E=1, that's a P65C816 bug.
// Frame counter still ticks in pool.frame_count for future layouts.
//
// Each cell maps to a 6-bit glyph id (debug_font_4x6 allocation: 0..9
// for digits, 10..35 for A..Z, 36 = space, 39 = '=').

`include "debug_pkg.svh"

module debug_overlay_format
`ifdef DBG_OVERLAY
(
	input  dbg_pool_t  pool,
	input  logic [4:0] cell_x,
	input  logic [3:0] cell_y,
	output logic [5:0] glyph_id
);
`else
(
	input  logic [4:0] cell_x,
	input  logic [3:0] cell_y,
	output logic [5:0] glyph_id
);
`endif

	// Glyph aliases
	localparam [5:0] G_SP = 6'd36;
	localparam [5:0] G_EQ = 6'd39;
	localparam [5:0] G_A  = 6'd10;
	localparam [5:0] G_B  = 6'd11;
	localparam [5:0] G_C  = 6'd12;
	localparam [5:0] G_D  = 6'd13;
	localparam [5:0] G_E  = 6'd14;
	localparam [5:0] G_F  = 6'd15;
	localparam [5:0] G_I  = 6'd18;
	localparam [5:0] G_M  = 6'd22;
	localparam [5:0] G_P  = 6'd25;
	localparam [5:0] G_R  = 6'd27;
	localparam [5:0] G_S  = 6'd28;
	localparam [5:0] G_U  = 6'd30;
	localparam [5:0] G_V  = 6'd31;

	// Helper: 4-bit hex nibble -> glyph. The font allocates 0..9 for
	// digits and 10..15 for A..F contiguously, so the nibble value
	// zero-extended to 6 bits IS the glyph id.
	function automatic logic [5:0] hex(input logic [3:0] n);
		hex = {2'b00, n};
	endfunction

`ifdef DBG_OVERLAY
	always_comb begin
		glyph_id = G_SP;
		case (cell_y)
			// ===== Row 0: REU C=#### A=######   =================
			4'd0: case (cell_x)
				5'd0:  glyph_id = G_R;
				5'd1:  glyph_id = G_E;
				5'd2:  glyph_id = G_U;
				5'd3:  glyph_id = G_SP;
				5'd4:  glyph_id = G_C;
				5'd5:  glyph_id = G_EQ;
				5'd6:  glyph_id = hex(pool.reu_c64_addr[15:12]);
				5'd7:  glyph_id = hex(pool.reu_c64_addr[11:8]);
				5'd8:  glyph_id = hex(pool.reu_c64_addr[7:4]);
				5'd9:  glyph_id = hex(pool.reu_c64_addr[3:0]);
				5'd10: glyph_id = G_SP;
				5'd11: glyph_id = G_A;
				5'd12: glyph_id = G_EQ;
				5'd13: glyph_id = hex(pool.reu_reu_addr[23:20]);
				5'd14: glyph_id = hex(pool.reu_reu_addr[19:16]);
				5'd15: glyph_id = hex(pool.reu_reu_addr[15:12]);
				5'd16: glyph_id = hex(pool.reu_reu_addr[11:8]);
				5'd17: glyph_id = hex(pool.reu_reu_addr[7:4]);
				5'd18: glyph_id = hex(pool.reu_reu_addr[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 1: VIC 18=## 16=## R=### ==================
			4'd1: case (cell_x)
				5'd0:  glyph_id = G_V;
				5'd1:  glyph_id = G_I;
				5'd2:  glyph_id = G_C;
				5'd3:  glyph_id = G_SP;
				5'd4:  glyph_id = 6'd1;       // '1'
				5'd5:  glyph_id = 6'd8;       // '8'
				5'd6:  glyph_id = G_EQ;
				5'd7:  glyph_id = hex(pool.vic_d018[7:4]);
				5'd8:  glyph_id = hex(pool.vic_d018[3:0]);
				5'd9:  glyph_id = G_SP;
				5'd10: glyph_id = 6'd1;       // '1'
				5'd11: glyph_id = 6'd6;       // '6'
				5'd12: glyph_id = G_EQ;
				5'd13: glyph_id = hex(pool.vic_d016[7:4]);
				5'd14: glyph_id = hex(pool.vic_d016[3:0]);
				5'd15: glyph_id = G_SP;
				5'd16: glyph_id = G_R;
				5'd17: glyph_id = G_EQ;
				5'd18: glyph_id = hex(pool.vic_raster[11:8]);
				5'd19: glyph_id = hex(pool.vic_raster[7:4]);
				5'd20: glyph_id = hex(pool.vic_raster[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 2: PC=###### P=## B=##    ==================
			4'd2: case (cell_x)
				5'd0:  glyph_id = G_P;
				5'd1:  glyph_id = G_C;
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.cpu_pc[23:20]);
				5'd4:  glyph_id = hex(pool.cpu_pc[19:16]);
				5'd5:  glyph_id = hex(pool.cpu_pc[15:12]);
				5'd6:  glyph_id = hex(pool.cpu_pc[11:8]);
				5'd7:  glyph_id = hex(pool.cpu_pc[7:4]);
				5'd8:  glyph_id = hex(pool.cpu_pc[3:0]);
				5'd9:  glyph_id = G_SP;
				5'd10: glyph_id = G_P;
				5'd11: glyph_id = G_EQ;
				5'd12: glyph_id = hex(pool.cpu_p[7:4]);
				5'd13: glyph_id = hex(pool.cpu_p[3:0]);
				5'd14: glyph_id = G_SP;
				5'd15: glyph_id = G_B;
				5'd16: glyph_id = G_EQ;
				5'd17: glyph_id = hex(pool.cpu_dbr[7:4]);
				5'd18: glyph_id = hex(pool.cpu_dbr[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 3: CMD=## E=# DD=## SC=# ==================
			4'd3: case (cell_x)
				5'd0:  glyph_id = G_C;
				5'd1:  glyph_id = G_M;
				5'd2:  glyph_id = G_D;
				5'd3:  glyph_id = G_EQ;
				5'd4:  glyph_id = hex(pool.reu_cmd[7:4]);
				5'd5:  glyph_id = hex(pool.reu_cmd[3:0]);
				5'd6:  glyph_id = G_SP;
				5'd7:  glyph_id = G_E;
				5'd8:  glyph_id = G_EQ;
				5'd9:  glyph_id = hex({3'b000, pool.cpu_flags[3]});  // emu_mode bit
				5'd10: glyph_id = G_SP;
				5'd11: glyph_id = G_D;
				5'd12: glyph_id = G_D;
				5'd13: glyph_id = G_EQ;
				5'd14: glyph_id = hex(pool.vic_dd00[7:4]);
				5'd15: glyph_id = hex(pool.vic_dd00[3:0]);
				5'd16: glyph_id = G_SP;
				5'd17: glyph_id = G_S;
				5'd18: glyph_id = G_C;
				5'd19: glyph_id = G_EQ;
				5'd20: glyph_id = hex({3'b000, pool.cpu_flags[4]});  // scpu_en bit
				default: glyph_id = G_SP;
			endcase

			// ===== Row 4: WPC=###### N=##         ==================
			// PC at last $DD00 write, plus 8-bit write count. PC pinpoints
			// which DL routine writes the bad VIC bank (T65=$01, SCPU=$00/$02).
			4'd4: case (cell_x)
				5'd0:  glyph_id = 6'd32;  // 'W'
				5'd1:  glyph_id = G_P;
				5'd2:  glyph_id = G_C;
				5'd3:  glyph_id = G_EQ;
				5'd4:  glyph_id = hex(pool.dd00_write_pc[23:20]);
				5'd5:  glyph_id = hex(pool.dd00_write_pc[19:16]);
				5'd6:  glyph_id = hex(pool.dd00_write_pc[15:12]);
				5'd7:  glyph_id = hex(pool.dd00_write_pc[11:8]);
				5'd8:  glyph_id = hex(pool.dd00_write_pc[7:4]);
				5'd9:  glyph_id = hex(pool.dd00_write_pc[3:0]);
				5'd10: glyph_id = G_SP;
				5'd11: glyph_id = 6'd23;  // 'N'
				5'd12: glyph_id = G_EQ;
				5'd13: glyph_id = hex(pool.dd00_write_count[7:4]);
				5'd14: glyph_id = hex(pool.dd00_write_count[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 5: P0=###### P1=######    ==================
			// Per-value PC capture for $DD00 writes by data nibble [1:0]:
			// P0 = last writer of $00 (bank 3 / $C000-$FFFF)
			// P1 = last writer of $01 (bank 2 / $8000-$BFFF) <- DL bitmap bank
			4'd5: case (cell_x)
				5'd0:  glyph_id = G_P;
				5'd1:  glyph_id = 6'd0;   // '0'
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.dd00_pc_v0[23:20]);
				5'd4:  glyph_id = hex(pool.dd00_pc_v0[19:16]);
				5'd5:  glyph_id = hex(pool.dd00_pc_v0[15:12]);
				5'd6:  glyph_id = hex(pool.dd00_pc_v0[11:8]);
				5'd7:  glyph_id = hex(pool.dd00_pc_v0[7:4]);
				5'd8:  glyph_id = hex(pool.dd00_pc_v0[3:0]);
				5'd9:  glyph_id = G_SP;
				5'd10: glyph_id = G_P;
				5'd11: glyph_id = 6'd1;   // '1'
				5'd12: glyph_id = G_EQ;
				5'd13: glyph_id = hex(pool.dd00_pc_v1[23:20]);
				5'd14: glyph_id = hex(pool.dd00_pc_v1[19:16]);
				5'd15: glyph_id = hex(pool.dd00_pc_v1[15:12]);
				5'd16: glyph_id = hex(pool.dd00_pc_v1[11:8]);
				5'd17: glyph_id = hex(pool.dd00_pc_v1[7:4]);
				5'd18: glyph_id = hex(pool.dd00_pc_v1[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 6: P2=###### P3=######    ==================
			// P2 = last writer of $02 (bank 1 / $4000-$7FFF)
			// P3 = last writer of $03 (bank 0 / $0000-$3FFF, default)
			4'd6: case (cell_x)
				5'd0:  glyph_id = G_P;
				5'd1:  glyph_id = 6'd2;   // '2'
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.dd00_pc_v2[23:20]);
				5'd4:  glyph_id = hex(pool.dd00_pc_v2[19:16]);
				5'd5:  glyph_id = hex(pool.dd00_pc_v2[15:12]);
				5'd6:  glyph_id = hex(pool.dd00_pc_v2[11:8]);
				5'd7:  glyph_id = hex(pool.dd00_pc_v2[7:4]);
				5'd8:  glyph_id = hex(pool.dd00_pc_v2[3:0]);
				5'd9:  glyph_id = G_SP;
				5'd10: glyph_id = G_P;
				5'd11: glyph_id = 6'd3;   // '3'
				5'd12: glyph_id = G_EQ;
				5'd13: glyph_id = hex(pool.dd00_pc_v3[23:20]);
				5'd14: glyph_id = hex(pool.dd00_pc_v3[19:16]);
				5'd15: glyph_id = hex(pool.dd00_pc_v3[15:12]);
				5'd16: glyph_id = hex(pool.dd00_pc_v3[11:8]);
				5'd17: glyph_id = hex(pool.dd00_pc_v3[7:4]);
				5'd18: glyph_id = hex(pool.dd00_pc_v3[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 7: 0=##:1=##:2=##:3=##:#### =================
			// 8-bit per-value $DD00 write counters (no leading 'N' to fit
			// 22 cells). T65 baseline expected to show all 4 incrementing
			// each frame; SCPU=on expected to show N1 / N3 frozen.
			// Cells 18..21 unused.
			4'd7: case (cell_x)
				5'd0:  glyph_id = 6'd0;   // '0'
				5'd1:  glyph_id = G_EQ;
				5'd2:  glyph_id = hex(pool.dd00_cnt_v0[7:4]);
				5'd3:  glyph_id = hex(pool.dd00_cnt_v0[3:0]);
				5'd4:  glyph_id = G_SP;
				5'd5:  glyph_id = 6'd1;   // '1'
				5'd6:  glyph_id = G_EQ;
				5'd7:  glyph_id = hex(pool.dd00_cnt_v1[7:4]);
				5'd8:  glyph_id = hex(pool.dd00_cnt_v1[3:0]);
				5'd9:  glyph_id = G_SP;
				5'd10: glyph_id = 6'd2;   // '2'
				5'd11: glyph_id = G_EQ;
				5'd12: glyph_id = hex(pool.dd00_cnt_v2[7:4]);
				5'd13: glyph_id = hex(pool.dd00_cnt_v2[3:0]);
				5'd14: glyph_id = G_SP;
				5'd15: glyph_id = 6'd3;   // '3'
				5'd16: glyph_id = G_EQ;
				5'd17: glyph_id = hex(pool.dd00_cnt_v3[7:4]);
				5'd18: glyph_id = hex(pool.dd00_cnt_v3[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 8: BPC=######  B=## C=## ===================
			// D018 corruption tracking: BPC = PC of last D018 write where
			// value != $18. B = count of those bad writes. C = total D018
			// write count. T65 baseline: B=00 (never writes != $18).
			// SCPU intermittently writes $FF / $66 — BPC pinpoints the
			// offending routine.
			4'd8: case (cell_x)
				5'd0:  glyph_id = G_B;
				5'd1:  glyph_id = G_P;
				5'd2:  glyph_id = G_C;
				5'd3:  glyph_id = G_EQ;
				5'd4:  glyph_id = hex(pool.d018_bad_pc[23:20]);
				5'd5:  glyph_id = hex(pool.d018_bad_pc[19:16]);
				5'd6:  glyph_id = hex(pool.d018_bad_pc[15:12]);
				5'd7:  glyph_id = hex(pool.d018_bad_pc[11:8]);
				5'd8:  glyph_id = hex(pool.d018_bad_pc[7:4]);
				5'd9:  glyph_id = hex(pool.d018_bad_pc[3:0]);
				5'd10: glyph_id = G_SP;
				5'd11: glyph_id = G_B;
				5'd12: glyph_id = G_EQ;
				5'd13: glyph_id = hex(pool.d018_bad_count[7:4]);
				5'd14: glyph_id = hex(pool.d018_bad_count[3:0]);
				5'd15: glyph_id = G_SP;
				5'd16: glyph_id = G_C;
				5'd17: glyph_id = G_EQ;
				5'd18: glyph_id = hex(pool.d018_count[7:4]);
				5'd19: glyph_id = hex(pool.d018_count[3:0]);
				default: glyph_id = G_SP;
			endcase

			default: glyph_id = G_SP;
		endcase
	end
`else
	always_comb glyph_id = G_SP;
`endif

endmodule
