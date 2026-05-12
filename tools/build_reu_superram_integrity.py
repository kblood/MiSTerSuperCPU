#!/usr/bin/env python3
"""Build reu_superram_integrity.prg — verify REU→SuperRAM byte-level data path.

Doom's loader copies REU → bank $00 RAM → SuperRAM via REU FETCH + CPU
long-store. The music_num=-9 bug is documented as HW-only / REU→SuperRAM
data-path related — cocotb+VICE oracles have proven CPU microcode is
correct on multiple Doom paths. This test exercises the exact path
Doom's loader uses, with a known signature so any byte corruption is
immediately visible.

Test plan:
  1. Write known ramp $00..$FF to bank $00:$C000-$C0FF (256 bytes).
  2. REU STASH (cmd $90): copy $C000-$C0FF → REU offset $00:010000
     (1 MB into REU, well away from Doom load region).
  3. REU FETCH (cmd $91): copy REU $00:010000 → $C100-$C1FF.
     If STASH+FETCH roundtrip fails, screen $0400 shows mismatch count.
  4. Long-store: copy $C100-$C1FF byte-by-byte → SuperRAM $20:$0000-$00FF
     (`STA $200000,X` long-indexed).
  5. Long-LDA: read back from $20:$0000-$00FF
     (`LDA $200000,X` long-indexed) and store to $C200-$C2FF.
  6. Compare $C200-$C2FF to original ramp; count mismatches in X reg.

Result (screen):
  $0400 = STASH+FETCH mismatch count (should be $00)
  $0401 = SuperRAM roundtrip mismatch count (should be $00)
  $0402 = $77 tripwire (proves test completed)
  $0403 = first mismatched byte's expected value (if any)
  $0404 = first mismatched byte's actual value (if any)
  $0405 = $AA tail tripwire

PEEK targets (via UART or screen):
  $0400-$0405: result summary above.
"""
import os, struct, sys

def main():
    code = bytearray()

    # ---- BASIC stub at $0801: "0 SYS 2061" ---------------------------------
    stub = bytes([
        0x0B, 0x08,            # next-line ptr
        0x00, 0x00,            # line number 0
        0x9E,                  # SYS token
        0x32, 0x30, 0x36, 0x31, # "2061"
        0x00,                  # EOL
        0x00, 0x00,            # EOP
    ])
    code += stub

    def addr_of(offs):
        return 0x0801 + offs

    def emit(*bs):
        code.extend(bs)

    main_entry = addr_of(len(code))
    assert main_entry == 0x080D, f'main_entry={main_entry:#06x} != $080D'

    # ---- main: switch to native mode, set up environment -------------------
    emit(0x78)                            # SEI
    emit(0x18)                            # CLC
    emit(0xFB)                            # XCE → native
    # XCE pipeline drops 1st instr and scrambles 2nd on hardware
    # (see project_xce_drops_next_instruction.md). Absorb with two NOPs.
    emit(0xEA)                            # NOP (drop slot)
    emit(0xEA)                            # NOP (scramble slot)
    emit(0xC2, 0x10)                      # REP #$10 (X=16-bit)
    emit(0xE2, 0x20)                      # SEP #$20 (M=8-bit)

    # ---- Step 1: write ramp $00..$FF to $C000-$C0FF -----------------------
    emit(0xA2, 0x00, 0x00)                # LDX #$0000
    step1_loop = addr_of(len(code))
    emit(0x8A)                            # TXA (A = X low byte = ramp value)
    emit(0x9D, 0x00, 0xC0)                # STA $C000,X (X is 16-bit, A is 8-bit)
    emit(0xE8)                            # INX
    emit(0xE0, 0x00, 0x01)                # CPX #$0100
    # BNE step1_loop
    branch_pc = addr_of(len(code) + 2)
    rel = step1_loop - branch_pc
    assert -128 <= rel <= 127
    emit(0xD0, rel & 0xFF)

    # ---- Step 2: REU STASH C64 $C000-$C0FF → REU $00:010000 ---------------
    # REU registers ($DF01..$DF08, $DF00 is status). Write order:
    #   $DF02/$DF03 = C64 addr = $C000
    #   $DF04/$DF05/$DF06 = REU addr = $010000 (LE)
    #   $DF07/$DF08 = length = $0100
    #   $DF01 = command $90 (STASH immediate, execute, no FF00 trigger)
    # (Note: cmd $90 = bit7 execute + bit4 immediate + type 1 STASH)
    # Actually verify against reu.v: bit7=execute, bit5=autoload,
    # bit4=ff00-trigger-off, bits1:0 = type (0=stash, 1=fetch).
    # $90 = 1001_0000 = execute + ff00-off + type 0 → STASH ✓
    # $91 = 1001_0001 = execute + ff00-off + type 1 → FETCH ✓
    emit(0xA9, 0x00); emit(0x8D, 0x02, 0xDF)  # STA $DF02 (C64 lo)
    emit(0xA9, 0xC0); emit(0x8D, 0x03, 0xDF)  # STA $DF03 (C64 hi)
    emit(0xA9, 0x00); emit(0x8D, 0x04, 0xDF)  # STA $DF04 (REU lo)
    emit(0xA9, 0x00); emit(0x8D, 0x05, 0xDF)  # STA $DF05 (REU mid)
    emit(0xA9, 0x01); emit(0x8D, 0x06, 0xDF)  # STA $DF06 (REU bank)
    emit(0xA9, 0x00); emit(0x8D, 0x07, 0xDF)  # STA $DF07 (len lo)
    emit(0xA9, 0x01); emit(0x8D, 0x08, 0xDF)  # STA $DF08 (len hi) → $0100
    emit(0xA9, 0x90); emit(0x8D, 0x01, 0xDF)  # STA $DF01 cmd=$90 STASH

    # ---- Step 3: REU FETCH REU $00:010000 → C64 $C100-$C1FF ---------------
    # Need to re-write length (reu auto-reloads to $FFFF after completion).
    emit(0xA9, 0x00); emit(0x8D, 0x02, 0xDF)  # STA $DF02 (C64 lo)
    emit(0xA9, 0xC1); emit(0x8D, 0x03, 0xDF)  # STA $DF03 (C64 hi = $C100)
    emit(0xA9, 0x00); emit(0x8D, 0x04, 0xDF)  # STA $DF04 (REU lo)
    emit(0xA9, 0x00); emit(0x8D, 0x05, 0xDF)  # STA $DF05 (REU mid)
    emit(0xA9, 0x01); emit(0x8D, 0x06, 0xDF)  # STA $DF06 (REU bank)
    emit(0xA9, 0x00); emit(0x8D, 0x07, 0xDF)  # STA $DF07 (len lo)
    emit(0xA9, 0x01); emit(0x8D, 0x08, 0xDF)  # STA $DF08 (len hi)
    emit(0xA9, 0x91); emit(0x8D, 0x01, 0xDF)  # STA $DF01 cmd=$91 FETCH

    # ---- Step 4: count STASH+FETCH mismatches between $C000 and $C100 ----
    emit(0xA2, 0x00, 0x00)                # LDX #$0000
    emit(0xA0, 0x00, 0x00)                # LDY #$0000 (mismatch counter, 16-bit)
    step4_loop = addr_of(len(code))
    emit(0xBD, 0x00, 0xC0)                # LDA $C000,X  (expected ramp)
    emit(0xDD, 0x00, 0xC1)                # CMP $C100,X  (FETCH result)
    # BEQ skip4
    skip4_branch_pos = len(code)
    emit(0xF0, 0x03)                      # BEQ +3 (skip INY)
    emit(0xC8)                            # INY
    emit(0xEA); emit(0xEA)                # filler so BEQ +3 lands correctly
    # back-patch ↑ would be confusing; instead reorder:
    # Replace above block with explicit calculations
    # (Just leave as-is, BEQ +3 is fine: skip INY+EA+EA = 3 bytes)
    # Actually INY is 1 byte. So BEQ should be +1 not +3.
    # Patch: replace +3 with +1, drop EA EAs.
    code[skip4_branch_pos + 1] = 0x01     # BEQ +1
    # Remove the two EA fillers we wrote
    del code[len(code) - 2:]
    emit(0xE8)                            # INX
    emit(0xE0, 0x00, 0x01)                # CPX #$0100
    branch_pc = addr_of(len(code) + 2)
    rel = step4_loop - branch_pc
    assert -128 <= rel <= 127, f'step4 rel={rel}'
    emit(0xD0, rel & 0xFF)                # BNE step4_loop

    # Store Y low byte to $0400 (STASH+FETCH mismatch count)
    emit(0xE2, 0x10)                      # SEP #$10 (X=8-bit) so STY works as 8-bit
    # Hmm, easier: transfer Y low to A and store.
    # Actually with X=16-bit, STY is 16-bit. Just keep X=16, use STY abs which stores both bytes.
    # Simpler: TYA (8-bit because M=1), STA $0400
    emit(0x98)                            # TYA (A=Y low)
    emit(0x8D, 0x00, 0x04)                # STA $0400

    # ---- Step 5: long-store $C100-$C1FF → SuperRAM $20:$0000-$00FF -------
    emit(0xC2, 0x10)                      # REP #$10 (X=16-bit again)
    emit(0xA2, 0x00, 0x00)                # LDX #$0000
    step5_loop = addr_of(len(code))
    emit(0xBD, 0x00, 0xC1)                # LDA $C100,X
    emit(0x9F, 0x00, 0x00, 0x20)          # STA $200000,X (long-indexed)
    emit(0xE8)                            # INX
    emit(0xE0, 0x00, 0x01)                # CPX #$0100
    branch_pc = addr_of(len(code) + 2)
    rel = step5_loop - branch_pc
    assert -128 <= rel <= 127, f'step5 rel={rel}'
    emit(0xD0, rel & 0xFF)

    # ---- Step 6: long-LDA from $20:$0000-$00FF → $C200-$C2FF -------------
    emit(0xA2, 0x00, 0x00)                # LDX #$0000
    step6_loop = addr_of(len(code))
    emit(0xBF, 0x00, 0x00, 0x20)          # LDA $200000,X (long-indexed)
    emit(0x9D, 0x00, 0xC2)                # STA $C200,X
    emit(0xE8)                            # INX
    emit(0xE0, 0x00, 0x01)                # CPX #$0100
    branch_pc = addr_of(len(code) + 2)
    rel = step6_loop - branch_pc
    assert -128 <= rel <= 127, f'step6 rel={rel}'
    emit(0xD0, rel & 0xFF)

    # ---- Step 7: count SuperRAM mismatches; capture first mismatch -------
    emit(0xA2, 0x00, 0x00)                # LDX #$0000
    emit(0xA0, 0x00, 0x00)                # LDY #$0000 (counter)
    # Tripwire: clear $C300 (will hold first mismatch expected),
    # $C301 (first mismatch actual). Default = $FF $FF if no mismatch.
    emit(0xA9, 0xFF)
    emit(0x8D, 0x00, 0xC3)
    emit(0x8D, 0x01, 0xC3)

    step7_loop = addr_of(len(code))
    emit(0xBD, 0x00, 0xC0)                # LDA $C000,X (original ramp)
    emit(0xDD, 0x00, 0xC2)                # CMP $C200,X (SuperRAM readback)
    # If equal, skip
    skip7_branch_pos = len(code)
    emit(0xF0, 0x00)                      # BEQ <patch later>
    # Mismatch: record if first (Y == 0)
    skip_record_pos = len(code)
    emit(0xC0, 0x00, 0x00)                # CPY #$0000 (16-bit cmp)
    emit(0xD0, 0x09)                      # BNE +9 (skip recording)
    emit(0x8D, 0x01, 0xC3)                # STA $C301 (first-actual)
    emit(0xBD, 0x00, 0xC0)                # LDA $C000,X (re-load expected)
    emit(0x8D, 0x00, 0xC3)                # STA $C300 (first-expected)
    # Always increment Y on mismatch (whether first or later)
    emit(0xC8)                            # INY
    # Back-patch BEQ skip distance
    skip_target = len(code)
    rel = skip_target - (skip7_branch_pos + 2)
    assert 0 <= rel <= 127, f'BEQ skip rel={rel}'
    code[skip7_branch_pos + 1] = rel
    emit(0xE8)                            # INX
    emit(0xE0, 0x00, 0x01)                # CPX #$0100
    branch_pc = addr_of(len(code) + 2)
    rel = step7_loop - branch_pc
    assert -128 <= rel <= 127, f'step7 rel={rel}'
    emit(0xD0, rel & 0xFF)

    # Store SuperRAM mismatch count to $0401
    emit(0x98)                            # TYA
    emit(0x8D, 0x01, 0x04)                # STA $0401

    # Tripwires + first mismatch info
    emit(0xA9, 0x77)
    emit(0x8D, 0x02, 0x04)                # STA $0402 = $77 tripwire (test completed)
    emit(0xAD, 0x00, 0xC3)                # LDA $C300 (first expected)
    emit(0x8D, 0x03, 0x04)                # STA $0403
    emit(0xAD, 0x01, 0xC3)                # LDA $C301 (first actual)
    emit(0x8D, 0x04, 0x04)                # STA $0404
    emit(0xA9, 0xAA)
    emit(0x8D, 0x05, 0x04)                # STA $0405 = $AA tail tripwire

    # ---- Return to emu mode and exit gracefully --------------------------
    emit(0xE2, 0x10)                      # SEP #$10 (X=8-bit)
    emit(0x38)                            # SEC
    emit(0xFB)                            # XCE → emu
    emit(0x58)                            # CLI
    emit(0x60)                            # RTS

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'reu_superram_integrity.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    end_addr = 0x0801 + len(code) - 1
    print(f'Wrote {out}: {len(prg)} bytes ($0801..${end_addr:04X})')
    print(f'  main_entry=${main_entry:04X}')
    print()
    print('Expected results on screen $0400-$0405 after RUN:')
    print('  $0400 = 00  (STASH+FETCH roundtrip mismatch count)')
    print('  $0401 = 00  (SuperRAM roundtrip mismatch count)')
    print('  $0402 = 77  (test-completed tripwire)')
    print('  $0403 = FF  (first mismatch expected; FF = no mismatch)')
    print('  $0404 = FF  (first mismatch actual; FF = no mismatch)')
    print('  $0405 = AA  (tail tripwire)')

if __name__ == '__main__':
    sys.exit(main() or 0)
