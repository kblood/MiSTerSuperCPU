; STA long bank $01, then write multiple distinct markers
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
    ; STA long bank $01:$0000
    .byte $A9, $A5
    .byte $8F, $00, $00, $01
    ; Write distinct markers to row 2 ($0450) — far from row 1 wreckage
    lda #$34
    sta $0450
    lda #$35
    sta $0451
    lda #$36
    sta $0452
    lda #$37
    sta $0453
@s: jmp @s
