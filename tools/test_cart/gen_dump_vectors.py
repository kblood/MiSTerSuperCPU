#!/usr/bin/env python3
"""Generate `dump_vectors.prg` — dump C64 KERNAL vector table + SCPU
kickstart handler region to screen via KERNAL CHROUT.

Why:
  The SCPU EPROM image (`scpu64.mif`) at RESET overlays bank $00:$E000
  with the kickstart code. On real CMD hardware the kickstart installs
  vector hooks in the $0300-$0333 table (so LOAD/SAVE/CHRIN/CHROUT route
  through CMD-aware handlers that throttle to 1MHz before touching
  CIA2/IEC) and places handler bytes at $00:$801A-$8054. After the
  hooks are installed the kickstart clears bootmap ($D0B6) and BASIC
  boots normally with the C64 KERNAL visible.

  If our scpu64.mif EPROM is actually running on the FPGA, this PRG
  shows non-stock vectors at ILOAD/IBASIN/etc. AND non-zero bytes at
  $801A-$8054. If the kickstart is not running (or only the bootmap
  exit fires without the hook-install code), all vectors are stock
  KERNAL defaults and $801A bytes are $00.

Output layout (when RUN):
    ILOAD =XXXX        ; expected stock: F4A5
    ISAVE =XXXX        ; expected stock: F5ED
    IOPEN =XXXX        ; expected stock: F34A
    ICHKIN=XXXX        ; expected stock: F291
    IBASIN=XXXX        ; expected stock: F157
    IBSOUT=XXXX        ; expected stock: F1CA
    IGETIN=XXXX        ; expected stock: F13E
    CINV  =XXXX        ; expected stock: EA31
    $801A =XXXX XXXX XXXX XXXX
    $8020 =XXXX XXXX XXXX XXXX
    $8000 =XXXX XXXX XXXX XXXX

Diagnostic interpretation:
  - All vectors == stock KERNAL → kickstart never installed hooks
  - ILOAD/IBASIN remapped (and $801A non-zero) → hooks installed; the
    LOAD wedge is then INSIDE the firmware's own throttle path, not
    a missing-throttle problem
  - Mixed → partial install, kickstart aborted mid-sequence

Usage:
    python tools/test_cart/gen_dump_vectors.py
    # produces tools/test_cart/out/dump_vectors.prg

Then load via MGL the same way as lorenz_autoload.prg.
"""
import os

# ---------------------------------------------------------------------------
# 6502 hand-assembler helpers
# ---------------------------------------------------------------------------

def b(*vals):
    out = []
    for v in vals:
        if isinstance(v, (bytes, bytearray)):
            out += list(v)
        else:
            out.append(v & 0xFF)
    return bytes(out)

CHROUT = 0xFFD2  # KERNAL CHROUT (output PETSCII char in A)

# ---------------------------------------------------------------------------
# Layout (all in one contiguous PRG starting at $0801):
#
#   $0801  BASIC stub  "10 SYS 2061"    (12 bytes)
#   $080D  ML entry
#   ...    ML body (~250 bytes)
#   ...    HEXTBL + strings
#
# SYS 2061 = $080D points to first ML instruction.
# ---------------------------------------------------------------------------

LOAD_ADDR = 0x0801
ML_ENTRY  = 0x080D


def build_basic_stub():
    """`10 SYS 2061` tokenized at $0801, ends at $080C, ML starts $080D."""
    # Line layout:
    #   0801: 0B 08     link to next line ($080B)
    #   0803: 0A 00     line# 10
    #   0805: 9E        SYS token
    #   0806: 32 30 36 31   "2061"
    #   080A: 00        end-of-line
    #   080B: 00 00     null next-line link
    next_link = 0x080B
    return b(
        next_link & 0xFF, (next_link >> 8) & 0xFF,
        10, 0,                       # line 10
        0x9E,                        # SYS
        ord('2'), ord('0'), ord('6'), ord('1'),
        0x00,                        # eol
        0x00, 0x00,                  # null next link
    )


# ---------------------------------------------------------------------------
# Build ML in two passes: first compute label offsets, then emit bytes
# with correct absolute addresses patched in.
# ---------------------------------------------------------------------------

# We build the ML as a list of (kind, payload) chunks, where:
#   ('raw', bytes)       — literal bytes
#   ('lblref', label)    — placeholder, replaced with absolute addr (2 bytes LE)
#   ('label', name)      — sets the current PC as `name`
# Pass 1 walks chunks tracking PC; pass 2 emits bytes with patches.

def assemble(chunks, base_pc):
    # Pass 1: compute labels
    labels = {}
    pc = base_pc
    for kind, payload in chunks:
        if kind == 'raw':
            pc += len(payload)
        elif kind == 'lblref':
            pc += 2
        elif kind == 'label':
            labels[payload] = pc
        else:
            raise ValueError(f"unknown chunk kind: {kind}")
    # Pass 2: emit
    out = bytearray()
    for kind, payload in chunks:
        if kind == 'raw':
            out += payload
        elif kind == 'lblref':
            addr = labels[payload]
            out += bytes([addr & 0xFF, (addr >> 8) & 0xFF])
        # 'label' produces no bytes
    return bytes(out), labels


def build_ml():
    """Assemble the dump program.

    ML routines used:
      JSR PRHEX        ; print A as 2 hex digits via CHROUT
      JSR PR_STR_INL   ; followed by `lo,hi` of asciiz string addr
      JSR PR_VEC <vec> ; not really a routine — inlined for each vector

    To keep things simple we inline the `print prefix + dump word` for
    each vector instead of using a parameterized helper.
    """
    chunks = []

    def emit(*bs):
        chunks.append(('raw', b(*bs)))

    def lblref(name):
        chunks.append(('lblref', name))

    def label(name):
        chunks.append(('label', name))

    # ---- ENTRY ----
    label('ENTRY')

    # Print each vector. Pattern per vector:
    #   LDX #0
    # .lp: LDA <STR>,X
    #      BEQ .done
    #      JSR $FFD2
    #      INX
    #      BNE .lp
    # .done:
    #      LDA <addr_hi>
    #      JSR PRHEX
    #      LDA <addr_lo>
    #      JSR PRHEX
    #      LDA #$0D
    #      JSR $FFD2

    def emit_print_vector(str_label, vec_addr):
        # LDX #0
        emit(0xA2, 0x00)
        # Loop bytes (offsets relative to LDX-end):
        #   +0: BD lo hi   ; LDA STR,X       (3 bytes)
        #   +3: F0 04      ; BEQ +4 → +9 (the BNE; Z=1 falls through)
        #   +5: 20 D2 FF   ; JSR CHROUT
        #   +8: E8         ; INX
        #   +9: D0 F5      ; BNE -11 → back to LDA STR,X at +0
        # After this loop X is the count of printed chars.
        chunks.append(('raw', b(0xBD)))  # LDA abs,X opcode
        lblref(str_label)
        emit(0xF0, 0x04)                 # BEQ +4 → BNE position (falls through, Z=1)
        emit(0x20, CHROUT & 0xFF, (CHROUT >> 8) & 0xFF)  # JSR CHROUT
        emit(0xE8)                       # INX
        emit(0xD0, 0xF5)                 # BNE -11 → back to LDA abs,X
        # After BEQ target lands here: print hi byte then lo byte of vec_addr+1, vec_addr.
        emit(0xAD, (vec_addr+1) & 0xFF, ((vec_addr+1) >> 8) & 0xFF)  # LDA vec_hi
        emit(0x20)
        lblref('PRHEX')
        emit(0xAD, vec_addr & 0xFF, (vec_addr >> 8) & 0xFF)          # LDA vec_lo
        emit(0x20)
        lblref('PRHEX')
        emit(0xA9, 0x0D)                 # LDA #$0D
        emit(0x20, CHROUT & 0xFF, (CHROUT >> 8) & 0xFF)              # JSR CHROUT

    def emit_print_bytes(str_label, base_addr, count):
        """Print prefix then `count` bytes from base_addr as hex pairs
        separated by spaces. After the last byte, print CR."""
        # Print prefix string (same loop as above)
        emit(0xA2, 0x00)
        chunks.append(('raw', b(0xBD)))
        lblref(str_label)
        emit(0xF0, 0x04)
        emit(0x20, CHROUT & 0xFF, (CHROUT >> 8) & 0xFF)
        emit(0xE8)
        emit(0xD0, 0xF5)                 # BNE -11 → loop to LDA abs,X
        # For each byte: LDA abs ; JSR PRHEX ; (optional space every 2 bytes)
        for i in range(count):
            addr = base_addr + i
            emit(0xAD, addr & 0xFF, (addr >> 8) & 0xFF)  # LDA abs
            emit(0x20)
            lblref('PRHEX')
            # space after every 2nd byte (except last)
            if i < count - 1 and (i & 1) == 1:
                emit(0xA9, 0x20)
                emit(0x20, CHROUT & 0xFF, (CHROUT >> 8) & 0xFF)
        emit(0xA9, 0x0D)
        emit(0x20, CHROUT & 0xFF, (CHROUT >> 8) & 0xFF)

    # Emit the program: one header line, then each vector, then handler dumps.
    emit_print_vector('STR_ILOAD',  0x0330)
    emit_print_vector('STR_ISAVE',  0x0332)
    emit_print_vector('STR_IOPEN',  0x031A)
    emit_print_vector('STR_ICHKIN', 0x031E)
    emit_print_vector('STR_IBASIN', 0x0324)
    emit_print_vector('STR_IBSOUT', 0x0326)
    emit_print_vector('STR_IGETIN', 0x032A)
    emit_print_vector('STR_CINV',   0x0314)
    emit_print_bytes ('STR_801A',   0x801A, 8)
    emit_print_bytes ('STR_8020',   0x8020, 8)
    emit_print_bytes ('STR_8000',   0x8000, 8)
    emit_print_bytes ('STR_FFFC',   0xFFFC, 4)   # RESET vector area

    # RTS — back to BASIC
    emit(0x60)

    # ---- PRHEX subroutine ----
    # PRHEX: print A as 2 hex chars via CHROUT
    label('PRHEX')
    emit(0x48)                       # PHA
    emit(0x4A, 0x4A, 0x4A, 0x4A)     # LSR LSR LSR LSR
    emit(0x20)
    lblref('PRNIB')                  # JSR PRNIB
    emit(0x68)                       # PLA
    emit(0x29, 0x0F)                 # AND #$0F
    # fall through to PRNIB
    label('PRNIB')
    emit(0xA8)                       # TAY
    emit(0xB9)                       # LDA abs,Y
    lblref('HEXTBL')
    emit(0x4C, CHROUT & 0xFF, (CHROUT >> 8) & 0xFF)  # JMP CHROUT (tail call)

    # ---- HEX table ----
    label('HEXTBL')
    chunks.append(('raw', b'0123456789ABCDEF'))

    # ---- Strings (PETSCII; uppercase = $41-$5A in default charset) ----
    def emit_str(name, s):
        label(name)
        chunks.append(('raw', s.encode('ascii') + b'\x00'))

    emit_str('STR_ILOAD',  'ILOAD =$')
    emit_str('STR_ISAVE',  'ISAVE =$')
    emit_str('STR_IOPEN',  'IOPEN =$')
    emit_str('STR_ICHKIN', 'ICHKIN=$')
    emit_str('STR_IBASIN', 'IBASIN=$')
    emit_str('STR_IBSOUT', 'IBSOUT=$')
    emit_str('STR_IGETIN', 'IGETIN=$')
    emit_str('STR_CINV',   'CINV  =$')
    emit_str('STR_801A',   '$801A =')
    emit_str('STR_8020',   '$8020 =')
    emit_str('STR_8000',   '$8000 =')
    emit_str('STR_FFFC',   '$FFFC =')

    # Assemble with ML_ENTRY as base PC
    code, labels = assemble(chunks, ML_ENTRY)
    return code, labels


def main():
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
    os.makedirs(out_dir, exist_ok=True)
    prg_path = os.path.join(out_dir, 'dump_vectors.prg')

    basic_stub = build_basic_stub()
    ml_code, labels = build_ml()

    prg = (
        bytes([LOAD_ADDR & 0xFF, (LOAD_ADDR >> 8) & 0xFF])
        + basic_stub
        + ml_code
    )

    with open(prg_path, 'wb') as f:
        f.write(prg)

    print(f"PRG: {prg_path} ({len(prg)} bytes)")
    print(f"  load addr  = ${LOAD_ADDR:04X}")
    print(f"  BASIC stub = {len(basic_stub)} bytes (SYS 2061)")
    print(f"  ML body    = {len(ml_code)} bytes")
    print(f"  ML entry   = ${ML_ENTRY:04X}")
    print()
    print("Label addresses:")
    for name, addr in sorted(labels.items(), key=lambda kv: kv[1]):
        print(f"  {name:12s} ${addr:04X}")


if __name__ == '__main__':
    main()
