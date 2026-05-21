; Same as sr_brd2 but LDA long at $0820 (one byte later)
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
    nop                ; pad to shift LDA long position
    nop
    nop
    nop
    lda #$01           ; WHITE
    sta BORDER
    lda #$31
    sta SCREEN+40
    .byte $AF, $20, $D0, $00     ; LDA $00:D020
    pha
    lda #$06           ; BLUE
    sta BORDER
    lda #$32
    sta SCREEN+41
@s: jmp @s
