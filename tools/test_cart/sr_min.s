; Minimum: LDA long bank=$00, then JMP self. No other ops.
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
    lda #$01
    sta BORDER         ; WHITE before everything
    clc
    xce
    .a8
    .i8
    sep #$30
    .byte $AF, $20, $D0, $00     ; LDA $00:D020
loop:
    jmp loop
