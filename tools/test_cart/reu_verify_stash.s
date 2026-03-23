; reu_verify_stash.s - Verify STASH writes to SDRAM by reading via SuperRAM
; 1. POKE $A5 to $C000 (C64 RAM)
; 2. STASH from C64 $C000 to REU $010000 (bank $01:$0000 in SuperRAM)
; 3. Read bank $01:$0000 via LDA long (SuperRAM path)
; 4. Display result — if $A5 appears, STASH SDRAM write works
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
    sta $D07A             ; 1MHz mode (safe for DMA)

    ; Write $A5 to $C000
    lda #$A5
    sta $C000

    ; STASH: C64 $C000 -> REU $010000, 1 byte
    lda #$00
    sta $DF0A
    sta $DF02             ; C64 low = $00
    lda #$C0
    sta $DF03             ; C64 high = $C0 -> $C000
    lda #$00
    sta $DF04             ; REU low = $00
    sta $DF05             ; REU mid = $00
    lda #$01
    sta $DF06             ; REU high = $01 -> REU $010000
    lda #$01
    sta $DF07             ; length = 1
    lda #$00
    sta $DF08
    lda #$90              ; STASH + FF00 + execute
    sta $DF01

    ; Read STASH status
    lda $DF00
    sta $02               ; save status

    ; Now read bank $01:$0000 via LDA long (SuperRAM path)
    sta $D07B             ; turbo mode
    clc
    xce                   ; native mode
    sep #$20
    .a8

    ; Read from $01:$0000 via LDA long,X
    ldx #$0000
    .i16
    rep #$10
    lda f:$010000         ; LDA long from bank $01:$0000
    sta $03               ; save SuperRAM value

    ; Back to emulation
    sep #$30
    .a8
    .i8
    sec
    xce
    sta $D07A             ; 1MHz

    ; Display results on screen
    ; "S:" + STASH status hex
    lda #$13
    sta $0400+160
    lda #$3A
    sta $0401+160
    lda $02
    jsr hex2
    stx $0402+160
    sta $0403+160

    ; " V:" + SuperRAM verify value hex
    lda #$20
    sta $0404+160
    lda #$16              ; V
    sta $0405+160
    lda #$3A
    sta $0406+160
    lda $03
    jsr hex2
    stx $0407+160
    sta $0408+160

    ; Border: green if V=$A5, red otherwise
    lda $03
    cmp #$A5
    beq @pass
    lda #$02              ; red
    bne @brd
@pass:
    lda #$05              ; green
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
