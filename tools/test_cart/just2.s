; Add SEI + 2nd marker
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
    lda #$31
    sta $0450
    sei
    lda #$32
    sta $0451
@s: jmp @s
