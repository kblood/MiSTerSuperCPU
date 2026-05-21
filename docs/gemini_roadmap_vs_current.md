# Gemini Roadmap vs Current SuperCPU Implementation

Side-by-side comparison of the Gemini 3.5 Flash research roadmap
(`docs/Gemini35FlashResearch.md` + the trailing Phase 3-4 text shared by
the user) against the actual state of this fork (branch `vanilla-cpu-swap`).
The goal is to extract *actionable items* — specifically anything that
might help unblock Phase 6b (RDY-handshake) and inform the next steps.

## Summary table

| Phase | Gemini recommendation | Our state | Verdict |
|---|---|---|---|
| 1 | srg320 SNES 65C816 core | P65C816 (Pasca's TG-16/SNES core, different lineage) | Different core, equivalent goal |
| 1 | Separate `clk_cpu` PLL @ 20/40 MHz | Single clk_sys (32 MHz), enableCpu gates the CPU | Different architecture — clock-gated, not multi-domain |
| 2 | RDY pin tied to wait-state generator | enableCpu pulse from arbiter (clock gating) | Same intent, different mechanism |
| 2 | Address decode fast/slow → RDY high/low | cs_ram / cs_io / scpu_long_access mux | Equivalent — already present |
| 2 | **Double-buffered CDC for completion signal** | `sdram_data_valid_sync` is single-FF | **Actionable — see below** |
| 3 | $D074-$D0BC register map, $D0BC bit7=0 detect | $D0B0=$40 works, $D0BC reads scpu_dos_ext_mode (default $00 → bit7=0) | Mostly done; partial functional gaps |
| 3 | OSD speed-switch → $D0B5 bit6, $D07A/$D07B real switch | OSD turbo IS used; $D07A/$D07B write the latch but NOT wired to clock gating | Partial — see below |
| 3 | **M10K BRAM cache $0000-$01FF write-through** | vanilla-cpu-swap routes all bank-$00 RAM to SDRAM | **Interesting — see below** |
| 4 | $D0BC bit7 read = 0 check | Should work (default $00) but memory file claims $FF — re-test | Re-verify |
| 4 | $D07A/$D07B speed switch test | Not wired to clock; OSD-only today | Spec gap |
| 4 | Vision BASIC compile speed | Not tested | Open |
| 4 | Doom + Metal Dust | Doom + Wolf3D PLAYABLE on v356; Metal Dust untested | Mostly green |

## Items relevant to the current Phase 6b problem

### 1. Double-FF sync on completion signal (Gemini Phase 2)

Gemini explicitly says: *"Set up double-buffered synchronization registers
to pass address, data, and write-enable states securely across the
boundary between clk_cpu and clk_sys."*

Our current Phase 6a/6b uses **single-FF** sync for `sdram_data_valid`:

```vhdl
sdram_data_valid_sync <= sdram_data_valid;   -- 1-FF
```

Justification (per CLAUDE.md / inline comments): the level signal stays
high for several clk64 cycles between the q==STATE_READ edge and the next
ce-edge, so single-flop is metastability-safe.

This is mostly true for *steady-state* operation, but Gemini's
recommendation is the conservative default and matches what we already
do for `sdram_ready_sync` (2-FF). If iso7 still has subtle timing
issues, upgrading `sdram_data_valid_sync` to 2-FF is a cheap fix to
try — it just adds 1 clk32 of latency that the defer-latch absorbs.

**Action:** if iso7 wedges in a metastability-shaped way (intermittent,
varies between cold/warm boot), upgrade to 2-FF first before
re-architecting.

### 2. The address-decode → RDY mapping (Gemini Phase 2)

Gemini: *"If the access falls within slow C64 ranges (such as I/O space
at $D000-$DFFF), pull RDY low and assert the synchronization flag."*

Our `iso7` does the inverse: I/O accesses are explicitly *not* deferred
(`cs_ram_at_cyc_s(1)='0'` → fire immediately). This is correct for our
mechanism because I/O bus is in-domain (no CDC needed), whereas Gemini
treats the entire C64 I/O bus as a separate slower domain.

Conclusion: not a port; our model already handles this differently and
correctly.

### 3. ZP+stack BRAM cache (Gemini Phase 3)

This is the most interesting *new* idea from Gemini. Real CMD SuperCPU
has 128 KB SRAM mirroring banks $00-$01 entirely. Gemini's plan reduces
that to a lighter "cache only $0000-$01FF write-through" design.

Why $0000-$01FF specifically:
- 6502/65C816 zero-page addressing modes ($00-$FF) are 30-40% of
  executed instructions in tight loops.
- Stack page ($0100-$01FF) hit on every JSR/RTS/PHA/PLA/IRQ/BRK.
- Single M10K block = 1024 bytes (we'd need 512 = 256 ZP + 256 stack).

Our `vanilla-cpu-swap` branch removed the BRAM cache entirely in favour
of pure-SDRAM bank-$00, which is the *opposite* direction.

If Phase 6c (Build C page-mode SDRAM) does not recover enough Doom
speed, the Gemini ZP+stack cache is a strong fallback that could give
30-40% throughput uplift on ZP/stack-heavy code paths.

**Caveat:** write-through means every CPU store still triggers an SDRAM
write cycle, so it does NOT reduce SDRAM write pressure — only read
latency for ZP+stack. With the current bus-arbiter cadence (CPUC every
1 µs, alt-slots blocked), the bottleneck is *slots-per-µs*, not SDRAM
read latency. So this would mostly help once Phase 6d alt-slot revival
is back.

**Action:** keep in back pocket as a Phase 6e or post-Phase-6 option.
Document but don't implement until 6c+6d settle.

### 4. Register map gaps that Gemini calls out

- **$D0BC bit 7 = 0 detection** — memory file says we return $FF but
  the read mux (line 1653-1654) reads `scpu_dos_ext_mode` which inits
  to $00. There may be a discrepancy: the memory file is dated
  2026-05-18 and may predate a fix. Worth running a quick PRG probe to
  confirm what $D0BC actually reads on the current build.
- **$D07A/$D07B speed switch** — writes update `scpu_speed_1mhz` but
  this signal is not consumed anywhere that gates the CPU clock. The
  symptom matches: tools/scpu_speedtest reports 1.0x ratio regardless
  of writes, and the memory file confirms $D0B8 returns $FF.
- **$D072/$D073 sys_1MHz** — same status (stubbed latch, no consumer).

These gaps don't block Doom/Wolf3D (those programs use the OSD turbo
or compile-time speed assumptions), but they would block Vision BASIC
and other SuperCPU-aware tools that use the software speed-switch
register.

## What we won't take from the Gemini plan

- **srg320 SNES core import** — we've already integrated P65C816 and it
  passes Lorenz / Doom / Wolf3D. Switching cores is a 6-month tax.
- **Separate clk_cpu PLL @ 20/40 MHz** — our clock-gated approach is
  the MiSTer C64 framework convention and doesn't need a new PLL. A
  separate PLL would also push us over the FPGA timing budget that the
  recent perf-experiments branch only barely closed (TNS=0 with
  multicycle constraints).
- **Phase-1 OSD CPU multiplex** — SuperCPU is hardcoded ON in this
  fork (per CLAUDE.md). Vanilla 6510 mode lives on `master`. Different
  product strategy from Gemini's "boot-time selectable" model.

## How this maps to the current Phase 6b iso7 work

iso7's `cpu_enable_pending` latch IS the wait-state generator from
Gemini Phase 2 — just expressed as "delay the enable pulse" rather than
"pull RDY low". If iso7 boots KERNAL the architecture is validated
end-to-end. If it doesn't, the most likely fixes from this comparison
are:

1. Upgrade `sdram_data_valid_sync` to 2-FF (Gemini's conservative
   default).
2. Re-check that the in-reset cpu_cyc shifts into `cs_ram_at_cyc_s`
   don't latch a phantom pending state when reset drops mid-shift.
3. If both fail, fall back to the ZP+stack cache idea so ZP/stack reads
   bypass the handshake entirely.

### iso7 test result (2026-05-21 ~08:00)

iso7 BUILT clean (003cc343, 13:31 elapsed) but WEDGED on cold boot with
the same symptom as iso2-v3 from earlier in the session:

- PC stuck at $00:$0005
- P=$B5 (emulation mode, N+I+C set)
- SP cycles chaotically across stack page ($0103 → $019F → $013B → ...)
- F counter advances normally so CPU IS getting enableCpu pulses
- The reset vector fetch at $FFFC/$FFFD is returning $05/$00 instead of
  $E2/$FC (the KERNAL reset entry)

Crucially this is **identical** to iso2-v3's wedge despite iso7 having
NO cpu_cyc gate. The common factor between iso2-v3 and iso7 is that
both add a `sdram_data_valid_sync` consumer to the enableCpu
computation — the gate vs no-gate distinction doesn't matter.

**Conclusion:** the bug is not in the cpu_cyc gate. It's in the
*semantics* of consuming dv_sync. The level signal arrives at the right
edge in steady state, but the very first SDRAM cycle after both fpga64
and sdram_pm reset drops returns wrong data, and the handshake-based
fire latches it instead of the correct subsequent cycle.

This shifts the priorities:

- **Gemini's 2-FF sync upgrade is the most direct next thing to try**
  (jumped to first-class).
- Try iso8 (literal Phase-6a baseline reconstruction) to prove the
  build pipeline is producing functionally-equivalent bitstreams to
  the known-good 88963b9e.
- If iso8 boots clean, the bug is purely in the dv_sync consumer
  semantics — try the 2-FF upgrade next, or model the consumer after
  Gemini's "hold RDY low until completion" rather than "fire later
  when valid". Subtle but different.

### Bigger architectural alternative: ZP+stack BRAM cache (Gemini Phase 3)

If multiple iterations of the dv_sync consumer keep wedging, the
Gemini ZP+stack cache becomes attractive: by bypassing the SDRAM
handshake entirely for the $0000-$01FF range, we eliminate the
class of bug we keep hitting. Most reset-path code (KERNAL reset
sequence at $FCE2 reads ZP heavily) would never touch the slow path
at all. This is a bigger change but moves the problem to a regime
where Phase 6a baseline timing already works.

## Open follow-ups (post-Phase-6b)

- Quick PRG probe to re-verify $D0BC bit 7 read value on current HW.
- Wire $D07A/$D07B writes into the actual CPU enable mux (today's
  `scpu_speed_1mhz` is a dead-end latch).
- Decide if real-CMD-style 128 KB SRAM (banks $00-$01 mirror) is
  worth the M10K cost vs the lighter Gemini ZP+stack cache.
- Vision BASIC import as a Phase 4 regression test once $D07A/$D07B
  are functional.
