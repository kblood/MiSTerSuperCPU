; LDA [DP] indirect long ($A7) - loads AB from DP+2, NOT from PC stream
; If this works → bug is specifically AB-load-from-PBR:PC
; If this crashes → bug is in AB-load itself
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
    ; Set up direct page pointer at $00:$0010..$0012
    ; Pointer = $00:D020 (border color reg)
    lda #$20
    sta $10
    lda #$D0
    sta $11
    lda #$00
    sta $12
    clc
    xce
    .a8
    .i8
    sep #$30
    ; LDA [DP] - reads 24-bit pointer from DP+offset, loads byte from that addr
    .byte $A7, $10               ; LDA [$10] = LDA [(DP+$10)] = LDA $00:D020
    sta SCREEN+40
    lda #$31
    sta SCREEN+41
@s: jmp @s
