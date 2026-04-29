// cap_cpu_state.sv
//
// Mux T65 vs P65C816 state (PC, P, S, flags) into the pool. Commit 2 is a
// stub; commit 5 wires the real CPU state via debug ports already exposed
// by both wrapper modules (cpu_6510.vhd / cpu_65c816.vhd).

module cap_cpu_state (
	input  logic        clk,
	input  logic        rst,

	output logic [23:0] o_pc,
	output logic  [7:0] o_p,
	output logic  [7:0] o_flags
);

	assign o_pc    = '0;
	assign o_p     = '0;
	assign o_flags = '0;

endmodule
