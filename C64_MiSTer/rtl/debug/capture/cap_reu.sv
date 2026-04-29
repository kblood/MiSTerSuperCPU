// cap_reu.sv
//
// Snapshot $DF00-$DF0A on $DF01 cmd write + maintain a FETCH execution
// counter. Commit 2 wires this as a zero-emitting stub; commit 5 fills in
// the real capture logic from the reu.v register set.

module cap_reu (
	input  logic        clk,
	input  logic        rst,

	output logic [15:0] o_c64_addr,
	output logic [23:0] o_reu_addr,
	output logic [15:0] o_length,
	output logic  [7:0] o_cmd,
	output logic [15:0] o_fetch_count
);

	assign o_c64_addr    = '0;
	assign o_reu_addr    = '0;
	assign o_length      = '0;
	assign o_cmd         = '0;
	assign o_fetch_count = '0;

endmodule
