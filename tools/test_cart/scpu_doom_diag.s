; scpu_doom_diag.s - Doom JML Target Diagnostic (fixed)
; After doom.reu loaded via MGL, SYS 2061 to run.
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

SCR      = $0400
BORDER   = $D020
BGCOL    = $D021

start:
    sei

    ; Clear screen + set color RAM
    ldx #$00
    lda #$20
@clr:
    sta SCR,x
    sta SCR+$100,x
    sta SCR+$200,x
    sta SCR+$300,x
    inx
    bne @clr
    ldx #$00
    lda #$01              ; white text
@clrc:
    sta $D800,x
    sta $D900,x
    sta $DA00,x
    sta $DB00,x
    inx
    bne @clrc

    lda #$00
    sta BORDER
    sta BGCOL

    ; === DMA: REU $FF0000 -> C64 $0500, 256 bytes ===
    ; (Avoid $0400 so we can see results on screen)
    lda #$00
    sta $DF0A
    sta $DF02             ; C64 low = $00
    lda #$05
    sta $DF03             ; C64 high = $05 -> $0500
    lda #$00
    sta $DF04             ; REU low
    sta $DF05             ; REU mid
    lda #$FF
    sta $DF06             ; REU high -> $FF0000
    lda #$00
    sta $DF07
    lda #$01
    sta $DF08             ; 256 bytes
    lda #$91
    sta $DF01             ; FETCH

    ldx #$80
@w1: dex
    bne @w1

    ; Show "JML " on screen line 0
    lda #$0A              ; J
    sta SCR+0
    lda #$0D              ; M
    sta SCR+1
    lda #$0C              ; L
    sta SCR+2
    lda #$20
    sta SCR+3

    ; Show $05FC-$05FE (= REU $FF00FC-$FF00FE, the JML target)
    lda $05FE             ; bank
    jsr show_at
    lda $05FD             ; high
    jsr show_at
    lda $05FC             ; low
    jsr show_at

    ; Show first 8 bytes of REU $FF0000 on line 2
    ; Label "FF:"
    lda #$06              ; F
    sta SCR+40
    sta SCR+41
    lda #$3A              ; :
    sta SCR+42
    lda #$00
    sta idx
@sf1:
    ldx idx
    lda $0500,x
    jsr show_at
    inc idx
    lda idx
    cmp #$08
    bne @sf1

    ; === DMA: REU $080000 -> $0500 ===
    lda #$00
    sta $DF0A
    sta $DF02
    lda #$05
    sta $DF03
    lda #$00
    sta $DF04
    sta $DF05
    lda #$08
    sta $DF06             ; REU = $080000
    lda #$00
    sta $DF07
    lda #$01
    sta $DF08
    lda #$91
    sta $DF01

    ldx #$80
@w2: dex
    bne @w2

    ; Show "HD:" and 8 bytes on line 4
    lda #$08              ; H
    sta SCR+120
    lda #$04              ; D
    sta SCR+121
    lda #$3A
    sta SCR+122
    lda #$00
    sta idx
@sf2:
    ldx idx
    lda $0500,x
    jsr show_at2
    inc idx
    lda idx
    cmp #$08
    bne @sf2

    ; === DMA: REU $020000 -> $0500 ===
    lda #$00
    sta $DF0A
    sta $DF02
    lda #$05
    sta $DF03
    lda #$00
    sta $DF04
    sta $DF05
    lda #$02
    sta $DF06             ; REU = $020000
    lda #$00
    sta $DF07
    lda #$01
    sta $DF08
    lda #$91
    sta $DF01

    ldx #$80
@w3: dex
    bne @w3

    ; Show "02:" and 8 bytes on line 6
    lda #$30              ; 0
    sta SCR+200
    lda #$32              ; 2
    sta SCR+201
    lda #$3A
    sta SCR+202
    lda #$00
    sta idx
@sf3:
    ldx idx
    lda $0500,x
    jsr show_at3
    inc idx
    lda idx
    cmp #$08
    bne @sf3

    ; === REU round-trip test: STASH $AA to REU $000000, FETCH back ===
    lda #$AA
    sta $0500
    lda #$55
    sta $0501

    ; STASH $0500 -> REU $000000, 2 bytes
    lda #$00
    sta $DF0A
    sta $DF02
    lda #$05
    sta $DF03
    lda #$00
    sta $DF04
    sta $DF05
    sta $DF06             ; REU = $000000
    lda #$02
    sta $DF07             ; 2 bytes
    lda #$00
    sta $DF08
    lda #$B0              ; STASH + FF00 + execute (bit7=1, bit4=1, bits1:0=00)
    sta $DF01

    ldx #$80
@w4: dex
    bne @w4

    ; Clear the test locations
    lda #$00
    sta $0500
    sta $0501

    ; FETCH REU $000000 -> $0500, 2 bytes
    lda #$00
    sta $DF0A
    sta $DF02
    lda #$05
    sta $DF03
    lda #$00
    sta $DF04
    sta $DF05
    sta $DF06
    lda #$02
    sta $DF07
    lda #$00
    sta $DF08
    lda #$91              ; FETCH + FF00 + execute
    sta $DF01

    ldx #$80
@w5: dex
    bne @w5

    ; Show "RT:" and 2 result bytes on line 8 (offset 280)
    lda #$12              ; R
    sta SCR+280
    lda #$14              ; T
    sta SCR+281
    lda #$3A
    sta SCR+282

    ; Expected: AA 55
    lda $0500
    jsr show_at4
    lda $0501
    jsr show_at4

    ; === 65816 native mode SuperRAM read ===
    sta $D07B             ; turbo
    clc
    xce                   ; native mode
    sep #$20
    rep #$10
    .a8
    .i16

    ; Read 8 bytes from $02:0000 via [dp],Y
    lda #$00
    sta $F0
    sta $F1
    lda #$02
    sta $F2

    ldy #$0000
@rsr:
    lda [$F0],y
    sta $0690,y
    iny
    cpy #$0008
    bne @rsr

    sep #$30
    .a8
    .i8
    sec
    xce

    ; Show "SR:" and 8 bytes on line 10 (offset 360)
    lda #$13              ; S
    sta SCR+360
    lda #$12              ; R
    sta SCR+361
    lda #$3A
    sta SCR+362

    lda #$00
    sta idx
@sf5:
    ldx idx
    lda $0690,x
    jsr show_at5
    inc idx
    lda idx
    cmp #$08
    bne @sf5

    ; Green border = complete
    lda #$05
    sta BORDER
    jmp *

; ===== show_at: hex byte at cursor on line 0 =====
; Writes hex to screen at cursor position (spos)
show_at:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    ldx spos
    sta SCR+4,x           ; line 0, col 4+
    inc spos
    pla
    and #$0F
    tax
    lda hextab,x
    ldx spos
    sta SCR+4,x
    inc spos
    inc spos              ; space between bytes
    rts

; show_at2: hex on line 4 starting at col 4
show_at2:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    ldx spos2
    sta SCR+124,x
    inc spos2
    pla
    and #$0F
    tax
    lda hextab,x
    ldx spos2
    sta SCR+124,x
    inc spos2
    inc spos2
    rts

; show_at3: hex on line 6 starting at col 4
show_at3:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    ldx spos3
    sta SCR+204,x
    inc spos3
    pla
    and #$0F
    tax
    lda hextab,x
    ldx spos3
    sta SCR+204,x
    inc spos3
    inc spos3
    rts

; show_at4: hex on line 8 starting at col 4
show_at4:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    ldx spos4
    sta SCR+284,x
    inc spos4
    pla
    and #$0F
    tax
    lda hextab,x
    ldx spos4
    sta SCR+284,x
    inc spos4
    inc spos4
    rts

; show_at5: hex on line 10 starting at col 4
show_at5:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    ldx spos5
    sta SCR+364,x
    inc spos5
    pla
    and #$0F
    tax
    lda hextab,x
    ldx spos5
    sta SCR+364,x
    inc spos5
    inc spos5
    rts

idx:   .byte 0
spos:  .byte 0
spos2: .byte 0
spos3: .byte 0
spos4: .byte 0
spos5: .byte 0

hextab:
    .byte $30,$31,$32,$33,$34,$35,$36,$37
    .byte $38,$39,$01,$02,$03,$04,$05,$06
