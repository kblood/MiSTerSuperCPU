// cap_reu.sv
//
// REU register snapshot. The reu module exposes live register state via
// already-existing reg_addr_c64 / reg_addr_ram / reg_length / reg_cmd
// outputs, and a reg_cmd_count counter. We forward those into the pool
// directly -- no edge latching needed because the regs sit stable for
// many CPU cycles after each cmd write, well long enough for the
// renderer to sample.

module cap_reu (
	input  logic        clk,
	input  logic        rst,

	// Live REU register inputs (driven by reu instance in c64.sv)
	input  logic [15:0] reu_reg_addr_c64,
	input  logic [23:0] reu_reg_addr_ram,
	input  logic [15:0] reu_reg_length,
	input  logic  [7:0] reu_reg_cmd,
	input  logic [15:0] reu_reg_cmd_count,

	// Pool slice
	output logic [15:0] o_c64_addr,
	output logic [23:0] o_reu_addr,
	output logic [15:0] o_length,
	output logic  [7:0] o_cmd,
	output logic [15:0] o_fetch_count
);

	assign o_c64_addr    = reu_reg_addr_c64;
	assign o_reu_addr    = reu_reg_addr_ram;
	assign o_length      = reu_reg_length;
	assign o_cmd         = reu_reg_cmd;
	assign o_fetch_count = reu_reg_cmd_count;

endmodule
