; Just write '1' to SCREEN+80 and loop. Simplest possible test.
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
@s: jmp @s
