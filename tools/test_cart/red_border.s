; Just set border to RED — no native mode, no LDA long
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
    sei
    lda #2          ; RED
    sta $D020
@s: jmp @s
