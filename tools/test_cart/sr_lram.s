; LDA long ($AF) reading from regular RAM (NOT I/O).
; Reads $00:0820 — that's our own program area.
; If this works → bug is specific to IOF read interaction with $AF
; If this crashes → bug is in $AF state machine itself (not I/O)
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
    ; Pre-load a known marker at $0810 so we know what to expect
    lda #$41         ; "A"
    sta $0810
    clc
    xce
    .a8
    .i8
    sep #$30
    lda #$31
    sta SCREEN+40
    .byte $AF, $10, $08, $00     ; LDA $00:0810 - reads RAM, not I/O
    sta SCREEN+41                ; should display "A" if read worked
    lda #$32
    sta SCREEN+42
@s: jmp @s
