; LDA long ($AF) executed in EMULATION mode (no CLC/XCE).
; The 65816 still decodes $AF as LDA long even in emu mode.
; If this works → bug is specific to NATIVE mode
; If this crashes → bug is in $AF state machine regardless of mode
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
    lda #$31
    sta SCREEN+40
    .byte $AF, $20, $D0, $00     ; LDA $00:D020 (4-byte) - emu mode, no XCE
    sta SCREEN+41
    lda #$32
    sta SCREEN+42
@s: jmp @s
