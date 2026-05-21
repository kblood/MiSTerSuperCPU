; LDA long in EMULATION mode (no XCE)
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
    lda #$33
    sta SCREEN+42
    ; LDA long in EMULATION mode (still 8-bit, no XCE)
    .byte $AF, $40, $00, $00
    lda #$34
    sta SCREEN+43
@s: jmp @s
