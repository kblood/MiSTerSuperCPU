; JML long $00:target — jump long
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
    sei
    lda #$31
    sta SCREEN+40
    lda #$32
    sta SCREEN+41
    clc
    xce
    .a8
    .i8
    sep #$30
    lda #$33
    sta SCREEN+42
    ; JML long to target label (bank $00)
    .byte $5C
    .word target
    .byte $00
target:
    lda #$34
    sta SCREEN+43
@s: jmp @s
