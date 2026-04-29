; LDA absolute (3-byte, not long) in native mode
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
    ; LDA abs $0040 (3-byte, opcode $AD)
    .byte $AD, $40, $00
    lda #$34
    sta SCREEN+43
@s: jmp @s
