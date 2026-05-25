// debug_uart_pool_fmt.sv
//
// Vanilla-cpu-swap minimal UART formatter. Emits ONE ASCII line per
// vblank rising edge containing the dbg_pool fields most relevant for
// the Dragon's Lair / SCPU-emu-mode investigation:
//
//   F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:#### J:#### #### #### #### M:#### #### #### #### G:## ## ## N:###### I:###### B:## C3:#### C9:#### D1:## D8:## C2:## D6:##\n
// v341: 1D:#### slot replaces dead R7; D6:## appended (line=230 bytes).
//
// J = 4-deep JSR-PC ring (low 16 bits)         from pool.jsr_pc_t0..t3
// M = 4-deep JMP-indirect target ring          from pool.jmp_tgt_t0..t3
// G = DL gate variables: $40 $44 $5C           from pool.mem_40/mem_44/mem_5C
// N = main-thread PC (last opcode fetch I=0)   from pool.pc_main
// I = IRQ-thread PC  (last opcode fetch I=1)   from pool.pc_irq
// B = wait-loop variable $0045                 from pool.mem_45
// C3 = opcode-fetch count at page $30          from pool.cnt_pc_30
// C9 = opcode-fetch count at page $97          from pool.cnt_pc_97
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
	reg [15:0] lat_sp;          // v280 doom triage: 16-bit SP
	reg [23:0] lat_wp;
	reg [15:0] lat_cg;     // v257 cnt_wr02_chg (now repurposed as W1)
	// 2026-05-10 doom-wait probe (Probe B): repurpose W1 slot to surface the
	// last-2 opcodes the SCPU actually fetched. Layout is now `OP:hh ll` where
	// hh = trace_op2 (one-back) and ll = trace_op3 (newest). Pairs with N
	// (last-fetch-PC main-thread) to confirm whether pc_main is a real
	// instruction or a frozen latch. Doom doesn't write $D001, so dropping
	// the d001_last_pc display loses no useful Doom signal.
	reg [15:0] lat_w1;     // now: {trace_op2, trace_op3} — opcode bytes
	reg [15:0] lat_cy;
	reg [15:0] lat_jsr0, lat_jsr1, lat_jsr2, lat_jsr3;
	reg [15:0] lat_jmp0, lat_jmp1, lat_jmp2, lat_jmp3;
	reg  [7:0] lat_m40, lat_m44, lat_m5c;
	reg [23:0] lat_pc_main, lat_pc_irq;
	reg  [7:0] lat_m45;
	reg [15:0] lat_c30, lat_c97;
	// v264: sprite-position last-write probes (replaces C3/C9 in line)
	reg  [7:0] lat_d000, lat_d001, lat_d002, lat_d003;
	reg  [7:0] lat_w5c0, lat_w5c1, lat_w5c2, lat_w5c3;
	reg [15:0] lat_w5cN;
	// v263: IRQ-source confirmation
	reg [15:0] lat_irq_fall;
	reg [15:0] lat_irq_vec;
	// 2026-05-09 doom-wait probe — last $00:$07xx read addr + data
	reg  [7:0] lat_rd07addr;
	reg  [7:0] lat_rd07data;
	reg  [7:0] lat_d019_rd;
	reg  [3:0] lat_d019_seen;
	// v267: $D012 raster-IRQ tail-chain timing (replaces DR/DS in line).
	reg [15:0] lat_d012_wc;     // d012_write_cycles (clk32 cycles)
	reg  [8:0] lat_d012_rr;     // raster_at_d012 (line 0..311 PAL)
	reg  [7:0] lat_d012_dv;     // d012_last_val (compare value)
	// v268: IRQ rising-edge counters (replaces SP:## ## ## ## in line).
	reg [15:0] lat_irq_rise_combined;
	reg [15:0] lat_irq_rise_vic;
	// v269: VIC-internal $D019 ack diagnostics (replaces IR/IV slot in
	// UART line — IR/IV are still latched to keep parsers backward
	// compatible if needed, but the visible bytes show VR/RR now).
	reg [15:0] lat_vic_d019_wr;
	reg [15:0] lat_vic_resetraster;
	// v9 MCP probe (2026-05-24): dc0d_rd_count (CIA1 ICR read counter)
	// and d019_wr_count (VIC IRQ ack write counter). Differential v8 ↔
	// MCP-active to test double-CIA-read hypothesis.
	reg [15:0] lat_dc0d_rd;
	reg [15:0] lat_d019_wr;
	// v12 (2026-05-24): CIA1-only IRQ falling-edge count, emitted as " C1:####".
	reg [15:0] lat_irq_cia1_fall;
	// v12b (2026-05-24): CIA1 IMR/CRA snapshots, emitted as " IM:## CR:##".
	reg [4:0]  lat_cia1_imr;
	reg [7:0]  lat_cia1_cra;
	reg [4:0]  lat_cia2_imr;
	reg [7:0]  lat_cia2_cra;
	reg [7:0]  lat_cia2_pra;
	reg [7:0]  lat_cia2_prb;
	reg [7:0]  lat_cia2_ddra;
	reg [7:0]  lat_cia2_ddrb;
	// v309 doom wedge: BRK vector lo/hi — repurposes the AC slot.
	reg  [7:0] lat_brk_vec_lo;
	reg  [7:0] lat_brk_vec_hi;
	// v270: $D019 writer PC + last cpuDo + sticky cpuDo OR.
	reg [23:0] lat_d019_pc;
	reg  [7:0] lat_d019_val;
	reg  [7:0] lat_d019_seen_w;
	// v271: $D019 ack-write counter + ack-write PC.
	reg [15:0] lat_d019_ack_count;
	reg [23:0] lat_d019_ack_pc;
	// 2026-05-09 vanilla-cpu-swap: VIC bank-select probes (replaces AW/PA
	// in line bytes 202..219). D1 = $D011 (bit5=bitmap mode, bit4=DEN,
	// bit6=ECM), D8 = $D018 (screen+char/bitmap base), C2 = $DD00
	// (CIA2 PRA bits 0-1 = VIC bank). Together these tell us which 16KB
	// region VIC sees + whether Doom switched to bitmap mode for rendering.
	reg  [7:0] lat_d011v;
	reg  [7:0] lat_d018v;
	reg  [7:0] lat_dd00v;
	// v341 doom bitmap probe (2026-05-14): page-flip handshake bytes at
	// bank $00:$1D02/$1D04 and $D016 MCM bit. After v340n IRQ wedge fix,
	// Doom reaches bitmap mode (D1=$3B) but DD00 stuck at $02 — VIC sees
	// only bank 1 ($4000-$7FFF). $1D04 is the flag Doom's flip code BEQs
	// on; if it never reaches 0, the flip never picks bank 3. D6/$D016
	// MCM bit confirms multicolor vs hires bitmap mode.
	reg  [7:0] lat_m1d02;
	reg  [7:0] lat_m1d04;
	reg  [7:0] lat_d016v;
	// v346 doom bitmap-content probe: per-frame sticky OR of vicDi.
	reg  [7:0] lat_vic_di_or;
	// v347 doom bitmap-write probe: per-frame saturating count of CPU
	// writes to bank-0 SDRAM regions $4000-$5FFF (bm1) and $C000-$DFFF
	// (bm3). Latched on vsync rising edge.
	reg  [7:0] lat_bm1_writes;
	reg  [7:0] lat_bm3_writes;

	// -----------------------------------------------------------------
	// Send FSM: drive tx_send for one cycle whenever tx is idle and the
	// next byte hasn't been issued yet. byte_idx indexes the line bytes
	// 0..LINE_LEN-1; LINE_LEN signals "line done, idle until next vblank".
	// -----------------------------------------------------------------
	// v9 MCP probe (2026-05-24): +16 bytes for " DR:#### D9:####" appended
	// after B3 — dc0d_rd_count and d019_wr_count for MCP-vs-passthrough
	// differential. Newline now at byte 260.
	// Option F (2026-05-25): +12 bytes for " M2:## T2:##" after CR (CIA2 imr/cra).
	// Renamed from I2/C2 to M2/T2 to avoid colliding with legacy C2: field.
	// Option G (2026-05-25): +24 bytes for " PA:## PB:## DA:## DB:##" — CIA2
	// PRA/PRB/DDRA/DDRB to detect IEC-port phantom writes during LOAD"*" wedge.
	// Newline now at byte 318.
	localparam LINE_LEN = 9'd319;

	reg [8:0] byte_idx;
	reg       byte_pending;     // a byte has been latched but not sent

	function [7:0] hex_nibble(input [3:0] n);
		hex_nibble = (n < 4'd10) ? (8'h30 + {4'b0, n})         // '0'..'9'
		                         : (8'h41 + {4'b0, n} - 8'd10); // 'A'..'F'
	endfunction

	// Combinational byte selector — emits the byte for `byte_idx`.
	function [7:0] line_byte(input [8:0] i);
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

			// v280: "SP:####" — 16-bit P65C816 stack pointer (replaces YX).
			// Confirms whether SP=$6C0X at the BRK loop in Doom v274.
			8'd36: line_byte = "S";
			8'd37: line_byte = "P";
			8'd38: line_byte = ":";
			8'd39: line_byte = hex_nibble(lat_sp[15:12]);
			8'd40: line_byte = hex_nibble(lat_sp[11:8]);
			8'd41: line_byte = hex_nibble(lat_sp[7:4]);
			8'd42: line_byte = hex_nibble(lat_sp[3:0]);
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

			// v320 (2026-05-12): "YX:####" repurposes OP slot to show
			// the source address (HI:LO) of the last bank-$2B read of
			// $F7 from SuperRAM. lat_y = $99 (HI), lat_x = $98 (LO).
			// Combined with V ring's source bank, we get a 24-bit
			// SuperRAM address that returned $F7 to the sign-extend.
			8'd54: line_byte = "Y";
			8'd55: line_byte = "X";
			8'd56: line_byte = ":";
			8'd57: line_byte = hex_nibble(lat_y[7:4]);
			8'd58: line_byte = hex_nibble(lat_y[3:0]);
			8'd59: line_byte = hex_nibble(lat_x[7:4]);
			8'd60: line_byte = hex_nibble(lat_x[3:0]);
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

			// " G:## ## ##" — DL gate variables ($40 / $44 / $5C)
			8'd113: line_byte = " ";
			8'd114: line_byte = "G";
			8'd115: line_byte = ":";
			8'd116: line_byte = hex_nibble(lat_m40[7:4]);
			8'd117: line_byte = hex_nibble(lat_m40[3:0]);
			8'd118: line_byte = " ";
			8'd119: line_byte = hex_nibble(lat_m44[7:4]);
			8'd120: line_byte = hex_nibble(lat_m44[3:0]);
			8'd121: line_byte = " ";
			8'd122: line_byte = hex_nibble(lat_m5c[7:4]);
			8'd123: line_byte = hex_nibble(lat_m5c[3:0]);

			// " N:###### " main-thread PC (last opcode fetch with I=0)
			8'd124: line_byte = " ";
			8'd125: line_byte = "N";
			8'd126: line_byte = ":";
			8'd127: line_byte = hex_nibble(lat_pc_main[23:20]);
			8'd128: line_byte = hex_nibble(lat_pc_main[19:16]);
			8'd129: line_byte = hex_nibble(lat_pc_main[15:12]);
			8'd130: line_byte = hex_nibble(lat_pc_main[11:8]);
			8'd131: line_byte = hex_nibble(lat_pc_main[7:4]);
			8'd132: line_byte = hex_nibble(lat_pc_main[3:0]);

			// " I:###### " IRQ-thread PC (last opcode fetch with I=1)
			8'd133: line_byte = " ";
			8'd134: line_byte = "I";
			8'd135: line_byte = ":";
			8'd136: line_byte = hex_nibble(lat_pc_irq[23:20]);
			8'd137: line_byte = hex_nibble(lat_pc_irq[19:16]);
			8'd138: line_byte = hex_nibble(lat_pc_irq[15:12]);
			8'd139: line_byte = hex_nibble(lat_pc_irq[11:8]);
			8'd140: line_byte = hex_nibble(lat_pc_irq[7:4]);
			8'd141: line_byte = hex_nibble(lat_pc_irq[3:0]);

			// " B:## " wait-loop variable $0045
			8'd142: line_byte = " ";
			8'd143: line_byte = "B";
			8'd144: line_byte = ":";
			8'd145: line_byte = hex_nibble(lat_m45[7:4]);
			8'd146: line_byte = hex_nibble(lat_m45[3:0]);

			// v269: " VW:####" VIC-internal myWr_a $D019 count +
			//       " AC:####" VIC-internal resetRasterIrq (ack) count.
			// Distinguishes: VW=0 -> alignment failure; VW>0 AC=0 ->
			// data-bit-0 corruption; both>0 -> IRST race / re-fires.
			// (Replaces v268 IR/IV labels — those were 0/0 on SCPU,
			//  no further info gained. Same byte positions.)
			8'd147: line_byte = " ";
			8'd148: line_byte = "V";
			8'd149: line_byte = "W";
			8'd150: line_byte = ":";
			8'd151: line_byte = hex_nibble(lat_vic_d019_wr[15:12]);
			8'd152: line_byte = hex_nibble(lat_vic_d019_wr[11:8]);
			8'd153: line_byte = hex_nibble(lat_vic_d019_wr[7:4]);
			8'd154: line_byte = hex_nibble(lat_vic_d019_wr[3:0]);
			// v340n: restore AC field = VIC-internal resetRasterIrq count.
			// (v309 had repurposed AC → VB:#### BRK vector; BRK diagnostic
			// no longer needed since v340e+ work confirmed the BRK/RTI
			// paths.) AC is the IRST-clear pulse counter — pulses every
			// time the VIC's resetRasterIrq fires inside video_vicII_656x.
			// Together with VW (myWr_a $D019 write count) this distinguishes:
			//   VW=0 AC=0  → SCPU $D019 writes never reach the VIC bus
			//   VW>0 AC=0  → writes reach myWr_a but di_r(0) wrong or IRST
			//                latch ignores the write (suspected bug)
			//   VW>0 AC>0  → ack chain works; wedge has another cause
			8'd155: line_byte = " ";
			8'd156: line_byte = "A";
			8'd157: line_byte = "C";
			8'd158: line_byte = ":";
			8'd159: line_byte = hex_nibble(lat_vic_resetraster[15:12]);
			8'd160: line_byte = hex_nibble(lat_vic_resetraster[11:8]);
			8'd161: line_byte = hex_nibble(lat_vic_resetraster[7:4]);
			8'd162: line_byte = hex_nibble(lat_vic_resetraster[3:0]);

			// " W5:## ## ## ##" v262 4-deep ring of writes to $005C
			8'd163: line_byte = " ";
			8'd164: line_byte = "W";
			8'd165: line_byte = "5";
			8'd166: line_byte = ":";
			8'd167: line_byte = hex_nibble(lat_w5c0[7:4]);
			8'd168: line_byte = hex_nibble(lat_w5c0[3:0]);
			8'd169: line_byte = " ";
			8'd170: line_byte = hex_nibble(lat_w5c1[7:4]);
			8'd171: line_byte = hex_nibble(lat_w5c1[3:0]);
			8'd172: line_byte = " ";
			8'd173: line_byte = hex_nibble(lat_w5c2[7:4]);
			8'd174: line_byte = hex_nibble(lat_w5c2[3:0]);
			8'd175: line_byte = " ";
			8'd176: line_byte = hex_nibble(lat_w5c3[7:4]);
			8'd177: line_byte = hex_nibble(lat_w5c3[3:0]);

			// " N5:####" v262 total writes-to-$005C counter
			8'd178: line_byte = " ";
			8'd179: line_byte = "N";
			8'd180: line_byte = "5";
			8'd181: line_byte = ":";
			8'd182: line_byte = hex_nibble(lat_w5cN[15:12]);
			8'd183: line_byte = hex_nibble(lat_w5cN[11:8]);
			8'd184: line_byte = hex_nibble(lat_w5cN[7:4]);
			8'd185: line_byte = hex_nibble(lat_w5cN[3:0]);

			// v263: " IF:####" irq_fall_count (source IRQ_N falling edges)
			8'd186: line_byte = " ";
			8'd187: line_byte = "I";
			8'd188: line_byte = "F";
			8'd189: line_byte = ":";
			8'd190: line_byte = hex_nibble(lat_irq_fall[15:12]);
			8'd191: line_byte = hex_nibble(lat_irq_fall[11:8]);
			8'd192: line_byte = hex_nibble(lat_irq_fall[7:4]);
			8'd193: line_byte = hex_nibble(lat_irq_fall[3:0]);

			// v341 doom bitmap probe (2026-05-14): " 1D:####" — replaces
			// dead R7 doom-wait probe. First 2 hex digits = last value
			// at bank $00:$1D02; last 2 hex digits = last value at $1D04.
			// Doom's frame-flip code at $80:$0B40 reads $1D04 then BEQs
			// to pick VIC bank 3 ($C000) vs 1 ($4000). HW stuck at
			// DD00=$02 (bank 1) implies $1D04 != 0; surfacing both bytes
			// confirms the IRQ-handler producer at $0F58 ran (writes
			// $1D04) and the consumer at $0EED loop is/isn't advancing.
			8'd194: line_byte = " ";
			8'd195: line_byte = "1";
			8'd196: line_byte = "D";
			8'd197: line_byte = ":";
			8'd198: line_byte = hex_nibble(lat_m1d02[7:4]);
			8'd199: line_byte = hex_nibble(lat_m1d02[3:0]);
			8'd200: line_byte = hex_nibble(lat_m1d04[7:4]);
			8'd201: line_byte = hex_nibble(lat_m1d04[3:0]);

			// 2026-05-09 vanilla-cpu-swap: VIC bank-select probes
			// (replaces v271 AW/PA). " D1:## D8:## C2:##   " — last
			// CPU writes to $D011 (bitmap-mode bit), $D018 (screen+
			// char/bitmap base), $DD00 (CIA2 PRA = VIC bank select).
			// Goal: explain Doom's blank screen — does VIC see the
			// region Doom writes bitmap data into? DL bug is fixed
			// in master so AW/PA are obsolete here.
			// Width = 21 bytes (202..222) including 3 trailing spaces.
			8'd202: line_byte = " ";
			8'd203: line_byte = "D";
			8'd204: line_byte = "1";
			8'd205: line_byte = ":";
			8'd206: line_byte = hex_nibble(lat_d011v[7:4]);
			8'd207: line_byte = hex_nibble(lat_d011v[3:0]);
			8'd208: line_byte = " ";
			8'd209: line_byte = "D";
			8'd210: line_byte = "8";
			8'd211: line_byte = ":";
			8'd212: line_byte = hex_nibble(lat_d018v[7:4]);
			8'd213: line_byte = hex_nibble(lat_d018v[3:0]);
			8'd214: line_byte = " ";
			8'd215: line_byte = "C";
			8'd216: line_byte = "2";
			8'd217: line_byte = ":";
			8'd218: line_byte = hex_nibble(lat_dd00v[7:4]);
			8'd219: line_byte = hex_nibble(lat_dd00v[3:0]);
			// v341: append " D6:##" — $D016 latched last cpuDo. MCM bit
			// (bit 4) confirms multicolor bitmap vs hires; VICE shows
			// D016=$D8 (MCM=1) during Doom gameplay.
			8'd220: line_byte = " ";
			8'd221: line_byte = "D";
			8'd222: line_byte = "6";
			8'd223: line_byte = ":";
			8'd224: line_byte = hex_nibble(lat_d016v[7:4]);
			8'd225: line_byte = hex_nibble(lat_d016v[3:0]);
			// v346 doom bitmap-content probe: " B6:##" — per-frame
			// sticky OR of vicDi (the byte VIC fetches from RAM).
			// If $00 across Doom runtime, VIC sees only zeros →
			// screen genuinely empty. If non-zero, VIC sees data
			// and the black has a non-memory cause.
			8'd226: line_byte = " ";
			8'd227: line_byte = "B";
			8'd228: line_byte = "6";
			8'd229: line_byte = ":";
			8'd230: line_byte = hex_nibble(lat_vic_di_or[7:4]);
			8'd231: line_byte = hex_nibble(lat_vic_di_or[3:0]);
			// v347 " B1:## B3:##" — bm1/bm3 per-frame CPU-write counters
			8'd232: line_byte = " ";
			8'd233: line_byte = "B";
			8'd234: line_byte = "1";
			8'd235: line_byte = ":";
			8'd236: line_byte = hex_nibble(lat_bm1_writes[7:4]);
			8'd237: line_byte = hex_nibble(lat_bm1_writes[3:0]);
			8'd238: line_byte = " ";
			8'd239: line_byte = "B";
			8'd240: line_byte = "3";
			8'd241: line_byte = ":";
			8'd242: line_byte = hex_nibble(lat_bm3_writes[7:4]);
			8'd243: line_byte = hex_nibble(lat_bm3_writes[3:0]);

			// v9 MCP probe (2026-05-24): " DR:#### D9:####" appended.
			// DR = pool.dc0d_rd_count (CIA1 ICR reads, side-effect-bearing)
			// D9 = pool.d019_wr_count (CPU writes to $D019, ack chain)
			// Differential v8↔MCP-active hypothesis: if MCP causes double
			// reads of $DC0D, DR will be ~2× higher in MCP-active. If the
			// CPU is stuck in IRQ and never reaches the ack write, D9 will
			// be lower in MCP-active.
			8'd244: line_byte = " ";
			8'd245: line_byte = "D";
			8'd246: line_byte = "R";
			8'd247: line_byte = ":";
			8'd248: line_byte = hex_nibble(lat_dc0d_rd[15:12]);
			8'd249: line_byte = hex_nibble(lat_dc0d_rd[11:8]);
			8'd250: line_byte = hex_nibble(lat_dc0d_rd[7:4]);
			8'd251: line_byte = hex_nibble(lat_dc0d_rd[3:0]);
			8'd252: line_byte = " ";
			8'd253: line_byte = "D";
			8'd254: line_byte = "9";
			8'd255: line_byte = ":";
			9'd256: line_byte = hex_nibble(lat_d019_wr[15:12]);
			9'd257: line_byte = hex_nibble(lat_d019_wr[11:8]);
			9'd258: line_byte = hex_nibble(lat_d019_wr[7:4]);
			9'd259: line_byte = hex_nibble(lat_d019_wr[3:0]);

			// v12 (2026-05-24): " C1:####" — CIA1-only IRQ falling edges.
			// If C1 ≈ IF in both passthrough and MCP, the CIA1 IRQ output is
			// firing normally and the wedge is downstream of the AND. If C1
			// drops along with IF in MCP, MCP affects CIA1 IRQ generation.
			9'd260: line_byte = " ";
			9'd261: line_byte = "C";
			9'd262: line_byte = "1";
			9'd263: line_byte = ":";
			9'd264: line_byte = hex_nibble(lat_irq_cia1_fall[15:12]);
			9'd265: line_byte = hex_nibble(lat_irq_cia1_fall[11:8]);
			9'd266: line_byte = hex_nibble(lat_irq_cia1_fall[7:4]);
			9'd267: line_byte = hex_nibble(lat_irq_cia1_fall[3:0]);

			// v12b (2026-05-24): " IM:## CR:##" — CIA1 IMR mask (5 bits, hi
			// nibble = '0') + CRA Timer A control. If MCP causes a phantom
			// write that clears imr (bit0 = TA enable) or cra[0] (timer run),
			// IM or CR will differ from passthrough.
			9'd268: line_byte = " ";
			9'd269: line_byte = "I";
			9'd270: line_byte = "M";
			9'd271: line_byte = ":";
			9'd272: line_byte = hex_nibble({3'b000, lat_cia1_imr[4]});
			9'd273: line_byte = hex_nibble(lat_cia1_imr[3:0]);
			9'd274: line_byte = " ";
			9'd275: line_byte = "C";
			9'd276: line_byte = "R";
			9'd277: line_byte = ":";
			9'd278: line_byte = hex_nibble(lat_cia1_cra[7:4]);
			9'd279: line_byte = hex_nibble(lat_cia1_cra[3:0]);

			// Option F (2026-05-25): " M2:## T2:##" CIA2 IMR + CRA snapshots.
			// M2 hi nibble = '0' (imr is 5 bits). Renamed from I2/C2 to avoid
			// collision with the legacy "C2:" field appearing earlier in line.
			9'd280: line_byte = " ";
			9'd281: line_byte = "M";
			9'd282: line_byte = "2";
			9'd283: line_byte = ":";
			9'd284: line_byte = hex_nibble({3'b000, lat_cia2_imr[4]});
			9'd285: line_byte = hex_nibble(lat_cia2_imr[3:0]);
			9'd286: line_byte = " ";
			9'd287: line_byte = "T";
			9'd288: line_byte = "2";
			9'd289: line_byte = ":";
			9'd290: line_byte = hex_nibble(lat_cia2_cra[7:4]);
			9'd291: line_byte = hex_nibble(lat_cia2_cra[3:0]);

			// Option G (2026-05-25): " PA:## PB:## DA:## DB:##" CIA2 port + DDR.
			// CIA2 PRA $DD00 = IEC ATN/CLK/DATA out + serial bus drive bits.
			// CIA2 DDRA $DD02 sets which bits are outputs. If MCP phantom-clears
			// DDRA bits, IEC outputs go hi-Z and drive sees no command edges.
			9'd292: line_byte = " ";
			9'd293: line_byte = "P";
			9'd294: line_byte = "A";
			9'd295: line_byte = ":";
			9'd296: line_byte = hex_nibble(lat_cia2_pra[7:4]);
			9'd297: line_byte = hex_nibble(lat_cia2_pra[3:0]);
			9'd298: line_byte = " ";
			9'd299: line_byte = "P";
			9'd300: line_byte = "B";
			9'd301: line_byte = ":";
			9'd302: line_byte = hex_nibble(lat_cia2_prb[7:4]);
			9'd303: line_byte = hex_nibble(lat_cia2_prb[3:0]);
			9'd304: line_byte = " ";
			9'd305: line_byte = "D";
			9'd306: line_byte = "A";
			9'd307: line_byte = ":";
			9'd308: line_byte = hex_nibble(lat_cia2_ddra[7:4]);
			9'd309: line_byte = hex_nibble(lat_cia2_ddra[3:0]);
			9'd310: line_byte = " ";
			9'd311: line_byte = "D";
			9'd312: line_byte = "B";
			9'd313: line_byte = ":";
			9'd314: line_byte = hex_nibble(lat_cia2_ddrb[7:4]);
			9'd315: line_byte = hex_nibble(lat_cia2_ddrb[3:0]);

			// newline (LINE_LEN-1 = 318)
			9'd316: line_byte = " ";
			9'd317: line_byte = " ";
			9'd318: line_byte = 8'h0A;

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
				lat_sp    <= pool.cpu_sp;     // v280 doom triage
				lat_wp    <= pool.wr02_pc;
				lat_cg    <= pool.cnt_wr02_chg;
				lat_w1    <= {pool.trace_op2, pool.trace_op3};  // OP probe (2026-05-10)
				lat_cy    <= pool.cnt_wr02;
				lat_jsr0  <= pool.jsr_pc_t0;
				lat_jsr1  <= pool.jsr_pc_t1;
				lat_jsr2  <= pool.jsr_pc_t2;
				lat_jsr3  <= pool.jsr_pc_t3;
				lat_jmp0  <= pool.jmp_tgt_t0;
				lat_jmp1  <= pool.jmp_tgt_t1;
				lat_jmp2  <= pool.jmp_tgt_t2;
				lat_jmp3  <= pool.jmp_tgt_t3;
				lat_m40   <= pool.mem_40;
				lat_m44   <= pool.mem_44;
				lat_m5c   <= pool.mem_5C;
				lat_pc_main <= pool.pc_main;
				lat_pc_irq  <= pool.pc_irq;
				lat_m45     <= pool.mem_45;
				lat_c30     <= pool.cnt_pc_30;
				lat_c97     <= pool.cnt_pc_97;
				lat_d000    <= pool.d000_last_val;
				lat_d001    <= pool.d001_last_val;
				lat_d002    <= pool.d002_last_val;
				lat_d003    <= pool.d003_last_val;
				lat_w5c0    <= pool.wr5C_v0;
				lat_w5c1    <= pool.wr5C_v1;
				lat_w5c2    <= pool.wr5C_v2;
				lat_w5c3    <= pool.wr5C_v3;
				lat_w5cN    <= pool.cnt_wr5C;
				lat_irq_fall  <= pool.irq_fall_count;
				lat_irq_vec   <= pool.irq_vec_count;
				// 2026-05-09 doom-wait probe — last read in $00:$07xx
				lat_rd07addr  <= pool.rd07xx_addr;
				lat_rd07data  <= pool.rd07xx_data;
				lat_d019_rd   <= pool.d019_last_read;
				lat_d019_seen <= pool.d019_seen_bits;
				// v267: $D012 raster-IRQ tail-chain timing latches
				lat_d012_wc   <= pool.d012_write_cycles;
				lat_d012_rr   <= pool.raster_at_d012;
				lat_d012_dv   <= pool.d012_last_val;
				// v268: IRQ rising-edge counter latches
				lat_irq_rise_combined <= pool.irq_combined_rise_count;
				lat_irq_rise_vic      <= pool.irq_vic_rise_count;
				// v269: VIC-internal $D019 ack diagnostic latches
				lat_vic_d019_wr       <= pool.vic_d019_wr_count;
				lat_vic_resetraster   <= pool.vic_resetraster_count;
				// v9 MCP probe (2026-05-24): CIA1 ICR-read + d019 ack-write
				lat_dc0d_rd           <= pool.dc0d_rd_count;
				lat_d019_wr           <= pool.d019_wr_count;
				// v12 (2026-05-24): CIA1-only IRQ falling edges
				lat_irq_cia1_fall     <= pool.irq_cia1_fall_count;
				// v12b (2026-05-24): CIA1 IMR/CRA snapshots
				lat_cia1_imr          <= pool.cia1_imr;
				lat_cia1_cra          <= pool.cia1_cra;
				// Option F (2026-05-25): CIA2 imr/cra snapshots
				lat_cia2_imr          <= pool.cia2_imr;
				lat_cia2_cra          <= pool.cia2_cra;
				// Option G (2026-05-25): CIA2 PRA/PRB/DDR snapshots
				lat_cia2_pra          <= pool.cia2_pra;
				lat_cia2_prb          <= pool.cia2_prb;
				lat_cia2_ddra         <= pool.cia2_ddra;
				lat_cia2_ddrb         <= pool.cia2_ddrb;
				// v309: BRK vector lo/hi
				lat_brk_vec_lo        <= pool.brk_vec_lo;
				lat_brk_vec_hi        <= pool.brk_vec_hi;
				// v270: $D019 writer-PC + sticky cpuDo OR latches
				lat_d019_pc      <= pool.d019_last_pc;
				lat_d019_val     <= pool.d019_last_val;
				lat_d019_seen_w  <= pool.d019_seen_writes;
				// v271: $D019 ack-write counter + ack-write PC latches
				lat_d019_ack_count <= pool.d019_ack_count;
				lat_d019_ack_pc    <= pool.d019_ack_pc;
				// 2026-05-09 vanilla-cpu-swap: VIC-bank probe latches
				lat_d011v <= pool.vic_d011;
				lat_d018v <= pool.vic_d018;
				lat_dd00v <= pool.vic_dd00;
				// v341 doom bitmap probe
				lat_m1d02 <= pool.mem_1d02;
				lat_m1d04 <= pool.mem_1d04;
				lat_d016v <= pool.vic_d016;
				// v346 doom bitmap-content probe (per-frame vicDi OR)
				lat_vic_di_or <= pool.vic_di_or;
				// v347 doom bitmap-write probe (bm1/bm3 per-frame counters)
				lat_bm1_writes <= pool.bm1_writes;
				lat_bm3_writes <= pool.bm3_writes;
				byte_idx  <= 9'd0;
			end
			else if (byte_idx < LINE_LEN && !tx_busy && !byte_pending) begin
				tx_data      <= line_byte(byte_idx);
				tx_send      <= 1'b1;
				byte_pending <= 1'b1;
			end
			else if (byte_pending && tx_busy) begin
				// Send pulse acknowledged by transmitter; advance.
				byte_pending <= 1'b0;
				byte_idx     <= byte_idx + 9'd1;
			end
		end
	end

endmodule

`endif
