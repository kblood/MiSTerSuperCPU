GOAL: Falsify a phasing decision in RTL before a 30-40 min FPGA build. This
speed lever has been HW-falsified ~5x by off-by-one consume-race bugs, so be
adversarial and precise with cycle/slot reasoning.

CONTEXT — read these:
- docs/iter14_altfire_rtl_brief.md  (the design; esp. the "CORRECTED DESIGN" section)
- sim/cache_coherency_tb/cpu_cache_altfire_race_tb.vhd  (the proof bench; GATE_MODE 6 is the accepted policy)
- C64_MiSTer/rtl/cpu_cache.vhd  (lines 172-310: same_line, tag_match, byte_valid, cache_hit, line_word, prev_line/prev_tag, cache_di byte-select)
- C64_MiSTer/rtl/fpga64_sid_iec.vhd:
    * 3426-3432 cpu_cyc combinational (fires CPU0/4/8/C)
    * 3554-3556 cpu_cyc_s shift + `enableCpu <= cpu_cyc_s(1)`
    * 1987-1989 cpuDi override (uses registered rp_cache_hit_d1/rp_cache_di_d1)
    * 4916-4971 gen_read_path: rp_cache_*_d1 registration + read_path_cache instance (same_line => open today)

KEY RTL FACTS I have established (verify them):
1. enableCpu is REGISTERED: `enableCpu <= cpu_cyc_s(1)`. Baseline supercpu native
   mode forces turbo_m=max so cpu_cyc fires CPU0/4/8/C => enableCpu high during
   CPU3/7/B/F (4-apart). The P65C816 samples `enable` at a rising edge and reads the
   PRE-EDGE value, so enableCpu high during slot X => the CPU steps at edge X->X+1
   (latches di-during-X, new cpuAddr appears during X+1). "cpuAddr advances 1 clk32
   AFTER the enable-high slot."
2. cpu_cache: prev_line/prev_tag are registered EVERY clk32 from the live address
   (cpu_cache.vhd:293-294, unconditional). So same_line(now) = "current cpuAddr line
   == cpuAddr line one clk32 ago." tag_match/byte_valid are COMBINATIONAL (MLAB async)
   on the live cpuAddr, so cache_hit is valid the SAME cycle the address is presented.
   line_word is registered 1 clk32 after the address; cache_di = byteselect(line_word,
   live byte_offset). The fpga64 override registers cache_di/cache_hit once more
   (rp_cache_di_d1 / rp_cache_hit_d1), so cpuDi(slot S) = rp_cache_di_d1(S) reflects
   the address from 2 clk32 earlier for the line_word part, but the byte_offset part
   tracks 1-earlier — i.e. a same-line consume is correct, a cross-line consume is stale.

THE BENCH (GATE_MODE=6) models the consume as a SINGLE clocked event: at edge E it
decides do_latch from sl_d1 (=same_line registered once = same_line(E-1)) AND
rp_cache_hit_d1(=cache_hit(E-1)), and at that SAME edge E it consumes cpuDi and advances
the address. i.e. the bench models a COMBINATIONAL enable (decision-edge == consume-edge),
with the decision inputs sampled one clk32 before the consume edge.

THE PROPOSED RTL realizes a single gap-gated scheduler that owns enableCpu:
  fire (combinational, evaluated during slot Y) -> `enableCpu <= fire` (REGISTERED)
  -> enableCpu high during slot Y+1 -> CPU consumes at edge (Y+1)->(Y+2).
Candidate fire-eval slots = even CPU slots CPU2/4/6/8/A/C/E (producing enable-high at
the following odd slot CPU3/5/7/9/B/D/F). Mains at fire-eval CPU2/6/A/E; fast 2-apart
inserts at fire-eval CPU4/8/C.

THE QUESTION I want falsified — live vs registered decision inputs:
The brief's CORRECTED DESIGN pseudocode gates the fast 2-apart fire on
`rp_same_line_d1 AND rp_cache_hit_d1` (the REGISTERED versions, matching the bench).
But I argue that because the RTL `enableCpu <= fire` adds ONE register that the bench
does NOT have (the bench's decision-edge == consume-edge), the RTL must instead gate on
the LIVE `rp_same_line` and LIVE `rp_cache_hit` sampled at the even fire-eval slot — NOT
the _d1 versions.

My derivation for a fast fire (prev enable-high at CPU3, want enable-high at CPU5):
- prev consume at edge CPU3->CPU4; new addr (the fast access) appears during CPU4.
- "useful" same_line (the one that means 'fast access same line as prev-consumed') is
  same_line DURING CPU4: cpuAddr(CPU4)=fast access, prev_line=line(cpuAddr(CPU3))=prev
  access => same_line(CPU4) = exactly the safe condition. During CPU5 the address has
  been stable so same_line(CPU5)=1 trivially (the mode-0 bug).
- fire is evaluated during CPU4 to make enableCpu high during CPU5. So fire must read
  LIVE same_line(CPU4) and LIVE cache_hit(CPU4). Using rp_same_line_d1 at CPU4 would
  read same_line(CPU3) which is the trivially-1 useless sample => re-introduces staleness.
- Symmetric check on the DATA side: at the fast consume edge CPU5->CPU6, cpuDi(CPU5) =
  rp_cache_di_d1(CPU5) = cache_di(CPU4) registered = byteselect(line_word(CPU4)=prev
  line, offset(CPU4)=fast access offset). Correct byte IFF same-line. And the override
  condition rp_cache_hit_d1(CPU5)=rp_cache_hit(CPU4) which we gated on. So the DATA side
  correctly uses _d1 (registered, latched at consume) while the GATE side uses LIVE.

So my claim: GATE on LIVE rp_same_line + LIVE rp_cache_hit; the cpuDi override keeps the
existing _d1 registered data. This asymmetry (live gate, registered data) is the crux.

TASKS:
(A) Verify or refute facts 1-2 against the actual RTL (cite line numbers).
(B) Is my live-vs-_d1 conclusion correct, or does the registered `enableCpu <= fire`
    actually preserve the bench's _d1 timing (am I miscounting a register)? Give the
    exact slot-by-slot trace that settles it. THIS IS THE MAIN QUESTION.
(C) The gap counter: I plan `en_gap` incremented every clk32, reset to 0 at the
    enable-high slot; gate main on en_gap>=3 (new spacing>=4) and fast on en_gap>=1
    (new spacing>=2) at the even fire-eval slot. Any off-by-one that lets a 1-apart
    (consecutive-slot) enable through, or wedges by never reaching en_gap>=3?
(D) Transition fast<->slow: I intend the scheduler to own enableCpu only when
    (supercpu_en and scpu_fast_path and not scpu_force_1mhz and not dma_active); else
    fall back to `enableCpu <= cpu_cyc_s(1)`. cpu_cyc_s keeps shifting underneath. Can
    the mux double-fire (enableCpu high two clk32 in a row) at the boundary, and how do
    I prevent it without dropping the slow path's I/O timing? Concrete fix please.

Reply under 600 words, prioritized, with slot-level traces where it matters. If I'm
wrong on (B) say so bluntly and show the correct registration.
