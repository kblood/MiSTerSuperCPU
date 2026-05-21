; Add STA long write only (no readback)
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
    ; STA long write to bank $00:$0300
    .byte $A9, $11
    .byte $8F, $00, $03, $00      ; STA $000300
    lda #$34
    sta $042B
@s: jmp @s
