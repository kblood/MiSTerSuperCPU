; LDA long bank=$00 with software 1MHz active (disables turbo + BRAM hit fast path)
; Write to $D07A enables software 1MHz mode → turbo_en goes low
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
SCPU_1MHZ = $D07A
    sei
    lda #$01
    sta BORDER         ; WHITE before LDA long
    lda #$ff
    sta SCPU_1MHZ      ; enable software 1MHz mode (disables turbo)
    clc
    xce
    .a8
    .i8
    sep #$30
    .byte $AF, $20, $D0, $00     ; LDA $00:D020 (the crashing case)
    pha
    lda #$06           ; BLUE if survived
    sta BORDER
loop:
    jmp loop
