; reu_test_minimal.s - Minimal REU DMA round-trip test
; Write $AA to REU, read back, display result on screen
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

    ; --- Step 1: Write $AA to $0600 ---
    lda #$AA
    sta $0600
    lda #$55
    sta $0601

    ; --- Step 2: STASH $0600 -> REU $000000, 2 bytes ---
    lda #$00
    sta $DF0A             ; no interrupts
    sta $DF02             ; C64 addr low = $00
    lda #$06
    sta $DF03             ; C64 addr high = $06 -> $0600
    lda #$00
    sta $DF04             ; REU addr low
    sta $DF05             ; REU addr mid
    sta $DF06             ; REU addr high -> $000000
    lda #$02
    sta $DF07             ; length = 2
    lda #$00
    sta $DF08
    lda #$90              ; STASH + FF00 + execute
    sta $DF01

    ; Wait for DMA to complete (CPU halts during DMA anyway)
    nop
    nop
    nop
    nop

    ; --- Step 3: Clear $0600-$0601 ---
    lda #$00
    sta $0600
    sta $0601

    ; --- Step 4: FETCH REU $000000 -> $0600, 2 bytes ---
    lda #$00
    sta $DF0A
    sta $DF02
    lda #$06
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

    nop
    nop
    nop
    nop

    ; --- Step 5: Display results ---
    ; Expected: $0600=$AA, $0601=$55
    ; Show at screen position $0400+160 (line 4)

    ; "R:" label
    lda #$12              ; R
    sta $0400+160
    lda #$3A              ; :
    sta $0400+161

    ; $0600 value
    lda $0600
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    sta $0400+163
    pla
    and #$0F
    tax
    lda hextab,x
    sta $0400+164

    lda #$20
    sta $0400+165

    ; $0601 value
    lda $0601
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    sta $0400+166
    pla
    and #$0F
    tax
    lda hextab,x
    sta $0400+167

    ; --- Show REU status register ---
    lda #$20
    sta $0400+168
    lda #$13              ; S
    sta $0400+169
    lda #$3A
    sta $0400+170

    lda $DF00             ; REU status
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    sta $0400+171
    pla
    and #$0F
    tax
    lda hextab,x
    sta $0400+172

    ; --- Show if pass/fail ---
    lda $0600
    cmp #$AA
    bne @fail
    lda $0601
    cmp #$55
    bne @fail

    ; PASS - green border
    lda #$05
    sta $D020
    lda #$10              ; P
    sta $0400+200
    lda #$01              ; A
    sta $0400+201
    lda #$13              ; S
    sta $0400+202
    sta $0400+203
    jmp @done

@fail:
    ; FAIL - red border
    lda #$02
    sta $D020
    lda #$06              ; F
    sta $0400+200
    lda #$01              ; A
    sta $0400+201
    lda #$09              ; I
    sta $0400+202
    lda #$0C              ; L
    sta $0400+203

@done:
    jmp @done

hextab:
    .byte $30,$31,$32,$33,$34,$35,$36,$37
    .byte $38,$39,$01,$02,$03,$04,$05,$06
