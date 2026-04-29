; Use border color $D020 as progress marker — survives KERNAL screen clear
; Borders: 0=black, 1=white, 2=red, 3=cyan, 4=purple, 5=green, 6=blue, 7=yellow
; If we see WHITE border = test reached step 1 only
; CYAN border = step 2 reached
; etc.
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
BORDER = $D020
    sei
    lda #1            ; WHITE = before native
    sta BORDER
    clc
    xce
    .a8
    .i8
    sep #$30
    lda #2            ; RED = native mode entered
    sta BORDER
    ; LDA long $00:0040 (BRAM)
    .byte $AF, $40, $00, $00
    lda #5            ; GREEN = LDA long completed
    sta BORDER
@s: jmp @s
