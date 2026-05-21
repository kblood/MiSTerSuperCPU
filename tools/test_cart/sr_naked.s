; LDA long $20:20FC followed immediately by spin (no STA, no return to emu)
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
    ; LDA long
    .byte $AF, $FC, $20, $20
    ; Marker '4' immediately after
    lda #$34
    sta SCREEN+43
    ; Display A as hex
    pha
    lsr
    lsr
    lsr
    lsr
    jsr nibble
    sta SCREEN+44
    pla
    and #$0F
    jsr nibble
    sta SCREEN+45
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
