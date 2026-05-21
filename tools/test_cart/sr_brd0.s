; Border color test WITHOUT LDA long. Positive control for sr_brd2.
; Same as sr_brd2 but with NOPs instead of LDA long.
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
    lda #$01           ; WHITE
    sta BORDER
    lda #$31
    sta SCREEN+40
    .byte $EA, $EA, $EA, $EA     ; 4 NOPs in place of LDA long
    pha
    lda #$06           ; BLUE
    sta BORDER
    lda #$32
    sta SCREEN+41
@s: jmp @s
