; CMP long ($CF) - same 4-byte structure as LDA long ($AF), no register change
; Tests if all $xF long opcodes crash, or just $AF
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
    lda #$31
    sta SCREEN+40
    .byte $CF, $20, $D0, $00     ; CMP $00:D020 (4-byte)
    lda #$32
    sta SCREEN+41
@s: jmp @s
