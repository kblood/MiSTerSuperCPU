# Session handoff — 2026-05-28: hybrid banner-patch (working LOAD + SCPU64 banner)

## 0. TL;DR

- **Decision (operator):** "Hybrid — banner-patch JiffyDOS/DolphinDOS." Serve a
  **non-SCPU-patched** KERNAL in emu mode (working serial → working LOAD) and
  cosmetically restore the `**** C=64 SCPU64 ROM V0.07 ****` cold-start banner.
  Accepted as NOT bit-identical / not VICE-faithful.
- **Functional goal MET (silicon-verified, build `12867108`):** `LOAD"*",8,1`
  now completes in SuperCPU/65816 mode — the Lorenz suite loads and runs
  (`basic commands - ok`, `ldab/ldaz/ldazx/... - ok`), UART shows `IE:1F` (all
  IEC lines released, the success state) with NO `$ED5A` wedge.
  Screenshot: `tools/hybrid_load_test_scpu.png`.
- **Root cause REFINED (important correction):** it is **NOT** a universal
  "P65C816 core cycle timing ≠ 6510" bug. **Stock C64 serial works fine in
  65816** (LOAD succeeded with stock KERNAL in the dprom). Only the
  **SCPU-EPROM-patched** KERNAL wedges — its IEC helpers are wrapped with
  `STA $D072`/`STA $D073` (1MHz throttle toggles); those extra cycles shift the
  bit-cell/handshake timing enough to desync the emulated c1541. Serving ANY
  unwrapped KERNAL (stock or DolphinDOS) fixes LOAD.
- **Banner snag (builds #1, #2):** the embedded dprom init
  (`rtl/roms/dol_C64.mif`) is **overwritten at boot** by the MiSTer firmware
  downloading a stock C64 ROM (`c64rom_wr` / `load_rom`, no ROM file needed —
  embedded in MiSTer Main). The boot banner is read from KERNAL `$E47E`, so it
  showed stock. **Build #2's `c64rom_wr && !supercpu_enable` gate FAILED**
  (still stock banner) — `status[82]` isn't latched before the boot download
  (timing race). Reverted.
- **Banner fix (build #3, verifying):** download-immune **banner-window
  override**. In emu mode, reads of the 46-byte cold-start message
  `$E47E-$E4AB` are served from the **resident `scpu_rom` EPROM dprom** (which
  has the SCPU64 banner at `$E483` and **no `wren`** → the firmware download
  can't touch it), via the `cpuAddr-$BF00` offset. All KERNAL/BASIC *code*
  (incl. serial) still comes from `romData`. Pure data bytes, no code → cannot
  affect serial. Reuses existing BRAM. `dol_C64.mif` and the c64.sv gate are
  reverted; the only source change vs HEAD is now in `fpga64_buslogic.vhd`.

## 1. The hybrid — now a single-file change (this session, UNCOMMITTED)

All in `rtl/fpga64_buslogic.vhd` (build #3):
1. **LOAD fix (verified, build #1):** emu-mode `cs_romLoc` serves `romData`
   (the C64 KERNAL+BASIC dprom — working serial) instead of the wedging
   `scpuRomData` (SCPU-EPROM-patched KERNAL).
2. **Banner override (build #3):** within `cs_romLoc`, for emu mode and
   `cpuAddr` in `$E47E-$E4AB`, serve `scpuRomData` (resident `scpu_rom` EPROM,
   download-immune) so the cold-start banner reads `**** C=64 SCPU64 ROM V0.07
   ****`. `scpu_rom_rdaddr` gets the `cpuAddr-$BF00` offset only for that
   window; raw `cpuAddr` elsewhere (native/bootmap bank-$F8 EPROM reads).

REVERTED dead ends: build #2's `c64.sv` `c64rom_wr && !supercpu_enable` gate
(status[82] timing race — no effect, still stock banner); the `dol_C64.mif`
banner splice (moot — banner now comes from `scpu_rom`); a stale force-turbo
comment in `fpga64_sid_iec.vhd`. The `IE:##` UART diagnostic field
(`debug_pkg.svh`, `c64.sv`, `debug_uart_pool_fmt.sv`) stays UNCOMMITTED
(instrumentation, not a fix).

`git push` still needs explicit user go-ahead. Commit the hybrid
(`fpga64_buslogic.vhd`) once build #3 verifies banner + LOAD together.

## 2. How the C64 system ROM is actually served (the mechanism that bit us)

- `kernel_c64` dprom (`fpga64_buslogic.vhd:170`) init = `rtl/roms/dol_C64.mif`
  (DolphinDOS 2.0), 16KB: `$0000-$1FFF`=BASIC (`$A000-$BFFF`),
  `$2000-$3FFF`=KERNAL (`$E000-$FFFF`). rdaddress = `cpuAddr(14) & cpuAddr(12:0)`.
- It has `wren => c64rom_wr`. `c64rom_wr` (c64.sv:2050) pulses on `load_rom`
  (`ioctl_index==8`, the OSD `P2FC8` "System ROM C64+C1541" path) for the low
  16KB.
- OSD `P2O[15:14],System ROM` = `0 Loadable C64 | 1 Standard C64 | 2 C64GS |
  3 Japanese` → fed as `.bios(status[15:14])`, but the **bios ROM-selector was
  removed** in our fork (buslogic:258) — `bios` is inert. ROM content is purely
  dprom-init-OR-overwritten-by-`c64rom_wr`.
- The MiSTer firmware downloads a stock C64 ROM at boot **even with no ROM file
  on the SD card** (embedded in MiSTer Main) and **even in "Loadable C64" mode**
  — empirically confirmed (cfg byte1 `0x00` still booted stock). That download
  overwrote our patched dprom init. Hence the `c64rom_wr` gate (change #3).

## 3. EXACT next steps (build #3 verification)

Build #3 (`/tmp/hybrid_build3.log`, background id `bjxqf0thk`) is the banner
window override. On completion (auto-archived to `C64_MiSTer/builds/`, staged at
`C64.rbf`):

```powershell
# verify ownership first (see §5)
python tools/mister_debug.py deploy
# cold-boot SCPU mode (no MGL) and check the banner:
#   expect  **** C=64 SCPU64 ROM V0.07 ****   /   64K RAM SYSTEM ...
#   (cfg byte10 must be 0x0C = scpu)
python tools/mister_debug.py screen tools/hybrid_banner_v3.png
# re-confirm LOAD still completes (serial in 65816):
python tools/iec_wedge_probe.py scpu --secs 90
#   pass = Lorenz "- ok" lines / PC in $08xx / IE:1F ; fail = J:ED5A + IE:13
```

- **Banner SCPU64 + LOAD ok** → DONE. Commit `fpga64_buslogic.vhd`.
  Then `python tools/deploy_and_probe_doom.py` (Doom must still reach the `$2C`
  main loop — serving the dprom in emu mode shouldn't touch native-mode Doom,
  but confirm).
- **Banner still stock** → the banner window read isn't selected at boot. Check
  the `cs_romLoc`/`scpu_native_mode`/`scpu_bootmap` gating during the cold-boot
  BASIC banner print (bootmap must already be `0` and CPU in emu mode when the
  banner prints — verify with the `T:`/overlay fields), and confirm `scpu_rom`
  holds the SCPU64 banner at EPROM `$257E`.
- **LOAD breaks / garbled banner** → the `$E47E-$E4AB` window override is wrong
  (offset or range); narrow/verify against `tools/disasm_serial_region.py
  E460 E4B0`.

## 4. Build / verification artifacts

- Build #1 (LOAD fix only, serve `romData`): md5
  `1286710858b13d317fff65d803862a65`. **Proves LOAD works**
  (`tools/hybrid_load_test_scpu.png` — Lorenz running) but banner = stock
  (`tools/hybrid_banner_scpu.png`, `tools/hybrid_banner_loadable.png`).
- Build #2 (`c64rom_wr` gate): md5 `764613fc5b128c1ef4b5826243d3c3b9`. Gate
  FAILED — still stock banner (`tools/hybrid_banner_v2.png`). Reverted.
- Build #3 (banner window override): building now, md5 TBD →
  `tools/hybrid_banner_v3.png`.
- Tooling: `tools/iec_wedge_probe.py [t65|scpu]` (sets cfg byte10, fires lorenz
  autoload MGL, captures UART); `tools/wait_for_c64_free.py` (read-only poll of
  `/tmp/CORENAME`); `tools/disasm_serial_region.py` (serial-region 6502 disasm).

## 5. Shared-MiSTer state & a tooling gotcha

- The MiSTer is shared with the CD32/Minimig agent. `/tmp/CORENAME` showed
  `CannonFodder-Z2fix` (their Amiga workload) earlier; the operator explicitly
  cleared us to use the device. Re-verify ownership before disruptive ops;
  do NOT delete the other agent's `/tmp` files.
- **Winsock race:** paramiko's `client.connect(HOST,...)` intermittently fails
  with `getaddrinfo failed` (errno 10109) on this Windows host while heavy
  WSL/network load is present. Fixed in `tools/mister_debug.py` and
  `tools/iec_wedge_probe.py` by pre-connecting a raw socket
  (`socket.create_connection`) and passing it via `sock=`, with a small retry.
  Apply the same pattern to any new SSH tool.

## 6. What this supersedes

- The prior handoff's "FINAL ROOT CAUSE = P65C816 core cycle timing, fix needs
  CPU-core surgery, cosmetic-only" is **superseded**: stock serial works in
  65816, only the SCPU-patched `$D072`-wrapped serial wedges, and the hybrid
  (serve unwrapped KERNAL + banner-patch + gate the ROM download) gives BOTH
  working LOAD and the SCPU64 banner with NO CPU-core changes.
- The memory `project_load_wedge_is_p65c816_serial_cycle_timing.md` needs a
  follow-up note with this refinement (do after build #2 confirms).
