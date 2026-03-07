// debug_uart_tx.sv - Simple UART transmitter for debug output
//
// Fixed 8N1 format. Active-low idle (line idles HIGH).
// Active only when `enable` is asserted.

module debug_uart_tx #(
	parameter CLK_FREQ = 32000000,
	parameter BAUD     = 115200
)(
	input        clk,
	input        reset,
	input        enable,    // global enable (from OSD toggle)
	input  [7:0] data,      // byte to send
	input        send,      // pulse to begin transmission
	output reg   tx,        // serial output (active low, idle high)
	output reg   busy       // '1' while transmitting
);

localparam CLKS_PER_BIT = CLK_FREQ / BAUD;
localparam CNT_WIDTH    = $clog2(CLKS_PER_BIT);

reg [CNT_WIDTH-1:0] clk_cnt;
reg [3:0]           bit_idx;   // 0=start, 1-8=data, 9=stop
reg [7:0]           shift_reg;

always @(posedge clk) begin
	if (reset || !enable) begin
		tx      <= 1'b1;
		busy    <= 1'b0;
		clk_cnt <= 0;
		bit_idx <= 0;
	end
	else if (!busy) begin
		tx <= 1'b1;  // idle high
		if (send) begin
			busy      <= 1'b1;
			shift_reg <= data;
			clk_cnt   <= 0;
			bit_idx   <= 0;
		end
	end
	else begin
		if (clk_cnt < CLKS_PER_BIT[CNT_WIDTH-1:0] - 1'b1) begin
			clk_cnt <= clk_cnt + 1'b1;
		end
		else begin
			clk_cnt <= 0;
			case (bit_idx)
				4'd0:    tx <= 1'b0;                   // start bit
				4'd1:    tx <= shift_reg[0];
				4'd2:    tx <= shift_reg[1];
				4'd3:    tx <= shift_reg[2];
				4'd4:    tx <= shift_reg[3];
				4'd5:    tx <= shift_reg[4];
				4'd6:    tx <= shift_reg[5];
				4'd7:    tx <= shift_reg[6];
				4'd8:    tx <= shift_reg[7];
				4'd9: begin                             // stop bit
					tx   <= 1'b1;
					busy <= 1'b0;
				end
				default: begin
					tx   <= 1'b1;
					busy <= 1'b0;
				end
			endcase
			if (bit_idx < 4'd10)
				bit_idx <= bit_idx + 1'b1;
		end
	end
end

endmodule
