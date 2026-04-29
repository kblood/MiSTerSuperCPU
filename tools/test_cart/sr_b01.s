; LDA long with BANK OPERAND = $01
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
    lda #$01           ; WHITE border
    sta BORDER
    lda #$31
    sta SCREEN+40
    .byte $AF, $00, $00, $01     ; LDA $01:0000 (bank $01 = SuperRAM)
    pha
    lda #$06           ; BLUE border
    sta BORDER
    lda #$32
    sta SCREEN+41
@s: jmp @s
