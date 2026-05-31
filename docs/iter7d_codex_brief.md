# iter-7d fix design — falsify this

## Context
MiSTer C64 + 65C816 SuperCPU. A read-only BRAM cache (`cpu_cache.vhd`) is wired
to feed the CPU behind a default-false VHDL constant `CACHE_READ_PATH` in
`fpga64_sid_iec.vhd`. All in the **clk32 domain** (no clk64 here).

### The cache (cpu_cache.vhd), relevant timing facts
- `cache_hit` is **combinational** on the current `cpu_addr` (tag_mem MLAB async
  read + per-byte valid). Asserts the SAME cycle the address is presented.
- `line_word` (the 64-bit line) is **registered**: `line_word <= data_bankN(line_index)`
  on `rising_edge(clk)`. So `line_word` reflects the line_index that was present
  during the PREVIOUS cycle.
- `cache_di` is combinational from `line_word` + current `byte_offset`.
- Net: on a **cross-line hit**, at edge N (cpu_addr just became new line L):
  `cache_hit=1` (correct), but `line_word` still holds the prev line ⇒ `cache_di`
  is STALE for one cycle. At edge N+1, `line_word`←L, `cache_di` valid.

### Current consumer (fpga64_sid_iec.vhd), CACHE_READ_PATH=true
- `cpuDi <= rp_cache_di when (CACHE_READ_PATH and rp_cache_hit='1') else <normal bus mux>`.
  Uses the **combinational** rp_cache_hit/rp_cache_di directly.
- `sdram_hit_pred <= rp_cache_hit when CACHE_READ_PATH else '0';` (a hit loads
  arbiter `sdram_busy_cnt<="001"` short grant vs "011" miss floor).
- Cadence: `cpu_cyc` fires at main slots CYCLE_CPU0/4/8/C (every 4 clk32).
  `cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc; enableCpu <= cpu_cyc_s(1);`
  `enableCpu_816 <= enableCpu and not dma_active and supercpu_en;`
  So enableCpu_816 pulses ~4 clk32 apart. The CPU (p65c816, enable=enableCpu_816)
  latches `di` and advances ONLY on that pulse. alt_fire is hard-'0' (so strictly
  4-apart for now).

### Empirical HW facts
- `e0e83e5c` (fill cache on EVERY read): boots CLEAN, corrupts only on serial LOAD.
- `0228d2b6` (= e0e83e5c + fill-on-MISS-only, sole RTL delta `rp_fill_we and (not rp_cache_hit)`):
  corrupts at BOOT (garbled screen, no SCPU64 banner).
- GHDL (c64_reduced_harness, real fpga64+real p65c816, CACHE_READ_PATH=true,
  fill-on-miss-only) boots CLEAN to final_pc=$00:FD83 — i.e. GHDL canNOT reproduce
  the HW boot corruption.
- iter-6 scripted STA on the fitted netlist, path `*read_path_cache* -> *P65C816:cpu|*`:
  as-built `-setup 2` (62.5ns) = +31.07ns 0/8 viol; forced `-setup 1` (31.25ns)
  = -0.651ns 8/8 VIOLATED. Worst path tag_mem -> ... -> P65C816|AddrGen|PCr[7]
  (~10ns cache-internal + ~2.7ns cpuDi mux + ~11ns inside P65C816 di->ALU->PC).
  A `set_multicycle_path -setup 2 -to {*P65C816:cpu|*}` exists in C64.sdc.

## My read of the bug
The corruption boots clean in GHDL but fails on silicon ⇒ it's a **masked
single-cycle timing violation**, not functional. The setup-2 multicycle relaxes
the `cache_di->cpuDi->P65C816` path to 62.5ns; the real combinational path is
~31.9ns, which FAILS a true single-cycle (31.25ns) budget by 0.65ns. On HW the
CPU latches a not-fully-settled value on cross-line hits → boot corrupts.

## Proposed fix (iter-7d) — falsify it
Insert a **pipeline register** on the cache override so the long combinational
path is split, sampling the cache output the cycle AFTER `line_word` settles:

```vhdl
process(clk32) begin
  if rising_edge(clk32) then
    rp_cache_hit_d1 <= rp_cache_hit;   -- valid 1 clk32 after addr present
    rp_cache_di_d1  <= rp_cache_di;    -- samples the SETTLED line_word value
  end if;
end process;

cpuDi <= rp_cache_di_d1 when (CACHE_READ_PATH and rp_cache_hit_d1 = '1') else ...;
sdram_hit_pred <= rp_cache_hit_d1 when CACHE_READ_PATH else '0';
```

Reasoning:
- At edge N cpu_addr→L, rp_cache_hit=1 but rp_cache_di stale. At edge N+1
  line_word settles, rp_cache_di correct. The register samples at edge N+2 the
  value present during cycle N+1 (correct), so rp_cache_di_d1 is CORRECT and
  co-phased with rp_cache_hit_d1.
- cpu_addr is stable for 4 clk32 (CPU advances only on enableCpu), so the 1-clk
  added latency is absorbed; CPU latches at edge N+4, well after N+2.
- STA: the failing path now launches from rp_cache_di_d1 (register) → cpuDi mux
  (~2.7ns) → P65C816 di->ALU->PCr (~11ns) ≈ 14ns, closes single-cycle. The
  cache-internal ~10ns (line_word->cache_di) is now a separate path into the
  register, also closing. So the forced setup-1 probe should go POSITIVE.

## Questions for you (be adversarial)
1. Does registering rp_cache_di actually capture the CORRECT (settled) byte, or
   am I off-by-one on the cross-line phase? Walk the edges.
2. Does using the REGISTERED hit for `sdram_hit_pred` (arbiter short-grant /
   busy_cnt) introduce a hazard vs the current combinational use, given cpu_cyc
   fires at the main slot and the grant decision samples sdram_hit_pred then?
3. `rp_fill_we` currently uses combinational rp_cache_hit (fill on miss only) at
   the enableCpu_816 edge. Should fill stay on combinational hit, or move to
   registered? Any coherency hazard if override is registered but fill is not?
4. Is there any scenario where rp_cache_hit_d1=1 but the current cpu_addr has
   ALREADY moved to a different access (so the registered di belongs to a stale
   address) that would feed wrong data to cpuDi? Consider the cycle right after
   enableCpu_816 when the CPU presents a new address.
5. Anything that would make the forced setup-1 STA probe still FAIL after this
   change (e.g. the cache-internal launch path tag_mem->line_word being the real
   >31ns offender, not the cpuDi consumer)?
