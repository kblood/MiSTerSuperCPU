; Native mode test with explicit DBR initialization
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

    ; Step 1 in emulation mode
    lda #$31
    sta $0450       ; '1'

    ; Enter native mode
    sei
    clc
    xce
    .a8
    .i8

    ; Step 2 in native mode WITHOUT DBR init
    lda #$32
    sta $0451       ; '2' — might go to wrong bank if DBR != $00

    ; Initialize DBR to $00
    lda #$00
    pha
    plb             ; DBR = $00

    ; Step 3 in native mode WITH DBR=$00
    lda #$33
    sta $0452       ; '3' — should now go to bank $00

    ; Step 4: STA long (doesn't use DBR)
    .byte $A9, $34  ; LDA #$34
    .byte $8F, $53, $04, $00  ; STA $000453

    ; Step 5: Write to SuperRAM bank $01:$0000
    .byte $A9, $A5  ; LDA #$A5
    .byte $8F, $00, $00, $01  ; STA $010000

    ; Step 5 marker
    lda #$35
    sta $0454       ; '5' — uses DBR=$00

    ; Step 6: Read SuperRAM
    .byte $AF, $00, $00, $01  ; LDA $010000
    sta $02         ; save in dp

    lda #$36
    sta $0455       ; '6'

    ; Step 7: Write/read bank $01:$20FC
    .byte $A9, $5A
    .byte $8F, $FC, $20, $01
    .byte $AF, $FC, $20, $01
    sta $03

    lda #$37
    sta $0456       ; '7'

    ; Step 8: Write/read bank $20:$20FC (Doom)
    .byte $A9, $77
    .byte $8F, $FC, $20, $20
    .byte $AF, $FC, $20, $20
    sta $04

    lda #$38
    sta $0457       ; '8'

    ; Return to emulation
    sec
    xce
    .a8
    .i8

    ; Step 9 in emulation mode
    lda #$39
    sta $0458       ; '9'

    ; Display hex results on row 3
    ; $02 = bank $01:$0000 (expect $A5)
    lda $02
    jsr hex_at_0

    lda #$20        ; space
    sta $04C2

    ; $03 = bank $01:$20FC (expect $5A)
    lda $03
    jsr hex_at_3

    lda #$20
    sta $04C5

    ; $04 = bank $20:$20FC (expect $77)
    lda $04
    jsr hex_at_6

    ; Row 4: labels
    lda #$05        ; 'E'
    sta $04F0
    lda #$18        ; 'X'
    sta $04F1
    lda #$10        ; 'P'
    sta $04F2
    lda #$3A        ; ':'
    sta $04F3
    ; "A5 5A 77"
    lda #$01        ; 'A'
    sta $04F4
    lda #$35        ; '5'
    sta $04F5
    lda #$20
    sta $04F6
    lda #$35
    sta $04F7
    lda #$01        ; 'A'
    sta $04F8
    lda #$20
    sta $04F9
    lda #$37
    sta $04FA
    lda #$37
    sta $04FB

@spin:
    jmp @spin

; Print A as hex at $04C0+offset, offset passed via jsr target
hex_at_0:
    ldx #0
    jmp do_hex
hex_at_3:
    ldx #3
    jmp do_hex
hex_at_6:
    ldx #6
    jmp do_hex

do_hex:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nib
    pla
    and #$0F
nib:
    and #$0F
    ora #$30
    cmp #$3A
    bcc @ok
    clc
    adc #$07
@ok:
    sta $04C0,x
    inx
    rts
