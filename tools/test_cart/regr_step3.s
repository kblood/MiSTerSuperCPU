; STA long to bank $01 (SuperRAM) instead of bank $00
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
    clc
    xce
    .a8
    .i8
    sep #$30
    lda #$33
    sta $042A
    ; STA long to bank $01:$0000 (SuperRAM)
    .byte $A9, $A5
    .byte $8F, $00, $00, $01
    lda #$34
    sta $042B
@s: jmp @s
