# Session handoff — 2026-05-25 → NEW SHIP-READY BASELINE: passthrough + CIA gates + F/G probes

## 0. SESSION OUTCOME: passthrough mode + CIA gates is a strict superset of v8 — both LOAD"$" and LOAD"*" complete cleanly

Final test (2 reproducible runs) of build `8a7489ef`:
- `SAME_CLOCK_PASSTHROUGH => '1'` (MCP disabled)
- All earlier CIA gates kept (v13d CIA1, v13g CIA2 `cia2_write_safe`, Option F IMR/CRA probes, Option G PRA/PRB/DDR probes)
- **LOAD"$",8 → SEARCHING → LOADING → READY ✓**
- **LOAD"*",8,1 → SEARCHING → LOADING → READY ✓**
- CIA1 IRQ rate post-LOAD: 59.1/s (PAL nominal)
- CIA2 PRA cycles {$0F, $27, $47, $A7, $C7} during LOAD = full KERNAL IEC handshake

This **supersedes v8** as the practical baseline. Strict superset: gates are no-ops when vpa/vda are set (= every real CPU write), and protect against MCP phantom-writes when MCP is later re-enabled.

**Direct A/B comparison** between this build (`8a7489ef`, passthrough) and Option G (`10512bf2`, MCP active, IDENTICAL source otherwise) proves the LOAD"*" wedge is purely MCP-specific. Not caused by:
- CIA1 IMR/CRA phantom write (Option F ruled out; gate works)
- CIA2 IMR/CRA phantom write (Option F ruled out; gate works)
- CIA2 PRA/PRB/DDRA/DDRB phantom write (Option G ruled out; PA changes naturally only)
- 1541 emulator timing (passthrough drives same emulator; works)

**Remaining bug** is in MCP bridge's bus_di_capture timing OR vpa/vda hold extending cs_cia2 across phi2_n edges OR bus_addr_out propagation delay. Memories: [[passthrough-plus-gates-baseline-2026-05-25]], [[optionG-cia2-port-no-phantom-2026-05-25]], [[optionF-cia2-imrcra-no-phantom-2026-05-25]].

## 1. Recommended next steps (for future sessions, not this one)

1. **Ship `8a7489ef`** as the active build. Either: copy to `/media/fat/_Test/C64.rbf`, OR commit + archive the source state as "milestone-b CIA-gate-protected v8".
2. **For MCP revival** (Phase F.3 at clk_cpu=64MHz): build a GHDL bench (`sim/scpu_async_bridge_tb/`) that wires the bridge to mos6526 + a KERNAL IEC byte-receive trace. Reproduce the wedge in sim. Design fix in sim. Validate in sim. ONLY then build on FPGA.
3. **Do NOT iterate more MCP RTL builds** — three sessions of build-test loops failed to find the MCP wedge. Hardware probing has plateaued; bench needed.

## ORIGINAL HANDOFF (earlier in this session, kept for context) — Options F+G work

Two more instrumentation builds completed this session:
- **Option F** (md5 `507f1318`): added CIA2 IMR/CRA UART fields. **Result: CIA2 IMR=$00, CRA=$08 stable throughout wedge.** No CIA2 ctrl-reg phantom write.
- **Option G** (md5 `10512bf2`): added CIA2 PRA/PRB/DDRA/DDRB UART fields. **Result: PRA varies legitimately, DDRA=$3F stable, PRB/DDRB=$00 stable.** No CIA2 port/DDR phantom write.

**Major behavioral shift on Option G**: CIA1 IRQs now fire at 55-60/s during wedges (was 0/s on Option F). Wedge sites moved to $EEAD (KERNAL IECIN poll) or recover via timeout. System occasionally returns "DEVICE NOT PRESENT" or "SYNTAX ERROR" instead of infinite-looping at $EAxx. Either: (a) observer-effect from extra dbg ports changing routing/timing, (b) the "CIA1 IRQs stop" symptom was a marginal-timing manifestation of the IEC-drive wedge.

**The remaining failure is now in the 1541 emulator layer**, not in CIA register state. CIA1 fires normally, CPU is healthy, KERNAL is healthy — only the drive doesn't respond to LOAD commands.

Currently deployed: `C64.rbf` (Option G, md5 `10512bf2`) on `/media/fat/_Test/`. v13d's CIA1 cs-write-gate + v13g's CIA2 cia2_write_safe-gate remain active. Memories: [[optionG-cia2-port-no-phantom-2026-05-25]], [[optionF-cia2-imrcra-no-phantom-2026-05-25]].

## ORIGINAL HANDOFF — 2026-05-25 (earlier in session): MCP partial fix; cs-side gate width does NOT unlock LOAD"*",8,1

## 0. Mission brief for next agent

The MCP IEC wedge root cause is **confirmed for CIA1**: phantom writes to CIA1 between bridge requests, caused by `bus_addr_out` + `bus_we_out` being ungated in `scpu_async_bridge.vhd`. **v13d** fixes the CIA1 half with a write-only `cs_n` gate at the CIA1 instantiation — LOAD"$",8 (directory) now completes to READY.

**Five fix attempts have been mapped this session; all failed for LOAD"*",8,1:**
- **v13d** (CIA1 cs-gate `vpa OR vda`, CIA2 ungated): LOAD"$",8 works, LOAD"*",8,1 wedges (3+min PC bounce in $EAxx KERNAL SCNKEY)
- **v13e** (CIA1 + CIA2 same cs-gate): LOAD"$",8 wedges at PC=$018C (CPU crash — CIA2 IEC writes are edge-timing-critical, can't tolerate vpa/vda-based gate)
- **v13f** (bridge-level: all bus_*_out gated by request_pending): CPU wedges at PC=$FCD1 from boot (black screen — bridge's "always-valid bus" contract is load-bearing for some downstream consumer)
- **v13g** (CIA1 gate WIDENED to `vpa OR vda OR vpa_d1 OR vda_d1`, CIA2 ungated): same as v13d. LOAD"$",8 works; LOAD"*",8,1 wedges identically.

**The LOAD"*",8,1 wedge is NOT a phantom-write-window-width problem.** v13d's narrow `vpa OR vda` and v13g's wider `vpa OR vda OR vpa_d1 OR vda_d1` produce bit-identical user-visible behavior on LOAD"*". The CIA1 IMR clobber that v12b nailed is fully blocked. The LOAD"*" wedge has a SECOND distinct mechanism.

**Do NOT iterate more cs-side gate-width variants.** Five builds in this session; all five fail LOAD"*". Section 5 lists three productive paths forward; Section 6 has the recommended next probe.

v13d_mcp (md5 d8dc6d09) and v13g (md5 517f873e) both work equally well as a partial fix. v13d is on `/media/fat/_Test/C64.rbf` right now.

## 1. State of the tree

- **Active MiSTer build:** `C64_v13d_mcp_writeonlygate.rbf` md5 `d8dc6d09` on `/media/fat/_Test/C64.rbf`. LOAD"$",8 works; LOAD"*",8,1 wedges.
- **Source tree (uncommitted):**
  - `SAME_CLOCK_PASSTHROUGH => '0'` (MCP active) at `fpga64_sid_iec.vhd:2780`
  - CIA1: `cs_n => not (cs_cia1 and (not cpuWe or vpa_816 or vda_816))` — write-only gate, works
  - CIA2: `cs_n => not cs_cia2` — ungated (v13e write-only gate broke it)
  - Bridge `bus_addr_out`/`bus_we_out`/`bus_do_out`: all UNGATED (v13 attempt to gate `bus_we_out` broke RAM writes at boot)
  - UART pool: IM/CR/C1/DR/D9/IF probes intact, `LINE_LEN=283`
- **Preserved builds in `C64_MiSTer/builds/`:**
  - `C64_v13d_mcp_writeonlygate.rbf` md5 `d8dc6d09` — CIA1 write-only gate (CURRENT working baseline)
  - `C64_v13e_mcp_bothcia_writegate.rbf` md5 `3bed921d` — added CIA2 gate, wedges LOAD"$",8
  - `C64_v12b_pass.rbf` / `C64_v12b_mcp.rbf` — IM/CR probe baselines

## 2. Verified findings

### v13d (CIA1 write-only gate) — partial fix
- **Boot to READY:** clean
- **LOAD"$",8 (directory):** SEARCHING → LOADING → READY (full dir listing) [`tools/v13d_test/v13d_after_60s.png`]
- **IM ($DC0D mask):** stays $01 throughout LOAD (phantom write blocked)
- **IRQ rate idle:** 60/s (PAL nominal)
- **LOAD"*",8,1 (PRG):** wedges at `SEARCHING FOR *`, PC stuck $EAB3-$EAD8 (KERNAL SCNKEY) for 3+ min [`tools/v13d_test/v13d_load_star_3m.png`]. IF/DR/D9 all frozen — KERNAL SEI'd CIA1 IRQs (expected); real wedge is IEC byte-receive loop.

### v13e (CIA1 + CIA2 write-only gate) — regression
- **LOAD"$",8 wedges** at `SEARCHING FOR $` (failure mode `v13b` documented at line 2561-2563)
- **PC stuck at $018C** (stack page = CPU crash, not just IEC stall)
- **Diagnosis:** dropping CIA2 writes — even time-critical IEC edge writes — corrupts something fundamental enough to crash the CPU. Likely a missed $DD02 (PORT B DDR) or $DD0E (Timer A CR) write at KERNAL setup.

### Why the same gate works on CIA1 but not CIA2
- CIA1 writes during LOAD are mostly to `$DC0D` mask register — fire-and-forget value writes. Loose timing on the gate is fine; if write happens 1 cycle late, the mask is still correct.
- CIA2 writes during IEC are to `$DD00` setting ATN/CLK/DATA output bits in a tight handshake loop. **The IEC protocol depends on EDGES** of these bits. If a $DD00 write is dropped (gated off because vpa/vda just fell), the IEC line edge doesn't happen → byte transfer stalls. Worse: stale data on `cpu_req_do_reg` from a previous write gets re-applied, creating a *spurious edge* in the opposite direction.

## 3. Reproduce the v13d state in 3 minutes
```bash
cd C:/LLM/C64/MiSTerSuperCPU
# Re-deploy v13d
python -c "
import paramiko, time
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('192.168.50.130', username='root', password='1')
sftp = c.open_sftp(); sftp.put(r'C64_MiSTer/builds/C64_v13d_mcp_writeonlygate.rbf', '/media/fat/_Test/C64.rbf'); sftp.close()
c.exec_command('echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd')
"

# Then run the differential
python tools/v13d_load_star.py
# Expect: BASELINE OK (60/s IRQ), LOAD"*",8,1 wedges in $EAxx for 3min
```

## 4. The bridge asymmetry (root cause)

`scpu_async_bridge.vhd` outputs to the bus arbiter:

| Signal             | Gated?                                          | Line  |
| ------------------ | ----------------------------------------------- | ----- |
| `bus_addr_out`     | NO — always `cpu_req_addr_reg`                  | 467   |
| `bus_addr_hi_out`  | NO — always `cpu_req_addr_hi_reg`               | 468   |
| `bus_do_out`       | NO — always `cpu_req_do_reg`                    | 469   |
| `bus_we_out`       | NO — always `cpu_req_we_reg` (v13 tried, broke) | 475   |
| `bus_vpa_out`      | YES — `req_vpa_reg AND request_pending`         | 476   |
| `bus_vda_out`      | YES — `req_vda_reg AND request_pending`         | 477   |

Between requests, the bridge's three latched signals (addr, we, do) hold their previous-request values. The arbiter sees vpa=vda=0 (correctly) and *doesn't* enable CPU cycles — but `cs_cia1/cs_cia2` are still decoded combinationally from `cpuAddr` whenever `io_enable=1`, and `wr` inside CIA only requires `phi2_n AND NOT cs_n AND NOT rw`. If `rw='0'` (=`cpuWe='1'` stale) when the next phi2_n fires while cs_cia* is still high, the CIA accepts a phantom write.

**Confirmed by v12b:** in MCP LOAD, CIA1's `imr` is clobbered from $01 to $00. CIA1's `cra` is unaffected. The phantom-write hits $DC0D specifically — that's the address held in `cpu_req_addr_reg` from the last KERNAL write to $DC0D before the LOAD.

## 5. Proper fix design — what's been tried

### Option A/B (v13f, FAILED 2026-05-25)
Gating `bus_addr_out` (with `bus_addr_hi_out` + `bus_do_out` + `bus_we_out`) by `bus_request_pending_reg`, defaulting to $0000 / 0 between requests. **CPU wedged at PC=$FCD1 from boot. Black screen.** The bridge was designed with always-valid bus_*_out outputs; gating exposes a state where `cpu_cyc` fires (cs_ram=1 from gated addr=$0000) but request_pending=0. Some downstream consumer (arbiter's enableCpu logic, io_enable management, ramCE, or the bridge sink's bus_di_in capture timing) breaks. Memory: [[v13f-bridge-gate-wedge-2026-05-25]]. **Do not retry without SignalTap.**

### Option C (NOT YET TRIED)
Extend `bus_request_pending_reg` hold by 1 clk_sys past `bus_ack_pulse_in`. The hypothesis is that the bridge's `request_pending<='0'` on the same edge as enableCpu rising creates a setup-time race for the arbiter's write strobe. By holding pending '1' for one more cycle, all gated signals stay asserted through the arbiter's write completion. Single-line edit in `scpu_async_bridge.vhd:413-417`. Cheap to try, but **only if combined with Option A/B** — Option C alone changes nothing observable on v13d's ungated bus_*_out.

### Option D (TRIED 2026-05-25, FAILED on LOAD"*",8,1) — wider CIA1 gate
v13g widened the CIA1 gate to `(vpa_816 or vda_816 or vpa_816_d1 or vda_816_d1)` with 1-clk32 delayed regs. Same behavior as v13d. CIA2 was NOT gated (the v13e regression mode). Conclusion: gate-width is not the LOAD"*" blocker.

Variation NOT YET TRIED: apply the WIDER gate to CIA2 too (v13e's narrow `vpa OR vda` broke immediately, but maybe `vpa OR vda OR vpa_d1 OR vda_d1` keeps edge-critical IEC writes through). Costs 1 build (~30min). Lower priority than Option E now.

### Option E (NOT YET TRIED) — bench-first
Build a GHDL bench (`sim/scpu_async_bridge_tb/`) that wires the bridge to a minimal arbiter stub + CIA model. Reproduce v13f's PC=$FCD1 wedge in sim. Find which cycle the bug occurs. Design a fix. Re-test in sim. ONLY then build on FPGA.

### Option F (TRIED 2026-05-25 — partial signal) — CIA2 IMR/CRA snapshots
Built and tested (md5 `507f1318`). Wired CIA2 dbg_imr/dbg_cra through to UART (LINE_LEN 283→295, new I2/C2 fields). **Result: CIA2 IMR stays $00, CRA stays $08 from BOOT through LOAD"*" wedge — CIA2 control registers are NOT phantom-written.** One run captured PC=$00EEAD with IF=58.8/s during wedge: CIA1 healthy, CPU healthy, IRQs flowing, only IEC drive response never arrives. Memory: [[optionF-cia2-imrcra-no-phantom-2026-05-25]]. Falsifies the "same mechanism as CIA1, just on CIA2" hypothesis for ctrl regs.

Not measured by Option F (NEXT PROBE candidates):
- `cia2_prb_now` ($DD01 — IEC ATN/CLK/DATA write side)
- `cia2_pra_now` ($DD00 — IEC read side, what KERNAL sees)
- `cia2_ddra_now` / `cia2_ddrb_now` ($DD02/$DD03 — port direction; if these get phantom-cleared, outputs go hi-Z and IEC handshake breaks silently)

Branches to distinguish:
- Timer A fires but CPU IRQ doesn't run → CPU IRQ-input sync path (similar to v9-era hypothesis)
- Timer A stops firing → CRA got clobbered (v13d gate has hole for CIA1 CRA writes — only IMR/$DC0D was confirmed clobbered in v12b)
- CIA2 PRB unexpectedly driven → CIA2 phantom write to IEC port
- CIA2 PRA shows IEC handshake stuck → real IEC protocol failure (drive talking? clock stuck?)

This is the cheapest path to disambiguate the LOAD"*" wedge from the (now-fixed) CIA1 IMR clobber.

### Option G (NEXT PROBE — natural successor to Option F) — CIA2 port/DDR snapshots

Option F ruled out CIA2 ctrl regs. Option G should add port-side instrumentation:
1. **mos6526.v** add 4 new output ports: `dbg_pra` (8 bits = $DD00 read), `dbg_prb` (8 bits = $DD01 read), `dbg_ddra`, `dbg_ddrb`. Each is `assign dbg_xxx = xxx_internal_reg`.
2. **fpga64_sid_iec.vhd** add signals + wire CIA2 instance + entity output ports (mirror Option F pattern at lines 980-ish, 2629-ish, 297-ish, 4258-ish — all already exist for IMR/CRA).
3. **c64.sv** + **debug_pkg.svh** + **debug_uart_pool_fmt.sv** — extend the pool struct and format. Rename my fields from `I2:/C2:` to `M2:/T2:` (or pick non-colliding letters) to avoid the legacy-C2 collision found this session.

Format: `M2:## T2:## PA:## PB:## DA:## DB:##` = ~30 bytes. Extend LINE_LEN to ~325.

Expected diagnostic:
- PA/PB change during LOAD-* idle (no CPU CIA write) → CIA2 PRA/PRB phantom-written → mechanism found
- DA/DB drop bits during LOAD-* (e.g., $FF → $7F) → DDR phantom-cleared → outputs go hi-Z → IEC silent
- All four steady but IEC still wedges → wedge is in 1541 module side or in MCP read-path corruption

### Option E (still NOT TRIED) — bench-first
Build a GHDL bench (`sim/scpu_async_bridge_tb/`) that wires the bridge to a minimal arbiter stub + CIA model. Reproduce the wedge in sim. Find which cycle the bug occurs. Design a fix. Re-test in sim. ONLY then build on FPGA.

**Recommended order:** G first (continues the productive instrumentation track). If G shows steady PA/PB/DA/DB, escalate to E (GHDL bench) since the bug is no longer in CIA-visible state.

## 6. Cycle-level timing — investigate BEFORE building

Before another build, read these files and write down the cycle-level sequence:

1. **`scpu_async_bridge.vhd:400-420`** — `sys_side` process. Shows `bus_request_pending_reg <= '0'` happens on the SAME clk_sys edge as `bus_ack_pulse_in = '1'` is sampled. Combinational `bus_*_out` signals drop on that edge.

2. **`fpga64_sid_iec.vhd:2667`** — `enableCpu_816 = enableCpu AND NOT dma_active AND supercpu_en`. This is the arbiter's CPU slot pulse, wired to `bus_ack_pulse_in`.

3. **`fpga64_sid_iec.vhd` near `enableCpu`** — find where `enableCpu` is generated (look for `CYCLE_CPUE` or arbiter state machine). Identify WHICH clk_sys cycle within the slot the arbiter latches `bus_we_out` for the write. This determines whether request_pending falling on `enableCpu_816` rising is too early.

4. **CIA `phi2_n` sample edge** — `mos6526.v:90` has `wr = phi2_n AND NOT cs_n AND NOT rw`. `phi2_n` is `enableCia_n` driven from `CYCLE_CPUC` (line 1506 of `fpga64_sid_iec.vhd`). Trace whether phi2_n's "1"-cycle and enableCpu_816 align or stagger.

5. **GHDL bench `sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd`** — has the bridge FSM in isolation. Add a CIA write phantom-write reproducer: schedule a write request, ack it, then check that no further `cs` assertions happen between the ack and the next request. If the bench reproduces the issue, iterate fixes in the bench BEFORE rebuilding the FPGA.

## 7. If next agent must ship something today

Revert to v8 passthrough — `SAME_CLOCK_PASSTHROUGH => '1'` at line 2780. This is the known-good IEC state. Lorenz, Doom, Wolf3D all work. Performance cap stays at ~3MHz (no MCP value at clk_cpu=clk_sys anyway). MCP code is dormant but preserved.

## 8. Cross-refs (memory)

- `v13d-mcp-iec-load-fix-2026-05-25` — current state (partial fix)
- `v12b-mcp-phantom-write-confirmed-2026-05-24` — IMR clobber smoking gun
- `v12-mcp-cia1-irq-stops-2026-05-24` — disambiguation of CIA1 vs downstream
- `v11-mcp-wedge-quantified-2026-05-24` — quantified wedge
- `mcp-cycle-trace-2026-05-24` — paper-walk identifying ungated bus_addr_out
- `v8-passthrough-iec-fix-2026-05-24` — shipping-grade workaround
- `project-phaseF-mcp-handshake-plan` — F.3 (clk_cpu=64MHz) blocked until MCP fully fixed
- `v13g-wider-gate-no-help-2026-05-25` — wider CIA1 gate did NOT unlock LOAD"*",8,1; phantom-write window is not the blocker for that path
