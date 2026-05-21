; LDA absolute,Y ($B9) - 3-byte 65816 instruction with index, NOT bank operand
; Should NOT crash. Tests if the bug is specifically about loading bank from PC stream.
.segment "LOADADDR"
.word $0801
.segment "EXEHDR"
.word @next
.word 10
.byte $9E
.byte "2061",0
@next:
.word 0
.segment "CODE"
SCREEN = $0400
    sei
    clc
    xce
    .a8
    .i8
    sep #$30
    ldy #$00
    .byte $B9, $20, $D0    ; LDA $D020,Y - 3 bytes, indexed
    sta SCREEN+40
    lda #$31
    sta SCREEN+41
@s: jmp @s
