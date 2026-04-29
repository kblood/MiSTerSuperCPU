// cap_vic_wr.sv
//
// Latch $D018 / $D016 / $DD00 + raster line. Commit 2: stub emitting '0.
// Commit 5: tap the VIC chip-select + cpuWe path inside fpga64_sid_iec.

module cap_vic_wr (
	input  logic        clk,
	input  logic        rst,

	output logic  [7:0] o_d018,
	output logic  [7:0] o_d016,
	output logic  [7:0] o_dd00,
	output logic [11:0] o_raster
);

	assign o_d018   = '0;
	assign o_d016   = '0;
	assign o_dd00   = '0;
	assign o_raster = '0;

endmodule
