; LDA long with extra belt-and-suspenders on M flag
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
    clc
    xce
    .a8
    .i8
    sep #$30
    sep #$30        ; twice for belt & suspenders
    lda #$33
    sta SCREEN+41
    ; Try LDA long with all zero address
    .byte $AF, $00, $00, $00  ; LDA $000000
    ; If we get here, STA $042A
    lda #$34
    sta SCREEN+42
@s: jmp @s
