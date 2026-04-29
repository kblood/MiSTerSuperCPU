# Session Passover 2026-04-11d: Doom loads and runs — first VIC output, crash in K:2D

## Headline

**doom.reu loaded correctly for the first time!** Via USB symlink trick to bypass SD card data bug. Doom init executes real code through K:20 → K:2D, changes VIC colors (screen turns purple), then crashes with PBR=$F8 and stack overflow.

## 1. USB Symlink Loading — UNRELIABLE

The SD card ioctl data bug (sends byte counter instead of file data) has blocked all previous doom.reu loading attempts. Solved with a filesystem symlink:

```bash
ln -sf /media/usb0/C64/doom.reu /media/fat/games/C64/doom_usb.reu
```

MGL references the symlink path (`games/C64/doom_usb.reu`), but the kernel follows the symlink to USB at read time, delivering correct file data through the ioctl pipeline:

```xml
<mistergamedescription>
<rbf>_Test/C64</rbf>
<file delay="5" type="f" index="2" path="games/C64/doom_usb.reu"/>
</mistergamedescription>
```

**Result**: Worked ONCE (first attempt), showed real 65816 instructions. Failed on ALL subsequent attempts — bank $20 contains zeros (BRK chain). The symlink trick is unreliable; MiSTer may not consistently follow symlinks during ioctl file reading.

**Reliable alternative**: Load doom.reu manually via OSD F12 → Load REU, navigating to USB drive path. This is the only confirmed method that consistently delivers correct file data from USB.

## 2. Doom Init Flow — Verified Working

UART captured the full init progression:

| Phase | Bank (K) | Duration | What Happens |
|-------|----------|----------|-------------|
| Init | K:20 | ~10s | SEI, CLD, CLC, XCE, disable CIAs, SuperCPU regs, math table build (banks $89-$8B) |
| Game Init | K:2D | ~15s | Data copying, VIC color setup (screen → purple), game state init |
| **CRASH** | K:F8→K:00 | — | CPU jumps to ROM bank $F8, stack overflow, runaway PEI loop |

### K:20 Init (confirmed working):
- Instructions: STA [$dp],Y ($97), JML ($5C), LDA dp ($A5), STZ ($64), LDY/LDX ($A0/$A2)
- DBR flips between $20 (code), $00 (DP), $89/$8A/$8B (math table target banks)
- T:01 = turbo, E:0 = native mode, S:$01FF = stack initialized correctly

### K:2D Game Init (confirmed working):
- Diverse instruction mix: ADC, CMP, BEQ, BCC, REP, SEP, STA dp, LDA dp, INC, DEC, AND, ORA
- T:FF = all speed flags active
- C:014F, N:0776 = healthy cache/enable counts
- B mostly $2D with $00 for DP accesses — correct

### Crash:
- UART: K:00, I:D4 (PEI), S cycling wildly through all 64KB, P:D5
- Overlay: K:F8 (ROM bank!), S:0001 (stack bottomed out), I:09 (ORA)
- Screen: solid purple/magenta (VIC regs were successfully written before crash)

## 3. Crash Analysis

The CPU ended up in bank $F8, which is ROM space ($F0-$FF). With bootmap disabled, these banks map to SuperRAM in SDRAM. Bank $F8 = doom.reu offset $F80000 = WAD data (not code). Executing WAD data as code leads to the observed crash.

**Possible causes for the K:F8 jump:**
1. **Indirect long addressing with wrong bank byte** — STA [$dp],Y or JML ($xxxx) reading a corrupted bank byte from DP
2. **Native mode interrupt vectoring** — if native IRQ vector at $00:FFEE points to an address in bank $F8 (from doom.reu data at offset $FFEE)
3. **Stack corruption** — a JSL pushed wrong PBR, RTL returns to wrong bank
4. **Bank $00 BRAM vs SDRAM conflict** — if doom.reu data at offset $FFEE-$FFEF overwrites the native IRQ vector area in SDRAM but BRAM still holds the ROM stub vector ($FF00)

**Most likely cause: native mode IRQ vector conflict.** Doom writes its IRQ handler address to $00:FFEE-$00:FFEF (native IRQ vector). But in our implementation:
- $00:FFE0-$00:FFFF is in BRAM (64KB covers $8000-$FFFF excl I/O)
- doom.reu data at REU_ADDR + $FFEE = $100FFEE in SDRAM contains doom.reu file data, not a vector
- If Doom wrote its vector to BRAM but the native IRQ handler reads from SDRAM (or vice versa), the wrong vector would be used

## 4. VIC Output Works!

The purple screen proves that native-mode writes to $D020/$D021 from turbo mode reach VIC-II correctly. This validates:
- I/O address handling (writes to $D000-$DFFF work)
- No io_slowdown needed (writes work at turbo speed)
- VIC register updates visible on screen

## 5. mtype.py \r Separator Syntax

The `keys` command in mister_debug.py supports `\r` as a separator for multi-line BASIC input:
```
python tools/mister_debug.py keys 'LINE1\rLINE2\rLINE3\r'
```
This correctly splits into separate text + enter sequences. Previous attempts with `'text' enter` syntax didn't work because the `enter` token was treated as text (not all tokens were key names).

## Files Modified This Session

- `crt/doom_usb.mgl` — NEW: MGL pointing to USB symlink path
- `docs/session_passover_2026_04_11d.md` — this file
- On MiSTer: `/media/fat/games/C64/doom_usb.reu` symlink → `/media/usb0/C64/doom.reu`

## 6. mister_debug.py `keys` Command — `enter` Not Interpreted

The `keys` command in mister_debug.py does NOT interpret `enter` as a key when mixed with text:
- `keys "'text' enter"` → ALL tokens must be key names for native mode; `'text'` isn't a key, so everything is treated as text
- `keys 'text\rtext\r'` → WORKS: `\r` is split into separate text + enter tokens
- Direct mtype.py on MiSTer: `python3 /tmp/mtype.py 'text' enter` → WORKS natively

The `\r` syntax is the correct way to send multi-line BASIC input via `keys`.

## 7. mtype.py Keyboard Exhaustion — CONFIRMED

After ~10+ `mtype.py` calls in a session, the uinput device system becomes exhausted. No keyboard input is processed. **Fix: reboot MiSTer** (`ssh root@192.168.50.130 reboot`).

## 8. Launcher Address Issue — $C000 vs $033C

Both $C000 and $033C launchers failed in later attempts (K:A7 instead of K:20). The first attempt at $C000 worked (K:20 with real Doom instructions). Investigation into BRAM read path showed BRAM pages require valid bits set by writes. Need to determine why the launcher works inconsistently.

**Open question**: The $C000 launcher worked in the first MGL load but not in subsequent reloads. Possible causes:
- BRAM page valid state differs between first boot and reloads
- doom.reu ioctl may overwrite C64 DRAM content via SDRAM at bank $00
- Keyboard exhaustion caused POKEs to not execute in later attempts

## Next Steps

### Priority 1: Debug the K:F8 crash (from first successful run)
1. Check what's at $00:FFEE-$00:FFEF in BRAM after Doom writes its vector
2. Add UART diagnostic: capture PBR changes (log when K transitions from $2D to anything else)
3. Check if IRQ is the trigger: run with SEI permanently set (patch doom.reu or add VHDL gate)
4. Compare vector area handling between BRAM and SDRAM paths

### Priority 2: Verify vector area architecture
- Commit 38821f9 "Make native mode vectors writable" — verify implementation
- Check: does the native mode vector read come from BRAM ($8000-$FFFF) or SDRAM?
- Doom may be writing vectors to bank $00 SRAM (which hits BRAM) — correct
- But doom.reu loading writes the same region to SDRAM — potential conflict
- After loading doom.reu, the ioctl writes $00:FFEE in SDRAM with file data
- If native vector read somehow hits SDRAM instead of BRAM, wrong vector!

### Priority 3: Run Doom without IRQs
- Patch the Doom entry: add SEI before JML $200000 (already there)
- Verify P register shows I=1 throughout K:2D execution
- If crash still happens with IRQs disabled → not an IRQ vector issue

## Build Info
- RBF: `C64_MiSTer/output_files/C64.rbf` (existing build from earlier 2026-04-11)
- doom.reu: 16,777,216 bytes, loaded via USB symlink
- Fitter: 73% ALMs, 95% RAM blocks
