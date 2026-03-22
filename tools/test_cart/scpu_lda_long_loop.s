; scpu_lda_long_loop.s — Tight loop LDA long from SuperRAM for UART diagnosis
;
; First writes $A5 to bank $02:$0100 via STA long (which works),
; then loops doing LDA $020100 and storing result to screen RAM.
; UART captures will show the bank byte and data on every frame.
;
; Build:
;   ca65 --cpu 65816 -o out/scpu_lda_long_loop.o scpu_lda_long_loop.s
;   ld65 -C c64-816.cfg -o out/scpu_lda_long_loop.prg out/scpu_lda_long_loop.o

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

    ; Enter native mode
    clc
    xce
    .a8
    .i8

    ; Write $A5 to bank $02:$0100 using STA long (known to work)
    lda #$A5
    sta $020100

    ; Write $5A to bank $02:$0200 as second test value
    lda #$5A
    sta $020200

    ; Verify STA worked: border = green(5) if first STA readback matches
    ; (This uses MVN-style access which works)

    ; Now loop: LDA long from $02:$0100, store result to screen
    ; Border cycles between 2 (red) and 5 (green) based on result
@loop:
    ; Read from SuperRAM
    lda $020100         ; LDA long — the instruction under test

    ; Store raw result to screen pos 0
    sta $0400

    ; Compare with expected
    cmp #$A5
    beq @pass

    ; FAIL: border = red, show result at $0401
    sta $0401
    lda #2
    sta $D020
    bra @loop           ; keep looping

@pass:
    ; PASS: border = green
    lda #5
    sta $D020

    ; Also test second address
    lda $020200
    sta $0402
    cmp #$5A
    beq @loop

    ; Second test failed
    lda #10             ; light red
    sta $D020
    bra @loop
