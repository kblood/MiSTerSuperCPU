; Same as sr_min but bank=$01 instead of $00
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
    .byte $AF, $20, $D0, $01     ; LDA $01:D020 (bank $01)
loop:
    jmp loop
