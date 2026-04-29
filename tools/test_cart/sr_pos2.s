; Same as sr_pos1 but bank operand $01 instead of $00
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
BORDER = $D020
    sei
    clc
    xce
    .a8
    .i8
    sep #$30
    nop
    nop
    nop
    nop
    lda #$01           ; WHITE
    sta BORDER
    lda #$31
    sta SCREEN+40
    .byte $AF, $20, $D0, $01     ; LDA $01:D020 (bank $01)
    pha
    lda #$06           ; BLUE
    sta BORDER
    lda #$32
    sta SCREEN+41
@s: jmp @s
