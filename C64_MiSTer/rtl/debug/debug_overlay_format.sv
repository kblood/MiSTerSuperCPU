// debug_overlay_format.sv
//
// Combinational layout selector. Given the current cell coordinates
// (cell_x 0..21, cell_y 0..3) and the captured pool, returns a 6-bit
// glyph id for the font cascade. Layouts are switched at compile time
// via DBG_LAYOUT (default = 1, populated in commit 6).
//
// Commit 4 just emits a static "READY" string at row 0, spaces elsewhere.
// Commit 6 will replace this with the layout 1 (DL triage) bindings.

`include "debug_pkg.svh"

module debug_overlay_format
`ifdef DBG_OVERLAY
(
	input  dbg_pool_t  pool,
	input  logic [4:0] cell_x,
	input  logic [1:0] cell_y,
	output logic [5:0] glyph_id
);
`else
(
	input  logic [4:0] cell_x,
	input  logic [1:0] cell_y,
	output logic [5:0] glyph_id
);
`endif

	// Glyph constants matching debug_font_4x6 allocation.
	localparam [5:0] G_SP = 6'd36;
	localparam [5:0] G_R  = 6'd27;
	localparam [5:0] G_E  = 6'd14;
	localparam [5:0] G_A  = 6'd10;
	localparam [5:0] G_D  = 6'd13;
	localparam [5:0] G_Y  = 6'd34;

	always_comb begin
		glyph_id = G_SP;
		if (cell_y == 2'd0) begin
			case (cell_x)
				5'd0:  glyph_id = G_R;
				5'd1:  glyph_id = G_E;
				5'd2:  glyph_id = G_A;
				5'd3:  glyph_id = G_D;
				5'd4:  glyph_id = G_Y;
				default: glyph_id = G_SP;
			endcase
		end
	end

endmodule
