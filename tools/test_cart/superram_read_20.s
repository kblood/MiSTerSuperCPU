; ============================================================================
; superram_read_20.s — Read $20:$20F0..$20:$210F via LDA long, display as hex
; ============================================================================
; Purpose: diagnose Doom $20:$20FC crash. Compare what CPU sees vs file content.
; Expected (from doom.reu offset $2020F0):
;   F0: 0A 26 8E 0A 26 8E 0A 26 8E 0A 26 8E 85 8C 38 A5
;   00: 8C E5 90 85 8C A5 8E E5 92 85 8E 18 A5 94 65 8C
;
; Workaround: SEP #$30 after CLC+XCE (P65C816 XCE M/X bug).
; Avoids STA long (broken bank $00→bank $01 path) — only LDA long, STA dp.
;
; PREREQUISITE: doom.reu must be loaded into REU/SuperRAM via OSD before running.
; ============================================================================

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

start:
    ; Marker '1' (emu)
    lda #$31
    sta SCREEN+40
    sei
    lda #$32
    sta SCREEN+41

    ; Native mode entry (with M/X workaround)
    clc
    xce
    .a8
    .i8
    sep #$30

    lda #$33
    sta SCREEN+42

    ; ====================================================
    ; Read 32 bytes from $20:$20F0..$20:$210F
    ; Store to zero page $40..$5F
    ; All hand-encoded — only LDA long + STA dp
    ; ====================================================
    .byte $AF, $F0, $20, $20, $85, $40
    .byte $AF, $F1, $20, $20, $85, $41
    .byte $AF, $F2, $20, $20, $85, $42
    .byte $AF, $F3, $20, $20, $85, $43
    .byte $AF, $F4, $20, $20, $85, $44
    .byte $AF, $F5, $20, $20, $85, $45
    .byte $AF, $F6, $20, $20, $85, $46
    .byte $AF, $F7, $20, $20, $85, $47
    .byte $AF, $F8, $20, $20, $85, $48
    .byte $AF, $F9, $20, $20, $85, $49
    .byte $AF, $FA, $20, $20, $85, $4A
    .byte $AF, $FB, $20, $20, $85, $4B
    .byte $AF, $FC, $20, $20, $85, $4C    ; *** $20:20FC ***
    .byte $AF, $FD, $20, $20, $85, $4D
    .byte $AF, $FE, $20, $20, $85, $4E
    .byte $AF, $FF, $20, $20, $85, $4F
    .byte $AF, $00, $21, $20, $85, $50
    .byte $AF, $01, $21, $20, $85, $51
    .byte $AF, $02, $21, $20, $85, $52
    .byte $AF, $03, $21, $20, $85, $53
    .byte $AF, $04, $21, $20, $85, $54
    .byte $AF, $05, $21, $20, $85, $55
    .byte $AF, $06, $21, $20, $85, $56
    .byte $AF, $07, $21, $20, $85, $57
    .byte $AF, $08, $21, $20, $85, $58
    .byte $AF, $09, $21, $20, $85, $59
    .byte $AF, $0A, $21, $20, $85, $5A
    .byte $AF, $0B, $21, $20, $85, $5B
    .byte $AF, $0C, $21, $20, $85, $5C
    .byte $AF, $0D, $21, $20, $85, $5D
    .byte $AF, $0E, $21, $20, $85, $5E
    .byte $AF, $0F, $21, $20, $85, $5F

    lda #$34
    sta SCREEN+43

    ; Return to emulation
    sec
    xce
    .a8
    .i8
    cli

    lda #$35
    sta SCREEN+44

    ; ============================================================
    ; Display 32 bytes as hex on screen rows 3-4
    ; Row 3 (SCREEN+120): bytes $40-$4F (=$20F0-$20FF)
    ; Row 4 (SCREEN+160): bytes $50-$5F (=$2100-$210F)
    ; ============================================================
    ldx #0
@loop1:
    lda $40,x
    jsr put_hex_lo
    inx
    cpx #16
    bne @loop1

    ldx #0
@loop2:
    lda $50,x
    jsr put_hex_hi
    inx
    cpx #16
    bne @loop2

@spin:
    jmp @spin

; ----------------------------------------------------------------
; put_hex_lo: A=byte, X=byte index (0-15)
; Writes 2 hex chars to SCREEN+120 + (X*2), (X*2+1)
; ----------------------------------------------------------------
put_hex_lo:
    pha
    txa
    asl                 ; X*2 → screen offset
    tay
    pla
    pha
    lsr
    lsr
    lsr
    lsr
    jsr to_screencode
    sta SCREEN+120,y
    iny
    pla
    and #$0F
    jsr to_screencode
    sta SCREEN+120,y
    rts

put_hex_hi:
    pha
    txa
    asl
    tay
    pla
    pha
    lsr
    lsr
    lsr
    lsr
    jsr to_screencode
    sta SCREEN+160,y
    iny
    pla
    and #$0F
    jsr to_screencode
    sta SCREEN+160,y
    rts

; A in 0..15 → screen code (0-9 → $30-$39, A-F → $01-$06)
to_screencode:
    cmp #$0A
    bcc @dig
    sec
    sbc #$0A
    clc
    adc #$01
    rts
@dig:
    clc
    adc #$30
    rts
