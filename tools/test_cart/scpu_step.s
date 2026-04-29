; Step-by-step SuperCPU test — writes a screen marker after each operation
; to identify exactly where execution stops/crashes.
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
    ; Marker 'A' - emulation mode entry
    lda #$01
    sta SCREEN+80

    sei
    lda #$02            ; 'B'
    sta SCREEN+81

    clc
    xce
    .a8
    .i8

    ; Marker 'C' - just after XCE in native mode
    lda #$03
    sta SCREEN+82

    ; T1: write to bank $01:$0000
    .byte $A9, $A5            ; LDA #$A5
    .byte $8F, $00, $00, $01  ; STA $010000

    ; Marker 'D' - after first STA long
    lda #$04
    sta SCREEN+83

    ; T1: read back
    .byte $AF, $00, $00, $01  ; LDA $010000

    ; Marker 'E' - after first LDA long
    lda #$05
    sta SCREEN+84

    ; Save result
    .byte $85, $F0            ; STA $F0

    ; Marker 'F'
    lda #$06
    sta SCREEN+85

    ; T2: bank $01:$20FC
    .byte $A9, $5A
    .byte $8F, $FC, $20, $01

    ; Marker 'G'
    lda #$07
    sta SCREEN+86

    .byte $AF, $FC, $20, $01
    .byte $85, $F1

    ; Marker 'H'
    lda #$08
    sta SCREEN+87

    ; T3: bank $20:$20FC
    .byte $A9, $77
    .byte $8F, $FC, $20, $20

    ; Marker 'I'
    lda #$09
    sta SCREEN+88

    .byte $AF, $FC, $20, $20
    .byte $85, $F2

    ; Marker 'J'
    lda #$0A
    sta SCREEN+89

    sec
    xce
    .a8
    .i8

    ; Marker 'K' (emulation mode)
    lda #$0B
    sta SCREEN+90

    ; Now write the readback values to row 3
    ; Row 3 = SCREEN+120
    ; Print T1 result (should be A5 → 'A','5')
    lda $F0
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nib0    ; high nibble at SCREEN+120
    pla
    and #$0F
    jsr nib1    ; low nibble at SCREEN+121

    lda $F1
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nib3
    pla
    and #$0F
    jsr nib4

    lda $F2
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nib6
    pla
    and #$0F
    jsr nib7

@spin:
    jmp @spin

nib0:
    jsr conv
    sta SCREEN+120
    rts
nib1:
    jsr conv
    sta SCREEN+121
    rts
nib3:
    jsr conv
    sta SCREEN+123
    rts
nib4:
    jsr conv
    sta SCREEN+124
    rts
nib6:
    jsr conv
    sta SCREEN+126
    rts
nib7:
    jsr conv
    sta SCREEN+127
    rts

conv:
    and #$0F
    cmp #$0A
    bcc digit
    sec
    sbc #$0A
    clc
    adc #$01    ; A=$01 in screen code
    rts
digit:
    clc
    adc #$30    ; '0'=$30
    rts
