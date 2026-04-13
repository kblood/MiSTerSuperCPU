// debug_uart_fmt.sv - Formats CPU debug state as ASCII hex lines over UART
//
// Sends one line per frame (at vblank) containing CPU state:
//   A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx W:xxxx L:xx[!/.]\n
//
// Fields:
//   A = CPU address (16-bit)
//   K = PBR - Program Bank Register (8-bit)
//   B = Address bus bank byte (8-bit, A23-A16)
//   S = Stack pointer (16-bit)
//   P = Processor status (8-bit)
//   I = Instruction register / opcode (8-bit)
//   E = Emulation mode (1-bit)
//   F = Frame counter (16-bit, for freeze detection)
//   T = Diag byte: b0=turbo,b1=rom_vis,b2=1mhz,b3=iec,b4=overlay,b5=cache,b6=enCpu
//   C = Cache hit count per frame (16-bit)
//   N = enableCpu count per frame (16-bit)
//
// At 115200 baud, each line is ~63 chars = ~5.5ms. One line per frame
// (50Hz PAL / 60Hz NTSC) = well within bandwidth.

module debug_uart_fmt (
	input         clk,
	input         reset,
	input         enable,     // from OSD toggle

	// Debug data inputs (directly from core, latched internally at vblank)
	input         vblank,     // vblank edge triggers a new line
	input  [15:0] cpu_addr,
	input   [7:0] cpu_data,
	input   [7:0] cpu_bank,
	input  [15:0] cpu_sp,
	input   [7:0] cpu_p,
	input   [7:0] cpu_ir,
	input         cpu_emul,
	input   [7:0] cpu_pbr,      // Program Bank Register
	input   [7:0] cpu_dbr,      // Data Bank Register

	// Turbo/cache diagnostics (active signals, counted per frame)
	input         turbo_en,
	input   [7:0] diag,         // diagnostic byte: b0=turbo,b1=rom_vis,b2=1mhz,b3=iec,b4=overlay,b5=cache,b6=enCpu
	input         cache_hit_pulse,
	input         enable_cpu_pulse,
	input         cpu_cyc_pulse,

	// Crash diagnostics
	input  [15:0] native_irq_vec,   // native IRQ vector value ($FFEE/$FFEF)
	input   [7:0] crash_bank,       // first unexpected PBR (crash bank latch)
	input         vic_irq,          // VIC IRQ asserted (active high)

	// Crash trace ring buffer
	// Layout (161 bytes = 1288 bits):
	//   [7:0]       status (bit0 = frozen, bits[5:1] = wp)
	//   [1031:8]    32 × (PC_lo, PC_hi, PBR, IR) — 4 bytes per entry
	//   [1287:1032] 32 × P byte — one per entry, appended
	input [1287:0] trace_buf,

	// UART TX interface
	output reg [7:0] tx_data,
	output reg       tx_send,
	input            tx_busy
);

// Frame counter (increments each vblank)
reg [15:0] frame_cnt;

// Latch debug data at vblank for stable output
reg [15:0] lat_addr;
reg  [7:0] lat_data;
reg  [7:0] lat_bank;
reg [15:0] lat_sp;
reg  [7:0] lat_p;
reg  [7:0] lat_ir;
reg        lat_emul;
reg  [7:0] lat_pbr;
reg  [7:0] lat_dbr;
reg [15:0] lat_frame;
reg        lat_turbo;
reg  [7:0] lat_diag;
reg [19:0] lat_ch_cnt;
reg [19:0] lat_en_cnt;
reg [15:0] lat_irq_vec;
reg  [7:0] lat_crash_bank;
reg        lat_vic_irq;

// Crash trace stream: one entry per vblank when trace is frozen.
// trace_idx cycles 0..31 through the ring buffer after freeze trips.
reg  [4:0] trace_idx;
reg        lat_frozen;
reg  [4:0] lat_trace_idx;
reg [31:0] lat_trace_entry;  // {IR, PBR, PC_hi, PC_lo}
reg  [7:0] lat_trace_p;      // P register for the selected entry

// Per-frame counters (running, latched at vblank)
// 20-bit to avoid 16-bit wrapping (max ~628k cycles/frame)
reg [19:0] ch_cnt;
reg [19:0] en_cnt;
reg [19:0] cy_cnt;
reg [19:0] lat_cy_cnt;

// State machine
reg        vblank_r;
reg        sending;       // currently sending a line
reg [6:0]  char_idx;      // character position within the line
reg        char_pending;  // a character is ready to send

// Line format: "A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx V:xxxx L:xx.\n"
// Total: 77 characters + \n = 78 characters
// Character positions (0-indexed):
//  0-5   A:xxxx
//  6     space
//  7-10  K:xx (PBR)
// 11     space
// 12-15  B:xx (bank)
// 16     space
// 17-22  S:xxxx
// 23     space
// 24-27  P:xx
// 28     space
// 29-32  I:xx
// 33     space
// 34-36  E:x
// 37     space
// 38-43  F:xxxx
// 44     space
// 45-48  T:xx
// 49     space
// 50-55  C:xxxx (20-bit, show top 16)
// 56     space
// 57-62  N:xxxx (20-bit, show top 16)
// 63     space
// 64-69  V:xxxx (native IRQ vector)
// 70     space
// 71-74  L:xx (crash bank latch)
// 75     !/. (VIC IRQ indicator)
// 76     ' ' when frozen (to continue line), '\n' when not
// --- Crash trace extension (only emitted when lat_frozen=1) ---
// 77-81  TR:xx (trace_idx 0..31)
// 82     space
// 83-89  PC:xxxx
// 90     space
// 91-94  K:xx
// 95     space
// 96-99  I:xx
// 100    space
// 101-104 P:xx
// 105    \n
localparam LINE_LEN_NORMAL = 7'd77;
localparam LINE_LEN_FROZEN = 7'd106;
wire [6:0] line_len_cur = lat_frozen ? LINE_LEN_FROZEN : LINE_LEN_NORMAL;

// Hex nibble to ASCII
function [7:0] hex_char;
	input [3:0] nibble;
	hex_char = (nibble < 4'd10) ? (8'h30 + {4'b0, nibble}) : (8'h41 + {4'b0, nibble} - 8'd10);
endfunction

// Combinational mux: select one of 32 trace entries using constant part-selects.
// Avoids variable part-select (which crashed Quartus 17 Analysis & Synthesis).
reg [31:0] trace_entry_sel;
always @(*) begin
	case (trace_idx)
		5'd0:  trace_entry_sel = trace_buf[  39:   8];
		5'd1:  trace_entry_sel = trace_buf[  71:  40];
		5'd2:  trace_entry_sel = trace_buf[ 103:  72];
		5'd3:  trace_entry_sel = trace_buf[ 135: 104];
		5'd4:  trace_entry_sel = trace_buf[ 167: 136];
		5'd5:  trace_entry_sel = trace_buf[ 199: 168];
		5'd6:  trace_entry_sel = trace_buf[ 231: 200];
		5'd7:  trace_entry_sel = trace_buf[ 263: 232];
		5'd8:  trace_entry_sel = trace_buf[ 295: 264];
		5'd9:  trace_entry_sel = trace_buf[ 327: 296];
		5'd10: trace_entry_sel = trace_buf[ 359: 328];
		5'd11: trace_entry_sel = trace_buf[ 391: 360];
		5'd12: trace_entry_sel = trace_buf[ 423: 392];
		5'd13: trace_entry_sel = trace_buf[ 455: 424];
		5'd14: trace_entry_sel = trace_buf[ 487: 456];
		5'd15: trace_entry_sel = trace_buf[ 519: 488];
		5'd16: trace_entry_sel = trace_buf[ 551: 520];
		5'd17: trace_entry_sel = trace_buf[ 583: 552];
		5'd18: trace_entry_sel = trace_buf[ 615: 584];
		5'd19: trace_entry_sel = trace_buf[ 647: 616];
		5'd20: trace_entry_sel = trace_buf[ 679: 648];
		5'd21: trace_entry_sel = trace_buf[ 711: 680];
		5'd22: trace_entry_sel = trace_buf[ 743: 712];
		5'd23: trace_entry_sel = trace_buf[ 775: 744];
		5'd24: trace_entry_sel = trace_buf[ 807: 776];
		5'd25: trace_entry_sel = trace_buf[ 839: 808];
		5'd26: trace_entry_sel = trace_buf[ 871: 840];
		5'd27: trace_entry_sel = trace_buf[ 903: 872];
		5'd28: trace_entry_sel = trace_buf[ 935: 904];
		5'd29: trace_entry_sel = trace_buf[ 967: 936];
		5'd30: trace_entry_sel = trace_buf[ 999: 968];
		5'd31: trace_entry_sel = trace_buf[1031:1000];
		default: trace_entry_sel = 32'h0;
	endcase
end

// Parallel mux for the P byte appended after the main trace region.
// P bytes live at bits 1032..1287, one 8-bit entry per slot.
reg [7:0] trace_p_sel;
always @(*) begin
	case (trace_idx)
		5'd0:  trace_p_sel = trace_buf[1039:1032];
		5'd1:  trace_p_sel = trace_buf[1047:1040];
		5'd2:  trace_p_sel = trace_buf[1055:1048];
		5'd3:  trace_p_sel = trace_buf[1063:1056];
		5'd4:  trace_p_sel = trace_buf[1071:1064];
		5'd5:  trace_p_sel = trace_buf[1079:1072];
		5'd6:  trace_p_sel = trace_buf[1087:1080];
		5'd7:  trace_p_sel = trace_buf[1095:1088];
		5'd8:  trace_p_sel = trace_buf[1103:1096];
		5'd9:  trace_p_sel = trace_buf[1111:1104];
		5'd10: trace_p_sel = trace_buf[1119:1112];
		5'd11: trace_p_sel = trace_buf[1127:1120];
		5'd12: trace_p_sel = trace_buf[1135:1128];
		5'd13: trace_p_sel = trace_buf[1143:1136];
		5'd14: trace_p_sel = trace_buf[1151:1144];
		5'd15: trace_p_sel = trace_buf[1159:1152];
		5'd16: trace_p_sel = trace_buf[1167:1160];
		5'd17: trace_p_sel = trace_buf[1175:1168];
		5'd18: trace_p_sel = trace_buf[1183:1176];
		5'd19: trace_p_sel = trace_buf[1191:1184];
		5'd20: trace_p_sel = trace_buf[1199:1192];
		5'd21: trace_p_sel = trace_buf[1207:1200];
		5'd22: trace_p_sel = trace_buf[1215:1208];
		5'd23: trace_p_sel = trace_buf[1223:1216];
		5'd24: trace_p_sel = trace_buf[1231:1224];
		5'd25: trace_p_sel = trace_buf[1239:1232];
		5'd26: trace_p_sel = trace_buf[1247:1240];
		5'd27: trace_p_sel = trace_buf[1255:1248];
		5'd28: trace_p_sel = trace_buf[1263:1256];
		5'd29: trace_p_sel = trace_buf[1271:1264];
		5'd30: trace_p_sel = trace_buf[1279:1272];
		5'd31: trace_p_sel = trace_buf[1287:1280];
		default: trace_p_sel = 8'h0;
	endcase
end

// Character lookup
reg [7:0] line_char;

always @(*) begin
	case (char_idx)
		7'd0:  line_char = "A";
		7'd1:  line_char = ":";
		7'd2:  line_char = hex_char(lat_addr[15:12]);
		7'd3:  line_char = hex_char(lat_addr[11:8]);
		7'd4:  line_char = hex_char(lat_addr[7:4]);
		7'd5:  line_char = hex_char(lat_addr[3:0]);
		7'd6:  line_char = " ";
		7'd7:  line_char = "K";  // K = PBR (program bank register)
		7'd8:  line_char = ":";
		7'd9:  line_char = hex_char(lat_pbr[7:4]);
		7'd10: line_char = hex_char(lat_pbr[3:0]);
		7'd11: line_char = " ";
		7'd12: line_char = "B";
		7'd13: line_char = ":";
		7'd14: line_char = hex_char(lat_bank[7:4]);
		7'd15: line_char = hex_char(lat_bank[3:0]);
		7'd16: line_char = " ";
		7'd17: line_char = "S";  // S = Stack pointer (16-bit)
		7'd18: line_char = ":";
		7'd19: line_char = hex_char(lat_sp[15:12]);
		7'd20: line_char = hex_char(lat_sp[11:8]);
		7'd21: line_char = hex_char(lat_sp[7:4]);
		7'd22: line_char = hex_char(lat_sp[3:0]);
		7'd23: line_char = " ";
		7'd24: line_char = "P";
		7'd25: line_char = ":";
		7'd26: line_char = hex_char(lat_p[7:4]);
		7'd27: line_char = hex_char(lat_p[3:0]);
		7'd28: line_char = " ";
		7'd29: line_char = "I";
		7'd30: line_char = ":";
		7'd31: line_char = hex_char(lat_ir[7:4]);
		7'd32: line_char = hex_char(lat_ir[3:0]);
		7'd33: line_char = " ";
		7'd34: line_char = "E";
		7'd35: line_char = ":";
		7'd36: line_char = hex_char({3'b0, lat_emul});
		7'd37: line_char = " ";
		7'd38: line_char = "F";
		7'd39: line_char = ":";
		7'd40: line_char = hex_char(lat_frame[15:12]);
		7'd41: line_char = hex_char(lat_frame[11:8]);
		7'd42: line_char = hex_char(lat_frame[7:4]);
		7'd43: line_char = hex_char(lat_frame[3:0]);
		7'd44: line_char = " ";
		7'd45: line_char = "T";
		7'd46: line_char = ":";
		7'd47: line_char = hex_char(lat_diag[7:4]);
		7'd48: line_char = hex_char(lat_diag[3:0]);
		7'd49: line_char = " ";
		7'd50: line_char = "C";
		7'd51: line_char = ":";
		7'd52: line_char = hex_char(lat_ch_cnt[19:16]);
		7'd53: line_char = hex_char(lat_ch_cnt[15:12]);
		7'd54: line_char = hex_char(lat_ch_cnt[11:8]);
		7'd55: line_char = hex_char(lat_ch_cnt[7:4]);
		7'd56: line_char = " ";
		7'd57: line_char = "N";
		7'd58: line_char = ":";
		7'd59: line_char = hex_char(lat_en_cnt[19:16]);
		7'd60: line_char = hex_char(lat_en_cnt[15:12]);
		7'd61: line_char = hex_char(lat_en_cnt[11:8]);
		7'd62: line_char = hex_char(lat_en_cnt[7:4]);
		7'd63: line_char = " ";
		7'd64: line_char = "W";  // W:xxxx = last addr when PBR=$20
		7'd65: line_char = ":";
		7'd66: line_char = hex_char(lat_irq_vec[15:12]);
		7'd67: line_char = hex_char(lat_irq_vec[11:8]);
		7'd68: line_char = hex_char(lat_irq_vec[7:4]);
		7'd69: line_char = hex_char(lat_irq_vec[3:0]);
		7'd70: line_char = " ";
		7'd71: line_char = "L";
		7'd72: line_char = ":";
		7'd73: line_char = hex_char(lat_crash_bank[7:4]);
		7'd74: line_char = hex_char(lat_crash_bank[3:0]);
		7'd75: line_char = lat_vic_irq ? "!" : ".";
		7'd76: line_char = lat_frozen ? " " : 8'h0A;  // continue when frozen
		// Trace extension (only reached when lat_frozen=1)
		7'd77: line_char = "T";
		7'd78: line_char = "R";
		7'd79: line_char = ":";
		7'd80: line_char = hex_char({3'b0, lat_trace_idx[4]});
		7'd81: line_char = hex_char(lat_trace_idx[3:0]);
		7'd82: line_char = " ";
		7'd83: line_char = "P";
		7'd84: line_char = "C";
		7'd85: line_char = ":";
		7'd86: line_char = hex_char(lat_trace_entry[15:12]); // PC_hi[7:4]
		7'd87: line_char = hex_char(lat_trace_entry[11:8]);  // PC_hi[3:0]
		7'd88: line_char = hex_char(lat_trace_entry[7:4]);   // PC_lo[7:4]
		7'd89: line_char = hex_char(lat_trace_entry[3:0]);   // PC_lo[3:0]
		7'd90: line_char = " ";
		7'd91: line_char = "K";
		7'd92: line_char = ":";
		7'd93: line_char = hex_char(lat_trace_entry[23:20]); // PBR[7:4]
		7'd94: line_char = hex_char(lat_trace_entry[19:16]); // PBR[3:0]
		7'd95: line_char = " ";
		7'd96: line_char = "I";
		7'd97: line_char = ":";
		7'd98: line_char = hex_char(lat_trace_entry[31:28]); // IR[7:4]
		7'd99: line_char = hex_char(lat_trace_entry[27:24]); // IR[3:0]
		7'd100: line_char = " ";
		7'd101: line_char = "P";
		7'd102: line_char = ":";
		7'd103: line_char = hex_char(lat_trace_p[7:4]);
		7'd104: line_char = hex_char(lat_trace_p[3:0]);
		7'd105: line_char = 8'h0A;                           // newline
		default: line_char = " ";
	endcase
end

always @(posedge clk) begin
	if (reset) begin
		sending     <= 0;
		char_idx    <= 0;
		tx_send     <= 0;
		char_pending <= 0;
		frame_cnt   <= 0;
		vblank_r    <= 0;
		ch_cnt      <= 0;
		en_cnt      <= 0;
		cy_cnt      <= 0;
		trace_idx       <= 0;
		lat_frozen      <= 0;
		lat_trace_idx   <= 0;
		lat_trace_entry <= 0;
		lat_trace_p     <= 0;
	end
	else begin
		vblank_r <= vblank;
		tx_send  <= 0;

		// Per-frame pulse counters
		if (cache_hit_pulse)
			ch_cnt <= ch_cnt + 1'b1;
		if (enable_cpu_pulse)
			en_cnt <= en_cnt + 1'b1;
		if (cpu_cyc_pulse)
			cy_cnt <= cy_cnt + 1'b1;

		// Detect vblank rising edge → latch data and start sending
		if (vblank && !vblank_r && enable && !sending) begin
			lat_addr   <= cpu_addr;
			lat_data   <= cpu_data;
			lat_bank   <= cpu_bank;
			lat_sp     <= cpu_sp;
			lat_p      <= cpu_p;
			lat_ir     <= cpu_ir;
			lat_emul   <= cpu_emul;
			lat_pbr    <= cpu_pbr;
			lat_dbr    <= cpu_dbr;
			lat_frame  <= frame_cnt;
			lat_turbo  <= turbo_en;
			lat_diag   <= diag;
			lat_ch_cnt <= ch_cnt;
			lat_en_cnt <= en_cnt;
			lat_cy_cnt <= cy_cnt;
			lat_irq_vec <= native_irq_vec;
			lat_crash_bank <= crash_bank;
			lat_vic_irq <= vic_irq;
			frame_cnt  <= frame_cnt + 1'b1;
			ch_cnt     <= 0;
			en_cnt     <= 0;
			cy_cnt     <= 0;

			// Latch frozen status and current trace entry for this frame.
			// trace_entry_sel is a combinational mux selected by trace_idx.
			lat_frozen      <= trace_buf[0];
			lat_trace_idx   <= trace_idx;
			lat_trace_entry <= trace_entry_sel;
			lat_trace_p     <= trace_p_sel;
			if (trace_buf[0])
				trace_idx <= trace_idx + 1'b1;

			sending      <= 1;
			char_idx     <= 0;
			char_pending <= 1;
		end

		// Send characters one at a time
		if (sending && char_pending && !tx_busy) begin
			tx_data      <= line_char;
			tx_send      <= 1;
			char_pending <= 0;
		end

		// After tx_send, advance to next character
		if (sending && !char_pending && !tx_busy && !tx_send) begin
			if (char_idx == line_len_cur - 1'b1) begin
				sending <= 0;
			end
			else begin
				char_idx     <= char_idx + 1'b1;
				char_pending <= 1;
			end
		end
	end
end

endmodule
