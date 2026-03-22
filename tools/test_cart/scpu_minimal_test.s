; Minimal test: enter native mode, STA long to bank $01, return, show result
.p816
.smart

.segment "LOADADDR"
    .word $0801

.segment "EXEHDR"
    .word @end
    .word 10
    .byte $9E
    .byte "2061"
    .byte 0
@end:
    .word 0

.segment "CODE"

start:
    sei

    ; Border = 1 (white): we got here
    lda #1
    sta $D020

    ; Enter native mode
    clc
    xce
    .a8
    .i8

    ; Border = 2 (red): native mode OK
    lda #2
    sta $D020

    ; STA long to bank $01
    lda #$A5
    sta $014000

    ; Border = 3 (cyan): STA long OK
    lda #3
    sta $D020

    ; LDA long from bank $01
    lda $014000

    ; Border = 7 (yellow): LDA long OK
    pha
    lda #7
    sta $D020
    pla

    ; Check result
    cmp #$A5
    bne @fail

    ; Border = 5 (green): PASS
    lda #5
    sta $D020

    ; Return to emulation
    sec
    xce
    .a8
    .i8
    jmp @halt

@fail:
    ; Border = 10 (light red): FAIL — store actual value
    sta $07E7       ; last screen position, won't be overwritten
    lda #10
    sta $D020

    ; Return to emulation
    sec
    xce
    .a8
    .i8

@halt:
    jmp @halt
