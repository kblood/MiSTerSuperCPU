#!/usr/bin/env python3
"""Generate a menu-driven C64 diagnostic KERNAL MVP (8KB, $E000-$FFFF).

MVP features:
- Menu with key input (1-4, R)
- Test 1: CPU core basics
- Test 2: CIA1 timer IRQ/RTI path
- Test 3: VIC/screen RAM read-write sanity
- Test 4: SuperCPU presence probe ($D0B2 == $53 => pass, else skip)
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass


def scr_code(ch: str) -> int:
    if "A" <= ch <= "Z":
        return ord(ch) - ord("A") + 1
    if "0" <= ch <= "9":
        return ord(ch)
    table = {
        " ": 0x20,
        "-": 0x2D,
        ":": 0x3A,
        "/": 0x2F,
    }
    return table.get(ch, 0x20)


@dataclass
class Fixup:
    pos: int
    label: str
    kind: str  # "abs" or "rel"


class Asm6502:
    def __init__(self, start: int):
        self.start = start
        self.pc = start
        self.code = bytearray()
        self.labels: dict[str, int] = {}
        self.fixups: list[Fixup] = []

    def _emit(self, *vals: int) -> None:
        for v in vals:
            self.code.append(v & 0xFF)
            self.pc += 1

    def label(self, name: str) -> None:
        self.labels[name] = self.pc

    def byte(self, val: int) -> None:
        self._emit(val)

    def word(self, val: int) -> None:
        self._emit(val & 0xFF, (val >> 8) & 0xFF)

    # Basic instructions used by this MVP.
    def sei(self): self._emit(0x78)
    def cli(self): self._emit(0x58)
    def cld(self): self._emit(0xD8)
    def rts(self): self._emit(0x60)
    def rti(self): self._emit(0x40)
    def pha(self): self._emit(0x48)
    def pla(self): self._emit(0x68)
    def txa(self): self._emit(0x8A)
    def tax(self): self._emit(0xAA)
    def tya(self): self._emit(0x98)
    def tay(self): self._emit(0xA8)
    def inx(self): self._emit(0xE8)
    def dex(self): self._emit(0xCA)
    def dey(self): self._emit(0x88)
    def nop(self): self._emit(0xEA)
    def lda_imm(self, v: int): self._emit(0xA9, v)
    def ldx_imm(self, v: int): self._emit(0xA2, v)
    def ldy_imm(self, v: int): self._emit(0xA0, v)
    def lda_zp(self, a: int): self._emit(0xA5, a)
    def sta_zp(self, a: int): self._emit(0x85, a)
    def inc_zp(self, a: int): self._emit(0xE6, a)
    def lda_abs(self, a: int): self._emit(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def sta_abs(self, a: int): self._emit(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def sta_absx(self, a: int): self._emit(0x9D, a & 0xFF, (a >> 8) & 0xFF)
    def lda_absx(self, a: int): self._emit(0xBD, a & 0xFF, (a >> 8) & 0xFF)
    def cmp_imm(self, v: int): self._emit(0xC9, v)
    def and_imm(self, v: int): self._emit(0x29, v)
    def txs(self): self._emit(0x9A)

    def jsr(self, label: str):
        self._emit(0x20)
        self.fixups.append(Fixup(self.pc, label, "abs"))
        self.word(0)

    def jmp(self, label: str):
        self._emit(0x4C)
        self.fixups.append(Fixup(self.pc, label, "abs"))
        self.word(0)

    def beq(self, label: str):
        self._emit(0xF0)
        self.fixups.append(Fixup(self.pc, label, "rel"))
        self.byte(0)

    def bne(self, label: str):
        self._emit(0xD0)
        self.fixups.append(Fixup(self.pc, label, "rel"))
        self.byte(0)

    def resolve(self) -> None:
        for f in self.fixups:
            if f.label not in self.labels:
                raise ValueError(f"Undefined label: {f.label}")
            target = self.labels[f.label]
            idx = f.pos - self.start
            if f.kind == "abs":
                self.code[idx] = target & 0xFF
                self.code[idx + 1] = (target >> 8) & 0xFF
            else:
                # Relative branch offset from next instruction.
                branch_pc_after_operand = f.pos + 1
                rel = target - branch_pc_after_operand
                if not -128 <= rel <= 127:
                    raise ValueError(f"Branch out of range: {f.label} ({rel})")
                self.code[idx] = rel & 0xFF


def emit_screen_str(a: Asm6502, addr: int, text: str) -> None:
    for i, ch in enumerate(text):
        a.lda_imm(scr_code(ch))
        a.sta_abs(addr + i)


def build_mvp() -> bytes:
    ROM_BASE = 0xE000
    ROM_SIZE = 0x2000

    # Zero page variables.
    ZP_STATUS1 = 0x20
    ZP_STATUS2 = 0x21
    ZP_STATUS3 = 0x22
    ZP_STATUS4 = 0x23
    ZP_KEYTMP = 0x24
    ZP_IRQCNT = 0x25

    # Fixed per-row status column (prevents overlap with varying label lengths).
    RES1 = 0x049E  # row at $0478 + col 38
    RES2 = 0x04C6  # row at $04A0 + col 38
    RES3 = 0x04EE  # row at $04C8 + col 38
    RES4 = 0x0516  # row at $04F0 + col 38

    a = Asm6502(ROM_BASE)

    # --- Reset/init ---
    a.label("reset")
    a.sei()
    a.cld()
    a.ldx_imm(0xFF)
    a.txs()

    # Ensure 6510 memory map exposes I/O area ($D000-$DFFF).
    # Without this, reads from $D0B2 may come from RAM and SCPU detect can false-skip.
    a.lda_imm(0x2F); a.sta_zp(0x00)  # DDR
    a.lda_imm(0x37); a.sta_zp(0x01)  # LORAM+HIRAM+CHAREN

    # Disable/ack IRQ sources up front.
    a.lda_imm(0x00); a.sta_abs(0xD01A)  # VIC IRQ mask off
    a.lda_imm(0x0F); a.sta_abs(0xD019)  # VIC IRQ ack
    a.lda_imm(0x7F); a.sta_abs(0xDC0D)  # CIA1 IRQ mask off

    # CIA1 keyboard matrix setup: PA output, PB input.
    a.lda_imm(0xFF); a.sta_abs(0xDC02)
    a.lda_imm(0x00); a.sta_abs(0xDC03)

    # VIC base settings.
    a.lda_imm(0x06); a.sta_abs(0xD020)  # border blue
    a.lda_imm(0x00); a.sta_abs(0xD021)  # bg black
    a.lda_imm(0x1B); a.sta_abs(0xD011)  # display on
    a.lda_imm(0x08); a.sta_abs(0xD016)  # 40 columns
    a.lda_imm(0x14); a.sta_abs(0xD018)  # screen at $0400

    a.jsr("clear_screen")
    a.jsr("draw_menu")

    a.label("main_loop")
    a.jsr("poll_key")
    a.cmp_imm(1); a.beq("run_t1")
    a.cmp_imm(2); a.beq("run_t2")
    a.cmp_imm(3); a.beq("run_t3")
    a.cmp_imm(4); a.beq("run_t4")
    a.cmp_imm(5); a.beq("run_all")
    a.jmp("main_loop")

    a.label("run_t1"); a.jsr("test1_cpu"); a.jmp("main_loop")
    a.label("run_t2"); a.jsr("test2_irq"); a.jmp("main_loop")
    a.label("run_t3"); a.jsr("test3_vic"); a.jmp("main_loop")
    a.label("run_t4"); a.jsr("test4_scpu"); a.jmp("main_loop")

    a.label("run_all")
    a.jsr("test1_cpu")
    a.jsr("test2_irq")
    a.jsr("test3_vic")
    a.jsr("test4_scpu")
    a.jmp("main_loop")

    # --- clear_screen ---
    a.label("clear_screen")
    a.lda_imm(0x20)
    a.ldx_imm(0x00)
    a.label("clr_loop")
    a.sta_absx(0x0400)
    a.sta_absx(0x0500)
    a.sta_absx(0x0600)
    a.sta_absx(0x06E8)
    a.inx()
    a.bne("clr_loop")

    a.lda_imm(0x01)
    a.ldx_imm(0x00)
    a.label("col_loop")
    a.sta_absx(0xD800)
    a.sta_absx(0xD900)
    a.sta_absx(0xDA00)
    a.sta_absx(0xDAE8)
    a.inx()
    a.bne("col_loop")
    a.rts()

    # --- draw_menu ---
    a.label("draw_menu")
    emit_screen_str(a, 0x0400, "C64 DIAG ROM MVP")
    emit_screen_str(a, 0x0428, "MENU: 1-4 RUN TEST, R RUN ALL")
    emit_screen_str(a, 0x0478, "1 CPU CORE TEST")
    emit_screen_str(a, 0x0495, "STATUS:")
    emit_screen_str(a, 0x04A0, "2 IRQ TIMING TEST")
    emit_screen_str(a, 0x04BD, "STATUS:")
    emit_screen_str(a, 0x04C8, "3 VIC SCREEN TEST")
    emit_screen_str(a, 0x04E5, "STATUS:")
    emit_screen_str(a, 0x04F0, "4 SUPERCPU DETECT")
    emit_screen_str(a, 0x050D, "STATUS:")
    emit_screen_str(a, 0x0540, "P PASS  F FAIL  S SKIP")

    a.lda_imm(0); a.sta_zp(ZP_STATUS1); a.sta_zp(ZP_STATUS2); a.sta_zp(ZP_STATUS3); a.sta_zp(ZP_STATUS4)
    a.lda_imm(scr_code("-"))
    a.sta_abs(RES1); a.sta_abs(RES2); a.sta_abs(RES3); a.sta_abs(RES4)
    a.rts()

    # --- poll_key ---
    a.label("poll_key")
    a.label("poll_loop")
    # Key '1': row 7, bit 0
    a.lda_imm(0x7F); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("key_1")
    # Key '2': row 7, bit 3
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("key_2")
    # Key '3': row 1, bit 0
    a.lda_imm(0xFD); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("key_3")
    # Key '4': row 1, bit 3
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("key_4")
    # Key 'R': row 2, bit 1
    a.lda_imm(0xFB); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x02); a.beq("key_r")
    a.jmp("poll_loop")

    a.label("key_1"); a.lda_imm(1); a.jsr("wait_release"); a.rts()
    a.label("key_2"); a.lda_imm(2); a.jsr("wait_release"); a.rts()
    a.label("key_3"); a.lda_imm(3); a.jsr("wait_release"); a.rts()
    a.label("key_4"); a.lda_imm(4); a.jsr("wait_release"); a.rts()
    a.label("key_r"); a.lda_imm(5); a.jsr("wait_release"); a.rts()

    a.label("wait_release")
    a.sta_zp(ZP_KEYTMP)
    a.label("wr_loop")
    # if any monitored key still pressed, keep waiting.
    a.lda_imm(0x7F); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("wr_loop")
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("wr_loop")
    a.lda_imm(0xFD); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("wr_loop")
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("wr_loop")
    a.lda_imm(0xFB); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x02); a.beq("wr_loop")
    a.lda_imm(0xFF); a.sta_abs(0xDC00)
    a.lda_zp(ZP_KEYTMP)
    a.rts()

    # --- test1_cpu ---
    a.label("test1_cpu")
    a.lda_imm(0x42); a.sta_abs(0xC100); a.lda_abs(0xC100); a.cmp_imm(0x42); a.bne("t1_fail")
    a.lda_imm(0xAA); a.pha()
    a.lda_imm(0x55); a.pha()
    a.pla(); a.cmp_imm(0x55); a.bne("t1_fail")
    a.pla(); a.cmp_imm(0xAA); a.bne("t1_fail")
    a.lda_imm(1); a.sta_zp(ZP_STATUS1)
    a.lda_imm(scr_code("P")); a.sta_abs(RES1); a.rts()
    a.label("t1_fail")
    a.lda_imm(2); a.sta_zp(ZP_STATUS1)
    a.lda_imm(scr_code("F")); a.sta_abs(RES1); a.rts()

    # --- test2_irq ---
    a.label("test2_irq")
    a.lda_imm(0); a.sta_zp(ZP_IRQCNT)
    a.lda_imm(0x7F); a.sta_abs(0xDC0D)  # disable all CIA1 IRQ masks
    a.lda_imm(0x81); a.sta_abs(0xDC0D)  # enable timer A IRQ
    a.lda_imm(0x00); a.sta_abs(0xDC04)  # timer A low latch
    a.lda_imm(0x20); a.sta_abs(0xDC05)  # timer A high latch
    a.lda_imm(0x19); a.sta_abs(0xDC0E)  # start + oneshot + load
    a.cli()
    a.ldx_imm(0x20)
    a.label("t2_outer")
    a.ldy_imm(0xFF)
    a.label("t2_inner")
    a.dey()
    a.bne("t2_inner")
    a.dex()
    a.bne("t2_outer")
    a.sei()
    a.lda_imm(0x00); a.sta_abs(0xDC0E)  # stop timer
    a.lda_imm(0x7F); a.sta_abs(0xDC0D)  # disable irq mask
    a.lda_zp(ZP_IRQCNT); a.cmp_imm(0x00); a.beq("t2_fail")
    a.lda_imm(1); a.sta_zp(ZP_STATUS2)
    a.lda_imm(scr_code("P")); a.sta_abs(RES2); a.rts()
    a.label("t2_fail")
    a.lda_imm(2); a.sta_zp(ZP_STATUS2)
    a.lda_imm(scr_code("F")); a.sta_abs(RES2); a.rts()

    # --- test3_vic ---
    a.label("test3_vic")
    a.lda_imm(0x11); a.sta_abs(0x0400)
    a.lda_imm(0x22); a.sta_abs(0x0401)
    a.lda_abs(0x0400); a.cmp_imm(0x11); a.bne("t3_fail")
    a.lda_abs(0x0401); a.cmp_imm(0x22); a.bne("t3_fail")
    a.lda_imm(0x02); a.sta_abs(0xD800)
    a.lda_imm(0x03); a.sta_abs(0xD801)
    a.lda_imm(1); a.sta_zp(ZP_STATUS3)
    a.lda_imm(scr_code("P")); a.sta_abs(RES3); a.rts()
    a.label("t3_fail")
    a.lda_imm(2); a.sta_zp(ZP_STATUS3)
    a.lda_imm(scr_code("F")); a.sta_abs(RES3); a.rts()

    # --- test4_scpu ---
    a.label("test4_scpu")
    a.lda_abs(0xD0B2)
    a.cmp_imm(0x53)
    a.beq("t4_pass")
    # Not present -> SKIP
    a.lda_imm(3); a.sta_zp(ZP_STATUS4)
    a.lda_imm(scr_code("S")); a.sta_abs(RES4); a.rts()
    a.label("t4_pass")
    a.lda_imm(1); a.sta_zp(ZP_STATUS4)
    a.lda_imm(scr_code("P")); a.sta_abs(RES4); a.rts()

    # --- NMI/IRQ handlers ---
    a.label("nmi_handler")
    a.rti()

    a.label("irq_handler")
    a.pha()
    a.txa(); a.pha()
    a.tya(); a.pha()
    a.inc_zp(ZP_IRQCNT)
    a.lda_abs(0xDC0D)  # acknowledge CIA1 irq source
    a.pla(); a.tay()
    a.pla(); a.tax()
    a.pla()
    a.rti()

    # Resolve labels and build 8KB image.
    a.resolve()
    image = bytearray([0xFF] * ROM_SIZE)
    offs = a.start - ROM_BASE
    if offs != 0:
        raise ValueError("Unexpected start offset")
    if len(a.code) > ROM_SIZE:
        raise ValueError(f"Code too large: {len(a.code)} > {ROM_SIZE}")
    image[:len(a.code)] = a.code

    # Vectors.
    def set_vec(addr: int, target: int) -> None:
        idx = addr - ROM_BASE
        image[idx] = target & 0xFF
        image[idx + 1] = (target >> 8) & 0xFF

    set_vec(0xFFFA, a.labels["nmi_handler"])
    set_vec(0xFFFC, a.labels["reset"])
    set_vec(0xFFFE, a.labels["irq_handler"])
    return bytes(image)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate C64 diagnostic KERNAL MVP binary.")
    parser.add_argument(
        "--out",
        default="tools/rom_builder/rom_inputs/debug_kernal.bin",
        help="Output binary path (default: tools/rom_builder/rom_inputs/debug_kernal.bin)",
    )
    args = parser.parse_args()

    blob = build_mvp()
    with open(args.out, "wb") as f:
        f.write(blob)
    print(f"Wrote {args.out} ({len(blob)} bytes)")


if __name__ == "__main__":
    main()
