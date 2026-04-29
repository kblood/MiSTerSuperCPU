; Border color test: distinct colors before and after LDA long.
; Border WHITE before LDA long, BLUE after.
; If border ends WHITE → crashed during LDA long
; If border ends BLUE → LDA long completed normally
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
BORDER = $D020
    sei
    clc
    xce
    .a8
    .i8
    sep #$30
    lda #$01           ; WHITE
    sta BORDER
    lda #$31
    sta SCREEN+40
    .byte $AF, $20, $D0, $00     ; LDA $00:D020
    pha                ; save A so we can recover it (16-bit, but M=8)
    lda #$06           ; BLUE
    sta BORDER
    lda #$32
    sta SCREEN+41
@s: jmp @s
