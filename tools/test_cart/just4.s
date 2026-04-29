; Add SuperRAM write to bank $01:$0000
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
    clc
    xce
    .a8
    .i8
    lda #$33
    sta $0452
    ; SuperRAM write
    .byte $A9, $A5             ; LDA #$A5
    .byte $8F, $00, $00, $01   ; STA $010000
    lda #$34
    sta $0453
@s: jmp @s
