; reu_asm_test.s - All-in-one REU DMA test in assembly
; 1. Force 1MHz mode
; 2. Write $A5 to $C000 (C64 RAM, not screen)
; 3. STASH $C000 -> REU $000000, 1 byte
; 4. Clear $C000 to $00
; 5. FETCH REU $000000 -> $C000, 1 byte
; 6. Read $C000 and display result
; Also: read REU status after each DMA
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

    ; Force 1MHz (disable turbo/cache)
    sta $D07A

    ; Write test value to $C000
    lda #$A5
    sta $C000
    lda #$5A
    sta $C001

    ; ====== STASH: C64 $C000 -> REU $000000, 2 bytes ======
    lda #$00
    sta $DF0A             ; no interrupts, addrs increment
    lda #$00
    sta $DF02             ; C64 addr low
    lda #$C0
    sta $DF03             ; C64 addr high -> $C000
    lda #$00
    sta $DF04             ; REU low
    sta $DF05             ; REU mid
    sta $DF06             ; REU high -> $000000
    lda #$02
    sta $DF07             ; length = 2
    lda #$00
    sta $DF08
    lda #$91              ; FETCH+FF00 = $91... wait, STASH = $90
    ; STASH = bits 1:0 = 00. FETCH = bits 1:0 = 01
    lda #$90              ; STASH + FF00 + execute
    sta $DF01             ; GO!

    ; CPU halts during DMA, resumes here after completion

    ; Read status after STASH
    lda $DF00             ; read clears status
    sta $02               ; save status

    ; Clear test locations
    lda #$00
    sta $C000
    sta $C001

    ; ====== FETCH: REU $000000 -> C64 $C000, 2 bytes ======
    lda #$00
    sta $DF0A
    sta $DF02
    lda #$C0
    sta $DF03             ; C64 = $C000
    lda #$00
    sta $DF04
    sta $DF05
    sta $DF06             ; REU = $000000
    lda #$02
    sta $DF07
    lda #$00
    sta $DF08
    lda #$91              ; FETCH + FF00 + execute
    sta $DF01             ; GO!

    ; Read status after FETCH
    lda $DF00
    sta $03               ; save status

    ; ====== Display results ======
    ; Line 0: "STASH S:xx"
    lda #$13              ; S
    sta $0400
    lda #$14              ; T
    sta $0401
    lda #$01              ; A
    sta $0402
    lda #$13              ; S
    sta $0403
    lda #$08              ; H
    sta $0404
    lda #$20
    sta $0405
    lda #$13              ; S
    sta $0406

    lda $02               ; STASH status
    jsr hex2
    stx $0407
    sta $0408

    ; Line 2: "FETCH S:xx"
    lda #$06              ; F
    sta $0400+80
    lda #$05              ; E
    sta $0401+80
    lda #$14              ; T
    sta $0402+80
    lda #$03              ; C
    sta $0403+80
    lda #$08              ; H
    sta $0404+80
    lda #$20
    sta $0405+80
    lda #$13              ; S
    sta $0406+80

    lda $03               ; FETCH status
    jsr hex2
    stx $0407+80
    sta $0408+80

    ; Line 4: "DATA: xx xx"
    lda #$04              ; D
    sta $0400+160
    lda #$01              ; A
    sta $0401+160
    lda #$14              ; T
    sta $0402+160
    lda #$01              ; A
    sta $0403+160

    lda $C000
    jsr hex2
    stx $0405+160
    sta $0406+160

    lda #$20
    sta $0407+160

    lda $C001
    jsr hex2
    stx $0408+160
    sta $0409+160

    ; Border color indicates pass/fail
    lda $C000
    cmp #$A5
    bne @fail
    lda $C001
    cmp #$5A
    bne @fail
    lda #$05              ; green = pass
    bne @setborder
@fail:
    lda #$02              ; red = fail
@setborder:
    sta $D020

@hang:
    jmp @hang

; A -> X=hi nybble screencode, A=lo nybble screencode
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
