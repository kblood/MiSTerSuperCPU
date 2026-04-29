; doom_check.s - Minimal SuperRAM read test
; Reads byte from SuperRAM bank $01:$0000, displays hex on screen
; Build: cl65 -t none -C c64-816.cfg --cpu 65816 -o doom_check.prg doom_check.s

.setcpu "65816"

.segment "LOADADDR"
    .word $0801

.segment "CODE"
    ; BASIC stub: 10 SYS 2061
    .word @end
    .word 10
    .byte $9E, "2061", 0
@end:
    .word 0

start:
    sei

    ; Marker: red border = started
    lda #$02
    sta $D020

    ; Read from SuperRAM bank $01 using LDA long
    ; Need: RAM visible ($34 or $35 in $01), native mode, then LDA $01xxxx
    lda #$35
    sta $01         ; KERNAL + I/O visible

    ; Enter 65C816 native mode
    clc
    xce

    ; Read from SuperRAM bank $01, addr $0000
    ; Opcode: LDA $010000 = AF 00 00 01
    lda $010000

    ; Back to emulation mode
    sec
    xce

    ; Store the read value
    sta $C000       ; Save to RAM

    ; Display on screen
    ; High nibble
    lda $C000
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextbl,x
    sta $0400       ; Screen pos 0,0

    ; Low nibble
    lda $C000
    and #$0F
    tax
    lda hextbl,x
    sta $0401       ; Screen pos 0,1

    ; Also read bank $02:$0000
    clc
    xce
    lda $020000
    sec
    xce
    sta $C001

    lda $C001
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextbl,x
    sta $0403

    lda $C001
    and #$0F
    tax
    lda hextbl,x
    sta $0404

    ; Green border = done
    lda #$05
    sta $D020

    cli
@halt:
    jmp @halt

hextbl: .byte $30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$01,$02,$03,$04,$05,$06
