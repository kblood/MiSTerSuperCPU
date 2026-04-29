; lda_bank2.s — Read bank $02:$0000-$0001 via LDA long, print result
; Assemble: cl65 --cpu 65816 -t none -C c64-816.cfg -o lda_bank2.prg lda_bank2.s
; Run: SYS 2061

.segment "CODE"

CHROUT = $FFD2

start:
    ; Print header
    ldx #0
@hdr:
    lda header,x
    beq @done_hdr
    jsr CHROUT
    inx
    bne @hdr
@done_hdr:

    ; Switch to native mode and read bank $02
    clc
    xce                         ; native mode
    .byte $AF, $00, $00, $02   ; LDA long $020000
    sta result
    .byte $AF, $01, $00, $02   ; LDA long $020001
    sta result+1
    sec
    xce                         ; back to emulation

    ; Print result as decimal
    lda result
    jsr print_dec
    lda #','
    jsr CHROUT
    lda result+1
    jsr print_dec
    lda #13
    jsr CHROUT

    ; Also do STA $5A then LDA to verify SuperRAM path works
    ldx #0
@rt:
    lda rthdr,x
    beq @done_rt
    jsr CHROUT
    inx
    bne @rt
@done_rt:
    clc
    xce
    lda #$5A
    .byte $8F, $00, $01, $02   ; STA long $020100
    .byte $AF, $00, $01, $02   ; LDA long $020100
    sta result
    sec
    xce
    lda result
    jsr print_dec
    lda #13
    jsr CHROUT
    rts

print_dec:
    pha
    lda #0
    sta hund
    sta tens
    pla
@h: cmp #100
    bcc @t
    sbc #100
    inc hund
    bne @h
@t: cmp #10
    bcc @u
    sbc #10
    inc tens
    bne @t
@u: pha
    lda hund
    ora #'0'
    jsr CHROUT
    lda tens
    ora #'0'
    jsr CHROUT
    pla
    ora #'0'
    jmp CHROUT

header:  .byte 13, "B02:0000=", 0
rthdr:   .byte "RT $5A=", 0
result:  .byte 0, 0
hund:    .byte 0
tens:    .byte 0
