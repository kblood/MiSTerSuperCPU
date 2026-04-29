; Test CHROUT after native mode entry
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

CHROUT = $FFD2

    ; Print "A" before native
    lda #'A'
    jsr CHROUT

    ; Enter native mode
    sei
    clc
    xce
    .a8
    .i8

    ; Write to bank $01:$0000 via STA long
    lda #$A5
    sta f:$010000
    lda f:$010000
    sta $F0           ; save in ZP

    ; Return to emulation
    sec
    xce
    .a8
    .i8
    cli

    ; Print "B"
    lda #'B'
    jsr CHROUT

    ; Print the result hex byte
    lda $F0
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nib
    pla
    and #$0F
    jsr nib

    lda #13
    jsr CHROUT
    rts

nib:
    cmp #$0A
    bcc @dig
    clc
    adc #$07
@dig:
    adc #$30
    jmp CHROUT
