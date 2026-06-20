# U64 SuperCPU Porting Plan (template — fill in after repo inventory)

## Pre-conditions to revisit before starting

- [ ] v343 MiSTer test result is known. If wolf3d works on v343, MiSTer
      may be the better immediate target and this plan deprioritizes.
- [ ] U64 host core is confirmed buildable from source (not just
      readable). Need: clone → unmodified build → flash → run vanilla
      KERNAL on real U64 hardware at 192.168.50.94.
- [ ] U64 turbo mode is confirmed to apply to instruction throughput,
      not just specific I/O paths. Need: micro-benchmark on real U64.
- [ ] License compatibility between our 65C816 work (T65 derivative +
      SNES-core adaptation) and U64 core has been verified.

## Phase 0 — Toolchain & baseline

1. Identify U64 build toolchain (Quartus / Vivado / Yosys + nextpnr / ?).
2. Set up build environment (may differ from MiSTer's WSL + Quartus 17.0).
3. Clone canonical U64 repo at known-good tag/commit.
4. Build stock bitstream WITHOUT modifications.
5. Deploy to physical U64 at `192.168.50.94`.
6. Run vanilla C64 KERNAL boot + Lorenz test suite (use U64 REST API
   for screenshots — `docs/ultimate64_agent.md`).
7. Capture pass/fail baseline for reference.

**Exit criteria:** stock U64 bitstream rebuilds clean and matches
production behavior. We can deploy and screenshot via REST.

## Phase 1 — 65C816 CPU integration point

1. Find the CPU instantiation in the U64 host core (likely a single
   wrapper instantiating a 6510 / T65 equivalent).
2. Document its bus interface signals (addr, data in/out, RW, clock
   enable, IRQ, NMI, RDY, etc.).
3. Map the existing P65C816 from `C64_MiSTer/rtl/65C816/` onto that
   interface — likely needs adapter shim, not deep changes.
4. First swap: wire P65C816 in emulation-mode-only, retain 1 MHz CPU
   clock. Verify KERNAL boots, Lorenz emulation tests pass.

**Exit criteria:** U64 bitstream with 65C816 emulation-mode CPU runs
vanilla C64 software identically to stock 6510.

## Phase 2 — SCPU register decode + ROM

1. Port `scpu_native_mode`, `scpu_speed_1mhz`, `scpu_optim_mode`,
   `scpu_hwenable`, `scpu_regs_enabled` from `fpga64_sid_iec.vhd`.
2. Map `$D07x`, `$D0Bx` SCPU registers onto U64 bus.
3. Instantiate `scpu64.mif` dprom in U64 core (or load via U64's existing
   ROM-mount mechanism).
4. Implement bootmap intercept at `$00:$E000-$FFFF`.
5. Implement writable native vectors `$00:$FFE4-$FFEF`.
6. Implement `$FF00` IRQ stub recipe from v342 (NOPs at $FF1A-$FF1D).

**Exit criteria:** xa65-assembled SCPU test program writes / reads
`$D07A` / `$D07B` correctly, XCE+CLC enters native mode, RTI returns.

## Phase 3 — SuperRAM + bus extensions

1. Identify the U64's SDRAM (or DDR) controller and access pattern.
2. Add bank-aware addressing: bank `$00` = motherboard RAM, banks
   `$02-$FF` = SuperRAM in SDRAM/DDR.
3. Port the cpuDi mux + the bank-aware I/O decode (b2d44d1 fix).
4. Implement 65C816 long-address opcodes' actual SDRAM access.

**Exit criteria:** STA long `$2B:1234` writes a byte that LDA long
reads back, on hardware.

## Phase 4 — Turbo speed exploration

This is **the entire reason we're considering the pivot**. Once SCPU runs
at 1 MHz on U64, this phase asks: can we run it at SCPU-native 20 MHz?

1. Investigate U64's existing turbo path. Does it gate the CPU on VIC
   slots? Or does it run truly free with a separate CPU clock domain?
2. If truly free: wire the 65C816's clock-enable to a faster signal.
3. Verify VIC-II raster timing remains accurate (most demos depend on
   exact raster slots).
4. Implement write-buffer/cache infrastructure if needed for I/O writes
   to maintain 1 MHz CIA / VIC visibility.
5. Benchmark Doom frame rate at increasing turbo levels.

**Exit criteria:** Doom playable at ≥ 8 MHz effective CPU clock on
real U64 hardware.

## Phase 5 — Wolf3D + kickstart

1. Re-enable bootmap=1 at reset (same as v343 retry).
2. Verify kickstart copies ROM to banks `$F0-$FE` RAM cleanly.
3. Run wolf3d_v342_long.py equivalent on U64.

**Exit criteria:** Wolf3D renders front-end menu identical to VICE.

## Phase 6 — Regression sweep + ship

1. Run full Lorenz CPU test suite on U64.
2. Re-run Doom test on U64.
3. Re-run wolf3d test on U64.
4. Document final results, compare to MiSTer.
5. Decide: U64 becomes primary target, MiSTer becomes secondary.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| U64 host core not fully open | Medium | Project blocked | Verify Phase 0 BEFORE committing |
| U64 turbo doesn't help instruction throughput | Medium | Pivot offers nothing new | Verify Phase 0 micro-benchmark |
| Toolchain mismatch (Vivado/different IDE) | Low | Time cost | Budget 2-3 days Phase 0 |
| FPGA different from Cyclone V | Low | Resource budget unknown | Verify Phase 0 build success |
| U64 community already has SuperCPU fork | Low | Wasted work | Search before Phase 1 |
| License incompatibility | Low | Can't redistribute | Resolve before Phase 1 |

## Time estimate (rough)

- Phase 0: 2-3 days
- Phase 1: 3-5 days
- Phase 2: 2-3 days
- Phase 3: 3-5 days
- Phase 4: 1-2 weeks (this is the speculative phase)
- Phase 5: 2-3 days
- Phase 6: 2-3 days

**Total: ~4-6 weeks** if everything goes smoothly. Comparable to or shorter
than implementing 20 MHz CPU clock decoupling on MiSTer's existing arbiter.
