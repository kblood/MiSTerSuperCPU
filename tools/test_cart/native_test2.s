; Native mode test v2 — uses STA long for all screen writes
; Avoids DBR dependency
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

    ; Step 1: prove we're running (emulation mode)
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

    ; Step 4: in native mode — use STA long to write '3' (avoids DBR)
    lda #$33
    sta $000000+SCREEN+82  ; explicit bank $00

    ; Step 5: write '4' via STA long
    lda #$34
    sta $000000+SCREEN+83

    ; Step 6: write $A5 to SuperRAM bank $01:$0000
    lda #$A5
    sta $010000

    ; write '5'
    lda #$35
    sta $000000+SCREEN+84

    ; Step 7: read back from SuperRAM bank $01:$0000
    lda $010000
    sta $02         ; save in ZP (DP is at $0000, so this is STA dp)

    ; write '6'
    lda #$36
    sta $000000+SCREEN+85

    ; Step 8: write $5A to bank $01:$20FC
    lda #$5A
    sta $0120FC
    lda $0120FC
    sta $03

    ; write '7'
    lda #$37
    sta $000000+SCREEN+86

    ; Step 9: write $77 to bank $20:$20FC (Doom offset)
    lda #$77
    sta $2020FC
    lda $2020FC
    sta $04

    ; write '8'
    lda #$38
    sta $000000+SCREEN+87

    ; Step 10: return to emulation mode
    sec
    xce
    .a8
    .i8

    ; write '9' to confirm emu return
    lda #$39        ; '9'
    sta SCREEN+88

    ; Display hex results on row 3
    ; $02 = bank $01:$0000 readback (expect $A5)
    ldx #0
    lda $02
    jsr print_hex

    ; space
    lda #$20
    sta SCREEN+120+4,x

    ; $03 = bank $01:$20FC readback (expect $5A)
    ldx #5
    lda $03
    jsr print_hex

    ; space
    lda #$20
    sta SCREEN+120+9,x

    ; $04 = bank $20:$20FC readback (expect $77)
    ldx #10
    lda $04
    jsr print_hex

    ; "DONE" on row 4
    lda #$04        ; D
    sta SCREEN+160
    lda #$0F        ; O
    sta SCREEN+161
    lda #$0E        ; N
    sta SCREEN+162
    lda #$05        ; E
    sta SCREEN+163

@spin:
    jmp @spin

; Print A as hex at SCREEN+120+X, advances X by 2
print_hex:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr @nib
    pla
    and #$0F
    jsr @nib
    rts
@nib:
    and #$0F
    ora #$30        ; map 0-9 to $30-$39
    cmp #$3A        ; > '9'?
    bcc @store
    adc #$06        ; map A-F: $3A+7=$41 etc (carry set)
@store:
    sta SCREEN+120,x
    inx
    rts
