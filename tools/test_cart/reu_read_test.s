; reu_read_test.s - REU register read test with I/O control check
; Reads $D020 (border color) as control, then $DF00/$DF01/$DF04
; Expected: D0:xx (non-FF), R0:10, R1:10, R4:42 after write
.p816
.smart

.segment "LOADADDR"
    .word $0801

.segment "EXEHDR"
    .word @end
    .word 10
    .byte $9E
    .byte "2061"
    .byte 0
@end:
    .word 0

.segment "CODE"

start:
    sei
    sta $D07A             ; 1MHz mode

    ; Read border color (control: should NOT be $FF)
    lda $D020
    and #$0F              ; border color is 4 bits
    sta $05

    ; Read REU status register
    lda $DF00
    sta $02               ; save to ZP

    ; Also read $DF01 (command register)
    lda $DF01
    sta $03

    ; Write $42 to $DF04, read it back
    lda #$42
    sta $DF04
    lda $DF04
    sta $04

    ; Display on line 2: "BD:xx R0:xx R1:xx R4:xx"
    ; BD = border color (control)
    lda #$02              ; B
    sta $0400+80
    lda #$04              ; D
    sta $0401+80
    lda #$3A              ; :
    sta $0402+80
    lda $05
    jsr hex2
    stx $0403+80
    sta $0404+80

    lda #$20              ; space
    sta $0405+80

    lda #$12              ; R
    sta $0406+80
    lda #$30              ; 0
    sta $0407+80
    lda #$3A              ; :
    sta $0408+80
    lda $02
    jsr hex2
    stx $0409+80
    sta $040A+80

    lda #$20
    sta $040B+80

    lda #$12              ; R
    sta $040C+80
    lda #$31              ; 1
    sta $040D+80
    lda #$3A              ; :
    sta $040E+80
    lda $03
    jsr hex2
    stx $040F+80
    sta $0410+80

    lda #$20
    sta $0411+80

    lda #$12              ; R
    sta $0412+80
    lda #$34              ; 4
    sta $0413+80
    lda #$3A              ; :
    sta $0414+80
    lda $04
    jsr hex2
    stx $0415+80
    sta $0416+80

    ; Border: green if R0 != $FF AND R4 = $42, red otherwise
    lda $04
    cmp #$42
    bne @fail
    lda $02
    cmp #$FF
    beq @fail
    lda #$05              ; green
    bne @brd
@fail:
    lda #$02              ; red
@brd:
    sta $D020

@hang:
    jmp @hang

hex2:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    tax
    pla
    and #$0F
    tay
    lda hextab,y
    rts

hextab:
    .byte $30,$31,$32,$33,$34,$35,$36,$37
    .byte $38,$39,$01,$02,$03,$04,$05,$06
