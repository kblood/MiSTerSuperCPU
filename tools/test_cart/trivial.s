; Trivial test: writes HELLO to screen position 0, then loops
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
    ; Write HELLO at screen position 80 (row 2, col 0)
    lda #$08        ; H screen code
    sta $0450
    lda #$05        ; E
    sta $0451
    lda #$0C        ; L
    sta $0452
    lda #$0C        ; L
    sta $0453
    lda #$0F        ; O
    sta $0454
    ; Set colors
    lda #$01        ; white
    sta $D850
    sta $D851
    sta $D852
    sta $D853
    sta $D854
@spin:
    jmp @spin
