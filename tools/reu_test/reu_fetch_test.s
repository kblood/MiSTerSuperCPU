; reu_fetch_test.s
; Test that REU FETCH from doom.reu bank $02 page $00 delivers the right bytes.
; Expected first 16 bytes at REU $020000:
;   00 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01
;
; This program:
;   1) Sets up a single REU FETCH from $020000 to C64 $0400 (length $0100)
;   2) Triggers FETCH via $DF01 = $91
;   3) Fills the screen with a recognizable pattern based on the result:
;      - if $0400 == $00 and $0401 == $01: green border (success)
;      - else: red border + dump first 8 bytes as hex digits at top of screen
;   4) Loops forever
;
; Assemble:
;   ca65 -o reu_fetch_test.o reu_fetch_test.s
;   ld65 -t c64 -o reu_fetch_test.prg reu_fetch_test.o c64.lib

.feature labels_without_colons

.segment "STARTUP"
.segment "INIT"
.segment "ONCE"
.segment "BSS"
.segment "ZEROPAGE"

.segment "CODE"

.export _main
_main:
        sei
        ; Save $01 for safety, set to $35 (no ROMs, I/O on)
        lda $01
        pha
        lda #$35
        sta $01

        ; Border = light blue (sentinel: program is running)
        lda #$0E
        sta $D020
        lda #$06
        sta $D021

        ; Set up REU FETCH
        lda #$00
        sta $DF02         ; C64 addr lo
        lda #$04
        sta $DF03         ; C64 addr hi  -> $0400
        lda #$00
        sta $DF04         ; REU addr lo
        sta $DF05         ; REU addr mid
        lda #$02
        sta $DF06         ; REU addr hi  -> $020000
        lda #$00
        sta $DF07         ; length lo
        lda #$01
        sta $DF08         ; length hi    -> $0100 (256 bytes)

        lda #$91
        sta $DF01         ; cmd = FETCH (immediate, type 1)

        ; Done — REU FETCH is synchronous on real HW (CPU stalled).
        ; On our core: CPU continues but REU runs in background.
        ; Wait a few thousand cycles to be safe.
        ldx #$00
        ldy #$10
delay:  dex
        bne delay
        dey
        bne delay

        ; Compare $0400 vs $00 and $0401 vs $01 (the expected first two bytes)
        lda $0400
        cmp #$00
        bne fail
        lda $0401
        cmp #$01
        bne fail

        ; SUCCESS — green border
        lda #$05
        sta $D020
        jmp halt

fail:
        ; FAILURE — red border, dump first 8 bytes as hex pairs to screen $0400+40
        lda #$02
        sta $D020

        ldx #$00
dump_loop:
        lda $0400,x
        pha               ; save byte
        lsr
        lsr
        lsr
        lsr
        jsr to_petscii
        sta $0428,y
        iny
        pla
        and #$0F
        jsr to_petscii
        sta $0428,y
        iny
        iny               ; skip a column for readability
        inx
        cpx #$08
        bne dump_loop

halt:
        jmp halt

; Convert nibble in A to PETSCII screen code (0-9, A-F)
to_petscii:
        cmp #$0A
        bcc digit
        clc
        adc #$07          ; A-F: $0A+7 = $11 ('A' screen code)
digit:
        adc #$30          ; '0' screen code is $30
        rts
