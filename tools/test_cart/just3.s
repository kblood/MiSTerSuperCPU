; Add SEI + CLC + XCE + 3rd marker via STA abs in native
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
    sta $0452       ; STA abs in native (uses DBR)
@s: jmp @s
