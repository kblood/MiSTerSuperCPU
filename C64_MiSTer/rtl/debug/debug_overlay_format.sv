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
	localparam [5:0] G_W  = 6'd32;
	localparam [5:0] G_H  = 6'd17;
	localparam [5:0] G_N  = 6'd23;

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

			// ===== Row 4: 02=#### 03=#### C=#### v256 dispatch-vector ===
			// v256: writers of $0002 and $0003 (the dispatch-vector RAM
			// bytes) + counter of $0002 writes.
			//   02=#### = lower 16 bits of wr02_pc (PC of last writer to $0002)
			//   03=#### = lower 16 bits of wr03_pc (PC of last writer to $0003)
			//   C=####  = cnt_wr02 (count of writes to $0002)
			// v255 found SCPU's JMP-indirect targets stuck at $3300/$3380
			// across many IRQs while T65's targets are different every IRQ.
			// Hypothesis: SCPU rarely re-writes $0002. If cnt_wr02 << T65's,
			// confirms. wr02_pc reveals WHICH code does the writing — that
			// PC's surrounding routine is the divergent code.
			// (Replaces v246 $0079..$007F mem dump; mem_79..mem_7F confirmed
			// identical T65/SCPU per memory.)
			4'd4: case (cell_x)
				5'd0:  glyph_id = 6'd0;        // '0'
				5'd1:  glyph_id = 6'd2;        // '2'
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.wr02_pc[15:12]);
				5'd4:  glyph_id = hex(pool.wr02_pc[11:8]);
				5'd5:  glyph_id = hex(pool.wr02_pc[7:4]);
				5'd6:  glyph_id = hex(pool.wr02_pc[3:0]);
				5'd7:  glyph_id = G_SP;
				5'd8:  glyph_id = 6'd0;        // '0'
				5'd9:  glyph_id = 6'd3;        // '3'
				5'd10: glyph_id = G_EQ;
				5'd11: glyph_id = hex(pool.wr03_pc[15:12]);
				5'd12: glyph_id = hex(pool.wr03_pc[11:8]);
				5'd13: glyph_id = hex(pool.wr03_pc[7:4]);
				5'd14: glyph_id = hex(pool.wr03_pc[3:0]);
				5'd15: glyph_id = G_SP;
				5'd16: glyph_id = G_C;
				5'd17: glyph_id = G_EQ;
				5'd18: glyph_id = hex(pool.cnt_wr02[15:12]);
				5'd19: glyph_id = hex(pool.cnt_wr02[11:8]);
				5'd20: glyph_id = hex(pool.cnt_wr02[7:4]);
				5'd21: glyph_id = hex(pool.cnt_wr02[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 5: V0=## V1=## W=###### ========================
			// v245: actual VALUES written to $0070/$0071 (cpuDo at the
			// write cycle) + W = wr70_pc (PC of the writer instruction).
			// v244 row 5 ($3388-$338F dump) was identical T65/SCPU per
			// v244 capture; retiring it frees the row for v245 data.
			4'd5: case (cell_x)
				5'd0:  glyph_id = G_V;
				5'd1:  glyph_id = 6'd0;       // '0'
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.wr70_val[7:4]);
				5'd4:  glyph_id = hex(pool.wr70_val[3:0]);
				5'd5:  glyph_id = G_SP;
				5'd6:  glyph_id = G_V;
				5'd7:  glyph_id = 6'd1;       // '1'
				5'd8:  glyph_id = G_EQ;
				5'd9:  glyph_id = hex(pool.wr71_val[7:4]);
				5'd10: glyph_id = hex(pool.wr71_val[3:0]);
				5'd11: glyph_id = G_SP;
				5'd12: glyph_id = 6'd32;       // 'W'
				5'd13: glyph_id = G_EQ;
				5'd14: glyph_id = hex(pool.wr70_pc[23:20]);
				5'd15: glyph_id = hex(pool.wr70_pc[19:16]);
				5'd16: glyph_id = hex(pool.wr70_pc[15:12]);
				5'd17: glyph_id = hex(pool.wr70_pc[11:8]);
				5'd18: glyph_id = hex(pool.wr70_pc[7:4]);
				5'd19: glyph_id = hex(pool.wr70_pc[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 6: V=## ## ## ##  YX=#### v258 wr02 value ring + regs
			// v258: replaces stale v246 cnt_3200/cnt_3100 (proven 50/50
			// identical both modes since v246, no longer load-bearing).
			//   V=## ## ## ## : last 4 values stored to $0002 (newest=v3)
			//   YX=####       : Y/X register pair at most-recent $0002
			//                   write (Y[7:0] X[7:0])
			// SCPU expected: V cycles through 2 narrow values (e.g. $00
			// $80 $00 $80) → JMP ring narrow ($3300/$3380). Y is the
			// suspected upstream table index.
			4'd6: case (cell_x)
				5'd0:  glyph_id = G_V;
				5'd1:  glyph_id = G_EQ;
				5'd2:  glyph_id = hex(pool.wr02_v0[7:4]);
				5'd3:  glyph_id = hex(pool.wr02_v0[3:0]);
				5'd4:  glyph_id = G_SP;
				5'd5:  glyph_id = hex(pool.wr02_v1[7:4]);
				5'd6:  glyph_id = hex(pool.wr02_v1[3:0]);
				5'd7:  glyph_id = G_SP;
				5'd8:  glyph_id = hex(pool.wr02_v2[7:4]);
				5'd9:  glyph_id = hex(pool.wr02_v2[3:0]);
				5'd10: glyph_id = G_SP;
				5'd11: glyph_id = hex(pool.wr02_v3[7:4]);
				5'd12: glyph_id = hex(pool.wr02_v3[3:0]);
				5'd13: glyph_id = G_SP;
				5'd14: glyph_id = G_SP;
				5'd15: glyph_id = 6'd34;          // 'Y'
				5'd16: glyph_id = 6'd33;          // 'X'
				5'd17: glyph_id = G_EQ;
				5'd18: glyph_id = hex(pool.wr02_y[7:4]);
				5'd19: glyph_id = hex(pool.wr02_y[3:0]);
				5'd20: glyph_id = hex(pool.wr02_x[7:4]);
				5'd21: glyph_id = hex(pool.wr02_x[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 7: V=#### IO=## ## ============================
			// v255: KERNAL IRQ vector ($0314 lo, $0315 hi) + CPU IO port
			// direction ($0000) and data ($0001).
			//   V=####    = mem[$0315] : mem[$0314] (16-bit IRQ vector)
			//   IO=## ##  = mem[$0000] mem[$0001] (CPU IO port DDR/DATA)
			// DL replaces the IRQ vector with its raster handler. If T65
			// vs SCPU read different bytes, IRQ entry diverges. The CPU
			// IO port bit 7 (CHAREN), bit 6 (HIRAM), bit 5 (LORAM) gate
			// what's visible at $A000/$D000/$E000. Different IO port
			// value => same PC sees different code => state divergence.
			// Replaces v247 5B-row (mem_5B confirmed identical both modes).
			4'd7: case (cell_x)
				5'd0:  glyph_id = G_V;
				5'd1:  glyph_id = G_EQ;
				5'd2:  glyph_id = hex(pool.mem_0315[7:4]);
				5'd3:  glyph_id = hex(pool.mem_0315[3:0]);
				5'd4:  glyph_id = hex(pool.mem_0314[7:4]);
				5'd5:  glyph_id = hex(pool.mem_0314[3:0]);
				5'd6:  glyph_id = G_SP;
				5'd7:  glyph_id = G_I;
				5'd8:  glyph_id = 6'd24;       // 'O'
				5'd9:  glyph_id = G_EQ;
				5'd10: glyph_id = hex(pool.mem_00[7:4]);
				5'd11: glyph_id = hex(pool.mem_00[3:0]);
				5'd12: glyph_id = G_SP;
				5'd13: glyph_id = hex(pool.mem_01[7:4]);
				5'd14: glyph_id = hex(pool.mem_01[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 8: ZP=[14 hex chars = 7 bytes, bisection grid] ====
			// v247 (superseded 2026-08-24): was the IRQ stub's REU dispatch
			// routine at $0080-$0086 (Doom-era, now dead/uncompiled path).
			// Repurposed as a zero-page/low-RAM bisection grid for the
			// Asterix low-RAM-zeroed bug: mem_80..mem_86 registers (same
			// wiring) now snoop $0002, $0030, $0060, $0090, $00C0, $00F0,
			// $0200 respectively. See
			// project_asterix_postspace_lowram_zeroed_root_cause.md.
			4'd8: case (cell_x)
				5'd0:  glyph_id = 6'd35;      // 'Z'
				5'd1:  glyph_id = 6'd25;      // 'P'
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.mem_80[7:4]);
				5'd4:  glyph_id = hex(pool.mem_80[3:0]);
				5'd5:  glyph_id = hex(pool.mem_81[7:4]);
				5'd6:  glyph_id = hex(pool.mem_81[3:0]);
				5'd7:  glyph_id = hex(pool.mem_82[7:4]);
				5'd8:  glyph_id = hex(pool.mem_82[3:0]);
				5'd9:  glyph_id = hex(pool.mem_83[7:4]);
				5'd10: glyph_id = hex(pool.mem_83[3:0]);
				5'd11: glyph_id = hex(pool.mem_84[7:4]);
				5'd12: glyph_id = hex(pool.mem_84[3:0]);
				5'd13: glyph_id = hex(pool.mem_85[7:4]);
				5'd14: glyph_id = hex(pool.mem_85[3:0]);
				5'd15: glyph_id = hex(pool.mem_86[7:4]);
				5'd16: glyph_id = hex(pool.mem_86[3:0]);
				// 2026-08-24 (15th pass): cells 17-20 repurposed again.
				// The write-attribution bitmaps that lived here (mem_87/
				// mem_88, decisively read as $00/$00 — neither REU DMA nor
				// a CPU store ever touched the $0AC0-$0B10 checkpoint
				// range) already answered their question; that data isn't
				// needed live anymore (still in mem_87/mem_88 if a future
				// pass wants it back). vecfetch_addr's own question is now
				// also settled (confirmed $FFE7 native BRK vector, 17th
				// pass) so this cell group is repurposed again (18th pass)
				// to show jmlvec_hi/jmlvec_bank: the actual CPU-bus-read
				// bytes at $04FD/$04FE, i.e. loader.prg's JML ($04FC) exit
				// vector's hi+bank bytes. VICE ground truth is $00/$20
				// (target $20:0000, boots clean) — see
				// project_wolf3d_postreu_bank28_freeze_regression.md
				// 18th-pass update. If HW disagrees, the REU/SuperRAM
				// write path for the skip-flag table is the bug.
				5'd17: glyph_id = hex(pool.jmlvec_hi[7:4]);
				5'd18: glyph_id = hex(pool.jmlvec_hi[3:0]);
				5'd19: glyph_id = hex(pool.jmlvec_bank[7:4]);
				5'd20: glyph_id = hex(pool.jmlvec_bank[3:0]);
				5'd21: glyph_id = G_SP;
				default: glyph_id = G_SP;
			endcase

			// ===== Row 9: 87=[10 hex chars = 5 bytes $0087..$008B] ====
			// v247: continuation of dispatch routine.
			// ===== Row 9: J=#### #### #### #### v254 JSR ring ============
			// v254: lower 16 bits of last 4 JSR/JSL fetch PCs. Reading
			// order jsr_pc_t0 (oldest) -> jsr_pc_t3 (newest).
			// jsr_pc_t3 = the JSR/JSL that called the routine where the
			// $DF01 trigger fired (i.e. the writer's immediate caller).
			// Earlier entries reveal the call chain leading there.
			// T65 expected to show JSR PCs that route to $852B/$805F/
			// $8835/$832C; SCPU shows different upstream PC if dispatcher
			// branches diverge. Replaced the mem_87..mem_8B row (those
			// bytes are identical T65/SCPU per v249, so freed for JSR).
			4'd9: case (cell_x)
				5'd0:  glyph_id = 6'd19;         // 'J'   (G_J = 19)
				5'd1:  glyph_id = G_EQ;
				5'd2:  glyph_id = hex(pool.jsr_pc_t0[15:12]);
				5'd3:  glyph_id = hex(pool.jsr_pc_t0[11:8]);
				5'd4:  glyph_id = hex(pool.jsr_pc_t0[7:4]);
				5'd5:  glyph_id = hex(pool.jsr_pc_t0[3:0]);
				5'd6:  glyph_id = G_SP;
				5'd7:  glyph_id = hex(pool.jsr_pc_t1[15:12]);
				5'd8:  glyph_id = hex(pool.jsr_pc_t1[11:8]);
				5'd9:  glyph_id = hex(pool.jsr_pc_t1[7:4]);
				5'd10: glyph_id = hex(pool.jsr_pc_t1[3:0]);
				5'd11: glyph_id = G_SP;
				5'd12: glyph_id = hex(pool.jsr_pc_t2[15:12]);
				5'd13: glyph_id = hex(pool.jsr_pc_t2[11:8]);
				5'd14: glyph_id = hex(pool.jsr_pc_t2[7:4]);
				5'd15: glyph_id = hex(pool.jsr_pc_t2[3:0]);
				5'd16: glyph_id = G_SP;
				5'd17: glyph_id = hex(pool.jsr_pc_t3[15:12]);
				5'd18: glyph_id = hex(pool.jsr_pc_t3[11:8]);
				5'd19: glyph_id = hex(pool.jsr_pc_t3[7:4]);
				5'd20: glyph_id = hex(pool.jsr_pc_t3[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 10: D1=## P=###### ============================
			// v247: last write to $DF01 (REU command).
			//   D1=## = value the CPU last wrote to $DF01 (REU cmd byte)
			//   P=##  = 24-bit PC of that writer instruction
			// v246 readback differed T65=$31 vs SCPU=$7D; this captures
			// the actual byte the CPU writes (vs reads back post-DMA
			// when bit 7 has cleared and other bits may be muted).
			4'd10: case (cell_x)
				5'd0:  glyph_id = G_D;
				5'd1:  glyph_id = 6'd1;       // '1'
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.wr_df01_val[7:4]);
				5'd4:  glyph_id = hex(pool.wr_df01_val[3:0]);
				5'd5:  glyph_id = G_SP;
				5'd6:  glyph_id = G_P;
				5'd7:  glyph_id = G_EQ;
				5'd8:  glyph_id = hex(pool.wr_df01_pc[23:20]);
				5'd9:  glyph_id = hex(pool.wr_df01_pc[19:16]);
				5'd10: glyph_id = hex(pool.wr_df01_pc[15:12]);
				5'd11: glyph_id = hex(pool.wr_df01_pc[11:8]);
				5'd12: glyph_id = hex(pool.wr_df01_pc[7:4]);
				5'd13: glyph_id = hex(pool.wr_df01_pc[3:0]);
				// 2026-08-24 Wolf3D wild-jump investigation: SP=####
				// packed into this row's 8 free cells (14-21).
				// cpu_sp (already wired end-to-end since v280 Doom
				// triage, never displayed on an overlay row) is the
				// live 16-bit P65C816 stack pointer. NMI is ruled out
				// (N=0000 confirmed at all 7 timeline timepoints) --
				// this checks the alternative theory: stack corruption
				// causing an accidental RTI/RTL that pops a garbage
				// E-equivalent bit and/or a garbage return address.
				// See project_wolf3d_postreu_bank28_freeze_regression.md.
				5'd14: glyph_id = G_SP;
				5'd15: glyph_id = G_S;
				5'd16: glyph_id = G_P;
				5'd17: glyph_id = G_EQ;
				5'd18: glyph_id = hex(pool.cpu_sp[15:12]);
				5'd19: glyph_id = hex(pool.cpu_sp[11:8]);
				5'd20: glyph_id = hex(pool.cpu_sp[7:4]);
				5'd21: glyph_id = hex(pool.cpu_sp[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 11: DC=#### CG=#### ===========================
			// v247: DC=#### = 16-bit counter of writes to $DF01 (REU DMA
			// count). v257: CG=#### = subset where stored value at $0002
			// differs from previous (T65 expected ≈ cnt_wr02; SCPU
			// expected << cnt_wr02 because dispatcher writes same target
			// repeatedly).
			4'd11: case (cell_x)
				5'd0:  glyph_id = G_D;
				5'd1:  glyph_id = G_C;
				5'd2:  glyph_id = G_EQ;
				5'd3:  glyph_id = hex(pool.cnt_df01[15:12]);
				5'd4:  glyph_id = hex(pool.cnt_df01[11:8]);
				5'd5:  glyph_id = hex(pool.cnt_df01[7:4]);
				5'd6:  glyph_id = hex(pool.cnt_df01[3:0]);
				5'd7:  glyph_id = G_SP;
				5'd8:  glyph_id = G_C;
				5'd9:  glyph_id = 6'd16;          // 'G' (G_G inline)
				5'd10: glyph_id = G_EQ;
				5'd11: glyph_id = hex(pool.cnt_wr02_chg[15:12]);
				5'd12: glyph_id = hex(pool.cnt_wr02_chg[11:8]);
				5'd13: glyph_id = hex(pool.cnt_wr02_chg[7:4]);
				5'd14: glyph_id = hex(pool.cnt_wr02_chg[3:0]);
				// 2026-08-24 Wolf3D wild-jump investigation: N=####
				// packed into this row's 7 free cells (15-21).
				// nmi_vec_count (already wired end-to-end, dbg_pool
				// -> c64.sv -> fpga64_sid_iec.vhd nmi_vec_count_r,
				// previously uncaptured on any overlay row) counts
				// every native-mode NMI vector fetch since reset.
				// >0 during the t=15-30s wild-jump window would
				// confirm a spurious NMI as the E-flag-flip trigger.
				// See project_wolf3d_postreu_bank28_freeze_regression.md.
				5'd15: glyph_id = G_SP;
				5'd16: glyph_id = G_N;
				5'd17: glyph_id = G_EQ;
				5'd18: glyph_id = hex(pool.nmi_vec_count[15:12]);
				5'd19: glyph_id = hex(pool.nmi_vec_count[11:8]);
				5'd20: glyph_id = hex(pool.nmi_vec_count[7:4]);
				5'd21: glyph_id = hex(pool.nmi_vec_count[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 12: O=## ## ## ## F=#  v250 trace ring opcodes ====
			// v250: row 12 repurposed. trace_op0..op3 = opcode bytes at
			// each PC in the trace ring. F=1 once frozen.
			// 20th pass (2026-08-24, Wolf3D wild-jump investigation): the
			// freeze trigger is now the FIRST opcode fetch with PC bank=0,
			// PC>$07DB after loader.prg's $0700 entry (see loader_armed_r,
			// fpga64_sid_iec.vhd) -- i.e. the moment execution leaves
			// loader.prg's own 220-byte relocated code block. trace_op3 =
			// opcode byte AT that moment; trace_op0..op2 = the 3 opcodes
			// immediately before it. The old $DF01-write/Doom-dispatcher
			// trigger this row/row 14 used through v249-v287 doesn't fire
			// in the Wolf3D flow and is superseded here (still described
			// in git history if ever needed again for that investigation).
			4'd12: case (cell_x)
				5'd0:  glyph_id = 6'd24;         // 'O'   (G_O = 24)
				5'd1:  glyph_id = G_EQ;
				5'd2:  glyph_id = hex(pool.trace_op0[7:4]);
				5'd3:  glyph_id = hex(pool.trace_op0[3:0]);
				5'd4:  glyph_id = G_SP;
				5'd5:  glyph_id = hex(pool.trace_op1[7:4]);
				5'd6:  glyph_id = hex(pool.trace_op1[3:0]);
				5'd7:  glyph_id = G_SP;
				5'd8:  glyph_id = hex(pool.trace_op2[7:4]);
				5'd9:  glyph_id = hex(pool.trace_op2[3:0]);
				5'd10: glyph_id = G_SP;
				5'd11: glyph_id = hex(pool.trace_op3[7:4]);
				5'd12: glyph_id = hex(pool.trace_op3[3:0]);
				5'd13: glyph_id = G_SP;
				5'd14: glyph_id = G_F;
				5'd15: glyph_id = G_EQ;
				5'd16: glyph_id = hex({3'b000, pool.trace_frozen});
				// 2026-08-24 Wolf3D wild-jump investigation: IV=##
				// packed into this row's 5 free cells (17-21). Second
				// placement attempt -- row 7 (where V=#### already
				// lives) turned out to sit inside Wolf3D's dithered 3D
				// viewport texture at every sampled timepoint (t=5..90s),
				// making anything placed there unreadable regardless of
				// content -- confirmed by diffing raw (unfiltered) row-7
				// crops across timepoints and finding a static dithered
				// checkerboard, not overlay glyphs. Row 12 (this row)
				// sits in the status-bar band and read cleanly at every
				// timepoint including t=90s. irq_vec_count[7:0] (lower
				// byte only -- 5 free cells isn't enough for the full
				// 16-bit field, but zero-vs-incrementing is all this
				// probe needs) counts CPU reads at $FFFE/$FFFF (the
				// emulation-mode IRQ/BRK vector). loader.prg executes SEI
				// as its first instruction with no CLI after, so IV=00
				// throughout is the SEI-correctness prediction; any
				// nonzero/incrementing value means the core dispatches an
				// IRQ despite I=1 -- an emulation-mode interrupt-masking
				// bug in its own right.
				// See project_wolf3d_postreu_bank28_freeze_regression.md.
				// 18th/19th pass: irq_vec_count settled at 0 throughout
				// every capture this saga (SEI-correctness confirmed, no
				// masked-interrupt bug) -- question answered, cell freed.
				// Now shows last_07b9: the last-read value of C64 RAM
				// $07B9 (skip-table REU source mid-byte), disambiguating
				// the jmlvec HW/VICE divergence (see jmlvec_hi_r comment
				// in fpga64_sid_iec.vhd).
				5'd17: glyph_id = hex(4'd9);     // '9'
				5'd18: glyph_id = G_EQ;
				5'd19: glyph_id = hex(pool.last_07b9[7:4]);
				5'd20: glyph_id = hex(pool.last_07b9[3:0]);
				// 26th pass (2026-08-25): last free cell in this row.
				// trace_pc0/pc3 are already full 24-bit (PBR:PC) internally
				// (see trace_pc0_r in fpga64_sid_iec.vhd) but row 14 below
				// only ever displayed the low 16 bits, so the bank byte of
				// the 3 pre-trigger ring entries was invisible even though
				// it was already captured -- this is a display-only fix,
				// no new capture RTL. Shows trace_pc0[19:16] (bank nibble
				// of the FIRST pre-trigger opcode fetch) paired with row
				// 14 cell 21 below (trace_pc2[19:16], the LAST pre-trigger
				// fetch) to answer: was the whole ring already in bank 0
				// (fitting "REU-transfer-loop exits early"), or did it
				// start in a different bank (e.g. $2 for bank $20,
				// legitimate native game code) and only cross into bank 0
				// at the trigger? No label fits in 1 cell -- position is
				// fixed, read by row/cell like the rest of this ring. See
				// project_wolf3d_postreu_bank28_freeze_regression.md 26th
				// pass "Next step".
				5'd21: glyph_id = hex(pool.trace_pc0[19:16]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 13: M=#### #### #### #### v255 JMP-indirect ring ===
			// v255: lower 16 bits of last 4 JMP-indirect targets ($6C
			// JMP (abs), $7C JMP (abs,X), $DC JML [abs]). After fetching
			// the indirect-jump opcode the next opcode_fetch_pulse fires
			// AT the target -- captured here. DL's IRQ stub calls
			// `JMP ($0002)` so this ring shows the dispatch destination
			// chosen each IRQ. T65 vs SCPU divergence here = the same
			// vector resolved to different writers despite identical
			// stored vector bytes. Replaces v249 P-irq ring (D/V flag
			// stability already verified at v249-v253).
			4'd13: case (cell_x)
				5'd0:  glyph_id = G_M;
				5'd1:  glyph_id = G_EQ;
				5'd2:  glyph_id = hex(pool.jmp_tgt_t0[15:12]);
				5'd3:  glyph_id = hex(pool.jmp_tgt_t0[11:8]);
				5'd4:  glyph_id = hex(pool.jmp_tgt_t0[7:4]);
				5'd5:  glyph_id = hex(pool.jmp_tgt_t0[3:0]);
				5'd6:  glyph_id = G_SP;
				5'd7:  glyph_id = hex(pool.jmp_tgt_t1[15:12]);
				5'd8:  glyph_id = hex(pool.jmp_tgt_t1[11:8]);
				5'd9:  glyph_id = hex(pool.jmp_tgt_t1[7:4]);
				5'd10: glyph_id = hex(pool.jmp_tgt_t1[3:0]);
				5'd11: glyph_id = G_SP;
				5'd12: glyph_id = hex(pool.jmp_tgt_t2[15:12]);
				5'd13: glyph_id = hex(pool.jmp_tgt_t2[11:8]);
				5'd14: glyph_id = hex(pool.jmp_tgt_t2[7:4]);
				5'd15: glyph_id = hex(pool.jmp_tgt_t2[3:0]);
				5'd16: glyph_id = G_SP;
				5'd17: glyph_id = hex(pool.jmp_tgt_t3[15:12]);
				5'd18: glyph_id = hex(pool.jmp_tgt_t3[11:8]);
				5'd19: glyph_id = hex(pool.jmp_tgt_t3[7:4]);
				5'd20: glyph_id = hex(pool.jmp_tgt_t3[3:0]);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 15: P######B######R###### ========================
			// v241: RTI snapshot ring — 3 PCs ending at RTI execution.
			//   P###### = PBR:PC two opcodes before RTI (rti_h2)
			//   B###### = PBR:PC one opcode before RTI (rti_h1)
			//   R###### = PBR:PC of the RTI itself (rti_pc)
			// Reading order: P → B → R (chronological, oldest to RTI).
			// Diagnostic: T65 vs SCPU comparison shows the divergent
			// instruction. If P/B addresses differ, the JMP/branch
			// inside the IRQ handler took different paths.
			4'd15: case (cell_x)
				5'd0:  glyph_id = G_P;
				5'd1:  glyph_id = hex(pool.rti_h2[23:20]);
				5'd2:  glyph_id = hex(pool.rti_h2[19:16]);
				5'd3:  glyph_id = hex(pool.rti_h2[15:12]);
				5'd4:  glyph_id = hex(pool.rti_h2[11:8]);
				5'd5:  glyph_id = hex(pool.rti_h2[7:4]);
				5'd6:  glyph_id = hex(pool.rti_h2[3:0]);
				5'd7:  glyph_id = G_B;
				5'd8:  glyph_id = hex(pool.rti_h1[23:20]);
				5'd9:  glyph_id = hex(pool.rti_h1[19:16]);
				5'd10: glyph_id = hex(pool.rti_h1[15:12]);
				5'd11: glyph_id = hex(pool.rti_h1[11:8]);
				5'd12: glyph_id = hex(pool.rti_h1[7:4]);
				5'd13: glyph_id = hex(pool.rti_h1[3:0]);
				5'd14: glyph_id = G_R;
				5'd15: glyph_id = hex(pool.rti_pc[23:20]);
				5'd16: glyph_id = hex(pool.rti_pc[19:16]);
				5'd17: glyph_id = hex(pool.rti_pc[15:12]);
				5'd18: glyph_id = hex(pool.rti_pc[11:8]);
				5'd19: glyph_id = hex(pool.rti_pc[7:4]);
				5'd20: glyph_id = hex(pool.rti_pc[3:0]);
				// 2026-08-24 (14th pass): raw call_depth[3:0] nibble
				// sampled A,6,D,7,8,6,6 across t=5..90s -- noisy, not
				// flat, but ambiguous (a wrapped signed nibble can't
				// distinguish true depth 7 from true depth 23).
				// Replaced with call_depth_maxabs: a saturating (never
				// decrements, clamped at 15) magnitude tracker. Its
				// value across the same 7 timestamped samples is
				// monotonic non-decreasing, so the *trajectory* pins
				// down whether abnormal depth appears specifically
				// during the t=15-30s divergence window (would jump
				// there and not before) versus already being present
				// at t=5s from ordinary KERNAL/IRQ nesting (flat from
				// the start). See
				// project_wolf3d_postreu_bank28_freeze_regression.md.
				5'd21: glyph_id = hex(pool.call_depth_maxabs);
				default: glyph_id = G_SP;
			endcase

			// ===== Row 14: T=#### #### #### #### v250 trace ring PCs =====
			// v250: trace_pc0..pc3 = PCs at the last 4 opcode_fetch_pulses.
			// 20th pass (2026-08-24): see row 12's updated comment -- ring
			// now freezes on the first opcode fetch outside loader.prg's
			// own $0700-$07DB footprint (PC bank=0, PC>$07DB, after
			// arming at the $0700 entry). trace_pc3 = the PC AT that
			// moment (should read >$07DB if this fires as designed);
			// trace_pc0..pc2 = the 3 PCs immediately before it, which
			// should still read <=$07DB if this is a legitimate
			// straight-line fall-through off the end of loader.prg's own
			// code (relocation-copy bounds bug), or could jump around
			// erratically even before crossing $07DB if it's a genuine
			// wild branch triggered from inside the loader's own code.
			4'd14: case (cell_x)
				5'd0:  glyph_id = 6'd29;         // 'T'   (G_T = 29)
				5'd1:  glyph_id = G_EQ;
				5'd2:  glyph_id = hex(pool.trace_pc0[15:12]);
				5'd3:  glyph_id = hex(pool.trace_pc0[11:8]);
				5'd4:  glyph_id = hex(pool.trace_pc0[7:4]);
				5'd5:  glyph_id = hex(pool.trace_pc0[3:0]);
				5'd6:  glyph_id = G_SP;
				5'd7:  glyph_id = hex(pool.trace_pc1[15:12]);
				5'd8:  glyph_id = hex(pool.trace_pc1[11:8]);
				5'd9:  glyph_id = hex(pool.trace_pc1[7:4]);
				5'd10: glyph_id = hex(pool.trace_pc1[3:0]);
				5'd11: glyph_id = G_SP;
				5'd12: glyph_id = hex(pool.trace_pc2[15:12]);
				5'd13: glyph_id = hex(pool.trace_pc2[11:8]);
				5'd14: glyph_id = hex(pool.trace_pc2[7:4]);
				5'd15: glyph_id = hex(pool.trace_pc2[3:0]);
				5'd16: glyph_id = G_SP;
				5'd17: glyph_id = hex(pool.trace_pc3[15:12]);
				5'd18: glyph_id = hex(pool.trace_pc3[11:8]);
				5'd19: glyph_id = hex(pool.trace_pc3[7:4]);
				5'd20: glyph_id = hex(pool.trace_pc3[3:0]);
				// 26th pass (2026-08-25): last free cell in this row.
				// Pairs with row 12 cell 21 (trace_pc0[19:16]) -- see that
				// comment for the full rationale. This is trace_pc2's bank
				// nibble: trace_pc2 is the LAST pre-trigger opcode fetch
				// (immediately before trace_pc3, the triggering fetch that
				// crossed $07DB), so this cell is the single most
				// diagnostic bit of new data for the "same bank throughout
				// vs. cross-bank wild jump" question. trace_pc0..pc3 are
				// already 24-bit internally (see trace_pc0_r in
				// fpga64_sid_iec.vhd) -- this is a display-only addition.
				5'd21: glyph_id = hex(pool.trace_pc2[19:16]);
				default: glyph_id = G_SP;
			endcase

			default: glyph_id = G_SP;
		endcase
	end
`else
	always_comb glyph_id = G_SP;
`endif

endmodule
