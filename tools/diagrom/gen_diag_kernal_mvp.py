#!/usr/bin/env python3
"""Generate a menu-driven C64 diagnostic KERNAL (8KB, $E000-$FFFF).

Features:
- Main menu with per-item detail pages
- Keys: 1-5 open pages, R run full suite
- On each page: R run page test, M return to menu
- Tests:
  1) CPU core sanity
  2) IRQ timing sanity
  3) VIC/screen sanity
  4) RAM diagnostics (regions, sectors/amount, speed index)
  5) SuperCPU debug page (raw register values)
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass


# Keyboard return codes.
KEY_1 = 1
KEY_2 = 2
KEY_3 = 3
KEY_4 = 4
KEY_5 = 5
KEY_R = 6
KEY_M = 7


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
        ".": 0x2E,
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

    def sei(self): self._emit(0x78)
    def cli(self): self._emit(0x58)
    def cld(self): self._emit(0xD8)
    def rts(self): self._emit(0x60)
    def rti(self): self._emit(0x40)
    def clc(self): self._emit(0x18)
    def sec(self): self._emit(0x38)
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
    def cmp_abs(self, a: int): self._emit(0xCD, a & 0xFF, (a >> 8) & 0xFF)
    def cmp_imm(self, v: int): self._emit(0xC9, v)
    def and_imm(self, v: int): self._emit(0x29, v)
    def adc_imm(self, v: int): self._emit(0x69, v)
    def sbc_imm(self, v: int): self._emit(0xE9, v)
    def lsr_a(self): self._emit(0x4A)
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

    def bcc(self, label: str):
        self._emit(0x90)
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
                branch_pc_after_operand = f.pos + 1
                rel = target - branch_pc_after_operand
                if not -128 <= rel <= 127:
                    raise ValueError(f"Branch out of range: {f.label} ({rel})")
                self.code[idx] = rel & 0xFF


def emit_screen_str(a: Asm6502, addr: int, text: str) -> None:
    for i, ch in enumerate(text):
        a.lda_imm(scr_code(ch))
        a.sta_abs(addr + i)


def emit_hex_to_abs(a: Asm6502, src_zp: int, hi_addr: int, lo_addr: int, tag: str) -> None:
    hi_digit = f"hex_{tag}_hi_digit"
    hi_store = f"hex_{tag}_hi_store"
    lo_digit = f"hex_{tag}_lo_digit"
    lo_store = f"hex_{tag}_lo_store"

    a.lda_zp(src_zp)
    a.pha()
    a.lsr_a(); a.lsr_a(); a.lsr_a(); a.lsr_a()
    a.and_imm(0x0F)
    a.cmp_imm(0x0A)
    a.bcc(hi_digit)
    a.sec(); a.sbc_imm(0x09)
    a.jmp(hi_store)
    a.label(hi_digit)
    a.clc(); a.adc_imm(0x30)
    a.label(hi_store)
    a.sta_abs(hi_addr)

    a.pla()
    a.and_imm(0x0F)
    a.cmp_imm(0x0A)
    a.bcc(lo_digit)
    a.sec(); a.sbc_imm(0x09)
    a.jmp(lo_store)
    a.label(lo_digit)
    a.clc(); a.adc_imm(0x30)
    a.label(lo_store)
    a.sta_abs(lo_addr)


def build_diag_rom() -> tuple[bytes, int]:
    ROM_BASE = 0xE000
    ROM_SIZE = 0x2000

    ZP_STATUS1 = 0x20
    ZP_STATUS2 = 0x21
    ZP_STATUS3 = 0x22
    ZP_STATUS4 = 0x23
    ZP_STATUS5 = 0x24
    ZP_KEYTMP = 0x25
    ZP_IRQCNT = 0x26
    ZP_TMP = 0x27
    ZP_RAMSECT = 0x28
    ZP_RAMSPEED = 0x29
    ZP_FAIL = 0x2A
    ZP_OLD01 = 0x2B
    ZP_D0B2 = 0x2C
    ZP_D07A = 0x2D
    ZP_D07E = 0x2E
    ZP_REU = 0x2F
    ZP_GEO = 0x30

    MENU_S1 = 0x045F
    MENU_S2 = 0x0487
    MENU_S3 = 0x04AF
    MENU_S4 = 0x04D7
    MENU_S5 = 0x04FF

    a = Asm6502(ROM_BASE)

    a.label("reset")
    a.sei()
    a.cld()
    a.ldx_imm(0xFF)
    a.txs()

    a.lda_imm(0x2F); a.sta_zp(0x00)
    a.lda_imm(0x37); a.sta_zp(0x01)

    a.lda_imm(0x00); a.sta_abs(0xD01A)
    a.lda_imm(0x0F); a.sta_abs(0xD019)
    a.lda_imm(0x7F); a.sta_abs(0xDC0D)

    a.lda_imm(0xFF); a.sta_abs(0xDC02)
    a.lda_imm(0x00); a.sta_abs(0xDC03)

    a.lda_imm(0x06); a.sta_abs(0xD020)
    a.lda_imm(0x00); a.sta_abs(0xD021)
    a.lda_imm(0x1B); a.sta_abs(0xD011)
    a.lda_imm(0x08); a.sta_abs(0xD016)
    a.lda_imm(0x14); a.sta_abs(0xD018)

    a.lda_imm(0); a.sta_zp(ZP_STATUS1); a.sta_zp(ZP_STATUS2); a.sta_zp(ZP_STATUS3); a.sta_zp(ZP_STATUS4); a.sta_zp(ZP_STATUS5)
    a.lda_imm(0); a.sta_zp(ZP_RAMSECT); a.sta_zp(ZP_RAMSPEED)
    a.lda_imm(0); a.sta_zp(ZP_REU); a.sta_zp(ZP_GEO)

    a.jsr("clear_screen")
    a.jsr("draw_menu")

    a.label("main_loop")
    a.jsr("poll_menu_key")
    a.cmp_imm(KEY_1); a.beq("go_page_cpu")
    a.cmp_imm(KEY_2); a.beq("go_page_irq")
    a.cmp_imm(KEY_3); a.beq("go_page_vic")
    a.cmp_imm(KEY_4); a.beq("go_page_ram")
    a.cmp_imm(KEY_5); a.beq("go_page_scpu")
    a.cmp_imm(KEY_R); a.beq("run_all")
    a.jmp("main_loop")

    a.label("go_page_cpu"); a.jsr("page_cpu"); a.jmp("main_loop")
    a.label("go_page_irq"); a.jsr("page_irq"); a.jmp("main_loop")
    a.label("go_page_vic"); a.jsr("page_vic"); a.jmp("main_loop")
    a.label("go_page_ram"); a.jsr("page_ram"); a.jmp("main_loop")
    a.label("go_page_scpu"); a.jsr("page_scpu"); a.jmp("main_loop")

    a.label("run_all")
    a.jsr("test1_cpu")
    a.jsr("test2_irq")
    a.jsr("test3_vic")
    a.jsr("test4_ram")
    a.jsr("test5_scpu")
    a.jsr("draw_menu")
    a.jmp("main_loop")

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

    a.label("status_to_char")
    a.cmp_imm(1); a.beq("stc_p")
    a.cmp_imm(2); a.beq("stc_f")
    a.cmp_imm(3); a.beq("stc_s")
    a.lda_imm(scr_code("-")); a.rts()
    a.label("stc_p")
    a.lda_imm(scr_code("P")); a.rts()
    a.label("stc_f")
    a.lda_imm(scr_code("F")); a.rts()
    a.label("stc_s")
    a.lda_imm(scr_code("S")); a.rts()

    a.label("draw_menu")
    a.jsr("clear_screen")
    emit_screen_str(a, 0x0400, "C64 DIAG ROM")
    emit_screen_str(a, 0x0428, "1 CPU CORE")
    emit_screen_str(a, 0x0450, "2 IRQ TIMING")
    emit_screen_str(a, 0x0478, "3 VIC SCREEN")
    emit_screen_str(a, 0x04A0, "4 RAM DIAG")
    emit_screen_str(a, 0x04C8, "5 SUPERCPU DEBUG")
    emit_screen_str(a, 0x0500, "R RUN ALL")
    emit_screen_str(a, 0x0550, "OPEN PAGE: 1-5")
    emit_screen_str(a, 0x0578, "PER PAGE: R RUN, M MENU")

    a.lda_zp(ZP_STATUS1); a.jsr("status_to_char"); a.sta_abs(MENU_S1)
    a.lda_zp(ZP_STATUS2); a.jsr("status_to_char"); a.sta_abs(MENU_S2)
    a.lda_zp(ZP_STATUS3); a.jsr("status_to_char"); a.sta_abs(MENU_S3)
    a.lda_zp(ZP_STATUS4); a.jsr("status_to_char"); a.sta_abs(MENU_S4)
    a.lda_zp(ZP_STATUS5); a.jsr("status_to_char"); a.sta_abs(MENU_S5)
    a.rts()

    a.label("poll_menu_key")
    a.label("pm_loop")
    a.jsr("frame_sync")
    a.jsr("scan_keys")
    a.cmp_imm(0); a.beq("pm_loop")
    a.rts()

    a.label("poll_page_key")
    a.label("pp_loop")
    a.jsr("frame_sync")
    a.jsr("scan_keys")
    a.cmp_imm(KEY_R); a.beq("pp_ret")
    a.cmp_imm(KEY_M); a.beq("pp_ret")
    a.jmp("pp_loop")
    a.label("pp_ret")
    a.rts()

    # Throttle UI loops to one scan per video frame to reduce bus churn.
    a.label("frame_sync")
    a.lda_abs(0xD012)
    a.label("fs_wait_change")
    a.cmp_abs(0xD012)
    a.beq("fs_wait_change")
    a.lda_imm(0x00)
    a.label("fs_wait_line0")
    a.cmp_abs(0xD012)
    a.bne("fs_wait_line0")
    a.rts()

    a.label("scan_keys")
    a.lda_imm(0x7F); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("sk_1")
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("sk_2")

    a.lda_imm(0xFD); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("sk_3")
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("sk_4")

    a.lda_imm(0xFB); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("sk_5")
    a.lda_abs(0xDC01); a.and_imm(0x02); a.beq("sk_r")

    a.lda_imm(0xEF); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x10); a.beq("sk_m")

    a.lda_imm(0xFF); a.sta_abs(0xDC00)
    a.lda_imm(0)
    a.rts()

    a.label("sk_1"); a.lda_imm(KEY_1); a.jsr("wait_release"); a.rts()
    a.label("sk_2"); a.lda_imm(KEY_2); a.jsr("wait_release"); a.rts()
    a.label("sk_3"); a.lda_imm(KEY_3); a.jsr("wait_release"); a.rts()
    a.label("sk_4"); a.lda_imm(KEY_4); a.jsr("wait_release"); a.rts()
    a.label("sk_5"); a.lda_imm(KEY_5); a.jsr("wait_release"); a.rts()
    a.label("sk_r"); a.lda_imm(KEY_R); a.jsr("wait_release"); a.rts()
    a.label("sk_m"); a.lda_imm(KEY_M); a.jsr("wait_release"); a.rts()

    a.label("wait_release")
    a.sta_zp(ZP_KEYTMP)
    a.label("wr_loop")
    a.lda_imm(0x7F); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("wr_loop")
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("wr_loop")

    a.lda_imm(0xFD); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("wr_loop")
    a.lda_abs(0xDC01); a.and_imm(0x08); a.beq("wr_loop")

    a.lda_imm(0xFB); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x01); a.beq("wr_loop")
    a.lda_abs(0xDC01); a.and_imm(0x02); a.beq("wr_loop")

    a.lda_imm(0xEF); a.sta_abs(0xDC00); a.lda_abs(0xDC01); a.and_imm(0x10); a.beq("wr_loop")

    a.lda_imm(0xFF); a.sta_abs(0xDC00)
    a.lda_zp(ZP_KEYTMP)
    a.rts()

    a.label("page_cpu")
    a.jsr("clear_screen")
    emit_screen_str(a, 0x0400, "CPU CORE DETAIL")
    emit_screen_str(a, 0x0428, "CHECKS ALU LOAD STORE STACK")
    emit_screen_str(a, 0x0478, "RESULT:")
    emit_screen_str(a, 0x04A0, "R RUN TEST")
    emit_screen_str(a, 0x04C8, "M BACK TO MENU")
    a.lda_zp(ZP_STATUS1); a.jsr("status_to_char"); a.sta_abs(0x047F)
    a.label("page_cpu_loop")
    a.jsr("poll_page_key")
    a.cmp_imm(KEY_M); a.beq("page_cpu_exit")
    a.jsr("test1_cpu")
    a.lda_zp(ZP_STATUS1); a.jsr("status_to_char"); a.sta_abs(0x047F)
    a.jmp("page_cpu_loop")
    a.label("page_cpu_exit")
    a.jsr("draw_menu")
    a.rts()

    a.label("page_irq")
    a.jsr("clear_screen")
    emit_screen_str(a, 0x0400, "IRQ TIMING DETAIL")
    emit_screen_str(a, 0x0428, "CHECKS CIA1 TIMER IRQ PATH")
    emit_screen_str(a, 0x0478, "IRQ COUNT:")
    emit_screen_str(a, 0x04A0, "RESULT:")
    emit_screen_str(a, 0x04C8, "R RUN TEST")
    emit_screen_str(a, 0x04F0, "M BACK TO MENU")
    emit_hex_to_abs(a, ZP_IRQCNT, 0x0482, 0x0483, "irq0")
    a.lda_zp(ZP_STATUS2); a.jsr("status_to_char"); a.sta_abs(0x04A7)
    a.label("page_irq_loop")
    a.jsr("poll_page_key")
    a.cmp_imm(KEY_M); a.beq("page_irq_exit")
    a.jsr("test2_irq")
    emit_hex_to_abs(a, ZP_IRQCNT, 0x0482, 0x0483, "irq1")
    a.lda_zp(ZP_STATUS2); a.jsr("status_to_char"); a.sta_abs(0x04A7)
    a.jmp("page_irq_loop")
    a.label("page_irq_exit")
    a.jsr("draw_menu")
    a.rts()

    a.label("page_vic")
    a.jsr("clear_screen")
    emit_screen_str(a, 0x0400, "VIC SCREEN DETAIL")
    emit_screen_str(a, 0x0428, "CHECKS SCREEN/COLOR RAM RW")
    emit_screen_str(a, 0x0478, "RESULT:")
    emit_screen_str(a, 0x04A0, "R RUN TEST")
    emit_screen_str(a, 0x04C8, "M BACK TO MENU")
    a.lda_zp(ZP_STATUS3); a.jsr("status_to_char"); a.sta_abs(0x047F)
    a.label("page_vic_loop")
    a.jsr("poll_page_key")
    a.cmp_imm(KEY_M); a.beq("page_vic_exit")
    a.jsr("test3_vic")
    a.lda_zp(ZP_STATUS3); a.jsr("status_to_char"); a.sta_abs(0x047F)
    a.jmp("page_vic_loop")
    a.label("page_vic_exit")
    a.jsr("draw_menu")
    a.rts()

    a.label("page_ram")
    a.jsr("clear_screen")
    emit_screen_str(a, 0x0400, "RAM DIAG DETAIL")
    emit_screen_str(a, 0x0428, "TYPES: BASE COLOR MAPPED")
    emit_screen_str(a, 0x0450, "SECTOR PASS:")
    emit_screen_str(a, 0x0478, "SPEED IDX:")
    emit_screen_str(a, 0x04A0, "RESULT:")
    emit_screen_str(a, 0x04C8, "SECTORS USE 4K PROBES")
    emit_screen_str(a, 0x04F0, "R RUN TEST   M MENU")
    emit_screen_str(a, 0x0518, "REU:")
    emit_screen_str(a, 0x0540, "GEORAM:")
    emit_hex_to_abs(a, ZP_RAMSECT, 0x045C, 0x045D, "ram0")
    emit_hex_to_abs(a, ZP_RAMSPEED, 0x0482, 0x0483, "ram1")
    a.lda_zp(ZP_STATUS4); a.jsr("status_to_char"); a.sta_abs(0x04A7)
    a.lda_zp(ZP_REU); a.jsr("status_to_char"); a.sta_abs(0x051D)
    a.lda_zp(ZP_GEO); a.jsr("status_to_char"); a.sta_abs(0x0547)
    a.label("page_ram_loop")
    a.jsr("poll_page_key")
    a.cmp_imm(KEY_M); a.beq("page_ram_exit")
    a.jsr("test4_ram")
    emit_hex_to_abs(a, ZP_RAMSECT, 0x045C, 0x045D, "ram2")
    emit_hex_to_abs(a, ZP_RAMSPEED, 0x0482, 0x0483, "ram3")
    a.lda_zp(ZP_STATUS4); a.jsr("status_to_char"); a.sta_abs(0x04A7)
    a.lda_zp(ZP_REU); a.jsr("status_to_char"); a.sta_abs(0x051D)
    a.lda_zp(ZP_GEO); a.jsr("status_to_char"); a.sta_abs(0x0547)
    a.jmp("page_ram_loop")
    a.label("page_ram_exit")
    a.jsr("draw_menu")
    a.rts()

    a.label("page_scpu")
    a.jsr("clear_screen")
    emit_screen_str(a, 0x0400, "SUPERCPU DEBUG DETAIL")
    emit_screen_str(a, 0x0428, "D0B2:")
    emit_screen_str(a, 0x0450, "D07A:")
    emit_screen_str(a, 0x0478, "D07E:")
    emit_screen_str(a, 0x04A0, "RAM SECTOR PASS:")
    emit_screen_str(a, 0x04C8, "RAM SPEED IDX:")
    emit_screen_str(a, 0x04F0, "RESULT:")
    emit_screen_str(a, 0x0518, "R RUN TEST   M MENU")
    emit_screen_str(a, 0x0540, "REU:")
    emit_screen_str(a, 0x0568, "GEORAM:")
    a.jsr("test4_ram")
    a.jsr("test5_scpu")
    emit_hex_to_abs(a, ZP_D0B2, 0x042D, 0x042E, "scpu0")
    emit_hex_to_abs(a, ZP_D07A, 0x0455, 0x0456, "scpu1")
    emit_hex_to_abs(a, ZP_D07E, 0x047D, 0x047E, "scpu2")
    emit_hex_to_abs(a, ZP_RAMSECT, 0x04AF, 0x04B0, "scpu3")
    emit_hex_to_abs(a, ZP_RAMSPEED, 0x04D6, 0x04D7, "scpu4")
    a.lda_zp(ZP_STATUS5); a.jsr("status_to_char"); a.sta_abs(0x04F7)
    a.lda_zp(ZP_REU); a.jsr("status_to_char"); a.sta_abs(0x0545)
    a.lda_zp(ZP_GEO); a.jsr("status_to_char"); a.sta_abs(0x056F)
    a.label("page_scpu_loop")
    a.jsr("poll_page_key")
    a.cmp_imm(KEY_M); a.bne("page_scpu_run")
    a.jmp("page_scpu_exit")
    a.label("page_scpu_run")
    a.jsr("test4_ram")
    a.jsr("test5_scpu")
    emit_hex_to_abs(a, ZP_D0B2, 0x042D, 0x042E, "scpu5")
    emit_hex_to_abs(a, ZP_D07A, 0x0455, 0x0456, "scpu6")
    emit_hex_to_abs(a, ZP_D07E, 0x047D, 0x047E, "scpu7")
    emit_hex_to_abs(a, ZP_RAMSECT, 0x04AF, 0x04B0, "scpu8")
    emit_hex_to_abs(a, ZP_RAMSPEED, 0x04D6, 0x04D7, "scpu9")
    a.lda_zp(ZP_STATUS5); a.jsr("status_to_char"); a.sta_abs(0x04F7)
    a.lda_zp(ZP_REU); a.jsr("status_to_char"); a.sta_abs(0x0545)
    a.lda_zp(ZP_GEO); a.jsr("status_to_char"); a.sta_abs(0x056F)
    a.jmp("page_scpu_loop")
    a.label("page_scpu_exit")
    a.jsr("draw_menu")
    a.rts()

    a.label("test1_cpu")
    a.lda_imm(0x42); a.sta_abs(0xC100); a.lda_abs(0xC100); a.cmp_imm(0x42); a.bne("t1_fail")
    a.lda_imm(0xAA); a.pha()
    a.lda_imm(0x55); a.pha()
    a.pla(); a.cmp_imm(0x55); a.bne("t1_fail")
    a.pla(); a.cmp_imm(0xAA); a.bne("t1_fail")
    a.lda_imm(1); a.sta_zp(ZP_STATUS1); a.rts()
    a.label("t1_fail")
    a.lda_imm(2); a.sta_zp(ZP_STATUS1); a.rts()

    a.label("test2_irq")
    a.lda_imm(0); a.sta_zp(ZP_IRQCNT)
    a.lda_imm(0x7F); a.sta_abs(0xDC0D)
    a.lda_imm(0x81); a.sta_abs(0xDC0D)
    a.lda_imm(0x00); a.sta_abs(0xDC04)
    a.lda_imm(0x20); a.sta_abs(0xDC05)
    a.lda_imm(0x19); a.sta_abs(0xDC0E)
    a.cli()
    a.ldx_imm(0x20)
    a.label("t2_outer")
    a.ldy_imm(0xFF)
    a.label("t2_inner")
    a.dey(); a.bne("t2_inner")
    a.dex(); a.bne("t2_outer")
    a.sei()
    a.lda_imm(0x00); a.sta_abs(0xDC0E)
    a.lda_imm(0x7F); a.sta_abs(0xDC0D)
    a.lda_zp(ZP_IRQCNT); a.cmp_imm(0x00); a.beq("t2_fail")
    a.lda_imm(1); a.sta_zp(ZP_STATUS2); a.rts()
    a.label("t2_fail")
    a.lda_imm(2); a.sta_zp(ZP_STATUS2); a.rts()

    a.label("test3_vic")
    a.lda_imm(0x11); a.sta_abs(0x0400)
    a.lda_imm(0x22); a.sta_abs(0x0401)
    a.lda_abs(0x0400); a.cmp_imm(0x11); a.bne("t3_fail")
    a.lda_abs(0x0401); a.cmp_imm(0x22); a.bne("t3_fail")
    a.lda_imm(0x0A); a.sta_abs(0xD800)
    a.lda_abs(0xD800); a.and_imm(0x0F); a.cmp_imm(0x0A); a.bne("t3_fail")
    a.lda_imm(1); a.sta_zp(ZP_STATUS3); a.rts()
    a.label("t3_fail")
    a.lda_imm(2); a.sta_zp(ZP_STATUS3); a.rts()

    a.label("test4_ram")
    a.lda_imm(0); a.sta_zp(ZP_FAIL)
    a.lda_imm(0); a.sta_zp(ZP_RAMSECT)

    a.lda_imm(0x5A); a.sta_abs(0x0800)
    a.lda_abs(0x0800); a.cmp_imm(0x5A); a.beq("t4_low_ok")
    a.lda_imm(1); a.sta_zp(ZP_FAIL)
    a.label("t4_low_ok")

    a.lda_imm(0xA5); a.sta_abs(0xC000)
    a.lda_abs(0xC000); a.cmp_imm(0xA5); a.beq("t4_hi_ok")
    a.lda_imm(1); a.sta_zp(ZP_FAIL)
    a.label("t4_hi_ok")

    a.lda_imm(0x0B); a.sta_abs(0xD800)
    a.lda_abs(0xD800); a.and_imm(0x0F); a.cmp_imm(0x0B); a.beq("t4_col_ok")
    a.lda_imm(1); a.sta_zp(ZP_FAIL)
    a.label("t4_col_ok")

    a.lda_zp(0x01); a.sta_zp(ZP_OLD01)
    a.lda_imm(0x30); a.sta_zp(0x01)

    for i in range(16):
        addr = (i << 12) | 0x002
        val = (i * 0x11 + 0x03) & 0xFF
        a.lda_imm(val)
        a.sta_abs(addr)

    for i in range(16):
        addr = (i << 12) | 0x002
        val = (i * 0x11 + 0x03) & 0xFF
        miss = f"t4_sec_miss_{i}"
        done = f"t4_sec_done_{i}"
        a.lda_abs(addr)
        a.cmp_imm(val)
        a.bne(miss)
        a.inc_zp(ZP_RAMSECT)
        a.jmp(done)
        a.label(miss)
        a.lda_imm(1); a.sta_zp(ZP_FAIL)
        a.label(done)

    a.lda_zp(ZP_OLD01); a.sta_zp(0x01)

    a.lda_imm(0x7F); a.sta_abs(0xDC0D)
    a.lda_imm(0xFF); a.sta_abs(0xDC04)
    a.lda_imm(0xFF); a.sta_abs(0xDC05)
    a.lda_imm(0x11); a.sta_abs(0xDC0E)

    a.ldy_imm(0x20)
    a.label("t4_spd_outer")
    a.ldx_imm(0x00)
    a.label("t4_spd_inner")
    a.lda_absx(0x0400)
    a.sta_absx(0xC100)
    a.inx()
    a.bne("t4_spd_inner")
    a.dey()
    a.bne("t4_spd_outer")

    a.lda_imm(0x00); a.sta_abs(0xDC0E)
    a.lda_abs(0xDC04); a.sta_zp(ZP_RAMSPEED)

    # REU probe at $DFxx: detect register response and basic register stickiness.
    a.lda_imm(3); a.sta_zp(ZP_REU)  # default SKIP when not present
    a.lda_imm(0x00); a.sta_abs(0xDF09)   # intr bits -> expect low bits fixed to 1s
    a.lda_abs(0xDF09); a.cmp_imm(0x1F); a.bne("t4_reu_done")
    a.lda_imm(0x34); a.sta_abs(0xDF02)
    a.lda_abs(0xDF02); a.cmp_imm(0x34); a.bne("t4_reu_fail")
    a.lda_imm(1); a.sta_zp(ZP_REU)
    a.jmp("t4_reu_done")
    a.label("t4_reu_fail")
    a.lda_imm(2); a.sta_zp(ZP_REU)
    a.label("t4_reu_done")

    # GeoRAM probe at $DE/$DF: bank select via DFFE/DFFF and banked data at DE00.
    a.lda_imm(3); a.sta_zp(ZP_GEO)  # default SKIP when not present
    a.lda_imm(0x00); a.sta_abs(0xDFFF)
    a.lda_imm(0x00); a.sta_abs(0xDFFE)
    a.lda_imm(0xA5); a.sta_abs(0xDE00)
    a.lda_abs(0xDE00); a.cmp_imm(0xA5); a.bne("t4_geo_done")
    a.lda_imm(0x00); a.sta_abs(0xDFFF)
    a.lda_imm(0x01); a.sta_abs(0xDFFE)
    a.lda_imm(0x5A); a.sta_abs(0xDE00)
    a.lda_abs(0xDE00); a.cmp_imm(0x5A); a.bne("t4_geo_fail")
    a.lda_imm(0x00); a.sta_abs(0xDFFF)
    a.lda_imm(0x00); a.sta_abs(0xDFFE)
    a.lda_abs(0xDE00); a.cmp_imm(0xA5); a.bne("t4_geo_fail")
    a.lda_imm(1); a.sta_zp(ZP_GEO)
    a.jmp("t4_geo_done")
    a.label("t4_geo_fail")
    a.lda_imm(2); a.sta_zp(ZP_GEO)
    a.label("t4_geo_done")

    a.lda_zp(ZP_FAIL); a.cmp_imm(0x00); a.bne("t4_fail")
    a.lda_zp(ZP_RAMSECT); a.cmp_imm(0x10); a.beq("t4_pass")
    a.label("t4_fail")
    a.lda_imm(2); a.sta_zp(ZP_STATUS4); a.rts()
    a.label("t4_pass")
    a.lda_imm(1); a.sta_zp(ZP_STATUS4); a.rts()

    a.label("test5_scpu")
    a.lda_abs(0xD0B2); a.sta_zp(ZP_D0B2)
    a.lda_abs(0xD07A); a.sta_zp(ZP_D07A)
    a.lda_abs(0xD07E); a.sta_zp(ZP_D07E)
    a.lda_zp(ZP_D0B2); a.cmp_imm(0x53); a.beq("t5_pass")
    a.lda_imm(3); a.sta_zp(ZP_STATUS5); a.rts()
    a.label("t5_pass")
    a.lda_imm(1); a.sta_zp(ZP_STATUS5); a.rts()

    a.label("nmi_handler")
    a.rti()

    a.label("irq_handler")
    a.pha()
    a.txa(); a.pha()
    a.tya(); a.pha()
    a.inc_zp(ZP_IRQCNT)
    a.lda_abs(0xDC0D)
    a.pla(); a.tay()
    a.pla(); a.tax()
    a.pla()
    a.rti()

    a.resolve()

    image = bytearray([0xFF] * ROM_SIZE)
    if len(a.code) > ROM_SIZE:
        raise ValueError(f"Code too large: {len(a.code)} > {ROM_SIZE}")
    image[:len(a.code)] = a.code

    def set_vec(addr: int, target: int) -> None:
        idx = addr - ROM_BASE
        image[idx] = target & 0xFF
        image[idx + 1] = (target >> 8) & 0xFF

    set_vec(0xFFFA, a.labels["nmi_handler"])
    set_vec(0xFFFC, a.labels["reset"])
    set_vec(0xFFFE, a.labels["irq_handler"])

    return bytes(image), len(a.code)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate C64 diagnostic KERNAL binary.")
    parser.add_argument(
        "--out",
        default="tools/rom_builder/rom_inputs/debug_kernal.bin",
        help="Output binary path (default: tools/rom_builder/rom_inputs/debug_kernal.bin)",
    )
    args = parser.parse_args()

    blob, code_len = build_diag_rom()
    with open(args.out, "wb") as f:
        f.write(blob)
    code_budget = 0x1FFA  # $E000-$FFF9 (vectors live at $FFFA-$FFFF)
    code_free = code_budget - code_len
    total_used = code_len + 6  # include fixed vectors
    print(f"Wrote {args.out} ({len(blob)} bytes)")
    print(f"KERNAL code used: {code_len}/{code_budget} bytes, free: {code_free} bytes")
    print(f"Total occupied including vectors: {total_used}/8192 bytes")


if __name__ == "__main__":
    main()
