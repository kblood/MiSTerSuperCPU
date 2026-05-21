; Minimal CHROUT test — just print "OK" and return
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

CHROUT = $FFD2

    lda #'O'
    jsr CHROUT
    lda #'K'
    jsr CHROUT
    lda #13
    jsr CHROUT
    rts
