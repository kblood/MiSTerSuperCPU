; Native mode entry test — progressively tests each step
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

    ; Step 1: prove we're running
    lda #$31        ; '1'
    sta SCREEN+80

    ; Step 2: SEI
    sei
    lda #$32        ; '2'
    sta SCREEN+81

    ; Step 3: CLC + XCE (enter native mode)
    clc
    xce
    .a8
    .i8

    ; Step 4: in native mode now — write '3'
    lda #$33        ; '3'
    sta SCREEN+82

    ; Step 5: simple bank $00 long addressing
    lda #$34        ; '4'
    sta $000400+83  ; STA long to bank $00 screen

    ; Step 6: write to SuperRAM bank $01:$0000
    lda #$A5
    sta $010000

    lda #$35        ; '5'
    sta SCREEN+84

    ; Step 7: read back from SuperRAM bank $01:$0000
    lda $010000
    sta $02         ; save in ZP

    lda #$36        ; '6'
    sta SCREEN+85

    ; Step 8: SEC + XCE (back to emulation mode)
    sec
    xce
    .a8
    .i8

    lda #$37        ; '7'
    sta SCREEN+86

    ; Step 9: display the read-back value as hex
    lda $02
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr @nib
    pla
    jsr @nib

    ; Step 10: done marker
    lda #$38        ; '8'
    sta SCREEN+91

@spin:
    jmp @spin

@nib:
    and #$0F
    cmp #$0A
    bcc @dig
    adc #$36        ; 'A'-10 + carry = $37 + carry... need screen codes
@dig:
    adc #$30        ; '0'
    sta SCREEN+88
    inc @nib+10     ; self-modify store address (hacky but simple)
    rts
