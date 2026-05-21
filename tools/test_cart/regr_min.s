; Minimal scpu_regress: just early markers, no display logic
; Goal: prove markers are visible and find which test segment kills the screen
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

SCREEN = $0400

start:
    lda #$31
    sta SCREEN+40
    sei
    lda #$32
    sta SCREEN+41

    clc
    xce
    .a8
    .i8
    sep #$30

    lda #$33
    sta SCREEN+42

    ; T1: bank $00 STA long
    .byte $A9, $11
    .byte $8F, $00, $03, $00      ; STA $000300
    .byte $AF, $00, $03, $00      ; LDA $000300
    .byte $8D, $2B, $04            ; STA SCREEN+43 (show readback)

    lda #$34
    sta SCREEN+44

    ; Return to emu
    sec
    xce
    .a8
    .i8
    cli

    lda #$35
    sta SCREEN+45

@spin:
    jmp @spin
