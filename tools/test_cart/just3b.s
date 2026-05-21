; Force M=X=1 after XCE via SEP #$30
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
    sep #$30        ; Force M=X=1 (8-bit accumulator + index)
    lda #$33
    sta $0452
@s: jmp @s
