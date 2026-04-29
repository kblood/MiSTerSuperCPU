; Pure emu-mode screen write to $0428 (SCREEN+40)
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
    lda #$31
    sta $0428
    lda #$32
    sta $0429
    lda #$33
    sta $042A
@s: jmp @s
