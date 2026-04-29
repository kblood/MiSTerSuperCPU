; Add NOPs and a 3-byte LDA abs BEFORE LDA long, see if pipeline state matters
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
    nop
    nop
    nop
    nop
    lda #$32
    sta SCREEN+41
    ; LDA abs first (3-byte) — known to work
    .byte $AD, $40, $00          ; LDA $0040
    sta SCREEN+42
    ; Now LDA long (4-byte)
    .byte $AF, $40, $00, $00     ; LDA $000040
    sta SCREEN+43
    lda #$34
    sta SCREEN+44
@s: jmp @s
