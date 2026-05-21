# Async-Bridge MCP Handshake — Multi-Phase Implementation Plan

**Status:** planning artefact for Phase F (post-D4.2 cache wedge + Phase-E.1 64 MHz dead-end).
**Goal:** rewrite `C64_MiSTer/rtl/scpu_async_bridge.vhd` to use a proper MCP / word-synchronizer CDC handshake so `clk_cpu = clk64 (64 MHz)` and `clk_sys = clk32 (32 MHz)` can coexist cleanly, lifting the SuperCPU's effective dispatch rate.
**Authoritative coding rules:** `docs/hdl-coding-guidelines/{20,23,24,40,90,91}*.md`. The MCP pattern in §3.3 of doc 24 is the structural target; payload-stable-hold (AP "MCP without payload-stable hold", entry 60 in `90-anti-patterns.md`) is the load-bearing invariant.

## 0. Operating context

- Current wiring (verified): `c64.sv:328 wire clk_cpu = clk_sys;` (32 MHz); `fpga64_sid_iec.vhd:2670-2705` instantiates `scpu_async_bridge` with `BRIDGE_ACTIVE='0'` + `CACHE_ACTIVE='0'`, `bus_rdy_in => baLoc` (always `'1'`), `bus_di_in => cpuDi` (a *combinational* mux — `fpga64_sid_iec.vhd:1650`).
- The arbiter has no explicit "access complete" net. The CPU latches `cpuDi` on the cycle where `enableCpu_816 = '1'`. `enableCpu` is registered (`fpga64_sid_iec.vhd:2803 enableCpu <= cpu_cyc_s(1);`) and pulses inside `sysCycleDef` (32 clk32 cycles per master cycle). With `dma_active = '0'` and `supercpu_en = '1'`, `enableCpu_816 = enableCpu`. This pulse IS the "data is valid on cpuDi this cycle" signal — the cycle the bridge must capture the read response.
- Anti-patterns to avoid by name: AP-20.3 (no `valid` depending combinationally on `ready` — keep MCP toggles registered), entry 60 (MCP without payload-stable hold), entry 19 (bit-by-bit 2FF on multi-bit data). The existing 2-FF chain on `bus_di_in` (bridge lines 64-68, 123-132) is exactly the entry-19 anti-pattern *if* `bus_di_in` can change while the CPU is sampling it; today it gets away with it because `clk_cpu = clk_sys`. That collapses with the frequency split.
- D4.2 cache wedge hypothesis (`memory/project_bridge_cache_d4_2_wedge.md`): the `cpu_di` mux at bridge lines 217-219 selects across `cache_dout`, `cpu_di_latched`, and `bus_di_in` — three sources, two of which (`cpu_di_latched`, `bus_di_in`) lived in the *same* clock domain on hardware but had different settling timelines via 2-FF vs combinational paths. Once the MCP rewrite collapses this to one synchronized path (`cpu_di_latched` only, driven by an ack-toggle event), the cache can come back in phase F.5.

---

## Phase F.0 — Preparation: confirm the arbiter "access-complete" signal

**Goal:** prove that `enableCpu_816` (one clk32 cycle wide, fires once per CPU bus access in non-DMA SuperCPU mode) is the right "capture-this-cycle" event for the sink-side MCP. Without this, every later phase is built on sand.

**Files to inspect (read-only):**
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1442-1490` — `cpuHasBus` / `phi0_cpu` derivation; sets the slot the CPU occupies.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2740-2826` — `cpu_cyc` / `enableCpu` / `enableCpu_6510` / `enableCpu_816` generation. Specifically `:2802-2804`: `cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc; enableCpu <= cpu_cyc_s(1);` — so `enableCpu` is the *registered* output of the cycle gating, one clk32 cycle wide.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1650` — `cpuDi` combinational mux (verify single assignment; no clocked process re-drives it).
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2604` — `enableCpu_816 <= enableCpu and not dma_active and supercpu_en;` — combinational and-gate of the registered pulse. **This is the signal to wire as the sink-side capture-strobe.**

**Grep targets (already verified during planning):**
- `cpuDi\s*<=` in `fpga64_sid_iec.vhd` → single hit at line 1650, no clocked re-driver. **Confirmed combinational.**
- `enableCpu_816` driver → line 2604. **Confirmed single driver.**

**Open question for the user (decision point #1):**
On a CPU **write**, does `cpuDi` carry any useful payload? Per the arbiter, write data leaves the CPU via `cpuDo` → `cpuDo_pre` → `cpuDo` (`fpga64_sid_iec.vhd:2708, 2829`), and SDRAM/IO consume `cpuDo` directly. The bridge's sink-side does NOT need to capture `cpuDi` on writes — but the request-toggle still needs an ack so the CPU can advance. **Resolution:** on the sink side, the ack-toggle fires on the `enableCpu_816` cycle regardless of `we`; the captured `bus_di_reg` is meaningless on writes but the CPU ignores it (it's reading `cpu_di_out` only when `we=0` in real cycles). Document this in the bridge header.

**Risk register:**
- *Risk F.0.a — `enableCpu_816` doesn't actually fire once per CPU bus access.* The Phase-E.1 dead-end comment (`fpga64_sid_iec.vhd:2696-2701`) explicitly says it pulses 16x per 32-cycle sysCycleDef. **Resolution:** it pulses up to 16x, but each pulse corresponds to ONE possible CPU advance — the CPU's own `enable` port treats each pulse as a "you may advance one micro-step" gate. In SCPU mode with turbo on, the arbiter issues CPU pulses at one of the alt-slot cadences (CYCLE_CPU0/4/8/C) per the `turbo_m` mask. So the pulse rate is *the* CPU advance rate. What the bridge needs is "next pulse AFTER our request reaches clk_sys" — which is exactly what the request-toggle handshake gives us.
- *Risk F.0.b — IO accesses ($D0xx) stretch.* Per `fpga64_sid_iec.vhd:2580-2594`, IO is gated to CYCLE_CPUC only (`io_enable` plus `cs_io`). That's one slot per 32-cycle master cycle = ~1 MHz effective IO rate. The bridge's MCP handshake will see one ack pulse per IO access, even though many sysCycles pass between request and ack. The toggle-based protocol handles this: the request-toggle just sits there waiting; the ack-toggle fires when the IO slot opens.
- *Risk F.0.c — NMI / IRQ vector fetches.* These are normal reads at `$FFFE/$FFFF` (6510) or the SCPU's `$FFE6/E7` etc. From the bridge's POV they're indistinguishable from any other read.
- *Risk F.0.d — REU side-effects on $D0xx writes.* The arbiter executes the actual write on the clk_sys cycle of `enableCpu_816`, so the bridge just needs to deliver the write data stably. No bridge-side change needed.

**Exit criterion:** a short written note (2-3 paragraphs, append to this doc) recording the conclusion that `enableCpu_816` is the capture strobe, plus the answer to decision point #1.

**Rollback:** N/A (read-only).

---

## Phase F.1 — Bridge rewrite at clk_cpu = clk_sys (both 32 MHz)

**Goal:** replace the combinational passthrough + 2-cycle WAIT_ACK with a proper MCP handshake, while keeping both clocks at 32 MHz so the rewrite can be validated against the existing baseline before any frequency-split risk is added. The bench must still pass scenarios A-D (with updated expectations), and a hardware boot must still match `88963b9e` bit-for-bit.

**Files touched:**
- `C64_MiSTer/rtl/scpu_async_bridge.vhd` — full rewrite of the handshake portion (lines 58-202 today). Cache code (lines 83-117, 146-170) untouched but stays under `CACHE_ACTIVE='0'`.
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2702` — change `bus_rdy_in => baLoc` to a new port `bus_ack_in => enableCpu_816`. Requires a port-signature change on the bridge entity (see below).

**Removed signals (bridge):**
- `bus_rdy_sync1`, `bus_rdy_sync2` (`scpu_async_bridge.vhd:64-65`) — replaced by ack-toggle synchronizer.
- `bus_di_sync1`, `bus_di_sync2` (`:66-67`) — the data-in bus crosses unsynchronized as part of the MCP payload (per doc 24 §3.3 / entry 19 fix); no per-bit 2FF.
- `cpu_vpa_d`, `cpu_vda_d`, `access_pulse` (`:79-81, 134`) — replaced by an `accepting_new_request` term inside the FSM.
- `bridge_state`, `cpu_di_latched`, `cpu_rdy_latched`, `IDLE/WAIT_ACK` enum (`:72-75, 175-202`) — replaced by the new MCP FSM.

**New signals (bridge), VHDL conventions matching the existing style (lowercase_with_underscores, `_reg` suffix for FFs):**

Port changes:
```vhdl
-- removed:
--   bus_rdy_in   : in  std_logic;
-- added:
bus_di_in       : in  unsigned(7 downto 0);              -- unchanged port, but now crosses unsynchronized
bus_ack_pulse_in: in  std_logic;                          -- arbiter capture-strobe (enableCpu_816)
-- bus_addr_out etc unchanged
```

Source-domain (clk_cpu) signals:
- `cpu_req_toggle_reg : std_logic := '0';` — the request-toggle, flipped on each new CPU access.
- `cpu_request_reg` : a record / set of registers holding `{addr, addr_hi, do, we, vpa, vda}` latched at request time, held stable until ack.
- `ack_sync1_reg`, `ack_sync2_reg : std_logic := '0';` — 2-FF sync of `bus_ack_toggle_reg` (lives in clk_sys) into clk_cpu.
- `bus_di_capture_reg : unsigned(7 downto 0);` — captured payload, **clocked by clk_cpu on the destination-side ack edge** (i.e., on the clk_cpu cycle where `ack_sync2_reg /= cpu_req_toggle_reg` transitions to `=`). This is the payload-stable-hold property: `bus_di_capture_reg` only reloads after we observe ack.
- `cpu_rdy_reg : std_logic := '1';` — stall signal.

Sink-domain (clk_sys) signals:
- `req_sync1_reg`, `req_sync2_reg : std_logic := '0';` — 2-FF sync of `cpu_req_toggle_reg` into clk_sys.
- `req_sync3_reg : std_logic := '0';` — extra register for clean edge-detect (sync2 vs sync3 XOR gives a 1-cycle request-arrived pulse).
- `bus_request_pending_reg : std_logic := '0';` — set on req edge, cleared on `bus_ack_pulse_in`.
- `bus_ack_toggle_reg : std_logic := '0';` — flips on `bus_ack_pulse_in and bus_request_pending_reg`.
- `bus_payload_reg` : `{addr, addr_hi, do, we, vpa, vda}` registered output of the payload bus (driven combinationally from `cpu_request_reg` — payload crosses unsynchronized but is held stable for the full round-trip; on the clk_sys side we present a registered output to the arbiter so combinational logic glitches in the bridge don't propagate).
- `bus_di_reg : unsigned(7 downto 0);` — captured `bus_di_in` on `bus_ack_pulse_in`. Stays valid until the next req-edge.

**VHDL FSM skeleton (clk_cpu side):**

```vhdl
type cpu_fsm_t is (CPU_IDLE, CPU_REQUEST, CPU_WAIT_ACK);
signal cpu_fsm : cpu_fsm_t := CPU_IDLE;

process(clk_cpu) begin
    if rising_edge(clk_cpu) then
        if reset = '1' then
            cpu_fsm             <= CPU_IDLE;
            cpu_req_toggle_reg  <= '0';
            cpu_rdy_reg         <= '1';
            -- payload regs reset
        else
            -- 2FF ack sync
            ack_sync1_reg <= bus_ack_toggle_reg;
            ack_sync2_reg <= ack_sync1_reg;

            case cpu_fsm is
                when CPU_IDLE =>
                    cpu_rdy_reg <= '1';
                    if (cpu_vpa_in = '1' or cpu_vda_in = '1') then
                        -- latch payload BEFORE toggling req — payload-stable-hold rule
                        cpu_request_reg.addr    <= cpu_addr_in;
                        cpu_request_reg.addr_hi <= cpu_addr_hi_in;
                        cpu_request_reg.do      <= cpu_do_in;
                        cpu_request_reg.we      <= cpu_we_in;
                        cpu_request_reg.vpa     <= cpu_vpa_in;
                        cpu_request_reg.vda     <= cpu_vda_in;
                        cpu_req_toggle_reg      <= not cpu_req_toggle_reg;
                        cpu_rdy_reg             <= '0';   -- stall
                        cpu_fsm                 <= CPU_WAIT_ACK;
                    end if;
                when CPU_WAIT_ACK =>
                    if ack_sync2_reg = cpu_req_toggle_reg then
                        -- ack observed: capture and release
                        bus_di_capture_reg <= bus_di_in;  -- payload crosses unsynchronized; safe because held stable
                        cpu_rdy_reg        <= '1';
                        cpu_fsm            <= CPU_IDLE;
                    end if;
                when CPU_REQUEST =>
                    null;  -- reserved for future skid-buffer expansion
            end case;
        end if;
    end if;
end process;

cpu_di_out  <= bus_di_capture_reg;  -- always latched, never raw passthrough
cpu_rdy_out <= cpu_rdy_reg;
```

**VHDL FSM skeleton (clk_sys side):**

```vhdl
process(clk_sys) begin
    if rising_edge(clk_sys) then
        if reset = '1' then
            req_sync1_reg          <= '0';
            req_sync2_reg          <= '0';
            req_sync3_reg          <= '0';
            bus_ack_toggle_reg     <= '0';
            bus_request_pending_reg<= '0';
            bus_di_reg             <= (others => '0');
        else
            -- 2FF req sync (plus one extra stage for edge-detect)
            req_sync1_reg <= cpu_req_toggle_reg;
            req_sync2_reg <= req_sync1_reg;
            req_sync3_reg <= req_sync2_reg;

            -- New request arrived from clk_cpu?
            if req_sync2_reg /= req_sync3_reg then
                bus_request_pending_reg <= '1';
            end if;

            -- Arbiter says "this is the cycle"
            if bus_request_pending_reg = '1' and bus_ack_pulse_in = '1' then
                bus_di_reg              <= bus_di_in;
                bus_request_pending_reg <= '0';
                bus_ack_toggle_reg      <= not bus_ack_toggle_reg;
            end if;
        end if;
    end if;
end process;

-- Payload bus to arbiter: combinational from latched request regs.
-- Payload is stable from the cycle req_sync2 rises until the cycle the
-- CPU side observes ack — covers the entire round-trip.
bus_addr_out    <= cpu_request_reg.addr;
bus_addr_hi_out <= cpu_request_reg.addr_hi;
bus_do_out      <= cpu_request_reg.do;
bus_we_out      <= cpu_request_reg.we;
bus_vpa_out     <= cpu_request_reg.vpa and bus_request_pending_reg;
bus_vda_out     <= cpu_request_reg.vda and bus_request_pending_reg;
```

Note the `and bus_request_pending_reg` gating on `vpa/vda`: those drive the arbiter's view of "CPU is currently accessing the bus." Outside a pending request, they must be `'0'` or the arbiter sees a stale stuck access. This is the equivalent of "CPU has dropped its bus request" — a level-low signal in the clk_sys domain.

**Test method:**
- GHDL bench `sim/scpu_async_bridge_tb/bridge_tb.vhd` — needs new port `bus_ack_pulse_in` driven by a synthetic arbiter model. Scenario A (single-cycle ack), B (4-cycle delayed ack), C (fast-path bank $02 — depends on how F.1 handles `is_slow_access`; simplest: route all accesses through MCP, drop the fast-path mux entirely. Decision point #2.), D (cache write-through stays disabled).
- Hardware: build, boot KERNAL, confirm baseline behavior matches `88963b9e`. Doom should still run and produce identical timing.

**Decision point #2 (user input needed):** the existing bridge has an `is_slow_access` decoder (lines 59, 120) that only flagged bank `$00` accesses for the WAIT_ACK path. In F.1 do we keep that bifurcation (slow path through MCP, fast path through combinational passthrough), or route every access through MCP?
- *Argument for unified MCP:* fewer code paths, no second cpu_di mux source, easier to reason about, and at 32/32 MHz the round-trip is ~4-5 clk_cpu cycles — still much shorter than the arbiter's 32-cycle master period, so this doesn't slow the CPU.
- *Argument for keeping fast-path:* at 64 MHz CPU rate, every saved cycle helps for bank-$02 SuperRAM accesses. But this re-introduces the cross-module RDW mux anti-pattern (entry 24 in `90-anti-patterns.md`).
- *Recommended:* unified MCP for F.1; revisit a single-domain bank-$02 fast-path in a separate phase only if F.4 regression shows it's needed.

**Exit criterion:**
1. GHDL bench passes scenarios A-D with updated expectations (no `bus_rdy_in`; ack is now a single-cycle pulse).
2. Synthesis report: `cpu_req_toggle_reg → req_sync1_reg → req_sync2_reg` chain shows up in Quartus *Synchronizer Statistics* with MTBF reported (per doc 23 §8). Same for `bus_ack_toggle_reg → ack_sync1_reg → ack_sync2_reg`.
3. No combinational logic between `cpu_req_toggle_reg` and `req_sync1_reg` (synthesis warning check; the bridge architecture body must place the source-register and sink-register in different processes).
4. Hardware boot: KERNAL READY prompt + Doom intro reach identical pixel-state to baseline `88963b9e` at frame 600.

**Rollback strategy:** the F.1 commit is a single-file rewrite of `scpu_async_bridge.vhd` plus a one-line `fpga64_sid_iec.vhd:2702` change. `git revert` the commit; everything else is untouched. The `BRIDGE_ACTIVE`/`CACHE_ACTIVE` generics stay at `'0'`/`'0'` in production wiring throughout F.1, so even a botched MCP-on path is dead code in the netlist.

---

## Phase F.2 — Bench upgrade: two clock domains + stall scenarios

**Goal:** prove the F.1 handshake is robust under realistic arbiter stall patterns *before* deploying to hardware at 64 MHz.

**Files touched:**
- `sim/scpu_async_bridge_tb/bridge_tb.vhd` — full upgrade. Currently both clocks at 32 MHz from one driver (`bridge_tb.vhd:67, 99-100`). Change to:
  - `clk_sys` @ 32 MHz (`CLK_SYS_PERIOD : time := 31.25 ns`)
  - `clk_cpu` @ 64 MHz (`CLK_CPU_PERIOD : time := 15.625 ns`)
  - Drive each from its own concurrent assignment, no phase relation.

**New scenarios (append after current D):**
- *Scenario E — 1-cycle arbiter response:* `bus_ack_pulse_in` fires on the first clk_sys cycle after `req_sync2_reg` rises. Worst-case fast bus. Expected: CPU sees ack within ≈ 4-6 clk_cpu cycles.
- *Scenario F — 4-cycle stall:* arbiter holds `bus_ack_pulse_in='0'` for 4 clk_sys cycles, then pulses once. Models REU contention.
- *Scenario G — 16-cycle stall:* models a full sysCycleDef wait (IO access during a VIC raster cycle). Confirms the FSM doesn't time out or wedge.
- *Scenario H — back-to-back accesses:* CPU drives a new vda/vpa the cycle after `cpu_rdy_out` rises. Confirms `cpu_request_reg` and toggle update cleanly without dropping the second request.
- *Scenario I — write followed immediately by read of same address:* validates that the write payload reaches the arbiter and the read returns the right value. (At the bridge level there's no cache yet — the arbiter handles ordering.)

**Helper additions:**
- A bridge-internal `bus_di_drive` that the model arbiter sets to a known per-address value (e.g., low byte of address) so each scenario's expected `cpu_di_out` can be asserted post-hoc.
- Drop the `wait for 520 * CLK_PERIOD` cache-flush delay (F.1 keeps cache off; F.5 re-introduces).

**Test method:**
- `ghdl -a` / `ghdl -e` / `ghdl -r` from `sim/scpu_async_bridge_tb/` per existing project conventions.
- Per-clk_cpu trace already exists at `bridge_tb.vhd:132-139`; extend to also trace `bus_ack_toggle_reg` and `req_sync2_reg` so the handshake's round-trip is visible per scenario.

**Exit criterion:** all scenarios A-I close handshake within their expected cycle bounds; no X's on `cpu_di_out`; `cpu_rdy_out` is `'0'` exactly during in-flight transactions and `'1'` otherwise.

**Rollback:** revert `bridge_tb.vhd` to F.1 state.

**Decision point #3:** GHDL doesn't model metastability. The bench can prove *protocol* correctness but cannot prove the synchronizer chain depth is sufficient. F.3's Quartus Synchronizer Statistics report is the only authoritative source for MTBF.

---

## Phase F.3 — Deploy clk_cpu = clk64 to MiSTer

**Goal:** flip `c64.sv:328` to `wire clk_cpu = clk64;`, add SDC constraints for the new asynchronous clock pair, deploy, and verify a clean KERNAL boot.

**Files touched:**
- `C64_MiSTer/c64.sv:319-328` — replace the alias comment block with a one-line `wire clk_cpu = clk64;`. Update the comment to reference this plan and the F.1 success commit.
- `C64_MiSTer/C64.sdc` — append a new section:

```tcl
# F.3 — async-bridge MCP CDC declarations (clk_cpu=clk64, clk_sys=clk32)
# The MCP handshake registers on each side are tagged with a synchronizer
# attribute in scpu_async_bridge.vhd; the SDC tells TimeQuest not to time
# the inter-domain paths for setup/hold (per docs/.../23-cdc-single-bit.md §3.3
# and 24-cdc-multi-bit.md §5).
set_clock_groups -asynchronous \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}] \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
```

Note: the existing `set_multicycle_path -setup 2` constraints (`C64.sdc:13-37`) between counter[1] (clk64) and counter[2] (clk32) become *moot* for the bridge-handshake paths once `set_clock_groups -asynchronous` is in place, but they MUST remain for the legacy SDRAM dout_r → P65C816 path (lines 21-37) and the P65C816 → sdram address path (59-64). The `set_clock_groups` covers the bridge MCP toggle registers; the multicycle covers the SDRAM/CPU register paths that are NOT going through the new MCP. **Verify in TimeQuest's Inter-Clock Paths report that the bridge synchronizer endpoints show as false-pathed and the SDRAM paths show as multicycle 2.**

- Optional: add `set_false_path -to [get_registers {*scpu_async_bridge_inst|req_sync1_reg}]` and similar for `ack_sync1_reg` if `set_clock_groups` alone doesn't yield the right report annotations. (Per doc 23 §3.3, the group form is preferred but `set_false_path` is the fallback.)

**Quartus attributes inside `scpu_async_bridge.vhd` for the MCP synchronizer registers:**

```vhdl
attribute preserve : boolean;
attribute altera_attribute : string;

attribute preserve of req_sync1_reg : signal is true;
attribute preserve of req_sync2_reg : signal is true;
attribute preserve of ack_sync1_reg : signal is true;
attribute preserve of ack_sync2_reg : signal is true;
attribute altera_attribute of req_sync1_reg : signal is
    "-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
attribute altera_attribute of req_sync2_reg : signal is
    "-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
attribute altera_attribute of ack_sync1_reg : signal is
    "-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
attribute altera_attribute of ack_sync2_reg : signal is
    "-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
```

This is the VHDL equivalent of the Verilog `(* preserve *)` + `(* altera_attribute = ... *)` pattern in doc 23 §3.1. The `req_sync3_reg` does NOT get these attributes — it's an in-domain edge-detect register, not a synchronizer.

**Test method:**
1. Quartus full compile. Confirm **Synchronizer Statistics** report shows two recognized chains (req-into-clk_sys, ack-into-clk_cpu) with MTBF in years.
2. TimeQuest **Inter-Clock Paths** report: bridge-handshake paths show as false-pathed.
3. TimeQuest **Worst-Case Setup** at clk_cpu = 64 MHz: positive slack required. Failure here likely means the P65C816 internal critical path is too long at 64 MHz, which is a CPU-core problem not a bridge problem.
4. Deploy `.rbf`, boot. Expected: KERNAL READY prompt at the normal time.
5. Run quick smoke tests: cursor blinks, BASIC `PRINT 1+1` returns 2, `LOAD` from joystick port path works.

**Risk register:**
- *Risk F.3.a — P65C816 fails timing at 64 MHz.* The CPU core has never been targeted at 64 MHz on this fabric. If TimeQuest reports negative setup slack on critical CPU paths, the bridge plan stalls — pivot to either (a) accept lower clk_cpu (e.g., 48 MHz from `clk48`), or (b) pipeline the P65C816 critical paths in a separate sub-project. **Decision point #4 lives here.**
- *Risk F.3.b — SDRAM read latency stretches.* SDRAM is on clk64 already (the bridge doesn't change it). But the CPU's effective dispatch rate is now higher, so SDRAM contention increases. The arbiter's `sdram_busy_cnt` (`fpga64_sid_iec.vhd:2782`) should already handle this — but watch for instruction-fetch starvation patterns.
- *Risk F.3.c — IO accesses become disproportionately expensive.* At clk_cpu=64 MHz, an IO access still takes one full sysCycleDef on clk_sys = 32 clk32 = 64 clk_cpu cycles. The CPU is stalled for 64 cycles per IO access. This is *correct* (matches a real SCPU's IO stretch behavior, doc references VICE's `scpu64_clock_*_stretch_io`), but profiling code that hammers `$D012` (raster polling) will now show much higher stall ratios. Document this; don't try to "fix" it.

**Exit criterion:**
1. Synchronizer Statistics shows recognized chains with MTBF ≫ 1 year.
2. TimeQuest closes with positive slack on all clocks including clk_cpu=64 MHz (or a documented multi-cycle waiver covering the affected paths).
3. KERNAL boots clean.

**Rollback strategy:** revert `c64.sv:328` to `wire clk_cpu = clk_sys;` and remove the `set_clock_groups` line from `C64.sdc`. Bridge stays at F.1 form (single-domain MCP). Hardware build is identical to F.1 baseline.

---

## Phase F.4 — Performance validation (terse)

Regression suite at clk_cpu = 64 MHz:

| Test | Expected outcome | Compare to |
|---|---|---|
| Doom intro → first level → end of level 1 demo loop | No corruption, frame count matches at-or-better baseline | Pre-F.3 32 MHz Doom run |
| Wolf3D demo loop (single level) | No corruption | Baseline (if exists; if not, just "doesn't crash") |
| Lorenz CPU test suite | All instructions pass | Pre-F.3 run |
| `READY.` prompt time-from-reset | Within ± 10% of baseline | Stopwatch |
| Synthetic loop: `LDA #$00 / TAX / TAY / INX / BNE` tight loop, measure cycles | Effective MHz ≥ 60% of clk_cpu (handshake overhead bound) | Theoretical 64 MHz upper bound |

Document throughput gain in a 1-paragraph addendum to this doc.

---

## Phase F.5 — (Optional) Re-enable cache

**Hypothesis:** the D4.2 wedge was driven by the `cpu_di` mux at `scpu_async_bridge.vhd:217-219` selecting across three sources with different settling timelines on hardware (`cache_dout` combinational, `cpu_di_latched` 2-cycle, `bus_di_in` raw combinational). The MCP rewrite collapses to a single registered `bus_di_capture_reg` and the cache becomes a second registered source — only one of which is selected per cycle. The mux is now between two clean clk_cpu-domain registers, not across a CDC boundary.

**Test plan:**
1. Bench scenario D back to `CACHE_ACTIVE='1'`. Confirm ZP write-through + ZP read hits.
2. Hardware: flip `fpga64_sid_iec.vhd:2673 CACHE_ACTIVE => '1'`. Boot KERNAL. If the wedge returns, this plan is wrong and the cache needs deeper investigation (the ZP+stack reads themselves are the issue, not the mux). If KERNAL boots clean, run Doom + Wolf3D + Lorenz.
3. The 512-cycle MLAB flush walker (`scpu_async_bridge.vhd:101-114, 146-170`) remains — it's the only safe valid-bit init on Cyclone V MLAB. The `wait for 520 * CLK_PERIOD` reset delay returns to the bench.

**Decision point #5:** If F.5 fails again with the MCP in place, the next experiment is changing the cache from MLAB to direct flip-flop storage (512 bytes × 8 bits = 4096 flops + 512 valid flops = ~4600 flops, fits the Cyclone V easily). Stop chasing MLAB inference if it wedges twice.

---

## First-day starting tasks

When implementation begins:

1. **Run Phase F.0 confirmation.** Open `fpga64_sid_iec.vhd` in an editor; jump to line 2604 (`enableCpu_816` driver) and line 1650 (`cpuDi` mux); jump to lines 2782-2826 (the `enableCpu` generator process). In ~30 minutes, write a 3-paragraph appendix to this doc confirming (a) `enableCpu_816` is the right capture strobe, (b) `cpuDi` is purely combinational, (c) the answer to decision point #1 (write-data treatment).

2. **Sketch the new bridge entity port list on paper.** Compare to the existing entity at `scpu_async_bridge.vhd:18-56`. Decide whether to keep `bus_rdy_in` as a no-op port (lowers diff churn at the instantiation site) or to rename to `bus_ack_pulse_in`. Recommendation: rename and update both sites in one commit.

3. **Open the bench file** `sim/scpu_async_bridge_tb/bridge_tb.vhd` **and identify the model-arbiter region** (lines 175-200). This is the smallest piece of new code in F.2 and the fastest way to mentally validate the F.1 protocol before writing bridge RTL.

4. **Stage a no-op commit** that renames `bus_rdy_in` → `bus_ack_pulse_in` across both files and wires `enableCpu_816` into the new port. With `BRIDGE_ACTIVE='0'`, the bridge ignores the new port (output mux defaults to `bus_di_in`). Build this and confirm hardware still matches baseline `88963b9e`. This is the safest possible "no-functional-change" commit and locks in the wiring change before the FSM rewrite lands.

5. **Re-read** `docs/hdl-coding-guidelines/24-cdc-multi-bit.md` **§3.3 and §4.1 immediately before writing the new FSM.** The payload-stable-hold invariant and the 2-phase toggle sequencing diagram are the two things that, if violated, will let the rewrite pass the bench and wedge on hardware — exactly like the D4.2 cache did.

---

## Decision points summary

| # | Decision | Default if user doesn't weigh in |
|---|---|---|
| 1 | Write-data treatment on sink side | Bridge always toggles ack on `enableCpu_816`; `bus_di_reg` is dontcare on writes. Documented in bridge header. |
| 2 | Unified MCP vs slow/fast-path bifurcation | Unified MCP — drop `is_slow_access` decoder. Revisit only if F.4 shows a regression. |
| 3 | Synchronizer chain depth (2-FF or 3-FF) | 2-FF (matches doc 23 §3.1 default). Trust Quartus Synchronizer Statistics MTBF report. |
| 4 | clk_cpu target if 64 MHz fails timing | Drop to 48 MHz (clk48 already exists in PLL) before attempting CPU-core pipelining. |
| 5 | Cache storage if F.5 wedges again | Switch from MLAB to direct flip-flops (~4600 flops, easily fits). |

## Files for implementation

- `C64_MiSTer/rtl/scpu_async_bridge.vhd` — full rewrite (F.1)
- `sim/scpu_async_bridge_tb/bridge_tb.vhd` — full upgrade (F.2)
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2670-2705` — port rewiring (F.1, no-op commit)
- `C64_MiSTer/c64.sv:319-328` — clk_cpu source flip (F.3)
- `C64_MiSTer/C64.sdc` — async clock-group declarations (F.3)

---

# Appendix A — Phase F.0 confirmation (2026-05-21)

**Claim 1 — `enableCpu_816` is a single clk32-cycle pulse, fires once per CPU bus advance in non-DMA SuperCPU mode: PASS.**

Verified at `fpga64_sid_iec.vhd:2604`: `enableCpu_816 <= enableCpu and not dma_active and supercpu_en;`. `enableCpu` is the registered output of a 2-stage shift register (`fpga64_sid_iec.vhd:2800-2801`: `cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc; enableCpu <= cpu_cyc_s(1);`), so it's exactly one clk32 wide. `cpu_cyc` is the per-slot CPU cycle gate combinationally derived from sysCycleDef + turbo masks + sdram_busy_cnt. `dma_active` is the REU/cartridge DMA-in-progress latch (set at CYCLE_EXT1/5 from `dma_req`). Verdict accepted as the sink-side capture strobe.

**Claim 2 — `cpuDi` is a purely combinational mux, single concurrent assignment at line 1650: PASS.**

Grep for `cpuDi\s*<=` returns exactly one hit at line 1650. The assignment spans lines 1650–2087 as one big conditional-expression cascade selecting between SuperCPU register intercepts, native vector intercepts, $F8-$FF ROM stubs, SDRAM `ramDin` for non-$00 banks, and `cpuDi_raw` (buslogic) as fallback. No clocked re-driver. Safe to wire `bus_di_in => cpuDi` and capture combinationally on the sink ack cycle.

**Claim 3 — `bus_di_in` (= cpuDi) is valid on the clk32 edge where the CPU samples (one edge after enableCpu_816 rises): PASS, after careful re-analysis.**

The Explore agent's initial reading flagged this as FAIL, claiming SDRAM read data wouldn't be settled when `enableCpu_816` fires. That reading was mechanically wrong. Closer inspection of the arbiter's timing chain at `fpga64_sid_iec.vhd:2780-2801`:

- `cpu_cyc='1'` fires only when `sdram_busy_cnt='000'` AND it's a CPU slot (the busy counter blocks `cpu_cyc` from firing during an in-flight SDRAM cycle).
- The same edge that observes `cpu_cyc='1'` sets `sdram_busy_cnt<="011"` and shifts `cpu_cyc_s(0)<='1'`. SDRAM begins its 3-clk32 read pipeline at this edge.
- 2 clk32 cycles later, `enableCpu` rises (via the shift register). At this point `sdram_busy_cnt` has decremented to ~1 and the SDRAM data is arriving at `ramDin`.
- The CPU's standard CE-gated FF pattern samples `cpuDi` at the *next* clk32 rising edge after `enableCpu` is high. By then `sdram_busy_cnt='000'` and `cpuDi=ramData` is the correct read response.

My F.1 sink-side process captures `bus_di_in` on the same clk32 rising edge where `bus_ack_pulse_in='1'` was sampled (i.e., the edge AFTER enableCpu rose). This mirrors what the CPU itself does — same timing, same data. The existing passthrough (`cpuDi <= bus_di_in`) has been working for SDRAM reads for the whole fork's history, which would not be possible if the agent's reading were correct.

**Decision point #1 resolution — write-data treatment on sink-side ack:**
On a CPU write the bridge's sink-side captures `bus_di_in` into `bus_di_reg` regardless of `we`, then toggles ack. The capture is meaningless on writes (the arbiter consumes `bus_do_out`, not `bus_di_in`, for the write path) but the captured byte is dontcare because the CPU side ignores `cpu_di_out` when `we='1'`. This matches the default in the decision-point table; no FSM branching on `we` needed.

**F.0 → F.1 transition:** all three claims passed; the F.1 bridge as written captures at the correct moment; no FSM changes required from the original plan.
