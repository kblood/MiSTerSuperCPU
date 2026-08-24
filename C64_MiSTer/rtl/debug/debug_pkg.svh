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
  `ifndef DBG_UART
    `define DBG_UART
  `endif
`endif

// ---- DBG_UART implies DBG_OVERLAY -------------------------------------
// The pool struct is declared inside `ifdef DBG_OVERLAY in debug_pkg.svh,
// and the UART formatter consumes pool fields, so enabling DBG_UART
// without DBG_OVERLAY is a config error. Auto-promote.
`ifdef DBG_UART
  `ifndef DBG_OVERLAY
    `define DBG_OVERLAY
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
  logic  [7:0] vic_d011;         // VIC ctl1 (bit5=BMM, bit4=DEN, bit6=ECM)
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
  logic  [7:0] d018_bad_value;  // value of cpuDo at last D018 != $18 write

  // v211: PC ring buffer. Latches PC at each opcode fetch (T65 SYNC=1
  // OR P65C816 vpa=vda=1). Freezes on FIRST $D018 != $18 write. Reveals
  // the call chain leading to the bug. T0 = oldest of 4 entries, T3 =
  // newest (= the PC just before the trigger fired).
  logic [23:0] trace_pc0;
  logic [23:0] trace_pc1;
  logic [23:0] trace_pc2;
  logic [23:0] trace_pc3;
  // v223: parallel 4-deep opcode-byte ring. Captures cpuDi at the
  // same edge as the PC ring on opcode_fetch_pulse. Pairs as
  // {pc0, op0} ... {pc3, op3}. Tells us the actual byte at each
  // captured PC. T65/SCPU should see the SAME opcode at the SAME
  // address; if bytes differ -> RAM corruption, if bytes are same
  // but ring chains diverge -> CPU instruction-decode bug.
  logic  [7:0] trace_op0;
  logic  [7:0] trace_op1;
  logic  [7:0] trace_op2;
  logic  [7:0] trace_op3;
  logic        trace_frozen;

  // v254: 4-deep JSR ring. Lower 16 bits of the PC of the last 4 JSR
  // ($20) or JSL ($22) opcode fetches. Independent of trace_frozen.
  // Each captured screenshot reveals the most recent 4 callers — the
  // JSR-immediately-before-trigger is the routine that called the
  // writer. Compare T65 vs SCPU JSR PCs to find upstream divergent
  // dispatcher. t0=oldest, t3=newest.
  logic [15:0] jsr_pc_t0;
  logic [15:0] jsr_pc_t1;
  logic [15:0] jsr_pc_t2;
  logic [15:0] jsr_pc_t3;

  // v255: 4-deep JMP-indirect target ring. After fetching $6C / $7C /
  // $DC, the next opcode_fetch_pulse fires AT the resolved target —
  // we capture cpu_pc_now's lower 16 bits at that moment. DL's IRQ
  // stub runs `JMP ($0002)` so this ring shows the dispatch target
  // chosen each IRQ. T65 vs SCPU difference here = the same vector
  // address resolved to different writer/handler routines.
  logic [15:0] jmp_tgt_t0;
  logic [15:0] jmp_tgt_t1;
  logic [15:0] jmp_tgt_t2;
  logic [15:0] jmp_tgt_t3;

  // v255: KERNAL IRQ vector RAM bytes ($0314 / $0315) and CPU IO port
  // direction/data ($0000 / $0001). KERNAL IRQ vector bytes show
  // where IRQ jumps; if T65 vs SCPU differ here, IRQ entry diverges.
  // CPU IO port $01 controls LORAM/HIRAM/CHAREN — affects what code
  // is visible at $A000/$D000/$E000 (BASIC ROM, charset, KERNAL ROM).
  // SCPU running with different IO port value = same PC fetches
  // different bytes -> wholly different code path.
  logic  [7:0] mem_0314;
  logic  [7:0] mem_0315;
  logic  [7:0] mem_00;
  logic  [7:0] mem_01;

  // v219: throughput counter — increments on every opcode fetch
  // (T65 SYNC=1 + enableCpu_6510=1 OR P65C816 vpa=vda=1 +
  // enableCpu_816=1). 24-bit gives ~16M opcodes range = ~16 sec
  // at 1MHz before wrap. Diff between consecutive frame samples =
  // opcodes per frame. T65 vs SCPU comparison answers "same code,
  // slower" vs "different code path".
  logic [23:0] op_count;

  // v228: I-flag diagnostics. scpu_iclr=1 if SCPU's I-flag was ever
  // observed at 0 (CLI / PLP cleared it). irq_vec_count = 16-bit count
  // of $FFFE/$FFFF reads (IRQ vector fetches). min_p = lowest dbg_p
  // observed when SCPU active. Together these confirm whether SCPU
  // ever clears I and whether IRQs ever fire.
  logic        scpu_iclr;
  logic [15:0] irq_vec_count;
  logic  [7:0] min_p;

  // v229: tail-chain diagnostics. RTI count vs IRQ entries
  // (= irq_vec_count/2) discriminates mid-handler re-entry from
  // source re-fire. nmi_vec_count > 0 indicates NMI path is firing
  // (DL doesn't normally use NMIs).
  logic [15:0] rti_count;
  logic [15:0] nmi_vec_count;

  // 2026-08-24 Wolf3D wild-jump investigation: signed JSR/JSL vs
  // RTS/RTL call-depth drift counter (see fpga64_sid_iec.vhd
  // call_depth_r). Hardware-IRQ theory falsified (irq_vec_count flat
  // through the divergence window) -- this tests whether an unbalanced
  // call/return inside loader.prg's REU-poll loop walks SP toward
  // $01FF instead.
  logic [15:0] call_depth;
  // 14th pass: saturating (sticky, never-decrements) |call_depth|
  // tracker, clamped at 15. A single noisy nibble sample of the raw
  // signed call_depth wrapped ambiguously (true depth 7 and depth 23
  // both read as hex 7); this field's value across timestamped
  // samples is monotonic non-decreasing, so its growth trajectory
  // pins down whether abnormal depth appears during the t=15-30s
  // divergence window specifically.
  // 15th pass: HW showed this pinned at $F from t=5s onward -- a
  // "since reset" counter saturates on ordinary KERNAL/BASIC boot
  // nesting alone. Both call_depth and call_depth_maxabs now rezero
  // when PC reaches loader.prg's relocated entry ($00:0700), so the
  // trajectory reflects drift from the loader taking over, not boot.
  logic [3:0] call_depth_maxabs;
  // 15th pass: call_depth_maxabs saturated at $F even measured from the
  // loader's own entry -- consistent with benign JSR/JMP-tail asymmetry
  // in ordinary code saturating a maxabs-15 tracker within milliseconds
  // at MHz execution rates, not a diagnosable signal at any zero point.
  // Pivoted to a direct P65C816 VPB (vector pull) snoop instead: last
  // vector-fetch address (low 16 bits, bank always $00), rezeroed at the
  // same $0700 loader-entry trigger. A nonzero final value means at
  // least one interrupt/reset vector was fetched after the loader took
  // over; the specific address identifies which vector class (see
  // fpga64_sid_iec.vhd's vecfetch_addr_r declaration comment for the
  // full address-to-vector-class table).
  logic [15:0] vecfetch_addr;

  // v230: source-ack discrimination.
  // d019_wr_count = CPU writes to $D019 (VIC IRQ ack write-1-clear)
  // dc0d_rd_count = CPU reads of $DC0D (CIA1 ICR read-clear)
  // Compare against IV/2 = IRQ entries. If T65 = SCPU = entries,
  // handler runs to ack on both → source-re-fire bug. If SCPU << T65,
  // ack write/read is missing → handler-incomplete bug.
  logic [15:0] d019_wr_count;
  logic [15:0] dc0d_rd_count;

  // v231: source-side IRQ_N falling-edge count. Should match IV/2
  // for both T65 and SCPU. If SCPU IV/2 >> falling edges, the CPU
  // re-enters on a single source pulse (level-IRQ tail-chain).
  logic [15:0] irq_fall_count;
  // v12 (2026-05-24): CIA1-only IRQ falling edges (pre-AND).
  // Differential vs irq_fall_count disambiguates whether MCP affects
  // CIA1 internally vs eats the assertion downstream of the AND.
  logic [15:0] irq_cia1_fall_count;
  // v12b (2026-05-24): CIA1 internal IMR / CRA snapshots. If MCP causes
  // phantom $DC0D/$DC0E writes, these will differ between passthrough
  // (imr=$81, cra[0]=1 during LOAD) and MCP (likely cleared).
  logic  [4:0] cia1_imr;
  logic  [7:0] cia1_cra;
  // mb-probe-003 (2026-05-26): CIA1 Timer A counter, reload latch, raw ICR.
  // Identifies which of (counter halted / reload zeroed / ICR latch stuck /
  // downstream IRQ logic) explains why CIA1 stops firing Timer A IRQs
  // during the MCP LOAD"*",8,1 wedge.
  logic [15:0] cia1_timer_a;
  logic [15:0] cia1_timer_a_latch;
  logic  [4:0] cia1_icr;
  // Option F (2026-05-25): CIA2 imr/cra snapshots for LOAD"*",8,1 wedge.
  logic  [4:0] cia2_imr;
  logic  [7:0] cia2_cra;
  // Option G (2026-05-25): CIA2 port + DDR snapshots for IEC-port phantom-write.
  logic  [7:0] cia2_pra;
  logic  [7:0] cia2_prb;
  logic  [7:0] cia2_ddra;
  logic  [7:0] cia2_ddrb;

  // v232: per-source IRQ levels + last $D019 write value. Identifies
  // which source is stuck low and confirms SCPU writes the correct
  // ack value to $D019.
  logic        irq_vic_lvl;
  logic        irq_cia1_lvl;
  logic        irq_n_lvl;
  logic        irq_ext_lvl;
  logic  [7:0] d019_last_val;

  // v234: $D019 read-side + $D01A write-side probes. d019_last_read =
  // value the CPU READ from $D019 (= IRQ source bits visible to DL's
  // dispatch). d019_seen_bits = sticky-OR of bits 0..3 (IRST/IMBC/
  // IMMC/ILP) ever seen in any read; tells us the full set of source
  // latches that have asserted at any point. d01a_last_val = last
  // value written to $D01A (the IRQ enable mask). If T65 and SCPU
  // diverge on any of these, the upstream branch divergence has
  // already happened by the time the IRQ handler runs.
  logic  [7:0] d019_last_read;
  logic  [3:0] d019_seen_bits;
  logic  [7:0] d01a_last_val;

  // v235: VIC sprite-control register write probes. T65 reads
  // $D019=$F1 (only IRST set); SCPU reads $D019=$F7 (IRST + IMBC +
  // IMMC = raster + sprite-bgnd + sprite-sprite collisions). Extra
  // collision IRQs imply sprites are wrong on SCPU. These probes
  // capture last-written values for the sprite control regs:
  //   $D015 = sprite enable mask (one bit per sprite)
  //   $D017 = sprite Y-expand mask
  //   $D01B = sprite-background priority mask
  //   $D01C = sprite multicolor mask
  //   $D01D = sprite X-expand mask
  // d015_last_pc = PBR:PC of the writer that last wrote $D015 (which
  // routine drives sprite enables). d015_wr_count = saturating 8-bit
  // counter (frequency = per-frame multiplexer vs setup-time enable).
  logic  [7:0] d015_last_val;
  logic [23:0] d015_last_pc;
  logic  [7:0] d015_wr_count;
  logic  [7:0] d017_last_val;
  logic  [7:0] d01b_last_val;
  logic  [7:0] d01c_last_val;
  logic  [7:0] d01d_last_val;

  // v236: sprite-position write probes. Sprite control (D015/D01B/D01C)
  // was identical T65 vs SCPU; collisions still fire on SCPU. Position
  // divergence is the remaining viable explanation. Capture last-written
  // values for sprite 0 X/Y ($D000/$D001), sprite 1 X/Y ($D002/$D003),
  // and the high-X bits register ($D010).
  logic  [7:0] d000_last_val;
  logic  [7:0] d001_last_val;
  logic  [7:0] d002_last_val;
  logic  [7:0] d003_last_val;
  logic  [7:0] d010_last_val;
  // v265: d001 writer PC. cpu_pc_now latched at the cycle that
  // wrote $D001 (sprite0_y). v264 found SCPU writes Y=$AA every
  // ~3rd frame, T65 keeps Y=$D4. The writer PC tells us which DL
  // routine performs the bad $AA store.
  logic [23:0] d001_last_pc;

  // v238: I-flag edge probes (sampled at opcode_fetch only).
  // p_set_pc/clr_pc identify the first instruction that observed the
  // new I value; counts gauge how often each transition fires;
  // p_opfetch_min is the lowest P seen at instruction boundaries
  // (cf. v237 min_p which sampled every clock and could catch
  // transient mid-microcode I=0).
  logic [23:0] p_set_pc;
  logic [23:0] p_clr_pc;
  logic [15:0] p_set_count;
  logic [15:0] p_clr_count;
  logic  [7:0] p_opfetch_min;

  // v239: IRQ vector + stub + $0314/$0315 + cpuIO snapshot. v238 showed
  // SCPU IRQ enters $0062 invariant; v239 captures the actual RAM
  // bytes at $FFFE/$FFFF (vector), $0062..$0064 (stub opcode), and
  // $0314/$0315 (KERNAL-on indirect IRQ vector), plus cpuIO at the
  // moment of the $FFFE fetch (LORAM/HIRAM/CHAREN tells us if
  // KERNAL ROM was even mapped).
  logic  [7:0] vec_lo;       // byte read from $FFFE
  logic  [7:0] vec_hi;       // byte read from $FFFF
  logic  [7:0] mem_314;      // byte read from $0314 (KERNAL IRQ vec lo)
  logic  [7:0] mem_315;      // byte read from $0315 (KERNAL IRQ vec hi)
  logic  [7:0] mem_62;       // byte read from $0062 (stub byte 0)
  logic  [7:0] mem_63;       // byte read from $0063 (stub byte 1)
  logic  [7:0] mem_64;       // byte read from $0064 (stub byte 2)
  logic  [2:0] io_at_vec;    // cpuIO[2:0] at last $FFFE fetch

  // v240: extended stub bytes + RTI PC. v239 confirmed RAM identical
  // T65/SCPU at $0062..$0064 — bug is in CPU execution, not RAM.
  // mem_65..mem_6B disassemble more of the stub. rti_pc = address of
  // the LAST executed RTI instruction (= where the IRQ handler ends).
  // T65 expected: $9Fxx (FLI body); SCPU expected: $00xx (zero-page
  // stub) — would localize the divergent JMP/branch.
  logic  [7:0] mem_65;
  logic  [7:0] mem_66;
  logic  [7:0] mem_67;
  logic  [7:0] mem_68;
  logic  [7:0] mem_69;
  logic  [7:0] mem_6A;
  logic  [7:0] mem_6B;
  // v242: stub continuation past STA $6F. Reveals the JMP/JSR/branch
  // that DL's IRQ stub uses to dispatch to the actual handler body.
  // T65 reaches FLI ($9F09); SCPU does not. The divergent instruction
  // must be in $006C..$0073 (or its target).
  logic  [7:0] mem_6C;
  logic  [7:0] mem_6D;
  logic  [7:0] mem_6E;
  logic  [7:0] mem_6F;
  logic  [7:0] mem_70;
  logic  [7:0] mem_71;
  logic  [7:0] mem_72;
  logic  [7:0] mem_73;
  // v243: extension $0074..$0078 + dispatch-target PC. v242 found
  // bytes $0070-$0071 differ T65/SCPU and SCPU is stuck in only the
  // $811C->$8166->$8168 handler. v243 reveals the IRQ stub's
  // dispatch JMP target by snapshotting PC at the first opcode-fetch
  // outside zero page.
  logic  [7:0] mem_74;
  logic  [7:0] mem_75;
  logic  [7:0] mem_76;
  logic  [7:0] mem_77;
  logic  [7:0] mem_78;
  logic [23:0] disp_target_pc;
  // v244: dispatcher disasm + FLI verify + PC trace ring + write-PC
  logic  [7:0] mem_3380, mem_3381, mem_3382, mem_3383;
  logic  [7:0] mem_3384, mem_3385, mem_3386, mem_3387;
  logic  [7:0] mem_3388, mem_3389, mem_338A, mem_338B;
  logic  [7:0] mem_338C, mem_338D, mem_338E, mem_338F;
  logic  [7:0] mem_9F09, mem_9F0A, mem_9F0B, mem_9F0C;
  logic  [7:0] mem_9F0D, mem_9F0E, mem_9F0F, mem_9F10;
  logic  [7:0] mem_9F11, mem_9F12, mem_9F13, mem_9F14;
  logic  [7:0] mem_9F15, mem_9F16, mem_9F17, mem_9F18;
  logic [23:0] disp2_target_pc;
  logic [23:0] pc33_t0, pc33_t1, pc33_t2, pc33_t3;
  logic [23:0] wr70_pc, wr71_pc;
  logic [23:0] rti_pc;

  // v241: 2 more PCs leading up to RTI. rti_h1 = PC of instruction
  // immediately before RTI; rti_h2 = PC 2 instructions before. Lets
  // us see the divergent JMP/branch instruction inside the handler.
  logic [23:0] rti_h1;
  logic [23:0] rti_h2;

  // v245: 16 bytes around the divergent writer at $335F (T65 stores
  // $00/$05 here, SCPU stores $EA/$EA — same instruction, different
  // A). Reveals the A-feeding instruction in the IRQ prologue.
  logic  [7:0] mem_335D, mem_335E, mem_335F, mem_3360;
  logic  [7:0] mem_3361, mem_3362, mem_3363, mem_3364;
  logic  [7:0] mem_3365, mem_3366, mem_3367, mem_3368;
  logic  [7:0] mem_3369, mem_336A, mem_336B, mem_336C;
  // v245: 8 bytes at $3300..$3307. v244 showed $3380 = JMP $3100;
  // need $3300 to disassemble the other dispatcher entry T65 uses
  // to reach $3200/FLI.
  logic  [7:0] mem_3300, mem_3301, mem_3302, mem_3303;
  logic  [7:0] mem_3304, mem_3305, mem_3306, mem_3307;
  // v245: 8 bytes at $3100..$3107. Both modes hit this; SCPU
  // dispatches here exclusively. Disassembling reveals the
  // instructions feeding the divergent A.
  logic  [7:0] mem_3100, mem_3101, mem_3102, mem_3103;
  logic  [7:0] mem_3104, mem_3105, mem_3106, mem_3107;
  // v245: actual cpuDo at $0070/$0071 write cycle. v244 inferred
  // T65=$00/$05, SCPU=$EA/$EA from later READS but a second writer
  // could have intervened. Direct write-cycle capture is unambiguous.
  logic  [7:0] wr70_val;
  logic  [7:0] wr71_val;

  // v246: bytes $0079..$007F (past v243's $78 boundary). v245 proved
  // the bug is in dispatcher predicate (selecting $3300 vs $3380),
  // so the dispatch JMP itself must live here.
  logic  [7:0] mem_79;
  logic  [7:0] mem_7A;
  logic  [7:0] mem_7B;
  logic  [7:0] mem_7C;
  logic  [7:0] mem_7D;
  logic  [7:0] mem_7E;
  logic  [7:0] mem_7F;
  // v246: 16-bit counters for disp2_target hits at $3200 (FLI/gameplay)
  // and $3100 (chain). T65 expected ~50/50, SCPU expected biased.
  logic [15:0] cnt_3200;
  logic [15:0] cnt_3100;

  // v247: $5B + DF01 + bytes $0080-$008B. v246 proved IRQ stub at
  // $0079 does LDA #$40 / STA $DF02 / LDA $5B; REU CMD readback
  // differs T65=$31 vs SCPU=$7D. Hypothesis: LDA $5B returns
  // different value, fed to next STA (presumably $DF01).
  logic  [7:0] mem_5B;
  logic [23:0] wr5B_pc;
  logic  [7:0] wr5B_val;
  logic [23:0] wr_df01_pc;
  logic  [7:0] wr_df01_val;
  logic [15:0] cnt_df01;
  logic  [7:0] mem_80;
  logic  [7:0] mem_81;
  logic  [7:0] mem_82;
  logic  [7:0] mem_83;
  logic  [7:0] mem_84;
  logic  [7:0] mem_85;
  logic  [7:0] mem_86;
  logic  [7:0] mem_87;
  logic  [7:0] mem_88;
  logic  [7:0] mem_89;
  logic  [7:0] mem_8A;
  logic  [7:0] mem_8B;

  // v249: IRQ dispatch ptr + JMP indirect operand high byte. v248
  // overlay decode showed bytes $80..$8B = "8D 06 DF A5 59 8D 04 DF
  // A0 FF 6C 02" -- the IRQ stub ends with JMP ($XX02). Operand low
  // byte is $02 (NOT $FF) so v248's NMOS page-wrap fix is irrelevant
  // to DL. mem_8C captures the operand high byte: if $00, dispatch is
  // JMP ($0002). mem_02/mem_03 carry the actual target word; if T65
  // and SCPU read different values there, the upstream divergence is
  // localized. wr02_pc/val/wr03_pc/val pinpoint the writer of those
  // bytes. p_irq_tN holds the P (status flags) at the last 4 IRQ
  // entries (sampled on $FFFE vector fetch) -- detects D/V/C flag
  // drift between modes that could divert the handler.
  logic  [7:0] mem_8C;
  logic  [7:0] mem_02;
  logic  [7:0] mem_03;
  logic [23:0] wr02_pc;
  logic  [7:0] wr02_val;
  logic [23:0] wr03_pc;
  logic  [7:0] wr03_val;
  // v256: write-count to $0002 (dispatch vector lo). Increments every
  // cpuWe to $0002. Tracks how often the dispatch vector is updated.
  // T65 should tick this once per IRQ; SCPU << T65 if writer skipped.
  logic [15:0] cnt_wr02;
  // v257: write-count to $0002 where new value DIFFERS from previous.
  // T65 expected: cnt_wr02_chg ≈ cnt_wr02 (every write is a fresh
  // dispatch target). SCPU expected: cnt_wr02_chg << cnt_wr02 (writer
  // stores same target repeatedly across IRQs).
  logic [15:0] cnt_wr02_chg;
  // v258: 4-deep ring of last values stored to $0002 (newest=v3) +
  // X+Y register state at the most recent $0002 write. Direct probe
  // of the value distribution and the upstream table-index register.
  logic  [7:0] wr02_v0;
  logic  [7:0] wr02_v1;
  logic  [7:0] wr02_v2;
  logic  [7:0] wr02_v3;
  logic  [7:0] wr02_y;
  logic  [7:0] wr02_x;
  // 2026-05-09 doom-wait probe — captures last $00:$0700-$07FF read.
  // _addr is low byte of the read address; _data is the byte returned.
  // See project_doom_wait_loop_at_41db9a.md.
  logic  [7:0] rd07xx_addr;
  logic  [7:0] rd07xx_data;
  logic  [7:0] p_irq_t0;
  logic  [7:0] p_irq_t1;
  logic  [7:0] p_irq_t2;
  logic  [7:0] p_irq_t3;

  // v259: DL per-IRQ gate variables. Per x64sc disasm of $8100-$811C:
  //   LDA $44 / BNE $811C  -- if $44 != 0, skip game advance
  //   LDA $40 / BEQ $811C  -- if $40 == 0, skip game advance
  //   ; else SED / DEC $40 / CLD / JMP $1F4E (game advance)
  // T65 reaches JMP $1F4E (page $1F vblank-PC sample); SCPU never does.
  // Capture the actual byte values to localize gate corruption.
  logic  [7:0] mem_40;
  logic  [7:0] mem_44;
  logic  [7:0] mem_5C;

  // v260: main-thread vs IRQ-thread PC split. v259 falsified the gate
  // hypothesis (both modes have $40=$44=$00 always). Divergence is in
  // main-thread code path. pc_main = PC at last opcode fetch with
  // I-flag clear; pc_irq = with I-flag set. Plus mem_45 (wait-loop var)
  // and per-page opcode counters for $30 (T65 FLI body) and $97 (SCPU
  // mirror) — directly compares time spent in each region.
  logic [23:0] pc_main;
  logic [23:0] pc_irq;
  logic  [7:0] mem_45;
  logic [15:0] cnt_pc_30;
  logic [15:0] cnt_pc_97;

  // v262: 4-deep ring of values written to $005C (newest = v3) plus a
  // 16-bit total-write counter. $5C is DL's IRQ-handler state counter,
  // decremented at $8166 (STX $5C with X = $5C - 1) and reset at $8164
  // (LDX #$04) and $3343 (STA $5C #$04). VICE x64sc disasm shows T65
  // expected sequence is 4,3,2,1,0,4,3,2,1,0... (5-cycle). v260 found
  // SCPU has $5C zero-rate 33% (vs T65's 20%) — points to a 3-cycle
  // sequence. Direct ring capture shows the actual write values so we
  // can prove whether DEX is decrementing by 2 (4,2,0,4,2,0) or by 1
  // with skipped resets (4,3,2,4,3,2) or some other pattern.
  logic  [7:0] wr5C_v0;
  logic  [7:0] wr5C_v1;
  logic  [7:0] wr5C_v2;
  logic  [7:0] wr5C_v3;
  logic [15:0] cnt_wr5C;

  // v267: $D012 raster-IRQ tail-chain timing probe (Path B1).
  // v266 ruled out collision-IRQ as cause of SCPU's 3.755 IRQ
  // entries/frame. Hypothesis: SCPU emu-mode IRQ handler updates
  // $D012 (raster compare) AFTER the raster has advanced past the
  // new compare value, causing IRST to re-assert immediately on
  // the $D012 write -> level-IRQ tail-chain re-entries.
  // Fields snapshot the most-recent CPU write to $D012:
  //   d012_write_cycles : clk32 cycles since last IRQ_N falling
  //                       (saturating). T65 expected ~few hundred,
  //                       SCPU expected larger.
  //   d012_last_val     : value written.
  //   raster_at_d012    : raster line at write moment. If
  //                       raster_at_d012 > d012_last_val, the
  //                       compare register is BEHIND the beam.
  //   d012_last_pc      : writer PC (24-bit).
  //   d012_wr_count     : total $D012 writes (delta-per-frame =
  //                       compare-arms per frame).
  logic [15:0] d012_write_cycles;
  logic  [7:0] d012_last_val;
  logic  [8:0] raster_at_d012;
  logic [23:0] d012_last_pc;
  logic [15:0] d012_wr_count;

  // v268: IRQ rising-edge counters. v267 ruled out per-IRQ $D012
  // updates — bug is now "irq_combined never rises after first fall
  // on SCPU." This probe distinguishes:
  //   irq_vic_rise_count       == 0 -> VIC IRST never clears -> ack
  //                                   write doesn't reach VIC OR
  //                                   resetRasterIrq pulse doesn't
  //                                   align with phi=1 sample window.
  //   irq_combined_rise_count  == 0 but irq_vic_rise_count > 0 -> VIC
  //                                   ack works but another irq source
  //                                   on the AND chain holds combined low.
  logic [15:0] irq_vic_rise_count;
  logic [15:0] irq_combined_rise_count;

  // v269: VIC-internal IRQ ack diagnostics. v268 confirmed irq_vic
  // never rises on SCPU. These two counters peek inside the VIC to
  // distinguish where the $D019 ack write fails:
  //   vic_d019_wr_count     : myWr_a fires AND addr_r=$D019 (regardless
  //                           of di_r(0)). Cf. dbg_pool.d019_wr_count
  //                           which counts CPU-side attempts.
  //   vic_resetraster_count : resetRasterIrq pulses (IRST clear path
  //                           actually fires). Should equal
  //                           vic_d019_wr_count when di_r(0)=1 each time.
  logic [15:0] vic_d019_wr_count;
  logic [15:0] vic_resetraster_count;

  // v270: $D019 writer PC + sticky cpuDo OR. v269 confirmed di_r(0) is
  // always 0 at SCPU $D019 writes. d019_seen_writes shows whether bit 0
  // of cpuDo is EVER set across the whole capture; d019_last_pc points
  // at the most recent $D019 writer's instruction (24-bit {PBR,PC} for
  // SCPU, {00,PC} for T65).
  logic [23:0] d019_last_pc;
  logic  [7:0] d019_seen_writes;

  // v271: per-write filter on cpuDo(0). d019_ack_count counts the writes
  // that actually clear IRST (cpuDo bit 0 = 1); d019_ack_pc latches the
  // PC of the most-recent ack write. Predicts T65 ~1/frame, SCPU 0/frame.
  // T65's d019_ack_pc identifies the ack instruction; disasm + cross-ref
  // SCPU's IRQ-thread PCs from v260 to find the divergent branch.
  logic [15:0] d019_ack_count;
  logic [23:0] d019_ack_pc;

  // v280: 16-bit P65C816 stack pointer. Doom v274 PC-stuck at $006C03
  // shows V-ring `00 6C 05 04` matching native-mode BRK 4-byte push to
  // $00:$6C04..$6C01 — so SP appears to live in $6C0X. Direct readback
  // confirms or refutes the SP-in-$6C0X hypothesis.
  logic [15:0] cpu_sp;

  // v309 doom wedge: native BRK vector lo/hi (scpu_native_vec(2)/(3)).
  // Reveals whether software installed BRK→$0705, closing the wedge in
  // one hop.
  logic  [7:0] brk_vec_lo;
  logic  [7:0] brk_vec_hi;

  // v341 doom bitmap probe: last R/W value seen at bank $00:$1D02 and
  // $00:$1D04. Doom's frame-flip code at $80:$0B40 reads $1D04; if 0,
  // VIC bank → 3 ($C000); otherwise → 1 ($4000). HW stuck at DD00=$02
  // (bank 1) means $1D04 never reaches 0. Surfacing both bytes per
  // vblank tells us whether the IRQ handler's $0D6C handshake fires.
  logic  [7:0] mem_1d02;
  logic  [7:0] mem_1d04;
  // v346 doom bitmap-content probe: per-frame sticky OR of vicDi. If $00
  // across full Doom runtime, VIC is reading only zero bytes → screen
  // is genuinely empty regardless of register state. If != $00, VIC sees
  // data and the black screen has a non-memory cause (color RAM, mode).
  logic  [7:0] vic_di_or;

  // v347 doom bitmap-write probe: per-frame saturating count of CPU
  // SDRAM writes targeting bank-0 SDRAM regions $4000-$5FFF (bm1) and
  // $C000-$DFFF (bm3). Counts both direct bank-$00 writes and bank-$01
  // writes routed via the Tier-3 mirror. Latched on vsync rising edge.
  // bitmap_render_test*.prg proved this path renders correctly, so if
  // Doom's counters stay at $00 across all frames, Doom never reaches
  // its bitmap renderer (init wedge somewhere upstream).
  logic  [7:0] bm1_writes;
  logic  [7:0] bm3_writes;

  // Milestone B (2026-05-25): bridge-internal UART probes per
  // docs/milestone_b_bridge_probe_design.md §B. Drive the new
  // " FS:# DI:## RQ:#### AK:#### VF:##" suffix in the UART line so
  // the next HW build can discriminate Race α (vector-byte aliasing)
  // vs Race β (ack-stall accumulation) at the LOAD"*",8,1 wedge.
  logic [3:0]  bridge_fsm_state;       // 0=IDLE 1=REQ_PENDING 2=WAIT_ACK 3=LATCH
  logic [7:0]  bridge_last_bus_di;     // bus_di_capture_reg snapshot
  // v2 (2026-05-26 — Codex Design 3): the next three fields are now
  // vblank-SNAPSHOT registers (held stable per frame in clk_cpu before
  // crossing to clk_sys, fixing v1's multi-bit-tearing CDC).
  logic [15:0] bridge_req_count;       // wrapping IDLE→REQ_PENDING count (snap)
  logic [15:0] bridge_ack_count;       // wrapping WAIT_ACK→LATCH count (snap)
  logic [7:0]  bridge_vec_fetch_count; // saturating $00:$FFFE/$FFFF read count

  // Milestone B v2 (2026-05-26): Codex Design 3 additions.
  //   wait_dwell_max — max clk_cpu cycles in WAIT_ACK per frame (sat $FFFF).
  //     The real Race β detector — bridge is one-outstanding so RQ-AK gap
  //     can't widen, but a wedge in WAIT_ACK shows up here.
  //   activity_flags — sticky-per-frame: {dwell_sat,_,_,_,_,wait_seen,
  //     ack_seen,req_seen}. Tells you whether the FSM made any progress.
  //   gap_max — max RQ-AK divergence per frame (sat $FF). Sanity check —
  //     should be 0/1 always; any higher = invariant broken.
  logic [15:0] bridge_wait_dwell_max;
  logic [7:0]  bridge_activity_flags;
  logic [7:0]  bridge_gap_max;

  // 2026-05-28: live IEC line states for the LOAD"*",8,1 1MHz wedge.
  // Distinguishes "65816 read of $DD00 is stale (drive released DATA but
  // C64 can't see it)" from "drive is holding DATA (write-sequence/
  // drive-side stall)". Bit layout:
  //   [0] c64_iec_data (C64 DATA-out line, 1=released/high)
  //   [1] c64_iec_clk  (C64 CLK-out line)
  //   [2] c64_iec_atn  (C64 ATN-out line, 1=released)
  //   [3] drive_iec_data (drive DATA-out, 1=released; 0=drive pulling)
  //   [4] drive_iec_clk  (drive CLK-out)
  logic  [7:0] iec_lines;

  // more-turbo iter-4d (2026-05-30): read-only cpu_cache hit-rate observer.
  // cache_hr = HITs in last completed 256-cacheable-read window (sat 255;
  //            cache_hr/2.56 = approx hit %). Sliding window => steady state,
  //            immune to cold-start compulsory misses. GHDL-validated ~237
  //            (92.6%) on the KERNAL stream vs the 94.12% cross-checked bench.
  // cache_hw = window-completion counter (wraps every 256 windows). Advances
  //            between UART lines => observer is seeing CPU read traffic
  //            (liveness; distinguishes "0% hit" from "no cacheable reads").
  logic  [7:0] cache_hr;
  logic  [7:0] cache_hw;
} dbg_pool_t;
`endif

`endif // DEBUG_PKG_SVH
