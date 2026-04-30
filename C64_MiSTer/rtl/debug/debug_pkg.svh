// debug_pkg.svh
//
// Macro defaults, layout constants, and the dbg_pool_t struct that carries
// captured diagnostic state from cap_*.sv modules to the renderer.
//
// Include with `include "debug_pkg.svh"` from c64.sv (the SEARCH_PATH in
// debug.qip puts rtl/debug/ on the include path).
//
// Macro polarity:
//   - C64_release.qsf defines DEBUG_RELEASE=1 -> everything below resolves
//     to "undef" and synthesis collapses every overlay/capture wire.
//   - C64.qsf (default debug build) defines DEBUG_ENABLE=1 which cascades
//     to DBG_OVERLAY + DBG_CAP_* unless the caller has set finer gates
//     before this header is included.

`ifndef DEBUG_PKG_SVH
`define DEBUG_PKG_SVH

// ---- Master release gate ----------------------------------------------
// If set, undef every fine-grained DBG_* macro so synthesis collapses the
// overlay/capture trees to direct passthroughs.
`ifdef DEBUG_RELEASE
  `undef DEBUG_ENABLE
  `undef DBG_OVERLAY
  `undef DBG_CAP_REU
  `undef DBG_CAP_VIC_WR
  `undef DBG_CAP_CPU_STATE
  `undef DBG_CAP_FRAME
  `undef DBG_UART
`endif

// ---- DEBUG_ENABLE cascade ---------------------------------------------
// Turning on DEBUG_ENABLE in the qsf is shorthand for "I want overlay +
// every capture domain unless I've already opted out below". A user who
// wants only one capture lane can `\`define DBG_OVERLAY` + a single
// `DBG_CAP_*` in the qsf and leave DEBUG_ENABLE undef.
`ifdef DEBUG_ENABLE
  `ifndef DBG_OVERLAY
    `define DBG_OVERLAY
  `endif
  `ifndef DBG_CAP_REU
    `define DBG_CAP_REU
  `endif
  `ifndef DBG_CAP_VIC_WR
    `define DBG_CAP_VIC_WR
  `endif
  `ifndef DBG_CAP_CPU_STATE
    `define DBG_CAP_CPU_STATE
  `endif
  `ifndef DBG_CAP_FRAME
    `define DBG_CAP_FRAME
  `endif
`endif

// ---- Layout id (commit 6 will populate) -------------------------------
// DBG_LAYOUT picks which fields render where. Layout 1 = DL triage.
`ifndef DBG_LAYOUT
  `define DBG_LAYOUT 1
`endif

// ---- Pool struct -------------------------------------------------------
// Carries captured diagnostic state from cap_*.sv modules to the
// renderer. Only declared when DBG_OVERLAY is set so release builds
// don't pay the type-check overhead.
`ifdef DBG_OVERLAY
typedef struct packed {
  // REU domain
  logic [15:0] reu_c64_addr;     // $DF02/$DF03 - C64 target
  logic [23:0] reu_reu_addr;     // $DF04/$DF05/$DF06 - REU side
  logic [15:0] reu_length;       // $DF07/$DF08
  logic  [7:0] reu_cmd;          // $DF01 last command
  logic [15:0] reu_fetch_count;  // FETCH/STASH execution counter

  // VIC + bus domain
  logic  [7:0] vic_d018;         // screen + char-bitmap pointer
  logic  [7:0] vic_d016;         // X-scroll + control2
  logic  [7:0] vic_dd00;         // CIA2 PA - VIC bank select
  logic [11:0] vic_raster;       // raster line decimal (0..311 PAL)

  // CPU domain
  logic [23:0] cpu_pc;           // 24-bit (PBR:PC) for SCPU, $00:PC for T65
  logic  [7:0] cpu_p;            // status flags (NV-MX-DIZC) - SCPU only
  logic  [7:0] cpu_dbr;          // data bank register - SCPU only
  logic  [7:0] cpu_flags;        // {ba,dma,turbo,scpu_en,1mhz,iec,emu,e_flag}

  // Misc
  logic [15:0] frame_count;      // ticks each vsync rising edge

  // 2026-04-30 DL triage extension: capture PC at the moment of the
  // last $DD00 write + a write counter. T65 baseline writes $DD00=$01
  // for VIC bank 2; SCPU=on path writes $00 / $02 (wrong) — the PC
  // logged here pinpoints which DL routine produces the bad value so
  // we can disassemble at that address.
  logic [23:0] dd00_write_pc;    // PC at last $DD00 write
  logic  [7:0] dd00_write_count; // wraps; nonzero = at least one write seen

  // Per-value PC latches: dd_pc_v[N] = PC where last $DD00 write had
  // value & 3 == N. Reveals which routine writes which VIC bank value.
  // T65 baseline expected to populate all 4; SCPU=on missing v[1] is
  // the divergence ($01 = bank 2 = correct DL bitmap location).
  logic [23:0] dd00_pc_v0;       // value & 3 == 0
  logic [23:0] dd00_pc_v1;       // value & 3 == 1 (target — DL bitmap)
  logic [23:0] dd00_pc_v2;       // value & 3 == 2
  logic [23:0] dd00_pc_v3;       // value & 3 == 3

  // Per-value 8-bit counters: tells us *how often* each writer fires.
  // T65 baseline alternates all four; SCPU bug = N1/N3 frozen at 1.
  logic  [7:0] dd00_cnt_v0;
  logic  [7:0] dd00_cnt_v1;
  logic  [7:0] dd00_cnt_v2;
  logic  [7:0] dd00_cnt_v3;

  // 2026-04-30 v210: $D018 write tracking. SCPU intermittently writes
  // garbage values (e.g., $FF, $66) while T65 always writes $18. Capture
  // PC at last write where D018 != $18 (= "bad" write) and a count.
  logic [23:0] d018_bad_pc;     // PC at last D018-write with value != $18
  logic  [7:0] d018_bad_count;  // #writes where written value != $18
  logic [23:0] d018_last_pc;    // PC at last D018-write (any value)
  logic  [7:0] d018_count;      // total D018-writes
} dbg_pool_t;
`endif

`endif // DEBUG_PKG_SVH
