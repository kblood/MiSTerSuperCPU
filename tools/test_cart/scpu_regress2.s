; SuperCPU regression v2 — uses direct screen writes (proven method)
; Based on the working native_test.s pattern
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

; ZP storage for results (use $F0+ to avoid BASIC)
zp_t1 = $F0    ; bank $00:$0200 (BRAM via STA long)
zp_t2 = $F1    ; bank $01:$0000
zp_t3 = $F2    ; bank $01:$20FC
zp_t4 = $F3    ; bank $01:$4000
zp_t5 = $F4    ; bank $01:$8000
zp_t6 = $F5    ; bank $20:$20FC
zp_t7a = $F6   ; sequential reads
zp_t7b = $F7
zp_t7c = $F8
zp_t7d = $F9
zp_t8a = $FA   ; cross-bank
zp_t8b = $FB
zp_t8c = $FC

start:
    ; Marker '1' at row 1 col 0 — proves we got here in emu mode
    lda #$31
    sta SCREEN+40

    ; Enter native mode
    sei
    clc
    xce
    .a8
    .i8

    ; Marker '2' at row 1 col 1 — STA abs in native mode (DBR test)
    lda #$32
    sta SCREEN+41

    ; T1: STA long to bank $00 RAM at $0300 (cassette buffer area)
    lda #$11
    .byte $8F, $00, $03, $00      ; STA $000300
    .byte $AF, $00, $03, $00      ; LDA $000300
    sta zp_t1

    ; Marker '3'
    lda #$33
    sta SCREEN+42

    ; T2: bank $01:$0000
    lda #$A5
    .byte $8F, $00, $00, $01      ; STA $010000
    .byte $AF, $00, $00, $01      ; LDA $010000
    sta zp_t2

    lda #$34
    sta SCREEN+43

    ; T3: bank $01:$20FC (Doom offset)
    lda #$5A
    .byte $8F, $FC, $20, $01      ; STA $0120FC
    .byte $AF, $FC, $20, $01      ; LDA $0120FC
    sta zp_t3

    lda #$35
    sta SCREEN+44

    ; T4: bank $01:$4000
    lda #$33
    .byte $8F, $00, $40, $01      ; STA $014000
    .byte $AF, $00, $40, $01      ; LDA $014000
    sta zp_t4

    lda #$36
    sta SCREEN+45

    ; T5: bank $01:$8000
    lda #$CC
    .byte $8F, $00, $80, $01      ; STA $018000
    .byte $AF, $00, $80, $01      ; LDA $018000
    sta zp_t5

    lda #$37
    sta SCREEN+46

    ; T6: bank $20:$20FC (Doom bank)
    lda #$77
    .byte $8F, $FC, $20, $20      ; STA $2020FC
    .byte $AF, $FC, $20, $20      ; LDA $2020FC
    sta zp_t6

    lda #$38
    sta SCREEN+47

    ; T7: sequential pipeline stress
    lda #$11
    .byte $8F, $00, $10, $01
    lda #$22
    .byte $8F, $01, $10, $01
    lda #$33
    .byte $8F, $02, $10, $01
    lda #$44
    .byte $8F, $03, $10, $01
    .byte $AF, $00, $10, $01
    sta zp_t7a
    .byte $AF, $01, $10, $01
    sta zp_t7b
    .byte $AF, $02, $10, $01
    sta zp_t7c
    .byte $AF, $03, $10, $01
    sta zp_t7d

    lda #$39
    sta SCREEN+48

    ; T8: cross-bank
    lda #$AA
    .byte $8F, $00, $00, $01      ; bank 1 (overwrite $A5)
    lda #$BB
    .byte $8F, $00, $00, $02      ; bank 2
    lda #$CC
    .byte $8F, $00, $00, $03      ; bank 3
    .byte $AF, $00, $00, $01
    sta zp_t8a
    .byte $AF, $00, $00, $02
    sta zp_t8b
    .byte $AF, $00, $00, $03
    sta zp_t8c

    lda #$3A          ; ':' = end native marker
    sta SCREEN+49

    ; Return to emulation mode
    sec
    xce
    .a8
    .i8
    cli

    ; Marker 'E' (end) at SCREEN+50
    lda #$05
    sta SCREEN+50

    ; ============ Display results on row 3 ============
    ; Row 3 = SCREEN+120
    ; Print T1 hex at +0
    lda zp_t1
    ldx #0
    jsr print_hex_row3

    ; Skip 1, print T2
    inx
    lda zp_t2
    jsr print_hex_row3

    inx
    lda zp_t3
    jsr print_hex_row3

    inx
    lda zp_t4
    jsr print_hex_row3

    inx
    lda zp_t5
    jsr print_hex_row3

    inx
    lda zp_t6
    jsr print_hex_row3

    ; Row 4 = SCREEN+160 — sequential
    lda zp_t7a
    ldx #0
    jsr print_hex_row4
    inx
    lda zp_t7b
    jsr print_hex_row4
    inx
    lda zp_t7c
    jsr print_hex_row4
    inx
    lda zp_t7d
    jsr print_hex_row4

    ; Row 5 = SCREEN+200 — cross-bank
    lda zp_t8a
    ldx #0
    jsr print_hex_row5
    inx
    lda zp_t8b
    jsr print_hex_row5
    inx
    lda zp_t8c
    jsr print_hex_row5

    ; Row 6 = SCREEN+240 — expected reference values (label "EXP:")
    lda #$05    ; E
    sta SCREEN+240
    lda #$10    ; X
    sta SCREEN+241    ; not X, screen code for X is 24
    lda #$18    ; X
    sta SCREEN+241
    lda #$10    ; P
    sta SCREEN+242
    lda #$3A    ; :
    sta SCREEN+243

    ; "11 A5 5A 33 CC 77" expected for T1-T6
    ; just put the literal hex chars
    lda #$31    ; '1'
    sta SCREEN+245
    lda #$31
    sta SCREEN+246
    lda #$01    ; 'A'
    sta SCREEN+248
    lda #$35    ; '5'
    sta SCREEN+249
    lda #$35
    sta SCREEN+251
    lda #$01    ; 'A'
    sta SCREEN+252
    lda #$33
    sta SCREEN+254
    lda #$33
    sta SCREEN+255
    lda #$03    ; 'C'
    sta SCREEN+257
    lda #$03
    sta SCREEN+258
    lda #$37    ; '7'
    sta SCREEN+260
    lda #$37
    sta SCREEN+261

@spin:
    jmp @spin

; print A as 2 hex chars at SCREEN+120 + (X*3)
print_hex_row3:
    pha
    txa
    asl a
    clc
    adc tmp_x
    sta tmp_x2
    txa
    sta tmp_x_save
    lda tmp_x2
    tax
    pla
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nibble3
    pla
    and #$0F
    jsr nibble3
    ldx tmp_x_save
    rts

print_hex_row4:
    pha
    txa
    asl a
    clc
    adc tmp_x
    sta tmp_x2
    txa
    sta tmp_x_save
    lda tmp_x2
    tax
    pla
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nibble4
    pla
    and #$0F
    jsr nibble4
    ldx tmp_x_save
    rts

print_hex_row5:
    pha
    txa
    asl a
    clc
    adc tmp_x
    sta tmp_x2
    txa
    sta tmp_x_save
    lda tmp_x2
    tax
    pla
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nibble5
    pla
    and #$0F
    jsr nibble5
    ldx tmp_x_save
    rts

nibble3:
    and #$0F
    cmp #$0A
    bcc :+
    clc
    adc #$01-$0A    ; 'A'-10 = $01-10
    bra :++
:   ora #$30        ; '0'
:   sta SCREEN+120,x
    inx
    rts

nibble4:
    and #$0F
    cmp #$0A
    bcc :+
    clc
    adc #$01-$0A
    bra :++
:   ora #$30
:   sta SCREEN+160,x
    inx
    rts

nibble5:
    and #$0F
    cmp #$0A
    bcc :+
    clc
    adc #$01-$0A
    bra :++
:   ora #$30
:   sta SCREEN+200,x
    inx
    rts

tmp_x:        .byte 0
tmp_x2:       .byte 0
tmp_x_save:   .byte 0
