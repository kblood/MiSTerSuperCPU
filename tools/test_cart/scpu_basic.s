; Minimal SuperCPU test — based on the WORKING native_test.s pattern
; Tests bank $01:$0000, bank $01:$20FC, bank $20:$20FC
; Displays markers and hex results via direct screen writes

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
    ; Print '1' to prove we're running (emulation mode)
    lda #$31
    sta SCREEN+80

    sei
    lda #$32
    sta SCREEN+81       ; '2' = SEI worked

    clc
    xce
    .a8
    .i8

    ; ===== Native mode tests =====
    ; T1: bank $01:$0000
    .byte $A9, $A5            ; LDA #$A5
    .byte $8F, $00, $00, $01  ; STA $010000
    .byte $AF, $00, $00, $01  ; LDA $010000
    .byte $85, $F0            ; STA $F0

    ; T2: bank $01:$20FC
    .byte $A9, $5A
    .byte $8F, $FC, $20, $01
    .byte $AF, $FC, $20, $01
    .byte $85, $F1

    ; T3: bank $20:$20FC
    .byte $A9, $77
    .byte $8F, $FC, $20, $20
    .byte $AF, $FC, $20, $20
    .byte $85, $F2

    ; Done with native, return to emulation
    sec
    xce
    .a8
    .i8

    ; '3' marker after returning
    lda #$33
    sta SCREEN+82

    ; Now print results as hex chars at row 2 col 0+
    ; Result T1: $F0 should be $A5
    ldx #0
    lda $F0
    jsr hex_to_screen

    ; Skip 1 char
    inx

    ; Result T2: $F1 should be $5A
    lda $F1
    jsr hex_to_screen
    inx

    ; Result T3: $F2 should be $77
    lda $F2
    jsr hex_to_screen

    ; Expected line on row 3
    lda #$01    ; A
    sta SCREEN+120
    lda #$35    ; 5
    sta SCREEN+121
    ; space at 122
    lda #$35    ; 5
    sta SCREEN+123
    lda #$01    ; A
    sta SCREEN+124
    ; space at 125
    lda #$37    ; 7
    sta SCREEN+126
    lda #$37    ; 7
    sta SCREEN+127

@spin:
    jmp @spin

; Print A as 2 hex digits at SCREEN+80+X (row 2 col X), advances X
hex_to_screen:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nib
    pla
    and #$0F
    ; fall through
nib:
    and #$0F
    cmp #$0A
    bcc digit
    ; A-F: subtract 10, add 'A' screen code (1)
    sec
    sbc #$0A
    clc
    adc #$01
    bra store
digit:
    clc
    adc #$30
store:
    sta SCREEN+80,x
    inx
    rts
