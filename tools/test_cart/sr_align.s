; Minimum bytes before LDA long, simplest test
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
    clc
    xce
    .a8
    .i8
    sep #$30
    ; LDA long IMMEDIATELY after sep
    .byte $AF, $20, $D0, $00     ; LDA $00D020 (border color register!)
    ; If we got here, A holds border color
    sta SCREEN+40
@s: jmp @s
