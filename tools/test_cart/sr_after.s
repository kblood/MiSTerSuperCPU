; LDA long but with EXTRA writes BEFORE to mark position, then check screen after
; The screen writes BEFORE LDA long should remain visible if BRK does NOT trigger.
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
    sei
    clc
    xce
    .a8
    .i8
    sep #$30
    ; Write distinctive characters to many screen locations BEFORE LDA long
    lda #$01
    sta SCREEN+0
    lda #$02
    sta SCREEN+1
    lda #$03
    sta SCREEN+2
    lda #$04
    sta SCREEN+3
    lda #$05
    sta SCREEN+4
    lda #$06
    sta SCREEN+5
    lda #$07
    sta SCREEN+6
    lda #$08
    sta SCREEN+7
    ; Now LDA long
    .byte $AF, $20, $D0, $00     ; LDA $00D020 (border color)
    sta SCREEN+8
    lda #$09
    sta SCREEN+9
@s: jmp @s
