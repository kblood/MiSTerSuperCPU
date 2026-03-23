; reu_path_test.s - Test DMA read vs CPU write to SuperRAM
; 1. STA long writes $A5 to bank $01:$0000 (SuperRAM)
; 2. REU FETCH from REU $010000 to C64 $FB
; 3. Display results: if PEEK($FB) = $A5, DMA read from SuperRAM works
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

    ; Step 1: Write $A5 to bank $01:$0000 via STA long
    sta $D07B             ; turbo mode
    clc
    xce                   ; native mode
    sep #$20
    .a8

    lda #$A5
    sta f:$010000         ; STA long to bank $01:$0000

    lda #$5A
    sta f:$010001         ; STA long to bank $01:$0001

    ; Back to emulation mode
    sec
    xce

    ; Step 2: REU FETCH from REU $010000 to C64 $00FB, 2 bytes
    ; REU addr $010000 maps to SDRAM at REU_ADDR + $010000 = $1010000
    ; This is the same physical address that STA f:$010000 wrote to
    lda #$00
    sta $DF0A             ; no interrupts
    lda #$FB
    sta $DF02             ; C64 addr low = $FB
    lda #$00
    sta $DF03             ; C64 addr high = $00 -> C64 $00FB
    lda #$00
    sta $DF04             ; REU addr low = $00
    lda #$00
    sta $DF05             ; REU addr mid = $00
    lda #$01
    sta $DF06             ; REU addr high = $01 -> REU $010000
    lda #$02
    sta $DF07             ; length = 2
    lda #$00
    sta $DF08
    lda #$91              ; FETCH + FF00 + execute
    sta $DF01

    ; Small delay (CPU halts during DMA anyway)
    nop
    nop
    nop
    nop

    ; Step 3: Check results
    ; If DMA FETCH worked: $FB=$A5, $FC=$5A
    ; If DMA FETCH failed: $FB=old value
    lda $FB
    cmp #$A5
    bne @fail
    lda $FC
    cmp #$5A
    bne @fail

    ; PASS - green border
    lda #$05
    sta $D020

    ; Display "PASS" at screen line 4
    lda #$10
    sta $0400+160
    lda #$01
    sta $0400+161
    lda #$13
    sta $0400+162
    sta $0400+163
    jmp @show

@fail:
    ; FAIL - red border
    lda #$02
    sta $D020

    lda #$06
    sta $0400+160
    lda #$01
    sta $0400+161
    lda #$09
    sta $0400+162
    lda #$0C
    sta $0400+163

@show:
    ; Show $FB value
    lda #$20
    sta $0400+165

    lda $FB
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

    ; Show $FC value
    lda #$20
    sta $0400+168

    lda $FC
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    sta $0400+169
    pla
    and #$0F
    tax
    lda hextab,x
    sta $0400+170

    ; Show REU status
    lda #$20
    sta $0400+172
    lda #$13
    sta $0400+173

    lda $DF00
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hextab,x
    sta $0400+174
    pla
    and #$0F
    tax
    lda hextab,x
    sta $0400+175

@hang:
    jmp @hang

hextab:
    .byte $30,$31,$32,$33,$34,$35,$36,$37
    .byte $38,$39,$01,$02,$03,$04,$05,$06
