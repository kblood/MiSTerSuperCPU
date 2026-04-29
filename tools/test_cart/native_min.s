; Minimal native mode test — just enter/exit native, write markers
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

    ; Write '1' before native (emulation mode)
    lda #$31
    sta $0450

    ; SEI + enter native mode
    sei
    clc
    xce
    .a8
    .i8

    ; Write '2' in native mode (STA absolute uses DBR)
    lda #$32
    sta $0451

    ; Write '3' via STA long (explicit bank $00)
    lda #$8F        ; opcode for STA long
    ; Actually just do it inline:
    ; We need .byte trick to force long addressing
    .byte $A9, $33  ; LDA #$33
    .byte $8F, $52, $04, $00  ; STA $000452 (long)

    ; Write $A5 to SuperRAM bank $01:$0000
    .byte $A9, $A5  ; LDA #$A5
    .byte $8F, $00, $00, $01  ; STA $010000

    ; Write '4' marker
    .byte $A9, $34  ; LDA #$34
    .byte $8F, $53, $04, $00  ; STA $000453

    ; Read back from SuperRAM
    .byte $AF, $00, $00, $01  ; LDA $010000
    .byte $85, $02             ; STA $02

    ; Write '5' marker
    .byte $A9, $35
    .byte $8F, $54, $04, $00

    ; Return to emulation mode
    sec
    xce
    .a8
    .i8

    ; Write '6' marker (emulation, should definitely work)
    lda #$36
    sta $0455

    ; Display readback as hex on row 3 ($04C8)
    lda $02
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nib
    pla
    jsr nib

    ; Write 'D' for done
    lda #$04
    sta $0456

@spin:
    jmp @spin

nib:
    and #$0F
    ora #$30
    cmp #$3A
    bcc @ok
    clc
    adc #$07       ; 'A'-'0'-10 = 7
@ok:
    sta $04C8
    ; advance store address
    inc nib+12     ; low byte of STA address
    rts
