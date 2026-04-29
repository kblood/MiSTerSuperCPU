; LDA long from bank $01 instead of $20
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
    lda #$31
    sta SCREEN+40
    lda #$32
    sta SCREEN+41
    clc
    xce
    .a8
    .i8
    sep #$30
    lda #$33
    sta SCREEN+42
    ; LDA long $01:$0000 (bank 1)
    .byte $AF, $00, $00, $01
    .byte $85, $40
    lda #$34
    sta SCREEN+43
    sec
    xce
    .a8
    .i8
    cli
    lda #$35
    sta SCREEN+44
    lda $40
    pha
    lsr
    lsr
    lsr
    lsr
    jsr nibble
    sta SCREEN+45
    pla
    and #$0F
    jsr nibble
    sta SCREEN+46
@s: jmp @s

nibble:
    cmp #$0A
    bcc @d
    sec
    sbc #$0A
    clc
    adc #$01
    rts
@d:
    clc
    adc #$30
    rts
