; Replace LDA long with 4 NOPs at same position - is bug the opcode or the layout?
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
    ; 4 NOPs in same position where sr_align.s puts $AF $20 $D0 $00
    .byte $EA, $EA, $EA, $EA
    lda #$31
    sta SCREEN+40
@s: jmp @s
