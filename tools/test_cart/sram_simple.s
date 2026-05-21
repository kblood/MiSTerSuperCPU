; Minimal SuperRAM test — write/read one byte at bank $01:$0000
; Results shown as single hex chars at top of screen
; Build: ca65 --cpu 65816 sram_simple.s && ld65 -C c64prg.cfg sram_simple.o -o sram_simple.prg

.segment "LOADADDR"
.word $0801

.segment "EXEHDR"
.word @nextline
.word 10
.byte $9E
.byte "2061",0
@nextline:
.word 0

.segment "CODE"

SCREEN = $0400

    ; Step 1: Write 'A' to screen to prove we got here
    lda #$01        ; 'A' in PETSCII screen code
    sta SCREEN

    ; Step 2: Write 'B' to show we're about to enter native
    lda #$02
    sta SCREEN+1

    ; Step 3: Enter native mode
    sei
    clc
    xce
    .a8
    .i8

    ; Step 4: Write 'C' to show native mode entry worked
    lda #$03
    sta SCREEN+2

    ; Step 5: Write $A5 to SuperRAM bank $01, offset $0000
    lda #$A5
    sta $010000     ; STA long $01:0000

    ; Step 6: Write 'D' to show write completed
    lda #$04
    sta SCREEN+3

    ; Step 7: Read back from SuperRAM
    lda $010000     ; LDA long $01:0000

    ; Step 8: Store result at $02 for later display
    sta $02

    ; Step 9: Write 'E' to show read completed
    lda #$05
    sta SCREEN+4

    ; Step 10: Write $5A to bank $01, offset $20FC (Doom offset)
    lda #$5A
    sta $0120FC
    lda $0120FC
    sta $03

    ; Step 11: Write 'F' to show second test done
    lda #$06
    sta SCREEN+5

    ; Step 12: Write $77 to bank $20, offset $20FC (Doom bank+offset)
    lda #$77
    sta $2020FC
    lda $2020FC
    sta $04

    ; Write 'G'
    lda #$07
    sta SCREEN+6

    ; Return to emulation mode
    sec
    xce
    .a8
    .i8

    ; Write 'H' to show emu mode return worked
    lda #$08
    sta SCREEN+7

    ; Now display hex results on row 2
    ; Result 1: $02 (bank $01:$0000, expected $A5)
    lda $02
    jsr print_hex_at_10

    ; Result 2: $03 (bank $01:$20FC, expected $5A)
    lda $03
    jsr print_hex_at_14

    ; Result 3: $04 (bank $20:$20FC, expected $77)
    lda $04
    jsr print_hex_at_18

    ; Write "DONE" on row 3
    lda #$04        ; 'D'
    sta SCREEN+120
    lda #$0F        ; 'O'
    sta SCREEN+121
    lda #$0E        ; 'N'
    sta SCREEN+122
    lda #$05        ; 'E'
    sta SCREEN+123

@spin:
    jmp @spin

; Print A as 2 hex digits at SCREEN+40+X (row 1, column X)
; X is set by caller wrapper
print_hex_at_10:
    ldx #10
    jmp print_hex_at_x
print_hex_at_14:
    ldx #14
    jmp print_hex_at_x
print_hex_at_18:
    ldx #18
    jmp print_hex_at_x

print_hex_at_x:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr @nib
    pla
@nib:
    and #$0F
    cmp #$0A
    bcc @dig
    ; A >= 10: subtract 10, add 'A' screen code (1)
    sbc #$0A
    clc
    adc #$01        ; screen code for 'A'
    jmp @store
@dig:
    ; 0-9: add $30... no, screen codes: '0'=$30
    ; Actually C64 screen codes: 0-9 = $30-$39
    clc
    adc #$30
@store:
    sta SCREEN+40,x
    inx
    rts
