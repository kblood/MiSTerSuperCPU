// cap_frame.sv
//
// 16-bit frame counter, ticked on vsync rising edge. Commit 2 stub; commit 5
// will wire vsync to it.

module cap_frame (
	input  logic        clk,
	input  logic        rst,

	output logic [15:0] o_frame_count
);

	assign o_frame_count = '0;

endmodule
